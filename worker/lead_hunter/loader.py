"""Carga no PostgreSQL (Supabase).

Toda a carga de uma competência acontece numa ÚNICA transação: ou tudo entra
(e a competência vira a vigente), ou nada muda e a importação anterior continua
valendo. Os upserts tornam a reexecução idempotente.
"""
from __future__ import annotations

import csv
import logging
from datetime import date
from pathlib import Path

import psycopg

from .transform import PreparedData

log = logging.getLogger(__name__)

STAGING = {
    "cnae_catalog": "code text, description text",
    "municipalities": "code text, description text",
    "legal_natures": "code text, description text",
    "companies": ("cnpj_basico text, razao_social text, natureza_juridica text, capital_social numeric, "
                  "porte text, ente_federativo text, source_competence text"),
    "establishments": (
        "cnpj text, cnpj_basico text, cnpj_ordem text, cnpj_dv text, identificador_matriz smallint, "
        "nome_fantasia text, situacao_cadastral text, data_situacao_cadastral date, motivo_situacao text, "
        "data_inicio_atividade date, cnae_principal text, cnaes_secundarios text[], tipo_logradouro text, "
        "logradouro text, numero text, complemento text, bairro text, cep text, uf text, municipio_code text, "
        "ddd1 text, telefone1 text, ddd2 text, telefone2 text, email text, situacao_especial text, "
        "data_situacao_especial date, source_competence text"),
    "company_simple_status": (
        "cnpj_basico text, opcao_simples boolean, data_opcao_simples date, data_exclusao_simples date, "
        "opcao_mei boolean, data_opcao_mei date, data_exclusao_mei date, source_competence text"),
}

EST_UPDATE_COLS = [
    "identificador_matriz", "nome_fantasia", "situacao_cadastral", "data_situacao_cadastral", "motivo_situacao",
    "data_inicio_atividade", "cnae_principal", "cnaes_secundarios", "tipo_logradouro", "logradouro", "numero",
    "complemento", "bairro", "cep", "uf", "municipio_code", "ddd1", "telefone1", "ddd2", "telefone2", "email",
    "situacao_especial", "data_situacao_especial",
]
EMP_UPDATE_COLS = ["razao_social", "natureza_juridica", "capital_social", "porte", "ente_federativo"]
SIM_UPDATE_COLS = ["opcao_simples", "data_opcao_simples", "data_exclusao_simples", "opcao_mei",
                   "data_opcao_mei", "data_exclusao_mei"]


def export_existing_cnpjs(conn: psycopg.Connection, dest: Path) -> int:
    """Grava os CNPJs já presentes na base operacional (para atualizar a situação cadastral)."""
    n = 0
    with open(dest, "w", newline="") as fh, conn.cursor() as cur:
        fh.write("cnpj\n")
        with cur.copy("COPY (SELECT cnpj FROM public.establishments) TO STDOUT") as cp:
            for chunk in cp:
                data = bytes(chunk)
                n += data.count(b"\n")
                fh.write(data.decode())
    return n


def _copy_csv(cur: psycopg.Cursor, table: str, path: Path) -> int:
    with open(path, newline="", encoding="utf-8") as fh:
        header = next(csv.reader(fh))
    cols = ", ".join(header)
    with open(path, "rb") as fh, cur.copy(
        f"COPY {table} ({cols}) FROM STDIN WITH (FORMAT csv, HEADER true, NULL '')"
    ) as cp:
        while data := fh.read(8 * 1024 * 1024):
            cp.write(data)
    return cur.rowcount


def _changed(cols: list[str], target: str = "t") -> str:
    left = ", ".join(f"{target}.{c}" for c in cols)
    right = ", ".join(f"excluded.{c}" for c in cols)
    return f"({left}) IS DISTINCT FROM ({right})"


