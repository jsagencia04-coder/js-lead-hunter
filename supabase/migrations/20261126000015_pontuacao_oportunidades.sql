-- =====================================================================
-- JS Lead Hunter 2.0 — Fase 4: pontuação versionada, catálogo de serviços,
-- Central de Oportunidades, assistente comercial e dashboard executivo.
-- Somente alterações ADITIVAS.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Catálogo de serviços: preços, pacotes, recorrência e condições
-- ---------------------------------------------------------------------
alter table public.service_catalog add column if not exists price_from numeric(12, 2) check (price_from is null or price_from >= 0);
alter table public.service_catalog add column if not exists price_to numeric(12, 2) check (price_to is null or price_to >= 0);
alter table public.service_catalog add column if not exists package text;
alter table public.service_catalog add column if not exists recurrence text not null default 'unico'
  check (recurrence in ('unico', 'mensal', 'trimestral', 'semestral', 'anual'));
alter table public.service_catalog add column if not exists payment_terms text;
alter table public.service_catalog add column if not exists deliverables text;

insert into public.service_catalog (code, name, description, sort_order, recurrence) values
  ('landing_page',      'Landing pages',                   'Página de captação para campanhas e lançamentos.', 42, 'unico'),
  ('loja_virtual',      'Lojas virtuais',                  'Loja on-line com catálogo, pagamento e frete.', 44, 'unico'),
  ('gestao_instagram',  'Gestão de Instagram',             'Planejamento, criação e publicação no Instagram.', 46, 'mensal'),
  ('seo',               'SEO',                             'Otimização para aparecer no Google.', 48, 'mensal'),
  ('presenca_digital',  'Estruturação de presença digital','Perfil no Google, site, redes e WhatsApp Business organizados.', 49, 'unico')
on conflict (code) do nothing;
update public.service_catalog set recurrence = 'mensal' where code = 'redes_sociais' and recurrence = 'unico';

insert into public.cnae_service_rules (cnae_prefix, service_id, relevance, reason)
select v.prefix, s.id, v.rel, v.motivo
  from (values
  ('47', 'loja_virtual', 75, 'Varejo pode vender também pela internet'),
  ('47', 'gestao_instagram', 80, 'Loja nova atrai clientes pelo Instagram'),
  ('56', 'gestao_instagram', 85, 'Alimentação depende de fotos e promoções no Instagram'),
  ('56', 'presenca_digital', 80, 'Clientes procuram restaurantes no Google Maps'),
  ('96', 'gestao_instagram', 85, 'Beleza e estética vivem de antes e depois no Instagram'),
  ('86', 'presenca_digital', 75, 'Pacientes procuram clínicas no Google'),
  ('86', 'seo', 60, 'Serviços de saúde são buscados no Google'),
  ('69', 'seo', 65, 'Escritórios profissionais são buscados no Google'),
  ('68', 'landing_page', 70, 'Lançamentos imobiliários usam páginas de captação'),
  ('85', 'landing_page', 70, 'Cursos captam alunos com landing pages'),
  ('93', 'gestao_instagram', 75, 'Academias divulgam aulas e resultados no Instagram'),
  ('45', 'presenca_digital', 70, 'Oficinas são encontradas no Google Maps'),
  ('43', 'presenca_digital', 65, 'Prestadores de obra são encontrados no Google Maps'),
  ('46', 'loja_virtual', 60, 'Atacado pode receber pedidos on-line')
  ) as v(prefix, code, rel, motivo)
  join public.service_catalog s on s.code = v.code
on conflict (cnae_prefix, service_id) do nothing;

-- Regras por evidência digital (editáveis)
create table if not exists public.digital_service_rules (
  id          uuid primary key default gen_random_uuid(),
  condition   text not null check (condition in ('site_nao_localizado', 'site_estacionado', 'site_problemas_tecnicos',
                                                 'site_sem_seo', 'instagram_nao_localizado', 'google_nao_localizado',
                                                 'sem_presenca_digital', 'whatsapp_nao_divulgado')),
  service_id  uuid not null references public.service_catalog (id) on delete cascade,
  relevance   smallint not null default 80 check (relevance between 0 and 100),
  reason      text not null,
  active      boolean not null default true,
  unique (condition, service_id)
);
alter table public.digital_service_rules enable row level security;
revoke all on public.digital_service_rules from anon;
create policy digital_service_rules_select on public.digital_service_rules for select to authenticated using (public.is_active_user());
create policy digital_service_rules_admin on public.digital_service_rules for all to authenticated
  using (public.has_role(array['admin']::public.app_role[])) with check (public.has_role(array['admin']::public.app_role[]));
create trigger digital_service_rules_audit after insert or update or delete on public.digital_service_rules
  for each row execute function public.audit_trigger();

insert into public.digital_service_rules (condition, service_id, relevance, reason)
select v.cond, s.id, v.rel, v.motivo
  from (values
  ('site_nao_localizado', 'site_institucional', 95, 'Pesquisa não localizou site da empresa'),
  ('site_nao_localizado', 'landing_page', 70, 'Sem site: uma página de apresentação já gera contatos'),
  ('site_estacionado', 'site_institucional', 95, 'O domínio da empresa só mostra página vazia ou estacionada'),
  ('site_problemas_tecnicos', 'site_institucional', 85, 'O site tem problemas técnicos verificados'),
  ('site_sem_seo', 'seo', 80, 'O site não tem informações básicas de SEO'),
  ('instagram_nao_localizado', 'gestao_instagram', 85, 'Pesquisa não localizou Instagram comercial'),
  ('instagram_nao_localizado', 'redes_sociais', 75, 'Pesquisa não localizou redes sociais comerciais'),
  ('google_nao_localizado', 'presenca_digital', 85, 'Sem Perfil da Empresa no Google'),
  ('sem_presenca_digital', 'presenca_digital', 95, 'Nem site, nem Instagram, nem Perfil no Google localizados'),
  ('whatsapp_nao_divulgado', 'presenca_digital', 60, 'O site não divulga WhatsApp')
  ) as v(cond, code, rel, motivo)
  join public.service_catalog s on s.code = v.code
on conflict (condition, service_id) do nothing;

