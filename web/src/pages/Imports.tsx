import { Fragment, useCallback, useEffect, useState } from 'react'
import { Loader2, PlayCircle, RefreshCw, SearchCheck, XCircle } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import type { ImportJob, IntegrationStatus } from '@/lib/types'
import { formatDate, formatDateTime, nf } from '@/lib/utils'
import { useAuth } from '@/hooks/useAuth'
import { PageHeader } from '@/components/layout/AppLayout'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Alert } from '@/components/ui/alert'
import { Table, TBody, TD, TH, THead, TR } from '@/components/ui/table'

const STATUS: Record<ImportJob['status'], { label: string; variant: 'default' | 'success' | 'warning' | 'danger' | 'outline' }> = {
  pendente: { label: 'Aguardando worker', variant: 'warning' },
  baixando: { label: 'Baixando', variant: 'default' },
  processando: { label: 'Processando', variant: 'default' },
  validando: { label: 'Validando', variant: 'default' },
  concluido: { label: 'Concluída', variant: 'success' },
  falhou: { label: 'Falhou', variant: 'danger' },
  cancelado: { label: 'Cancelada', variant: 'outline' },
}

const INTEGRATION: Record<IntegrationStatus['status'], { label: string; variant: 'success' | 'warning' | 'danger' | 'outline' }> = {
  nao_configurado: { label: 'Não configurado', variant: 'outline' },
  configurado: { label: 'Configurado', variant: 'warning' },
  ativo: { label: 'Ativo', variant: 'success' },
  erro: { label: 'Erro', variant: 'danger' },
}

// Worker contínuo: sinal a cada poucos segundos (tolerância 10 min).
// Worker agendado (GitHub Actions): sinal a cada execução (tolerância 1,5x o intervalo).
// O agendador gratuito do GitHub atrasa execuções por horas; tolera até 26 h.
function heartbeatToleranceMs(details: IntegrationStatus['details'] | undefined) {
  if (details?.modo === 'agendado') return 26 * 60 * 60 * 1000
  const interval = Number(details?.intervalo_min ?? 0)
  return Math.max(10, interval * 1.5) * 60 * 1000
}

function duration(job: ImportJob) {
  if (!job.started_at) return '—'
  const end = job.finished_at ? new Date(job.finished_at).getTime() : Date.now()
  const s = Math.round((end - new Date(job.started_at).getTime()) / 1000)
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60)
  return h ? `${h}h ${m}min` : m ? `${m}min ${s % 60}s` : `${s}s`
}

