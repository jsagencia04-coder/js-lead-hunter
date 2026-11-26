"""Recálculo em lotes de pontuação, recomendações e resumo (lead_insights).

Usado quando uma migration muda as regras (ex.: pontuação 2.0) e deixa a
pendência `recalculo_pendente` em app_settings. Cada lote é uma transação curta
(sem estourar o tempo limite do Supabase); entre lotes o VACUUM devolve o espaço
das versões antigas das linhas para reutilização, para o banco não crescer.
Retomável: o último id processado fica gravado na própria pendência.
"""
from __future__ import annotations

import json
import logging
import time

import psycopg

log = logging.getLogger(__name__)

BATCH = 2000
VACUUM_EVERY = 1
TABLES = ("leads", "lead_recommendations", "lead_insights")


def _vacuum(database_url: str) -> None:
    with psycopg.connect(database_url, autocommit=True) as c:
        c.execute("set statement_timeout = 0")
        for t in TABLES:
            if c.execute("select to_regclass(%s) is not null", (f"public.{t}",)).fetchone()[0]:
                c.execute(f"vacuum (analyze) public.{t}")


def run_pending(database_url: str, *, db_size_limit_mb: int = 0, deadline: float | None = None,
                batch: int = BATCH) -> dict | None:
    """Processa a pendência de recálculo, se houver. Retorna estatísticas ou None."""
    with psycopg.connect(database_url, autocommit=True, application_name="js-lead-hunter-recalc") as c:
        row = c.execute("select value from public.app_settings where key = 'recalculo_pendente'").fetchone()
        if not row:
            return None
        state = row[0] or {}
        last = state.get("ultimo_id")
        total = c.execute("select count(*) from public.leads").fetchone()[0]
        done = int(state.get("processados") or 0)
        log.info("Recálculo pendente (%s): %d de %d leads já processados", state.get("motivo"), done, total)
        batches = 0
        finished = False
        while True:
            if deadline and time.monotonic() > deadline:
                break
            if db_size_limit_mb:
                size = c.execute("select pg_database_size(current_database())").fetchone()[0]
                # o recálculo reduz as recomendações (máx. 5 por lead) e compacta no fim;
                # só para se o banco passar bem do limite do plano
                if size > db_size_limit_mb * 1024 * 1024 * 1.2:
                    log.warning("Recálculo pausado: banco com %.0f MB (limite %d MB). Nada foi apagado.",
                                size / 1e6, db_size_limit_mb)
                    _vacuum(database_url)
                    break
            ids = [r[0] for r in c.execute(
                "select id from public.leads where (%s::uuid is null or id > %s::uuid) order by id limit %s",
                (last, last, batch)).fetchall()]
            if not ids:
                finished = True
                break
            with c.transaction():
                c.execute("set local statement_timeout = 0")
                c.execute("set local app.bulk_load = 'on'")
                c.execute("select public.recalculate_lead_scores(%s::uuid[], null, public.current_reference_date())", (ids,))
                c.execute("select public.rebuild_lead_recommendations(%s::uuid[])", (ids,))
                last = str(ids[-1])
                done += len(ids)
                c.execute("""update public.app_settings
                                set value = value || %s::jsonb, updated_at = now() where key = 'recalculo_pendente'""",
                          (json.dumps({"ultimo_id": last, "processados": done, "total": total}),))
            batches += 1
            if batches % VACUUM_EVERY == 0:
                _vacuum(database_url)
                log.info("Recálculo: %d de %d leads", done, total)
        if finished:
            c.execute("delete from public.app_settings where key = 'recalculo_pendente'")
            log.info("Recálculo concluído: %d leads", done)
            c.execute("set statement_timeout = 0")
            for t in TABLES:
                if c.execute("select to_regclass(%s) is not null", (f"public.{t}",)).fetchone()[0]:
                    c.execute(f"vacuum (full, analyze) public.{t}")
        else:
            _vacuum(database_url)
        return {"processados": done, "total": total, "concluido": finished}


COMPACT_TABLES = ("leads", "lead_recommendations", "lead_events", "establishments", "companies", "digital_channels",
                  "lead_archive", "audit_logs", "lead_insights", "enrichment_queue", "registry_changes")


def table_sizes(c) -> list[tuple[str, int, int, int]]:
    """(tabela, MB totais, linhas vivas, linhas mortas) das maiores tabelas — só totais, sem dados."""
    return [(r[0], int(r[1]), int(r[2] or 0), int(r[3] or 0)) for r in c.execute(
        """select s.relname, round(pg_total_relation_size(s.relid) / 1048576.0), s.n_live_tup, s.n_dead_tup
             from pg_stat_user_tables s where s.schemaname = 'public'
            order by pg_total_relation_size(s.relid) desc limit 12""").fetchall()]


def compact_if_needed(database_url: str, db_size_limit_mb: int) -> dict | None:
    """Compacta (VACUUM FULL) as tabelas com espaço morto quando o banco passa de 90% do limite.

    Não remove nenhum registro: só devolve ao disco o espaço de versões antigas das linhas
    (ex.: transação desfeita por tempo limite). Cada tabela fica bloqueada por alguns segundos.
    """
    if not db_size_limit_mb:
        return None
    with psycopg.connect(database_url, autocommit=True, application_name="js-lead-hunter-compact") as c:
        c.execute("set statement_timeout = 0")
        before = c.execute("select pg_database_size(current_database())").fetchone()[0]
        if before < db_size_limit_mb * 1024 * 1024 * 0.9:
            return None
        sizes = table_sizes(c)
        log.info("Banco com %.0f MB (limite %d MB). Maiores tabelas (MB, vivas, mortas): %s", before / 1e6,
                 db_size_limit_mb, "; ".join(f"{t} {mb} MB {live}/{dead}" for t, mb, live, dead in sizes))
        c.execute("vacuum (analyze)")  # registra as linhas mortas atuais em todas as tabelas
        done = []
        for t in COMPACT_TABLES:
            if not c.execute("select to_regclass(%s) is not null", (f"public.{t}",)).fetchone()[0]:
                continue
            c.execute("set lock_timeout = '30s'")
            try:
                c.execute(f"vacuum (full, analyze) public.{t}")
                done.append(t)
            except psycopg.errors.LockNotAvailable:
                log.warning("Compactação de %s adiada: tabela em uso", t)
        after = c.execute("select pg_database_size(current_database())").fetchone()[0]
        log.info("Compactação: %.0f MB -> %.0f MB (%s). Nenhum registro removido.", before / 1e6, after / 1e6, ", ".join(done))
        return {"antes_mb": round(before / 1e6), "depois_mb": round(after / 1e6), "tabelas": done}