-- ---------------------------------------------------------------------
-- 2. Sinais digitais por lead (base da pontuação, das recomendações e da Central)
-- ---------------------------------------------------------------------
create or replace view public.lead_digital_signals with (security_invoker = true) as
select l.id as lead_id, l.cnpj_basico,
       s.status as site_status, s.url as site_url, s.confidence as site_confidence,
       coalesce((s.result ->> 'nota')::int, null) as site_nota,
       coalesce((select count(*) from jsonb_array_elements(coalesce(s.result -> 'problemas', '[]'::jsonb)) p
                  where p ->> 'gravidade' = 'alta' and p ->> 'codigo' <> 'pagina_vazia_ou_estacionada'), 0) as site_problemas_altos,
       coalesce((select count(*) from jsonb_array_elements(coalesce(s.result -> 'problemas', '[]'::jsonb)) p), 0) as site_problemas,
       exists (select 1 from jsonb_array_elements(coalesce(s.result -> 'problemas', '[]'::jsonb)) p
                where p ->> 'codigo' = 'pagina_vazia_ou_estacionada') as site_estacionado,
       (select count(*) from jsonb_array_elements(coalesce(s.result -> 'problemas', '[]'::jsonb)) p
         where p ->> 'codigo' in ('sem_titulo', 'sem_meta_descricao', 'sem_h1', 'noindex')) >= 2 as site_sem_seo,
       i.status as instagram_status, i.url as instagram_url,
       f.status as facebook_status, f.url as facebook_url,
       g.status as google_status, g.url as google_url,
       w.status as whatsapp_status,
       lk.status as linkedin_status
  from public.leads l
  left join public.digital_channels s  on s.cnpj_basico = l.cnpj_basico and s.platform = 'site'
  left join public.digital_channels i  on i.cnpj_basico = l.cnpj_basico and i.platform = 'instagram'
  left join public.digital_channels f  on f.cnpj_basico = l.cnpj_basico and f.platform = 'facebook'
  left join public.digital_channels g  on g.cnpj_basico = l.cnpj_basico and g.platform = 'google_business'
  left join public.digital_channels w  on w.cnpj_basico = l.cnpj_basico and w.platform = 'whatsapp'
  left join public.digital_channels lk on lk.cnpj_basico = l.cnpj_basico and lk.platform = 'linkedin';
revoke all on public.lead_digital_signals from anon;
grant select on public.lead_digital_signals to authenticated;

-- Resumo por lead (sinais digitais + serviço principal), mantido pelo sistema para
-- a Central de Oportunidades e os indicadores responderem rápido com 100 mil+ empresas.
create table if not exists public.lead_insights (
  lead_id               uuid primary key references public.leads (id) on delete cascade,
  cnpj_basico           text not null,
  site_status           text, site_url text, site_nota integer,
  site_problemas        integer not null default 0,
  site_problemas_altos  integer not null default 0,
  site_estacionado      boolean not null default false,
  site_sem_seo          boolean not null default false,
  instagram_status      text, facebook_status text, google_status text, whatsapp_status text, linkedin_status text,
  servico_codigo        text, servico_nome text, servico_relevancia smallint,
  oportunidade_digital  boolean not null default false,
  updated_at            timestamptz not null default now()
);
create index if not exists lead_insights_site_idx on public.lead_insights (site_status);
create index if not exists lead_insights_insta_idx on public.lead_insights (instagram_status);
create index if not exists lead_insights_google_idx on public.lead_insights (google_status);
create index if not exists lead_insights_servico_idx on public.lead_insights (servico_codigo);
alter table public.lead_insights enable row level security;
revoke all on public.lead_insights from anon;
create policy lead_insights_select on public.lead_insights for select to authenticated using (public.is_active_user());

create or replace function public.refresh_lead_insights(p_lead_ids uuid[] default null)
returns integer
language plpgsql security definer set search_path = public as $$
declare
  n integer;
begin
  insert into public.lead_insights as li (lead_id, cnpj_basico, site_status, site_url, site_nota, site_problemas, site_problemas_altos,
         site_estacionado, site_sem_seo, instagram_status, facebook_status, google_status, whatsapp_status, linkedin_status,
         servico_codigo, servico_nome, servico_relevancia, oportunidade_digital, updated_at)
  select sg.lead_id, sg.cnpj_basico, sg.site_status, sg.site_url, sg.site_nota, sg.site_problemas, sg.site_problemas_altos,
         coalesce(sg.site_estacionado, false), coalesce(sg.site_sem_seo, false), sg.instagram_status, sg.facebook_status,
         sg.google_status, sg.whatsapp_status, sg.linkedin_status, ts.code, ts.name, ts.relevance,
         coalesce((l.score_breakdown ->> 'oportunidade_digital')::int, 0) > 0, now()
    from public.lead_digital_signals sg
    join public.leads l on l.id = sg.lead_id
    left join lateral (select s.code, s.name, lr.relevance from public.lead_recommendations lr
                         join public.service_catalog s on s.id = lr.service_id
                        where lr.lead_id = sg.lead_id order by lr.relevance desc, s.sort_order limit 1) ts on true
   where p_lead_ids is null or sg.lead_id = any (p_lead_ids)
  on conflict (lead_id) do update set
    site_status = excluded.site_status, site_url = excluded.site_url, site_nota = excluded.site_nota,
    site_problemas = excluded.site_problemas, site_problemas_altos = excluded.site_problemas_altos,
    site_estacionado = excluded.site_estacionado, site_sem_seo = excluded.site_sem_seo,
    instagram_status = excluded.instagram_status, facebook_status = excluded.facebook_status,
    google_status = excluded.google_status, whatsapp_status = excluded.whatsapp_status, linkedin_status = excluded.linkedin_status,
    servico_codigo = excluded.servico_codigo, servico_nome = excluded.servico_nome, servico_relevancia = excluded.servico_relevancia,
    oportunidade_digital = excluded.oportunidade_digital, updated_at = now()
  where (li.site_status, li.site_url, li.site_nota, li.site_problemas, li.instagram_status, li.facebook_status, li.google_status,
         li.whatsapp_status, li.servico_codigo, li.servico_relevancia, li.oportunidade_digital)
        is distinct from
        (excluded.site_status, excluded.site_url, excluded.site_nota, excluded.site_problemas, excluded.instagram_status,
         excluded.facebook_status, excluded.google_status, excluded.whatsapp_status, excluded.servico_codigo,
         excluded.servico_relevancia, excluded.oportunidade_digital);
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.refresh_lead_insights(uuid[]) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. Pontuação versionada e explicável
-- ---------------------------------------------------------------------
create table if not exists public.scoring_versions (
  id          integer generated always as identity primary key,
  rules       jsonb not null,
  created_at  timestamptz not null default now(),
  created_by  uuid references public.profiles (id) on delete set null,
  note        text
);
alter table public.scoring_versions enable row level security;
revoke all on public.scoring_versions from anon;
create policy scoring_versions_select on public.scoring_versions for select to authenticated using (public.is_active_user());

