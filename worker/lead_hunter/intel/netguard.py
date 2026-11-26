"""Acesso seguro a URLs externas (proteção contra SSRF).

- só http/https, portas 80/443 (ou a porta padrão do esquema);
- o nome é resolvido e TODOS os endereços precisam ser públicos (nada de rede
  interna, loopback, link-local, multicast, reservado, metadados de nuvem);
- redirecionamentos são seguidos manualmente (no máximo 5), validando cada destino;
- depois de conectar, o endereço REAL do servidor é conferido (protege contra
  DNS rebinding entre a validação e a conexão);
- o corpo é lido com limite de tamanho; respostas maiores são truncadas.
"""
from __future__ import annotations

import ipaddress
import socket
import time
from dataclasses import dataclass, field
from typing import Callable
from urllib.parse import urljoin, urlsplit

import httpx

MAX_BYTES = 1_500_000
MAX_REDIRECTS = 5
USER_AGENT = "Mozilla/5.0 (compatible; JS-Lead-Hunter/2.0; +https://jsdesigner.pro)"


class BlockedURL(ValueError):
    """URL recusada pela política de segurança."""


@dataclass
class FetchResult:
    url: str
    final_url: str
    status: int
    headers: dict[str, str]
    body: bytes
    elapsed_ms: int
    redirects: list[str] = field(default_factory=list)
    truncated: bool = False
    https_ok: bool = False

    @property
    def text(self) -> str:
        ct = self.headers.get("content-type", "")
        enc = "utf-8"
        if "charset=" in ct:
            enc = ct.split("charset=", 1)[1].split(";")[0].strip() or "utf-8"
        try:
            return self.body.decode(enc, errors="replace")
        except LookupError:
            return self.body.decode("utf-8", errors="replace")


def is_public_ip(ip: str) -> bool:
    try:
        addr = ipaddress.ip_address(ip.split("%", 1)[0])
    except ValueError:
        return False
    if isinstance(addr, ipaddress.IPv6Address) and addr.ipv4_mapped:
        addr = addr.ipv4_mapped
    return addr.is_global and not (addr.is_multicast or addr.is_reserved or addr.is_loopback
                                   or addr.is_link_local or addr.is_private or addr.is_unspecified)


def default_resolver(host: str, port: int) -> list[str]:
    return sorted({ai[4][0] for ai in socket.getaddrinfo(host, port, proto=socket.IPPROTO_TCP)})


class SafeFetcher:
    def __init__(self, client: httpx.Client | None = None, *, allow_private: bool = False,
                 resolver: Callable[[str, int], list[str]] = default_resolver,
                 max_bytes: int = MAX_BYTES, timeout: float = 10.0):
        self.client = client or httpx.Client(
            timeout=httpx.Timeout(timeout, connect=5), follow_redirects=False,
            headers={"User-Agent": USER_AGENT, "Accept": "text/html,application/xhtml+xml;q=0.9,*/*;q=0.5"},
            limits=httpx.Limits(max_connections=32))
        self.own_client = client is None
        self.allow_private = allow_private
        self.resolver = resolver
        self.max_bytes = max_bytes

    def close(self) -> None:
        if self.own_client:
            self.client.close()

    def check_url(self, url: str) -> None:
        parts = urlsplit(url)
        if parts.scheme not in ("http", "https"):
            raise BlockedURL(f"esquema não permitido: {parts.scheme or '?'}")
        if not parts.hostname:
            raise BlockedURL("URL sem servidor")
        if parts.username or parts.password:
            raise BlockedURL("URL com credenciais")
        port = parts.port or (443 if parts.scheme == "https" else 80)
        if port not in (80, 443) and not self.allow_private:
            raise BlockedURL(f"porta não permitida: {port}")
        if self.allow_private:
            return
        host = parts.hostname
        if host.lower() in ("localhost", "metadata.google.internal") or host.lower().endswith((".local", ".internal")):
            raise BlockedURL("servidor interno")
        try:
            ips = self.resolver(host, port)
        except socket.gaierror as exc:
            raise BlockedURL(f"nome não resolvido: {exc.strerror or exc}") from exc
        if not ips or not all(is_public_ip(ip) for ip in ips):
            raise BlockedURL("endereço não público")

    def _peer_ok(self, response: httpx.Response) -> bool:
        if self.allow_private:
            return True
        stream = response.extensions.get("network_stream")
        if stream is None:
            return True
        try:
            addr = stream.get_extra_info("server_addr")
        except Exception:  # noqa: BLE001
            return True
        return not addr or is_public_ip(str(addr[0]))

    def get(self, url: str, *, method: str = "GET", read_body: bool = True) -> FetchResult:
        redirects: list[str] = []
        current = url
        t0 = time.monotonic()
        for _ in range(MAX_REDIRECTS + 1):
            self.check_url(current)
            req = self.client.build_request(method, current)
            r = self.client.send(req, stream=True)
            try:
                if not self._peer_ok(r):
                    raise BlockedURL("o servidor respondeu de um endereço não público")
                if r.status_code in (301, 302, 303, 307, 308) and "location" in r.headers:
                    nxt = urljoin(current, r.headers["location"])
                    redirects.append(nxt)
                    current = nxt
                    continue
                body = b""
                truncated = False
                if read_body and method != "HEAD":
                    chunks = []
                    size = 0
                    for chunk in r.iter_bytes():
                        chunks.append(chunk)
                        size += len(chunk)
                        if size >= self.max_bytes:
                            truncated = True
                            break
                    body = b"".join(chunks)[: self.max_bytes]
                return FetchResult(url=url, final_url=current, status=r.status_code,
                                   headers={k.lower(): v for k, v in r.headers.items()}, body=body,
                                   elapsed_ms=int((time.monotonic() - t0) * 1000), redirects=redirects,
                                   truncated=truncated, https_ok=urlsplit(current).scheme == "https")
            finally:
                r.close()
        raise BlockedURL(f"redirecionamentos demais (> {MAX_REDIRECTS})")
