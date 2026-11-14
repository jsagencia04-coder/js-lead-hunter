-- =====================================================================
-- JS Lead Hunter — Etapa 1 — Estrutura do banco
-- Dados cadastrais (Receita Federal) separados dos dados comerciais (CRM).
-- Todos os campos CNPJ são TEXT e aceitam o formato alfanumérico.
-- =====================================================================

create extension if not exists pg_trgm;

-- ---------------------------------------------------------------------
-- Tipos
-- ---------------------------------------------------------------------
create type public.app_role as enum ('admin', 'gestor', 'comercial', 'leitura');

create type public.lead_stage as enum (
  'novo', 'validado', 'pronto_contato', 'primeiro_contato',
  'aguardando_resposta', 'interessado', 'proposta_enviada',
  'em_negociacao', 'convertido', 'perdido'
);

create type public.import_status as enum (
  'pendente', 'baixando', 'processando', 'validando',
  'concluido', 'falhou', 'cancelado'
);

-- ---------------------------------------------------------------------
-- Função utilitária de updated_at
-- ---------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- =====================================================================
-- USUÁRIOS
-- =====================================================================
create table public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  full_name   text,
  email       text not null,
  role        public.app_role not null default 'leitura',
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index profiles_role_idx on public.profiles (role) where active;

-- =====================================================================
-- TABELAS DE REFERÊNCIA (Receita Federal)
-- =====================================================================
create table public.cnae_catalog (
  code        text primary key check (code ~ '^[0-9]{7}$'),
  description text not null,
  updated_at  timestamptz not null default now()
);
create index cnae_catalog_desc_trgm on public.cnae_catalog using gin (description gin_trgm_ops);

-- Código de município da Receita Federal (tabela TOM, 4 dígitos)
create table public.municipalities (
  code        text primary key check (code ~ '^[0-9]{1,4}$'),
  name        text not null,
  uf          char(2),
  ibge_code   text check (ibge_code is null or ibge_code ~ '^[0-9]{7}$'),
  updated_at  timestamptz not null default now()
);
create index municipalities_uf_idx on public.municipalities (uf);
create index municipalities_name_trgm on public.municipalities using gin (name gin_trgm_ops);

create table public.legal_natures (
  code        text primary key check (code ~ '^[0-9]{4}$'),
  description text not null,
  updated_at  timestamptz not null default now()
);

-- =====================================================================
-- DADOS CADASTRAIS
-- =====================================================================

