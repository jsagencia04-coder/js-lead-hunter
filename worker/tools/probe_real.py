"""Valida o leiaute com dados REAIS sem baixar os arquivos inteiros.

Baixa os primeiros MB de alguns ZIPs da competência mais recente, descompacta
parcialmente (deflate em streaming) e passa as linhas pelo mesmo caminho do
worker: conversão UTF-8 → DuckDB (read_csv) → Polars. Não grava no banco.
Uso: python tools/probe_real.py
"""
import struct
import sys
import tempfile
import zlib
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import duckdb  # noqa: E402

from lead_hunter.config import Settings  # noqa: E402
from lead_hunter.layout import CODIGO_DESCRICAO, EMPRESAS, ESTABELECIMENTOS, SIMPLES  # noqa: E402
from lead_hunter.rf_source import RFSource  # noqa: E402
from lead_hunter.transform import _read_csv_sql, to_utf8  # noqa: E402

PROBES = [("Estabelecimentos0.zip", ESTABELECIMENTOS), ("Empresas0.zip", EMPRESAS),
          ("Simples.zip", SIMPLES), ("Cnaes.zip", CODIGO_DESCRICAO), ("Municipios.zip", CODIGO_DESCRICAO)]


def sample(src: RFSource, comp: str, name: str, nbytes: int = 8 * 1024 * 1024) -> bytes:
    r = src.client.get(src.file_url(comp, name), headers={"Range": f"bytes=0-{nbytes - 1}"})
    raw = r.content
    sig, _v, _f, method, _t, _d, _crc, _cs, _us, nlen, xlen = struct.unpack("<IHHHHHIIIHH", raw[:30])
    assert sig == 0x04034B50, "assinatura ZIP inesperada"
    data = raw[30 + nlen + xlen:]
    out = zlib.decompressobj(-15).decompress(data) if method == 8 else data
    return out[: out.rfind(b"\n") + 1]


def main() -> int:
    src = RFSource(Settings(database_url="x"))
    comp, _ = src.latest_complete_competence()
    print("Competência:", comp)
    tmp = Path(tempfile.mkdtemp())
    con = duckdb.connect()
    ok = True
    for name, cols in PROBES:
        raw = sample(src, comp, name)
        utf = to_utf8(raw)
        f = tmp / (name + ".csv")
        f.write_bytes(utf)
        try:
            t = name.split('.')[0].lower()
            con.execute(f"CREATE TABLE s_{t} AS SELECT * FROM {_read_csv_sql(f, cols, 'rej_' + t)}")
            rows = con.execute(f"SELECT count(*) FROM s_{t}").fetchone()[0]
            rej = con.execute(f"SELECT count(*) FROM rej_{t}").fetchone()[0]
            first = con.execute(f"SELECT * FROM s_{t} LIMIT 1").fetchone()
            nlines = raw.count(b"\n")
            print(f"{name}: {nlines} linhas na amostra, {rows} lidas, {rej} rejeitadas")
            print("   1ª linha:", [str(v)[:25] for v in first][:12])
            nonascii = sorted({b for b in raw if b >= 0x80})
            print("   bytes não-ASCII presentes:", " ".join(f"{b:02x}" for b in nonascii[:40]))
            if rej > rows * 0.01:
                ok = False
        except Exception as exc:  # noqa: BLE001
            ok = False
            print(f"{name}: ERRO {exc}")
    if ok:
        # pipeline completo (DuckDB + Polars) sobre as amostras reais
        import zipfile

        from lead_hunter.layout import REQUIRED_FILES
        from lead_hunter.transform import prepare
        zdir = tmp / "zips"
        zdir.mkdir()
        samples = {n: (tmp / (n + ".csv")) for n, _ in PROBES}
        zips = {}
        for n in REQUIRED_FILES:
            z = zdir / n
            with zipfile.ZipFile(z, "w", zipfile.ZIP_DEFLATED) as zf:
                payload = sample(src, comp, n) if n in samples else b""
                zf.writestr(n.replace(".zip", ".CSV"), payload)
            zips[n] = z
        data = prepare(zips, tmp / "work", comp, date.today(), 40000, None, "1GB", 2)
        print(f"Pipeline completo: {data.records_read} linhas, {data.establishments} estabelecimentos, "
              f"{data.rejected_rows} rejeitadas, {data.invalid_cnpj} DV inválido")
        import polars as pl
        est = pl.read_csv(data.files["establishments"], infer_schema=False)
        print(est.select(["cnpj", "nome_fantasia", "situacao_cadastral", "data_inicio_atividade", "uf",
                          "municipio_code", "email"]).head(5))
        emp = pl.read_csv(data.files["companies"], infer_schema=False)
        print(emp.head(3))
        ok = data.establishments > 0
    print("RESULTADO:", "OK" if ok else "FALHOU", date.today())
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
