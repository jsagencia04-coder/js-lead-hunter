-- =====================================================================
-- JS Lead Hunter — Etapa 2 — Inteligência comercial, CRM, mapa e worker
-- =====================================================================

-- ---------------------------------------------------------------------
-- Carga em massa: o worker liga app.bulk_load = 'on' na transação para
-- não gerar uma linha de auditoria por registro importado.
-- ---------------------------------------------------------------------
create or replace function public.is_bulk_load()
returns boolean language sql stable as $$
  select coalesce(current_setting('app.bulk_load', true), '') = 'on'
$$;

create or replace function public.audit_trigger()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  rec_id text;
begin
  if public.is_bulk_load() then
    return coalesce(new, old);
  end if;
  rec_id := coalesce(
    to_jsonb(coalesce(new, old)) ->> 'id',
    to_jsonb(coalesce(new, old)) ->> 'key',
    to_jsonb(coalesce(new, old)) ->> 'cnpj_basico');
  insert into public.audit_logs (actor_id, action, table_name, record_id, old_data, new_data)
  values (
    auth.uid(), tg_op, tg_table_name, rec_id,
    case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end);
  return coalesce(new, old);
end $$;

-- Recálculo em massa de pontuação não polui o histórico do lead
create or replace function public.leads_track_changes()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into public.lead_events (lead_id, event_type, to_stage, actor_id, metadata)
    values (new.id, 'criado', new.stage, auth.uid(),
            jsonb_build_object('source', new.source, 'import_job_id', new.import_job_id));
    return new;
  end if;

  if new.stage is distinct from old.stage then
    insert into public.lead_events (lead_id, event_type, from_stage, to_stage, actor_id)
    values (new.id, 'mudanca_etapa', old.stage, new.stage, auth.uid());
  end if;
  if new.owner_id is distinct from old.owner_id then
    insert into public.lead_events (lead_id, event_type, actor_id, metadata)
    values (new.id, 'responsavel_alterado', auth.uid(),
            jsonb_build_object('de', old.owner_id, 'para', new.owner_id));
  end if;
  if new.score is distinct from old.score and not public.is_bulk_load() then
    insert into public.lead_events (lead_id, event_type, actor_id, metadata)
    values (new.id, 'pontuacao_alterada', auth.uid(),
            jsonb_build_object('de', old.score, 'para', new.score));
  end if;
  if new.next_follow_up_at is distinct from old.next_follow_up_at and new.next_follow_up_at is not null then
    insert into public.lead_events (lead_id, event_type, scheduled_for, actor_id)
    values (new.id, 'follow_up_agendado', new.next_follow_up_at, auth.uid());
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------------
-- Validação de CNPJ (numérico e alfanumérico).
-- Valor de cada caractere = código ASCII - 48 (0-9 → 0-9, A → 17 ... Z → 42).
-- ---------------------------------------------------------------------
create or replace function public.cnpj_is_valid(p text)
returns boolean language plpgsql immutable parallel safe as $$
declare
  w1 int[] := array[5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2];
  w2 int[] := array[6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2];
  s int := 0;
  d1 int;
  d2 int;
  i int;
begin
  if p is null or p !~ '^[0-9A-Z]{12}[0-9]{2}$' or p ~ '^(.)\1{13}$' then
    return false;
  end if;
  for i in 1..12 loop
    s := s + (ascii(substr(p, i, 1)) - 48) * w1[i];
  end loop;
  d1 := case when s % 11 < 2 then 0 else 11 - s % 11 end;
  s := 0;
  for i in 1..12 loop
    s := s + (ascii(substr(p, i, 1)) - 48) * w2[i];
  end loop;
  s := s + d1 * w2[13];
  d2 := case when s % 11 < 2 then 0 else 11 - s % 11 end;
  return substr(p, 13, 1)::int = d1 and substr(p, 14, 1)::int = d2;
end $$;

-- ---------------------------------------------------------------------
-- Pontuação de leads (0 a 100) a partir de scoring_rules.
-- Compatibilidade de CNAE usa só regras específicas (prefixo ≠ '*').
-- Oportunidade digital só pontua com enriquecimento real
-- (digital_presence.status = 'sem_site' ou 'site_fraco').
-- ---------------------------------------------------------------------
create or replace function public.recalculate_lead_scores(
  p_lead_ids uuid[] default null,
  p_import_job_id uuid default null,
  p_ref_date date default current_date)
