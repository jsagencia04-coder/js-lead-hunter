-- Testes de comportamento. Cada bloco falha (exception) se a regra não for respeitada.
-- Os registros abaixo são SINTÉTICOS e existem apenas neste banco de teste.
\set ON_ERROR_STOP 1

create or replace function pg_temp.expect_error(sql text, label text) returns void language plpgsql as $$
begin
  begin
    execute sql;
  exception when others then
    raise notice 'ok (bloqueado): %', label;
    return;
  end;
  raise exception 'FALHA: deveria ter bloqueado: %', label;
end $$;

create or replace function pg_temp.assert(cond boolean, label text) returns void language plpgsql as $$
begin
  if cond is not true then raise exception 'FALHA: %', label; end if;
  raise notice 'ok: %', label;
end $$;

-- ---------------- Validação de CNPJ ----------------
select pg_temp.assert(public.cnpj_is_valid('11222333000181'), 'CNPJ numérico válido');
select pg_temp.assert(not public.cnpj_is_valid('11222333000182'), 'CNPJ com DV errado é inválido');
select pg_temp.assert(public.cnpj_is_valid('12ABC34501DE35'), 'CNPJ alfanumérico válido (exemplo oficial)');
select pg_temp.assert(not public.cnpj_is_valid('00000000000000'), 'sequência repetida é inválida');

-- ---------------- Usuários e papéis ----------------
insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'admin@teste.local'),
  ('22222222-2222-2222-2222-222222222222', 'vendas@teste.local');
select pg_temp.assert((select role = 'admin' from profiles where email = 'admin@teste.local'), 'primeiro usuário é admin');
select pg_temp.assert((select role = 'leitura' from profiles where email = 'vendas@teste.local'), 'segundo usuário é leitura');

-- ---------------- Dados cadastrais sintéticos (como o worker faria) ----------------
insert into municipalities (code, name, uf) values ('7107', 'MUNICIPIO TESTE', 'SP');
insert into cnae_catalog values ('7319002', 'Promoção de vendas', now()), ('4781400', 'Comércio de vestuário', now());
insert into companies (cnpj_basico, razao_social, porte, capital_social) values
  ('11222333', 'EMPRESA TESTE A', '01', 1000), ('99999999', 'EMPRESA TESTE BLOQ', '03', 5),
  ('12ABC345', 'EMPRESA TESTE ALFA', '05', 50000);
insert into establishments (cnpj, cnpj_basico, cnpj_ordem, cnpj_dv, identificador_matriz, situacao_cadastral,
                            data_inicio_atividade, cnae_principal, uf, municipio_code, telefone1, email, source_competence)
values ('11222333000181', '11222333', '0001', '81', 1, '02', current_date - 5,  '4781400', 'SP', '7107', '12345678', 'a@b.com', '2026-11'),
       ('99999999000191', '99999999', '0001', '91', 1, '02', current_date - 10, '7319002', 'SP', '7107', null, null, '2026-11'),
       ('12ABC34501DE35', '12ABC345', '01DE', '35', 1, '02', current_date - 60, '7319002', 'SP', '7107', null, 'x@y.com', '2026-11');

-- ---------------- Usuário de leitura ----------------
set role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', false);
select pg_temp.expect_error($$update profiles set role = 'admin' where id = auth.uid()$$, 'leitura se promover a admin');
select pg_temp.expect_error($$insert into leads (cnpj_basico, cnpj) values ('11222333', '11222333000181')$$, 'leitura criar lead');
select pg_temp.expect_error($$select request_import()$$, 'leitura solicitar importação');
select pg_temp.expect_error($$select admin_recalculate_leads()$$, 'leitura recalcular pontuação');
select pg_temp.expect_error($$select worker_create_leads(null, '2000-01-01', '2100-01-01')$$, 'cliente chamar função do worker');
reset role;

-- ---------------- Admin ----------------
set role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
insert into contact_suppressions (cnpj_basico, reason, created_by) values ('99999999', 'pedido do titular', auth.uid());
reset role;

