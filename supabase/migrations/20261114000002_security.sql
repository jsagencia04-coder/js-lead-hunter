-- =====================================================================
-- JS Lead Hunter — Etapa 1 — Segurança, RLS, auditoria e regras de CRM
-- =====================================================================

-- ---------------------------------------------------------------------
-- Funções de papel (security definer para evitar recursão de RLS)
-- ---------------------------------------------------------------------
create or replace function public.current_app_role()
returns public.app_role
language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid() and active
$$;

create or replace function public.has_role(roles public.app_role[])
returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.current_app_role() = any (roles), false)
$$;

create or replace function public.is_active_user()
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and active)
$$;

revoke all on function public.current_app_role() from public, anon;
revoke all on function public.has_role(public.app_role[]) from public, anon;
revoke all on function public.is_active_user() from public, anon;
grant execute on function public.current_app_role() to authenticated;
grant execute on function public.has_role(public.app_role[]) to authenticated;
grant execute on function public.is_active_user() to authenticated;

-- ---------------------------------------------------------------------
-- Perfil automático ao criar usuário.
-- O primeiro usuário do sistema vira admin; os demais entram como
-- 'leitura' até um admin definir o papel.
-- ---------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, full_name, role)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'full_name', split_part(new.email, '@', 1)),
    case when exists (select 1 from public.profiles where role = 'admin')
         then 'leitura'::public.app_role else 'admin'::public.app_role end
  );
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Impede que um usuário comum altere o próprio papel ou status
create or replace function public.protect_profile_privileges()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (new.role is distinct from old.role or new.active is distinct from old.active
      or new.email is distinct from old.email)
     and auth.uid() is not null
     and not public.has_role(array['admin']::public.app_role[]) then
    raise exception 'Somente administradores podem alterar papel, status ou e-mail de usuários';
  end if;
  if new.id = auth.uid() and old.role = 'admin' and new.role <> 'admin' then
    raise exception 'Um administrador não pode remover o próprio acesso de administrador';
  end if;
  return new;
end $$;

create trigger profiles_protect_privileges
  before update on public.profiles
  for each row execute function public.protect_profile_privileges();

-- ---------------------------------------------------------------------
-- Auditoria genérica
-- ---------------------------------------------------------------------
create or replace function public.audit_trigger()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  rec_id text;
begin
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

do $$
declare t text;
begin
  foreach t in array array[
    'profiles', 'leads', 'contact_suppressions', 'service_catalog',
    'cnae_service_rules', 'scoring_rules', 'message_templates', 'integration_status'
  ] loop
    execute format(
      'create trigger %I after insert or update or delete on public.%I for each row execute function public.audit_trigger()',
      t || '_audit', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Regras de CRM
-- ---------------------------------------------------------------------

-- Bloqueia criação de lead para empresa com oposição ao contato
create or replace function public.leads_check_suppression()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.contact_suppressions s where s.cnpj_basico = new.cnpj_basico) then
    raise exception 'Empresa % está bloqueada para contato', new.cnpj_basico
      using errcode = 'check_violation';
  end if;
  return new;
end $$;

create trigger leads_check_suppression
  before insert on public.leads
  for each row execute function public.leads_check_suppression();

-- Registra automaticamente toda movimentação do lead
create or replace function public.leads_track_changes()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into public.lead_events (lead_id, event_type, to_stage, actor_id, metadata)
    values (new.id, 'criado', new.stage, auth.uid(), jsonb_build_object('source', new.source));
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
  if new.score is distinct from old.score then
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

create trigger leads_track_changes
  after insert or update on public.leads
  for each row execute function public.leads_track_changes();

create or replace function public.leads_set_converted_at()
returns trigger language plpgsql as $$
begin
  if new.stage = 'convertido' and (tg_op = 'INSERT' or old.stage is distinct from 'convertido') then
    new.converted_at := now();
  elsif new.stage <> 'convertido' then
    new.converted_at := null;
  end if;
  return new;
end $$;

create trigger leads_set_converted_at
  before insert or update of stage on public.leads
  for each row execute function public.leads_set_converted_at();

