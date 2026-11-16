-- =====================================================================
-- JS Lead Hunter — Corrige a primeira rodada de presença digital
-- Respostas 401/403/429/5xx são bloqueio de robôs ou falha do servidor,
-- não ausência de site: passam a "inconclusivo" (não pontua).
-- Respostas só 404/410 indicam hospedagem sem página: "site_fraco".
-- =====================================================================
select set_config('app.bulk_load', 'on', true);

with alvo as (
  select id,
         case when digital_presence ->> 'detalhe' ~ '^HTTP (401|403|429|5[0-9]{2})$' then 'inconclusivo'
              when digital_presence ->> 'detalhe' ~ '^HTTP 4[0-9]{2}$' then 'site_fraco'
         end as novo
    from public.leads
   where digital_presence ->> 'status' = 'sem_site'
     and digital_presence ->> 'detalhe' ~ '^HTTP [0-9]{3}$'
)
update public.leads l
   set digital_presence = l.digital_presence || jsonb_build_object('status', a.novo, 'corrigido_em', now())
  from alvo a
 where a.id = l.id and a.novo is not null;

select public.recalculate_lead_scores(null, null, public.current_reference_date());
