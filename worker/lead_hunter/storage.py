"""Armazenamento temporário opcional dos ZIPs em Cloudflare R2 ou S3.

Serve como cópia de segurança da competência: se o servidor da Receita ficar
lento ou indisponível, um reprocessamento usa a cópia do bucket.
Sem as variáveis S3_*, tudo funciona só com o disco local.
"""
from __future__ import annotations

import logging
from pathlib import Path

from .config import Settings

log = logging.getLogger(__name__)


class Storage:
    def __init__(self, settings: Settings):
        self.s = settings
        self.client = None
        if settings.s3_enabled:
            import boto3

            self.client = boto3.client(
                "s3",
                endpoint_url=settings.s3_endpoint,
                aws_access_key_id=settings.s3_access_key,
                aws_secret_access_key=settings.s3_secret_key,
                region_name=settings.s3_region,
            )

    def _key(self, competence: str, name: str) -> str:
        return f"cnpj/{competence}/{name}"

    def backup(self, competence: str, path: Path) -> None:
        if not self.client:
            return
        try:
            self.client.upload_file(str(path), self.s.s3_bucket, self._key(competence, path.name))
        except Exception:  # noqa: BLE001 — backup não pode derrubar a importação
            log.exception("Falha ao copiar %s para o bucket", path.name)

    def restore(self, competence: str, rf, dest_dir: Path) -> Path | None:
        """Baixa do bucket se lá houver cópia com o mesmo tamanho."""
        if not self.client:
            return None
        key = self._key(competence, rf.name)
        try:
            head = self.client.head_object(Bucket=self.s.s3_bucket, Key=key)
        except Exception:  # noqa: BLE001
            return None
        if rf.size and head.get("ContentLength") != rf.size:
            return None
        dest_dir.mkdir(parents=True, exist_ok=True)
        out = dest_dir / rf.name
        if out.exists() and out.stat().st_size == head.get("ContentLength"):
            return out
        self.client.download_file(self.s.s3_bucket, key, str(out))
        return out
