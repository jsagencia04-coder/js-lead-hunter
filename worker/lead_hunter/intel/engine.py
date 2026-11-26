"""Motor de inteligência digital: processa a fila de enriquecimento.

Independente da importação do CNPJ (comando próprio: `python -m lead_hunter intel`).
Lotes com concorrência, prioridade, limites/custos por provedor, cache, retentativas
com espera exponencial, batimento, recuperação de falhas, checkpoint e pausa.

Regra de ouro: falha de conexão, bloqueio, provedor indisponível ou ausência de
resultado NÃO provam inexistência de presença digital. "Não localizado" só quando
uma pesquisa conclusiva cobrindo aquele canal rodou e não achou correspondência.
"""
from __future__ import annotations

import json
import logging
import socket
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from urllib.parse import urlsplit

import psycopg

from ..enrich import dns_missing as default_dns_missing
from .audit import audit_site
from .match import Company, classify, digits, score_match
from .netguard import SafeFetcher
from .providers import (BraveSearch, Budget, Cache, GooglePlaces, ProviderUnavailable, TemporaryError,
                        email_domain_site, from_env)

log = logging.getLogger(__name__)

PLATFORMS = ("site", "instagram", "facebook", "google_business", "linkedin", "whatsapp")
DEFAULTS = {
    "pausado": False, "lote": 150, "concorrencia": 8, "enfileirar_por_rodada": 2000, "cache_dias": 30,
    "limites_diarios": {}, "custo_por_consulta_usd": {}, "custo_maximo_diario_usd": 5,
    "reverificar_dias": {"verificado": 90, "possivel": 30, "nao_localizado": 30, "inconclusivo": 7,
                         "erro_temporario": 1, "pendente": 7},
    "confianca_verificado": 70, "confianca_possivel": 40,
}

COMPANY_SQL = """
select q.cnpj_basico, l.id as lead_id, l.cnpj, c.razao_social, e.nome_fantasia, m.name as municipio, e.uf,
       e.logradouro, e.numero, e.bairro, e.cep, e.ddd1, e.telefone1, e.ddd2, e.telefone2, e.email, e.cnae_principal
  from unnest(%s::text[]) as q(cnpj_basico)
  join public.leads l on l.cnpj_basico = q.cnpj_basico
  join public.establishments e on e.cnpj = l.cnpj
  join public.companies c on c.cnpj_basico = l.cnpj_basico
  left join public.municipalities m on m.code = e.municipio_code
"""


@dataclass
class Channel:
    platform: str
    status: str
    url: str | None = None
    source: str | None = None
    confidence: int = 0
    evidence: list[dict] = field(default_factory=list)
    result: dict = field(default_factory=dict)
    candidates: list[dict] = field(default_factory=list)


@dataclass
class Outcome:
    channels: dict[str, Channel]
    temporary_error: str | None = None
    calls: dict[str, int] = field(default_factory=dict)