alter table public.leads add column if not exists score_version integer references public.scoring_versions (id);
alter table public.leads add column if not exists score_reasons jsonb not null default '{}'::jsonb;
alter table public.leads add column if not exists diagnosis_confidence smallint check (diagnosis_confidence between 0 and 100);

-- Novos pesos sugeridos (40/25/15/10/10). Só altera o que ainda está no padrão anterior.
insert into public.scoring_rules (key, label, description, points, params) values
  ('potencial_segmento', 'Potencial comercial do segmento',
   'Proporcional ao número de serviços da JS Designer aplicáveis ao CNAE (3 ou mais = integral).', 15, '{"servicos_para_integral": 3}'),
  ('canais_contato', 'Canais de contato verificados',
   'Telefone (30%) e e-mail (20%) no cadastro público + canal digital verificado (50%).', 10, '{}')
on conflict (key) do nothing;
update public.scoring_rules r set points = v.novo, updated_at = now()
  from (values ('oportunidade_digital', 30, 40), ('cnae_compativel', 35, 25), ('recencia', 15, 10)) as v(key, antigo, novo)
 where r.key = v.key and r.points = v.antigo;
update public.scoring_rules set active = false, updated_at = now()
 where (key in ('telefone', 'email') and points = 5) or (key = 'porte' and points = 10);
update public.scoring_rules set label = 'Compatibilidade com serviços' where key = 'cnae_compativel';
update public.scoring_rules set description =
  'Só pontua com evidência conclusiva: site não localizado após pesquisa (100%), domínio estacionado (90%), '
  || 'site com problemas técnicos graves (60%) ou leves (30%), Instagram não localizado com site verificado (40%). '
  || 'Empresas não pesquisadas ou com pesquisa inconclusiva não recebem estes pontos.'
 where key = 'oportunidade_digital';

create or replace function public.current_scoring_version()
returns integer
language plpgsql security definer set search_path = public as $$
declare
  snap jsonb := (select jsonb_object_agg(key, jsonb_build_object('pontos', points, 'ativo', active, 'params', params))
                   from public.scoring_rules)
                || jsonb_build_object('regras_cnae', (select md5(coalesce(string_agg(cnae_prefix || ':' || service_id || ':' || relevance
                                                                 || ':' || active, ',' order by cnae_prefix, service_id), ''))
                                                        from public.cnae_service_rules),
                                      'servicos_ativos', (select md5(coalesce(string_agg(id::text, ',' order by id), ''))
                                                            from public.service_catalog where active));
  v record;
begin
  select id, rules into v from public.scoring_versions order by id desc limit 1;
  if v.id is not null and v.rules = snap then
    return v.id;
  end if;
  insert into public.scoring_versions (rules, created_by, note) values (snap, auth.uid(), 'regras alteradas')
  returning id into v.id;
  return v.id;
end $$;
revoke all on function public.current_scoring_version() from public, anon, authenticated;

create or replace function public.recalculate_lead_scores(
  p_lead_ids uuid[] default null,
  p_import_job_id uuid default null,
  p_ref_date date default current_date)
returns integer
language plpgsql security definer set search_path = public as $$
declare
  n integer;
  ver integer := public.current_scoring_version();
begin
  with r as (
    select key, points, params from public.scoring_rules where active
  ),
  base as (
    select l.id, l.cnpj_basico, e.data_inicio_atividade, e.has_phone, e.has_email, e.cnae_principal, c.porte,
           sg.site_status, sg.site_confidence, sg.site_estacionado, sg.site_problemas_altos, sg.site_problemas,
           sg.instagram_status, sg.google_status,
           (sg.site_status = 'verificado' or sg.instagram_status = 'verificado' or sg.whatsapp_status = 'verificado'
              or sg.facebook_status = 'verificado' or sg.google_status = 'verificado') as canal_verificado
      from public.leads l
      join public.establishments e on e.cnpj = l.cnpj
      join public.companies c on c.cnpj_basico = l.cnpj_basico
      left join public.lead_digital_signals sg on sg.lead_id = l.id
     where (p_lead_ids is null or l.id = any (p_lead_ids))
       and (p_import_job_id is null or l.import_job_id = p_import_job_id)
  ),
  cnae_best as (
    select b.id, max(cr.relevance) as rel, count(distinct cr.service_id) as n_serv
      from base b
      join public.cnae_service_rules cr
        on cr.active and cr.cnae_prefix <> '*' and b.cnae_principal like cr.cnae_prefix || '%'
      join public.service_catalog s on s.id = cr.service_id and s.active
     group by b.id
  ),
  dig as (
    select b.id,
           case
             when b.site_status = 'nao_localizado' then 1.0
             when b.site_status = 'verificado' and b.site_estacionado then 0.9
             when b.site_status = 'verificado' and b.site_problemas_altos > 0 then 0.6
             when b.site_status = 'verificado' and b.site_problemas > 0 and b.instagram_status = 'nao_localizado' then 0.5
             when b.site_status = 'verificado' and b.instagram_status = 'nao_localizado' then 0.4
             when b.site_status = 'verificado' and b.site_problemas > 0 then 0.3
             else 0 end as frac,
           case
             when b.site_status = 'nao_localizado' then 'site não localizado após pesquisa conclusiva'
             when b.site_status = 'verificado' and b.site_estacionado then 'site verificado com página vazia ou estacionada'
             when b.site_status = 'verificado' and b.site_problemas_altos > 0 then b.site_problemas_altos || ' problema(s) técnico(s) grave(s) no site'
             when b.site_status = 'verificado' and b.instagram_status = 'nao_localizado' then 'Instagram não localizado após pesquisa'
             when b.site_status = 'verificado' and b.site_problemas > 0 then b.site_problemas || ' melhoria(s) técnica(s) no site'
             when b.site_status in ('inconclusivo', 'erro_temporario') then 'pesquisa inconclusiva: não pontua'
             when b.site_status = 'possivel' then 'site possível (confiança insuficiente): não pontua'
             when b.site_status = 'verificado' then 'site verificado sem problemas relevantes'
             else 'presença digital ainda não pesquisada: não pontua' end as motivo
      from base b
  ),
  calc as (
    select b.id,
      jsonb_strip_nulls(jsonb_build_object(
        'oportunidade_digital', (select round(r.points * d.frac) from r where r.key = 'oportunidade_digital'),
        'cnae_compativel', (select round(r.points * coalesce(cb.rel, 0) / 100.0) from r where r.key = 'cnae_compativel'),
        'potencial_segmento', (select round(r.points * least(1.0, coalesce(cb.n_serv, 0)::numeric
                                 / greatest(1, coalesce((r.params ->> 'servicos_para_integral')::int, 3)))) from r where r.key = 'potencial_segmento'),
        'recencia', (select case
                       when b.data_inicio_atividade is null then 0
                       when p_ref_date - b.data_inicio_atividade <= coalesce((r.params ->> 'dias_integral')::int, 30) then r.points
                       when p_ref_date - b.data_inicio_atividade <= coalesce((r.params ->> 'dias_metade')::int, 90) then round(r.points / 2.0)
                       else 0 end from r where r.key = 'recencia'),
        'canais_contato', (select round(r.points * ((case when b.has_phone then 0.3 else 0 end)
                                                    + (case when b.has_email then 0.2 else 0 end)
                                                    + (case when b.canal_verificado then 0.5 else 0 end))) from r where r.key = 'canais_contato'),
        'telefone', (select case when b.has_phone then r.points else 0 end from r where r.key = 'telefone'),
        'email',    (select case when b.has_email then r.points else 0 end from r where r.key = 'email'),
        'porte',    (select least(r.points, coalesce((r.params ->> coalesce(b.porte, '00'))::int, 0)) from r where r.key = 'porte')
      )) as breakdown,
      jsonb_build_object(
        'oportunidade_digital', d.motivo,
        'cnae_compativel', case when cb.rel is null then 'nenhuma regra de serviço para o CNAE ' || coalesce(b.cnae_principal, '?')
                                else 'maior relevância entre os serviços para o CNAE: ' || cb.rel || '%' end,
        'potencial_segmento', coalesce(cb.n_serv, 0) || ' serviço(s) da JS Designer aplicáveis ao segmento',
        'recencia', case when b.data_inicio_atividade is null then 'data de abertura desconhecida'
                         else (p_ref_date - b.data_inicio_atividade) || ' dias desde a abertura' end,
        'canais_contato', concat_ws(', ', case when b.has_phone then 'telefone' end, case when b.has_email then 'e-mail' end,
                                    case when b.canal_verificado then 'canal digital verificado' end),
        'versao', ver) as reasons,
      b.site_confidence as conf
    from base b
    left join cnae_best cb on cb.id = b.id
    join dig d on d.id = b.id
  )
  update public.leads l
     set score = least(100, (select coalesce(sum(v::numeric), 0) from jsonb_each_text(c.breakdown) as t(k, v)))::smallint,
         score_breakdown = c.breakdown, score_reasons = c.reasons, score_version = ver,
         diagnosis_confidence = c.conf
    from calc c
   where c.id = l.id
     and (l.score_breakdown is distinct from c.breakdown or l.score_version is distinct from ver
          or l.diagnosis_confidence is distinct from c.conf or l.score_reasons is distinct from c.reasons);
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.recalculate_lead_scores(uuid[], uuid, date) from public, anon, authenticated;

