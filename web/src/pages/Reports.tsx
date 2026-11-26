import { useCallback, useEffect, useState, type FormEvent } from 'react'
import { Download, Loader2, Plus, RefreshCw } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { friendlyError, readCache, writeCache } from '@/lib/cache'
import { brl, nf, UFS } from '@/lib/utils'
import { downloadCsv } from '@/lib/crm'
import { useAuth } from '@/hooks/useAuth'
import { PageHeader } from '@/components/layout/AppLayout'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Select } from '@/components/ui/select'
import { Alert } from '@/components/ui/alert'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'

type Rec = Record<string, string | number | null>
export interface Executive {
  periodo: { de: string; ate: string }
  cadastrais: Record<string, number | Rec[]>
  comerciais: Record<string, number | null>
  denominadores: Record<string, string>
  por_responsavel: Rec[]; por_servico: Rec[]; por_segmento: Rec[]; por_regiao: Rec[]
}
const METRIC: Record<string, string> = {
  receita_contratada: 'Receita contratada (R$)', contratos: 'Contratos', contatos: 'Contatos', reunioes: 'Reuniões realizadas',
  propostas: 'Propostas enviadas', oportunidades: 'Oportunidades criadas',
}
const COLS: Record<string, string> = {
  label: 'Nome', oportunidades: 'Oportunidades', ganhas: 'Ganhas', perdidas: 'Perdidas', receita: 'Receita', leads: 'Leads', alta: 'Alta prioridade',
}