-- Pessoa jurídica: identificada pelo CNPJ básico (8 caracteres)
create table public.companies (
  cnpj_basico         text primary key check (cnpj_basico ~ '^[0-9A-Z]{8}$'),
  razao_social        text,
  natureza_juridica   text references public.legal_natures (code),
  capital_social      numeric(18, 2) check (capital_social is null or capital_social >= 0),
  -- 00 não informado, 01 micro empresa, 03 empresa de pequeno porte, 05 demais
  porte               text check (porte is null or porte in ('00', '01', '03', '05')),
  ente_federativo     text,
  source_competence   text check (source_competence is null or source_competence ~ '^[0-9]{4}-[0-9]{2}$'),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index companies_porte_idx on public.companies (porte);
create index companies_capital_idx on public.companies (capital_social);
create index companies_razao_trgm on public.companies using gin (razao_social gin_trgm_ops);

create table public.company_simple_status (
  cnpj_basico            text primary key references public.companies (cnpj_basico) on delete cascade,
  opcao_simples          boolean,
  data_opcao_simples     date,
  data_exclusao_simples  date,
  opcao_mei              boolean,
  data_opcao_mei         date,
  data_exclusao_mei      date,
  source_competence      text check (source_competence is null or source_competence ~ '^[0-9]{4}-[0-9]{2}$'),
  updated_at             timestamptz not null default now()
);
create index company_simple_mei_idx on public.company_simple_status (opcao_mei);
create index company_simple_simples_idx on public.company_simple_status (opcao_simples);

-- Estabelecimento: identificado pelo CNPJ completo (14 caracteres;
-- 12 alfanuméricos + 2 dígitos verificadores numéricos)
create table public.establishments (
  cnpj                    text primary key check (cnpj ~ '^[0-9A-Z]{12}[0-9]{2}$'),
  cnpj_basico             text not null references public.companies (cnpj_basico) on delete cascade,
  cnpj_ordem              text not null check (cnpj_ordem ~ '^[0-9A-Z]{4}$'),
  cnpj_dv                 text not null check (cnpj_dv ~ '^[0-9]{2}$'),
  identificador_matriz    smallint not null check (identificador_matriz in (1, 2)), -- 1 matriz, 2 filial
  nome_fantasia           text,
  situacao_cadastral      text not null check (situacao_cadastral in ('01', '02', '03', '04', '08')),
  data_situacao_cadastral date,
  motivo_situacao         text,
  data_inicio_atividade   date,
  cnae_principal          text references public.cnae_catalog (code),
  cnaes_secundarios       text[] not null default '{}',
  tipo_logradouro         text,
  logradouro              text,
  numero                  text,
  complemento             text,
  bairro                  text,
  cep                     text check (cep is null or cep ~ '^[0-9]{8}$'),
  uf                      char(2),
  municipio_code          text references public.municipalities (code),
  ddd1                    text,
  telefone1               text,
  ddd2                    text,
  telefone2               text,
  email                   text,
  situacao_especial       text,
  data_situacao_especial  date,
  has_phone boolean generated always as (
    coalesce(nullif(trim(telefone1), ''), nullif(trim(telefone2), '')) is not null
  ) stored,
  has_email boolean generated always as (nullif(trim(email), '') is not null) stored,
  source_competence       text check (source_competence is null or source_competence ~ '^[0-9]{4}-[0-9]{2}$'),
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  constraint establishments_cnpj_parts_chk check (cnpj = cnpj_basico || cnpj_ordem || cnpj_dv)
);
create index establishments_basico_idx   on public.establishments (cnpj_basico);
create index establishments_inicio_idx   on public.establishments (data_inicio_atividade desc);
create index establishments_uf_mun_idx   on public.establishments (uf, municipio_code);
create index establishments_cnae_idx     on public.establishments (cnae_principal);
create index establishments_cnae2_gin    on public.establishments using gin (cnaes_secundarios);
create index establishments_situacao_idx on public.establishments (situacao_cadastral);
-- Índice parcial para o caso principal: matrizes ativas por data de abertura
create index establishments_matriz_ativa_idx
  on public.establishments (data_inicio_atividade desc, uf)
  where identificador_matriz = 1 and situacao_cadastral = '02';

-- =====================================================================
-- CATÁLOGO DE SERVIÇOS E REGRAS (editáveis pelo administrador)
-- =====================================================================
create table public.service_catalog (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique check (code ~ '^[a-z0-9_]+$'),
  name        text not null,
  description text,
  active      boolean not null default true,
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- Regra por prefixo de CNAE: '*' vale para todos, '47' para a divisão 47,
-- '4781400' para uma subclasse específica. Prefixo mais longo vence.
create table public.cnae_service_rules (
  id          uuid primary key default gen_random_uuid(),
  cnae_prefix text not null check (cnae_prefix = '*' or cnae_prefix ~ '^[0-9]{2,7}$'),
  service_id  uuid not null references public.service_catalog (id) on delete cascade,
  relevance   smallint not null default 50 check (relevance between 0 and 100),
  reason      text,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (cnae_prefix, service_id)
);
create index cnae_service_rules_prefix_idx on public.cnae_service_rules (cnae_prefix) where active;

-- Regras de pontuação (0 a 100). Tabela adicional à lista original,
-- necessária para que a pontuação seja editável pelo administrador.
create table public.scoring_rules (
  key         text primary key check (key ~ '^[a-z0-9_]+$'),
  label       text not null,
  description text,
  points      smallint not null check (points between 0 and 100),
  params      jsonb not null default '{}'::jsonb,
  active      boolean not null default true,
  updated_at  timestamptz not null default now()
);

-- =====================================================================
-- CRM (dados comerciais)
-- =====================================================================
create table public.leads (
  id                  uuid primary key default gen_random_uuid(),
  cnpj_basico         text not null unique references public.companies (cnpj_basico),
  cnpj                text not null unique references public.establishments (cnpj),
  stage               public.lead_stage not null default 'novo',
  score               smallint not null default 0 check (score between 0 and 100),
  priority            text generated always as (
                        case when score >= 70 then 'alta'
                             when score >= 40 then 'media'
                             else 'baixa' end
                      ) stored,
  score_breakdown     jsonb not null default '{}'::jsonb,
  owner_id            uuid references public.profiles (id) on delete set null,
  next_follow_up_at   timestamptz,
  website             text,
  digital_presence    jsonb not null default '{}'::jsonb,  -- preenchido só por enriquecimento real
  lost_reason         text,
  converted_at        timestamptz,
  source              text not null default 'importacao' check (source in ('importacao', 'manual')),
  import_job_id       uuid,
  created_by          uuid references public.profiles (id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint leads_cnpj_matches_basico check (left(cnpj, 8) = cnpj_basico)
);
create index leads_stage_idx      on public.leads (stage);
create index leads_priority_idx   on public.leads (priority);
create index leads_owner_idx      on public.leads (owner_id);
create index leads_score_idx      on public.leads (score desc);
create index leads_followup_idx   on public.leads (next_follow_up_at) where next_follow_up_at is not null;

create table public.lead_events (
  id            bigint generated always as identity primary key,
  lead_id       uuid not null references public.leads (id) on delete cascade,
  event_type    text not null check (event_type in (
                  'criado', 'mudanca_etapa', 'anotacao', 'contato',
                  'follow_up_agendado', 'follow_up_concluido',
                  'responsavel_alterado', 'pontuacao_alterada', 'bloqueado')),
  from_stage    public.lead_stage,
  to_stage      public.lead_stage,
  channel       text check (channel is null or channel in ('telefone', 'whatsapp', 'email', 'presencial', 'outro')),
  content       text,
  scheduled_for timestamptz,
  metadata      jsonb not null default '{}'::jsonb,
  actor_id      uuid references public.profiles (id) on delete set null,
  created_at    timestamptz not null default now()
);
create index lead_events_lead_idx on public.lead_events (lead_id, created_at desc);

create table public.lead_recommendations (
  id          uuid primary key default gen_random_uuid(),
  lead_id     uuid not null references public.leads (id) on delete cascade,
  service_id  uuid not null references public.service_catalog (id) on delete cascade,
  rule_id     uuid references public.cnae_service_rules (id) on delete set null,
  relevance   smallint not null check (relevance between 0 and 100),
  reason      text,
  created_at  timestamptz not null default now(),
  unique (lead_id, service_id)
);

create table public.lead_searches (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references public.profiles (id) on delete cascade,
  name        text not null,
  filters     jsonb not null default '{}'::jsonb,
  is_shared   boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (owner_id, name)
);

-- Oposição ao contato. Sem FK de propósito: um CNPJ pode ser bloqueado
-- antes mesmo de existir na base operacional.
create table public.contact_suppressions (
  id           uuid primary key default gen_random_uuid(),
  cnpj_basico  text not null unique check (cnpj_basico ~ '^[0-9A-Z]{8}$'),
  reason       text not null,
  origin       text not null default 'interno' check (origin in ('pedido_titular', 'interno', 'juridico')),
  created_by   uuid references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now()
);

-- =====================================================================
-- MENSAGENS (preparação para WhatsApp Business Cloud API)
-- =====================================================================
create table public.message_templates (
  id                     uuid primary key default gen_random_uuid(),
  name                   text not null unique,
  channel                text not null check (channel in ('whatsapp', 'email')),
  category               text check (category in ('marketing', 'utility', 'authentication')),
  language               text not null default 'pt_BR',
  body                   text not null,
  variables              text[] not null default '{}',
  provider_template_name text,
  provider_status        text not null default 'nao_enviado'
                           check (provider_status in ('nao_enviado', 'pendente', 'aprovado', 'rejeitado')),
  active                 boolean not null default false,
  created_by             uuid references public.profiles (id) on delete set null,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);

create table public.message_logs (
  id                   uuid primary key default gen_random_uuid(),
  lead_id              uuid references public.leads (id) on delete set null,
  template_id          uuid references public.message_templates (id) on delete set null,
  channel              text not null check (channel in ('whatsapp', 'email')),
  direction            text not null check (direction in ('saida', 'entrada')),
  status               text not null check (status in ('enfileirada', 'enviada', 'entregue', 'lida', 'falhou', 'recebida')),
  provider_message_id  text unique,
  to_address           text,
  payload              jsonb not null default '{}'::jsonb,
  error                text,
  sent_by              uuid references public.profiles (id) on delete set null,
  created_at           timestamptz not null default now()
);
create index message_logs_lead_idx on public.message_logs (lead_id, created_at desc);

-- =====================================================================
-- IMPORTAÇÃO
-- =====================================================================
create table public.import_jobs (
  id               uuid primary key default gen_random_uuid(),
  job_type         text not null default 'importacao' check (job_type in ('verificacao', 'importacao')),
  competence       text check (competence is null or competence ~ '^[0-9]{4}-[0-9]{2}$'),
  reference_date   date,
  status           public.import_status not null default 'pendente',
  trigger_type     text not null default 'manual' check (trigger_type in ('manual', 'agendado')),
  requested_by     uuid references public.profiles (id) on delete set null,
  started_at       timestamptz,
  finished_at      timestamptz,
  files_found      integer not null default 0,
  files_processed  integer not null default 0,
  records_read     bigint not null default 0,
  new_leads        integer not null default 0,
  updated_records  bigint not null default 0,
  error_count      integer not null default 0,
  errors           jsonb not null default '[]'::jsonb,
  log              jsonb not null default '[]'::jsonb,
  is_current       boolean not null default false,  -- última importação VÁLIDA e completa
  metadata         jsonb not null default '{}'::jsonb,
  created_at       timestamptz not null default now(),
  constraint import_jobs_current_requires_done check (not is_current or status = 'concluido')
);
-- Só uma importação vigente
create unique index import_jobs_single_current on public.import_jobs ((true)) where is_current;
-- Só um job em execução por vez
create unique index import_jobs_single_running on public.import_jobs ((true))
  where status in ('baixando', 'processando', 'validando');
create index import_jobs_created_idx on public.import_jobs (created_at desc);

alter table public.leads
  add constraint leads_import_job_fk foreign key (import_job_id)
  references public.import_jobs (id) on delete set null;

-- Estado das integrações externas (worker, armazenamento, WhatsApp).
-- Tabela adicional, para a interface mostrar com clareza o que está pendente.
create table public.integration_status (
  key           text primary key check (key in ('worker', 'storage', 'whatsapp', 'enriquecimento')),
  label         text not null,
  status        text not null default 'nao_configurado'
                  check (status in ('nao_configurado', 'configurado', 'ativo', 'erro')),
  last_seen_at  timestamptz,
  details       jsonb not null default '{}'::jsonb,
  updated_at    timestamptz not null default now()
);

-- =====================================================================
-- AUDITORIA
-- =====================================================================
create table public.audit_logs (
  id          bigint generated always as identity primary key,
  actor_id    uuid,
  action      text not null check (action in ('INSERT', 'UPDATE', 'DELETE')),
  table_name  text not null,
  record_id   text,
  old_data    jsonb,
  new_data    jsonb,
  created_at  timestamptz not null default now()
);
create index audit_logs_table_idx on public.audit_logs (table_name, created_at desc);
create index audit_logs_actor_idx on public.audit_logs (actor_id, created_at desc);

-- ---------------------------------------------------------------------
-- updated_at triggers
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array[
    'profiles', 'companies', 'establishments', 'service_catalog',
    'cnae_service_rules', 'leads', 'lead_searches', 'message_templates'
  ] loop
    execute format(
      'create trigger %I before update on public.%I for each row execute function public.set_updated_at()',
      t || '_updated_at', t);
  end loop;
end $$;
