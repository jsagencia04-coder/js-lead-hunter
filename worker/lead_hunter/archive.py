"""Arquivamento de leads sem contato e compactação do banco.

Regras na função SQL public.archive_stale_leads; parâmetros em
public.app_settings (chave 'arquivamento'), editáveis pelo administrador.
"""
from __future__ import annotations

import json
import logging

import psycopg

log = logging.getLogger(__name__)

TABLES_TO_COMPACT = ["lead_events", "lead_recommendations", "leads", "establishments",
                     "company_simple_status", "companies"]


def load_settings(conn: psycopg.Connection) -> dict:
    row = conn.execute("select value from public.app_settings where key = 'arquivamento'").fetchone()
    defaults = {"ativo": True, "dias": 30, "dias_alta": 60, "liberar_espaco_na_importacao": True}
    return {**defaults, **(row[0] if row else {})}


def _archive(database_url: str, dias: int, dias_alta: int, motivo: str,
             somente_anteriores: bool, incluir_alta: bool) -> dict:
    with psycopg.connect(database_url) as c:
        res = c.execute("select public.archive_stale_leads(%s, %s, %s, %s, %s)",
                        (dias, dias_alta, motivo, somente_anteriores, incluir_alta)).fetchone()[0]
    if res.get("leads"):
        compact(database_url)
    return res


def compact(database_url: str) -> None:
    """VACUUM FULL devolve o espaço ao plano do banco (o DELETE sozinho não reduz o tamanho)."""
    with psycopg.connect(database_url, autocommit=True) as c:
        for t in TABLES_TO_COMPACT:
            c.execute(f"vacuum (full, analyze) public.{t}")


def run_scheduled(database_url: str) -> dict | None:
    """Rotina diária: arquiva leads intocados mais velhos que os dias configurados."""
    with psycopg.connect(database_url, autocommit=True) as c:
        cfg = load_settings(c)
        last = c.execute("""select (value ->> 'ultima_execucao')::timestamptz > now() - interval '20 hours'
                              from public.app_settings where key = 'arquivamento'""").fetchone()
    if not cfg["ativo"] or (last and last[0]):
        return None
    res = _archive(database_url, int(cfg["dias"]), int(cfg["dias_alta"]),
                   f"sem contato após {cfg['dias']} dias", False, True)
    with psycopg.connect(database_url, autocommit=True) as c:
        c.execute("""update public.app_settings
                        set value = value || jsonb_build_object('ultima_execucao', now(), 'ultimo_resultado', %s::jsonb)
                      where key = 'arquivamento'""", (json.dumps(res),))
    log.info("Arquivamento diário: %s", res)
    return res


def free_space_for_import(database_url: str) -> dict | None:
    """Antes de gravar uma competência nova sem espaço: arquiva leads intocados já existentes
    (exceto alta prioridade), qualquer que seja a idade. Os leads da competência nova
    ainda não foram gravados neste momento, então todos os atuais são de importações anteriores."""
    with psycopg.connect(database_url, autocommit=True) as c:
        cfg = load_settings(c)
    if not cfg["ativo"] or not cfg["liberar_espaco_na_importacao"]:
        return None
    res = _archive(database_url, 0, 1_000_000, "liberar espaço para nova competência", False, False)
    log.info("Arquivamento para liberar espaço: %s", res)
    return res