-- Ao bloquear uma empresa, o lead existente vai para "perdido" e o bloqueio é registrado
create or replace function public.suppression_apply_to_lead()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.leads
     set stage = 'perdido',
         lost_reason = coalesce(lost_reason, 'Bloqueado para contato: ' || new.reason),
         next_follow_up_at = null
   where cnpj_basico = new.cnpj_basico and stage <> 'convertido';

  insert into public.lead_events (lead_id, event_type, content, actor_id)
  select id, 'bloqueado', new.reason, auth.uid()
    from public.leads where cnpj_basico = new.cnpj_basico;
  return new;
end $$;

create trigger suppression_apply_to_lead
  after insert on public.contact_suppressions
  for each row execute function public.suppression_apply_to_lead();

-- =====================================================================
-- RLS
-- Nada é acessível sem autenticação: nenhuma política para 'anon'.
-- Escrita em dados cadastrais e importações: só o worker (service_role,
-- que ignora RLS) — nunca pelo frontend.
-- =====================================================================
alter table public.profiles              enable row level security;
alter table public.cnae_catalog          enable row level security;
alter table public.municipalities        enable row level security;
alter table public.legal_natures         enable row level security;
alter table public.companies             enable row level security;
alter table public.company_simple_status enable row level security;
alter table public.establishments        enable row level security;
alter table public.service_catalog       enable row level security;
alter table public.cnae_service_rules    enable row level security;
alter table public.scoring_rules         enable row level security;
alter table public.leads                 enable row level security;
alter table public.lead_events           enable row level security;
alter table public.lead_recommendations  enable row level security;
alter table public.lead_searches         enable row level security;
alter table public.contact_suppressions  enable row level security;
alter table public.message_templates     enable row level security;
alter table public.message_logs          enable row level security;
alter table public.import_jobs           enable row level security;
alter table public.integration_status    enable row level security;
alter table public.audit_logs            enable row level security;

revoke all on all tables in schema public from anon;

-- Perfis
create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_active_user());
create policy profiles_update_self on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());
create policy profiles_update_admin on public.profiles for update to authenticated
  using (public.has_role(array['admin']::public.app_role[]))
  with check (public.has_role(array['admin']::public.app_role[]));

-- Dados cadastrais e referências: leitura para usuários ativos
do $$
declare t text;
begin
  foreach t in array array[
    'cnae_catalog', 'municipalities', 'legal_natures', 'companies',
    'company_simple_status', 'establishments'
  ] loop
    execute format(
      'create policy %I on public.%I for select to authenticated using (public.is_active_user())',
      t || '_select', t);
  end loop;
end $$;

-- Catálogo e regras: leitura geral, escrita só admin
do $$
declare t text;
begin
  foreach t in array array['service_catalog', 'cnae_service_rules', 'scoring_rules', 'message_templates'] loop
    execute format(
      'create policy %I on public.%I for select to authenticated using (public.is_active_user())',
      t || '_select', t);
    execute format(
      'create policy %I on public.%I for all to authenticated
         using (public.has_role(array[''admin'']::public.app_role[]))
         with check (public.has_role(array[''admin'']::public.app_role[]))',
      t || '_admin_write', t);
  end loop;
end $$;

-- Leads
create policy leads_select on public.leads for select to authenticated
  using (public.is_active_user());
create policy leads_insert on public.leads for insert to authenticated
  with check (public.has_role(array['admin', 'gestor', 'comercial']::public.app_role[]));
create policy leads_update on public.leads for update to authenticated
  using (public.has_role(array['admin', 'gestor', 'comercial']::public.app_role[]))
  with check (public.has_role(array['admin', 'gestor', 'comercial']::public.app_role[]));
create policy leads_delete on public.leads for delete to authenticated
  using (public.has_role(array['admin']::public.app_role[]));

-- Histórico: imutável (sem update/delete pelo cliente)
create policy lead_events_select on public.lead_events for select to authenticated
  using (public.is_active_user());
create policy lead_events_insert on public.lead_events for insert to authenticated
  with check (
    public.has_role(array['admin', 'gestor', 'comercial']::public.app_role[])
    and actor_id = auth.uid()
    and event_type in ('anotacao', 'contato', 'follow_up_concluido'));

create policy lead_recommendations_select on public.lead_recommendations for select to authenticated
  using (public.is_active_user());
create policy lead_recommendations_write on public.lead_recommendations for all to authenticated
  using (public.has_role(array['admin', 'gestor']::public.app_role[]))
  with check (public.has_role(array['admin', 'gestor']::public.app_role[]));

