"""Provedores de pesquisa autorizados (APIs oficiais, sem raspagem nem evasão de bloqueios).

- dominio_email: domínio próprio do e-mail cadastral (grátis);
- google_places: Google Places API (New) — Text Search; requer GOOGLE_PLACES_API_KEY;
- brave: Brave Search API — pesquisa web; requer BRAVE_SEARCH_API_KEY.

Instagram, Facebook e LinkedIn não oferecem busca aberta de perfis comerciais:
eles são descobertos por links publicados no site da própria empresa ou por
resultados da pesquisa web — nunca acessando essas plataformas diretamente.
"""
from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import threading
import time
from dataclasses import dataclass, field
from urllib.parse import urlsplit

import httpx

from ..enrich import ACCOUNTANT_DOMAIN, GENERIC_DOMAINS
from .match import Company, norm

log = logging.getLogger(__name__)

DIRECTORY_HOSTS = re.compile(
    r"(cnpj\.(biz|info|ws|services)|cnpja|casadosdados|econodata|empresaqui|consultas?cnpj|cnpjs\.rocks|solutudo|"
    r"guiamais|telelistas|apontador|listamais|encontrasp|infobel|cylex|hotfrog|yelp|tripadvisor|ifood|"
    r"google\.|goo\.gl|youtube|tiktok|twitter|x\.com|wikipedia|jusbrasil|escavador|reclameaqui|olx|mercadolivre|"
    r"gov\.br|receita|serasa|linkedin\.com/in/|glassdoor|indeed|catho|infojobs|vagas\.com|maps\.app)", re.I)


class ProviderUnavailable(RuntimeError):
    """Sem chave, limite diário ou orçamento esgotado: o canal fica pendente (nunca 'não localizado')."""


class TemporaryError(RuntimeError):
    """Falha passageira do provedor (rede, 429, 5xx): nova tentativa com espera crescente."""


@dataclass
class Candidate:
    platform: str
    url: str
    source: str
    name: str | None = None
    address: str | None = None
    phone: str | None = None
    snippet: str | None = None
    extra: dict = field(default_factory=dict)


@dataclass
class SearchOutcome:
    provider: str
    candidates: list[Candidate]
    conclusive: bool          # a pesquisa rodou de fato (pode ser "nada encontrado")
    platforms: tuple[str, ...]  # canais que essa pesquisa cobre
    business_found: bool = False  # Google: a empresa foi encontrada (Perfil existe)


class Budget:
    """Limites diários e custo por provedor, gravados em provider_usage (por dia)."""

    def __init__(self, conn, settings: dict):
        self.conn = conn
        self.limits = settings.get("limites_diarios", {})
        self.costs = settings.get("custo_por_consulta_usd", {})
        self.max_cost = float(settings.get("custo_maximo_diario_usd", 0) or 0)
        self.calls: dict[str, int] = {}
        self.cost = 0.0
        self._lock = threading.Lock()

    def _today(self) -> tuple[dict, float]:
        rows = self.conn.execute("select provider, calls, cost_usd from public.provider_usage where day = current_date").fetchall()
        return {r[0]: r[1] for r in rows}, float(sum(r[2] for r in rows))

    def reserve(self, provider: str) -> None:
        with self._lock:
            self._reserve(provider)

    def _reserve(self, provider: str) -> None:
        used, cost_today = self._today()
        limit = int(self.limits.get(provider, 0) or 0)
        unit = float(self.costs.get(provider, 0) or 0)
        if limit and used.get(provider, 0) >= limit:
            raise ProviderUnavailable(f"{provider}: limite diário de {limit} consultas atingido")
        if unit and self.max_cost and cost_today + unit > self.max_cost:
            raise ProviderUnavailable(f"orçamento diário de US$ {self.max_cost:.2f} atingido")
        self.conn.execute(
            """insert into public.provider_usage (provider, day, calls, cost_usd) values (%s, current_date, 1, %s)
               on conflict (provider, day) do update set calls = provider_usage.calls + 1,
                                                         cost_usd = provider_usage.cost_usd + excluded.cost_usd""",
            (provider, unit))
        self.calls[provider] = self.calls.get(provider, 0) + 1
        self.cost += unit

    def error(self, provider: str) -> None:
        self.conn.execute(
            """insert into public.provider_usage (provider, day, errors) values (%s, current_date, 1)
               on conflict (provider, day) do update set errors = provider_usage.errors + 1""", (provider,))


class Cache:
    def __init__(self, conn, days: int):
        self.conn = conn
        self.days = days

    @staticmethod
    def key(*parts: str) -> str:
        return hashlib.sha256("|".join(norm(p) for p in parts).encode()).hexdigest()

    def get(self, provider: str, key: str):
        r = self.conn.execute(
            """select response from public.enrichment_cache where provider = %s and query_key = %s
                and fetched_at > now() - make_interval(days => %s)""", (provider, key, self.days)).fetchone()
        return r[0] if r else None

    def put(self, provider: str, key: str, response) -> None:
        self.conn.execute(
            """insert into public.enrichment_cache (provider, query_key, response) values (%s, %s, %s::jsonb)
               on conflict (provider, query_key) do update set response = excluded.response, fetched_at = now()""",
            (provider, key, json.dumps(response)))