returns integer
language plpgsql security definer set search_path = public as $$
declare
  n integer;
begin
  with r as (
    select key, points, params from public.scoring_rules where active
  ),
  base as (
    select l.id, e.data_inicio_atividade, e.has_phone, e.has_email, e.cnae_principal,
           c.porte, l.digital_presence
      from public.leads l
      join public.establishments e on e.cnpj = l.cnpj
      join public.companies c on c.cnpj_basico = l.cnpj_basico
     where (p_lead_ids is null or l.id = any (p_lead_ids))
       and (p_import_job_id is null or l.import_job_id = p_import_job_id)
  ),
  cnae_best as (
    select b.id, max(cr.relevance) as rel
      from base b
      join public.cnae_service_rules cr
        on cr.active and cr.cnae_prefix <> '*' and b.cnae_principal like cr.cnae_prefix || '%'
      join public.service_catalog s on s.id = cr.service_id and s.active
     group by b.id
  ),
  calc as (
    select b.id, jsonb_strip_nulls(jsonb_build_object(
      'recencia', (select case
                     when b.data_inicio_atividade is null then 0
                     when p_ref_date - b.data_inicio_atividade <= coalesce((r.params ->> 'dias_integral')::int, 30) then r.points
                     when p_ref_date - b.data_inicio_atividade <= coalesce((r.params ->> 'dias_metade')::int, 90) then round(r.points / 2.0)
                     else 0 end
                     from r where r.key = 'recencia'),
      'telefone', (select case when b.has_phone then r.points else 0 end from r where r.key = 'telefone'),
      'email',    (select case when b.has_email then r.points else 0 end from r where r.key = 'email'),
      'cnae_compativel', (select round(r.points * coalesce(cb.rel, 0) / 100.0) from r where r.key = 'cnae_compativel'),
      'porte',    (select least(r.points, coalesce((r.params ->> coalesce(b.porte, '00'))::int, 0))
                     from r where r.key = 'porte'),
      'oportunidade_digital', (select case when b.digital_presence ->> 'status' in ('sem_site', 'site_fraco')
                                           then r.points else 0 end
                                 from r where r.key = 'oportunidade_digital')
    )) as breakdown
    from base b
    left join cnae_best cb on cb.id = b.id
  )
  update public.leads l
     set score = least(100, (select coalesce(sum(v::numeric), 0) from jsonb_each_text(c.breakdown) as t(k, v)))::smallint,
         score_breakdown = c.breakdown
    from calc c
   where c.id = l.id
     and l.score_breakdown is distinct from c.breakdown;
  get diagnostics n = row_count;
  return n;
end $$;

-- Recomendações: para cada serviço ativo, vale a regra de prefixo mais longo.
create or replace function public.rebuild_lead_recommendations(
  p_lead_ids uuid[] default null,
  p_import_job_id uuid default null)
returns integer
language plpgsql security definer set search_path = public as $$
declare
  n integer;
begin
  delete from public.lead_recommendations lr
   using public.leads l
   where l.id = lr.lead_id
     and (p_lead_ids is null or l.id = any (p_lead_ids))
     and (p_import_job_id is null or l.import_job_id = p_import_job_id);

  insert into public.lead_recommendations (lead_id, service_id, rule_id, relevance, reason)
  select distinct on (l.id, cr.service_id)
         l.id, cr.service_id, cr.id, cr.relevance, cr.reason
    from public.leads l
    join public.establishments e on e.cnpj = l.cnpj
    join public.cnae_service_rules cr
      on cr.active and (cr.cnae_prefix = '*' or e.cnae_principal like cr.cnae_prefix || '%')
    join public.service_catalog s on s.id = cr.service_id and s.active
   where (p_lead_ids is null or l.id = any (p_lead_ids))
     and (p_import_job_id is null or l.import_job_id = p_import_job_id)
   order by l.id, cr.service_id,
            case when cr.cnae_prefix = '*' then 0 else length(cr.cnae_prefix) end desc;
  get diagnostics n = row_count;
  return n;
end $$;

revoke all on function public.recalculate_lead_scores(uuid[], uuid, date) from public, anon, authenticated;
revoke all on function public.rebuild_lead_recommendations(uuid[], uuid) from public, anon, authenticated;

