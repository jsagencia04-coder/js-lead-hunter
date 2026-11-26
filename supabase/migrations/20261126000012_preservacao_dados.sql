-- =====================================================================
-- JS Lead Hunter 2.0 — Fase 1: preservação dos dados
-- Somente alterações ADITIVAS. Nenhum dado existente é apagado.
--   * arquivamento automático por idade DESLIGADO (a janela é só filtro)
--   * importação sem espaço: para com segurança e avisa (nunca arquiva)
--   * histórico de alterações cadastrais
--   * recuperação de leads arquivados
--   * inventário de registros (antes/depois de cada rodada do worker)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Política de armazenamento: nada é excluído automaticamente
-- ---------------------------------------------------------------------
update public.app_settings
   set value = value
         || jsonb_build_object('ativo', false, 'liberar_espaco_na_importacao', false,
                               'politica_anterior', value - 'politica_anterior',
                               'desativado_em', now(),
                               'motivo_desativacao', 'JS Lead Hunter 2.0: empresas não são excluídas por idade; a janela de captação é só filtro'),
       description = 'Arquivamento automático DESATIVADO por política de preservação. Leads sem contato permanecem na base. '
                     || 'Se o banco ficar sem espaço, a importação é interrompida com aviso ao administrador.',
       updated_at = now()
 where key = 'arquivamento';

-- ---------------------------------------------------------------------
-- 2. Histórico de alterações cadastrais (a cada importação)
-- ---------------------------------------------------------------------
create table if not exists public.registry_changes (
  id            bigint generated always as identity primary key,
  entity        text not null check (entity in ('estabelecimento', 'empresa')),
  key           text not null,              -- CNPJ completo ou CNPJ básico
  changes       jsonb not null,             -- {"campo": {"de": ..., "para": ...}}
  competence    text,
  changed_at    timestamptz not null default now()
);
create index if not exists registry_changes_key_idx on public.registry_changes (key, changed_at desc);
alter table public.registry_changes enable row level security;
revoke all on public.registry_changes from anon;
drop policy if exists registry_changes_select on public.registry_changes;
create policy registry_changes_select on public.registry_changes for select to authenticated
  using (public.is_active_user());

create or replace function public.jsonb_diff(p_old jsonb, p_new jsonb, p_fields text[])
returns jsonb language sql immutable as $$
  select coalesce(jsonb_object_agg(f, jsonb_build_object('de', p_old -> f, 'para', p_new -> f)), '{}'::jsonb)
    from unnest(p_fields) f
   where (p_old -> f) is distinct from (p_new -> f)
$$;

create or replace function public.track_registry_changes()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  d jsonb;
begin
  if tg_table_name = 'establishments' then
    d := public.jsonb_diff(to_jsonb(old), to_jsonb(new), array[
      'situacao_cadastral', 'data_situacao_cadastral', 'motivo_situacao', 'nome_fantasia', 'cnae_principal',
      'cnaes_secundarios', 'tipo_logradouro', 'logradouro', 'numero', 'complemento', 'bairro', 'cep', 'uf',
      'municipio_code', 'ddd1', 'telefone1', 'ddd2', 'telefone2', 'email', 'identificador_matriz',
      'situacao_especial', 'data_situacao_especial']);
    if d <> '{}'::jsonb then
      insert into public.registry_changes (entity, key, changes, competence)
      values ('estabelecimento', new.cnpj, d, new.source_competence);
    end if;
  else
    d := public.jsonb_diff(to_jsonb(old), to_jsonb(new), array[
      'razao_social', 'natureza_juridica', 'capital_social', 'porte', 'ente_federativo']);
    if d <> '{}'::jsonb then
      insert into public.registry_changes (entity, key, changes, competence)
      values ('empresa', new.cnpj_basico, d, new.source_competence);
    end if;
  end if;
  return new;
end $$;

drop trigger if exists establishments_registry_changes on public.establishments;
create trigger establishments_registry_changes after update on public.establishments
  for each row execute function public.track_registry_changes();
drop trigger if exists companies_registry_changes on public.companies;
create trigger companies_registry_changes after update on public.companies
  for each row execute function public.track_registry_changes();

