"""Leitura dos arquivos oficiais e preparação dos dados para a carga.

1. Cada ZIP é descompactado em streaming (contando as linhas no caminho).
2. DuckDB lê o CSV (sem cabeçalho, ';', aspas, Latin-1) e filtra o que interessa:
   estabelecimentos abertos dentro da janela de prospecção + os que já existem
   na base operacional (para atualizar a situação cadastral).
3. Polars normaliza e valida (CNPJ alfanumérico + DV, datas, CEP, e-mail...)
   e grava CSVs UTF-8 prontos para COPY no PostgreSQL.

Só o necessário à prospecção chega ao banco operacional.
"""
from __future__ import annotations

import logging
import shutil
import zipfile
from dataclasses import dataclass, field
from datetime import date, timedelta
from pathlib import Path
from typing import Callable

import duckdb
import polars as pl

from .cnpj import CHAR_VALUE, WEIGHTS_1, WEIGHTS_2
from .layout import (CODIGO_DESCRICAO, EMPRESAS, EMPRESAS_FILES, ESTABELECIMENTOS,
                     ESTABELECIMENTOS_FILES, SIMPLES, SIMPLES_FILES)

log = logging.getLogger(__name__)

VALID_SITUACAO = ["01", "02", "03", "04", "08"]
VALID_PORTE = ["00", "01", "03", "05"]


@dataclass
class PreparedData:
    work_dir: Path
    files: dict[str, Path] = field(default_factory=dict)  # tabela -> CSV pronto para COPY
    records_read: int = 0
    rejected_rows: int = 0
    invalid_cnpj: int = 0
    establishments: int = 0
    new_establishments: int = 0   # ainda não estão no banco (os demais só são atualizados)
    window_from: date | None = None
    window_to: date | None = None


def extract_zip(zip_path: Path, out_dir: Path) -> tuple[Path, int]:
    """Descompacta o único arquivo do ZIP; retorna (caminho, nº de linhas)."""
    out_dir.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(zip_path) as z:
        members = [m for m in z.infolist() if not m.is_dir()]
        if len(members) != 1:
            raise ValueError(f"{zip_path.name}: esperado 1 arquivo no ZIP, encontrado {len(members)}")
        out = out_dir / (zip_path.stem + ".csv")
        lines = 0
        last = b"\n"
        with z.open(members[0]) as src, open(out, "wb") as dst:
            while True:
                buf = src.read(16 * 1024 * 1024)  # zipfile valida o CRC ao final
                if not buf:
                    break
                lines += buf.count(b"\n")
                last = buf[-1:]
                dst.write(buf)
        if last != b"\n" and out.stat().st_size > 0:
            lines += 1
    return out, lines