def _api_call(fn, provider: str, budget: Budget, attempts: int = 3):
    delay = 1.0
    for i in range(attempts):
        try:
            r = fn()
        except httpx.HTTPError as exc:
            if i == attempts - 1:
                budget.error(provider)
                raise TemporaryError(f"{provider}: {type(exc).__name__}") from exc
        else:
            if r.status_code == 429 or r.status_code >= 500:
                if i == attempts - 1:
                    budget.error(provider)
                    raise TemporaryError(f"{provider}: HTTP {r.status_code}")
            elif r.status_code in (401, 403):
                budget.error(provider)
                raise ProviderUnavailable(f"{provider}: chave recusada (HTTP {r.status_code})")
            elif r.status_code >= 400:
                budget.error(provider)
                raise TemporaryError(f"{provider}: HTTP {r.status_code} {r.text[:200]}")
            else:
                return r.json()
        time.sleep(delay)
        delay *= 2
    raise TemporaryError(provider)


class GooglePlaces:
    name = "google_places"
    URL = "https://places.googleapis.com/v1/places:searchText"
    FIELDS = ("places.id,places.displayName,places.formattedAddress,places.nationalPhoneNumber,"
              "places.internationalPhoneNumber,places.websiteUri,places.googleMapsUri,places.businessStatus")

    def __init__(self, api_key: str | None, client: httpx.Client | None = None):
        self.api_key = api_key
        self.client = client or httpx.Client(timeout=20)

    @property
    def enabled(self) -> bool:
        return bool(self.api_key)

    def search(self, c: Company, budget: Budget, cache: Cache) -> SearchOutcome:
        if not self.enabled:
            raise ProviderUnavailable("google_places: GOOGLE_PLACES_API_KEY não configurada")
        query = f"{c.display_name} {c.municipio or ''} {c.uf or ''}".strip()
        key = Cache.key(query)
        data = cache.get(self.name, key)
        if data is None:
            budget.reserve(self.name)
            data = _api_call(lambda: self.client.post(
                self.URL, headers={"X-Goog-Api-Key": self.api_key, "X-Goog-FieldMask": self.FIELDS},
                json={"textQuery": query, "languageCode": "pt-BR", "regionCode": "BR", "pageSize": 5}), self.name, budget)
            cache.put(self.name, key, data)
        cands = []
        for p in (data or {}).get("places", [])[:5]:
            name = (p.get("displayName") or {}).get("text")
            extra = {"place_id": p.get("id"), "status": p.get("businessStatus"), "site": p.get("websiteUri")}
            cands.append(Candidate("google_business", p.get("googleMapsUri") or "", self.name, name=name,
                                   address=p.get("formattedAddress"),
                                   phone=p.get("nationalPhoneNumber") or p.get("internationalPhoneNumber"), extra=extra))
        return SearchOutcome(self.name, cands, conclusive=True, platforms=("google_business",))


class BraveSearch:
    name = "brave"
    URL = "https://api.search.brave.com/res/v1/web/search"

    def __init__(self, api_key: str | None, client: httpx.Client | None = None):
        self.api_key = api_key
        self.client = client or httpx.Client(timeout=20)

    @property
    def enabled(self) -> bool:
        return bool(self.api_key)

    def _query(self, q: str, budget: Budget, cache: Cache) -> list[dict]:
        key = Cache.key(q)
        data = cache.get(self.name, key)
        if data is None:
            budget.reserve(self.name)
            data = _api_call(lambda: self.client.get(
                self.URL, params={"q": q, "country": "BR", "search_lang": "pt-br", "count": 10, "safesearch": "moderate"},
                headers={"X-Subscription-Token": self.api_key, "Accept": "application/json"}), self.name, budget)
            cache.put(self.name, key, data)
        return ((data or {}).get("web") or {}).get("results", [])

    def search(self, c: Company, budget: Budget, cache: Cache) -> SearchOutcome:
        if not self.enabled:
            raise ProviderUnavailable("brave: BRAVE_SEARCH_API_KEY não configurada")
        place = f"{c.municipio or ''} {c.uf or ''}".strip()
        results = self._query(f'"{c.display_name}" {place}', budget, cache)
        results += self._query(f'"{c.display_name}" {place} instagram OR facebook', budget, cache)
        cands: list[Candidate] = []
        seen = set()
        for r in results:
            url = (r.get("url") or "").split("#")[0]
            if not url or url in seen:
                continue
            seen.add(url)
            snippet = " ".join(x for x in (r.get("title"), r.get("description")) if x)
            host = (urlsplit(url).hostname or "").lower()
            platform = None
            if host.endswith("instagram.com"):
                platform = "instagram"
            elif host.endswith(("facebook.com", "fb.com")):
                platform = "facebook"
            elif host.endswith("linkedin.com") and "/company/" in url:
                platform = "linkedin"
            elif not DIRECTORY_HOSTS.search(url):
                platform = "site"
            if platform:
                cands.append(Candidate(platform, url, self.name, name=r.get("title"), snippet=snippet))
        return SearchOutcome(self.name, cands, conclusive=True, platforms=("site", "instagram", "facebook", "linkedin"))


def email_domain_site(c: Company) -> Candidate | None:
    d = c.email_domain
    if not d or d in GENERIC_DOMAINS or (ACCOUNTANT_DOMAIN.search(d) and not (c.cnae or "").startswith("6920")):
        return None
    return Candidate("site", f"https://{d}/", "dominio_email", extra={"dominio": d})


def from_env() -> tuple[GooglePlaces, BraveSearch]:
    return GooglePlaces(os.getenv("GOOGLE_PLACES_API_KEY") or None), BraveSearch(os.getenv("BRAVE_SEARCH_API_KEY") or None)