-- ---------------- Worker (service_role) cria leads ----------------
set role service_role;
insert into import_jobs (id, job_type, competence, status) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'importacao', '2026-11', 'processando');
select set_config('app.bulk_load', 'on', false);
select pg_temp.assert(
  worker_create_leads('aaaaaaaa-0000-0000-0000-000000000001', current_date - 90, current_date) = 2,
  'worker cria 2 leads (bloqueada fica de fora)');
select pg_temp.assert(
  worker_create_leads('aaaaaaaa-0000-0000-0000-000000000001', current_date - 90, current_date) = 0,
  'rodar de novo não duplica (idempotente)');
select recalculate_lead_scores(p_import_job_id => 'aaaaaaaa-0000-0000-0000-000000000001');
select rebuild_lead_recommendations(p_import_job_id => 'aaaaaaaa-0000-0000-0000-000000000001');
select set_config('app.bulk_load', '', false);
reset role;

-- varejo (CNAE 47): recência 15 + telefone 5 + e-mail 5 + porte 6 + CNAE 80% de 35 = 59
select pg_temp.assert((select score = 59 from leads where cnpj_basico = '11222333'), 'pontuação calculada (59)');
select pg_temp.assert((select priority = 'media' from leads where cnpj_basico = '11222333'), 'prioridade média sem oportunidade digital');
-- publicidade (CNAE 73), 60 dias: recência 8 + e-mail 5 + porte 8 + CNAE 85% de 35 = 51
select pg_temp.assert((select score = 51 from leads where cnpj_basico = '12ABC345'), 'pontuação do CNPJ alfanumérico (51)');
select pg_temp.assert((select count(*) = 10 from lead_recommendations), 'recomendações gerais + específicas por CNAE');
select pg_temp.assert((select count(*) = 0 from audit_logs where table_name = 'leads'), 'carga em massa não gera auditoria linha a linha');
select pg_temp.assert((select count(*) = 2 from lead_events where event_type = 'criado'), 'histórico registra criação');

-- Regra específica de CNAE muda pontuação após recálculo
set role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
update cnae_service_rules set relevance = 100
 where cnae_prefix = '47' and service_id = (select id from service_catalog where code = 'site_institucional');
select admin_recalculate_leads();
select pg_temp.assert((select score = 66 from leads where cnpj_basico = '11222333'), 'regra editada pelo admin muda a pontuação (66)');
update leads set digital_presence = '{"status": "sem_site"}' where cnpj_basico = '11222333';
select admin_recalculate_leads();
select pg_temp.assert((select score = 96 from leads where cnpj_basico = '11222333'), 'oportunidade digital verificada soma 30 (96)');
select pg_temp.assert((select priority = 'alta' from leads where cnpj_basico = '11222333'), 'prioridade alta com oportunidade digital');
select pg_temp.assert(
  (select relevance = 100 from lead_recommendations lr join service_catalog s on s.id = lr.service_id
    join leads l on l.id = lr.lead_id where s.code = 'site_institucional' and l.cnpj_basico = '11222333'),
  'regra mais específica prevalece na recomendação');

-- CRM
update leads set stage = 'pronto_contato', owner_id = auth.uid() where cnpj_basico = '11222333';
insert into lead_events (lead_id, event_type, channel, content, actor_id)
select id, 'contato', 'telefone', 'Primeira ligação', auth.uid() from leads where cnpj_basico = '11222333';
select pg_temp.expect_error(
  $$insert into lead_events (lead_id, event_type, actor_id) select id, 'mudanca_etapa', auth.uid() from leads limit 1$$,
  'cliente forjar evento de sistema');
select pg_temp.assert((select total = 1 from crm_stage_counts() where stage = 'pronto_contato'), 'contagem do Kanban');
select pg_temp.assert((select leads = 2 from map_state_counts() where uf = 'SP'), 'contagem do mapa');
select pg_temp.assert(((dashboard_metrics('SP', current_date, '7107') ->> 'leads_alta')::int = 1), 'dashboard filtrado por município');
select pg_temp.assert((select count(*) >= 3 from lead_events l join leads x on x.id = l.lead_id
                        where x.cnpj_basico = '11222333'), 'movimentações registradas no histórico');
