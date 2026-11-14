-- =====================================================================
-- JS Lead Hunter — Períodos contados a partir da data de referência da base
-- A base pública do CNPJ é publicada com defasagem (competência mensal).
-- "Abertas nos últimos N dias" passa a contar a partir da data de referência
-- da importação vigente (ou de hoje, se ainda não houver importação).
-- =====================================================================

create or replace function public.current_reference_date()
returns date
language sql stable security definer set search_path = public as $$
  select coalesce((select reference_date from public.import_jobs where is_current limit 1), current_date)
$$;
revoke all on function public.current_reference_date() from public, anon;
grant execute on function public.current_reference_date() to authenticated;

-- Dashboard: a função original vira dashboard_metrics_at; a nova usa a data de referência por padrão
alter function public.dashboard_metrics(text, date, text) rename to dashboard_metrics_at;

create or replace function public.dashboard_metrics(
  p_uf text default null, p_ref_date date default null, p_municipio text default null)
returns jsonb
language sql stable security invoker set search_path = public as $$
  select public.dashboard_metrics_at(p_uf, coalesce(p_ref_date, public.current_reference_date()), p_municipio)
    || jsonb_build_object('data_referencia', coalesce(p_ref_date, public.current_reference_date()))
$$;
revoke all on function public.dashboard_metrics(text, date, text) from public, anon;
grant execute on function public.dashboard_metrics(text, date, text) to authenticated;
revoke all on function public.dashboard_metrics_at(text, date, text) from public, anon;
grant execute on function public.dashboard_metrics_at(text, date, text) to authenticated;

-- Mapa
alter function public.map_state_counts(integer, date) rename to map_state_counts_at;

create or replace function public.map_state_counts(p_days integer default 90, p_ref_date date default null)
returns table (uf text, empresas bigint, leads bigint, leads_alta bigint)
language sql stable security invoker set search_path = public as $$
  select * from public.map_state_counts_at(p_days, coalesce(p_ref_date, public.current_reference_date()))
$$;
revoke all on function public.map_state_counts(integer, date) from public, anon;
grant execute on function public.map_state_counts(integer, date) to authenticated;
revoke all on function public.map_state_counts_at(integer, date) from public, anon;
grant execute on function public.map_state_counts_at(integer, date) to authenticated;

-- Recálculo pelo admin usa a mesma data de referência do worker
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
  scores := public.recalculate_lead_scores(null, null, public.current_reference_date());
  recs := public.rebuild_lead_recommendations();
  insert into public.audit_logs (actor_id, action, table_name, record_id, new_data)
  values (auth.uid(), 'UPDATE', 'leads', 'recalculo_geral',
          jsonb_build_object('pontuacoes_alteradas', scores, 'recomendacoes', recs));
  return jsonb_build_object('pontuacoes_alteradas', scores, 'recomendacoes', recs);
end $$;
revoke all on function public.admin_recalculate_leads() from public, anon;
grant execute on function public.admin_recalculate_leads() to authenticated;
