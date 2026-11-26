"""Validação de identidade digital: evita associar canais de empresas homônimas.

O índice de confiança (0 a 100) soma evidências verificáveis e desconta
divergências. Cada evidência fica registrada com o peso usado.
"""
from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass, field
from difflib import SequenceMatcher

STOPWORDS = {
    "ltda", "me", "epp", "eireli", "sa", "s/a", "ss", "mei", "cia", "comercio", "servicos", "servico", "de", "da",
    "do", "das", "dos", "e", "em", "the", "industria", "empresa", "holding", "participacoes", "limitada", "unipessoal",
}


def strip_accents(s: str) -> str:
    return "".join(c for c in unicodedata.normalize("NFKD", s) if not unicodedata.combining(c))


def norm(s: str | None) -> str:
    s = strip_accents((s or "").lower())
    s = re.sub(r"[^a-z0-9 ]+", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def name_tokens(s: str | None) -> list[str]:
    return [t for t in norm(s).split() if t not in STOPWORDS and len(t) > 1 and not t.isdigit()]


def name_similarity(a: str | None, b: str | None) -> float:
    ta, tb = name_tokens(a), name_tokens(b)
    if not ta or not tb:
        return 0.0
    sa, sb = set(ta), set(tb)
    jacc = len(sa & sb) / len(sa | sb)
    seq = SequenceMatcher(None, " ".join(ta), " ".join(tb)).ratio()
    contain = 1.0 if (" ".join(ta) in " ".join(tb) or " ".join(tb) in " ".join(ta)) else 0.0
    return round(max(jacc, seq * 0.9, contain * 0.85), 3)


def digits(s: str | None) -> str:
    return re.sub(r"\D", "", s or "")


def phone_variants(ddd: str | None, tel: str | None) -> set[str]:
    t = digits(tel)
    d = digits(ddd)
    if len(t) < 8:
        return set()
    out = {t, t[-8:]}
    if d:
        out |= {d + t, "55" + d + t}
    return out


@dataclass
class Company:
    cnpj_basico: str
    cnpj: str
    razao_social: str | None
    nome_fantasia: str | None
    municipio: str | None
    uf: str | None
    logradouro: str | None = None
    numero: str | None = None
    bairro: str | None = None
    cep: str | None = None
    ddd1: str | None = None
    telefone1: str | None = None
    ddd2: str | None = None
    telefone2: str | None = None
    email: str | None = None
    cnae: str | None = None
    lead_id: str | None = None

    @property
    def display_name(self) -> str:
        return self.nome_fantasia or self.razao_social or self.cnpj

    @property
    def phones(self) -> set[str]:
        return phone_variants(self.ddd1, self.telefone1) | phone_variants(self.ddd2, self.telefone2)

    @property
    def email_domain(self) -> str | None:
        if self.email and "@" in self.email:
            return self.email.rsplit("@", 1)[1].lower().strip(". ")
        return None


@dataclass
class Evidence:
    tipo: str
    detalhe: str
    peso: int

    def as_dict(self) -> dict:
        return {"tipo": self.tipo, "detalhe": self.detalhe, "peso": self.peso}


@dataclass
class MatchResult:
    confidence: int
    evidence: list[Evidence] = field(default_factory=list)

    def add(self, tipo: str, detalhe: str, peso: int) -> None:
        self.evidence.append(Evidence(tipo, detalhe, peso))


def score_match(company: Company, *, name: str | None = None, text: str | None = None, address: str | None = None,
                phone: str | None = None, url_domain: str | None = None, city_hint: str | None = None) -> MatchResult:
    """Confronta um candidato (página, perfil ou resultado de pesquisa) com o cadastro.

    `text`: conteúdo textual disponível (página ou trecho do resultado).
    """
    res = MatchResult(0)
    body = norm(text)
    body_digits = digits(text)

    # CNPJ na página: evidência mais forte (só a própria empresa publica o CNPJ dela)
    if company.cnpj and company.cnpj.isdigit() and company.cnpj in body_digits:
        res.add("cnpj", "CNPJ da empresa encontrado no conteúdo", 60)
    elif company.cnpj_basico and len(body_digits) > 0 and re.search(
            re.escape(company.cnpj_basico[:2]) + r"\D?" + re.escape(company.cnpj_basico[2:5]) + r"\D?"
            + re.escape(company.cnpj_basico[5:8]), text or ""):
        res.add("cnpj_basico", "raiz do CNPJ encontrada no conteúdo", 40)

    # Telefone
    cand_phones = phone_variants(None, phone) if phone else set()
    if company.phones and (company.phones & cand_phones or any(p in body_digits for p in company.phones if len(p) >= 10)):
        res.add("telefone", "telefone do cadastro confere", 30)

    # Domínio igual ao do e-mail cadastral (e não genérico)
    if url_domain and company.email_domain and (url_domain == company.email_domain
                                                or url_domain.endswith("." + company.email_domain)):
        res.add("dominio_email", f"domínio igual ao do e-mail cadastral ({company.email_domain})", 40)

    # Nome
    own_names = [n for n in (company.nome_fantasia, company.razao_social) if n]
    if name:
        sim = max([name_similarity(n, name) for n in own_names] or [0.0])
        if sim >= 0.85:
            res.add("nome", f"nome muito semelhante ({sim:.0%})", 25)
        elif sim >= 0.6:
            res.add("nome", f"nome semelhante ({sim:.0%})", 15)
        else:
            res.add("nome_divergente", f"nome diferente do cadastro ({sim:.0%})", -25)
    elif body:
        for n in own_names:
            toks = name_tokens(n)
            if toks and all(re.search(rf"\b{re.escape(t)}\b", body) for t in toks):
                res.add("nome", "nome da empresa presente no conteúdo", 20)
                break

    # Localização
    city = norm(company.municipio)
    where = norm(" ".join(x for x in (address, city_hint, text[:3000] if text else None) if x))
    if city and where:
        if re.search(rf"\b{re.escape(city)}\b", where):
            res.add("municipio", f"município confere ({company.municipio})", 15)
        elif address:
            res.add("municipio_divergente", "endereço em outro município", -30)
    if company.logradouro and address and norm(company.logradouro) and norm(company.logradouro) in norm(address):
        res.add("endereco", "logradouro confere", 10)
    if company.cep and digits(company.cep) and digits(company.cep) in body_digits + digits(address):
        res.add("cep", "CEP confere", 10)

    res.confidence = max(0, min(100, sum(e.peso for e in res.evidence)))
    return res


def classify(confidence: int, verified_at: int = 70, possible_at: int = 40) -> str | None:
    if confidence >= verified_at:
        return "verificado"
    if confidence >= possible_at:
        return "possivel"
    return None
