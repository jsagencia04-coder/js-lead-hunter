"""Acesso aos arquivos oficiais do CNPJ publicados pela Receita Federal.

Desde 2026 a Receita publica os ZIPs num compartilhamento público Nextcloud,
acessível por WebDAV com autenticação Basic (usuário = token do compartilhamento,
senha vazia). Há uma pasta por competência (AAAA-MM). O servidor é lento por
conexão, então o download é feito em partes (HTTP Range), em paralelo e com
retomada.

Modos suportados:
- webdav: fonte oficial (padrão);
- html:   listagem HTML de diretório (endereço legado ou espelho);
- local:  ZIPs já baixados manualmente em RF_LOCAL_DIR/AAAA-MM/.
"""
from __future__ import annotations

import json
import logging
import re
import shutil
import threading
import time
import zipfile
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path
from typing import Callable
from urllib.parse import unquote
from xml.etree import ElementTree as ET

import httpx

from .config import Settings
from .layout import REQUIRED_FILES

log = logging.getLogger(__name__)

COMPETENCE_RE = re.compile(r"^(\d{4})-(\d{2})$")
DAV = "{DAV:}"


@dataclass
class RemoteFile:
    name: str
    size: int | None
    last_modified: datetime | None


class SourceError(RuntimeError):
    pass


class BudgetExceeded(RuntimeError):
    """Tempo da execução esgotado; o download continua de onde parou na próxima vez."""


