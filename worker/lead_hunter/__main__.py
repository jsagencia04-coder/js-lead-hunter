"""CLI do worker.

    python -m lead_hunter run                 # laço contínuo (produção)
    python -m lead_hunter check               # mostra a competência mais recente na fonte
    python -m lead_hunter import [AAAA-MM]    # importa agora (sem esperar a interface)
"""
from __future__ import annotations

import argparse
import logging
import sys

from .config import Settings
from .jobs import Worker
from .rf_source import RFSource, reference_date


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="lead_hunter", description="Worker de importação do JS Lead Hunter")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("run", help="laço contínuo: atende a interface e verifica novas competências")
    sub.add_parser("check", help="lista a competência mais recente disponível")
    imp = sub.add_parser("import", help="importa uma competência imediatamente")
    imp.add_argument("competence", nargs="?", help="AAAA-MM (padrão: mais recente completa)")
    args = p.parse_args(argv)

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")

    if args.cmd == "check":
        import os

        from .config import load_env_file

        load_env_file()
        os.environ.setdefault("DATABASE_URL", "postgresql://nao-usado")
        src = RFSource(Settings.from_env())
        try:
            found = src.latest_complete_competence()
        except Exception as exc:  # noqa: BLE001
            print(f"Não foi possível consultar a fonte da Receita: {exc}")
            print("Verifique a internet do servidor, RF_BASE_URL e RF_SHARE_TOKEN (ou use RF_MODE=local).")
            return 2
        if not found:
            print("Nenhuma competência completa encontrada.")
            return 1
        comp, files = found
        total = sum(f.size or 0 for f in files)
        print(f"Competência: {comp} | referência: {reference_date(files)} | {len(files)} arquivos | {total / 1e9:.1f} GB")
        return 0

    worker = Worker(Settings.from_env())
    try:
        if args.cmd == "run":
            worker.loop()
        elif args.cmd == "import":
            job_id = worker.enqueue("importacao", "manual", args.competence)
            job = worker.claim()
            if not job or str(job["id"]) != job_id:
                print("Há outro job pendente na fila; ele será executado primeiro pelo laço do worker.")
                return 1
            worker.run_job(job)
            status = worker.state.execute("SELECT status FROM public.import_jobs WHERE id = %s", (job_id,)).fetchone()
            print(f"Job {job_id}: {status['status']}")
            return 0 if status["status"] == "concluido" else 2
    finally:
        worker.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
