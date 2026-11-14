"""Configuração por variáveis de ambiente."""
from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


def load_env_file(path: Path | None = None) -> None:
    """Carrega um arquivo .env simples (CHAVE=valor) sem sobrescrever variáveis já definidas.

    Procura, nesta ordem: o caminho informado, ./.env e worker/.env.
    """
    candidates = [path] if path else [Path.cwd() / ".env", Path(__file__).resolve().parents[1] / ".env"]
    for p in candidates:
        if p and p.is_file():
            for raw in p.read_text(encoding="utf-8-sig").splitlines():
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                value = value.split(" #", 1)[0].strip().strip('"').strip("'")
                os.environ.setdefault(key.strip(), value)
            return


def _bool(name: str, default: bool) -> bool:
    v = os.getenv(name)
    if v is None or v == "":
        return default
    return v.strip().lower() in {"1", "true", "sim", "yes", "on"}


def _int(name: str, default: int) -> int:
    v = os.getenv(name)
    return int(v) if v not in (None, "") else default


@dataclass(frozen=True)
class Settings:
    # Conexão direta ou "session pooler" do Supabase (porta 5432).
    # O modo "transaction pooler" (6543) NÃO serve: a carga usa COPY e tabelas temporárias.
    database_url: str
    # Fonte oficial: compartilhamento público Nextcloud da Receita, acessado por WebDAV
    rf_mode: str = "webdav"  # "webdav" | "html" (listagem HTML legada/espelho) | "local"
    rf_base_url: str = "https://arquivos.receitafederal.gov.br/public.php/webdav"
    rf_share_token: str = "YggdBLfdninEJX9"
    rf_local_dir: str | None = None  # modo "local": pasta com subpastas AAAA-MM/ contendo os ZIPs
    data_dir: Path = Path("/data")
    lead_window_days: int = 90
    include_branches: bool = False
    download_connections: int = 8
    chunk_mb: int = 8
    http_timeout: int = 120
    poll_seconds: int = 30
    check_interval_hours: int = 12
    auto_import: bool = True
    keep_local_zips: bool = False
    duckdb_memory: str = "2GB"
    duckdb_threads: int = 4
    s3_endpoint: str | None = None
    s3_bucket: str | None = None
    s3_access_key: str | None = None
    s3_secret_key: str | None = None
    s3_region: str = "auto"

    @property
    def s3_enabled(self) -> bool:
        return bool(self.s3_bucket and self.s3_access_key and self.s3_secret_key)

    @classmethod
    def from_env(cls) -> "Settings":
        load_env_file()
        url = os.getenv("DATABASE_URL")
        if not url:
            raise SystemExit("DATABASE_URL não definida. Veja worker/.env.example.")
        return cls(
            database_url=url,
            rf_mode=os.getenv("RF_MODE", "webdav"),
            rf_base_url=os.getenv("RF_BASE_URL", cls.rf_base_url).rstrip("/"),
            rf_share_token=os.getenv("RF_SHARE_TOKEN", cls.rf_share_token),
            rf_local_dir=os.getenv("RF_LOCAL_DIR") or None,
            data_dir=Path(os.getenv("DATA_DIR") or (Path(__file__).resolve().parents[1] / "data")),
            lead_window_days=_int("LEAD_WINDOW_DAYS", 90),
            include_branches=_bool("INCLUDE_BRANCHES", False),
            download_connections=_int("DOWNLOAD_CONNECTIONS", 8),
            chunk_mb=_int("DOWNLOAD_CHUNK_MB", 8),
            http_timeout=_int("HTTP_TIMEOUT", 120),
            poll_seconds=_int("POLL_SECONDS", 30),
            check_interval_hours=_int("CHECK_INTERVAL_HOURS", 12),
            auto_import=_bool("AUTO_IMPORT", True),
            keep_local_zips=_bool("KEEP_LOCAL_ZIPS", False),
            duckdb_memory=os.getenv("DUCKDB_MEMORY", "2GB"),
            duckdb_threads=_int("DUCKDB_THREADS", 4),
            s3_endpoint=os.getenv("S3_ENDPOINT") or None,
            s3_bucket=os.getenv("S3_BUCKET") or None,
            s3_access_key=os.getenv("S3_ACCESS_KEY_ID") or None,
            s3_secret_key=os.getenv("S3_SECRET_ACCESS_KEY") or None,
            s3_region=os.getenv("S3_REGION", "auto"),
        )
