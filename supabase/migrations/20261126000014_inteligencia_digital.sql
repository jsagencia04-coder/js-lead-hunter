-- =====================================================================
-- JS Lead Hunter 2.0 — Fase 3: motor de inteligência digital
-- Canais digitais por empresa (site, Instagram, Facebook, Perfil no Google,
-- LinkedIn, WhatsApp) com índice de confiança e evidências, fila de
-- enriquecimento independente da importação, cache, limites e custos.
-- Somente alterações ADITIVAS.
-- =====================================================================

create table if not exists public.digital_channels (
  id               uuid primary key default gen_random_uuid(),
  cnpj_basico      text not null check (cnpj_basico ~ '^[0-9A-Z]{8}$'),
  lead_id          uuid references public.leads (id) on delete set null,
  platform         text not null check (platform in ('site', 'instagram', 'facebook', 'google_business', 'linkedin', 'whatsapp')),
  url              text,
  status           text not null default 'pendente' check (status in (
                     'pendente', 'em_processamento', 'verificado', 'possivel', 'nao_localizado', 'inconclusivo', 'erro_temporario')),
  source           text,
  evidence         jsonb not null default '[]'::jsonb,   -- [{"tipo": "...", "detalhe": "...", "peso": n}]
  confidence       smallint not null default 0 check (confidence between 0 and 100),
  result           jsonb not null default '{}'::jsonb,   -- ex.: auditoria técnica do site
  candidates       jsonb not null default '[]'::jsonb,   -- correspondências descartadas ou possíveis
  first_checked_at timestamptz,
  last_checked_at  timestamptz,
  next_check_at    timestamptz,
  manual           boolean not null default false,
  confirmed_by     uuid references public.profiles (id) on delete set null,
  confirmed_at     timestamptz,
  updated_at       timestamptz not null default now(),
  unique (cnpj_basico, platform)
);
create index if not exists digital_channels_lead_idx on public.digital_channels (lead_id);
create index if not exists digital_channels_status_idx on public.digital_channels (platform, status);