-- Pesquisas salvas: próprias ou compartilhadas
create policy lead_searches_select on public.lead_searches for select to authenticated
  using (public.is_active_user() and (owner_id = auth.uid() or is_shared));
create policy lead_searches_write on public.lead_searches for all to authenticated
  using (owner_id = auth.uid() and public.is_active_user())
  with check (owner_id = auth.uid() and public.is_active_user());

-- Oposição ao contato
create policy suppressions_select on public.contact_suppressions for select to authenticated
  using (public.is_active_user());
create policy suppressions_insert on public.contact_suppressions for insert to authenticated
  with check (public.has_role(array['admin', 'gestor', 'comercial']::public.app_role[])
              and created_by = auth.uid());
create policy suppressions_delete on public.contact_suppressions for delete to authenticated
  using (public.has_role(array['admin']::public.app_role[]));

-- Mensagens: só leitura no cliente (envio virá por Edge Function)
create policy message_logs_select on public.message_logs for select to authenticated
  using (public.has_role(array['admin', 'gestor', 'comercial']::public.app_role[]));

-- Importações e integrações
create policy import_jobs_select on public.import_jobs for select to authenticated
  using (public.has_role(array['admin', 'gestor']::public.app_role[]));
create policy integration_status_select on public.integration_status for select to authenticated
  using (public.is_active_user());

-- Auditoria: só admin lê; escrita só via trigger
create policy audit_logs_select on public.audit_logs for select to authenticated
  using (public.has_role(array['admin']::public.app_role[]));

-- =====================================================================
-- RPCs usadas pela interface
-- =====================================================================

-- Solicita verificação/importação. Apenas enfileira: quem executa é o worker.
create or replace function public.request_import(p_job_type text default 'verificacao')
returns public.import_jobs
language plpgsql security definer set search_path = public as $$
declare
  job public.import_jobs;
begin
  if not public.has_role(array['admin']::public.app_role[]) then
    raise exception 'Apenas administradores podem solicitar importações';
  end if;
  if p_job_type not in ('verificacao', 'importacao') then
    raise exception 'Tipo de job inválido: %', p_job_type;
  end if;
  if exists (select 1 from public.import_jobs
              where status in ('pendente', 'baixando', 'processando', 'validando')) then
    raise exception 'Já existe uma solicitação pendente ou em execução';
  end if;
  insert into public.import_jobs (job_type, status, trigger_type, requested_by)
  values (p_job_type, 'pendente', 'manual', auth.uid())
  returning * into job;
  return job;
end $$;
revoke all on function public.request_import(text) from public, anon;
grant execute on function public.request_import(text) to authenticated;

