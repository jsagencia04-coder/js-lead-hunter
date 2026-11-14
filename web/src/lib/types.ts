export type AppRole = 'admin' | 'gestor' | 'comercial' | 'leitura'

export type LeadStage =
  | 'novo' | 'validado' | 'pronto_contato' | 'primeiro_contato' | 'aguardando_resposta'
  | 'interessado' | 'proposta_enviada' | 'em_negociacao' | 'convertido' | 'perdido'

export const STAGES: { value: LeadStage; label: string }[] = [
  { value: 'novo', label: 'Novo lead' },
  { value: 'validado', label: 'Validado' },
  { value: 'pronto_contato', label: 'Pronto para contato' },
  { value: 'primeiro_contato', label: 'Primeiro contato realizado' },
  { value: 'aguardando_resposta', label: 'Aguardando resposta' },
  { value: 'interessado', label: 'Interessado' },
  { value: 'proposta_enviada', label: 'Proposta enviada' },
  { value: 'em_negociacao', label: 'Em negociação' },
  { value: 'convertido', label: 'Convertido' },
  { value: 'perdido', label: 'Perdido' },
]
export const STAGE_LABEL = Object.fromEntries(STAGES.map((s) => [s.value, s.label])) as Record<LeadStage, string>

export const ROLE_LABEL: Record<AppRole, string> = {
  admin: 'Administrador',
  gestor: 'Gestor',
  comercial: 'Comercial',
  leitura: 'Somente leitura',
}

export interface Profile {
  id: string
  full_name: string | null
  email: string
  role: AppRole
  active: boolean
  created_at: string
}

export interface LeadRow {
  id: string
  cnpj: string
  cnpj_basico: string
  stage: LeadStage
  score: number
  priority: 'alta' | 'media' | 'baixa'
  owner_name: string | null
  razao_social: string | null
  nome_fantasia: string | null
  porte: string | null
  capital_social: number | null
  data_inicio_atividade: string | null
  cnae_principal: string | null
  cnae_descricao: string | null
  uf: string | null
  municipio: string | null
  ddd1: string | null
  telefone1: string | null
  email: string | null
  has_phone: boolean
  has_email: boolean
  opcao_simples: boolean | null
  opcao_mei: boolean | null
}

export interface ImportJob {
  id: string
  job_type: 'verificacao' | 'importacao'
  competence: string | null
  reference_date: string | null
  status: 'pendente' | 'baixando' | 'processando' | 'validando' | 'concluido' | 'falhou' | 'cancelado'
  trigger_type: string
  started_at: string | null
  finished_at: string | null
  files_found: number
  files_processed: number
  records_read: number
  new_leads: number
  updated_records: number
  error_count: number
  errors: { em?: string; msg: string }[]
  log: { em: string; nivel: string; msg: string }[]
  metadata: Record<string, unknown>
  is_current: boolean
  created_at: string
}

export interface IntegrationStatus {
  key: string
  label: string
  status: 'nao_configurado' | 'configurado' | 'ativo' | 'erro'
  last_seen_at: string | null
  details: { descricao?: string; [k: string]: unknown }
}

export interface ChartItem { label: string | null; total: number }

export interface DashboardMetrics {
  total: number
  ativas: number
  ultimos_7: number
  ultimos_15: number
  ultimos_30: number
  ultimos_90: number
  com_telefone: number
  com_email: number
  leads_alta: number
  leads_contatados: number
  leads_convertidos: number
  por_uf: ChartItem[]
  por_municipio: ChartItem[]
  por_cnae: ChartItem[]
  por_porte: ChartItem[]
  por_mes_abertura: ChartItem[]
  competencia_vigente: { competence: string; reference_date: string | null; finished_at: string } | null
  data_referencia: string | null
  ultimo_job: { job_type: string; status: string; created_at: string; finished_at: string | null; competence: string | null } | null
}