-- ---------------------------------------------------------------------
-- 3. Recuperação de leads arquivados
--    O arquivo guarda uma ficha resumida. Para restaurar o cadastro
--    completo, o worker relê a empresa nos arquivos oficiais da Receita
--    na próxima importação e recria o lead (origem "restaurado").
-- ---------------------------------------------------------------------
alter table public.lead_archive add column if not exists restore_requested_at timestamptz;
alter table public.lead_archive add column if not exists restore_requested_by uuid references public.profiles (id) on delete set null;
alter table public.lead_archive add column if not exists restored_at timestamptz;
alter table public.lead_archive add column if not exists restored_lead_id uuid references public.leads (id) on delete set null;
alter table public.lead_archive add column if not exists restore_note text;
create index if not exists lead_archive_restore_idx on public.lead_archive (restore_requested_at)
  where restore_requested_at is not null and restored_at is null;

alter table public.leads drop constraint if exists leads_source_check;
alter table public.leads add constraint leads_source_check check (source in ('importacao', 'manual', 'restaurado'));

-- Solicitação (admin e gestor): por lista de CNPJs ou "todos os pendentes"
create or replace function public.request_archive_restore(p_cnpjs text[] default null, p_all boolean default false)
returns integer
language plpgsql security definer set search_path = public as $$
declare
  n integer;
begin
  if not public.has_role(array['admin', 'gestor']::public.app_role[]) then
    raise exception 'Apenas administradores e gestores podem restaurar leads arquivados';
  end if;
  if p_cnpjs is null and not p_all then
    raise exception 'Informe os CNPJs ou confirme a restauração de todos';
  end if;
  update public.lead_archive
     set restore_requested_at = now(), restore_requested_by = auth.uid(), restore_note = null
   where restored_at is null and restore_requested_at is null
     and (p_all or cnpj = any (p_cnpjs));
  get diagnostics n = row_count;
  insert into public.audit_logs (actor_id, action, table_name, record_id, new_data)
  values (auth.uid(), 'UPDATE', 'lead_archive', 'restauracao_solicitada', jsonb_build_object('quantidade', n, 'todos', p_all));
  return n;
end $$;
revoke all on function public.request_archive_restore(text[], boolean) from public, anon;
grant execute on function public.request_archive_restore(text[], boolean) to authenticated;

create or replace function public.cancel_archive_restore(p_cnpjs text[])
returns integer
language plpgsql security definer set search_path = public as $$
declare
  n integer;
begin
  if not public.has_role(array['admin', 'gestor']::public.app_role[]) then
    raise exception 'Apenas administradores e gestores';
  end if;
  update public.lead_archive set restore_requested_at = null, restore_requested_by = null
   where restored_at is null and cnpj = any (p_cnpjs);
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.cancel_archive_restore(text[]) from public, anon;
grant execute on function public.cancel_archive_restore(text[]) to authenticated;

-- CNPJs que o worker deve reler nos arquivos oficiais
create or replace function public.worker_restore_targets()
returns setof text
language sql stable security definer set search_path = public as $$
  select cnpj from public.lead_archive where restore_requested_at is not null and restored_at is null
$$;
revoke all on function public.worker_restore_targets() from public, anon, authenticated;

-- Recria os leads cujo cadastro voltou a existir (executado pelo worker na carga)
create or replace function public.worker_restore_archived_leads(p_import_job_id uuid)
returns integer
language plpgsql security definer set search_path = public as $$
declare
  n integer;
