-- =====================================================================
-- JS Lead Hunter 2.0 — Fase 2: CRM profissional
-- Empresa (leads + cadastro) separada da OPORTUNIDADE comercial.
-- Uma empresa pode ter várias oportunidades ao longo do tempo.
-- Somente alterações ADITIVAS; a etapa legada do lead (leads.stage) continua
-- existindo e passa a refletir a oportunidade mais avançada.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Etapas configuráveis do funil
-- ---------------------------------------------------------------------
create table if not exists public.pipeline_stages (
  code          text primary key check (code ~ '^[a-z0-9_]+$'),
  label         text not null,
  sort_order    integer not null,
  kind          text not null default 'aberta' check (kind in ('aberta', 'ganha', 'pos_venda', 'perdida')),
  legacy_stage  public.lead_stage not null,
  probability   smallint not null default 0 check (probability between 0 and 100),
  color         text not null default 'slate',
  active        boolean not null default true,
  updated_at    timestamptz not null default now()
);

insert into public.pipeline_stages (code, label, sort_order, kind, legacy_stage, probability, color) values
  ('novo_lead',          'Novo lead',          10,  'aberta',    'novo',                5,  'slate'),
  ('em_qualificacao',    'Em qualificação',    20,  'aberta',    'validado',            10, 'slate'),
  ('qualificado',        'Qualificado',        30,  'aberta',    'pronto_contato',      15, 'sky'),
  ('primeiro_contato',   'Primeiro contato',   40,  'aberta',    'primeiro_contato',    20, 'sky'),
  ('aguardando_retorno', 'Aguardando retorno', 50,  'aberta',    'aguardando_resposta', 25, 'amber'),
  ('interessado',        'Interessado',        60,  'aberta',    'interessado',         40, 'amber'),
  ('reuniao_agendada',   'Reunião agendada',   70,  'aberta',    'interessado',         50, 'violet'),
  ('proposta_enviada',   'Proposta enviada',   80,  'aberta',    'proposta_enviada',    60, 'violet'),
  ('em_negociacao',      'Em negociação',      90,  'aberta',    'em_negociacao',       75, 'orange'),
  ('contrato_fechado',   'Contrato fechado',   100, 'ganha',     'convertido',          100, 'emerald'),
  ('pos_venda',          'Pós-venda',          110, 'pos_venda', 'convertido',          100, 'teal'),
  ('perdido',            'Perdido',            120, 'perdida',   'perdido',             0,  'red')
on conflict (code) do nothing;

create table if not exists public.loss_reasons (
  id          uuid primary key default gen_random_uuid(),
  label       text not null unique,
  active      boolean not null default true,
  sort_order  integer not null default 0
);
insert into public.loss_reasons (label, sort_order) values
  ('Sem orçamento no momento', 10), ('Preço acima do esperado', 20), ('Escolheu outro fornecedor', 30),
  ('Sem interesse no serviço', 40), ('Não respondeu aos contatos', 50), ('Contato inválido', 60),
  ('Empresa encerrou ou suspendeu as atividades', 70), ('Pediu para não ser contatado', 80), ('Outro', 90)
on conflict (label) do nothing;