class RFSource:
    def __init__(self, settings: Settings):
        self.s = settings
        auth = (settings.rf_share_token, "") if settings.rf_mode == "webdav" else None
        self.client = httpx.Client(
            auth=auth,
            timeout=httpx.Timeout(settings.http_timeout, connect=30),
            follow_redirects=True,
            headers={"User-Agent": "JS-Lead-Hunter/0.2 (+dados abertos CNPJ)"},
        )

    def close(self):
        self.client.close()

    # ------------------------------------------------------------------ listagem
    def _url(self, *parts: str) -> str:
        return "/".join([self.s.rf_base_url, *[p.strip("/") for p in parts if p]]) + "/"

    def _propfind(self, url: str) -> list[tuple[str, int | None, datetime | None, bool]]:
        body = (
            '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop>'
            "<d:getcontentlength/><d:getlastmodified/><d:resourcetype/>"
            "</d:prop></d:propfind>"
        )
        r = self.client.request("PROPFIND", url, headers={"Depth": "1", "Content-Type": "application/xml"}, content=body)
        if r.status_code == 401:
            raise SourceError("A Receita recusou o acesso ao compartilhamento (401). Verifique RF_SHARE_TOKEN.")
        if r.status_code == 404:
            raise SourceError(f"Pasta não encontrada na fonte: {url}")
        if r.status_code not in (207, 200) or not r.content.strip():
            raise SourceError(f"Resposta inesperada da fonte ({r.status_code}) em {url}")
        out = []
        root = ET.fromstring(r.content)
        for resp in root.iter(f"{DAV}response"):
            href = unquote(resp.findtext(f"{DAV}href") or "")
            size = resp.findtext(f".//{DAV}getcontentlength")
            lm = resp.findtext(f".//{DAV}getlastmodified")
            is_dir = resp.find(f".//{DAV}resourcetype/{DAV}collection") is not None
            name = href.rstrip("/").rsplit("/", 1)[-1]
            out.append((
                name,
                int(size) if size and size.isdigit() else None,
                parsedate_to_datetime(lm) if lm else None,
                is_dir,
            ))
        return out

    def _html_listing(self, url: str) -> list[tuple[str, int | None, datetime | None, bool]]:
        r = self.client.get(url)
        if r.status_code != 200:
            raise SourceError(f"Listagem indisponível ({r.status_code}) em {url}")
        out = []
        for href in re.findall(r'href="([^"?#]+)"', r.text):
            name = unquote(href).rstrip("/").rsplit("/", 1)[-1]
            if href.endswith("/"):
                out.append((name, None, None, True))
            elif name.lower().endswith(".zip"):
                out.append((name, None, None, False))
        return out

    def _list(self, url: str):
        if self.s.rf_mode == "webdav":
            return self._propfind(url)
        if self.s.rf_mode == "html":
            return self._html_listing(url)
        raise SourceError(f"Modo de fonte desconhecido: {self.s.rf_mode}")

    def list_competences(self) -> list[str]:
        if self.s.rf_mode == "local":
            base = Path(self.s.rf_local_dir or "")
            if not base.is_dir():
                raise SourceError(f"RF_LOCAL_DIR não encontrado: {base}")
            return sorted(p.name for p in base.iterdir() if p.is_dir() and COMPETENCE_RE.match(p.name))
        entries = self._list(self._url())
        return sorted({n for n, _, _, d in entries if d and COMPETENCE_RE.match(n)})

    def list_files(self, competence: str) -> list[RemoteFile]:
        if self.s.rf_mode == "local":
            folder = Path(self.s.rf_local_dir or "") / competence
            return [
                RemoteFile(p.name, p.stat().st_size, datetime.fromtimestamp(p.stat().st_mtime, tz=timezone.utc))
                for p in sorted(folder.glob("*.zip"))
            ]
        entries = self._list(self._url(competence))
        files = [RemoteFile(n, s, lm) for n, s, lm, d in entries if not d and n.lower().endswith(".zip")]
        if self.s.rf_mode == "html":
            for f in files:  # a listagem HTML não traz tamanho: consulta por HEAD
                h = self.client.head(self._url(competence).rstrip("/") + "/" + f.name)
                if h.status_code == 200:
                    f.size = int(h.headers.get("content-length", 0)) or None
                    if h.headers.get("last-modified"):
                        f.last_modified = parsedate_to_datetime(h.headers["last-modified"])
        return files

    def latest_complete_competence(self) -> tuple[str, list[RemoteFile]] | None:
        """Competência mais recente que já contém TODOS os arquivos necessários."""
        for comp in reversed(self.list_competences()):
            files = self.list_files(comp)
            names = {f.name for f in files}
            missing = [n for n in REQUIRED_FILES if n not in names]
            if not missing:
                return comp, [f for f in files if f.name in REQUIRED_FILES]
            log.info("Competência %s ainda incompleta na fonte (faltam %d arquivos)", comp, len(missing))
        return None

    # ------------------------------------------------------------------ download
    def file_url(self, competence: str, name: str) -> str:
        return self._url(competence).rstrip("/") + "/" + name

    def fetch(self, competence: str, rf: RemoteFile, dest_dir: Path,
              progress: Callable[[str], None] | None = None, deadline: float | None = None) -> Path:
        """Baixa (ou reaproveita) um arquivo, com retomada. Retorna o caminho final."""
        dest_dir.mkdir(parents=True, exist_ok=True)
        final = dest_dir / rf.name
        if final.exists() and (rf.size is None or final.stat().st_size == rf.size) and _zip_ok(final):
            return final

        if self.s.rf_mode == "local":
            src = Path(self.s.rf_local_dir or "") / competence / rf.name
            shutil.copyfile(src, final)
            if not _zip_ok(final):
                raise SourceError(f"ZIP corrompido: {src}")
            return final

        url = self.file_url(competence, rf.name)
        size = rf.size or self._probe_size(url)
        part = final.with_suffix(".zip.partial")
        state_file = final.with_suffix(".zip.state")
        chunk = self.s.chunk_mb * 1024 * 1024

        if size and self._supports_range(url):
            n_chunks = (size + chunk - 1) // chunk
            done: set[int] = set()
            if part.exists() and state_file.exists() and part.stat().st_size == size:
                try:
                    st = json.loads(state_file.read_text())
                    if st.get("size") == size:
                        done = set(st.get("done", []))
                except ValueError:
                    pass
            else:
                with open(part, "wb") as fh:
                    fh.truncate(size)
            todo = [i for i in range(n_chunks) if i not in done]
            if progress:
                progress(f"Baixando {rf.name} ({size / 1e6:.0f} MB, {len(todo)} de {n_chunks} partes)")
            fh = open(part, "r+b")
            lock = threading.Lock()
            try:
                pool = ThreadPoolExecutor(max_workers=self.s.download_connections)
                try:
                    futs = {pool.submit(self._get_range, url, i * chunk, min(size, (i + 1) * chunk) - 1, fh, lock): i for i in todo}
                    last_save = time.monotonic()
                    for fut in as_completed(futs):
                        fut.result()
                        done.add(futs[fut])
                        if time.monotonic() - last_save > 5:
                            state_file.write_text(json.dumps({"size": size, "done": sorted(done)}))
                            last_save = time.monotonic()
                        if deadline and time.monotonic() > deadline:
                            pool.shutdown(wait=True, cancel_futures=True)
                            for f, i in futs.items():
                                if f.done() and not f.cancelled() and f.exception() is None:
                                    done.add(i)
                            raise BudgetExceeded(f"Tempo esgotado durante o download de {rf.name} "
                                                 f"({len(done)}/{n_chunks} partes)")
                finally:
                    pool.shutdown(wait=True, cancel_futures=True)
            finally:
                fh.close()
                state_file.write_text(json.dumps({"size": size, "done": sorted(done)}))
        else:
            if progress:
                progress(f"Baixando {rf.name} (sem suporte a partes; download contínuo)")
            with self.client.stream("GET", url) as r:
                if r.status_code != 200:
                    raise SourceError(f"Falha ao baixar {rf.name}: HTTP {r.status_code}")
                with open(part, "wb") as fh:
                    for b in r.iter_bytes(1024 * 1024):
                        fh.write(b)

        if size and part.stat().st_size != size:
            raise SourceError(f"Tamanho divergente em {rf.name}: {part.stat().st_size} != {size}")
        if not _zip_ok(part):
            raise SourceError(f"ZIP inválido após download: {rf.name}")
        part.replace(final)
        state_file.unlink(missing_ok=True)
        return final

    def _probe_size(self, url: str) -> int | None:
        h = self.client.head(url)
        return int(h.headers["content-length"]) if h.status_code == 200 and "content-length" in h.headers else None

    def _supports_range(self, url: str) -> bool:
        r = self.client.get(url, headers={"Range": "bytes=0-0"})
        return r.status_code == 206

    def _get_range(self, url: str, start: int, end: int, fh, lock: threading.Lock, attempts: int = 6) -> None:
        delay = 2.0
        for attempt in range(1, attempts + 1):
            try:
                r = self.client.get(url, headers={"Range": f"bytes={start}-{end}"})
                if r.status_code != 206:
                    raise SourceError(f"HTTP {r.status_code} no intervalo {start}-{end}")
                data = r.content
                if len(data) != end - start + 1:
                    raise SourceError(f"Parte incompleta {start}-{end}: {len(data)} bytes")
                with lock:  # funciona em Linux, macOS e Windows
                    fh.seek(start)
                    fh.write(data)
                return
            except (httpx.HTTPError, SourceError) as exc:
                if attempt == attempts:
                    raise SourceError(f"Falha ao baixar parte {start}-{end} após {attempts} tentativas: {exc}") from exc
                time.sleep(delay)
                delay = min(delay * 2, 60)


def _zip_ok(path: Path) -> bool:
    try:
        with zipfile.ZipFile(path) as z:
            return len(z.namelist()) >= 1
    except (zipfile.BadZipFile, OSError):
        return False


def reference_date(files: list[RemoteFile]):
    """Data de referência = maior data de publicação entre os arquivos (fuso de Brasília)."""
    from zoneinfo import ZoneInfo

    dates = [f.last_modified for f in files if f.last_modified]
    if not dates:
        return None
    return max(dates).astimezone(ZoneInfo("America/Sao_Paulo")).date()