-- Campos novos da pontuação também são só do sistema
create or replace function public.leads_protect_system_columns()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or public.is_bulk_load() or public.has_role(array['admin']::public.app_role[]) then
    return new;
  end if;
  if new.score is distinct from old.score
     or new.score_breakdown is distinct from old.score_breakdown
     or new.score_reasons is distinct from old.score_reasons
     or new.score_version is distinct from old.score_version
     or new.diagnosis_confidence is distinct from old.diagnosis_confidence
     or new.digital_presence is distinct from old.digital_presence
     or new.cnpj is distinct from old.cnpj
     or new.cnpj_basico is distinct from old.cnpj_basico
     or new.source is distinct from old.source
     or new.import_job_id is distinct from old.import_job_id
     or new.created_by is distinct from old.created_by
     or new.created_at is distinct from old.created_at then
    raise exception 'Pontuação, presença digital e dados de origem do lead são calculados pelo sistema';
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------------
-- 4. Recomendações: CNAE + evidências digitais (motivo registrado)
-- ---------------------------------------------------------------------
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

  insert into public.lead_recommendations (lead_id, service_id, rule_id, relevance, reason)
  select distinct on (x.lead_id, x.service_id) x.lead_id, x.service_id, null, x.relevance, 'Verificado: ' || x.reason
    from (
      select sg.lead_id, dr.service_id, dr.relevance, dr.reason
        from public.lead_digital_signals sg
        join public.leads l on l.id = sg.lead_id
        join public.digital_service_rules dr on dr.active and (
             (dr.condition = 'site_nao_localizado' and sg.site_status = 'nao_localizado')
          or (dr.condition = 'site_estacionado' and sg.site_status = 'verificado' and sg.site_estacionado)
          or (dr.condition = 'site_problemas_tecnicos' and sg.site_status = 'verificado' and sg.site_problemas_altos > 0)
          or (dr.condition = 'site_sem_seo' and sg.site_status = 'verificado' and sg.site_sem_seo)
          or (dr.condition = 'instagram_nao_localizado' and sg.instagram_status = 'nao_localizado')
          or (dr.condition = 'google_nao_localizado' and sg.google_status = 'nao_localizado')
          or (dr.condition = 'whatsapp_nao_divulgado' and sg.site_status = 'verificado' and sg.whatsapp_status = 'nao_localizado')
          or (dr.condition = 'sem_presenca_digital' and sg.site_status = 'nao_localizado'
              and sg.instagram_status = 'nao_localizado' and sg.google_status = 'nao_localizado'))
        join public.service_catalog s on s.id = dr.service_id and s.active
       where (p_lead_ids is null or sg.lead_id = any (p_lead_ids))
         and (p_import_job_id is null or l.import_job_id = p_import_job_id)
    ) x
   order by x.lead_id, x.service_id, x.relevance desc
  on conflict (lead_id, service_id) do update
    set relevance = greatest(public.lead_recommendations.relevance, excluded.relevance),
        reason = excluded.reason, rule_id = null;

  perform public.refresh_lead_insights(
    case when p_lead_ids is not null then p_lead_ids
         when p_import_job_id is not null then array(select id from public.leads where import_job_id = p_import_job_id)
         else null end);
  return n;
