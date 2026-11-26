-- =====================================================================
-- JS Lead Hunter — Operação comercial (auditoria de 25/11/2026)
-- Somente alterações ADITIVAS: nenhuma tabela, coluna ou dado existente
-- é removido. Corrige duplicidade pós-arquivamento, concorrência entre
-- workers, permissões, e acrescenta propostas, respostas, diagnóstico
-- comercial, modelos de abordagem e indicadores comerciais.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Concorrência entre workers: batimento por job.
--    Um job só é considerado "abandonado" se ficar sem batimento.
-- ---------------------------------------------------------------------
alter table public.import_jobs add column if not exists heartbeat_at timestamptz;
alter table public.import_jobs add column if not exists worker_host text;

-- ---------------------------------------------------------------------
-- 2. Duplicidade: empresa arquivada não volta como lead novo.
-- ---------------------------------------------------------------------
create index if not exists lead_archive_basico_idx on public.lead_archive (cnpj_basico);

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
     and not exists (select 1 from public.lead_archive a where a.cnpj_basico = e.cnpj_basico)
   order by e.cnpj_basico, e.identificador_matriz, e.cnpj
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.worker_create_leads(uuid, date, date, boolean) from public, anon, authenticated;

-- Estimativa do que um arquivamento liberaria, ANTES de apagar qualquer coisa
create or replace function public.archive_candidates_count(p_incluir_alta boolean default false)
returns integer
language sql stable security definer set search_path = public as $$
  select count(*)::int from public.leads l
   where l.stage = 'novo' and l.owner_id is null and l.next_follow_up_at is null
     and (p_incluir_alta or l.priority <> 'alta')
     and public.lead_is_untouched(l.id)
$$;
revoke all on function public.archive_candidates_count(boolean) from public, anon, authenticated;

create or replace function public.archive_summary()
returns jsonb
language sql stable security invoker set search_path = public as $$
  select jsonb_build_object(
    'total', (select count(*) from public.lead_archive),
    'ultimo', (select max(archived_at) from public.lead_archive),
    'banco_mb', round(pg_database_size(current_database()) / 1048576.0),
    'elegiveis', (select count(*) from public.leads l
                   where l.stage = 'novo' and l.owner_id is null and l.next_follow_up_at is null
                     and not exists (select 1 from public.lead_events ev
                                      where ev.lead_id = l.id and ev.event_type not in ('criado', 'pontuacao_alterada'))))
$$;
revoke all on function public.archive_summary() from public, anon;
grant execute on function public.archive_summary() to authenticated;

-- ---------------------------------------------------------------------
-- 3. Usuários que se cadastram sozinhos entram INATIVOS.
--    O primeiro usuário continua virando admin; convites (Edge Function)
--    ativam o usuário. Usuários existentes não são alterados.
-- ---------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  first_user boolean := not exists (select 1 from public.profiles where role = 'admin');
begin
  insert into public.profiles (id, email, full_name, role, active)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'full_name', split_part(new.email, '@', 1)),
    case when first_user then 'admin'::public.app_role else 'leitura'::public.app_role end,
    first_user);
  return new;
end $$;

-- ---------------------------------------------------------------------
-- 4. Campos do sistema no lead: só o worker (ou admin) altera.
-- ---------------------------------------------------------------------
create or replace function public.leads_protect_system_columns()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or public.is_bulk_load() or public.has_role(array['admin']::public.app_role[]) then
    return new;
  end if;
  if new.score is distinct from old.score
     or new.score_breakdown is distinct from old.score_breakdown
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

drop trigger if exists leads_protect_system_columns on public.leads;
create trigger leads_protect_system_columns
  before update on public.leads
  for each row execute function public.leads_protect_system_columns();

-- ---------------------------------------------------------------------
-- 5. Histórico: respostas recebidas e propostas
-- ---------------------------------------------------------------------
alter table public.lead_events drop constraint if exists lead_events_event_type_check;
alter table public.lead_events add constraint lead_events_event_type_check check (event_type in (
  'criado', 'mudanca_etapa', 'anotacao', 'contato', 'resposta_recebida',
  'follow_up_agendado', 'follow_up_concluido', 'responsavel_alterado',
  'pontuacao_alterada', 'bloqueado', 'proposta'));

drop policy if exists lead_events_insert on public.lead_events;
create policy lead_events_insert on public.lead_events for insert to authenticated
  with check (
    public.has_role(array['admin', 'gestor', 'comercial']::public.app_role[])
    and actor_id = auth.uid()
    and event_type in ('anotacao', 'contato', 'resposta_recebida', 'follow_up_concluido'));

