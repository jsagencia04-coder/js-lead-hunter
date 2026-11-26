"""Fase 1 da 2.0: preservação dos dados, restauração de arquivados e backup verificável."""
import json

from lead_hunter import backup as bk

from .fake_rf import FakeRF, build_competence, est_row
from .test_pipeline import make_worker, q, run_import


def _import(db, root, tmp_path, competence="2026-10", **kw):
    build_competence(root, competence, **kw)
    with FakeRF(root) as rf:
        return run_import(make_worker(db, rf.url, tmp_path), competence)


def test_reimportacao_atualiza_cadastro_sem_perder_historico(fresh_db, tmp_path):
    root = tmp_path / "rf"
    assert _import(fresh_db, root, tmp_path)["status"] == "concluido"
    lead = q(fresh_db, "select id from leads where cnpj_basico = '11222333'")[0]["id"]
    q(fresh_db, "insert into lead_events (lead_id, event_type, content) values (%s, 'anotacao', 'cliente quente') returning 1", lead)
    q(fresh_db, "update leads set stage = 'interessado' where id = %s returning 1", lead)

    # nova competência: a padaria trocou de telefone
    import shutil
    shutil.rmtree(root / "2026-10")
    job = _import(fresh_db, root, tmp_path, "2026-11",
                  extra_est=[est_row("11222333", fantasia="PADARIA SÃO JOÃO", tel="933334444",
                                     email="CONTATO@PADARIA.COM.BR")])
    assert job["status"] == "concluido", job["errors"]
    depois = q(fresh_db, "select id, stage from leads where cnpj_basico = '11222333'")
    assert len(depois) == 1 and depois[0]["id"] == lead and depois[0]["stage"] == "interessado"
    assert q(fresh_db, "select 1 from lead_events where lead_id = %s and content = 'cliente quente'", lead)
    mud = q(fresh_db, "select changes from registry_changes where key like '11222333%%' and entity = 'estabelecimento'")
    assert any(c["changes"].get("telefone1", {}).get("para") == "933334444" for c in mud)


def test_arquivado_restaurado_com_cadastro_completo(fresh_db, tmp_path):
    from lead_hunter.archive import run_scheduled

    root = tmp_path / "rf"
    assert _import(fresh_db, root, tmp_path)["status"] == "concluido"
    # simula o arquivamento antigo (política anterior à 2.0)
    q(fresh_db, "update leads set created_at = now() - interval '90 days' returning 1")
    q(fresh_db, """update app_settings set value = value || '{"ativo": true}' where key = 'arquivamento' returning 1""")
    assert run_scheduled(fresh_db)["leads"] >= 1
    assert not q(fresh_db, "select 1 from establishments where cnpj_basico = '11222333'")
    arq = q(fresh_db, "select cnpj from lead_archive where cnpj_basico = '11222333'")[0]["cnpj"]

    # reimportar sem pedido: continua arquivada (sem duplicidade)
    with FakeRF(root) as rf:
        assert run_import(make_worker(fresh_db, rf.url, tmp_path), "2026-10")["status"] == "concluido"
    assert not q(fresh_db, "select 1 from leads where cnpj_basico = '11222333'")

    # pedido de restauração + reimportação: cadastro completo volta e o lead é recriado
    q(fresh_db, "update lead_archive set restore_requested_at = now() where cnpj = %s returning 1", arq)
    with FakeRF(root) as rf:
        job = run_import(make_worker(fresh_db, rf.url, tmp_path), "2026-10")
    assert job["status"] == "concluido"
    assert job["metadata"]["restored_leads"] == 1
    lead = q(fresh_db, "select * from lead_list_v where cnpj_basico = '11222333'")[0]
    assert lead["nome_fantasia"] == "PADARIA SÃO JOÃO" and lead["telefone1"] == "912345678"
    assert q(fresh_db, "select source from leads where cnpj_basico = '11222333'")[0]["source"] == "restaurado"
    a = q(fresh_db, "select restored_at, restored_lead_id from lead_archive where cnpj = %s", arq)[0]
    assert a["restored_at"] and a["restored_lead_id"] == lead["id"]


