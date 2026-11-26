import httpx

from lead_hunter.enrich import CheckResult, Enricher, check_domain, domain_of

from .fake_rf import FakeRF, build_competence
from .test_pipeline import make_worker, q, run_import


def test_domain_of():
    assert domain_of("Contato@Empresa.COM.BR ") == "empresa.com.br"
    assert domain_of("sem-arroba") is None
    assert domain_of(None) is None


def _client(handler):
    return httpx.Client(transport=httpx.MockTransport(handler), follow_redirects=True)


def test_check_domain_classifica():
    def real(req):
        return httpx.Response(200, html="<html><title>Empresa</title><body>" + "Conteúdo institucional. " * 30 + "</body></html>")

    def parked(req):
        return httpx.Response(200, html="<html><body>This domain is for sale</body></html>")

    def down(req):
        raise httpx.ConnectError("sem DNS")

    assert check_domain("a.com.br", _client(real)).status == "site_ok"
    assert check_domain("a.com.br", _client(parked)).status == "site_fraco"
    # sem resposta só vira "sem site" quando o DNS prova que o domínio não existe
    assert check_domain("a.com.br", _client(down), resolver=lambda d: True).status == "sem_site"
    assert check_domain("a.com.br", _client(down), resolver=lambda d: False).status == "inconclusivo"

    def slow(req):
        raise httpx.ReadTimeout("lento")

    assert check_domain("a.com.br", _client(slow), resolver=lambda d: False).status == "inconclusivo"
    # bloqueio de robôs e erro de servidor não provam ausência de site
    assert check_domain("a.com.br", _client(lambda r: httpx.Response(403))).status == "inconclusivo"
    assert check_domain("a.com.br", _client(lambda r: httpx.Response(500))).status == "inconclusivo"
    # hospedagem sem página publicada
    assert check_domain("a.com.br", _client(lambda r: httpx.Response(404))).status == "site_fraco"


def test_enriquecimento_pontua_oportunidade_digital(fresh_db, tmp_path):
    root = tmp_path / "rf"
    build_competence(root, "2026-10")
    with FakeRF(root) as rf:
        assert run_import(make_worker(fresh_db, rf.url, tmp_path))["status"] == "concluido"
    antes = q(fresh_db, "select score from leads where cnpj_basico = '11222333'")[0]["score"]

    def checker(dom):
        return {"padaria.com.br": CheckResult("sem_site", None, None, "ConnectError"),
                "alfa.com": CheckResult("site_ok", 200, "https://alfa.com/")}[dom]

    stats = Enricher(fresh_db, checker=checker).run()
    assert stats["sem_site"] == 1 and stats["site_ok"] == 1

    padaria = q(fresh_db, "select score, digital_presence, website from leads where cnpj_basico = '11222333'")[0]
    assert padaria["digital_presence"]["status"] == "sem_site"
    assert padaria["score"] == antes + 30  # oportunidade digital efetivamente identificada
    alfa = q(fresh_db, "select website, digital_presence from leads where cnpj_basico = '12ABC345'")[0]
    assert alfa["website"] == "https://alfa.com/" and alfa["digital_presence"]["status"] == "site_ok"
    # segunda rodada não verifica de novo
    assert Enricher(fresh_db, checker=checker).run()["verificados"] == 0
    # não gera evento de pontuação por lead (carga em massa)
    assert not q(fresh_db, "select 1 from lead_events where event_type = 'pontuacao_alterada'")


def test_dominio_de_contador_nao_conta_como_site_da_empresa(fresh_db, tmp_path):
    root = tmp_path / "rf"
    build_competence(root, "2026-10")
    with FakeRF(root) as rf:
        run_import(make_worker(fresh_db, rf.url, tmp_path))
    q(fresh_db, "update establishments set email = 'abertura@silvacontabilidade.com.br' where cnpj_basico = '11222333' returning 1")

    def checker(dom):
        assert "contab" not in dom, "não deveria acessar o site do contador"
        return CheckResult("site_ok", 200, f"https://{dom}/")

    Enricher(fresh_db, checker=checker).run()
    dp = q(fresh_db, "select digital_presence from leads where cnpj_basico = '11222333'")[0]["digital_presence"]
    assert dp["status"] == "dominio_compartilhado"