-- Contato ou resposta não podem ser registrados para empresa bloqueada
create or replace function public.lead_events_check_suppression()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.event_type in ('contato', 'resposta_recebida') and exists (
       select 1 from public.leads l join public.contact_suppressions s on s.cnpj_basico = l.cnpj_basico
        where l.id = new.lead_id) then
    raise exception 'Empresa bloqueada para contato' using errcode = 'check_violation';
  end if;
  return new;
end $$;
drop trigger if exists lead_events_check_suppression on public.lead_events;
create trigger lead_events_check_suppression
  before insert on public.lead_events
  for each row execute function public.lead_events_check_suppression();

-- ---------------------------------------------------------------------
-- 6. Propostas e negociação
-- ---------------------------------------------------------------------
create table if not exists public.lead_proposals (
  id           uuid primary key default gen_random_uuid(),
  lead_id      uuid not null references public.leads (id) on delete cascade,
  title        text not null check (length(trim(title)) > 0),
  service_ids  uuid[] not null default '{}',
  amount       numeric(14, 2) check (amount is null or amount >= 0),
  status       text not null default 'rascunho'
                 check (status in ('rascunho', 'enviada', 'em_negociacao', 'aceita', 'recusada', 'expirada')),
  sent_at      timestamptz,
  valid_until  date,
  decided_at   timestamptz,
  notes        text,
  created_by   uuid references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index if not exists lead_proposals_lead_idx on public.lead_proposals (lead_id, created_at desc);
create index if not exists lead_proposals_status_idx on public.lead_proposals (status);

alter table public.lead_proposals enable row level security;
revoke all on public.lead_proposals from anon;
create policy lead_proposals_select on public.lead_proposals for select to authenticated
  using (public.is_active_user());
create policy lead_proposals_insert on public.lead_proposals for insert to authenticated
  with check (public.has_role(array['admin', 'gestor', 'comercial']::public.app_role[]) and created_by = auth.uid());
create policy lead_proposals_update on public.lead_proposals for update to authenticated
  using (public.has_role(array['admin', 'gestor', 'comercial']::public.app_role[]))
  with check (public.has_role(array['admin', 'gestor', 'comercial']::public.app_role[]));
create policy lead_proposals_delete on public.lead_proposals for delete to authenticated
  using (public.has_role(array['admin']::public.app_role[]));

create trigger lead_proposals_updated_at before update on public.lead_proposals
  for each row execute function public.set_updated_at();
create trigger lead_proposals_audit after insert or update or delete on public.lead_proposals
  for each row execute function public.audit_trigger();

-- Datas automáticas, histórico e avanço de etapa (nunca retrocede nem mexe em convertido/perdido)
create or replace function public.lead_proposals_track()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  st public.lead_stage;
  ord int;
  stages public.lead_stage[] := array['novo', 'validado', 'pronto_contato', 'primeiro_contato',
    'aguardando_resposta', 'interessado', 'proposta_enviada', 'em_negociacao']::public.lead_stage[];
  target public.lead_stage;
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status
     and new.amount is not distinct from old.amount then
    return new;
  end if;

  insert into public.lead_events (lead_id, event_type, content, actor_id, metadata)
  values (new.lead_id, 'proposta', new.title, auth.uid(),
          jsonb_build_object('proposta_id', new.id, 'status', new.status, 'valor', new.amount,
                             'status_anterior', case when tg_op = 'UPDATE' then old.status end));

  target := case new.status when 'enviada' then 'proposta_enviada'::public.lead_stage
                            when 'em_negociacao' then 'em_negociacao'::public.lead_stage end;
  if target is not null then
    select stage into st from public.leads where id = new.lead_id;
    ord := array_position(stages, st);
    if ord is not null and ord < array_position(stages, target) then
      update public.leads set stage = target where id = new.lead_id;
    end if;
  end if;
  return new;
end $$;

create or replace function public.lead_proposals_dates()
returns trigger language plpgsql as $$
begin
  if new.status <> 'rascunho' and new.sent_at is null then new.sent_at := now(); end if;
  if new.status in ('aceita', 'recusada', 'expirada')
     and (tg_op = 'INSERT' or old.status is distinct from new.status) then
    new.decided_at := now();
  elsif new.status not in ('aceita', 'recusada', 'expirada') then
    new.decided_at := null;
  end if;
  return new;
end $$;

create trigger lead_proposals_dates before insert or update on public.lead_proposals
  for each row execute function public.lead_proposals_dates();
create trigger lead_proposals_track after insert or update on public.lead_proposals
  for each row execute function public.lead_proposals_track();

-- ---------------------------------------------------------------------
-- 7. Portfólio da JS Designer: categorias que faltavam
-- ---------------------------------------------------------------------
insert into public.service_catalog (code, name, description, sort_order) values
  ('redes_sociais',     'Gestão de redes sociais', 'Planejamento, criação de conteúdo e gestão de perfis.', 45),
  ('catalogo_digital',  'Catálogos digitais',      'Catálogo de produtos e serviços em formato digital.', 55),
  ('materiais_graficos','Materiais gráficos',      'Folhetos, cardápios, banners, fachada e papelaria.', 58)
on conflict (code) do nothing;

insert into public.cnae_service_rules (cnae_prefix, service_id, relevance, reason)
select v.prefix, s.id, v.rel, v.motivo
  from (values
  ('47', 'redes_sociais', 80, 'Varejo atrai clientes com perfil ativo nas redes sociais'),
  ('47', 'catalogo_digital', 75, 'Loja nova pode vender pelo WhatsApp com catálogo digital'),
  ('56', 'redes_sociais', 85, 'Restaurantes e lanchonetes divulgam cardápio e promoções nas redes'),
  ('56', 'materiais_graficos', 80, 'Cardápio, fachada e embalagens'),
  ('46', 'catalogo_digital', 80, 'Atacado apresenta linha de produtos a revendedores'),
  ('10', 'catalogo_digital', 70, 'Indústria apresenta produtos a distribuidores'),
  ('14', 'catalogo_digital', 80, 'Confecção vende por catálogo de coleção'),
  ('14', 'redes_sociais', 75, 'Moda depende de vitrine nas redes'),
  ('31', 'catalogo_digital', 75, 'Móveis vendidos por catálogo'),
  ('86', 'redes_sociais', 65, 'Clínicas e consultórios comunicam serviços nas redes'),
  ('86', 'materiais_graficos', 60, 'Materiais para recepção e divulgação'),
  ('96', 'redes_sociais', 80, 'Beleza e estética vivem de antes e depois nas redes'),
  ('93', 'redes_sociais', 75, 'Academias e lazer divulgam aulas e eventos'),
  ('55', 'redes_sociais', 70, 'Hospedagem divulga a experiência nas redes'),
  ('79', 'redes_sociais', 70, 'Turismo vende destinos com conteúdo visual'),
  ('68', 'redes_sociais', 65, 'Imobiliárias divulgam imóveis nas redes'),
  ('85', 'redes_sociais', 60, 'Escolas e cursos captam alunos nas redes'),
  ('43', 'materiais_graficos', 60, 'Adesivos de veículo, uniformes e orçamentos impressos'),
  ('45', 'materiais_graficos', 60, 'Fachada e materiais de oficina'),
  ('18', 'materiais_graficos', 50, 'Gráficas: parceria em arte-final')
  ) as v(prefix, code, rel, motivo)
  join public.service_catalog s on s.code = v.code
on conflict (cnae_prefix, service_id) do nothing;

-- ---------------------------------------------------------------------
-- 8. Recomendações levam em conta a presença digital VERIFICADA
-- ---------------------------------------------------------------------
create or replace function public.rebuild_lead_recommendations(
  p_lead_ids uuid[] default null,
  p_import_job_id uuid default null)
returns integer
language plpgsql security definer set search_path = public as $$
declare
  n integer;
  site_id uuid := (select id from public.service_catalog where code = 'site_institucional' and active);
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

  -- Ausência de site comprovada pela verificação do domínio próprio
  if site_id is not null then
    insert into public.lead_recommendations (lead_id, service_id, rule_id, relevance, reason)
    select l.id, site_id, null, 95,
           case l.digital_presence ->> 'status'
             when 'sem_site' then 'Verificado: o domínio próprio ' || coalesce(l.digital_presence ->> 'dominio', '') || ' não tem site no ar'
             else 'Verificado: o domínio próprio ' || coalesce(l.digital_presence ->> 'dominio', '') || ' tem página vazia, padrão ou estacionada' end
      from public.leads l
     where l.digital_presence ->> 'status' in ('sem_site', 'site_fraco')
       and (p_lead_ids is null or l.id = any (p_lead_ids))
       and (p_import_job_id is null or l.import_job_id = p_import_job_id)
    on conflict (lead_id, service_id) do update
      set relevance = greatest(public.lead_recommendations.relevance, excluded.relevance),
          reason = excluded.reason, rule_id = null;
  end if;
  return n;
end $$;
revoke all on function public.rebuild_lead_recommendations(uuid[], uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 9. Diagnóstico comercial individual (explicável, só com fatos verificáveis)
-- ---------------------------------------------------------------------
create or replace function public.lead_diagnosis(p_lead_id uuid)
returns jsonb
language plpgsql stable security invoker set search_path = public as $$
declare
  r record;
  ref date := public.current_reference_date();
  ops jsonb := '[]'::jsonb;
  cautions jsonb := '[]'::jsonb;
  dp jsonb;
  dias int;
  top record;
begin
  select l.id, l.score, l.priority, l.digital_presence, l.website,
         c.razao_social, e.nome_fantasia, e.data_inicio_atividade, e.cnae_principal,
         k.description as cnae_desc, m.name as municipio, e.uf, e.has_phone, e.has_email, e.email,
         s.opcao_mei
    into r
    from public.leads l
    join public.establishments e on e.cnpj = l.cnpj
    join public.companies c on c.cnpj_basico = l.cnpj_basico
    left join public.cnae_catalog k on k.code = e.cnae_principal
    left join public.municipalities m on m.code = e.municipio_code
    left join public.company_simple_status s on s.cnpj_basico = l.cnpj_basico
   where l.id = p_lead_id;
  if not found then
    return null;
  end if;

  dp := coalesce(r.digital_presence, '{}'::jsonb);
  dias := case when r.data_inicio_atividade is not null then ref - r.data_inicio_atividade end;

  case dp ->> 'status'
    when 'sem_site' then
      ops := ops || jsonb_build_object('tipo', 'site', 'servico', 'site_institucional',
        'oportunidade', 'Ausência de site verificada no domínio próprio do e-mail cadastral',
        'evidencia', 'O domínio ' || coalesce(dp ->> 'dominio', '?') || ' não respondeu como site em '
                     || coalesce(to_char((dp ->> 'checked_at')::timestamptz, 'DD/MM/YYYY'), 'data não registrada'),
        'recomendacao', 'Desenvolvimento de site institucional com apresentação dos serviços, localização e canais de contato.');
    when 'site_fraco' then
      ops := ops || jsonb_build_object('tipo', 'site', 'servico', 'site_institucional',
        'oportunidade', 'Site com página vazia, padrão ou estacionada',
        'evidencia', 'Verificação de ' || coalesce(dp ->> 'dominio', '?') || ': ' || coalesce(dp ->> 'detalhe', 'página sem conteúdo'),
        'recomendacao', 'Criação ou reformulação do site institucional, aproveitando o domínio que a empresa já tem.');
    when 'site_ok' then
      cautions := cautions || to_jsonb('Já tem site no ar (' || coalesce(r.website, dp ->> 'url', dp ->> 'dominio') || '): oferecer melhorias só depois de avaliar o site.'::text);
    when 'inconclusivo' then
      cautions := cautions || to_jsonb('A verificação do site foi inconclusiva (o servidor recusou ou falhou): não afirmar que a empresa não tem site.'::text);
    when 'sem_dominio_proprio' then
      cautions := cautions || to_jsonb('Usa e-mail genérico: não foi possível verificar se tem site. Perguntar no primeiro contato.'::text);
    when 'dominio_compartilhado' then
      cautions := cautions || to_jsonb('O e-mail cadastral é de terceiro (ex.: contador): não representa a presença digital da empresa.'::text);
    else
      cautions := cautions || to_jsonb('Presença digital ainda não verificada.'::text);
  end case;

  if dias is not null and dias <= 90 then
    ops := ops || jsonb_build_object('tipo', 'recencia', 'servico', 'identidade_visual',
      'oportunidade', 'Empresa recém-aberta',
      'evidencia', 'Início de atividade em ' || to_char(r.data_inicio_atividade, 'DD/MM/YYYY') || ' (' || dias || ' dias antes da data de referência da base)',
      'recomendacao', 'Identidade visual e materiais de lançamento para começar com uma marca consistente.');
  end if;

  for top in
    select s.code, s.name, lr.relevance, lr.reason
      from public.lead_recommendations lr join public.service_catalog s on s.id = lr.service_id
     where lr.lead_id = p_lead_id and lr.rule_id is not null
     order by lr.relevance desc limit 3
  loop
    ops := ops || jsonb_build_object('tipo', 'segmento', 'servico', top.code,
      'oportunidade', top.name,
      'evidencia', 'CNAE ' || coalesce(r.cnae_principal, '?') || ' — ' || coalesce(r.cnae_desc, 'atividade não descrita'),
      'recomendacao', coalesce(top.reason, top.name), 'relevancia', top.relevance);
  end loop;

  if not r.has_phone and not r.has_email then
    cautions := cautions || to_jsonb('Sem telefone e sem e-mail no cadastro público: contato depende de pesquisa manual.'::text);
  end if;

  return jsonb_build_object(
    'empresa', coalesce(r.nome_fantasia, r.razao_social),
    'atividade', r.cnae_desc,
    'local', concat_ws(' / ', r.municipio, r.uf),
    'pontuacao', r.score,
    'prioridade', r.priority,
    'oportunidades', ops,
    'ressalvas', cautions,
    'data_referencia', ref);
end $$;
revoke all on function public.lead_diagnosis(uuid) from public, anon;
grant execute on function public.lead_diagnosis(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 10. Modelos de abordagem por segmento/oportunidade (envio sempre manual)
-- ---------------------------------------------------------------------
alter table public.message_templates add column if not exists service_code text;
alter table public.message_templates add column if not exists cnae_prefix text
  check (cnae_prefix is null or cnae_prefix ~ '^[0-9]{2,7}$');
alter table public.message_templates add column if not exists purpose text not null default 'abordagem'
  check (purpose in ('abordagem', 'follow_up', 'api'));

insert into public.message_templates (name, channel, language, body, variables, service_code, cnae_prefix, purpose, active)
values
  ('Abordagem · site · WhatsApp', 'whatsapp', 'pt_BR',
   'Olá! Aqui é {{responsavel}}, da JS Designer. Vi que a {{empresa}} começou as atividades em {{cidade}} há pouco tempo, parabéns! Procurei o site de vocês pelo domínio {{dominio}} e não encontrei uma página no ar. Criamos sites institucionais com os serviços, a localização e os contatos da empresa. Posso te mostrar alguns exemplos?',
   '{responsavel,empresa,cidade,dominio}', 'site_institucional', null, 'abordagem', true),
  ('Abordagem · identidade visual · WhatsApp', 'whatsapp', 'pt_BR',
   'Olá! Aqui é {{responsavel}}, da JS Designer. Vi que a {{empresa}} abriu recentemente em {{cidade}}. Empresas que estão começando costumam precisar de marca, cartão e materiais de divulgação, e é isso que fazemos. Faz sentido conversarmos?',
   '{responsavel,empresa,cidade}', 'identidade_visual', null, 'abordagem', true),
  ('Abordagem · redes sociais · WhatsApp', 'whatsapp', 'pt_BR',
   'Olá! Aqui é {{responsavel}}, da JS Designer. Para {{atividade_curta}} como a {{empresa}}, as redes sociais costumam trazer boa parte dos clientes. Cuidamos do planejamento e da criação dos posts. Posso te enviar uma proposta?',
   '{responsavel,empresa,atividade_curta}', 'redes_sociais', null, 'abordagem', true),
  ('Abordagem · alimentação · WhatsApp', 'whatsapp', 'pt_BR',
   'Olá! Aqui é {{responsavel}}, da JS Designer. Vi que a {{empresa}} abriu em {{cidade}}. Fazemos cardápio, fachada, identidade visual e posts para restaurantes e lanchonetes. Quer ver alguns trabalhos?',
   '{responsavel,empresa,cidade}', 'identidade_visual', '56', 'abordagem', true),
  ('Abordagem · catálogo · e-mail', 'email', 'pt_BR',
   'Olá, equipe da {{empresa}}.

Sou {{responsavel}}, da JS Designer. Vimos que a empresa iniciou as atividades recentemente em {{cidade}} ({{atividade}}). Desenvolvemos catálogos digitais e apresentações comerciais para mostrar os produtos a clientes e revendedores.

Se fizer sentido, posso enviar exemplos e uma proposta sem compromisso. Caso prefira não receber novos contatos, basta responder a este e-mail.

Atenciosamente,
{{responsavel}} — JS Designer',
   '{empresa,responsavel,cidade,atividade}', 'catalogo_digital', null, 'abordagem', true),
  ('Abordagem · geral · e-mail', 'email', 'pt_BR',
   'Olá, equipe da {{empresa}}.

Sou {{responsavel}}, da JS Designer, e vi que a empresa abriu recentemente em {{cidade}}. Ajudamos empresas novas com identidade visual, site, redes sociais e materiais comerciais.

{{oportunidade}}

Posso enviar alguns exemplos do nosso trabalho? Caso prefira não receber novos contatos, basta responder a este e-mail.

Atenciosamente,
{{responsavel}} — JS Designer',
   '{empresa,responsavel,cidade,oportunidade}', null, null, 'abordagem', true),
  ('Follow-up · WhatsApp', 'whatsapp', 'pt_BR',
   'Olá! Aqui é {{responsavel}}, da JS Designer. Passando para saber se você conseguiu ver a mensagem que enviei sobre a {{empresa}}. Se não for o momento, sem problema, é só me avisar.',
   '{responsavel,empresa}', null, null, 'follow_up', true)
on conflict (name) do nothing;

-- ---------------------------------------------------------------------
-- 11. Indicadores comerciais do dashboard (dados reais do banco)
-- ---------------------------------------------------------------------
create or replace function public.commercial_metrics(p_uf text default null)
returns jsonb
language sql stable security invoker set search_path = public as $$
  with cur as (select id from public.import_jobs where is_current limit 1),
  ld as (
    select l.* from public.leads l
      join public.establishments e on e.cnpj = l.cnpj
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
  top_service as (
    select distinct on (lr.lead_id) lr.lead_id, s.name
      from public.lead_recommendations lr
      join ld on ld.id = lr.lead_id
      join public.service_catalog s on s.id = lr.service_id
     order by lr.lead_id, lr.relevance desc, s.sort_order
  ),
  base as (
    select ld.id, ld.owner_id, ld.stage, ld.priority,
           ld.id in (select lead_id from contacted) as contatado,
           ld.id in (select lead_id from responded) as respondeu,
           ld.id in (select lead_id from props) as com_proposta,
           ld.stage = 'convertido' as convertido
      from ld
  ),
  n as (
    select count(*) filter (where contatado) as contatados,
           count(*) filter (where convertido) as convertidos
      from base
  )
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
        select ts.name as label, count(*) as leads,
               count(*) filter (where b.contatado) as contatados,
               count(*) filter (where b.com_proposta) as propostas,
               count(*) filter (where b.convertido) as convertidos
          from base b join top_service ts on ts.lead_id = b.id
         group by ts.name) x), '[]'::jsonb),
    'por_responsavel', coalesce((select jsonb_agg(x order by x.leads desc) from (
        select coalesce(p.full_name, p.email, 'Sem responsável') as label, count(*) as leads,
               count(*) filter (where b.contatado) as contatados,
               count(*) filter (where b.com_proposta) as propostas,
               count(*) filter (where b.convertido) as convertidos
          from base b left join public.profiles p on p.id = b.owner_id
         where b.owner_id is not null or b.contatado
         group by 1) x), '[]'::jsonb),
    'por_etapa', coalesce((select jsonb_agg(x) from (
        select stage as label, count(*) as total from ld group by stage) x), '[]'::jsonb)
  )
$$;
revoke all on function public.commercial_metrics(text) from public, anon;
grant execute on function public.commercial_metrics(text) to authenticated;

-- ---------------------------------------------------------------------
-- 12. "Sem site" antigo não tinha prova: era só falta de resposta (tempo
--     esgotado, conexão recusada). Passa a inconclusivo e é reverificado
--     na próxima rodada, agora com consulta ao DNS.
-- ---------------------------------------------------------------------
select set_config('app.bulk_load', 'on', true);

update public.leads
   set digital_presence = digital_presence || jsonb_build_object(
         'status', 'inconclusivo',
         'status_anterior', 'sem_site',
         'detalhe', 'sem resposta do servidor (' || coalesce(digital_presence ->> 'detalhe', 'desconhecido') || ')',
         'checked_at', now() - interval '8 days',
         'corrigido_em', now())
 where digital_presence ->> 'status' = 'sem_site'
   and coalesce(digital_presence ->> 'detalhe', '') <> 'domínio não existe no DNS';

select public.recalculate_lead_scores(null, null, public.current_reference_date());
-- Aplica a nova regra de recomendação aos leads já existentes
select public.rebuild_lead_recommendations();