def test_sem_espaco_para_com_aviso_e_nao_apaga(fresh_db, tmp_path):
    root = tmp_path / "rf"
    assert _import(fresh_db, root, tmp_path)["status"] == "concluido"
    antes = q(fresh_db, "select count(*) n from leads")[0]["n"]
    build_competence(root, "2026-11", extra_est=[est_row("77888999", fantasia="NOVA")])
    with FakeRF(root) as rf:
        w = make_worker(fresh_db, rf.url, tmp_path)
        object.__setattr__(w.s, "db_size_limit_mb", 1)
        job = run_import(w, "2026-11")
    assert job["status"] == "falhou"
    assert q(fresh_db, "select count(*) n from leads")[0]["n"] == antes
    assert q(fresh_db, "select count(*) n from lead_archive")[0]["n"] == 0
    alerta = q(fresh_db, "select details -> 'alerta_espaco' a from integration_status where key = 'worker'")[0]["a"]
    assert alerta and "Nenhum dado foi apagado" in alerta["mensagem"]


def test_rodada_registra_inventario_antes_e_depois(fresh_db, tmp_path):
    root = tmp_path / "rf"
    build_competence(root, "2026-10")
    n0 = q(fresh_db, "select count(*) n from data_inventory_snapshots")[0]["n"]
    with FakeRF(root) as rf:
        make_worker(fresh_db, rf.url, tmp_path).once()
    snaps = q(fresh_db, "select label, counts from data_inventory_snapshots order by id")
    assert len(snaps) == n0 + 2
    assert snaps[-2]["label"] == "início da rodada" and snaps[-1]["label"] == "fim da rodada"
    assert snaps[-2]["counts"]["leads"] == 0 and snaps[-1]["counts"]["leads"] == 5


def test_backup_verificavel_e_restauravel(fresh_db, empty_db, tmp_path):
    root = tmp_path / "rf"
    assert _import(fresh_db, root, tmp_path)["status"] == "concluido"
    lead = q(fresh_db, "select id from leads limit 1")[0]["id"]
    q(fresh_db, "insert into lead_events (lead_id, event_type, content) values (%s, 'anotacao', 'linha 1\nlinha 2; \"aspas\"') returning 1", lead)

    dest = bk.backup(fresh_db, tmp_path / "bk")
    manifest = json.loads((dest / "manifesto.json").read_text(encoding="utf-8"))
    assert manifest["tabelas"]["leads"]["linhas"] == 5
    assert bk.verify(dest) == []

    # restauração num banco vazio confere tabela por tabela
    res = bk.restore(dest, empty_db)
    assert all(r["restaurado"] == r["esperado"] for r in res.values()), res
    assert q(empty_db, "select content from lead_events where event_type = 'anotacao'")[0]["content"] == 'linha 1\nlinha 2; "aspas"'
    assert q(empty_db, "select has_phone from establishments where cnpj_basico = '11222333' and cnpj like '%%0001%%'")[0]["has_phone"]
    # identidade continua do maior id (novos eventos não colidem)
    q(empty_db, "insert into lead_events (lead_id, event_type, content) values (%s, 'anotacao', 'novo') returning id", lead)

    # nunca sobrescreve uma base com dados
    import pytest
    with pytest.raises(RuntimeError, match="só roda num banco vazio"):
        bk.restore(dest, empty_db)

    # arquivo adulterado é detectado
    with open(dest / "leads.csv.gz", "ab") as fh:
        fh.write(b"x")
    assert any("leads" in p for p in bk.verify(dest))


def test_recalculo_em_lotes_retomavel(fresh_db, tmp_path):
    """Regressão de 26/11/2026: a migration 015 estourou o tempo limite recalculando tudo de uma vez."""
    from lead_hunter.recalc import run_pending

    root = tmp_path / "rf"
    assert _import(fresh_db, root, tmp_path)["status"] == "concluido"
    q(fresh_db, "delete from lead_insights returning 1")
    q(fresh_db, """insert into app_settings (key, value) values ('recalculo_pendente', '{"motivo": "teste"}')
                   on conflict (key) do update set value = excluded.value returning 1""")
    q(fresh_db, "update leads set score = 0 returning 1")
    # interrompido no meio (prazo esgotado) e retomado de onde parou
    import time
    res = run_pending(fresh_db, batch=2, deadline=time.monotonic() - 1)
    assert res and not res["concluido"]
    res = run_pending(fresh_db, batch=2)
    assert res["concluido"] and res["processados"] == 5
    assert not q(fresh_db, "select 1 from app_settings where key = 'recalculo_pendente'")
    assert q(fresh_db, "select count(*) n from lead_insights")[0]["n"] == 5
    assert q(fresh_db, "select min(score) s from leads")[0]["s"] > 0
    assert run_pending(fresh_db) is None