create or replace function public.cancel_import(p_job_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role(array['admin']::public.app_role[]) then
    raise exception 'Apenas administradores podem cancelar importações';
  end if;
  update public.import_jobs set status = 'cancelado', finished_at = now()
   where id = p_job_id and status = 'pendente';
  if not found then
    raise exception 'Somente solicitações pendentes podem ser canceladas';
  end if;
end $$;
revoke all on function public.cancel_import(uuid) from public, anon;
grant execute on function public.cancel_import(uuid) to authenticated;

-- Indicadores do dashboard (respeita RLS: security invoker)
create or replace function public.dashboard_metrics(
  p_uf text default null, p_ref_date date default current_date, p_municipio text default null)
returns jsonb
language sql stable security invoker set search_path = public as $$
  with est as (
    select e.*, c.porte
      from public.establishments e
      join public.companies c on c.cnpj_basico = e.cnpj_basico
     where e.identificador_matriz = 1
       and (p_uf is null or e.uf = p_uf)
       and (p_municipio is null or e.municipio_code = p_municipio)
  ),
  ld as (
    select l.* from public.leads l
      join public.establishments e on e.cnpj = l.cnpj
     where (p_uf is null or e.uf = p_uf)
       and (p_municipio is null or e.municipio_code = p_municipio)
  ),
  cur as (
    select competence, reference_date, finished_at
      from public.import_jobs where is_current limit 1
  ),
  last_job as (
    select job_type, status, created_at, finished_at, competence
      from public.import_jobs order by created_at desc limit 1
  )
  select jsonb_build_object(
    'total',        (select count(*) from est),
    'ativas',       (select count(*) from est where situacao_cadastral = '02'),
    'ultimos_7',    (select count(*) from est where situacao_cadastral = '02' and data_inicio_atividade > p_ref_date - 7),
    'ultimos_15',   (select count(*) from est where situacao_cadastral = '02' and data_inicio_atividade > p_ref_date - 15),
    'ultimos_30',   (select count(*) from est where situacao_cadastral = '02' and data_inicio_atividade > p_ref_date - 30),
    'ultimos_90',   (select count(*) from est where situacao_cadastral = '02' and data_inicio_atividade > p_ref_date - 90),
    'com_telefone', (select count(*) from est where has_phone),
    'com_email',    (select count(*) from est where has_email),
    'leads_alta',   (select count(*) from ld where priority = 'alta'),
    'leads_contatados', (select count(*) from ld where stage in (
                      'primeiro_contato', 'aguardando_resposta', 'interessado',
                      'proposta_enviada', 'em_negociacao', 'convertido')),
    'leads_convertidos', (select count(*) from ld where stage = 'convertido'),
    'por_uf', coalesce((select jsonb_agg(x order by x.total desc) from (
                select uf as label, count(*) as total from est where situacao_cadastral = '02'
                 group by uf) x), '[]'::jsonb),
    'por_municipio', coalesce((select jsonb_agg(x order by x.total desc) from (
                select m.name || ' / ' || coalesce(m.uf, '') as label, count(*) as total
                  from est join public.municipalities m on m.code = est.municipio_code
                 where situacao_cadastral = '02'
                 group by m.name, m.uf order by count(*) desc limit 10) x), '[]'::jsonb),
    'por_cnae', coalesce((select jsonb_agg(x order by x.total desc) from (
                select coalesce(k.description, est.cnae_principal) as label, count(*) as total
                  from est left join public.cnae_catalog k on k.code = est.cnae_principal
                 where situacao_cadastral = '02'
                 group by k.description, est.cnae_principal order by count(*) desc limit 10) x), '[]'::jsonb),
    'por_porte', coalesce((select jsonb_agg(x order by x.total desc) from (
                select case porte when '01' then 'Microempresa' when '03' then 'Pequeno porte'
                                  when '05' then 'Demais' else 'Não informado' end as label,
                       count(*) as total
                  from est where situacao_cadastral = '02' group by 1) x), '[]'::jsonb),
    'por_mes_abertura', coalesce((select jsonb_agg(x order by x.label) from (
                select to_char(date_trunc('month', data_inicio_atividade), 'YYYY-MM') as label, count(*) as total
                  from est
                 where situacao_cadastral = '02'
                   and data_inicio_atividade >= date_trunc('month', p_ref_date) - interval '11 months'
                 group by 1) x), '[]'::jsonb),
    'competencia_vigente', (select to_jsonb(cur) from cur),
    'ultimo_job', (select to_jsonb(last_job) from last_job)
  )
$$;
revoke all on function public.dashboard_metrics(text, date, text) from public, anon;
grant execute on function public.dashboard_metrics(text, date, text) to authenticated;

-- Visão de listagem de leads (security_invoker: aplica a RLS de quem consulta)
create or replace view public.lead_list_v with (security_invoker = true) as
select
  l.id, l.cnpj, l.cnpj_basico, l.stage, l.score, l.priority, l.owner_id,
  l.next_follow_up_at, l.website, l.created_at,
  c.razao_social, e.nome_fantasia, c.porte, c.capital_social,
  e.situacao_cadastral, e.data_inicio_atividade, e.cnae_principal,
  k.description as cnae_descricao, e.cnaes_secundarios,
  e.uf, e.municipio_code, m.name as municipio,
  e.ddd1, e.telefone1, e.email, e.has_phone, e.has_email,
  s.opcao_simples, s.opcao_mei,
  p.full_name as owner_name
from public.leads l
join public.establishments e on e.cnpj = l.cnpj
join public.companies c on c.cnpj_basico = l.cnpj_basico
left join public.cnae_catalog k on k.code = e.cnae_principal
left join public.municipalities m on m.code = e.municipio_code
left join public.company_simple_status s on s.cnpj_basico = l.cnpj_basico
left join public.profiles p on p.id = l.owner_id;

revoke all on public.lead_list_v from anon;
grant select on public.lead_list_v to authenticated;