export function PerfTable({ title, rows, money = ['receita'] }: { title: string; rows: Rec[]; money?: string[] }) {
  const keys = rows[0] ? ['label', ...Object.keys(rows[0]).filter((k) => k !== 'label')] : []
  return (
    <Card>
      <CardHeader className="flex-row items-center justify-between">
        <CardTitle>{title}</CardTitle>
        {rows.length > 0 && <Button size="sm" variant="ghost" onClick={() => downloadCsv(`${title}.csv`, [keys.map((k) => COLS[k] ?? k), ...rows.map((r) => keys.map((k) => r[k]))])}><Download className="h-4 w-4" /></Button>}
      </CardHeader>
      <CardContent>
        {rows.length === 0 ? <p className="text-sm text-muted-foreground">Sem dados ainda.</p> : (
          <table className="w-full text-xs">
            <thead className="text-muted-foreground"><tr>{keys.map((k) => <th key={k} className={`pb-1 font-normal ${k === 'label' ? 'text-left' : 'text-right'}`}>{COLS[k] ?? k}</th>)}</tr></thead>
            <tbody>
              {rows.map((r, i) => (
                <tr key={i} className="border-t">
                  {keys.map((k) => <td key={k} className={`py-1.5 ${k === 'label' ? 'pr-2' : 'text-right tabular-nums'}`}>
                    {k === 'label' ? (r[k] ?? '—') : money.includes(k) ? brl.format(Number(r[k] ?? 0)) : nf.format(Number(r[k] ?? 0))}</td>)}
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </CardContent>
    </Card>
  )
}

export default function Reports() {
  const { hasRole, profile } = useAuth()
  const canGoal = hasRole('admin', 'gestor')
  const [uf, setUf] = useState('')
  const [from, setFrom] = useState(() => new Date(new Date().getFullYear(), new Date().getMonth(), 1).toISOString().slice(0, 10))
  const [to, setTo] = useState(() => new Date().toISOString().slice(0, 10))
  const [data, setData] = useState<Executive | null>(() => readCache<Executive>('relatorios')?.data ?? null)
  const [goals, setGoals] = useState<{ goal_id: string; owner_name: string; metric: string; target: number; realizado: number }[]>([])
  const [owners, setOwners] = useState<{ id: string; full_name: string | null; email: string }[]>([])
  const [g, setG] = useState({ owner: '', metric: 'receita_contratada', target: '' })
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(async () => {
    setLoading(true)
    const [e, gp, o] = await Promise.all([
      supabase.rpc('executive_metrics', { p_uf: uf || null, p_from: from, p_to: to }),
      supabase.rpc('goals_progress', { p_month: from.slice(0, 8) + '01' }),
      supabase.from('profiles').select('id,full_name,email').eq('active', true).order('full_name'),
    ])
    if (e.error || gp.error) setError(friendlyError((e.error ?? gp.error)!.message))
    if (!e.error) { setData(e.data as Executive); writeCache('relatorios', e.data) }
    setGoals((gp.data as typeof goals) ?? [])
    setOwners(o.data ?? [])
    setLoading(false)
  }, [uf, from, to])
  useEffect(() => { load() }, [load])

  async function addGoal(ev: FormEvent) {
    ev.preventDefault()
    const target = Number(g.target.replace(/\./g, '').replace(',', '.'))
    if (!target) return
    const { error } = await supabase.from('sales_goals').upsert({
      owner_id: g.owner || null, period_month: from.slice(0, 8) + '01', metric: g.metric, target, created_by: profile!.id,
    }, { onConflict: 'owner_id,period_month,metric' })
    if (error) setError(error.message); else { setG({ ...g, target: '' }); load() }
  }

  return (
    <>
      <PageHeader title="Relatórios" description="Desempenho por responsável, serviço, segmento e região; metas individuais e da equipe."
        actions={<>
          <Input type="date" value={from} onChange={(e) => setFrom(e.target.value)} className="w-40" aria-label="De" />
          <Input type="date" value={to} onChange={(e) => setTo(e.target.value)} className="w-40" aria-label="Até" />
          <Select value={uf} onChange={(e) => setUf(e.target.value)} className="w-28" aria-label="UF"><option value="">Brasil</option>{UFS.map((u) => <option key={u}>{u}</option>)}</Select>
          <Button variant="outline" onClick={load} disabled={loading}>{loading ? <Loader2 className="h-4 w-4 animate-spin" /> : <RefreshCw className="h-4 w-4" />}</Button>
        </>} />
      {error && <Alert tone="error" className="mb-4">{error}</Alert>}

      <Card className="mb-6">
        <CardHeader><CardTitle>Metas do mês ({from.slice(5, 7)}/{from.slice(0, 4)})</CardTitle>
          <CardDescription>O realizado é calculado a partir de contratos, contatos, reuniões, propostas e oportunidades registrados.</CardDescription></CardHeader>
        <CardContent className="space-y-3">
          {goals.length === 0 && <p className="text-sm text-muted-foreground">Nenhuma meta para o mês.</p>}
          {goals.map((x) => {
            const pct = Math.min(100, Math.round((100 * Number(x.realizado)) / Number(x.target)))
            const money = x.metric === 'receita_contratada'
            return (
              <div key={x.goal_id} className="text-sm">
                <div className="flex justify-between"><span>{x.owner_name} · {METRIC[x.metric]}</span>
                  <span className="tabular-nums">{money ? brl.format(Number(x.realizado)) : nf.format(Number(x.realizado))} / {money ? brl.format(Number(x.target)) : nf.format(Number(x.target))} ({pct}%)</span></div>
                <div className="mt-1 h-2 rounded-full bg-muted"><div className={`h-2 rounded-full ${pct >= 100 ? 'bg-emerald-500' : 'bg-primary'}`} style={{ width: `${pct}%` }} /></div>
              </div>
            )
          })}
          {canGoal && (
            <form onSubmit={addGoal} className="flex flex-col gap-2 border-t pt-3 md:flex-row">
              <Select value={g.owner} onChange={(e) => setG({ ...g, owner: e.target.value })} aria-label="Meta de"><option value="">Equipe</option>{owners.map((o) => <option key={o.id} value={o.id}>{o.full_name ?? o.email}</option>)}</Select>
              <Select value={g.metric} onChange={(e) => setG({ ...g, metric: e.target.value })} aria-label="Indicador">{Object.entries(METRIC).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select>
              <Input value={g.target} onChange={(e) => setG({ ...g, target: e.target.value })} placeholder="Meta" inputMode="decimal" className="md:w-40" />
              <Button type="submit"><Plus className="h-4 w-4" /> Definir meta</Button>
            </form>
          )}
        </CardContent>
      </Card>

      {data && (
        <div className="grid gap-4 lg:grid-cols-2">
          <PerfTable title="Desempenho por responsável" rows={data.por_responsavel} />
          <PerfTable title="Desempenho por serviço" rows={data.por_servico} />
          <PerfTable title="Desempenho por segmento (CNAE)" rows={data.por_segmento} />
          <PerfTable title="Desempenho por região (UF)" rows={data.por_regiao} />
        </div>
      )}
    </>
  )
}
