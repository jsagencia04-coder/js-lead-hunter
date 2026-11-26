import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { Loader2, RefreshCw } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import type { ChartItem, CommercialMetrics, DashboardMetrics, PerformanceRow } from '@/lib/types'
import { brl, formatDate, formatDateTime, nf, UFS } from '@/lib/utils'
import { PageHeader } from '@/components/layout/AppLayout'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Alert } from '@/components/ui/alert'
import { Button } from '@/components/ui/button'
import { Select } from '@/components/ui/select'
import { useAuth } from '@/hooks/useAuth'

const JOB_STATUS: Record<string, string> = {
  pendente: 'Aguardando o worker', baixando: 'Baixando arquivos', processando: 'Processando',
  validando: 'Validando', concluido: 'Concluída', falhou: 'Falhou', cancelado: 'Cancelada',
}

export default function Dashboard() {
  const { hasRole } = useAuth()
  const [uf, setUf] = useState('')
  const [data, setData] = useState<DashboardMetrics | null>(null)
  const [com, setCom] = useState<CommercialMetrics | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  async function load() {
    setLoading(true)
    setError(null)
    const [d, c] = await Promise.all([
      supabase.rpc('dashboard_metrics', { p_uf: uf || null }),
      supabase.rpc('commercial_metrics', { p_uf: uf || null }),
    ])
    if (d.error || c.error) setError((d.error ?? c.error)!.message)
    setData((d.data as DashboardMetrics) ?? null)
    setCom((c.data as CommercialMetrics) ?? null)
    setLoading(false)
  }

  useEffect(() => { load() }, [uf]) // eslint-disable-line react-hooks/exhaustive-deps

  const cur = data?.competencia_vigente
  const semDados = data && data.total === 0

  return (
    <>
      <PageHeader
        title="Dashboard"
        description="Empresas matrizes da base pública do CNPJ e andamento comercial."
        actions={
          <>
            <Select value={uf} onChange={(e) => setUf(e.target.value)} className="w-36" aria-label="Filtrar por UF">
              <option value="">Brasil</option>
              {UFS.map((u) => <option key={u} value={u}>{u}</option>)}
            </Select>
            <Button variant="outline" onClick={load} disabled={loading}>
              {loading ? <Loader2 className="h-4 w-4 animate-spin" /> : <RefreshCw className="h-4 w-4" />}
              Atualizar
            </Button>
          </>
        }
      />

      {error && <Alert tone="error" title="Não foi possível carregar os indicadores" className="mb-6">{error}</Alert>}

      <Card className="mb-6">
        <CardContent className="flex flex-col gap-2 pt-5 text-sm md:flex-row md:items-center md:gap-8">
          <div>
            <span className="text-muted-foreground">Competência vigente: </span>
            <strong>{cur ? cur.competence : 'nenhuma importação concluída'}</strong>
          </div>
          {cur && (
            <div>
              <span className="text-muted-foreground">Data de referência: </span>
              <strong>{formatDate(cur.reference_date)}</strong>
            </div>
          )}
          <div>
            <span className="text-muted-foreground">Última coleta: </span>
            <strong>
              {data?.ultimo_job
                ? `${JOB_STATUS[data.ultimo_job.status] ?? data.ultimo_job.status} · ${formatDateTime(data.ultimo_job.created_at)}`
                : 'nunca executada'}
            </strong>
          </div>
        </CardContent>
      </Card>

      {semDados && (
        <Alert tone="info" title="Ainda não há dados importados" className="mb-6">
          A base pública do CNPJ é atualizada por competência (não em tempo real). Os indicadores serão
          preenchidos quando o worker concluir a primeira importação oficial.{' '}
          {hasRole('admin', 'gestor') && <Link to="/importacao" className="font-medium underline">Ver central de importação</Link>}
        </Alert>
      )}

      <h2 className="mb-3 text-sm font-semibold text-muted-foreground">Prospecção comercial</h2>
      <div className="grid grid-cols-2 gap-4 md:grid-cols-3 xl:grid-cols-6">
        <Kpi label="Leads novos na competência" value={com?.leads_novos_competencia} />
        <Kpi label="Leads alta prioridade" value={com?.leads_alta} accent />
        <Kpi label="Leads qualificados" value={com?.leads_qualificados} />
        <Kpi label="Leads contatados" value={com?.leads_contatados} />
        <Kpi label="Respostas recebidas" value={com?.respostas_recebidas} />
        <Kpi label="Propostas enviadas" value={com?.propostas_enviadas} />
        <Kpi label="Clientes convertidos" value={com?.clientes_convertidos} accent />
        <Kpi label="Taxa de conversão" value={com?.taxa_conversao} suffix="%" />
        <Kpi label="Valor em propostas" value={com?.propostas_valor} money />
        <Kpi label="Propostas aceitas" value={com?.propostas_aceitas} />
        <Kpi label="Follow-ups atrasados" value={com?.follow_ups_atrasados} />
        <Kpi label="Leads na base" value={com?.leads_total} />
      </div>
      <p className="mt-2 text-xs text-muted-foreground">
        Qualificado: lead que saiu de “Novo lead” e não foi perdido. Contatado: tem contato registrado ou etapa a partir de “Primeiro contato”.
        Taxa de conversão: convertidos ÷ contatados.
      </p>

      <div className="mt-4 grid gap-4 lg:grid-cols-2">
        <PerfTable title="Desempenho por serviço (principal recomendação)" rows={com?.por_servico} />
        <PerfTable title="Desempenho por responsável" rows={com?.por_responsavel} />
      </div>

      <h2 className="mb-3 mt-8 text-sm font-semibold text-muted-foreground">Base de empresas (Receita Federal)</h2>
      <div className="grid grid-cols-2 gap-4 md:grid-cols-3 xl:grid-cols-4">
        <Kpi label="Empresas encontradas" value={data?.total} />
        <Kpi label="Empresas ativas" value={data?.ativas} />
        <Kpi label="Abertas · 7 dias" value={data?.ultimos_7} />
        <Kpi label="Abertas · 15 dias" value={data?.ultimos_15} />
        <Kpi label="Abertas · 30 dias" value={data?.ultimos_30} />
        <Kpi label="Abertas · 90 dias" value={data?.ultimos_90} />
        <Kpi label="Com telefone" value={data?.com_telefone} />
        <Kpi label="Com e-mail" value={data?.com_email} />
      </div>
      <p className="mt-2 text-xs text-muted-foreground">
        Períodos contados a partir da data de referência da base ({formatDate(data?.data_referencia)}), pela data de início de atividade.
        A base pública da Receita é publicada por competência, com defasagem. Situação cadastral ativa não comprova regularidade fiscal.
      </p>

      <div className="mt-6 grid gap-4 lg:grid-cols-2">
        <BarList title="Distribuição geográfica: empresas ativas por estado" items={data?.por_uf} />
        <BarList title="Top 10 municípios" items={data?.por_municipio} />
        <BarList title="Top 10 CNAEs principais" items={data?.por_cnae} />
        <BarList title="Por porte" items={data?.por_porte} />
        <BarList title="Abertura por mês (últimos 12 meses)" items={data?.por_mes_abertura} keepOrder />
      </div>
    </>
  )
}

