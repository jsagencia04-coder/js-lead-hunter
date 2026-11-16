"""Enriquecimento de presença digital a partir do domínio do e-mail cadastrado.

Só conta como "oportunidade digital" o que foi efetivamente verificado:
- e-mail em provedor genérico (gmail, hotmail...)  → sem_dominio_proprio (não pontua)
- domínio usado por várias empresas (ex.: contador) → dominio_compartilhado (não pontua)
- domínio próprio sem site respondendo              → sem_site    (pontua)
- domínio próprio com página vazia/estacionada      → site_fraco  (pontua)
- domínio próprio com site no ar                    → site_ok     (preenche "site")
- servidor recusou o acesso (403/429/5xx)           → inconclusivo (não pontua; nova tentativa em 7 dias)

Acessa apenas a página inicial pública do domínio da própria empresa.
"""
from __future__ import annotations

import json
import logging
import re
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Callable

import httpx
import psycopg

log = logging.getLogger(__name__)

GENERIC_DOMAINS = {
    "gmail.com", "googlemail.com", "hotmail.com", "hotmail.com.br", "outlook.com", "outlook.com.br",
    "live.com", "live.com.br", "msn.com", "yahoo.com", "yahoo.com.br", "ymail.com", "icloud.com", "me.com",
    "mac.com", "aol.com", "bol.com.br", "uol.com.br", "terra.com.br", "ig.com.br", "globo.com",
    "globomail.com", "r7.com", "zipmail.com.br", "oi.com.br", "click21.com.br", "protonmail.com",
    "proton.me", "yandex.com", "gmx.com", "mail.com", "zoho.com", "tutanota.com", "pop.com.br",
    "superig.com.br", "brturbo.com.br", "veloxmail.com.br", "itelefonica.com.br", "hotmai.com",
    "gmai.com", "gamil.com", "gmail.com.br",
}
PARKED_MARKERS = re.compile(
    r"domain (is )?for sale|this domain|dom[ií]nio (est[aá] )?(à|a) venda|parked|registro\.br|"
    r"hostgator|em constru[cç][aã]o|under construction|coming soon|index of /|default web site page|"
    r"it works!|welcome to nginx|apache2 ubuntu default", re.I)
SHARED_DOMAIN_MIN_COMPANIES = 3
# Escritórios de contabilidade costumam cadastrar o próprio e-mail ao abrir o CNPJ do cliente
ACCOUNTANT_DOMAIN = re.compile(r"contab|contador|contabil|escritorio|assessoriacont", re.I)


@dataclass
class CheckResult:
    status: str
    http_status: int | None = None
    final_url: str | None = None
    detail: str | None = None


def domain_of(email: str | None) -> str | None:
    if not email or "@" not in email:
        return None
    d = email.strip().lower().rsplit("@", 1)[1].strip(". ")
    return d if re.fullmatch(r"[a-z0-9.-]+\.[a-z]{2,}", d) else None


def check_domain(domain: str, client: httpx.Client) -> CheckResult:
    """Tenta https://dominio, https://www.dominio e http://dominio.

    Bloqueio de robôs (403, 429) e erros do servidor (5xx) não provam ausência
    de site: o resultado é "inconclusivo" e não pontua.
    """
    statuses: list[int] = []
    last_error = None
    for url in (f"https://{domain}", f"https://www.{domain}", f"http://{domain}"):
        try:
            r = client.get(url)
        except httpx.HTTPError as exc:
            last_error = type(exc).__name__
            continue
        if r.status_code >= 400:
            statuses.append(r.status_code)
            continue
        body = r.text[:20000] if "html" in r.headers.get("content-type", "html") else ""
        text = re.sub(r"<[^>]+>", " ", body)
        if len(text.strip()) < 200 or PARKED_MARKERS.search(body):
            return CheckResult("site_fraco", r.status_code, str(r.url), "página vazia, padrão ou estacionada")
        return CheckResult("site_ok", r.status_code, str(r.url))
    if any(code in (401, 403, 429) or code >= 500 for code in statuses):
        return CheckResult("inconclusivo", max(statuses), None, "servidor recusou ou falhou: " +
                           ",".join(str(c) for c in sorted(set(statuses))))
    if statuses:  # só 404/410 etc.: há hospedagem, mas nenhuma página publicada
        return CheckResult("site_fraco", statuses[-1], None, "domínio sem página publicada")
    return CheckResult("sem_site", None, None, last_error or "sem resposta")


