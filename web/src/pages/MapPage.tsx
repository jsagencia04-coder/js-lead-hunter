import { useEffect, useMemo, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { ArrowLeft, Loader2 } from 'lucide-react'
import brazil from '@svg-maps/brazil'
import { supabase } from '@/lib/supabase'
import { useCachedQuery } from '@/lib/cache'
import { DataStatus } from '@/components/DataStatus'
import type { DashboardMetrics, LeadRow } from '@/lib/types'
import { STAGE_LABEL } from '@/lib/types'
import { cn, formatCnpj, formatDate, nf } from '@/lib/utils'
import { PageHeader } from '@/components/layout/AppLayout'
import { LeadDrawer } from '@/components/LeadDrawer'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Select } from '@/components/ui/select'
import { Label } from '@/components/ui/label'
import { Badge } from '@/components/ui/badge'
import { Alert } from '@/components/ui/alert'
import { Table, TBody, TD, TH, THead, TR } from '@/components/ui/table'

interface StateCount { uf: string; empresas: number; leads: number; leads_alta: number }
interface Location { id: string; name: string; path: string }
const MAP = brazil as unknown as { viewBox: string; locations: Location[] }

const STATE_NAME: Record<string, string> = Object.fromEntries(MAP.locations.map((l) => [l.id.toUpperCase(), l.name]))
// 5 faixas de intensidade (escala sequencial de uma cor)
const SHADES = ['#dbe4f8', '#a9bdf0', '#6f92e4', '#3a68d1', '#1f45a6']