def iter_zip_chunks(zip_path: Path, out_dir: Path, chunk_bytes: int = 128 * 1024 * 1024):
    """Lê o único arquivo do ZIP em blocos de ~chunk_bytes, sempre cortando em fim de linha.

    Cada bloco é gravado num arquivo temporário (apagado pelo chamador). Assim o pico de disco
    fica em um bloco, em vez do arquivo inteiro descompactado (vários GB). O CRC do ZIP é
    validado pelo zipfile ao final da leitura.
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(zip_path) as z:
        members = [m for m in z.infolist() if not m.is_dir()]
        if len(members) != 1:
            raise ValueError(f"{zip_path.name}: esperado 1 arquivo no ZIP, encontrado {len(members)}")
        with z.open(members[0]) as src:
            rest = b""
            k = 0
            while True:
                buf = src.read(chunk_bytes)
                if not buf:
                    break
                buf = rest + buf
                cut = _safe_cut(buf)
                if cut == -1:
                    rest = buf
                    continue
                rest = buf[cut + 1:]
                yield _write_chunk(out_dir, zip_path.stem, k, buf[:cut + 1])
                k += 1
            if rest.strip():
                yield _write_chunk(out_dir, zip_path.stem, k, rest + b"\n")


def _safe_cut(buf: bytes, max_tries: int = 1000) -> int:
    """Posição da última quebra de linha que fecha um registro (fora de aspas).

    A Receita coloca todos os campos entre aspas e alguns campos contêm quebras
    de linha. Um corte é seguro quando o número de aspas antes dele é par.
    """
    total = buf.count(b'"')
    pos = len(buf)
    for _ in range(max_tries):
        nl = buf.rfind(b"\n", 0, pos)
        if nl == -1:
            return -1
        if (total - buf.count(b'"', nl)) % 2 == 0:
            return nl
        pos = nl
    return -1


def to_utf8(data: bytes) -> bytes:
    """Converte um bloco para UTF-8.

    Os arquivos da Receita são declarados como Latin-1 (ISO-8859-1), mas trazem
    caracteres do Windows-1252 (aspas tipográficas, travessão etc.). Blocos que
    já são UTF-8 válido passam direto.
    """
    try:
        data.decode("utf-8")
        return data
    except UnicodeDecodeError:
        pass
    # cp1252 cobre os bytes 0x80-0x9F; os 5 bytes sem mapeamento viram o caractere Latin-1 equivalente
    text = data.decode("cp1252", errors="surrogateescape")
    if "\udc81" in text or "\udc8d" in text or "\udc8f" in text or "\udc90" in text or "\udc9d" in text:
        text = "".join(chr(ord(c) - 0xDC00) if 0xDC80 <= ord(c) <= 0xDCFF else c for c in text)
    return text.encode("utf-8")


def _write_chunk(out_dir: Path, stem: str, k: int, data: bytes) -> tuple[Path, int]:
    path = out_dir / f"{stem}.{k:04d}.csv"
    path.write_bytes(to_utf8(data))
    return path, data.count(b"\n")


def _sqlpath(path: Path) -> str:
    """Caminho como literal SQL do DuckDB (barras normais funcionam também no Windows)."""
    return Path(path).resolve().as_posix().replace("'", "''")


def _read_csv_sql(path: Path, columns: list[str], rejects: str) -> str:
    cols = ", ".join(f"'{c}': 'VARCHAR'" for c in columns)
    p = _sqlpath(path)
    return (
        f"read_csv('{p}', auto_detect=false, header=false, delim=';', quote='\"', escape='\"', encoding='utf-8', "
        f"columns={{{cols}}}, null_padding=true, store_rejects=true, rejects_table='{rejects}', "
        f"rejects_scan='{rejects}_scan', parallel=false)"
    )


def prepare(
    zips: dict[str, Path] | Callable[[str], Path],
    work_dir: Path,
    competence: str,
    ref_date: date,
    window_days: int,
    existing_cnpjs: Path | None,
    settings_memory: str = "2GB",
    threads: int = 4,
    progress: Callable[[str, int], None] | None = None,
    release: Callable[[str], None] | None = None,
    chunk_bytes: int = 128 * 1024 * 1024,
) -> PreparedData:
    """Processa os arquivos de uma competência.

    `zips`: dicionário nome → caminho, ou função que entrega (baixando, se preciso) o ZIP pedido.
    `release`: chamada depois que cada ZIP foi lido (permite apagá-lo e economizar disco).
    `existing_cnpjs`: CSV com coluna cnpj (pode ser None).
    """
    get_zip = zips.__getitem__ if isinstance(zips, dict) else zips
    release = release or (lambda _name: None)
    work_dir.mkdir(parents=True, exist_ok=True)
    out_dir = work_dir / "out"
    out_dir.mkdir(exist_ok=True)
    result = PreparedData(work_dir=work_dir)
    result.window_from = ref_date - timedelta(days=window_days)
    result.window_to = ref_date

    db_path = work_dir / "stage.duckdb"
    db_path.unlink(missing_ok=True)
    con = duckdb.connect(str(db_path))
    con.execute(f"SET memory_limit='{settings_memory}'")
    con.execute(f"SET threads={int(threads)}")
    con.execute(f"SET temp_directory='{_sqlpath(work_dir / 'duck_tmp')}'")
    con.execute("SET preserve_insertion_order=false")

    def step(msg: str):
        log.info(msg)
        if progress:
            progress(msg, 0)

    # ---------------- CNPJs já existentes (para atualização cadastral) ----------------
    con.execute("CREATE TABLE existing (cnpj VARCHAR PRIMARY KEY)")
    if existing_cnpjs and existing_cnpjs.exists() and existing_cnpjs.stat().st_size > 0:
        con.execute(f"INSERT INTO existing SELECT DISTINCT cnpj FROM read_csv('{_sqlpath(existing_cnpjs)}', header=true, columns={{'cnpj':'VARCHAR'}})")

    chunk_dir = work_dir / "chunks"

    def ingest(name: str, table: str, columns: list[str], where: str) -> None:
        """Lê um ZIP em blocos (sem descompactar inteiro no disco) e grava só as linhas filtradas."""
        zip_path = get_zip(name)
        for k, (chunk, lines) in enumerate(iter_zip_chunks(zip_path, chunk_dir, chunk_bytes)):
            result.records_read += lines
            rej = f"rej_{table}_{abs(hash(name)) % 10_000}_{k}"
            con.execute(f"INSERT INTO {table} SELECT * FROM {_read_csv_sql(chunk, columns, rej)} {where}")
            result.rejected_rows += con.execute(f"SELECT count(*) FROM {rej}").fetchone()[0]
            con.execute(f"DROP TABLE IF EXISTS {rej}")
            con.execute(f"DROP TABLE IF EXISTS {rej}_scan")
            chunk.unlink(missing_ok=True)
        release(name)
        if progress:
            progress(f"{name} processado", 1)

    # ---------------- Estabelecimentos ----------------
    est_cols = ", ".join(f'"{c}" VARCHAR' for c in ESTABELECIMENTOS)
    con.execute(f"CREATE TABLE est ({est_cols})")
    cutoff = result.window_from.strftime("%Y%m%d")
    for i, name in enumerate(ESTABELECIMENTOS_FILES):
        step(f"Lendo {name} ({i + 1}/{len(ESTABELECIMENTOS_FILES)})")
        ingest(name, "est", ESTABELECIMENTOS, f"""
            WHERE (trim(data_inicio_atividade) >= '{cutoff}' AND trim(data_inicio_atividade) ~ '^[0-9]{{8}}$')
               OR upper(trim(cnpj_basico) || trim(cnpj_ordem) || trim(cnpj_dv)) IN (SELECT cnpj FROM existing)""")

    con.execute("CREATE TABLE basicos AS SELECT DISTINCT upper(trim(cnpj_basico)) AS cnpj_basico FROM est")
    only_basicos = "WHERE upper(trim(cnpj_basico)) IN (SELECT cnpj_basico FROM basicos)"

    # ---------------- Empresas ----------------
    con.execute(f"CREATE TABLE emp ({', '.join(f'{chr(34)}{c}{chr(34)} VARCHAR' for c in EMPRESAS)})")
    for i, name in enumerate(EMPRESAS_FILES):
        step(f"Lendo {name} ({i + 1}/{len(EMPRESAS_FILES)})")
        ingest(name, "emp", EMPRESAS, only_basicos)

    # ---------------- Simples / MEI ----------------
    con.execute(f"CREATE TABLE sim ({', '.join(f'{chr(34)}{c}{chr(34)} VARCHAR' for c in SIMPLES)})")
    for name in SIMPLES_FILES:
        step(f"Lendo {name}")
        ingest(name, "sim", SIMPLES, only_basicos)

    # ---------------- Tabelas de referência ----------------
    for name, table in [("Cnaes.zip", "ref_cnae"), ("Municipios.zip", "ref_mun"), ("Naturezas.zip", "ref_nat")]:
        con.execute(f"CREATE TABLE {table} (codigo VARCHAR, descricao VARCHAR)")
        ingest(name, table, CODIGO_DESCRICAO, "")

    # Exporta para Parquet e transforma com Polars
    for t in ["est", "emp", "sim", "ref_cnae", "ref_mun", "ref_nat"]:
        con.execute(f"COPY {t} TO '{_sqlpath(work_dir / (t + '.parquet'))}' (FORMAT parquet)")
    con.close()
    db_path.unlink(missing_ok=True)
    shutil.rmtree(work_dir / "duck_tmp", ignore_errors=True)
    shutil.rmtree(chunk_dir, ignore_errors=True)

    step("Normalizando e validando registros")
    _transform_with_polars(work_dir, out_dir, competence, result)
    return result


# ---------------------------------------------------------------------- Polars
def _clean(col: str) -> pl.Expr:
    return pl.col(col).str.strip_chars().replace("", None)


def _digits(col: str) -> pl.Expr:
    return pl.col(col).str.replace_all(r"\D", "").replace("", None)


def _date(col: str) -> pl.Expr:
    c = pl.col(col).str.strip_chars()
    parsed = c.str.strptime(pl.Date, "%Y%m%d", strict=False)
    # datas "00000000"/"0" e anteriores a 1900 são inválidas
    return pl.when(parsed >= pl.date(1900, 1, 1)).then(parsed).otherwise(None)


def _lpad_code(col: str, n: int) -> pl.Expr:
    d = _digits(col)
    return pl.when(d.is_not_null()).then(d.str.zfill(n)).otherwise(None)


def _cnpj_valid_expr(col: str) -> pl.Expr:
    """Validação vetorizada do DV (numérico e alfanumérico)."""
    vals = [pl.col(col).str.slice(i, 1).replace_strict(CHAR_VALUE, default=-1000, return_dtype=pl.Int32)
            for i in range(12)]
    s1 = sum(v * w for v, w in zip(vals, WEIGHTS_1))
    d1 = pl.when(s1 % 11 < 2).then(0).otherwise(11 - s1 % 11)
    s2 = sum(v * w for v, w in zip(vals, WEIGHTS_2[:12])) + d1 * WEIGHTS_2[12]
    d2 = pl.when(s2 % 11 < 2).then(0).otherwise(11 - s2 % 11)
    dv = pl.col(col).str.slice(12, 2)
    return (
        pl.col(col).str.contains(r"^[0-9A-Z]{12}[0-9]{2}$")
        & (pl.col(col).str.slice(0, 1).repeat_by(14).list.join("") != pl.col(col))
        & (dv == (d1.cast(pl.Utf8) + d2.cast(pl.Utf8)))
    )


def _pg_array(col: str) -> pl.Expr:
    """'4711301,4712100' -> '{4711301,4712100}' (literal de array do PostgreSQL)."""
    codes = pl.col(col).fill_null("").str.replace_all(r"[^0-9,]", "").str.split(",")
    codes = codes.list.eval(pl.element().filter(pl.element().str.len_chars() > 0).str.zfill(7))
    return pl.lit("{") + codes.list.join(",") + pl.lit("}")


def _transform_with_polars(work_dir: Path, out_dir: Path, competence: str, result: PreparedData) -> None:
    est = pl.scan_parquet(work_dir / "est.parquet").select(
        _clean("cnpj_basico").str.to_uppercase().alias("cnpj_basico"),
        _clean("cnpj_ordem").str.to_uppercase().alias("cnpj_ordem"),
        _digits("cnpj_dv").alias("cnpj_dv"),
        _digits("identificador_matriz").cast(pl.Int16, strict=False).alias("identificador_matriz"),
        _clean("nome_fantasia").alias("nome_fantasia"),
        _lpad_code("situacao_cadastral", 2).alias("situacao_cadastral"),
        _date("data_situacao_cadastral").alias("data_situacao_cadastral"),
        _clean("motivo_situacao").alias("motivo_situacao"),
        _date("data_inicio_atividade").alias("data_inicio_atividade"),
        _lpad_code("cnae_principal", 7).alias("cnae_principal"),
        _pg_array("cnae_secundaria").alias("cnaes_secundarios"),
        _clean("tipo_logradouro").alias("tipo_logradouro"),
        _clean("logradouro").alias("logradouro"),
        _clean("numero").alias("numero"),
        _clean("complemento").alias("complemento"),
        _clean("bairro").alias("bairro"),
        _digits("cep").alias("cep"),
        _clean("uf").str.to_uppercase().alias("uf"),
        _lpad_code("municipio", 4).alias("municipio_code"),
        _digits("ddd1").alias("ddd1"),
        _digits("telefone1").alias("telefone1"),
        _digits("ddd2").alias("ddd2"),
        _digits("telefone2").alias("telefone2"),
        _clean("email").str.to_lowercase().alias("email"),
        _clean("situacao_especial").alias("situacao_especial"),
        _date("data_situacao_especial").alias("data_situacao_especial"),
    ).with_columns(
        (pl.col("cnpj_basico") + pl.col("cnpj_ordem") + pl.col("cnpj_dv")).alias("cnpj"),
        pl.when(pl.col("cep").str.len_chars() == 8).then(pl.col("cep")).otherwise(None).alias("cep"),
        pl.when(pl.col("uf").str.len_chars() == 2).then(pl.col("uf")).otherwise(None).alias("uf"),
        pl.when(pl.col("email").str.contains(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")).then(pl.col("email")).otherwise(None).alias("email"),
        pl.lit(competence).alias("source_competence"),
    ).filter(
        pl.col("cnpj").str.contains(r"^[0-9A-Z]{12}[0-9]{2}$")
        & pl.col("identificador_matriz").is_in([1, 2])
        & pl.col("situacao_cadastral").is_in(VALID_SITUACAO)
    ).unique(subset="cnpj", keep="last")

    est_df = est.collect()
    result.invalid_cnpj = int(est_df.select((~_cnpj_valid_expr("cnpj")).sum()).item() or 0)
    result.establishments = est_df.height
    try:
        existing_df = con.execute("SELECT cnpj FROM existing").pl()
        result.new_establishments = est_df.join(existing_df, on="cnpj", how="anti").height
    except Exception:  # noqa: BLE001 — estimativa conservadora: tudo novo
        result.new_establishments = est_df.height

    est_cols = ["cnpj", "cnpj_basico", "cnpj_ordem", "cnpj_dv", "identificador_matriz", "nome_fantasia",
                "situacao_cadastral", "data_situacao_cadastral", "motivo_situacao", "data_inicio_atividade",
                "cnae_principal", "cnaes_secundarios", "tipo_logradouro", "logradouro", "numero", "complemento",
                "bairro", "cep", "uf", "municipio_code", "ddd1", "telefone1", "ddd2", "telefone2", "email",
                "situacao_especial", "data_situacao_especial", "source_competence"]
    est_df.select(est_cols).write_csv(out_dir / "establishments.csv")
    result.files["establishments"] = out_dir / "establishments.csv"

    basicos = est_df.select("cnpj_basico").unique()

    emp = (
        pl.scan_parquet(work_dir / "emp.parquet")
        .select(
            _clean("cnpj_basico").str.to_uppercase().alias("cnpj_basico"),
            _clean("razao_social").alias("razao_social"),
            _lpad_code("natureza_juridica", 4).alias("natureza_juridica"),
            _clean("capital_social").str.replace_all(r"\.", "").str.replace(",", ".")
                .cast(pl.Float64, strict=False).alias("capital_social"),
            _lpad_code("porte", 2).alias("porte"),
            _clean("ente_federativo").alias("ente_federativo"),
        )
        .with_columns(
            pl.when(pl.col("porte").is_in(VALID_PORTE)).then(pl.col("porte")).otherwise(None).alias("porte"),
            pl.when(pl.col("capital_social") >= 0).then(pl.col("capital_social").round(2)).otherwise(None).alias("capital_social"),
            pl.lit(competence).alias("source_competence"),
        )
        .unique(subset="cnpj_basico", keep="last")
        .collect()
    )
    # empresas sem linha em Empresas*.zip recebem registro mínimo (mantém a integridade referencial)
    emp = basicos.join(emp, on="cnpj_basico", how="left").with_columns(pl.lit(competence).alias("source_competence"))
    emp.select(["cnpj_basico", "razao_social", "natureza_juridica", "capital_social", "porte",
                "ente_federativo", "source_competence"]).write_csv(out_dir / "companies.csv")
    result.files["companies"] = out_dir / "companies.csv"

    def sn(col: str) -> pl.Expr:
        c = _clean(col).str.to_uppercase()
        return pl.when(c == "S").then(True).when(c == "N").then(False).otherwise(None)

    sim = (
        pl.scan_parquet(work_dir / "sim.parquet")
        .select(
            _clean("cnpj_basico").str.to_uppercase().alias("cnpj_basico"),
            sn("opcao_simples").alias("opcao_simples"),
            _date("data_opcao_simples").alias("data_opcao_simples"),
            _date("data_exclusao_simples").alias("data_exclusao_simples"),
            sn("opcao_mei").alias("opcao_mei"),
            _date("data_opcao_mei").alias("data_opcao_mei"),
            _date("data_exclusao_mei").alias("data_exclusao_mei"),
            pl.lit(competence).alias("source_competence"),
        )
        .unique(subset="cnpj_basico", keep="last")
        .collect()
    )
    sim.write_csv(out_dir / "company_simple_status.csv")
    result.files["company_simple_status"] = out_dir / "company_simple_status.csv"

    for src, dst, n in [("ref_cnae", "cnae_catalog", 7), ("ref_mun", "municipalities", 4), ("ref_nat", "legal_natures", 4)]:
        df = (
            pl.scan_parquet(work_dir / f"{src}.parquet")
            .select(_lpad_code("codigo", n).alias("code"), _clean("descricao").alias("description"))
            .filter(pl.col("code").is_not_null() & (pl.col("code").str.len_chars() == n) & pl.col("description").is_not_null())
            .unique(subset="code", keep="last")
            .collect()
        )
        df.write_csv(out_dir / f"{dst}.csv")
        result.files[dst] = out_dir / f"{dst}.csv"

    for t in ["est", "emp", "sim", "ref_cnae", "ref_mun", "ref_nat"]:
        (work_dir / f"{t}.parquet").unlink(missing_ok=True)