reset role;

-- Anônimo não lê nada
set role anon;
select pg_temp.expect_error($$select count(*) from establishments$$, 'anônimo ler estabelecimentos');
select pg_temp.expect_error($$select count(*) from leads$$, 'anônimo ler leads');
reset role;

-- Data de referência da competência vigente
update import_jobs set status = 'concluido', is_current = true, reference_date = current_date - 30
 where id = 'aaaaaaaa-0000-0000-0000-000000000001';
set role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
select pg_temp.assert((dashboard_metrics() ->> 'data_referencia')::date = current_date - 30, 'dashboard usa a data de referência da base');
select pg_temp.assert((select count(*) from map_state_counts(7)) = 1, 'mapa usa a data de referência da base');
select pg_temp.assert((admin_recalculate_leads() ->> 'recomendacoes')::int >= 0, 'recálculo com data de referência');
reset role;

-- =====================================================================
-- Migration 011 — operação comercial
-- =====================================================================
select pg_temp.assert((select not active from profiles where email = 'vendas@teste.local'),
  'usuário que se cadastra sozinho entra inativo');

-- Comercial ativo
insert into auth.users (id, email) values ('33333333-3333-3333-3333-333333333333', 'comercial@teste.local');
update profiles set role = 'comercial', active = true where email = 'comercial@teste.local';
set role authenticated;
select set_config('request.jwt.claim.sub', '33333333-3333-3333-3333-333333333333', false);
select pg_temp.expect_error($$update leads set score = 100 where cnpj_basico = '12ABC345'$$, 'comercial alterar pontuação');
select pg_temp.expect_error($$update leads set digital_presence = '{"status":"sem_site"}' where cnpj_basico = '12ABC345'$$,
  'comercial forjar presença digital');
update leads set stage = 'primeiro_contato', website = 'https://exemplo.local' where cnpj_basico = '12ABC345';
select pg_temp.assert((select stage = 'primeiro_contato' from leads where cnpj_basico = '12ABC345'), 'comercial move etapa e edita site');

-- Resposta recebida e proposta
insert into lead_events (lead_id, event_type, channel, content, actor_id)
select id, 'resposta_recebida', 'whatsapp', 'Pediu orçamento', auth.uid() from leads where cnpj_basico = '12ABC345';
insert into lead_proposals (lead_id, title, amount, status, created_by)
select id, 'Site institucional', 2500, 'enviada', auth.uid() from leads where cnpj_basico = '12ABC345';
select pg_temp.assert((select stage = 'proposta_enviada' from leads where cnpj_basico = '12ABC345'),
  'proposta enviada avança a etapa');
select pg_temp.assert((select sent_at is not null from lead_proposals limit 1), 'data de envio registrada');
select pg_temp.assert((select count(*) = 1 from lead_events where event_type = 'proposta'), 'proposta registrada no histórico');
update lead_proposals set status = 'em_negociacao';
select pg_temp.assert((select stage = 'em_negociacao' from leads where cnpj_basico = '12ABC345'), 'negociação avança a etapa');
update leads set stage = 'convertido' where cnpj_basico = '12ABC345';
update lead_proposals set status = 'aceita';
select pg_temp.assert((select stage = 'convertido' and converted_at is not null from leads where cnpj_basico = '12ABC345'),
  'proposta não rebaixa lead convertido');
select pg_temp.assert((select decided_at is not null from lead_proposals limit 1), 'data de decisão registrada');
delete from lead_proposals;
select pg_temp.assert((select count(*) = 1 from lead_proposals), 'comercial não exclui proposta (só admin)');