export default function MapPage() {
  // filtros e estado selecionado ficam na URL: atualizar a página mantém a tela
  const [params, setParams] = useSearchParams()
  const days = Number(params.get('dias') ?? 90)
  const metric = (params.get('indicador') === 'leads' ? 'leads' : 'empresas') as 'empresas' | 'leads'
  const selected = params.get('uf')
  const setParam = (k: string, v: string | null) => setParams((p) => { const n = new URLSearchParams(p); if (v === null) n.delete(k); else n.set(k, v); return n }, { replace: true })
  const setDays = (d: number) => setParam('dias', String(d))
  const setMetric = (m: 'empresas' | 'leads') => setParam('indicador', m)
  const setSelected = (uf: string | null) => setParam('uf', uf)
  const q = useCachedQuery<StateCount[]>(`map:${days}`, async () => {
    const r = await supabase.rpc('map_state_counts', { p_days: days })
    return { data: (r.data as StateCount[]) ?? null, error: r.error?.message ?? null }
  }, [days])
  const counts = useMemo(() => q.data ?? [], [q.data])
  const [hover, setHover] = useState<string | null>(null)
  const loading = q.loading

  const byUf = useMemo(() => Object.fromEntries(counts.map((c) => [c.uf, c])), [counts])
  const max = Math.max(1, ...counts.map((c) => c[metric]))
  const shade = (v: number) => (v <= 0 ? '#eef1f6' : SHADES[Math.min(4, Math.floor((v / max) * 5 - 1e-9))])
  const total = counts.reduce((a, c) => a + c[metric], 0)
  const hovered = hover ? byUf[hover] : null

  if (selected) return <StateView uf={selected} onBack={() => setSelected(null)} />

  return (
    <>
      <PageHeader
        title="Mapa do Brasil"
        description="Clique em um estado para ver indicadores, municípios e leads."
        actions={
          <>
            <Select value={metric} onChange={(e) => setMetric(e.target.value as 'empresas' | 'leads')} className="w-44" aria-label="Indicador">
              <option value="empresas">Empresas abertas</option>
              <option value="leads">Leads no CRM</option>
            </Select>
            {metric === 'empresas' && (
              <Select value={days} onChange={(e) => setDays(Number(e.target.value))} className="w-40" aria-label="Período">
                {[7, 15, 30, 90].map((d) => <option key={d} value={d}>Últimos {d} dias</option>)}
              </Select>
            )}
          </>
        }
      />
      <DataStatus loading={q.loading} error={q.error} savedAt={q.savedAt} hasData={!!q.data} />
      <div className="grid gap-6 lg:grid-cols-[1fr_20rem]">
        <Card className="relative">
          <CardContent className="pt-5">
            {loading && <Loader2 className="absolute right-4 top-4 h-5 w-5 animate-spin text-primary" />}
            <svg viewBox={MAP.viewBox} className="mx-auto max-h-[70vh] w-full" role="img" aria-label="Mapa dos estados do Brasil">
              {MAP.locations.map((loc) => {
                const uf = loc.id.toUpperCase()
                const v = byUf[uf]?.[metric] ?? 0
                return (
                  <path key={loc.id} d={loc.path} fill={shade(v)}
                    className={cn('cursor-pointer stroke-white transition-opacity hover:opacity-80', hover === uf && 'stroke-[2]')}
                    strokeWidth={1}
                    onMouseEnter={() => setHover(uf)} onMouseLeave={() => setHover(null)}
                    onClick={() => setSelected(uf)}>
                    <title>{`${loc.name}: ${nf.format(v)}`}</title>
                  </path>
                )
              })}
            </svg>
            <div className="mt-3 flex items-center justify-center gap-1 text-xs text-muted-foreground">
              <span>0</span>
              {SHADES.map((c) => <span key={c} className="h-3 w-8 rounded-sm" style={{ background: c }} />)}
              <span>{nf.format(max)}</span>
            </div>
            <p className="mt-2 text-center text-[10px] text-muted-foreground">Mapa: SVG Maps (Victor Cazanave), licença CC BY 4.0</p>
          </CardContent>
        </Card>
        <div className="space-y-4">
          <Card>
            <CardHeader><CardTitle>{hovered ? STATE_NAME[hover!] : 'Brasil'}</CardTitle></CardHeader>
            <CardContent className="space-y-1 text-sm">
              <Row k={`Empresas abertas (${days} dias)`} v={hovered ? hovered.empresas : counts.reduce((a, c) => a + c.empresas, 0)} />
              <Row k="Leads no CRM" v={hovered ? hovered.leads : counts.reduce((a, c) => a + c.leads, 0)} />
              <Row k="Leads alta prioridade" v={hovered ? hovered.leads_alta : counts.reduce((a, c) => a + c.leads_alta, 0)} />
            </CardContent>
          </Card>
          <Card>
            <CardHeader><CardTitle>Ranking por estado</CardTitle></CardHeader>
            <CardContent className="max-h-[45vh] space-y-1 overflow-y-auto text-sm">
              {[...counts].sort((a, b) => b[metric] - a[metric]).map((c) => (
                <button key={c.uf} onClick={() => setSelected(c.uf)}
                  className="flex w-full justify-between rounded px-2 py-1 hover:bg-accent">
                  <span>{c.uf} · {STATE_NAME[c.uf] ?? ''}</span>
                  <span className="tabular-nums text-muted-foreground">{nf.format(c[metric])}</span>
                </button>
              ))}
              {!loading && total === 0 && <p className="text-muted-foreground">Sem dados importados ainda.</p>}
            </CardContent>
          </Card>
        </div>
      </div>
    </>
  )
}

function Row({ k, v }: { k: string; v: number }) {
  return <div className="flex justify-between"><span className="text-muted-foreground">{k}</span><span className="tabular-nums font-medium">{nf.format(v)}</span></div>
}