function PerfTable({ title, rows }: { title: string; rows: PerformanceRow[] | undefined }) {
  const list = (rows ?? []).slice(0, 12)
  return (
    <Card>
      <CardHeader>
        <CardTitle>{title}</CardTitle>
        {list.length === 0 && <CardDescription>Sem movimentação comercial registrada.</CardDescription>}
      </CardHeader>
      {list.length > 0 && (
        <CardContent>
          <table className="w-full text-xs">
            <thead className="text-muted-foreground">
              <tr><th className="text-left font-normal">Nome</th><th className="text-right font-normal">Leads</th>
                <th className="text-right font-normal">Contatados</th><th className="text-right font-normal">Propostas</th>
                <th className="text-right font-normal">Convertidos</th><th className="text-right font-normal">Conversão</th></tr>
            </thead>
            <tbody>
              {list.map((r) => (
                <tr key={r.label} className="border-t">
                  <td className="py-1.5 pr-2">{r.label}</td>
                  <td className="text-right tabular-nums">{nf.format(r.leads)}</td>
                  <td className="text-right tabular-nums">{nf.format(r.contatados)}</td>
                  <td className="text-right tabular-nums">{nf.format(r.propostas)}</td>
                  <td className="text-right tabular-nums">{nf.format(r.convertidos)}</td>
                  <td className="text-right tabular-nums">{r.contatados ? `${Math.round((100 * r.convertidos) / r.contatados)}%` : '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </CardContent>
      )}
    </Card>
  )
}

function Kpi({ label, value, accent, suffix, money }: { label: string; value: number | undefined; accent?: boolean; suffix?: string; money?: boolean }) {
  return (
    <Card>
      <CardContent className="pt-5">
        <p className="text-xs text-muted-foreground">{label}</p>
        <p className={`mt-1 text-2xl font-semibold tabular-nums ${accent ? 'text-primary' : ''}`}>
          {value === undefined || value === null ? '—' : money ? brl.format(value) : nf.format(value) + (suffix ?? '')}
        </p>
      </CardContent>
    </Card>
  )
}

function BarList({ title, items, keepOrder }: { title: string; items: ChartItem[] | undefined; keepOrder?: boolean }) {
  const list = (items ?? []).slice(0, keepOrder ? 12 : 27)
  const max = Math.max(1, ...list.map((i) => i.total))
  return (
    <Card>
      <CardHeader>
        <CardTitle>{title}</CardTitle>
        {list.length === 0 && <CardDescription>Sem dados na competência atual.</CardDescription>}
      </CardHeader>
      {list.length > 0 && (
        <CardContent className="space-y-1.5">
          {list.map((i) => (
            <div key={i.label ?? 'nd'} className="grid grid-cols-[minmax(0,10rem)_1fr_auto] items-center gap-3 text-xs">
              <span className="truncate" title={i.label ?? ''}>{i.label ?? 'Não informado'}</span>
              <div className="h-2.5 rounded-full bg-muted">
                <div className="h-2.5 rounded-full bg-primary" style={{ width: `${(i.total / max) * 100}%` }} />
              </div>
              <span className="w-14 text-right tabular-nums text-muted-foreground">{nf.format(i.total)}</span>
            </div>
          ))}
        </CardContent>
      )}
    </Card>
  )
}
