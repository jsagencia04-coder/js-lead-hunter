-- =====================================================================
-- JS Lead Hunter — Arquivamento automático de leads sem contato
-- Leads que ninguém tocou (etapa "Novo lead", sem responsável, sem
-- follow-up e sem anotação/contato) saem do banco operacional e ficam
-- numa ficha resumida em lead_archive. Libera espaço para as próximas
-- competências. Leads com qualquer movimentação nunca são arquivados.
-- =====================================================================

-- Configurações editáveis pelo administrador
create table public.app_settings (
  key         text primary key check (key ~ '^[a-z0-9_]+$'),
  value       jsonb not null,
  description text,
  updated_at  timestamptz not null default now()
);
alter table public.app_settings enable row level security;
create policy app_settings_select on public.app_settings for select to authenticated
  using (public.is_active_user());
create policy app_settings_admin_write on public.app_settings for update to authenticated
  using (public.has_role(array['admin']::public.app_role[]))
  with check (public.has_role(array['admin']::public.app_role[]));
revoke all on public.app_settings from anon;
create trigger app_settings_audit after insert or update or delete on public.app_settings
  for each row execute function public.audit_trigger();

insert into public.app_settings (key, value, description) values
  ('arquivamento',
   '{"ativo": true, "dias": 30, "dias_alta": 60, "liberar_espaco_na_importacao": true}',
   'Arquiva leads sem nenhum contato (etapa Novo lead, sem responsável, follow-up, anotação ou contato) após o número de dias; leads de alta prioridade usam dias_alta.');

-- Ficha resumida dos leads arquivados (sem índices extras, para ocupar pouco espaço)
create table public.lead_archive (
  cnpj                  text primary key,
  cnpj_basico           text not null,
  razao_social          text,
  nome_fantasia         text,
  uf                    char(2),
  municipio             text,
  cnae_principal        text,
  data_inicio_atividade date,
  telefone              text,
  email                 text,
  website               text,
  score                 smallint,
  priority              text,
  source_competence     text,
  lead_created_at       timestamptz,
  archived_at           timestamptz not null default now(),
  motivo                text not null
);
alter table public.lead_archive enable row level security;
create policy lead_archive_select on public.lead_archive for select to authenticated
  using (public.is_active_user());
revoke all on public.lead_archive from anon;

-- Lead "intocado": nenhuma ação comercial
create or replace function public.lead_is_untouched(p_lead_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select not exists (
    select 1 from public.lead_events ev
     where ev.lead_id = p_lead_id
       and ev.event_type not in ('criado', 'pontuacao_alterada'))
$$;

-- Arquiva e remove do banco operacional.
--   p_dias / p_dias_alta: idade mínima (dias desde a criação do lead)
--   p_somente_anteriores: só leads de importações anteriores à vigente
--   p_incluir_alta: inclui leads de alta prioridade
create or replace function public.archive_stale_leads(
  p_dias integer,
  p_dias_alta integer,
  p_motivo text,
  p_somente_anteriores boolean default false,
  p_incluir_alta boolean default true)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  n_leads integer;
  n_est integer;
  n_emp integer;
  current_job uuid;
begin
  perform set_config('app.bulk_load', 'on', true);
  select id into current_job from public.import_jobs where is_current;

  create temp table _alvo on commit drop as
  select l.id, l.cnpj, l.cnpj_basico
    from public.leads l
   where l.stage = 'novo'
     and l.owner_id is null
     and l.next_follow_up_at is null
     and (p_incluir_alta or l.priority <> 'alta')
     and l.created_at < now() - make_interval(days => case when l.priority = 'alta' then p_dias_alta else p_dias end)
     and (not p_somente_anteriores or l.import_job_id is distinct from current_job)
     and public.lead_is_untouched(l.id);

  insert into public.lead_archive (cnpj, cnpj_basico, razao_social, nome_fantasia, uf, municipio, cnae_principal,
                                   data_inicio_atividade, telefone, email, website, score, priority,
                                   source_competence, lead_created_at, motivo)
  select l.cnpj, l.cnpj_basico, c.razao_social, e.nome_fantasia, e.uf, m.name, e.cnae_principal,
         e.data_inicio_atividade, nullif(concat(e.ddd1, e.telefone1), ''), e.email, l.website, l.score, l.priority,
         e.source_competence, l.created_at, p_motivo
    from _alvo a
    join public.leads l on l.id = a.id
    join public.establishments e on e.cnpj = l.cnpj
    join public.companies c on c.cnpj_basico = l.cnpj_basico
    left join public.municipalities m on m.code = e.municipio_code
  on conflict (cnpj) do nothing;

  delete from public.leads l using _alvo a where l.id = a.id;
  get diagnostics n_leads = row_count;

  -- dados cadastrais das empresas arquivadas (inclusive filiais), se não houver outro lead
  delete from public.establishments e
   using (select distinct cnpj_basico from _alvo) a
   where e.cnpj_basico = a.cnpj_basico
     and not exists (select 1 from public.leads l where l.cnpj_basico = e.cnpj_basico);
  get diagnostics n_est = row_count;

  delete from public.company_simple_status s
   using (select distinct cnpj_basico from _alvo) a
   where s.cnpj_basico = a.cnpj_basico
     and not exists (select 1 from public.establishments e where e.cnpj_basico = s.cnpj_basico);
  delete from public.companies c
   using (select distinct cnpj_basico from _alvo) a
   where c.cnpj_basico = a.cnpj_basico
     and not exists (select 1 from public.establishments e where e.cnpj_basico = c.cnpj_basico);
  get diagnostics n_emp = row_count;

  insert into public.audit_logs (actor_id, action, table_name, record_id, new_data)
  values (auth.uid(), 'DELETE', 'leads', 'arquivamento',
          jsonb_build_object('leads', n_leads, 'estabelecimentos', n_est, 'empresas', n_emp, 'motivo', p_motivo));

  return jsonb_build_object('leads', n_leads, 'estabelecimentos', n_est, 'empresas', n_emp);
end $$;
revoke all on function public.archive_stale_leads(integer, integer, text, boolean, boolean) from public, anon, authenticated;
revoke all on function public.lead_is_untouched(uuid) from public, anon, authenticated;

-- Números do arquivo para a interface
create or replace function public.archive_summary()
returns jsonb
language sql stable security invoker set search_path = public as $$
  select jsonb_build_object(
    'total', (select count(*) from public.lead_archive),
    'ultimo', (select max(archived_at) from public.lead_archive),
    'banco_mb', round(pg_database_size(current_database()) / 1048576.0),
    'elegiveis', (select count(*) from public.leads l
                   where l.stage = 'novo' and l.owner_id is null and l.next_follow_up_at is null))
$$;
revoke all on function public.archive_summary() from public, anon;
grant execute on function public.archive_summary() to authenticated;
