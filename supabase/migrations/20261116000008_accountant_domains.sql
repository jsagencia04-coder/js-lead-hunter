-- =====================================================================
-- JS Lead Hunter — E-mails de escritórios de contabilidade
-- Ao abrir o CNPJ, o contador costuma cadastrar o próprio e-mail. Para
-- empresas que não são de contabilidade (CNAE 6920), esse domínio não
-- representa a presença digital da empresa: vira "dominio_compartilhado".
-- =====================================================================
select set_config('app.bulk_load', 'on', true);

with alvo as (
  select l.id, l.digital_presence ->> 'url' as url_detectada
    from public.leads l
    join public.establishments e on e.cnpj = l.cnpj
   where l.digital_presence ->> 'dominio' ~* '(contab|contador|contabil|escritorio|assessoriacont)'
     and coalesce(e.cnae_principal, '') not like '6920%'
     and l.digital_presence ->> 'status' in ('sem_site', 'site_fraco', 'site_ok', 'inconclusivo')
)
update public.leads l
   set digital_presence = l.digital_presence
         || jsonb_build_object('status', 'dominio_compartilhado',
                               'motivo', 'domínio de escritório de contabilidade', 'corrigido_em', now()),
       website = case when l.website = a.url_detectada then null else l.website end
  from alvo a
 where a.id = l.id;

select public.recalculate_lead_scores(null, null, public.current_reference_date());
