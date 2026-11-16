-- =====================================================================
-- JS Lead Hunter — Recalibração dos pesos padrão de pontuação
-- Na base real, ~99,9% das empresas novas têm telefone e e-mail e todas
-- são recentes: esses critérios não diferenciam leads. O peso passa para
-- o que diferencia: compatibilidade do CNAE e oportunidade digital
-- verificada. Só altera pesos que ainda estão no valor padrão original
-- (edições do administrador são preservadas).
-- =====================================================================
update public.scoring_rules r
   set points = v.novo, updated_at = now()
  from (values
    ('recencia', 25, 15),
    ('telefone', 15, 5),
    ('email', 15, 5),
    ('cnae_compativel', 20, 35),
    ('porte', 10, 10),
    ('oportunidade_digital', 15, 30)
  ) as v(key, antigo, novo)
 where r.key = v.key and r.points = v.antigo;

select set_config('app.bulk_load', 'on', true);
select public.recalculate_lead_scores(null, null, public.current_reference_date());
