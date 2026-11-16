"""Ciclo de vida dos jobs de importação e comunicação de estado com a interface."""
from __future__ import annotations

import json
import logging
import shutil
import socket
import time
from datetime import datetime, timezone
from pathlib import Path

import psycopg
from psycopg.rows import dict_row

from . import __version__
from .config import Settings
from .layout import REQUIRED_FILES
from .loader import export_existing_cnpjs, load
from .rf_source import BudgetExceeded, RFSource, reference_date
from .storage import Storage
from .transform import prepare

log = logging.getLogger(__name__)

ACTIVE = ("baixando", "processando", "validando")


class JobFailed(RuntimeError):
    pass


class Worker:
    def __init__(self, settings: Settings):
        self.s = settings
        self.state = psycopg.connect(settings.database_url, autocommit=True, row_factory=dict_row,
                                     application_name="js-lead-hunter-worker")
        self.source = RFSource(settings)
        self.storage = Storage(settings)
        self.last_check = 0.0
        self.deadline: float | None = None
        if settings.max_runtime_minutes:
            # reserva 60 min para processar e gravar depois do último download
            self.deadline = time.monotonic() + max(5, settings.max_runtime_minutes - 60) * 60

    def close(self):
        self.source.close()
        self.state.close()

    # ------------------------------------------------------------ estado
    def heartbeat(self, extra: dict | None = None):
        details = {"versao": __version__, "host": socket.gethostname(), "fonte": self.s.rf_mode,
                   "janela_dias": self.s.lead_window_days, "modo": self.s.worker_mode,
                   "intervalo_min": self.s.worker_interval_min, **(extra or {})}
        self.state.execute(
            """UPDATE public.integration_status
                  SET status = 'ativo', last_seen_at = now(), details = details || %s::jsonb, updated_at = now()
                WHERE key = 'worker'""", (json.dumps(details),))
        storage_status = "ativo" if self.s.s3_enabled else "nao_configurado"
        self.state.execute(
            "UPDATE public.integration_status SET status = %s, updated_at = now() WHERE key = 'storage' AND status <> %s",
            (storage_status, storage_status))

    def _log(self, job_id: str, msg: str, level: str = "info"):
        {"erro": log.error, "aviso": log.warning}.get(level, log.info)(msg)
        entry = json.dumps([{"em": datetime.now(timezone.utc).isoformat(), "nivel": level, "msg": msg}])
        # mantém só as últimas 300 entradas
        self.state.execute(
            """UPDATE public.import_jobs
                  SET log = (SELECT coalesce(jsonb_agg(e), '[]'::jsonb) FROM (
                               SELECT e FROM jsonb_array_elements(log || %s::jsonb) WITH ORDINALITY AS x(e, i)
                               ORDER BY i DESC LIMIT 300) y)
                WHERE id = %s""", (entry, job_id))

    def _update(self, job_id: str, **fields):
        sets = ", ".join(f"{k} = %s" for k in fields)
        self.state.execute(f"UPDATE public.import_jobs SET {sets} WHERE id = %s", (*fields.values(), job_id))

    def recover_stale_jobs(self, resume: bool = False):
        """Jobs que ficaram 'em execução' por queda do worker.

        resume=True (modo agendado): voltam para 'pendente' e continuam na próxima execução.
        resume=False: são marcados como falha.
        """
        if resume:
            rows = self.state.execute(
                """UPDATE public.import_jobs SET status = 'pendente',
                          log = log || '[{"nivel": "aviso", "msg": "Execução anterior interrompida; retomando"}]'::jsonb
                    WHERE status IN ('baixando', 'processando', 'validando') RETURNING id""").fetchall()
        else:
            rows = self.state.execute(
                """UPDATE public.import_jobs SET status = 'falhou', finished_at = now(),
                          error_count = error_count + 1,
                          errors = errors || '[{"msg": "Worker reiniciado durante a execução"}]'::jsonb
                    WHERE status IN ('baixando', 'processando', 'validando') RETURNING id""").fetchall()
        for r in rows:
            log.warning("Job %s interrompido anteriormente (%s)", r["id"], "retomado" if resume else "falhou")

    def claim(self) -> dict | None:
        return self.state.execute(
            """UPDATE public.import_jobs SET status = 'processando', started_at = now()
                WHERE id = (SELECT id FROM public.import_jobs WHERE status = 'pendente'
                             ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 1)
            RETURNING *""").fetchone()

    def current_competence(self) -> str | None:
        r = self.state.execute("SELECT competence FROM public.import_jobs WHERE is_current").fetchone()
        return r["competence"] if r else None

    def enqueue(self, job_type: str, trigger: str = "agendado", competence: str | None = None) -> str:
        r = self.state.execute(
            """INSERT INTO public.import_jobs (job_type, status, trigger_type, competence)
               VALUES (%s, 'pendente', %s, %s) RETURNING id""", (job_type, trigger, competence)).fetchone()
        return str(r["id"])

    # ------------------------------------------------------------ execução
    def run_job(self, job: dict):
        job_id = str(job["id"])
        try:
            if job["job_type"] == "verificacao":
                self._run_check(job_id)
            else:
                self._run_import(job_id, job.get("competence"))
        except BudgetExceeded as exc:
            self._update(job_id, status="pendente")
            self._log(job_id, f"{exc}. Continua na próxima execução.", "aviso")
        except Exception as exc:  # noqa: BLE001 — qualquer falha precisa ficar registrada no job
            log.exception("Job %s falhou", job_id)
            self.state.execute(
                """UPDATE public.import_jobs SET status = 'falhou', finished_at = now(),
                          error_count = error_count + 1, errors = errors || %s::jsonb
                    WHERE id = %s""",
                (json.dumps([{"em": datetime.now(timezone.utc).isoformat(), "msg": str(exc)[:2000]}]), job_id))
            self._log(job_id, f"Falha: {exc}", "erro")

    def _run_check(self, job_id: str):
        self._log(job_id, "Consultando competências publicadas pela Receita Federal")
        found = self.source.latest_complete_competence()
        current = self.current_competence()
        if not found:
            self._update(job_id, status="concluido", finished_at=datetime.now(timezone.utc),
                         metadata=json.dumps({"nova_competencia": False, "vigente": current,
                                              "mensagem": "Nenhuma competência completa encontrada na fonte"}))
            return
        comp, files = found
        is_new = current is None or comp > current
        ref = reference_date(files)
        self._update(job_id, status="concluido", finished_at=datetime.now(timezone.utc), competence=comp,
                     reference_date=ref, files_found=len(files),
                     metadata=json.dumps({"nova_competencia": is_new, "vigente": current,
                                          "tamanho_total_mb": round(sum(f.size or 0 for f in files) / 1e6)}))
        self._log(job_id, f"Competência mais recente: {comp} ({'nova' if is_new else 'já importada'})")
        self.heartbeat({"competencia_disponivel": comp})

    def _run_import(self, job_id: str, competence: str | None):
        t0 = time.monotonic()
        # 1. Descobre a competência e os arquivos
        if competence:
            files = [f for f in self.source.list_files(competence) if f.name in REQUIRED_FILES]
            missing = sorted(set(REQUIRED_FILES) - {f.name for f in files})
            if missing:
                raise JobFailed(f"Competência {competence} incompleta na fonte; faltam: {', '.join(missing)}")
        else:
            found = self.source.latest_complete_competence()
            if not found:
                raise JobFailed("Nenhuma competência completa encontrada na fonte")
            competence, files = found
        ref = reference_date(files) or datetime.now().date()
        self._update(job_id, competence=competence, reference_date=ref, files_found=len(files),
                     status="baixando")
        self._log(job_id, f"Importando competência {competence} (referência {ref:%d/%m/%Y}), {len(files)} arquivos")

        # 2. Espaço em disco: baixa e processa UM arquivo por vez, apagando o ZIP depois de lido
        comp_dir = self.s.data_dir / "zips" / competence
        work = self.s.data_dir / "work" / competence
        shutil.rmtree(work, ignore_errors=True)
        work.mkdir(parents=True)
        by_name = {f.name: f for f in files}
        largest = max((f.size or 0) for f in files)
        need = largest + 2 * 1024 ** 3  # maior ZIP + blocos temporários e base de trabalho
        free = shutil.disk_usage(work).free
        if free < need:
            raise JobFailed(f"Espaço em disco insuficiente em {self.s.data_dir}: livres {free / 1e9:.1f} GB, "
                            f"necessários ~{need / 1e9:.1f} GB. Libere espaço ou defina DATA_DIR em outro disco.")
        self._log(job_id, f"Espaço livre: {free / 1e9:.1f} GB (mínimo ~{need / 1e9:.1f} GB)")

        # 3. Processamento
        self._update(job_id, status="processando")
        with psycopg.connect(self.s.database_url) as c:
            n_existing = export_existing_cnpjs(c, work / "existing.csv")
        self._log(job_id, f"{n_existing} estabelecimentos já na base serão atualizados se mudarem")

        processed = {"n": 0}

        def progress(msg: str, inc: int):
            if inc:
                processed["n"] += inc
                self._update(job_id, files_processed=processed["n"])
                self.heartbeat()
            else:
                self._log(job_id, msg)

        def get_zip(name: str) -> Path:
            rf = by_name[name]
            self._update(job_id, status="baixando")
            path = self.storage.restore(competence, rf, comp_dir)
            if not path:
                path = self.source.fetch(competence, rf, comp_dir, progress=lambda m: self._log(job_id, m),
                                         deadline=self.deadline)
                self.storage.backup(competence, path)
            self._update(job_id, status="processando")
            self.heartbeat()
            return path

        total = sum(f.size or 0 for f in files)
        # se sobrar espaço, mantém os ZIPs até o fim (uma nova tentativa não precisa baixar de novo)
        keep_until_end = self.s.keep_local_zips or free > total + 10 * 1024 ** 3

        def release(name: str) -> None:
            if not keep_until_end:
                (comp_dir / name).unlink(missing_ok=True)

        data = prepare(get_zip, work, competence, ref, self.s.lead_window_days, work / "existing.csv",
                       self.s.duckdb_memory, self.s.duckdb_threads, progress, release)
        self._update(job_id, records_read=data.records_read, files_processed=len(files),
                     error_count=data.rejected_rows)
        self._log(job_id, f"{data.records_read} linhas lidas; {data.establishments} estabelecimentos selecionados; "
                          f"{data.rejected_rows} linhas rejeitadas pelo leitor; {data.invalid_cnpj} CNPJs com DV inválido")

        # 4. Validação antes de tocar no banco operacional
        self._update(job_id, status="validando")
        problems = []
        if data.records_read == 0:
            problems.append("nenhuma linha lida")
        if data.establishments == 0:
            problems.append("nenhum estabelecimento dentro da janela")
        if data.records_read and data.rejected_rows / data.records_read > 0.01:
            problems.append(f"{data.rejected_rows} linhas rejeitadas (> 1%)")
        if problems:
            raise JobFailed("Validação reprovou a competência: " + "; ".join(problems) +
                            ". A importação vigente foi mantida.")

        # 5. Carga atômica
        self._log(job_id, "Gravando no banco (transação única)")
        with psycopg.connect(self.s.database_url, application_name="js-lead-hunter-load") as c:
            stats = load(c, data, job_id, competence, ref, self.s.include_branches)
        elapsed = time.monotonic() - t0
        self._update(job_id, metadata=json.dumps({**stats, "segundos": round(elapsed),
                                                  "janela": [str(data.window_from), str(data.window_to)],
                                                  "cnpj_dv_invalido": data.invalid_cnpj}))
        self._log(job_id, f"Concluído em {elapsed / 60:.1f} min: {stats['new_leads']} novos leads, "
                          f"{stats['establishments_inserted']} estabelecimentos novos, "
                          f"{stats['establishments_updated']} atualizados")

        shutil.rmtree(work, ignore_errors=True)
        if not self.s.keep_local_zips:
            shutil.rmtree(comp_dir, ignore_errors=True)

    # ------------------------------------------------------------ laço principal
    def loop(self):
        log.info("Worker iniciado (fonte=%s, janela=%d dias)", self.s.rf_mode, self.s.lead_window_days)
        self.recover_stale_jobs()
        while True:
            try:
                self.heartbeat()
                job = self.claim()
                if job:
                    self.run_job(job)
                    continue
                if time.monotonic() - self.last_check > self.s.check_interval_hours * 3600:
                    self.last_check = time.monotonic()
                    self.scheduled_check()
            except psycopg.OperationalError:
                log.exception("Conexão com o banco perdida; reconectando em 30s")
                time.sleep(30)
                self.state = psycopg.connect(self.s.database_url, autocommit=True, row_factory=dict_row,
                                             application_name="js-lead-hunter-worker")
                continue
            except Exception:  # noqa: BLE001
                log.exception("Erro no laço do worker")
            time.sleep(self.s.poll_seconds)

    def once(self) -> None:
        """Uma rodada (modo agendado): atende pedidos da interface e verifica nova competência."""
        log.info("Rodada do worker (fonte=%s, janela=%d dias, limite=%s min)", self.s.rf_mode,
                 self.s.lead_window_days, self.s.max_runtime_minutes or "sem")
        self.recover_stale_jobs(resume=True)
        self.heartbeat()
        job = self.claim()
        if not job:
            self.scheduled_check()
            job = self.claim()
        while job:
            self.run_job(job)
            self.heartbeat()
            if self.deadline and time.monotonic() > self.deadline:
                break
            job = self.claim()
        self.enrich()
        self.heartbeat()

    def enrich(self) -> None:
        """Verifica a presença digital de um lote de leads (usa o tempo que sobrar da rodada)."""
        if not self.s.enrich_enabled:
            return
        from .enrich import Enricher

        try:
            stats = Enricher(self.s.database_url, batch=self.s.enrich_batch).run(deadline=self.deadline)
        except Exception:  # noqa: BLE001 — o enriquecimento nunca derruba o worker
            log.exception("Falha no enriquecimento de presença digital")
            self.state.execute(
                "UPDATE public.integration_status SET status = 'erro', updated_at = now() WHERE key = 'enriquecimento'")
            return
        log.info("Presença digital: %s", stats)
        self.state.execute(
            """UPDATE public.integration_status
                  SET status = 'ativo', last_seen_at = now(), updated_at = now(),
                      details = details || jsonb_build_object('ultima_rodada', %s::jsonb, 'fonte', 'domínio do e-mail cadastral')
                WHERE key = 'enriquecimento'""", (json.dumps(stats),))

    def scheduled_check(self):
        """Verificação automática: se houver competência nova, enfileira a importação."""
        busy = self.state.execute(
            "SELECT 1 FROM public.import_jobs WHERE status IN ('pendente', 'baixando', 'processando', 'validando')"
        ).fetchone()
        if busy:
            return
        recent = self.state.execute(
            """SELECT 1 FROM public.import_jobs WHERE job_type = 'verificacao' AND trigger_type = 'agendado'
                  AND created_at > now() - make_interval(hours => %s)""", (self.s.check_interval_hours,)).fetchone()
        current = self.current_competence()
        if recent and current:
            return
        job_id = self.enqueue("verificacao")
        job = self.claim()
        if not job:
            return
        self.run_job(job)
        r = self.state.execute("SELECT status, metadata FROM public.import_jobs WHERE id = %s", (job_id,)).fetchone()
        if r and r["status"] == "concluido" and (r["metadata"] or {}).get("nova_competencia") and self.s.auto_import:
            self.enqueue("importacao")
