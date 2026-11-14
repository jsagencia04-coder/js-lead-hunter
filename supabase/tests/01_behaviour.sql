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

-- pontos: recência 25 + telefone 15 + e-mail 15 + porte 6 = 61 (sem regra específica de CNAE)
select pg_temp.assert((select score = 61 from leads where cnpj_basico = '11222333'), 'pontuação calculada (61)');
select pg_temp.assert((select priority = 'media' from leads where cnpj_basico = '11222333'), 'prioridade média');
-- alfanumérico: 60 dias → metade da recência (13) + e-mail 15 + porte 8 = 36
select pg_temp.assert((select score = 36 from leads where cnpj_basico = '12ABC345'), 'pontuação do CNPJ alfanumérico (36)');
select pg_temp.assert((select count(*) = 6 from lead_recommendations), '3 recomendações gerais por lead');
select pg_temp.assert((select count(*) = 0 from audit_logs where table_name = 'leads'), 'carga em massa não gera auditoria linha a linha');
select pg_temp.assert((select count(*) = 2 from lead_events where event_type = 'criado'), 'histórico registra criação');

-- Regra específica de CNAE muda pontuação após recálculo
set role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
insert into cnae_service_rules (cnae_prefix, service_id, relevance, reason)
select '47', id, 100, 'Varejo precisa de presença digital' from service_catalog where code = 'site_institucional';
select admin_recalculate_leads();
select pg_temp.assert((select score = 81 from leads where cnpj_basico = '11222333'), 'regra de CNAE soma 20 pontos (81)');
select pg_temp.assert((select priority = 'alta' from leads where cnpj_basico = '11222333'), 'prioridade alta após regra');
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