begin
  -- empresas bloqueadas não voltam ao CRM
  update public.lead_archive a
     set restore_note = 'Empresa bloqueada para contato: não restaurada'
   where a.restore_requested_at is not null and a.restored_at is null
     and exists (select 1 from public.contact_suppressions s where s.cnpj_basico = a.cnpj_basico);

  with alvo as (
    select a.cnpj, a.cnpj_basico
      from public.lead_archive a
      join public.establishments e on e.cnpj = a.cnpj
     where a.restore_requested_at is not null and a.restored_at is null
       and not exists (select 1 from public.contact_suppressions s where s.cnpj_basico = a.cnpj_basico)
       and not exists (select 1 from public.leads l where l.cnpj_basico = a.cnpj_basico)
  ),
  novos as (
    insert into public.leads (cnpj_basico, cnpj, source, import_job_id)
    select cnpj_basico, cnpj, 'restaurado', p_import_job_id from alvo
    on conflict do nothing
    returning id, cnpj
  )
  update public.lead_archive a
     set restored_at = now(), restored_lead_id = novos.id, restore_note = null
    from novos where novos.cnpj = a.cnpj;
  get diagnostics n = row_count;

  -- já existe lead para a empresa (ex.: recriado por outra via): marca como restaurado
  update public.lead_archive a
     set restored_at = now(), restored_lead_id = l.id, restore_note = 'Empresa já estava na base operacional'
    from public.leads l
   where l.cnpj_basico = a.cnpj_basico and a.restore_requested_at is not null and a.restored_at is null;

  -- cadastro não encontrado nos arquivos oficiais (ex.: CNPJ baixado/excluído da base pública)
  update public.lead_archive a
     set restore_note = 'Cadastro não encontrado na competência ' || coalesce(
           (select competence from public.import_jobs where id = p_import_job_id), '?')
   where a.restore_requested_at is not null and a.restored_at is null
     and a.restore_note is null
     and not exists (select 1 from public.establishments e where e.cnpj = a.cnpj);
  return n;
end $$;
revoke all on function public.worker_restore_archived_leads(uuid) from public, anon, authenticated;

-- worker_create_leads continua ignorando arquivados ainda não restaurados
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
     and not exists (select 1 from public.lead_archive a
                      where a.cnpj_basico = e.cnpj_basico and a.restore_requested_at is null)
   order by e.cnpj_basico, e.identificador_matriz, e.cnpj
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.worker_create_leads(uuid, date, date, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. Inventário de registros (evidência antes/depois)
-- ---------------------------------------------------------------------
create table if not exists public.data_inventory_snapshots (
  id          bigint generated always as identity primary key,
  taken_at    timestamptz not null default now(),
  label       text not null,
  counts      jsonb not null
);
alter table public.data_inventory_snapshots enable row level security;
revoke all on public.data_inventory_snapshots from anon;
drop policy if exists data_inventory_select on public.data_inventory_snapshots;
create policy data_inventory_select on public.data_inventory_snapshots for select to authenticated
  using (public.has_role(array['admin', 'gestor']::public.app_role[]));

create or replace function public.data_inventory()
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'empresas', (select count(*) from public.companies),
    'estabelecimentos', (select count(*) from public.establishments),
    'leads', (select count(*) from public.leads),
    'leads_ativos', (select count(*) from public.leads where stage not in ('convertido', 'perdido')),
    'leads_por_etapa', (select coalesce(jsonb_object_agg(stage, n), '{}'::jsonb)
                          from (select stage, count(*) n from public.leads group by stage) x),
    'leads_arquivados', (select count(*) from public.lead_archive),
    'arquivados_restauracao_pendente', (select count(*) from public.lead_archive
                                         where restore_requested_at is not null and restored_at is null),
    'arquivados_restaurados', (select count(*) from public.lead_archive where restored_at is not null),
    'eventos', (select count(*) from public.lead_events),
    'eventos_comerciais', (select count(*) from public.lead_events
                            where event_type not in ('criado', 'pontuacao_alterada')),
    'contatos', (select count(*) from public.lead_events where event_type = 'contato'),
    'respostas', (select count(*) from public.lead_events where event_type = 'resposta_recebida'),
    'propostas', (select count(*) from public.lead_proposals),
    'bloqueios', (select count(*) from public.contact_suppressions),
    'usuarios', (select count(*) from public.profiles),
    'alteracoes_cadastrais', (select count(*) from public.registry_changes),
    'competencia_vigente', (select competence from public.import_jobs where is_current limit 1),
    'banco_mb', round(pg_database_size(current_database()) / 1048576.0))
$$;
revoke all on function public.data_inventory() from public, anon, authenticated;

create or replace function public.take_inventory_snapshot(p_label text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c jsonb := public.data_inventory();
begin
  if auth.uid() is not null and not public.has_role(array['admin']::public.app_role[]) then
    raise exception 'Apenas administradores';
  end if;
  insert into public.data_inventory_snapshots (label, counts) values (left(p_label, 120), c);
  return c;
end $$;
revoke all on function public.take_inventory_snapshot(text) from public, anon;
grant execute on function public.take_inventory_snapshot(text) to authenticated;

-- Retrato antes de qualquer alteração da 2.0
select public.take_inventory_snapshot('migration 012 (antes da 2.0)');