-- ---------------------------------------------------------------------
-- 2. Oportunidades
-- ---------------------------------------------------------------------
create table if not exists public.opportunities (
  id               uuid primary key default gen_random_uuid(),
  lead_id          uuid not null references public.leads (id) on delete cascade,
  cnpj_basico      text not null,
  title            text not null check (length(trim(title)) > 0),
  stage_code       text not null default 'novo_lead' references public.pipeline_stages (code) on update cascade,
  status           text not null default 'aberta' check (status in ('aberta', 'ganha', 'pos_venda', 'perdida')),
  owner_id         uuid references public.profiles (id) on delete set null,
  service_ids      uuid[] not null default '{}',
  value            numeric(14, 2) check (value is null or value >= 0),
  recurring_value  numeric(14, 2) check (recurring_value is null or recurring_value >= 0),
  expected_close   date,
  lost_reason_id   uuid references public.loss_reasons (id) on delete set null,
  lost_reason      text,
  won_at           timestamptz,
  lost_at          timestamptz,
  stage_changed_at timestamptz not null default now(),
  source           text not null default 'manual' check (source in ('manual', 'migracao', 'central', 'reativacao')),
  reopened_from    uuid references public.opportunities (id) on delete set null,
  created_by       uuid references public.profiles (id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index if not exists opportunities_lead_idx on public.opportunities (lead_id);
create index if not exists opportunities_stage_idx on public.opportunities (stage_code);
create index if not exists opportunities_owner_idx on public.opportunities (owner_id);
create index if not exists opportunities_status_idx on public.opportunities (status);

-- Histórico: eventos podem apontar para a oportunidade
alter table public.lead_events add column if not exists opportunity_id uuid references public.opportunities (id) on delete set null;
create index if not exists lead_events_opp_idx on public.lead_events (opportunity_id) where opportunity_id is not null;

alter table public.lead_events drop constraint if exists lead_events_event_type_check;
alter table public.lead_events add constraint lead_events_event_type_check check (event_type in (
  'criado', 'mudanca_etapa', 'anotacao', 'contato', 'resposta_recebida',
  'follow_up_agendado', 'follow_up_concluido', 'responsavel_alterado',
  'pontuacao_alterada', 'bloqueado', 'proposta',
  'oportunidade_criada', 'oportunidade_etapa', 'oportunidade_ganha', 'oportunidade_perdida',
  'oportunidade_reaberta', 'tarefa_criada', 'tarefa_concluida', 'reuniao', 'contrato', 'pos_venda'));
alter table public.lead_events drop constraint if exists lead_events_channel_check;
alter table public.lead_events add constraint lead_events_channel_check check (
  channel is null or channel in ('telefone', 'whatsapp', 'email', 'presencial', 'reuniao', 'video', 'outro'));

drop policy if exists lead_events_insert on public.lead_events;
create policy lead_events_insert on public.lead_events for insert to authenticated
  with check (
    public.has_role(array['admin', 'gestor', 'comercial']::public.app_role[])
    and actor_id = auth.uid()
    and event_type in ('anotacao', 'contato', 'resposta_recebida', 'follow_up_concluido', 'reuniao', 'pos_venda'));

-- Status, datas e consistência
create or replace function public.opportunities_before()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  k text;
begin
  select kind into k from public.pipeline_stages where code = new.stage_code;
  if k is null then
    raise exception 'Etapa inexistente: %', new.stage_code;
  end if;
  new.status := k;
  new.cnpj_basico := (select cnpj_basico from public.leads where id = new.lead_id);
  if tg_op = 'INSERT' or new.stage_code is distinct from old.stage_code then
    new.stage_changed_at := now();
  end if;
  if k = 'perdida' then
    if coalesce(trim(new.lost_reason), '') = '' and new.lost_reason_id is null then
      raise exception 'Informe o motivo da perda';
    end if;
    new.lost_at := coalesce(new.lost_at, now());
  else
    new.lost_at := null;
  end if;
  if k in ('ganha', 'pos_venda') then
    new.won_at := coalesce(new.won_at, now());
  elsif k = 'aberta' then
    new.won_at := null;
  end if;
  if tg_op = 'INSERT' and new.owner_id is null then
    new.owner_id := coalesce((select owner_id from public.leads where id = new.lead_id), auth.uid());
  end if;
  return new;
end $$;

-- Etapa legada do lead = oportunidade mais avançada (não perdida)
create or replace function public.sync_lead_stage(p_lead_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  best public.lead_stage;
  any_open boolean;
  any_lost boolean;
begin
  select ps.legacy_stage into best
    from public.opportunities o join public.pipeline_stages ps on ps.code = o.stage_code
   where o.lead_id = p_lead_id and o.status <> 'perdida'
   order by ps.sort_order desc limit 1;
  select bool_or(status <> 'perdida'), bool_or(status = 'perdida') into any_open, any_lost
    from public.opportunities where lead_id = p_lead_id;
  if best is not null then
    update public.leads set stage = best where id = p_lead_id and stage is distinct from best;
  elsif any_lost and not coalesce(any_open, false) then
    update public.leads set stage = 'perdido',
           lost_reason = coalesce(lost_reason, (select coalesce(o.lost_reason, r.label)
                                                  from public.opportunities o left join public.loss_reasons r on r.id = o.lost_reason_id
                                                 where o.lead_id = p_lead_id order by o.lost_at desc nulls last limit 1))
     where id = p_lead_id and stage <> 'perdido';
  end if;
end $$;
revoke all on function public.sync_lead_stage(uuid) from public, anon, authenticated;

create or replace function public.opportunities_after()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  lbl text;
begin
  if tg_op = 'INSERT' then
    insert into public.lead_events (lead_id, opportunity_id, event_type, content, actor_id, metadata)
    values (new.lead_id, new.id, case when new.source = 'reativacao' then 'oportunidade_reaberta' else 'oportunidade_criada' end,
            new.title, auth.uid(), jsonb_build_object('etapa', new.stage_code, 'origem', new.source));
  elsif new.stage_code is distinct from old.stage_code then
    select label into lbl from public.pipeline_stages where code = new.stage_code;
    insert into public.lead_events (lead_id, opportunity_id, event_type, content, actor_id, metadata)
    values (new.lead_id, new.id,
            case new.status when 'ganha' then 'oportunidade_ganha' when 'perdida' then 'oportunidade_perdida'
                            else 'oportunidade_etapa' end,
            new.title || ' → ' || lbl, auth.uid(),
            jsonb_build_object('de', old.stage_code, 'para', new.stage_code,
                               'motivo_perda', coalesce(new.lost_reason, (select label from public.loss_reasons where id = new.lost_reason_id))));
  end if;
  if tg_op = 'UPDATE' and new.owner_id is distinct from old.owner_id then
    insert into public.lead_events (lead_id, opportunity_id, event_type, actor_id, metadata)
    values (new.lead_id, new.id, 'responsavel_alterado', auth.uid(), jsonb_build_object('de', old.owner_id, 'para', new.owner_id));
  end if;
  perform public.sync_lead_stage(new.lead_id);
  return new;
end $$;

drop trigger if exists opportunities_before on public.opportunities;
create trigger opportunities_before before insert or update on public.opportunities
  for each row execute function public.opportunities_before();
drop trigger if exists opportunities_after on public.opportunities;
create trigger opportunities_after after insert or update on public.opportunities
  for each row execute function public.opportunities_after();
create trigger opportunities_updated_at before update on public.opportunities
  for each row execute function public.set_updated_at();
create trigger opportunities_audit after insert or update or delete on public.opportunities
  for each row execute function public.audit_trigger();

-- Empresa bloqueada não ganha oportunidade nova
create or replace function public.opportunities_check_suppression()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.contact_suppressions s
              where s.cnpj_basico = (select cnpj_basico from public.leads where id = new.lead_id)) then
    raise exception 'Empresa bloqueada para contato' using errcode = 'check_violation';
  end if;
  return new;
end $$;
drop trigger if exists opportunities_check_suppression on public.opportunities;
create trigger opportunities_check_suppression before insert on public.opportunities
  for each row execute function public.opportunities_check_suppression();

-- Bloqueio: oportunidades abertas vão para "Perdido"
create or replace function public.suppression_close_opportunities()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.opportunities
     set stage_code = 'perdido', lost_reason = coalesce(lost_reason, 'Bloqueado para contato: ' || new.reason)
   where cnpj_basico = new.cnpj_basico and status = 'aberta';
  update public.crm_tasks set done_at = now(), outcome = 'Cancelada: empresa bloqueada para contato'
   where done_at is null and lead_id in (select id from public.leads where cnpj_basico = new.cnpj_basico);
  return new;
end $$;

-- ---------------------------------------------------------------------
-- 3. Tarefas, atividades e agenda
-- ---------------------------------------------------------------------
create table if not exists public.crm_tasks (
  id              uuid primary key default gen_random_uuid(),
  lead_id         uuid not null references public.leads (id) on delete cascade,
  opportunity_id  uuid references public.opportunities (id) on delete set null,
  kind            text not null default 'tarefa'
                    check (kind in ('ligacao', 'reuniao', 'email', 'whatsapp', 'visita', 'tarefa', 'follow_up', 'pos_venda')),
  title           text not null check (length(trim(title)) > 0),
  notes           text,
  due_at          timestamptz,
  remind_at       timestamptz,
  done_at         timestamptz,
  done_by         uuid references public.profiles (id) on delete set null,
  outcome         text,
  owner_id        uuid references public.profiles (id) on delete set null,
  created_by      uuid references public.profiles (id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists crm_tasks_owner_due_idx on public.crm_tasks (owner_id, due_at) where done_at is null;
create index if not exists crm_tasks_lead_idx on public.crm_tasks (lead_id, due_at);

create or replace function public.crm_tasks_before()
returns trigger language plpgsql as $$
begin
  if new.done_at is not null and (tg_op = 'INSERT' or old.done_at is null) then
    new.done_by := coalesce(new.done_by, auth.uid());
  elsif new.done_at is null then
    new.done_by := null;
  end if;
  return new;
end $$;

-- Follow-up legado do lead = próxima tarefa aberta com data
create or replace function public.crm_tasks_after()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  nxt timestamptz;
  l uuid := coalesce(new.lead_id, old.lead_id);
begin
  if tg_op = 'INSERT' then
    insert into public.lead_events (lead_id, opportunity_id, event_type, content, scheduled_for, actor_id, metadata)
    values (new.lead_id, new.opportunity_id, 'tarefa_criada', new.title, new.due_at, auth.uid(),
            jsonb_build_object('tarefa_id', new.id, 'tipo', new.kind));
  end if;
  if tg_op <> 'DELETE' and new.done_at is not null and (tg_op = 'INSERT' or old.done_at is null) then
    insert into public.lead_events (lead_id, opportunity_id, event_type, content, scheduled_for, actor_id, channel, metadata)
    values (new.lead_id, new.opportunity_id,
            case when new.kind = 'reuniao' then 'reuniao' else 'tarefa_concluida' end,
            new.title || coalesce(' — ' || new.outcome, ''), new.due_at, auth.uid(),
            case new.kind when 'ligacao' then 'telefone' when 'whatsapp' then 'whatsapp' when 'email' then 'email'
                          when 'reuniao' then 'reuniao' when 'visita' then 'presencial' end,
            jsonb_build_object('tarefa_id', new.id, 'tipo', new.kind));
  end if;
  select min(due_at) into nxt from public.crm_tasks where lead_id = l and done_at is null and due_at is not null;
  perform set_config('app.task_sync', 'on', true);
  update public.leads set next_follow_up_at = nxt where id = l and next_follow_up_at is distinct from nxt;
  perform set_config('app.task_sync', '', true);
  return coalesce(new, old);
end $$;

drop trigger if exists crm_tasks_before on public.crm_tasks;
create trigger crm_tasks_before before insert or update on public.crm_tasks
  for each row execute function public.crm_tasks_before();
drop trigger if exists crm_tasks_after on public.crm_tasks;
create trigger crm_tasks_after after insert or update or delete on public.crm_tasks
  for each row execute function public.crm_tasks_after();
create trigger crm_tasks_updated_at before update on public.crm_tasks
  for each row execute function public.set_updated_at();
create trigger crm_tasks_audit after insert or update or delete on public.crm_tasks
  for each row execute function public.audit_trigger();

-- Follow-up definido direto no lead (tela antiga) vira tarefa
create or replace function public.leads_followup_to_task()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('app.task_sync', true), '') = 'on' then
    return new;
  end if;
  if new.next_follow_up_at is not null and new.next_follow_up_at is distinct from old.next_follow_up_at then
    insert into public.crm_tasks (lead_id, kind, title, due_at, owner_id, created_by)
    values (new.id, 'follow_up', 'Follow-up', new.next_follow_up_at, coalesce(new.owner_id, auth.uid()), auth.uid());
  elsif new.next_follow_up_at is null and old.next_follow_up_at is not null then
    perform set_config('app.task_sync', 'on', true);
    update public.crm_tasks set done_at = now() where lead_id = new.id and done_at is null and kind = 'follow_up';
    perform set_config('app.task_sync', '', true);
  end if;
  return new;
end $$;
drop trigger if exists leads_followup_to_task on public.leads;
create trigger leads_followup_to_task after update of next_follow_up_at on public.leads
  for each row execute function public.leads_followup_to_task();

-- ---------------------------------------------------------------------
-- 4. Contratos e pós-venda
-- ---------------------------------------------------------------------
create table if not exists public.contracts (
  id               uuid primary key default gen_random_uuid(),
  lead_id          uuid not null references public.leads (id) on delete cascade,
  opportunity_id   uuid references public.opportunities (id) on delete set null,
  title            text not null check (length(trim(title)) > 0),
  service_ids      uuid[] not null default '{}',
  total_value      numeric(14, 2) check (total_value is null or total_value >= 0),
  recurring_value  numeric(14, 2) check (recurring_value is null or recurring_value >= 0),
  recurrence       text not null default 'unico' check (recurrence in ('unico', 'mensal', 'trimestral', 'semestral', 'anual')),
  payment_terms    text,
  start_date       date,
  end_date         date,
  signed_at        date,
  status           text not null default 'ativo' check (status in ('ativo', 'concluido', 'cancelado', 'suspenso')),
  notes            text,
  created_by       uuid references public.profiles (id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint contracts_dates_chk check (end_date is null or start_date is null or end_date >= start_date)
);
create index if not exists contracts_lead_idx on public.contracts (lead_id);
create index if not exists contracts_status_idx on public.contracts (status);

create or replace function public.contracts_after()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into public.lead_events (lead_id, opportunity_id, event_type, content, actor_id, metadata)
    values (new.lead_id, new.opportunity_id, 'contrato', new.title, auth.uid(),
            jsonb_build_object('contrato_id', new.id, 'valor', new.total_value, 'recorrente', new.recurring_value,
                               'recorrencia', new.recurrence));
    update public.opportunities set stage_code = 'contrato_fechado'
     where id = new.opportunity_id and status = 'aberta';
  elsif new.status is distinct from old.status then
    insert into public.lead_events (lead_id, opportunity_id, event_type, content, actor_id, metadata)
    values (new.lead_id, new.opportunity_id, 'contrato', new.title || ' — ' || new.status, auth.uid(),
            jsonb_build_object('contrato_id', new.id, 'status', new.status, 'status_anterior', old.status));
  end if;
  return new;
end $$;
drop trigger if exists contracts_after on public.contracts;
create trigger contracts_after after insert or update on public.contracts
  for each row execute function public.contracts_after();
create trigger contracts_updated_at before update on public.contracts
  for each row execute function public.set_updated_at();
create trigger contracts_audit after insert or update or delete on public.contracts
  for each row execute function public.audit_trigger();

-- Propostas passam a pertencer a uma oportunidade
alter table public.lead_proposals add column if not exists opportunity_id uuid references public.opportunities (id) on delete set null;
create index if not exists lead_proposals_opp_idx on public.lead_proposals (opportunity_id);

create or replace function public.lead_proposals_track()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  target text;
  cur_order int;
  tgt_order int;
  st public.lead_stage;
  stages public.lead_stage[] := array['novo', 'validado', 'pronto_contato', 'primeiro_contato',
    'aguardando_resposta', 'interessado', 'proposta_enviada', 'em_negociacao']::public.lead_stage[];
  legacy public.lead_stage;
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status
     and new.amount is not distinct from old.amount then
    return new;
  end if;

  insert into public.lead_events (lead_id, opportunity_id, event_type, content, actor_id, metadata)
  values (new.lead_id, new.opportunity_id, 'proposta', new.title, auth.uid(),
          jsonb_build_object('proposta_id', new.id, 'status', new.status, 'valor', new.amount,
                             'status_anterior', case when tg_op = 'UPDATE' then old.status end));

  target := case new.status when 'enviada' then 'proposta_enviada' when 'em_negociacao' then 'em_negociacao' end;
  if target is null then
    return new;
  end if;
  if new.opportunity_id is not null then
    -- avança a oportunidade (nunca retrocede; não mexe em ganha/perdida)
    select ps.sort_order into cur_order from public.opportunities o
      join public.pipeline_stages ps on ps.code = o.stage_code
     where o.id = new.opportunity_id and o.status = 'aberta';
    select sort_order into tgt_order from public.pipeline_stages where code = target;
    if cur_order is not null and cur_order < tgt_order then
      update public.opportunities set stage_code = target,
             value = coalesce(value, new.amount)
       where id = new.opportunity_id;
    end if;
  else
    -- proposta sem oportunidade (tela antiga): avança a etapa legada do lead
    legacy := target::public.lead_stage;
    select stage into st from public.leads where id = new.lead_id;
    if array_position(stages, st) is not null and array_position(stages, st) < array_position(stages, legacy) then
      update public.leads set stage = legacy where id = new.lead_id;
    end if;
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------------
-- 5. Tags, metas
-- ---------------------------------------------------------------------
create table if not exists public.tags (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique check (length(trim(name)) between 1 and 40),
  color       text not null default 'slate',
  created_by  uuid references public.profiles (id) on delete set null,
  created_at  timestamptz not null default now()
);
create table if not exists public.lead_tags (
  lead_id     uuid not null references public.leads (id) on delete cascade,
  tag_id      uuid not null references public.tags (id) on delete cascade,
  created_by  uuid references public.profiles (id) on delete set null,
  created_at  timestamptz not null default now(),
  primary key (lead_id, tag_id)
);
create index if not exists lead_tags_tag_idx on public.lead_tags (tag_id);

create table if not exists public.sales_goals (
  id            uuid primary key default gen_random_uuid(),
  owner_id      uuid references public.profiles (id) on delete cascade,   -- null = meta da equipe
  period_month  date not null check (extract(day from period_month) = 1),
  metric        text not null check (metric in ('receita_contratada', 'contratos', 'contatos', 'reunioes', 'propostas', 'oportunidades')),
  target        numeric(14, 2) not null check (target > 0),
  created_by    uuid references public.profiles (id) on delete set null,
  created_at    timestamptz not null default now(),
  unique nulls not distinct (owner_id, period_month, metric)
);
create trigger sales_goals_audit after insert or update or delete on public.sales_goals
  for each row execute function public.audit_trigger();

-- ---------------------------------------------------------------------
-- 6. RLS
-- ---------------------------------------------------------------------
alter table public.pipeline_stages enable row level security;
alter table public.loss_reasons    enable row level security;
alter table public.opportunities   enable row level security;
alter table public.crm_tasks       enable row level security;
alter table public.contracts       enable row level security;
alter table public.tags            enable row level security;
alter table public.lead_tags       enable row level security;
alter table public.sales_goals     enable row level security;
revoke all on public.pipeline_stages, public.loss_reasons, public.opportunities, public.crm_tasks,
              public.contracts, public.tags, public.lead_tags, public.sales_goals from anon;

do $$
declare t text;
begin
  -- leitura para usuários ativos
  foreach t in array array['pipeline_stages', 'loss_reasons', 'opportunities', 'crm_tasks', 'contracts',
                           'tags', 'lead_tags', 'sales_goals'] loop
    execute format('drop policy if exists %I on public.%I', t || '_select', t);
    execute format('create policy %I on public.%I for select to authenticated using (public.is_active_user())', t || '_select', t);
  end loop;
  -- configuração: só admin
  foreach t in array array['pipeline_stages', 'loss_reasons'] loop
    execute format('drop policy if exists %I on public.%I', t || '_admin', t);
    execute format('create policy %I on public.%I for all to authenticated
       using (public.has_role(array[''admin'']::public.app_role[]))
       with check (public.has_role(array[''admin'']::public.app_role[]))', t || '_admin', t);
  end loop;
  -- operação comercial: comercial, gestor e admin escrevem; só admin exclui
  foreach t in array array['opportunities', 'crm_tasks', 'contracts', 'lead_tags'] loop
    execute format('drop policy if exists %I on public.%I', t || '_insert', t);
    execute format('create policy %I on public.%I for insert to authenticated
       with check (public.has_role(array[''admin'', ''gestor'', ''comercial'']::public.app_role[]))', t || '_insert', t);
    execute format('drop policy if exists %I on public.%I', t || '_update', t);
    execute format('create policy %I on public.%I for update to authenticated
       using (public.has_role(array[''admin'', ''gestor'', ''comercial'']::public.app_role[]))
       with check (public.has_role(array[''admin'', ''gestor'', ''comercial'']::public.app_role[]))', t || '_update', t);
  end loop;
  foreach t in array array['opportunities', 'crm_tasks', 'contracts'] loop
    execute format('drop policy if exists %I on public.%I', t || '_delete', t);
    execute format('create policy %I on public.%I for delete to authenticated
       using (public.has_role(array[''admin'']::public.app_role[]))', t || '_delete', t);
  end loop;
end $$;

-- comercial remove tag do lead e cria tags; só admin exclui uma tag
create policy lead_tags_delete on public.lead_tags for delete to authenticated
  using (public.has_role(array['admin', 'gestor', 'comercial']::public.app_role[]));
create policy tags_insert on public.tags for insert to authenticated
  with check (public.has_role(array['admin', 'gestor', 'comercial']::public.app_role[]));
create policy tags_admin on public.tags for delete to authenticated
  using (public.has_role(array['admin']::public.app_role[]));
-- metas: admin e gestor
create policy sales_goals_write on public.sales_goals for all to authenticated
  using (public.has_role(array['admin', 'gestor']::public.app_role[]))
  with check (public.has_role(array['admin', 'gestor']::public.app_role[]));

-- O gatilho de bloqueio que fecha oportunidades depende de crm_tasks
drop trigger if exists suppression_close_opportunities on public.contact_suppressions;
create trigger suppression_close_opportunities after insert on public.contact_suppressions
  for each row execute function public.suppression_close_opportunities();

-- ---------------------------------------------------------------------
-- 7. RPCs
-- ---------------------------------------------------------------------
-- Reativação: cria NOVA oportunidade a partir de uma perdida/encerrada (histórico preservado)
create or replace function public.reopen_opportunity(p_id uuid, p_stage text default 'em_qualificacao', p_title text default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  o public.opportunities;
  new_id uuid;
begin
  if not public.has_role(array['admin', 'gestor', 'comercial']::public.app_role[]) then
    raise exception 'Sem permissão';
  end if;
  select * into o from public.opportunities where id = p_id;
  if not found then raise exception 'Oportunidade não encontrada'; end if;
  if o.status = 'aberta' then raise exception 'A oportunidade ainda está aberta'; end if;
  if (select kind from public.pipeline_stages where code = p_stage) <> 'aberta' then
    raise exception 'Escolha uma etapa aberta para reativar';
  end if;
  insert into public.opportunities (lead_id, title, stage_code, owner_id, service_ids, source, reopened_from, created_by)
  values (o.lead_id, coalesce(p_title, o.title), p_stage, coalesce(o.owner_id, auth.uid()), o.service_ids,
          'reativacao', o.id, auth.uid())
  returning id into new_id;
  return new_id;
end $$;
revoke all on function public.reopen_opportunity(uuid, text, text) from public, anon;
grant execute on function public.reopen_opportunity(uuid, text, text) to authenticated;

-- Distribuição de leads entre responsáveis (rodízio)
create or replace function public.distribute_leads(p_lead_ids uuid[], p_owner_ids uuid[], p_only_unassigned boolean default true)
returns integer
language plpgsql security definer set search_path = public as $$
declare
  n integer;
  k integer := coalesce(array_length(p_owner_ids, 1), 0);
begin
  if not public.has_role(array['admin', 'gestor']::public.app_role[]) then
    raise exception 'Apenas administradores e gestores distribuem leads';
  end if;
  if k = 0 then raise exception 'Escolha ao menos um responsável'; end if;
  if exists (select 1 from unnest(p_owner_ids) u
              where not exists (select 1 from public.profiles p where p.id = u and p.active
                                  and p.role in ('admin', 'gestor', 'comercial'))) then
    raise exception 'Responsável inválido ou inativo';
  end if;
  with alvo as (
    select l.id, row_number() over (order by l.score desc, l.id) - 1 as rn
      from public.leads l
     where l.id = any (p_lead_ids) and (not p_only_unassigned or l.owner_id is null)
  )
  update public.leads l set owner_id = p_owner_ids[(a.rn % k) + 1]
    from alvo a where a.id = l.id;
  get diagnostics n = row_count;
  update public.opportunities o set owner_id = l.owner_id
    from public.leads l
   where l.id = o.lead_id and l.id = any (p_lead_ids) and o.owner_id is null and o.status = 'aberta';
  return n;
end $$;
revoke all on function public.distribute_leads(uuid[], uuid[], boolean) from public, anon;
grant execute on function public.distribute_leads(uuid[], uuid[], boolean) to authenticated;

-- Adiciona leads ao funil (cria oportunidade se não houver aberta)
create or replace function public.add_leads_to_pipeline(p_lead_ids uuid[], p_title text default null,
                                                        p_owner uuid default null, p_service_ids uuid[] default '{}')
returns integer
language plpgsql security definer set search_path = public as $$
declare
  n integer;
begin
  if not public.has_role(array['admin', 'gestor', 'comercial']::public.app_role[]) then
    raise exception 'Sem permissão';
  end if;
  insert into public.opportunities (lead_id, title, stage_code, owner_id, service_ids, source, created_by)
  select l.id,
         coalesce(p_title, 'Prospecção — ' || coalesce(e.nome_fantasia, c.razao_social, l.cnpj)),
         'novo_lead', coalesce(p_owner, l.owner_id), coalesce(p_service_ids, '{}'), 'central', auth.uid()
    from public.leads l
    join public.establishments e on e.cnpj = l.cnpj
    join public.companies c on c.cnpj_basico = l.cnpj_basico
   where l.id = any (p_lead_ids)
     and not exists (select 1 from public.opportunities o where o.lead_id = l.id and o.status = 'aberta')
     and not exists (select 1 from public.contact_suppressions s where s.cnpj_basico = l.cnpj_basico);
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.add_leads_to_pipeline(uuid[], text, uuid, uuid[]) from public, anon;
grant execute on function public.add_leads_to_pipeline(uuid[], text, uuid, uuid[]) to authenticated;

-- Agenda: tarefas abertas e notificações de atraso do usuário (ou da equipe)
create or replace function public.my_agenda(p_all boolean default false)
returns jsonb
language sql stable security invoker set search_path = public as $$
  with t as (
    select t.*, coalesce(e.nome_fantasia, c.razao_social) as empresa
      from public.crm_tasks t
      join public.leads l on l.id = t.lead_id
      join public.establishments e on e.cnpj = l.cnpj
      join public.companies c on c.cnpj_basico = l.cnpj_basico
     where t.done_at is null and (p_all or t.owner_id = auth.uid())
  )
  select jsonb_build_object(
    'atrasadas', (select count(*) from t where due_at < now()),
    'hoje', (select count(*) from t where due_at >= date_trunc('day', now()) and due_at < date_trunc('day', now()) + interval '1 day'),
    'lembretes', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'titulo', title, 'empresa', empresa, 'quando', due_at, 'lead_id', lead_id))
                             from (select * from t where remind_at <= now() order by due_at limit 20) x), '[]'::jsonb))
$$;
revoke all on function public.my_agenda(boolean) from public, anon;
grant execute on function public.my_agenda(boolean) to authenticated;

-- Contagem do Kanban de oportunidades
create or replace function public.pipeline_counts(p_owner uuid default null, p_unassigned boolean default false, p_uf text default null)
returns table (stage_code text, total bigint, valor numeric)
language sql stable security invoker set search_path = public as $$
  select o.stage_code, count(*), coalesce(sum(o.value), 0)
    from public.opportunities o
    join public.leads l on l.id = o.lead_id
    join public.establishments e on e.cnpj = l.cnpj
   where (p_owner is null or o.owner_id = p_owner)
     and (not p_unassigned or o.owner_id is null)
     and (p_uf is null or e.uf = p_uf)
   group by o.stage_code
$$;
revoke all on function public.pipeline_counts(uuid, boolean, text) from public, anon;
grant execute on function public.pipeline_counts(uuid, boolean, text) to authenticated;

-- Progresso das metas no mês
create or replace function public.goals_progress(p_month date default date_trunc('month', current_date)::date)
returns table (goal_id uuid, owner_id uuid, owner_name text, metric text, target numeric, realizado numeric)
language sql stable security invoker set search_path = public as $$
  select g.id, g.owner_id, coalesce(p.full_name, p.email, 'Equipe'), g.metric, g.target,
         case g.metric
           when 'receita_contratada' then (select coalesce(sum(ct.total_value), 0) from public.contracts ct
               join public.opportunities o on o.id = ct.opportunity_id
              where ct.status <> 'cancelado' and date_trunc('month', coalesce(ct.signed_at, ct.created_at::date)) = g.period_month
                and (g.owner_id is null or o.owner_id = g.owner_id))
           when 'contratos' then (select count(*) from public.contracts ct
               left join public.opportunities o on o.id = ct.opportunity_id
              where ct.status <> 'cancelado' and date_trunc('month', coalesce(ct.signed_at, ct.created_at::date)) = g.period_month
                and (g.owner_id is null or o.owner_id = g.owner_id))
           when 'contatos' then (select count(*) from public.lead_events ev
              where ev.event_type = 'contato' and date_trunc('month', ev.created_at) = g.period_month
                and (g.owner_id is null or ev.actor_id = g.owner_id))
           when 'reunioes' then (select count(*) from public.lead_events ev
              where ev.event_type = 'reuniao' and date_trunc('month', ev.created_at) = g.period_month
                and (g.owner_id is null or ev.actor_id = g.owner_id))
           when 'propostas' then (select count(*) from public.lead_proposals pr
              where pr.status <> 'rascunho' and date_trunc('month', coalesce(pr.sent_at, pr.created_at)) = g.period_month
                and (g.owner_id is null or pr.created_by = g.owner_id))
           when 'oportunidades' then (select count(*) from public.opportunities o
              where date_trunc('month', o.created_at) = g.period_month and (g.owner_id is null or o.owner_id = g.owner_id))
         end
    from public.sales_goals g left join public.profiles p on p.id = g.owner_id
   where g.period_month = date_trunc('month', p_month)::date
$$;
revoke all on function public.goals_progress(date) from public, anon;
grant execute on function public.goals_progress(date) to authenticated;

-- Visão de listagem de oportunidades (RLS de quem consulta)
create or replace view public.opportunity_list_v with (security_invoker = true) as
select o.id, o.lead_id, o.title, o.stage_code, ps.label as stage_label, ps.sort_order as stage_order, o.status,
       o.owner_id, p.full_name as owner_name, o.value, o.recurring_value, o.expected_close, o.service_ids,
       o.lost_reason, lr.label as lost_reason_label, o.won_at, o.lost_at, o.stage_changed_at, o.source,
       o.created_at, o.updated_at, l.cnpj, l.cnpj_basico, l.score, l.priority, c.razao_social, e.nome_fantasia,
       e.uf, m.name as municipio, e.has_phone, e.has_email, l.next_follow_up_at,
       (select count(*) from public.crm_tasks t where t.opportunity_id = o.id and t.done_at is null) as tarefas_abertas
  from public.opportunities o
  join public.pipeline_stages ps on ps.code = o.stage_code
  join public.leads l on l.id = o.lead_id
  join public.establishments e on e.cnpj = l.cnpj
  join public.companies c on c.cnpj_basico = l.cnpj_basico
  left join public.municipalities m on m.code = e.municipio_code
  left join public.profiles p on p.id = o.owner_id
  left join public.loss_reasons lr on lr.id = o.lost_reason_id;
revoke all on public.opportunity_list_v from anon;
grant select on public.opportunity_list_v to authenticated;

-- Arquivamento (se religado) nunca alcança lead com oportunidade ou tarefa
create or replace function public.lead_is_untouched(p_lead_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select not exists (
    select 1 from public.lead_events ev
     where ev.lead_id = p_lead_id
       and ev.event_type not in ('criado', 'pontuacao_alterada'))
     and not exists (select 1 from public.opportunities o where o.lead_id = p_lead_id)
     and not exists (select 1 from public.crm_tasks t where t.lead_id = p_lead_id)
     and not exists (select 1 from public.lead_tags lt where lt.lead_id = p_lead_id)
$$;
revoke all on function public.lead_is_untouched(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 8. Migração dos dados existentes (sem perder histórico)
-- ---------------------------------------------------------------------
-- Leads trabalhados viram uma oportunidade na etapa correspondente
insert into public.opportunities (lead_id, title, stage_code, owner_id, value, lost_reason, won_at, source, created_at)
select l.id,
       'Prospecção — ' || coalesce(e.nome_fantasia, c.razao_social, l.cnpj),
       case l.stage when 'novo' then 'novo_lead' when 'validado' then 'em_qualificacao'
                    when 'pronto_contato' then 'qualificado' when 'primeiro_contato' then 'primeiro_contato'
                    when 'aguardando_resposta' then 'aguardando_retorno' when 'interessado' then 'interessado'
                    when 'proposta_enviada' then 'proposta_enviada' when 'em_negociacao' then 'em_negociacao'
                    when 'convertido' then 'contrato_fechado' when 'perdido' then 'perdido' end,
       l.owner_id,
       (select p.amount from public.lead_proposals p where p.lead_id = l.id order by p.created_at desc limit 1),
       case when l.stage = 'perdido' then coalesce(l.lost_reason, 'Perdido antes da 2.0') end,
       l.converted_at,
       'migracao',
       l.created_at
  from public.leads l
  join public.establishments e on e.cnpj = l.cnpj
  join public.companies c on c.cnpj_basico = l.cnpj_basico
 where (l.stage <> 'novo' or l.owner_id is not null
        or exists (select 1 from public.lead_proposals p where p.lead_id = l.id)
        or exists (select 1 from public.lead_events ev where ev.lead_id = l.id
                    and ev.event_type in ('anotacao', 'contato', 'resposta_recebida')))
   and not exists (select 1 from public.opportunities o where o.lead_id = l.id)
   and not exists (select 1 from public.contact_suppressions s where s.cnpj_basico = l.cnpj_basico);

update public.lead_proposals p set opportunity_id = o.id
  from public.opportunities o
 where o.lead_id = p.lead_id and o.source = 'migracao' and p.opportunity_id is null;

-- Follow-ups pendentes viram tarefas
insert into public.crm_tasks (lead_id, opportunity_id, kind, title, due_at, owner_id)
select l.id, (select o.id from public.opportunities o where o.lead_id = l.id and o.status = 'aberta' limit 1),
       'follow_up', 'Follow-up', l.next_follow_up_at, l.owner_id
  from public.leads l
 where l.next_follow_up_at is not null
   and not exists (select 1 from public.crm_tasks t where t.lead_id = l.id and t.kind = 'follow_up' and t.done_at is null);

-- Leads convertidos viram clientes com contrato a partir da proposta aceita, se houver
insert into public.contracts (lead_id, opportunity_id, title, total_value, signed_at, status, notes)
select o.lead_id, o.id, coalesce(p.title, o.title), p.amount, coalesce(o.won_at, now())::date, 'ativo',
       'Contrato registrado automaticamente na migração para a 2.0 (lead convertido)'
  from public.opportunities o
  left join lateral (select * from public.lead_proposals pr where pr.lead_id = o.lead_id and pr.status = 'aceita'
                      order by pr.decided_at desc nulls last limit 1) p on true
 where o.source = 'migracao' and o.status = 'ganha'
   and not exists (select 1 from public.contracts ct where ct.lead_id = o.lead_id);

select public.take_inventory_snapshot('migration 013 (CRM profissional)');