class Enricher:
    def __init__(self, database_url: str, batch: int = 3000, workers: int = 32, timeout: float = 8.0,
                 checker: Callable[[str], CheckResult] | None = None):
        self.database_url = database_url
        self.batch = batch
        self.workers = workers
        self.timeout = timeout
        self._checker = checker

    def _make_checker(self):
        if self._checker:
            return self._checker, None
        client = httpx.Client(timeout=httpx.Timeout(self.timeout, connect=5), follow_redirects=True,
                              headers={"User-Agent": "Mozilla/5.0 (compatible; JS-Lead-Hunter/1.0)"},
                              limits=httpx.Limits(max_connections=self.workers * 2))
        return (lambda d: check_domain(d, client)), client

    def run(self, deadline: float | None = None) -> dict:
        stats = {"verificados": 0, "sem_dominio_proprio": 0, "dominio_compartilhado": 0,
                 "sem_site": 0, "site_fraco": 0, "site_ok": 0, "inconclusivo": 0}
        with psycopg.connect(self.database_url, autocommit=True) as c:
            rows = c.execute("""
                select l.id, lower(trim(e.email)), coalesce(e.cnae_principal, '')
                  from public.leads l
                  join public.establishments e on e.cnpj = l.cnpj
                 where e.email is not null
                   and ((l.digital_presence ->> 'checked_at') is null
                        or (l.digital_presence ->> 'status' = 'inconclusivo'
                            and (l.digital_presence ->> 'checked_at')::timestamptz < now() - interval '7 days'))
                   and l.stage not in ('convertido', 'perdido')
                 order by l.score desc, l.created_at desc
                 limit %s""", (self.batch,)).fetchall()
            shared = {r[0]: r[1] for r in c.execute("""
                select split_part(lower(trim(email)), '@', 2) as dominio, count(distinct cnpj_basico)
                  from public.establishments
                 where email is not null
                 group by 1
                having count(distinct cnpj_basico) >= %s""", (SHARED_DOMAIN_MIN_COMPANIES,)).fetchall()}
        if not rows:
            return stats

        now = datetime.now(timezone.utc).isoformat()
        updates: dict[str, tuple[dict, str | None]] = {}
        to_check: dict[str, list[str]] = {}
        for lead_id, email, cnae in rows:
            dom = domain_of(email)
            if not dom or dom in GENERIC_DOMAINS:
                updates[str(lead_id)] = ({"status": "sem_dominio_proprio", "dominio": dom, "checked_at": now,
                                          "fonte": "email_cadastral"}, None)
            elif ACCOUNTANT_DOMAIN.search(dom) and not cnae.startswith("6920"):
                updates[str(lead_id)] = ({"status": "dominio_compartilhado", "dominio": dom, "checked_at": now,
                                          "motivo": "domínio de escritório de contabilidade",
                                          "fonte": "email_cadastral"}, None)
            elif dom in shared:
                updates[str(lead_id)] = ({"status": "dominio_compartilhado", "dominio": dom, "checked_at": now,
                                          "empresas_no_dominio": shared[dom], "fonte": "email_cadastral"}, None)
            else:
                to_check.setdefault(dom, []).append(str(lead_id))

        check, client = self._make_checker()
        try:
            with ThreadPoolExecutor(max_workers=self.workers) as pool:
                futures = {}
                for dom in to_check:
                    if deadline and time.monotonic() > deadline:
                        break
                    futures[pool.submit(check, dom)] = dom
                for fut, dom in futures.items():
                    try:
                        res = fut.result()
                    except Exception as exc:  # noqa: BLE001 — uma falha isolada não para o lote
                        log.debug("verificação de %s falhou: %s", dom, exc)
                        continue
                    info = {"status": res.status, "dominio": dom, "checked_at": now, "fonte": "dominio_email",
                            "http_status": res.http_status, "url": res.final_url, "detalhe": res.detail}
                    for lead_id in to_check[dom]:
                        updates[lead_id] = (info, res.final_url if res.status in ("site_ok", "site_fraco") else None)
        finally:
            if client:
                client.close()

        if not updates:
            return stats
        with psycopg.connect(self.database_url) as c, c.transaction():
            c.execute("SET LOCAL app.bulk_load = 'on'")
            with c.cursor() as cur:
                cur.executemany(
                    """update public.leads
                          set digital_presence = %s::jsonb,
                              website = coalesce(website, %s)
                        where id = %s""",
                    [(json.dumps(info), site, lead_id) for lead_id, (info, site) in updates.items()])
            ids = list(updates.keys())
            c.execute("select public.recalculate_lead_scores(%s::uuid[], null, public.current_reference_date())", (ids,))
            c.execute("select public.rebuild_lead_recommendations(%s::uuid[])", (ids,))
        for info, _ in updates.values():
            stats["verificados"] += 1
            stats[info["status"]] = stats.get(info["status"], 0) + 1
        return stats
