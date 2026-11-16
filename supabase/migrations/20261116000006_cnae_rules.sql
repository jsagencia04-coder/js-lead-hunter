-- =====================================================================
-- JS Lead Hunter — Regras iniciais de CNAE para os serviços da JS Designer
-- Padrões comerciais iniciais (não são dados oficiais): o administrador
-- pode editar, desativar ou excluir em Administração → Serviços e pontuação.
-- A regra de prefixo mais longo prevalece (ex.: 9602 sobre 96).
-- =====================================================================

insert into public.cnae_service_rules (cnae_prefix, service_id, relevance, reason)
select v.prefix, s.id, v.rel, v.motivo
  from (values
  ('47', 'site_institucional', 80, 'Varejo depende de vitrine digital para atrair clientes'),
  ('47', 'identidade_visual', 80, 'Loja nova precisa de marca, fachada e materiais de ponto de venda'),
  ('47', 'cartao_visita', 60, 'Material de divulgação no balcão'),
  ('46', 'apresentacoes', 80, 'Atacadista vende para empresas: apresentação comercial e catálogo'),
  ('46', 'automacao', 60, 'Pedidos e cotações repetitivos'),
  ('46', 'sistemas', 60, 'Controle de pedidos e estoque'),
  ('56', 'identidade_visual', 85, 'Alimentação vive de marca, cardápio e fachada'),
  ('56', 'site_institucional', 65, 'Cardápio online e presença em buscas locais'),
  ('56', 'cartao_visita', 60, 'Divulgação local'),
  ('55', 'site_institucional', 85, 'Hospedagem depende de site para reservas'),
  ('55', 'identidade_visual', 75, 'Marca e materiais para hóspedes'),
  ('41', 'portfolio', 80, 'Construtoras vendem com portfólio de obras'),
  ('41', 'apresentacoes', 75, 'Apresentação para clientes e investidores'),
  ('42', 'apresentacoes', 75, 'Propostas para contratos de infraestrutura'),
  ('43', 'portfolio', 80, 'Serviços de obra vendidos por portfólio de trabalhos'),
  ('43', 'cartao_visita', 65, 'Contato rápido com clientes'),
  ('68', 'site_institucional', 85, 'Imobiliárias precisam de vitrine de imóveis'),
  ('68', 'portfolio', 70, 'Portfólio de empreendimentos'),
  ('69', 'site_institucional', 80, 'Escritórios jurídicos e contábeis são buscados online'),
  ('69', 'identidade_visual', 75, 'Credibilidade da marca profissional'),
  ('69', 'automacao', 70, 'Rotinas administrativas e de clientes'),
  ('70', 'apresentacoes', 85, 'Consultorias vendem com apresentações'),
  ('70', 'portfolio', 80, 'Portfólio de cases'),
  ('70', 'site_institucional', 75, 'Autoridade e captação de clientes'),
  ('71', 'portfolio', 90, 'Arquitetura e engenharia vendem por portfólio'),
  ('71', 'site_institucional', 75, 'Vitrine de projetos'),
  ('73', 'portfolio', 85, 'Agências e publicidade dependem de portfólio'),
  ('73', 'apresentacoes', 80, 'Propostas para clientes'),
  ('74', 'portfolio', 85, 'Design, fotografia e serviços técnicos vendem por portfólio'),
  ('74', 'site_institucional', 70, 'Vitrine de trabalhos'),
  ('82', 'suporte_admin', 80, 'Serviços administrativos terceirizáveis'),
  ('82', 'automacao', 75, 'Processos repetitivos de escritório'),
  ('85', 'apresentacoes', 80, 'Educação usa material de aula e apresentações'),
  ('85', 'site_institucional', 75, 'Matrículas e divulgação de cursos'),
  ('86', 'site_institucional', 80, 'Pacientes procuram clínicas online'),
  ('86', 'identidade_visual', 75, 'Confiança e padronização visual'),
  ('86', 'sistemas', 60, 'Agendamento e prontuário'),
  ('87', 'site_institucional', 70, 'Divulgação de serviços de assistência'),
  ('93', 'identidade_visual', 75, 'Academias e lazer dependem de marca'),
  ('93', 'site_institucional', 70, 'Planos e horários online'),
  ('9602', 'identidade_visual', 85, 'Salões e estética vivem de marca'),
  ('9602', 'cartao_visita', 70, 'Cartão de agendamento'),
  ('9602', 'site_institucional', 60, 'Agendamento online'),
  ('96', 'identidade_visual', 70, 'Serviços pessoais precisam de marca'),
  ('62', 'portfolio', 60, 'Empresas de TI mostram projetos'),
  ('62', 'apresentacoes', 60, 'Propostas técnicas'),
  ('63', 'site_institucional', 60, 'Serviços digitais exigem presença online'),
  ('49', 'automacao', 65, 'Rotas, cobranças e controles'),
  ('49', 'suporte_admin', 60, 'Rotina administrativa de transporte'),
  ('52', 'sistemas', 65, 'Armazenagem e logística precisam de controle'),
  ('45', 'site_institucional', 70, 'Oficinas e revendas são buscadas online'),
  ('45', 'identidade_visual', 65, 'Fachada e materiais'),
  ('10', 'apresentacoes', 75, 'Indústria de alimentos vende para distribuidores'),
  ('10', 'identidade_visual', 70, 'Embalagem e marca'),
  ('14', 'portfolio', 75, 'Confecção vende por catálogo'),
  ('14', 'identidade_visual', 70, 'Marca de moda'),
  ('25', 'apresentacoes', 70, 'Catálogo técnico de produtos'),
  ('31', 'portfolio', 75, 'Móveis vendidos por catálogo'),
  ('01', 'sistemas', 55, 'Controle de produção rural'),
  ('85', 'sistemas', 55, 'Gestão acadêmica'),
  ('75', 'site_institucional', 75, 'Clínicas veterinárias são buscadas online'),
  ('75', 'identidade_visual', 70, 'Marca e materiais'),
  ('78', 'automacao', 70, 'Recrutamento e triagem repetitivos'),
  ('79', 'site_institucional', 80, 'Turismo vende online'),
  ('81', 'cartao_visita', 65, 'Serviços prediais e limpeza prospectam presencialmente'),
  ('81', 'apresentacoes', 65, 'Propostas para condomínios e empresas'),
  ('90', 'portfolio', 80, 'Artistas e produtoras vendem por portfólio'),
  ('59', 'portfolio', 85, 'Produção audiovisual vende por portfólio'),
  ('18', 'portfolio', 70, 'Gráficas mostram trabalhos'),
  ('95', 'cartao_visita', 65, 'Reparos dependem de contato local')
  ) as v(prefix, code, rel, motivo)
  join public.service_catalog s on s.code = v.code
on conflict (cnae_prefix, service_id) do nothing;

-- Recalcula pontuação e recomendações dos leads existentes
select set_config('app.bulk_load', 'on', true);
select public.recalculate_lead_scores(null, null, public.current_reference_date());
select public.rebuild_lead_recommendations();