-- Indicadores comerciais
select pg_temp.assert((commercial_metrics() ->> 'propostas_enviadas')::int = 1, 'indicador: propostas enviadas');
select pg_temp.assert((commercial_metrics() ->> 'respostas_recebidas')::int >= 1, 'indicador: respostas recebidas');
select pg_temp.assert((commercial_metrics() ->> 'clientes_convertidos')::int = 1, 'indicador: convertidos');
select pg_temp.assert((commercial_metrics() ->> 'taxa_conversao')::numeric = 50.0, 'indicador: taxa de conversão (1 de 2 contatados)');
select pg_temp.assert(jsonb_array_length(commercial_metrics() -> 'por_servico') >= 1, 'indicador: desempenho por serviço');
select pg_temp.assert(jsonb_array_length(commercial_metrics() -> 'por_responsavel') >= 1, 'indicador: desempenho por responsável');

-- Diagnóstico individual
select pg_temp.assert(
  (select bool_or(o ->> 'tipo' = 'site') from jsonb_array_elements(
     lead_diagnosis((select id from leads where cnpj_basico = '11222333')) -> 'oportunidades') o),
  'diagnóstico aponta site quando a ausência foi verificada');
select pg_temp.assert(
  (select not coalesce(bool_or(o ->> 'tipo' = 'site'), false) from jsonb_array_elements(
     lead_diagnosis((select id from leads where cnpj_basico = '12ABC345')) -> 'oportunidades') o),
  'diagnóstico não afirma ausência de site sem verificação');
select pg_temp.assert(
  (select reason like 'Verificado:%' from lead_recommendations lr join service_catalog s on s.id = lr.service_id
    join leads l on l.id = lr.lead_id where s.code = 'site_institucional' and l.cnpj_basico = '11222333'),
  'recomendação de site registra o motivo verificado');
reset role;

-- Bloqueio impede registrar contato
set role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
insert into contact_suppressions (cnpj_basico, reason, created_by) values ('11222333', 'pediu para não ser contatado', auth.uid());
select pg_temp.expect_error(
  $$insert into lead_events (lead_id, event_type, channel, content, actor_id)
    select id, 'contato', 'telefone', 'x', auth.uid() from leads where cnpj_basico = '11222333'$$,
  'registrar contato com empresa bloqueada');
reset role;

-- Empresa arquivada não volta como lead novo
insert into companies (cnpj_basico, razao_social) values ('44555666', 'EMPRESA TESTE ARQUIVADA');
do $$
declare base text := '445556660001'; s int := 0; d1 int; d2 int; w1 int[] := array[5,4,3,2,9,8,7,6,5,4,3,2];
        w2 int[] := array[6,5,4,3,2,9,8,7,6,5,4,3,2]; i int;
begin
  for i in 1..12 loop s := s + (ascii(substr(base, i, 1)) - 48) * w1[i]; end loop;
  d1 := case when s % 11 < 2 then 0 else 11 - s % 11 end; s := 0;
  for i in 1..12 loop s := s + (ascii(substr(base, i, 1)) - 48) * w2[i]; end loop;
  s := s + d1 * 2; d2 := case when s % 11 < 2 then 0 else 11 - s % 11 end;
  insert into establishments (cnpj, cnpj_basico, cnpj_ordem, cnpj_dv, identificador_matriz, situacao_cadastral,
                              data_inicio_atividade, cnae_principal, uf, municipio_code, source_competence)
  values (base || d1 || d2, '44555666', '0001', d1::text || d2::text, 1, '02', current_date - 3, '4781400', 'SP', '7107', '2026-11');
end $$;
insert into lead_archive (cnpj, cnpj_basico, razao_social, motivo) values ('44555666000100', '44555666', 'EMPRESA TESTE ARQUIVADA', 'teste');
set role service_role;
select pg_temp.assert(
  worker_create_leads('aaaaaaaa-0000-0000-0000-000000000001', current_date - 90, current_date) = 0,
  'empresa arquivada não é recriada como lead (sem duplicidade)');
delete from lead_archive where cnpj_basico = '44555666';
select pg_temp.assert(
  worker_create_leads('aaaaaaaa-0000-0000-0000-000000000001', current_date - 90, current_date) = 1,
  'mesma empresa vira lead quando não está no arquivo');