function StateView({ uf, onBack }: { uf: string; onBack: () => void }) {
  const [municipios, setMunicipios] = useState<{ code: string; name: string }[]>([])
  const [params, setParams] = useSearchParams()
  const mun = params.get('municipio') ?? ''
  const setMun = (v: string) => setParams((p) => { const n = new URLSearchParams(p); if (v) n.set('municipio', v); else n.delete('municipio'); return n }, { replace: true })
  const [openId, setOpenId] = useState<string | null>(null)
  const [munError, setMunError] = useState<string | null>(null)

  useEffect(() => {
    supabase.from('municipalities').select('code,name').eq('uf', uf).order('name')
      .then(({ data, error }) => { if (error) setMunError(error.message); setMunicipios(data ?? []) })
  }, [uf])

  const qm = useCachedQuery<DashboardMetrics>(`map:uf:${uf}:${mun}`, async () => {
    const r = await supabase.rpc('dashboard_metrics', { p_uf: uf, p_municipio: mun || null })
    return { data: (r.data as DashboardMetrics) ?? null, error: r.error?.message ?? null }
  }, [uf, mun])
  const ql = useCachedQuery<LeadRow[]>(`map:leads:${uf}:${mun}`, async () => {
    let q = supabase.from('lead_list_v')
      .select('id,cnpj,cnpj_basico,stage,score,priority,razao_social,nome_fantasia,municipio,data_inicio_atividade,has_phone,has_email')
      .eq('uf', uf)
    if (mun) q = q.eq('municipio_code', mun)
    const r = await q.order('score', { ascending: false }).limit(50)
    return { data: (r.data as unknown as LeadRow[]) ?? null, error: r.error?.message ?? null }
  }, [uf, mun])
  const metrics = qm.data
  const leads = ql.data ?? []
  const failed = qm.error ? qm : ql.error ? ql : null
  const error = munError

  return (
    <>
      <PageHeader
        title={`${STATE_NAME[uf] ?? uf} (${uf})`}
        description="Indicadores e leads do estado selecionado."
        actions={<Button variant="outline" onClick={onBack}><ArrowLeft className="h-4 w-4" /> Voltar à visão nacional</Button>}
      />
      {error && <Alert tone="error" className="mb-4">{error}</Alert>}
      <DataStatus loading={qm.loading || ql.loading} error={failed?.error ?? null} savedAt={failed?.savedAt ?? qm.savedAt} hasData={!!(qm.data || ql.data)} />
      <div className="mb-6 max-w-sm space-y-1">
        <Label>Município</Label>
        <Select value={mun} onChange={(e) => setMun(e.target.value)}>
          <option value="">Todos os municípios ({municipios.length})</option>
          {municipios.map((m) => <option key={m.code} value={m.code}>{m.name}</option>)}
        </Select>
      </div>
      <div className="mb-6 grid grid-cols-2 gap-4 md:grid-cols-4 xl:grid-cols-6">
        {([
          ['Empresas ativas', metrics?.ativas], ['Abertas · 7 dias', metrics?.ultimos_7], ['Abertas · 30 dias', metrics?.ultimos_30],
          ['Abertas · 90 dias', metrics?.ultimos_90], ['Com telefone', metrics?.com_telefone], ['Leads alta prioridade', metrics?.leads_alta],
        ] as [string, number | undefined][]).map(([k, v]) => (
          <Card key={k}><CardContent className="pt-5">
            <p className="text-xs text-muted-foreground">{k}</p>
            <p className="mt-1 text-2xl font-semibold tabular-nums">{v === undefined ? '—' : nf.format(v)}</p>
          </CardContent></Card>
        ))}
      </div>
      <Card>
        <CardHeader><CardTitle>Leads com maior pontuação</CardTitle></CardHeader>
        <Table>
          <THead><tr><TH>Empresa</TH><TH>Município</TH><TH>Abertura</TH><TH>Contato</TH><TH>Pontuação</TH><TH>Etapa</TH></tr></THead>
          <TBody>
            {leads.length === 0 && <tr><TD colSpan={6} className="py-8 text-center text-muted-foreground">Nenhum lead neste recorte.</TD></tr>}
            {leads.map((l) => (
              <TR key={l.id} className="cursor-pointer" onClick={() => setOpenId(l.id)}>
                <TD><p className="font-medium">{l.nome_fantasia || l.razao_social}</p><p className="text-xs text-muted-foreground">{formatCnpj(l.cnpj)}</p></TD>
                <TD>{l.municipio}</TD>
                <TD>{formatDate(l.data_inicio_atividade)}</TD>
                <TD className="text-xs">{[l.has_phone && 'telefone', l.has_email && 'e-mail'].filter(Boolean).join(' · ') || '—'}</TD>
                <TD><Badge variant={l.priority === 'alta' ? 'success' : l.priority === 'media' ? 'warning' : 'outline'}>{l.score}</Badge></TD>
                <TD className="text-xs">{STAGE_LABEL[l.stage]}</TD>
              </TR>
            ))}
          </TBody>
        </Table>
      </Card>
      <LeadDrawer leadId={openId} onClose={() => setOpenId(null)} />
    </>
  )
}