-- Recálculo disparado pela interface (admin), após editar regras
create or replace function public.admin_recalculate_leads()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  scores integer;
  recs integer;
begin
  if not public.has_role(array['admin']::public.app_role[]) then
    raise exception 'Apenas administradores podem recalcular a pontuação';
  end if;
  perform set_config('app.bulk_load', 'on', true);
  scores := public.recalculate_lead_scores();
  recs := public.rebuild_lead_recommendations();
  insert into public.audit_logs (actor_id, action, table_name, record_id, new_data)
  values (auth.uid(), 'UPDATE', 'leads', 'recalculo_geral',
          jsonb_build_object('pontuacoes_alteradas', scores, 'recomendacoes', recs));
  return jsonb_build_object('pontuacoes_alteradas', scores, 'recomendacoes', recs);
end $$;
revoke all on function public.admin_recalculate_leads() from public, anon;
grant execute on function public.admin_recalculate_leads() to authenticated;

-- ---------------------------------------------------------------------
-- Criação automática de leads (chamada pelo worker, service_role)
-- Regras: CNPJ válido, ativa (02), matriz, data de início válida dentro
-- do período, sem bloqueio de contato e sem lead existente.
-- ---------------------------------------------------------------------
create or replace function public.worker_create_leads(
  p_import_job_id uuid,
  p_from date,
  p_to date,
  p_include_branches boolean default false)
returns integer
language plpgsql security definer set search_path = public as $$
declare
  n integer;
begin
  insert into public.leads (cnpj_basico, cnpj, source, import_job_id)
  select distinct on (e.cnpj_basico) e.cnpj_basico, e.cnpj, 'importacao', p_import_job_id
    from public.establishments e
   where e.situacao_cadastral = '02'
     and (e.identificador_matriz = 1 or p_include_branches)
     and e.data_inicio_atividade between p_from and p_to
     and public.cnpj_is_valid(e.cnpj)
     and not exists (select 1 from public.contact_suppressions s where s.cnpj_basico = e.cnpj_basico)
     and not exists (select 1 from public.leads l where l.cnpj_basico = e.cnpj_basico)
   order by e.cnpj_basico, e.identificador_matriz, e.cnpj
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.worker_create_leads(uuid, date, date, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Mapa: contagem por estado
-- ---------------------------------------------------------------------
create or replace function public.map_state_counts(p_days integer default 90, p_ref_date date default current_date)
returns table (uf text, empresas bigint, leads bigint, leads_alta bigint)
language sql stable security invoker set search_path = public as $$
  select e.uf::text,
         count(*) filter (where e.data_inicio_atividade > p_ref_date - p_days),
         count(l.id),
         count(l.id) filter (where l.priority = 'alta')
    from public.establishments e
    left join public.leads l on l.cnpj = e.cnpj
   where e.identificador_matriz = 1
     and e.situacao_cadastral = '02'
     and e.uf is not null
   group by e.uf
$$;
revoke all on function public.map_state_counts(integer, date) from public, anon;
grant execute on function public.map_state_counts(integer, date) to authenticated;

-- ---------------------------------------------------------------------
-- CRM: contagem por etapa com os mesmos filtros do quadro
-- ---------------------------------------------------------------------
create or replace function public.crm_stage_counts(
  p_owner uuid default null,
  p_unassigned boolean default false,
  p_uf text default null,
  p_priority text default null)
returns table (stage public.lead_stage, total bigint)
language sql stable security invoker set search_path = public as $$
  select l.stage, count(*)
    from public.leads l
    join public.establishments e on e.cnpj = l.cnpj
   where (p_owner is null or l.owner_id = p_owner)
     and (not p_unassigned or l.owner_id is null)
     and (p_uf is null or e.uf = p_uf)
     and (p_priority is null or l.priority = p_priority)
   group by l.stage
$$;
revoke all on function public.crm_stage_counts(uuid, boolean, text, text) from public, anon;
grant execute on function public.crm_stage_counts(uuid, boolean, text, text) to authenticated;

-- Índice para listagem de municípios por UF no mapa
create index if not exists establishments_mun_ativa_idx
  on public.establishments (municipio_code)
  where identificador_matriz = 1 and situacao_cadastral = '02';