export default function Imports() {
  const { hasRole } = useAuth()
  const isAdmin = hasRole('admin')
  const [jobs, setJobs] = useState<ImportJob[]>([])
  const [integrations, setIntegrations] = useState<IntegrationStatus[]>([])
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [expanded, setExpanded] = useState<string | null>(null)
  const [snapshots, setSnapshots] = useState<{ id: number; taken_at: string; label: string; counts: Record<string, unknown> }[]>([])

  const load = useCallback(async () => {
    setLoading(true)
    const [j, i, s] = await Promise.all([
      supabase.from('import_jobs').select('*').order('created_at', { ascending: false }).limit(30),
      supabase.from('integration_status').select('*').order('key'),
      supabase.from('data_inventory_snapshots').select('*').order('id', { ascending: false }).limit(2),
    ])
    setSnapshots((s.data as typeof snapshots) ?? [])
    if (j.error || i.error) setError((j.error ?? i.error)!.message)
    setJobs((j.data as ImportJob[]) ?? [])
    setIntegrations((i.data as IntegrationStatus[]) ?? [])
    setLoading(false)
  }, [])

  useEffect(() => { load() }, [load])

  const worker = integrations.find((i) => i.key === 'worker')
  const workerOnline =
    worker?.status === 'ativo' && !!worker.last_seen_at &&
    Date.now() - new Date(worker.last_seen_at).getTime() < heartbeatToleranceMs(worker.details)
  const current = jobs.find((j) => j.is_current)
  const pending = jobs.find((j) => ['pendente', 'baixando', 'processando', 'validando'].includes(j.status))

  async function request(type: 'verificacao' | 'importacao') {
    setBusy(true)
    setError(null)
    setNotice(null)
    const { error } = await supabase.rpc('request_import', { p_job_type: type })
    if (error) setError(error.message)
    else setNotice(
      workerOnline
        ? (worker?.details?.modo === 'agendado'
            ? 'Solicitação registrada. O worker roda de forma agendada no GitHub (normalmente a cada poucas horas) e vai processá-la na próxima execução.'
            : 'Solicitação registrada. O worker irá processá-la no próximo ciclo.')
        : 'Solicitação registrada, mas o worker não está conectado. Ela ficará aguardando até o worker ser ativado.',
    )
    setBusy(false)
    load()
  }

  async function cancel(id: string) {
    const { error } = await supabase.rpc('cancel_import', { p_job_id: id })
    if (error) setError(error.message)
    load()
  }

  return (
    <>
      <PageHeader
        title="Central de importação"
        description="Coleta dos dados públicos do CNPJ da Receita Federal, por competência."
        actions={
          <>
            <Button variant="outline" onClick={load} disabled={loading}>
              <RefreshCw className="h-4 w-4" /> Atualizar
            </Button>
            {isAdmin && (
              <>
                <Button variant="outline" onClick={() => request('verificacao')} disabled={busy || !!pending}>
                  {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <SearchCheck className="h-4 w-4" />}
                  Verificar nova competência
                </Button>
                <Button onClick={() => request('importacao')} disabled={busy || !!pending}>
                  <PlayCircle className="h-4 w-4" /> Iniciar importação
                </Button>
              </>
            )}
          </>
        }
      />

      {!loading && !workerOnline && (
        <Alert tone="warning" title="Worker de importação não conectado" className="mb-6">
          O worker Python (DuckDB + Polars) não enviou sinal dentro do intervalo esperado. Enquanto ele não estiver
          rodando, as solicitações ficam como “Aguardando worker” e nenhum dado é importado.
          Veja a seção “Worker” do README para colocá-lo no ar.
        </Alert>
      )}
      {(() => {
        const a = worker?.details?.alerta_espaco as { em: string; usado_mb: number; necessario_mb: number; limite_mb: number; mensagem: string } | undefined
        return a ? (
          <Alert tone="error" title="Importação interrompida por falta de espaço no banco" className="mb-6">
            {a.mensagem} Uso atual: {a.usado_mb} MB; a carga precisaria de cerca de {a.necessario_mb} MB (limite configurado: {a.limite_mb} MB).
            Para continuar, amplie o plano do banco e ajuste DB_SIZE_LIMIT_MB, ou reduza LEAD_WINDOW_DAYS. Aviso de {formatDateTime(a.em)}.
          </Alert>
        ) : null
      })()}
      {error && <Alert tone="error" className="mb-4">{error}</Alert>}
      {notice && <Alert tone="info" className="mb-4">{notice}</Alert>}

      <div className="mb-6 grid gap-4 md:grid-cols-3">
        <Card>
          <CardHeader><CardDescription>Competência vigente</CardDescription>
            <CardTitle className="text-xl">{current?.competence ?? 'Nenhuma'}</CardTitle></CardHeader>
          <CardContent className="text-xs text-muted-foreground">
            {current ? `Referência ${formatDate(current.reference_date)} · concluída em ${formatDateTime(current.finished_at)}`
              : 'Nenhuma importação válida concluída até agora.'}
          </CardContent>
        </Card>
        <Card className="md:col-span-2">
          <CardHeader><CardTitle>Integrações</CardTitle></CardHeader>
          <CardContent className="space-y-2">
            {integrations.map((i) => (
              <div key={i.key} className="flex items-center justify-between gap-3 text-sm">
                <div>
                  <p>{i.label}</p>
                  <p className="text-xs text-muted-foreground">
                    {i.details?.descricao}{i.last_seen_at ? ` · último sinal ${formatDateTime(i.last_seen_at)}` : ''}
                  </p>
                </div>
                <Badge variant={INTEGRATION[i.status].variant}>{INTEGRATION[i.status].label}</Badge>
              </div>
            ))}
          </CardContent>
        </Card>
      </div>

      {snapshots.length > 0 && <InventoryCard snapshots={snapshots} />}

      <Card>
        <CardHeader><CardTitle>Histórico de execuções</CardTitle></CardHeader>
        <Table>
          <THead>
            <tr>
              <TH>Solicitada em</TH><TH>Tipo</TH><TH>Competência</TH><TH>Status</TH><TH>Arquivos</TH>
              <TH>Registros lidos</TH><TH>Novos leads</TH><TH>Atualizações</TH><TH>Erros</TH><TH>Duração</TH><TH />
            </tr>
          </THead>
          <TBody>
            {!loading && jobs.length === 0 && (
              <tr><TD colSpan={11} className="py-10 text-center text-muted-foreground">Nenhuma execução registrada.</TD></tr>
            )}
            {jobs.map((j) => (
              <Fragment key={j.id}>
              <TR>
                <TD className="whitespace-nowrap">{formatDateTime(j.created_at)}</TD>
                <TD>{j.job_type === 'verificacao' ? 'Verificação' : 'Importação'}</TD>
                <TD>{j.competence ?? '—'} {j.is_current && <Badge variant="success" className="ml-1">vigente</Badge>}</TD>
                <TD><Badge variant={STATUS[j.status].variant}>{STATUS[j.status].label}</Badge></TD>
                <TD className="tabular-nums">{j.files_processed}/{j.files_found}</TD>
                <TD className="tabular-nums">{nf.format(j.records_read)}</TD>
                <TD className="tabular-nums">{nf.format(j.new_leads)}</TD>
                <TD className="tabular-nums">{nf.format(j.updated_records)}</TD>
                <TD className="tabular-nums">{j.error_count}</TD>
                <TD className="whitespace-nowrap">{duration(j)}</TD>
                <TD className="whitespace-nowrap">
                  <Button variant="ghost" size="sm" onClick={() => setExpanded(expanded === j.id ? null : j.id)}>
                    {expanded === j.id ? 'Ocultar log' : 'Ver log'}
                  </Button>
                  {isAdmin && j.status === 'pendente' && (
                    <Button variant="ghost" size="sm" onClick={() => cancel(j.id)}>
                      <XCircle className="h-4 w-4" /> Cancelar
                    </Button>
                  )}
                </TD>
              </TR>
              {expanded === j.id && (
                <tr>
                  <TD colSpan={11} className="bg-muted/30">
                    {j.errors?.length > 0 && (
                      <Alert tone="error" title="Erros" className="mb-3">
                        {j.errors.map((e, i) => <p key={i}>{e.msg}</p>)}
                      </Alert>
                    )}
                    <div className="max-h-80 overflow-y-auto font-mono text-xs">
                      {(j.log ?? []).length === 0 && <p className="text-muted-foreground">Sem registros de log.</p>}
                      {[...(j.log ?? [])].sort((a, b) => a.em.localeCompare(b.em)).map((l, i) => (
                        <p key={i} className={l.nivel === 'erro' ? 'text-red-700' : ''}>
                          <span className="text-muted-foreground">{formatDateTime(l.em)}</span> {l.msg}
                        </p>
                      ))}
                    </div>
                  </TD>
                </tr>
              )}
              </Fragment>
            ))}
          </TBody>
        </Table>
      </Card>
    </>
  )
}