end $$;
revoke all on function public.rebuild_lead_recommendations(uuid[], uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 5. Central de Oportunidades
-- ---------------------------------------------------------------------
create or replace view public.opportunity_center_v with (security_invoker = true) as
select l.id, l.cnpj, l.cnpj_basico, l.score, l.priority, l.stage, l.owner_id, p.full_name as owner_name,
       l.diagnosis_confidence, l.created_at, c.razao_social, e.nome_fantasia, c.porte, e.uf, e.municipio_code,
       m.name as municipio, e.cnae_principal, left(e.cnae_principal, 2) as cnae_divisao, k.description as cnae_descricao,
       e.data_inicio_atividade, ((select public.current_reference_date()) - e.data_inicio_atividade) as dias_abertura,
       e.has_phone, e.has_email,
       li.site_status, li.site_url, li.site_nota, coalesce(li.site_problemas, 0) as site_problemas,
       coalesce(li.site_problemas_altos, 0) as site_problemas_altos,
       li.instagram_status, li.facebook_status, li.google_status, li.whatsapp_status,
       (coalesce(li.site_status, 'pendente') in ('pendente', 'em_processamento')) as diagnostico_pendente,
       li.servico_codigo, li.servico_nome, li.servico_relevancia,
       exists (select 1 from public.opportunities o where o.lead_id = l.id and o.status = 'aberta') as no_funil,
       coalesce((select array_agg(t.name order by t.name) from public.lead_tags lt join public.tags t on t.id = lt.tag_id
                  where lt.lead_id = l.id), '{}') as tags,
       exists (select 1 from public.contact_suppressions s where s.cnpj_basico = l.cnpj_basico) as bloqueado
  from public.leads l
  join public.establishments e on e.cnpj = l.cnpj
  join public.companies c on c.cnpj_basico = l.cnpj_basico
  left join public.municipalities m on m.code = e.municipio_code
  left join public.cnae_catalog k on k.code = e.cnae_principal
  left join public.profiles p on p.id = l.owner_id
  left join public.lead_insights li on li.lead_id = l.id;
revoke all on public.opportunity_center_v from anon;
grant select on public.opportunity_center_v to authenticated;

-- Agrupamentos da Central com os mesmos filtros (contagens no servidor)
create or replace function public.opportunity_center_groups(p_group text, p_filters jsonb default '{}'::jsonb)
returns table (chave text, rotulo text, total bigint, alta bigint)
language plpgsql stable security invoker set search_path = public as $$
declare
  col text;
  lbl text;
begin
  col := case p_group when 'cnae' then 'cnae_divisao' when 'uf' then 'uf' when 'municipio' then 'municipio'
                      when 'porte' then 'porte' when 'servico' then 'servico_nome' when 'prioridade' then 'priority'
                      when 'site' then 'site_status' when 'instagram' then 'instagram_status' when 'google' then 'google_status'
                      else null end;
  if col is null then raise exception 'Agrupamento inválido: %', p_group; end if;
  lbl := case p_group when 'cnae' then 'coalesce(min(cnae_descricao), cnae_divisao)'
                      when 'municipio' then 'municipio || '' / '' || min(uf)' else col end;
  return query execute format($q$
    select coalesce(%1$s::text, 'não informado'), coalesce((%2$s)::text, 'não informado'), count(*), count(*) filter (where priority = 'alta')
      from public.opportunity_center_v v
     where not bloqueado
       and ($1 ->> 'uf' is null or uf = $1 ->> 'uf')
       and ($1 ->> 'municipio' is null or municipio_code = $1 ->> 'municipio')
       and ($1 ->> 'cnae' is null or cnae_principal like ($1 ->> 'cnae') || '%%')
       and ($1 ->> 'porte' is null or porte = $1 ->> 'porte')
       and ($1 ->> 'prioridade' is null or priority = $1 ->> 'prioridade')
       and ($1 ->> 'servico' is null or servico_codigo = $1 ->> 'servico')
       and ($1 ->> 'dias' is null or dias_abertura <= ($1 ->> 'dias')::int)
       and (not coalesce(($1 ->> 'sem_site')::boolean, false) or site_status = 'nao_localizado')
       and (not coalesce(($1 ->> 'sem_instagram')::boolean, false) or instagram_status = 'nao_localizado')
       and (not coalesce(($1 ->> 'sem_facebook')::boolean, false) or facebook_status = 'nao_localizado')
       and (not coalesce(($1 ->> 'sem_google')::boolean, false) or google_status = 'nao_localizado')
       and (not coalesce(($1 ->> 'site_problemas')::boolean, false) or (site_status = 'verificado' and site_problemas > 0))
       and (not coalesce(($1 ->> 'pendente')::boolean, false) or diagnostico_pendente)
     group by %1$s order by 3 desc limit 60$q$, col, lbl)
  using p_filters;
end $$;
revoke all on function public.opportunity_center_groups(text, jsonb) from public, anon;
grant execute on function public.opportunity_center_groups(text, jsonb) to authenticated;

alter table public.lead_searches add column if not exists scope text not null default 'leads'
  check (scope in ('leads', 'oportunidades'));

-- ---------------------------------------------------------------------
-- 6. Diagnóstico + assistente comercial
-- ---------------------------------------------------------------------
create or replace function public.sales_assistant(p_lead_id uuid)
returns jsonb
language plpgsql stable security invoker set search_path = public as $$
declare
  d jsonb := public.lead_diagnosis(p_lead_id);
  sg record;
  top record;
  opp record;
  nxt record;
  ops jsonb := '[]'::jsonb;
  cautions jsonb := coalesce(d -> 'ressalvas', '[]'::jsonb);
  acao text;
  canal text;
  l record;
  est numeric;
begin
  if d is null then return null; end if;
  select * into sg from public.lead_digital_signals where lead_id = p_lead_id;
  select l2.*, e.has_phone, e.has_email into l from public.leads l2 join public.establishments e on e.cnpj = l2.cnpj where l2.id = p_lead_id;

  -- oportunidades vindas dos canais digitais (só com evidência conclusiva)
  if sg.site_status = 'nao_localizado' then
    ops := ops || jsonb_build_object('tipo', 'site', 'servico', 'site_institucional', 'oportunidade', 'Site não localizado',
      'evidencia', 'Pesquisa web e verificação do domínio sem site correspondente', 'recomendacao',
      'Desenvolvimento de site institucional com serviços, localização e canais de contato.');
  elsif sg.site_status = 'verificado' and (sg.site_estacionado or sg.site_problemas_altos > 0) then
    ops := ops || jsonb_build_object('tipo', 'site', 'servico', 'site_institucional', 'oportunidade', 'Site com problemas técnicos',
      'evidencia', coalesce((select string_agg(p ->> 'evidencia', '; ') from public.digital_channels c,
                              jsonb_array_elements(c.result -> 'problemas') p
                             where c.cnpj_basico = l.cnpj_basico and c.platform = 'site' and p ->> 'gravidade' = 'alta'), ''),
      'recomendacao', 'Reformulação do site corrigindo os problemas verificados.');
  end if;
  if sg.instagram_status = 'nao_localizado' then
    ops := ops || jsonb_build_object('tipo', 'instagram', 'servico', 'gestao_instagram', 'oportunidade', 'Instagram comercial não localizado',
      'evidencia', 'Pesquisa sem perfil correspondente' || case when sg.site_status = 'verificado' then ' e o site não indica Instagram' else '' end,
      'recomendacao', 'Criação e gestão do Instagram comercial.');
  end if;
  if sg.google_status = 'nao_localizado' then
    ops := ops || jsonb_build_object('tipo', 'google', 'servico', 'presenca_digital', 'oportunidade', 'Sem Perfil da Empresa no Google',
      'evidencia', 'Google Places sem perfil correspondente (nome, cidade e telefone)',
      'recomendacao', 'Estruturação da presença digital começando pelo Perfil no Google.');
  end if;
  if coalesce(sg.site_status, 'pendente') in ('pendente', 'em_processamento') then
    cautions := cautions || to_jsonb('Diagnóstico digital pendente: confirme site e redes no primeiro contato.'::text);
  end if;
  -- as oportunidades de site do diagnóstico básico (domínio do e-mail) são substituídas pelas dos canais
  ops := ops || coalesce((select jsonb_agg(o) from jsonb_array_elements(d -> 'oportunidades') o
                           where o ->> 'tipo' <> 'site' or not exists (select 1 from jsonb_array_elements(ops) x where x ->> 'tipo' = 'site')), '[]'::jsonb);

  select s.code, s.name, s.price_from, s.price_to, s.recurrence, s.package, lr.relevance, lr.reason into top
    from public.lead_recommendations lr join public.service_catalog s on s.id = lr.service_id
   where lr.lead_id = p_lead_id order by lr.relevance desc, s.sort_order limit 1;

  select o.*, ps.label as etapa into opp from public.opportunities o join public.pipeline_stages ps on ps.code = o.stage_code
   where o.lead_id = p_lead_id and o.status = 'aberta' order by o.updated_at desc limit 1;
  select * into nxt from public.crm_tasks where lead_id = p_lead_id and done_at is null order by due_at nulls last limit 1;

  canal := case when sg.whatsapp_status = 'verificado' then 'whatsapp'
                when l.has_phone then 'telefone'
                when l.has_email then 'email' else 'pesquisa' end;
  acao := case
    when exists (select 1 from public.contact_suppressions s where s.cnpj_basico = l.cnpj_basico) then 'Empresa bloqueada para contato: nenhuma ação comercial.'
    when nxt.id is not null then 'Executar a tarefa pendente: ' || nxt.title || coalesce(' (' || to_char(nxt.due_at at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') || ')', '')
    when opp.id is null then 'Adicionar ao funil e fazer o primeiro contato por ' || canal || '.'
    when opp.stage_code in ('novo_lead', 'em_qualificacao') then 'Qualificar: confirmar responsável, interesse e presença digital.'
    when opp.stage_code in ('qualificado') then 'Fazer o primeiro contato por ' || canal || ' com a abordagem sugerida.'
    when opp.stage_code in ('primeiro_contato', 'aguardando_retorno') then 'Fazer follow-up em 2 dias úteis.'
    when opp.stage_code in ('interessado') then 'Agendar reunião para apresentar portfólio e entender a necessidade.'
    when opp.stage_code in ('reuniao_agendada') then 'Preparar a proposta com o serviço recomendado.'
    when opp.stage_code in ('proposta_enviada') then 'Confirmar recebimento da proposta e tirar dúvidas.'
    when opp.stage_code in ('em_negociacao') then 'Negociar condições e registrar o contrato.'
    else 'Acompanhar.' end;
  est := coalesce(top.price_from, null);

  return d || jsonb_build_object(
    'oportunidades', ops,
    'ressalvas', cautions,
    'resumo', coalesce(d ->> 'empresa', 'Empresa') || ' (' || coalesce(d ->> 'atividade', 'atividade não informada') || ', '
              || coalesce(d ->> 'local', '') || '): ' || jsonb_array_length(ops) || ' oportunidade(s) com evidência'
              || case when l.diagnosis_confidence is not null then ', confiança do diagnóstico ' || l.diagnosis_confidence || '%' else '' end || '.',
    'servico_recomendado', case when top.code is null then null else jsonb_build_object(
        'codigo', top.code, 'nome', top.name, 'relevancia', top.relevance, 'motivo', top.reason,
        'preco_de', top.price_from, 'preco_ate', top.price_to, 'recorrencia', top.recurrence, 'pacote', top.package) end,
    'canal_sugerido', canal,
    'abordagem', case canal
        when 'whatsapp' then 'Mensagem curta pelo WhatsApp divulgado, citando a oportunidade verificada e pedindo permissão para enviar exemplos.'
        when 'telefone' then 'Ligação rápida (até 2 minutos): apresentar a JS Designer, citar a oportunidade e propor o envio de exemplos.'
        when 'email' then 'E-mail objetivo com a oportunidade verificada, exemplos de trabalhos e opção de não receber novos contatos.'
        else 'Sem contato no cadastro: pesquisar o canal antes de abordar.' end,
    'sugestao_proposta', case when top.code is null then null else jsonb_build_object(
        'titulo', top.name || ' — ' || coalesce(d ->> 'empresa', ''),
        'servicos', (select jsonb_agg(x.name) from (select s.name from public.lead_recommendations lr
                       join public.service_catalog s on s.id = lr.service_id where lr.lead_id = p_lead_id
                      order by lr.relevance desc limit 3) x),
        'valor_estimado', est,
        'observacao', case when est is null then 'Cadastre o preço do serviço em Serviços para estimar o valor.' end) end,
    'proxima_acao', acao,
    'follow_up_sugerido', (current_date + case extract(isodow from current_date) when 5 then 4 when 6 then 3 else 2 end),
    'oportunidade_aberta', case when opp.id is null then null else jsonb_build_object('id', opp.id, 'titulo', opp.title, 'etapa', opp.etapa) end);
end $$;
revoke all on function public.sales_assistant(uuid) from public, anon;
grant execute on function public.sales_assistant(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 7. Dashboard executivo (indicadores cadastrais separados dos comerciais)
-- ---------------------------------------------------------------------
create or replace function public.executive_metrics(p_uf text default null, p_from date default null, p_to date default null)
returns jsonb
language sql stable security invoker set search_path = public as $$
  with per as (select coalesce(p_from, date_trunc('month', current_date)::date) as d0, coalesce(p_to, current_date) as d1),
  ld as materialized (select l.id, l.cnpj_basico, l.priority, l.import_job_id, e.uf, left(e.cnae_principal, 2) as div
          from public.leads l join public.establishments e on e.cnpj = l.cnpj
          where p_uf is null or e.uf = p_uf),
  op as (select o.* from public.opportunities o join ld on ld.id = o.lead_id),
  ct as (select c.* from public.contracts c join ld on ld.id = c.lead_id where c.status <> 'cancelado'),
  ct_per as (select ct.* from ct, per where coalesce(ct.signed_at, ct.created_at::date) between per.d0 and per.d1),
  ins as (select li.* from public.lead_insights li join ld on ld.id = li.lead_id),
  won as (select * from op where status in ('ganha', 'pos_venda')),
  closed as (select * from op where status in ('ganha', 'pos_venda', 'perdida')),
  contacted as (select distinct ev.lead_id from public.lead_events ev join ld on ld.id = ev.lead_id where ev.event_type = 'contato')
  select jsonb_build_object(
    'periodo', (select jsonb_build_object('de', d0, 'ate', d1) from per),
    'cadastrais', jsonb_build_object(
      'total_historico', (select count(*) from public.companies) + (select count(*) from public.lead_archive a
                            where not exists (select 1 from public.companies c where c.cnpj_basico = a.cnpj_basico)),
      'leads_na_base', (select count(*) from ld),
      'novas_por_competencia', coalesce((select jsonb_agg(x order by x.competencia) from (
          select coalesce(j.competence, 'manual') as competencia, count(*) as total
            from ld left join public.import_jobs j on j.id = ld.import_job_id group by 1) x), '[]'::jsonb),
      'pesquisadas', (select count(*) from ins where coalesce(site_status, 'pendente') not in ('pendente', 'em_processamento')),
      'pendentes_pesquisa', (select count(*) from ld) - (select count(*) from ins
                               where coalesce(site_status, 'pendente') not in ('pendente', 'em_processamento')),
      'sites_localizados', (select count(*) from ins where site_status = 'verificado'),
      'instagram_localizado', (select count(*) from ins where instagram_status = 'verificado'),
      'facebook_localizado', (select count(*) from ins where facebook_status = 'verificado'),
      'google_localizado', (select count(*) from ins where google_status = 'verificado'),
      'oportunidades_identificadas', (select count(*) from ins where oportunidade_digital)),
    'comerciais', jsonb_build_object(
      'leads_qualificados', (select count(distinct o.lead_id) from op o join public.pipeline_stages ps on ps.code = o.stage_code
                              where ps.sort_order >= 30 and o.status <> 'perdida'),
      'leads_contatados', (select count(*) from contacted),
      'respostas_recebidas', (select count(distinct ev.lead_id) from public.lead_events ev join ld on ld.id = ev.lead_id
                               where ev.event_type = 'resposta_recebida'),
      'reunioes_agendadas', (select count(*) from public.crm_tasks t join ld on ld.id = t.lead_id where t.kind = 'reuniao' and t.done_at is null),
      'reunioes_realizadas', (select count(*) from public.lead_events ev join ld on ld.id = ev.lead_id where ev.event_type = 'reuniao'),
      'propostas_enviadas', (select count(*) from public.lead_proposals p join ld on ld.id = p.lead_id where p.status <> 'rascunho'),
      'valor_em_negociacao', (select coalesce(sum(value), 0) from op where status = 'aberta'
                               and stage_code in ('proposta_enviada', 'em_negociacao', 'reuniao_agendada')),
      'oportunidades_abertas', (select count(*) from op where status = 'aberta'),
      'receita_contratada_periodo', (select coalesce(sum(total_value), 0) from ct_per),
      'contratos_periodo', (select count(*) from ct_per),
      'receita_contratada_total', (select coalesce(sum(total_value), 0) from ct),
      'receita_recorrente_mensal', (select coalesce(sum(case recurrence when 'mensal' then recurring_value
                                      when 'trimestral' then recurring_value / 3 when 'semestral' then recurring_value / 6
                                      when 'anual' then recurring_value / 12 else 0 end), 0) from ct where status = 'ativo'),
      'ticket_medio', (select case when count(*) > 0 then round(coalesce(sum(total_value), 0) / count(*), 2) else 0 end from ct),
      'tempo_medio_fechamento_dias', (select round(avg(extract(epoch from (won_at - created_at)) / 86400)::numeric, 1) from won),
      'taxa_conversao_oportunidades', (select case when count(*) > 0 then round(100.0 * count(*) filter (where status <> 'perdida') / count(*), 1) end from closed),
      'taxa_conversao_contatados', (select case when (select count(*) from contacted) > 0
                                     then round(100.0 * (select count(distinct lead_id) from won) / (select count(*) from contacted), 1) end),
      'follow_ups_atrasados', (select count(*) from public.crm_tasks t join ld on ld.id = t.lead_id where t.done_at is null and t.due_at < now())),
    'denominadores', jsonb_build_object(
      'taxa_conversao_oportunidades', 'oportunidades ganhas ÷ oportunidades encerradas (ganhas + perdidas); abertas não entram',
      'taxa_conversao_contatados', 'empresas com oportunidade ganha ÷ empresas com pelo menos um contato registrado',
      'ticket_medio', 'receita contratada (contratos não cancelados) ÷ número desses contratos',
      'tempo_medio_fechamento_dias', 'média de dias entre a criação e o ganho das oportunidades ganhas',
      'receita_recorrente_mensal', 'soma do valor recorrente dos contratos ativos convertido para mês'),
    'por_responsavel', coalesce((select jsonb_agg(x order by x.receita desc, x.oportunidades desc) from (
        select coalesce(p.full_name, p.email, 'Sem responsável') as label, count(*) as oportunidades,
               count(*) filter (where o.status in ('ganha', 'pos_venda')) as ganhas,
               count(*) filter (where o.status = 'perdida') as perdidas,
               coalesce((select sum(c.total_value) from ct c where c.opportunity_id = any (array_agg(o.id))), 0) as receita
          from op o left join public.profiles p on p.id = o.owner_id group by 1) x), '[]'::jsonb),
    'por_servico', coalesce((select jsonb_agg(x order by x.receita desc, x.oportunidades desc) from (
        select s.name as label, count(distinct o.id) as oportunidades,
               count(distinct o.id) filter (where o.status in ('ganha', 'pos_venda')) as ganhas,
               coalesce((select sum(c.total_value) from ct c where c.opportunity_id = any (array_agg(o.id))), 0) as receita
          from op o
          left join public.lead_insights li on li.lead_id = o.lead_id
          cross join lateral unnest(case when cardinality(o.service_ids) > 0 then o.service_ids
                    else array(select s2.id from public.service_catalog s2 where s2.code = li.servico_codigo) end) sid
          join public.service_catalog s on s.id = sid
         group by s.name) x), '[]'::jsonb),
    'por_segmento', coalesce((select jsonb_agg(jsonb_build_object(
          'label', 'CNAE ' || y.div || coalesce(' — ' || (select description from public.cnae_catalog where code like y.div || '%' order by code limit 1), ''),
          'leads', y.leads, 'alta', y.alta, 'oportunidades', y.oportunidades, 'ganhas', y.ganhas) order by y.leads desc) from (
        select ld.div, count(*) as leads, count(*) filter (where ld.priority = 'alta') as alta,
               count(distinct o.id) as oportunidades, count(distinct o.id) filter (where o.status in ('ganha', 'pos_venda')) as ganhas
          from ld left join op o on o.lead_id = ld.id
         group by ld.div order by 2 desc limit 15) y), '[]'::jsonb),
    'por_regiao', coalesce((select jsonb_agg(x order by x.leads desc) from (
        select ld.uf as label, count(*) as leads, count(*) filter (where ld.priority = 'alta') as alta,
               count(distinct o.id) as oportunidades, count(distinct o.id) filter (where o.status in ('ganha', 'pos_venda')) as ganhas
          from ld left join op o on o.lead_id = ld.id group by ld.uf) x), '[]'::jsonb))
$$;
revoke all on function public.executive_metrics(text, date, date) from public, anon;
grant execute on function public.executive_metrics(text, date, date) to authenticated;

-- Confirmação manual de canal reflete na hora na pontuação, recomendações e Central
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
  perform set_config('app.bulk_load', 'on', true);
  if p_platform = 'site' and p_status = 'verificado' then
    update public.leads set website = trim(p_url) where id = p_lead_id;
  end if;
  perform public.recalculate_lead_scores(array[p_lead_id], null, public.current_reference_date());
  perform public.rebuild_lead_recommendations(array[p_lead_id]);
  perform set_config('app.bulk_load', '', true);
end $$;
revoke all on function public.confirm_digital_channel(uuid, text, text, text, text) from public, anon;
grant execute on function public.confirm_digital_channel(uuid, text, text, text, text) to authenticated;

create or replace function public.commercial_metrics(p_uf text default null)
returns jsonb
language sql stable security invoker set search_path = public as $$
  with cur as (select id from public.import_jobs where is_current limit 1),
  ld as (
    select l.id, l.owner_id, l.stage, l.priority, l.import_job_id, l.next_follow_up_at
      from public.leads l join public.establishments e on e.cnpj = l.cnpj
     where p_uf is null or e.uf = p_uf
  ),
  contacted as (
    select distinct lead_id from public.lead_events where event_type = 'contato'
    union
    select id from ld where stage in ('primeiro_contato', 'aguardando_resposta', 'interessado',
                                      'proposta_enviada', 'em_negociacao', 'convertido')
  ),
  responded as (
    select distinct lead_id from public.lead_events where event_type = 'resposta_recebida'
    union
    select id from ld where stage in ('interessado', 'proposta_enviada', 'em_negociacao', 'convertido')
  ),
  props as (
    select p.* from public.lead_proposals p join ld on ld.id = p.lead_id where p.status <> 'rascunho'
  ),
  base as (
    select ld.id, ld.owner_id, ld.stage,
           c.lead_id is not null as contatado, r.lead_id is not null as respondeu,
           exists (select 1 from props p where p.lead_id = ld.id) as com_proposta,
           ld.stage = 'convertido' as convertido, li.servico_nome
      from ld
      left join contacted c on c.lead_id = ld.id
      left join responded r on r.lead_id = ld.id
      left join public.lead_insights li on li.lead_id = ld.id
  ),
  n as (select count(*) filter (where contatado) as contatados, count(*) filter (where convertido) as convertidos from base)
  select jsonb_build_object(
    'leads_total', (select count(*) from ld),
    'leads_novos_competencia', (select count(*) from ld where import_job_id = (select id from cur)),
    'leads_alta', (select count(*) from ld where priority = 'alta'),
    'leads_qualificados', (select count(*) from ld where stage not in ('novo', 'perdido')),
    'leads_contatados', (select contatados from n),
    'respostas_recebidas', (select count(*) from base where respondeu),
    'propostas_enviadas', (select count(*) from props),
    'propostas_valor', (select coalesce(sum(amount), 0) from props),
    'propostas_aceitas', (select count(*) from props where status = 'aceita'),
    'clientes_convertidos', (select convertidos from n),
    'taxa_conversao', (select case when contatados > 0 then round(100.0 * convertidos / contatados, 1) else 0 end from n),
    'follow_ups_atrasados', (select count(*) from ld where next_follow_up_at < now()),
    'por_servico', coalesce((select jsonb_agg(x order by x.leads desc) from (
        select servico_nome as label, count(*) as leads, count(*) filter (where contatado) as contatados,
               count(*) filter (where com_proposta) as propostas, count(*) filter (where convertido) as convertidos
          from base where servico_nome is not null group by servico_nome) x), '[]'::jsonb),
    'por_responsavel', coalesce((select jsonb_agg(x order by x.leads desc) from (
        select coalesce(p.full_name, p.email, 'Sem responsável') as label, count(*) as leads,
               count(*) filter (where b.contatado) as contatados, count(*) filter (where b.com_proposta) as propostas,
               count(*) filter (where b.convertido) as convertidos
          from base b left join public.profiles p on p.id = b.owner_id
         where b.owner_id is not null or b.contatado
         group by 1) x), '[]'::jsonb),
    'por_etapa', coalesce((select jsonb_agg(x) from (select stage as label, count(*) as total from ld group by stage) x), '[]'::jsonb))
$$;
revoke all on function public.commercial_metrics(text) from public, anon;
grant execute on function public.commercial_metrics(text) to authenticated;

-- ---------------------------------------------------------------------
-- 8. Aplica a nova pontuação e as recomendações
-- ---------------------------------------------------------------------
select set_config('app.bulk_load', 'on', true);
select public.recalculate_lead_scores(null, null, public.current_reference_date());
select public.rebuild_lead_recommendations();
select public.take_inventory_snapshot('migration 015 (pontuação 2.0)');