def load(conn: psycopg.Connection, data: PreparedData, job_id: str, competence: str,
         ref_date: date | None, include_branches: bool) -> dict:
    """Executa a carga completa numa transação. Retorna estatísticas."""
    stats: dict[str, int] = {}
    with conn.transaction(), conn.cursor() as cur:
        cur.execute("SET LOCAL app.bulk_load = 'on'")
        cur.execute("SET LOCAL statement_timeout = 0")
        cur.execute("SET LOCAL lock_timeout = '60s'")

        for table, cols in STAGING.items():
            cur.execute(f"CREATE TEMP TABLE stg_{table} ({cols}) ON COMMIT DROP")
            _copy_csv(cur, f"stg_{table}", data.files[table])

        # ---- referências ----
        cur.execute("""
            INSERT INTO public.cnae_catalog AS t (code, description)
            SELECT code, description FROM stg_cnae_catalog
            ON CONFLICT (code) DO UPDATE SET description = excluded.description, updated_at = now()
            WHERE t.description IS DISTINCT FROM excluded.description""")
        cur.execute("""
            INSERT INTO public.municipalities AS t (code, name)
            SELECT code, description FROM stg_municipalities
            ON CONFLICT (code) DO UPDATE SET name = excluded.name, updated_at = now()
            WHERE t.name IS DISTINCT FROM excluded.name""")
        cur.execute("""
            INSERT INTO public.legal_natures AS t (code, description)
            SELECT code, description FROM stg_legal_natures
            ON CONFLICT (code) DO UPDATE SET description = excluded.description, updated_at = now()
            WHERE t.description IS DISTINCT FROM excluded.description""")
        # códigos usados nos arquivos mas ausentes nas tabelas de referência
        cur.execute("""
            INSERT INTO public.cnae_catalog (code, description)
            SELECT DISTINCT c, '(código sem descrição na tabela oficial)'
              FROM (SELECT cnae_principal AS c FROM stg_establishments
                    UNION SELECT unnest(cnaes_secundarios) FROM stg_establishments) x
             WHERE c ~ '^[0-9]{7}$'
            ON CONFLICT DO NOTHING""")
        cur.execute("""
            INSERT INTO public.municipalities (code, name)
            SELECT DISTINCT municipio_code, '(município ' || municipio_code || ')'
              FROM stg_establishments WHERE municipio_code IS NOT NULL
            ON CONFLICT DO NOTHING""")
        cur.execute("""
            INSERT INTO public.legal_natures (code, description)
            SELECT DISTINCT natureza_juridica, '(natureza sem descrição na tabela oficial)'
              FROM stg_companies WHERE natureza_juridica ~ '^[0-9]{4}$'
            ON CONFLICT DO NOTHING""")

        # ---- empresas ----
        cur.execute(f"""
            INSERT INTO public.companies AS t (cnpj_basico, {', '.join(EMP_UPDATE_COLS)}, source_competence)
            SELECT cnpj_basico, razao_social,
                   CASE WHEN natureza_juridica ~ '^[0-9]{{4}}$' THEN natureza_juridica END,
                   capital_social, porte, ente_federativo, source_competence
              FROM stg_companies WHERE cnpj_basico ~ '^[0-9A-Z]{{8}}$'
            ON CONFLICT (cnpj_basico) DO UPDATE SET
              {', '.join(f'{c} = excluded.{c}' for c in EMP_UPDATE_COLS)},
              source_competence = excluded.source_competence
            WHERE {_changed(EMP_UPDATE_COLS)}
            RETURNING (xmax = 0) AS inserted""")
        rows = cur.fetchall()
        stats["companies_inserted"] = sum(1 for r in rows if r[0])
        stats["companies_updated"] = len(rows) - stats["companies_inserted"]

        # ---- estabelecimentos ----
        cur.execute(f"""
            INSERT INTO public.establishments AS t (cnpj, cnpj_basico, cnpj_ordem, cnpj_dv, {', '.join(EST_UPDATE_COLS)}, source_competence)
            SELECT s.cnpj, s.cnpj_basico, s.cnpj_ordem, s.cnpj_dv, {', '.join('s.' + c for c in EST_UPDATE_COLS)}, s.source_competence
              FROM stg_establishments s
              JOIN public.companies c ON c.cnpj_basico = s.cnpj_basico
             WHERE s.cnpj ~ '^[0-9A-Z]{{12}}[0-9]{{2}}$' AND s.cnpj_ordem ~ '^[0-9A-Z]{{4}}$'
            ON CONFLICT (cnpj) DO UPDATE SET
              {', '.join(f'{c} = excluded.{c}' for c in EST_UPDATE_COLS)},
              source_competence = excluded.source_competence
            WHERE {_changed(EST_UPDATE_COLS)}
            RETURNING (xmax = 0) AS inserted""")
        rows = cur.fetchall()
        stats["establishments_inserted"] = sum(1 for r in rows if r[0])
        stats["establishments_updated"] = len(rows) - stats["establishments_inserted"]

        # ---- Simples / MEI ----
        cur.execute(f"""
            INSERT INTO public.company_simple_status AS t (cnpj_basico, {', '.join(SIM_UPDATE_COLS)}, source_competence)
            SELECT s.cnpj_basico, {', '.join('s.' + c for c in SIM_UPDATE_COLS)}, s.source_competence
              FROM stg_company_simple_status s
              JOIN public.companies c ON c.cnpj_basico = s.cnpj_basico
            ON CONFLICT (cnpj_basico) DO UPDATE SET
              {', '.join(f'{c} = excluded.{c}' for c in SIM_UPDATE_COLS)},
              source_competence = excluded.source_competence, updated_at = now()
            WHERE {_changed(SIM_UPDATE_COLS)}""")
        stats["simples_upserted"] = cur.rowcount

        # UF do município (a tabela oficial de municípios não traz UF)
        cur.execute("""
            UPDATE public.municipalities m SET uf = x.uf, updated_at = now()
              FROM (SELECT municipio_code, mode() WITHIN GROUP (ORDER BY uf) AS uf
                      FROM stg_establishments WHERE uf IS NOT NULL AND uf <> 'EX'
                     GROUP BY municipio_code) x
             WHERE m.code = x.municipio_code AND m.uf IS DISTINCT FROM x.uf""")

        # ---- leads, pontuação e recomendações ----
        cur.execute("SELECT public.worker_create_leads(%s, %s, %s, %s)",
                    (job_id, data.window_from, data.window_to, include_branches))
        stats["new_leads"] = cur.fetchone()[0]
        cur.execute("SELECT public.recalculate_lead_scores(NULL, NULL, %s)", (ref_date or date.today(),))
        stats["scores_updated"] = cur.fetchone()[0]
        cur.execute("SELECT public.rebuild_lead_recommendations(NULL, %s)", (job_id,))
        stats["recommendations"] = cur.fetchone()[0]

        # ---- troca da competência vigente (só aqui, no fim da transação) ----
        cur.execute("UPDATE public.import_jobs SET is_current = false WHERE is_current AND id <> %s", (job_id,))
        cur.execute("""
            UPDATE public.import_jobs
               SET status = 'concluido', is_current = true, finished_at = now(),
                   new_leads = %s, updated_records = %s
             WHERE id = %s""",
                    (stats["new_leads"],
                     stats["companies_updated"] + stats["establishments_updated"] + stats["simples_upserted"],
                     job_id))
    return stats
