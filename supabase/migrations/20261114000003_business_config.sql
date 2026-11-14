-- =====================================================================
-- JS Lead Hunter — Configuração comercial inicial da JS Designer
-- Não são dados cadastrais: são os serviços da própria JS Designer e
-- pesos de pontuação iniciais, todos editáveis pelo administrador.
-- =====================================================================

insert into public.service_catalog (code, name, description, sort_order) values
  ('apresentacoes',     'Apresentações comerciais',            'Apresentações institucionais e de vendas.', 10),
  ('portfolio',         'Portfólios profissionais',            'Portfólio impresso e digital.', 20),
  ('cartao_visita',     'Cartões de visita',                   'Criação e arte-final de cartões.', 30),
  ('site_institucional','Sites institucionais',                'Site institucional responsivo.', 40),
  ('identidade_visual', 'Identidade e materiais comerciais',   'Marca, papelaria e materiais de venda.', 50),
  ('suporte_admin',     'Suporte administrativo',              'Apoio em rotinas administrativas.', 60),
  ('automacao',         'Automatização de tarefas',            'Automação de processos repetitivos.', 70),
  ('consultoria_ti',    'Consultoria em tecnologia da informação', 'Diagnóstico e orientação em TI.', 80),
  ('sistemas',          'Desenvolvimento de sistemas e soluções digitais', 'Sistemas sob medida.', 90);

-- Regras gerais: toda empresa nova costuma precisar de identidade e cartão.
-- Regras específicas por CNAE devem ser cadastradas pelo administrador.
insert into public.cnae_service_rules (cnae_prefix, service_id, relevance, reason)
select '*', id, rel, motivo from (values
  ('identidade_visual', 70, 'Empresa recém-aberta, normalmente sem identidade consolidada'),
  ('cartao_visita',     60, 'Material básico para início das atividades'),
  ('site_institucional',50, 'Presença digital inicial')
) v(code, rel, motivo)
join public.service_catalog s on s.code = v.code;

-- Pesos iniciais (soma = 100)
insert into public.scoring_rules (key, label, description, points, params) values
  ('recencia',        'Recência da abertura',
   'Pontuação integral até o 1º limite de dias; metade até o 2º.', 25,
   '{"dias_integral": 30, "dias_metade": 90}'),
  ('telefone',        'Telefone disponível',   'Estabelecimento possui telefone no cadastro.', 15, '{}'),
  ('email',           'E-mail disponível',     'Estabelecimento possui e-mail no cadastro.', 15, '{}'),
  ('cnae_compativel', 'Compatibilidade do CNAE',
   'Proporcional à maior relevância entre as regras de CNAE aplicáveis.', 20, '{}'),
  ('porte',           'Porte empresarial',     'Pontos por porte informado.', 10,
   '{"01": 6, "03": 10, "05": 8, "00": 0}'),
  ('oportunidade_digital', 'Oportunidade digital identificada',
   'Só pontua quando o enriquecimento confirmar ausência ou fragilidade de presença digital.', 15, '{}');

insert into public.integration_status (key, label, details) values
  ('worker',         'Worker de importação (Python)',     '{"descricao": "Processa os arquivos oficiais da Receita Federal"}'),
  ('storage',        'Armazenamento temporário (R2/S3)', '{"descricao": "Guarda os ZIPs baixados durante o processamento"}'),
  ('whatsapp',       'WhatsApp Business Cloud API',       '{"descricao": "Envio controlado de mensagens com modelos aprovados"}'),
  ('enriquecimento', 'Enriquecimento de presença digital','{"descricao": "Identificação de site e redes sociais"}');