class IntelEngine:
    def __init__(self, database_url: str, *, places: GooglePlaces | None = None, brave: BraveSearch | None = None,
                 fetcher: SafeFetcher | None = None, dns_missing=default_dns_missing, db_size_limit_mb: int = 0,
                 host: str | None = None):
        self.database_url = database_url
        env_places, env_brave = from_env()
        self.places = places if places is not None else env_places
        self.brave = brave if brave is not None else env_brave
        self.fetcher = fetcher
        self.dns_missing = dns_missing
        self.db_size_limit_mb = db_size_limit_mb
        self.host = host or socket.gethostname()
        self._lock = threading.Lock()

    # ------------------------------------------------------------------ util
    def _settings(self, conn) -> dict:
        r = conn.execute("select value from public.app_settings where key = 'inteligencia'").fetchone()
        s = {**DEFAULTS, **(r[0] if r else {})}
        s["reverificar_dias"] = {**DEFAULTS["reverificar_dias"], **s.get("reverificar_dias", {})}
        return s

    def _next_check(self, settings: dict, status: str) -> datetime:
        days = settings["reverificar_dias"].get(status, 7)
        return datetime.now(timezone.utc) + timedelta(days=float(days))

    def _space_ok(self, conn) -> tuple[bool, str]:
        if not self.db_size_limit_mb:
            return True, ""
        size = conn.execute("select pg_database_size(current_database())").fetchone()[0]
        if size > self.db_size_limit_mb * 1024 * 1024 * 0.95:
            return False, (f"Banco com {size / 1e6:.0f} MB (limite {self.db_size_limit_mb} MB): "
                           "enriquecimento pausado para não estourar o espaço")
        return True, ""

    # ------------------------------------------------------------------ execução
    def run(self, deadline: float | None = None, max_items: int | None = None) -> dict:
        stats = {"processados": 0, "erros": 0, "encontrados": {}, "consultas": {}, "custo_usd": 0.0}
        with psycopg.connect(self.database_url, autocommit=True, application_name="js-lead-hunter-intel") as conn:
            if not conn.execute("select to_regclass('public.enrichment_queue') is not null").fetchone()[0]:
                log.warning("Estrutura da inteligência digital ainda não existe: aguardando as migrations do worker")
                return {**stats, "situacao": "aguardando_migrations"}
            settings = self._settings(conn)
            if settings.get("pausado"):
                self._status(conn, "ativo", {"situacao": "pausado"})
                log.info("Inteligência digital pausada pelo administrador")
                return {**stats, "situacao": "pausado"}
            ok, msg = self._space_ok(conn)
            if not ok:
                self._status(conn, "erro", {"situacao": "sem_espaco", "mensagem": msg})
                log.warning(msg)
                return {**stats, "situacao": "sem_espaco"}
            queued = conn.execute("select public.enqueue_enrichment(%s)", (int(settings["enfileirar_por_rodada"]),)).fetchone()[0]
            run_id = conn.execute(
                "insert into public.enrichment_runs (worker_host, heartbeat_at, checkpoint) values (%s, now(), %s::jsonb) returning id",
                (self.host, json.dumps({"enfileirados": queued}))).fetchone()[0]
            budget = Budget(conn, settings)
            cache = Cache(conn, int(settings["cache_dias"]))
            stop = threading.Event()
            beat = threading.Thread(target=self._heartbeat, args=(run_id, stop), daemon=True)
            beat.start()
            own_fetcher = self.fetcher is None
            fetcher = self.fetcher or SafeFetcher()
            final = "concluido"
            try:
                while True:
                    if deadline and time.monotonic() > deadline:
                        final = "interrompido"
                        break
                    if max_items is not None and stats["processados"] >= max_items:
                        break
                    if self._settings(conn).get("pausado"):
                        final = "pausado"
                        break
                    ok, msg = self._space_ok(conn)
                    if not ok:
                        final = "interrompido"
                        log.warning(msg)
                        break
                    n = int(settings["lote"]) if max_items is None else min(int(settings["lote"]), max_items - stats["processados"])
                    batch = conn.execute("select * from public.claim_enrichment_batch(%s, %s)", (self.host, n)).fetchall()
                    if not batch:
                        break
                    keys = [b[0] for b in batch]
                    attempts = {b[0]: b[4] for b in batch}
                    with conn.cursor() as cur:
                        cur.execute(COMPANY_SQL, (keys,))
                        cols = [d.name for d in cur.description]
                        rows = [dict(zip(cols, r)) for r in cur.fetchall()]
                    companies = {r["cnpj_basico"]: Company(
                        cnpj_basico=r["cnpj_basico"], cnpj=r["cnpj"], razao_social=r["razao_social"],
                        nome_fantasia=r["nome_fantasia"], municipio=r["municipio"], uf=r["uf"], logradouro=r["logradouro"],
                        numero=r["numero"], bairro=r["bairro"], cep=r["cep"], ddd1=r["ddd1"], telefone1=r["telefone1"],
                        ddd2=r["ddd2"], telefone2=r["telefone2"], email=r["email"], cnae=r["cnae_principal"],
                        lead_id=str(r["lead_id"])) for r in rows}
                    manual = {(r[0], r[1]) for r in conn.execute(
                        "select cnpj_basico, platform from public.digital_channels where manual and cnpj_basico = any(%s)",
                        (keys,)).fetchall()}
                    # empresas sem lead (ex.: arquivadas) saem da fila
                    for k in keys:
                        if k not in companies:
                            conn.execute("""update public.enrichment_queue set status = 'concluido', locked_by = null,
                                              last_error = 'sem lead ativo', updated_at = now() where cnpj_basico = %s""", (k,))
                    with ThreadPoolExecutor(max_workers=int(settings["concorrencia"])) as pool:
                        futures = {pool.submit(self.process, c, budget, cache, fetcher, settings): k
                                   for k, c in companies.items()}
                        for fut, k in futures.items():
                            try:
                                out = fut.result()
                            except Exception as exc:  # noqa: BLE001 — uma empresa não para o lote
                                log.warning("Falha no enriquecimento de uma empresa: %s", type(exc).__name__)
                                out = Outcome({}, temporary_error=f"{type(exc).__name__}: {str(exc)[:200]}")
                            self._save(conn, companies[k], out, settings, manual, attempts.get(k, 0))
                            stats["processados"] += 1
                            if out.temporary_error:
                                stats["erros"] += 1
                            for p, ch in out.channels.items():
                                if ch.status in ("verificado", "possivel"):
                                    stats["encontrados"][p] = stats["encontrados"].get(p, 0) + 1
                    lead_ids = [c.lead_id for c in companies.values()]
                    with conn.transaction():
                        conn.execute("set local app.bulk_load = 'on'")
                        conn.execute("select public.recalculate_lead_scores(%s::uuid[], null, public.current_reference_date())", (lead_ids,))
                        conn.execute("select public.rebuild_lead_recommendations(%s::uuid[])", (lead_ids,))
                    stats["consultas"] = dict(budget.calls)
                    stats["custo_usd"] = round(budget.cost, 4)
                    conn.execute(
                        """update public.enrichment_runs set processed = %s, errors = %s, found = %s::jsonb, calls = %s::jsonb,
                                  cost_usd = %s, checkpoint = checkpoint || %s::jsonb, heartbeat_at = now() where id = %s""",
                        (stats["processados"], stats["erros"], json.dumps(stats["encontrados"]), json.dumps(stats["consultas"]),
                         stats["custo_usd"], json.dumps({"ultimo_lote": len(keys), "em": datetime.now(timezone.utc).isoformat()}),
                         run_id))
            except Exception as exc:  # noqa: BLE001
                final = "falhou"
                log.exception("Falha na rodada de inteligência digital")
                conn.execute("update public.enrichment_runs set message = %s where id = %s", (str(exc)[:500], run_id))
            finally:
                stop.set()
                beat.join(timeout=5)
                if own_fetcher:
                    fetcher.close()
                conn.execute("update public.enrichment_runs set status = %s, finished_at = now() where id = %s", (final, run_id))
                self._status(conn, "erro" if final == "falhou" else "ativo",
                             {"situacao": final, "ultima_rodada": stats,
                              "provedores": {"google_places": self.places.enabled, "brave": self.brave.enabled}})
                for prov, enabled in (("google_places", self.places.enabled), ("brave", self.brave.enabled)):
                    conn.execute("""update public.integration_status set status = %s, updated_at = now(),
                                     last_seen_at = case when %s then now() else last_seen_at end where key = %s""",
                                 ("ativo" if enabled else "nao_configurado", enabled, prov))
        stats["situacao"] = final
        return stats

    def _status(self, conn, status: str, details: dict) -> None:
        conn.execute("""update public.integration_status set status = %s, last_seen_at = now(), updated_at = now(),
                          details = details || %s::jsonb where key = 'inteligencia'""", (status, json.dumps(details)))

    def _heartbeat(self, run_id, stop: threading.Event) -> None:
        try:
            with psycopg.connect(self.database_url, autocommit=True) as c:
                while not stop.wait(60):
                    c.execute("update public.enrichment_runs set heartbeat_at = now() where id = %s", (run_id,))
                    c.execute("""update public.enrichment_queue set heartbeat_at = now()
                                  where status = 'em_processamento' and locked_by = %s""", (self.host,))
        except Exception:  # noqa: BLE001
            log.warning("Batimento da inteligência digital interrompido", exc_info=True)

    # ------------------------------------------------------------------ uma empresa
    def process(self, c: Company, budget: Budget, cache: Cache, fetcher: SafeFetcher, settings: dict) -> Outcome:
        vt, pt = int(settings["confianca_verificado"]), int(settings["confianca_possivel"])
        ch: dict[str, Channel] = {}
        temp_err = None
        site_cands: list[tuple[str, list[dict], str]] = []   # (url, evidências extras, fonte)
        social_cands: dict[str, list] = {"instagram": [], "facebook": [], "linkedin": []}
        searched: set[str] = set()   # canais cobertos por pesquisa conclusiva
        dns_absent = False

        # 1. domínio do e-mail cadastral
        cand = email_domain_site(c)
        if cand:
            if self.dns_missing(cand.extra["dominio"]):
                dns_absent = True
            else:
                site_cands.append((cand.url, [], "dominio_email"))

        # 2. Perfil da Empresa no Google
        place_site = None
        if self.places.enabled:
            try:
                res = self.places.search(c, budget, cache)
                searched.update(res.platforms)
                best = None
                for p in res.candidates:
                    m = score_match(c, name=p.name, address=p.address, phone=p.phone)
                    if best is None or m.confidence > best[1].confidence:
                        best = (p, m)
                    ch.setdefault("google_business", Channel("google_business", "nao_localizado")).candidates.append(
                        {"url": p.url, "nome": p.name, "endereco": p.address, "confianca": m.confidence})
                status = classify(best[1].confidence, vt, pt) if best else None
                if best and status:
                    p, m = best
                    g = ch["google_business"]
                    g.status, g.url, g.source, g.confidence = status, p.url, "google_places", m.confidence
                    g.evidence = [e.as_dict() for e in m.evidence]
                    g.result = {"nome": p.name, "endereco": p.address, "telefone": p.phone,
                                "situacao": p.extra.get("status"), "site": p.extra.get("site")}
                    if p.extra.get("site"):
                        place_site = p.extra["site"]
                        bonus = 30 if status == "verificado" else 15
                        site_cands.append((p.extra["site"], [{"tipo": "perfil_google", "detalhe": "site informado no Perfil da Empresa no Google", "peso": bonus}], "google_places"))
                else:
                    g = ch.setdefault("google_business", Channel("google_business", "nao_localizado"))
                    g.source = "google_places"
                    g.confidence = 60
                    g.evidence = [{"tipo": "pesquisa", "detalhe": "nenhum perfil correspondente no Google (nome, cidade e telefone)", "peso": 0}]
            except ProviderUnavailable:
                pass
            except TemporaryError as exc:
                temp_err = str(exc)
                ch["google_business"] = Channel("google_business", "erro_temporario", source="google_places",
                                                evidence=[{"tipo": "erro", "detalhe": str(exc), "peso": 0}])

        # 3. pesquisa web
        if self.brave.enabled:
            try:
                res = self.brave.search(c, budget, cache)
                searched.update(res.platforms)
                for cd in res.candidates:
                    if cd.platform == "site":
                        host = (urlsplit(cd.url).hostname or "").lower()
                        if len(site_cands) < 4 and not any((urlsplit(u).hostname or "").lower() == host for u, _, _ in site_cands):
                            site_cands.append((f"https://{host}/", [], "brave"))
                    else:
                        social_cands[cd.platform].append(cd)
            except ProviderUnavailable:
                pass
            except TemporaryError as exc:
                temp_err = str(exc)

        # 4. site: auditoria técnica + validação de identidade
        site = Channel("site", "pendente")
        best_site = None
        inconclusive = []
        for url, extra_ev, src in site_cands[:4]:
            try:
                a = audit_site(fetcher, url)
            except Exception as exc:  # noqa: BLE001
                inconclusive.append(f"{url}: {type(exc).__name__}")
                continue
            if not a.get("disponivel"):
                if a.get("inconclusivo") or a.get("erro") or a.get("bloqueado"):
                    inconclusive.append(f"{url}: {a.get('erro') or a.get('bloqueado')}")
                continue
            host = (urlsplit(a.get("final_url") or url).hostname or "").lower().removeprefix("www.")
            m = score_match(c, text=(a.get("checks", {}).get("titulo", "") + " " + a.get("texto", "")), url_domain=host)
            for e in extra_ev:
                m.add(e["tipo"], e["detalhe"], e["peso"])
            phones = {digits(x) for x in a.get("checks", {}).get("contato", {}).get("telefones_texto", [])}
            if c.phones & phones and not any(e.tipo == "telefone" for e in m.evidence):
                m.add("telefone", "telefone do cadastro publicado no site", 30)
            m.confidence = max(0, min(100, sum(e.peso for e in m.evidence)))
            site.candidates.append({"url": a.get("final_url") or url, "fonte": src, "confianca": m.confidence})
            if best_site is None or m.confidence > best_site[1].confidence:
                best_site = (a, m, src)
        if best_site and classify(best_site[1].confidence, vt, pt):
            a, m, src = best_site
            site.status = classify(m.confidence, vt, pt)
            site.url, site.source, site.confidence = a.get("final_url"), src, m.confidence
            site.evidence = [e.as_dict() for e in m.evidence]
            site.result = {k: a[k] for k in ("checks", "problemas", "nota", "http_status", "sociais") if k in a}
        elif inconclusive:
            site.status = "inconclusivo"
            site.evidence = [{"tipo": "acesso", "detalhe": "; ".join(inconclusive)[:500], "peso": 0}]
        elif "site" in searched:
            site.status = "nao_localizado"
            site.source = "+".join(sorted({"brave"} | ({"google_places"} if "google_business" in searched else set())))
            ev = [{"tipo": "pesquisa_web", "detalhe": f"pesquisa por \"{c.display_name}\" em {c.municipio or '?'}/{c.uf or '?'} sem site correspondente", "peso": 0}]
            if "google_business" in searched and ch.get("google_business") and ch["google_business"].status in ("verificado", "possivel") and not place_site:
                ev.append({"tipo": "perfil_google", "detalhe": "Perfil no Google sem site informado", "peso": 0})
            if dns_absent:
                ev.append({"tipo": "dominio_email", "detalhe": f"domínio do e-mail ({c.email_domain}) não existe no DNS", "peso": 0})
            site.evidence = ev
            site.confidence = 60 + (20 if len(ev) > 1 else 0)
        elif dns_absent:
            site.status = "inconclusivo"
            site.evidence = [{"tipo": "dominio_email", "detalhe": f"domínio do e-mail ({c.email_domain}) não existe no DNS; "
                                                                  "pesquisa web não configurada para confirmar ausência", "peso": 0}]
        else:
            site.status = "pendente"
            site.evidence = [{"tipo": "pendente", "detalhe": "sem domínio próprio no cadastro e sem provedor de pesquisa configurado", "peso": 0}]
        ch["site"] = site

        # 5. redes sociais e WhatsApp
        site_verified = site.status == "verificado"
        sociais = site.result.get("sociais", {}) if site_verified else {}
        for plat in ("instagram", "facebook", "linkedin"):
            chan = Channel(plat, "pendente")
            if sociais.get(plat):
                chan.status, chan.url, chan.source, chan.confidence = "verificado", sociais[plat][0], "site_oficial", 90
                chan.evidence = [{"tipo": "link_no_site", "detalhe": f"link publicado no site oficial ({site.url})", "peso": 90}]
            else:
                best = None
                for cd in social_cands[plat]:
                    m = score_match(c, name=cd.name, text=cd.snippet, city_hint=cd.snippet)
                    chan.candidates.append({"url": cd.url, "titulo": cd.name, "confianca": m.confidence})
                    if best is None or m.confidence > best[1].confidence:
                        best = (cd, m)
                st = classify(best[1].confidence, vt, pt) if best else None
                if best and st:
                    chan.status, chan.url, chan.source, chan.confidence = st, best[0].url.split("?")[0], "brave", best[1].confidence
                    chan.evidence = [e.as_dict() for e in best[1].evidence]
                elif plat in searched:
                    chan.status, chan.source, chan.confidence = "nao_localizado", "brave", 50
                    chan.evidence = [{"tipo": "pesquisa_web", "detalhe": "nenhum perfil correspondente nos resultados da pesquisa", "peso": 0}]
            ch[plat] = chan
        wa = Channel("whatsapp", "pendente")
        if sociais.get("whatsapp"):
            num = digits(sociais["whatsapp"][0])
            wa.status, wa.url, wa.source = "verificado", sociais["whatsapp"][0], "site_oficial"
            wa.confidence = 95 if any(num.endswith(p[-8:]) for p in c.phones) else 85
            wa.evidence = [{"tipo": "link_no_site", "detalhe": "WhatsApp divulgado no site oficial", "peso": wa.confidence}]
        elif site_verified:
            wa.status, wa.source, wa.confidence = "nao_localizado", "site_oficial", 50
            wa.evidence = [{"tipo": "site", "detalhe": "o site oficial não divulga WhatsApp", "peso": 0}]
        ch["whatsapp"] = wa
        if "google_business" not in ch:
            ch["google_business"] = Channel("google_business", "pendente", evidence=[
                {"tipo": "pendente", "detalhe": "Google Places API não configurada", "peso": 0}])
        return Outcome(ch, temporary_error=temp_err)

    # ------------------------------------------------------------------ gravação
    def _save(self, conn, c: Company, out: Outcome, settings: dict, manual: set, attempts: int) -> None:
        now = datetime.now(timezone.utc)
        for p, chan in out.channels.items():
            if (c.cnpj_basico, p) in manual:
                continue
            conn.execute(
                """insert into public.digital_channels (cnpj_basico, lead_id, platform, url, status, source, evidence, confidence,
                                                         result, candidates, first_checked_at, last_checked_at, next_check_at)
                   values (%s, %s, %s, %s, %s, %s, %s::jsonb, %s, %s::jsonb, %s::jsonb, %s, %s, %s)
                   on conflict (cnpj_basico, platform) do update set
                     lead_id = excluded.lead_id, url = excluded.url, status = excluded.status, source = excluded.source,
                     evidence = excluded.evidence, confidence = excluded.confidence, result = excluded.result,
                     candidates = excluded.candidates, last_checked_at = excluded.last_checked_at,
                     next_check_at = excluded.next_check_at, updated_at = now()
                   where not public.digital_channels.manual""",
                (c.cnpj_basico, c.lead_id, p, chan.url, chan.status, chan.source, json.dumps(chan.evidence), chan.confidence,
                 json.dumps(chan.result), json.dumps(chan.candidates[:10]), now, now, self._next_check(settings, chan.status)))
        if out.temporary_error:
            wait = min(24 * 60, 2 ** (attempts + 1) * 5)   # 10, 20, 40 ... min (máx. 24 h)
            conn.execute("""update public.enrichment_queue set status = 'erro', attempts = attempts + 1, last_error = %s,
                              next_attempt_at = now() + make_interval(mins => %s), locked_by = null, locked_at = null,
                              last_run_at = now(), updated_at = now() where cnpj_basico = %s""",
                         (out.temporary_error[:500], wait, c.cnpj_basico))
        else:
            conn.execute("""update public.enrichment_queue set status = 'concluido', attempts = 0, last_error = null,
                              locked_by = null, locked_at = null, last_run_at = now(), updated_at = now()
                             where cnpj_basico = %s""", (c.cnpj_basico,))
        # compatibilidade: resumo do site em leads.digital_presence / website
        site = out.channels.get("site")
        if site and (c.cnpj_basico, "site") not in manual:
            legacy = {"verificado": "site_ok", "possivel": "site_ok", "nao_localizado": "sem_site",
                      "inconclusivo": "inconclusivo", "erro_temporario": "inconclusivo"}.get(site.status)
            if site.status == "verificado" and any(i["codigo"] == "pagina_vazia_ou_estacionada" for i in site.result.get("problemas", [])):
                legacy = "site_fraco"
            if site.status == "pendente":
                legacy = "sem_dominio_proprio" if not email_domain_site(c) else None
            if legacy:
                info = {"status": legacy, "fonte": "inteligencia", "checked_at": now.isoformat(), "url": site.url,
                        "dominio": c.email_domain, "confianca": site.confidence,
                        "detalhe": (site.evidence[0]["detalhe"] if site.evidence else None)}
                with conn.transaction():
                    conn.execute("set local app.bulk_load = 'on'")
                    conn.execute("""update public.leads set digital_presence = %s::jsonb,
                                      website = case when %s then coalesce(website, %s) else website end
                                     where id = %s""",
                                 (json.dumps(info), site.status == "verificado", site.url, c.lead_id))