const INVENTORY_LABEL: Record<string, string> = {
  empresas: 'Empresas', estabelecimentos: 'Estabelecimentos', leads: 'Leads', leads_ativos: 'Leads ativos',
  leads_arquivados: 'Leads arquivados', arquivados_restauracao_pendente: 'Restauração pendente',
  arquivados_restaurados: 'Arquivados restaurados', eventos: 'Eventos no histórico', eventos_comerciais: 'Ações comerciais',
  contatos: 'Contatos', respostas: 'Respostas', propostas: 'Propostas', bloqueios: 'Bloqueios de contato',
  usuarios: 'Usuários', alteracoes_cadastrais: 'Alterações cadastrais', banco_mb: 'Tamanho do banco (MB)',
}

function InventoryCard({ snapshots }: { snapshots: { id: number; taken_at: string; label: string; counts: Record<string, unknown> }[] }) {
  const [last, prev] = snapshots
  return (
    <Card className="mb-6">
      <CardHeader>
        <CardTitle>Inventário dos dados</CardTitle>
        <CardDescription>
          Quantidades registradas pelo worker no início e no fim de cada rodada, para comprovar que nada foi perdido.
          Último retrato: {last.label} · {formatDateTime(last.taken_at)}{prev ? ` (comparado com: ${prev.label} · ${formatDateTime(prev.taken_at)})` : ''}.
        </CardDescription>
      </CardHeader>
      <CardContent className="grid gap-x-8 gap-y-1 text-sm sm:grid-cols-2 lg:grid-cols-3">
        {Object.entries(INVENTORY_LABEL).map(([k, label]) => {
          const v = Number(last.counts[k] ?? 0)
          const p = prev ? Number(prev.counts[k] ?? 0) : null
          const diff = p === null ? 0 : v - p
          const drop = diff < 0 && k !== 'arquivados_restauracao_pendente' && k !== 'banco_mb'
          return (
            <div key={k} className="flex justify-between border-b py-1">
              <span className="text-muted-foreground">{label}</span>
              <span className={`tabular-nums ${drop ? 'font-semibold text-red-700' : ''}`}>
                {nf.format(v)}{diff !== 0 && <span className="ml-1 text-xs">({diff > 0 ? '+' : ''}{nf.format(diff)})</span>}
              </span>
            </div>
          )
        })}
      </CardContent>
    </Card>
  )
}