create table if not exists public.enrichment_queue (
  cnpj_basico      text primary key check (cnpj_basico ~ '^[0-9A-Z]{8}$'),
  lead_id          uuid references public.leads (id) on delete set null,
  priority         integer not null default 0,
  status           text not null default 'pendente' check (status in ('pendente', 'em_processamento', 'concluido', 'erro')),
  attempts         integer not null default 0,
  next_attempt_at  timestamptz not null default now(),
  locked_by        text,
  locked_at        timestamptz,
  heartbeat_at     timestamptz,
  last_error       text,
  last_run_at      timestamptz,
  requested_by     uuid references public.profiles (id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index if not exists enrichment_queue_next_idx on public.enrichment_queue (priority desc, next_attempt_at)
  where status in ('pendente', 'erro');

create table if not exists public.enrichment_runs (
  id            uuid primary key default gen_random_uuid(),
  started_at    timestamptz not null default now(),
  finished_at   timestamptz,
  heartbeat_at  timestamptz,
  worker_host   text,
  status        text not null default 'executando' check (status in ('executando', 'concluido', 'interrompido', 'pausado', 'falhou')),
  processed     integer not null default 0,
  errors        integer not null default 0,
  found         jsonb not null default '{}'::jsonb,
  calls         jsonb not null default '{}'::jsonb,
  cost_usd      numeric(10, 4) not null default 0,
  checkpoint    jsonb not null default '{}'::jsonb,
  message       text
);
create index if not exists enrichment_runs_started_idx on public.enrichment_runs (started_at desc);

create table if not exists public.provider_usage (
  provider  text not null,
  day       date not null,
  calls     integer not null default 0,
  cost_usd  numeric(10, 4) not null default 0,
  errors    integer not null default 0,
  primary key (provider, day)
);

create table if not exists public.enrichment_cache (
  provider    text not null,
  query_key   text not null,
  response    jsonb not null,
  fetched_at  timestamptz not null default now(),
  primary key (provider, query_key)
);

insert into public.app_settings (key, value, description) values
  ('inteligencia', jsonb_build_object(
     'pausado', false,
     'lote', 150,
     'concorrencia', 8,
     'enfileirar_por_rodada', 2000,
     'cache_dias', 30,
     'limites_diarios', jsonb_build_object('google_places', 300, 'brave', 600),
     'custo_por_consulta_usd', jsonb_build_object('google_places', 0.032, 'brave', 0.005),
     'custo_maximo_diario_usd', 5,
     'reverificar_dias', jsonb_build_object('verificado', 90, 'possivel', 30, 'nao_localizado', 30,
                                            'inconclusivo', 7, 'erro_temporario', 1),
     'confianca_verificado', 70,
     'confianca_possivel', 40),
   'Motor de inteligência digital: pausa, lotes, concorrência, limites de consultas e custos por provedor. '
   || 'Provedores pagos só funcionam com chave configurada no servidor do worker.')
on conflict (key) do nothing;

alter table public.integration_status drop constraint if exists integration_status_key_check;
alter table public.integration_status add constraint integration_status_key_check
  check (key in ('worker', 'storage', 'whatsapp', 'enriquecimento', 'inteligencia', 'google_places', 'brave'));
insert into public.integration_status (key, label, details) values
  ('inteligencia', 'Motor de inteligência digital', '{"descricao": "Fila de pesquisa de site, redes sociais e Perfil no Google"}'),
  ('google_places', 'Google Places API', '{"descricao": "Perfil da Empresa no Google, site e telefone (requer chave GOOGLE_PLACES_API_KEY)"}'),
  ('brave', 'Brave Search API', '{"descricao": "Pesquisa web de site, Instagram, Facebook e LinkedIn (requer chave BRAVE_SEARCH_API_KEY)"}')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------
alter table public.digital_channels enable row level security;
alter table public.enrichment_queue enable row level security;
alter table public.enrichment_runs  enable row level security;
alter table public.provider_usage   enable row level security;
alter table public.enrichment_cache enable row level security;
revoke all on public.digital_channels, public.enrichment_queue, public.enrichment_runs,
              public.provider_usage, public.enrichment_cache from anon;
revoke all on public.enrichment_cache from authenticated;

create policy digital_channels_select on public.digital_channels for select to authenticated using (public.is_active_user());
create policy enrichment_queue_select on public.enrichment_queue for select to authenticated
  using (public.has_role(array['admin', 'gestor']::public.app_role[]));
create policy enrichment_runs_select on public.enrichment_runs for select to authenticated
  using (public.has_role(array['admin', 'gestor']::public.app_role[]));
create policy provider_usage_select on public.provider_usage for select to authenticated
  using (public.has_role(array['admin', 'gestor']::public.app_role[]));

create trigger digital_channels_audit after insert or update or delete on public.digital_channels
  for each row execute function public.audit_trigger();

-- ---------------------------------------------------------------------
-- Fila: prioriza empresas recém-abertas e segmentos compatíveis
-- ---------------------------------------------------------------------
create or replace function public.enqueue_enrichment(p_limit integer default 2000)
returns integer
language plpgsql security definer set search_path = public as $$
declare
  n integer;
  ref date := public.current_reference_date();
begin
  insert into public.enrichment_queue (cnpj_basico, lead_id, priority)
  select l.cnpj_basico, l.id,
         l.score * 10 + greatest(0, 120 - coalesce(ref - e.data_inicio_atividade, 120))
           + case when l.stage <> 'novo' then 500 else 0 end
    from public.leads l
    join public.establishments e on e.cnpj = l.cnpj
   where not exists (select 1 from public.enrichment_queue q where q.cnpj_basico = l.cnpj_basico)
     and not exists (select 1 from public.contact_suppressions s where s.cnpj_basico = l.cnpj_basico)
   order by 3 desc
   limit p_limit
  on conflict do nothing;
  get diagnostics n = row_count;

  -- reverificação dos canais vencidos (nunca os confirmados manualmente)
  update public.enrichment_queue q
     set status = 'pendente', attempts = 0, next_attempt_at = now(), updated_at = now()
   where q.status = 'concluido'
     and exists (select 1 from public.digital_channels c
                  where c.cnpj_basico = q.cnpj_basico and not c.manual and c.next_check_at <= now());
  return n;
end $$;
revoke all on function public.enqueue_enrichment(integer) from public, anon, authenticated;

-- Reserva um lote para um worker (concorrência segura)
create or replace function public.claim_enrichment_batch(p_worker text, p_limit integer)
returns setof public.enrichment_queue
language plpgsql security definer set search_path = public as $$
begin
  -- itens presos por um worker que parou de dar sinal voltam para a fila
  update public.enrichment_queue
     set status = 'pendente', locked_by = null, locked_at = null
   where status = 'em_processamento' and coalesce(heartbeat_at, locked_at) < now() - interval '20 minutes';

  return query
  update public.enrichment_queue q
     set status = 'em_processamento', locked_by = p_worker, locked_at = now(), heartbeat_at = now(), updated_at = now()
   where q.cnpj_basico in (
           select cnpj_basico from public.enrichment_queue
            where status in ('pendente', 'erro') and next_attempt_at <= now() and attempts < 6
            order by priority desc, next_attempt_at
            for update skip locked
            limit p_limit)
  returning q.*;
end $$;
revoke all on function public.claim_enrichment_batch(text, integer) from public, anon, authenticated;

-- Pedido manual de nova pesquisa (comercial+)
create or replace function public.request_enrichment(p_lead_ids uuid[])
returns integer
language plpgsql security definer set search_path = public as $$
declare
  n integer;
begin
  if not public.has_role(array['admin', 'gestor', 'comercial']::public.app_role[]) then
    raise exception 'Sem permissão';
  end if;
  insert into public.enrichment_queue (cnpj_basico, lead_id, priority, requested_by)
  select l.cnpj_basico, l.id, 100000, auth.uid() from public.leads l where l.id = any (p_lead_ids)
  on conflict (cnpj_basico) do update
    set status = 'pendente', attempts = 0, next_attempt_at = now(), priority = 100000,
        requested_by = auth.uid(), updated_at = now()
    where public.enrichment_queue.status <> 'em_processamento';
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.request_enrichment(uuid[]) from public, anon;
grant execute on function public.request_enrichment(uuid[]) to authenticated;

-- Confirmação/correção manual de um canal (o worker nunca sobrescreve)
create or replace function public.confirm_digital_channel(
  p_lead_id uuid, p_platform text, p_url text, p_status text, p_note text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare
  b text;
begin
  if not public.has_role(array['admin', 'gestor', 'comercial']::public.app_role[]) then
    raise exception 'Sem permissão';
  end if;
  if p_status not in ('verificado', 'nao_localizado') then
    raise exception 'Use "verificado" (canal confirmado) ou "nao_localizado" (confirmado que não existe)';
  end if;
  if p_status = 'verificado' and coalesce(trim(p_url), '') !~* '^https?://' then
    raise exception 'Informe o endereço completo (https://...)';
  end if;
  select cnpj_basico into b from public.leads where id = p_lead_id;
  insert into public.digital_channels (cnpj_basico, lead_id, platform, url, status, source, confidence, evidence,
                                       manual, confirmed_by, confirmed_at, first_checked_at, last_checked_at, next_check_at)
  values (b, p_lead_id, p_platform, case when p_status = 'verificado' then trim(p_url) end, p_status, 'manual', 100,
          jsonb_build_array(jsonb_build_object('tipo', 'confirmacao_manual', 'detalhe', coalesce(p_note, 'Confirmado por usuário'), 'peso', 100)),
          true, auth.uid(), now(), now(), now(), null)
  on conflict (cnpj_basico, platform) do update
    set url = excluded.url, status = excluded.status, source = 'manual', confidence = 100, evidence = excluded.evidence,
        manual = true, confirmed_by = auth.uid(), confirmed_at = now(), last_checked_at = now(), next_check_at = null,
        lead_id = coalesce(public.digital_channels.lead_id, excluded.lead_id), updated_at = now();
  if p_platform = 'site' and p_status = 'verificado' then
    perform set_config('app.bulk_load', 'on', true);
    update public.leads set website = trim(p_url) where id = p_lead_id;
    perform set_config('app.bulk_load', '', true);
  end if;
end $$;
revoke all on function public.confirm_digital_channel(uuid, text, text, text, text) from public, anon;
grant execute on function public.confirm_digital_channel(uuid, text, text, text, text) to authenticated;

-- Desfaz confirmação manual (volta para a fila)
create or replace function public.reset_digital_channel(p_lead_id uuid, p_platform text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role(array['admin', 'gestor']::public.app_role[]) then
    raise exception 'Apenas administradores e gestores';
  end if;
  update public.digital_channels
     set manual = false, status = 'pendente', confirmed_by = null, confirmed_at = null, next_check_at = now(), updated_at = now()
   where lead_id = p_lead_id and platform = p_platform;
  perform public.request_enrichment(array[p_lead_id]);
end $$;
revoke all on function public.reset_digital_channel(uuid, text) from public, anon;
grant execute on function public.reset_digital_channel(uuid, text) to authenticated;

-- Pausa e retomada (admin)
create or replace function public.set_intelligence_paused(p_paused boolean)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role(array['admin']::public.app_role[]) then
    raise exception 'Apenas administradores';
  end if;
  update public.app_settings set value = value || jsonb_build_object('pausado', p_paused), updated_at = now()
   where key = 'inteligencia';
end $$;
revoke all on function public.set_intelligence_paused(boolean) from public, anon;
grant execute on function public.set_intelligence_paused(boolean) to authenticated;

-- Situação do motor (interface)
create or replace function public.intelligence_summary()
returns jsonb
language sql stable security invoker set search_path = public as $$
  select jsonb_build_object(
    'fila', (select coalesce(jsonb_object_agg(status, n), '{}'::jsonb) from (
               select status, count(*) n from public.enrichment_queue group by status) x),
    'sem_fila', (select count(*) from public.leads l
                  where not exists (select 1 from public.enrichment_queue q where q.cnpj_basico = l.cnpj_basico)),
    'canais', (select coalesce(jsonb_object_agg(platform, s), '{}'::jsonb) from (
                 select platform, jsonb_object_agg(status, n) s from (
                   select platform, status, count(*) n from public.digital_channels group by 1, 2) y group by 1) x),
    'uso_hoje', (select coalesce(jsonb_object_agg(provider, jsonb_build_object('consultas', calls, 'custo_usd', cost_usd, 'erros', errors)), '{}'::jsonb)
                   from public.provider_usage where day = current_date),
    'uso_mes', (select coalesce(jsonb_object_agg(provider, jsonb_build_object('consultas', c, 'custo_usd', v)), '{}'::jsonb)
                  from (select provider, sum(calls) c, sum(cost_usd) v from public.provider_usage
                         where day >= date_trunc('month', current_date) group by provider) x),
    'config', (select value from public.app_settings where key = 'inteligencia'))
$$;
revoke all on function public.intelligence_summary() from public, anon;
grant execute on function public.intelligence_summary() to authenticated;

-- ---------------------------------------------------------------------
-- Carga inicial: o que já foi verificado pelo domínio do e-mail vira canal "site"
-- ---------------------------------------------------------------------
insert into public.digital_channels (cnpj_basico, lead_id, platform, url, status, source, confidence, evidence, result,
                                     first_checked_at, last_checked_at, next_check_at)
select l.cnpj_basico, l.id, 'site',
       case when l.digital_presence ->> 'status' in ('site_ok', 'site_fraco') then coalesce(l.website, l.digital_presence ->> 'url') end,
       case l.digital_presence ->> 'status'
         when 'site_ok' then 'verificado' when 'site_fraco' then 'verificado'
         -- domínio do e-mail inexistente não prova ausência de site (pode haver outro domínio): só a pesquisa web confirma
         when 'sem_site' then 'inconclusivo'
         when 'inconclusivo' then 'inconclusivo'
         else 'pendente' end,
       'dominio_email',
       case l.digital_presence ->> 'status' when 'site_ok' then 70 when 'site_fraco' then 70 when 'sem_site' then 60 else 0 end,
       jsonb_build_array(jsonb_build_object('tipo', 'dominio_email', 'detalhe',
         coalesce(l.digital_presence ->> 'dominio', 'sem domínio próprio') || ': ' || coalesce(l.digital_presence ->> 'status', '?'), 'peso', 40)),
       jsonb_build_object('legado', l.digital_presence),
       (l.digital_presence ->> 'checked_at')::timestamptz, (l.digital_presence ->> 'checked_at')::timestamptz, now()
  from public.leads l
 where l.digital_presence ->> 'status' is not null
on conflict (cnpj_basico, platform) do nothing;

select public.take_inventory_snapshot('migration 014 (inteligência digital)');