select pg_temp.assert(archive_candidates_count(true) >= 1, 'estimativa de arquivamento sem apagar nada');
reset role;

-- =====================================================================
-- Migration 012 — preservação dos dados
-- =====================================================================
select pg_temp.assert((select not (value ->> 'ativo')::boolean and not (value ->> 'liberar_espaco_na_importacao')::boolean
                         from app_settings where key = 'arquivamento'), 'arquivamento automático desligado');
select pg_temp.assert((select count(*) >= 1 from data_inventory_snapshots), 'inventário registrado na migration');

-- Histórico cadastral
update establishments set telefone1 = '99998888' where cnpj = '11222333000181';
select pg_temp.assert((select changes -> 'telefone1' ->> 'para' = '99998888' from registry_changes
                        where key = '11222333000181' order by id desc limit 1), 'alteração cadastral registrada com de/para');
update establishments set telefone1 = '99998888' where cnpj = '11222333000181';
select pg_temp.assert((select count(*) = 1 from registry_changes where key = '11222333000181'), 'atualização sem mudança não gera histórico');

-- Restauração de arquivados
insert into lead_archive (cnpj, cnpj_basico, razao_social, motivo) values ('44555666000100', '44555666', 'X', 'teste');
set role authenticated;
select set_config('request.jwt.claim.sub', '33333333-3333-3333-3333-333333333333', false);
select pg_temp.expect_error($$select request_archive_restore(null, true)$$, 'comercial solicitar restauração');
select pg_temp.expect_error($$select take_inventory_snapshot('x')$$, 'comercial registrar inventário');
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
select pg_temp.expect_error($$select request_archive_restore()$$, 'restauração sem CNPJs nem confirmação');
select pg_temp.assert(request_archive_restore(array['44555666000100']) = 1, 'admin solicita restauração');
reset role;
set role service_role;
select pg_temp.assert(exists (select 1 from worker_restore_targets() t where t = '44555666000100'), 'worker recebe CNPJ a reler');
select worker_restore_archived_leads('aaaaaaaa-0000-0000-0000-000000000001');
select pg_temp.assert((select restored_at is not null and restore_note = 'Empresa já estava na base operacional'
                         from lead_archive where cnpj = '44555666000100'), 'empresa que já tem lead é marcada sem duplicar');
select pg_temp.assert((select count(*) = 1 from leads where cnpj_basico = '44555666'), 'sem lead duplicado');
reset role;

-- restauração completa: lead arquivado cujo cadastro volta pela importação
delete from leads where cnpj_basico = '44555666';
update lead_archive set restored_at = null, restored_lead_id = null, restore_note = null,
       restore_requested_at = now(), cnpj = (select cnpj from establishments where cnpj_basico = '44555666')
 where cnpj_basico = '44555666';
set role service_role;
select pg_temp.assert(worker_restore_archived_leads('aaaaaaaa-0000-0000-0000-000000000001') = 1, 'lead arquivado restaurado');
reset role;
select pg_temp.assert((select source = 'restaurado' from leads where cnpj_basico = '44555666'), 'origem "restaurado"');
select pg_temp.assert((select restored_lead_id = (select id from leads where cnpj_basico = '44555666')
                         from lead_archive where cnpj_basico = '44555666'), 'arquivo aponta para o lead restaurado');

-- empresa bloqueada não volta
insert into companies (cnpj_basico) values ('77000000');
insert into contact_suppressions (cnpj_basico, reason) values ('77000000', 'pedido do titular');
insert into lead_archive (cnpj, cnpj_basico, motivo, restore_requested_at) values ('77000000000100', '77000000', 't', now());
set role service_role;
select worker_restore_archived_leads('aaaaaaaa-0000-0000-0000-000000000001');
reset role;
select pg_temp.assert((select restored_at is null and restore_note like 'Empresa bloqueada%' from lead_archive
                        where cnpj_basico = '77000000'), 'bloqueio preservado na restauração');
select pg_temp.assert((data_inventory() ->> 'bloqueios')::int = 3, 'inventário conta bloqueios');
