import { useCallback, useEffect, useState } from 'react'
import { CheckCircle2, Loader2, RefreshCw } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { formatDateTime } from '@/lib/utils'
import { TASK_KIND, useOpenLead, type Task } from '@/lib/crm'
import { useAuth } from '@/hooks/useAuth'
import { PageHeader } from '@/components/layout/AppLayout'
import { Button } from '@/components/ui/button'
import { Select } from '@/components/ui/select'
import { Badge } from '@/components/ui/badge'
import { Alert } from '@/components/ui/alert'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'

type Row = Task & { empresa: string | null }

export default function Agenda() {
  const { profile, hasRole } = useAuth()
  const openLead = useOpenLead()
  const canEdit = hasRole('admin', 'gestor', 'comercial')
  const [scope, setScope] = useState<'meus' | 'equipe'>('meus')
  const [kind, setKind] = useState('')
  const [rows, setRows] = useState<Row[]>([])
  const [done, setDone] = useState<Row[]>([])
  const [owners, setOwners] = useState<Record<string, string>>({})
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(async () => {
    setLoading(true)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const base = (q: any) => {
      if (scope === 'meus') q = q.eq('owner_id', profile!.id)
      if (kind) q = q.eq('kind', kind)
      return q
    }
    const [a, b, p] = await Promise.all([
      base(supabase.from('crm_tasks').select('*, leads!inner(cnpj, establishments!inner(nome_fantasia), companies!inner(razao_social))').is('done_at', null))
        .order('due_at', { ascending: true, nullsFirst: false }).limit(300),
      base(supabase.from('crm_tasks').select('*, leads!inner(cnpj, establishments!inner(nome_fantasia), companies!inner(razao_social))').not('done_at', 'is', null))
        .order('done_at', { ascending: false }).limit(30),
      supabase.from('profiles').select('id,full_name,email'),
    ])
    const err = a.error ?? b.error
    if (err) setError(err.message)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const map = (r: any): Row => ({ ...r, empresa: r.leads?.establishments?.nome_fantasia || r.leads?.companies?.razao_social || r.leads?.cnpj })
    setRows((a.data ?? []).map(map))
    setDone((b.data ?? []).map(map))
    setOwners(Object.fromEntries((p.data ?? []).map((u) => [u.id, u.full_name ?? u.email])))
    setLoading(false)
  }, [scope, kind, profile])
  useEffect(() => { load() }, [load])

  async function complete(t: Row) {
    const { error } = await supabase.from('crm_tasks').update({ done_at: new Date().toISOString() }).eq('id', t.id)
    if (error) setError(error.message); else load()
  }

  const now = Date.now()
  const startTomorrow = new Date(); startTomorrow.setHours(24, 0, 0, 0)
  const groups: [string, Row[], string][] = [
    ['Atrasadas', rows.filter((r) => r.due_at && new Date(r.due_at).getTime() < now), 'border-red-300'],
    ['Hoje', rows.filter((r) => r.due_at && new Date(r.due_at).getTime() >= now && new Date(r.due_at) < startTomorrow), ''],
    ['Próximas', rows.filter((r) => r.due_at && new Date(r.due_at) >= startTomorrow), ''],
    ['Sem data', rows.filter((r) => !r.due_at), ''],
  ]

  const item = (t: Row, tone = '') => (
    <div key={t.id} className={`flex flex-wrap items-center gap-2 rounded-md border p-2 text-sm ${tone}`}>
      <Badge variant="secondary">{TASK_KIND[t.kind] ?? t.kind}</Badge>
      <button className="font-medium hover:underline" onClick={() => openLead(t.lead_id)}>{t.empresa}</button>
      <span>{t.title}</span>
      <span className="text-xs text-muted-foreground">{t.due_at ? formatDateTime(t.due_at) : ''}{scope === 'equipe' && t.owner_id ? ` · ${owners[t.owner_id] ?? ''}` : ''}</span>
      {t.done_at ? <span className="ml-auto text-xs text-muted-foreground">concluída {formatDateTime(t.done_at)}{t.outcome ? ` — ${t.outcome}` : ''}</span>
        : canEdit && <Button size="sm" variant="outline" className="ml-auto" onClick={() => complete(t)}><CheckCircle2 className="h-4 w-4" /> Concluir</Button>}
    </div>
  )

  return (
    <>
      <PageHeader title="Agenda e tarefas" description="Ligações, reuniões, e-mails, WhatsApp, visitas e follow-ups. Para criar, abra a ficha da empresa."
        actions={<>
          <Select value={scope} onChange={(e) => setScope(e.target.value as 'meus' | 'equipe')} className="w-40" aria-label="Escopo">
            <option value="meus">Minhas tarefas</option><option value="equipe">Toda a equipe</option>
          </Select>
          <Select value={kind} onChange={(e) => setKind(e.target.value)} className="w-40" aria-label="Tipo">
            <option value="">Todos os tipos</option>
            {Object.entries(TASK_KIND).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
          </Select>
          <Button variant="outline" onClick={load} disabled={loading}>{loading ? <Loader2 className="h-4 w-4 animate-spin" /> : <RefreshCw className="h-4 w-4" />}</Button>
        </>} />
      {error && <Alert tone="error" className="mb-4">{error}</Alert>}
      <div className="grid gap-4 lg:grid-cols-2">
        {groups.map(([title, list, tone]) => (
          <Card key={title}>
            <CardHeader><CardTitle className={title === 'Atrasadas' && list.length ? 'text-red-700' : ''}>{title} ({list.length})</CardTitle></CardHeader>
            <CardContent className="space-y-2">
              {list.length === 0 ? <p className="text-sm text-muted-foreground">Nada aqui.</p> : list.map((t) => item(t, tone))}
            </CardContent>
          </Card>
        ))}
      </div>
      <Card className="mt-4">
        <CardHeader><CardTitle>Concluídas recentemente</CardTitle></CardHeader>
        <CardContent className="space-y-2">{done.length === 0 ? <p className="text-sm text-muted-foreground">Nenhuma.</p> : done.map((t) => item(t))}</CardContent>
      </Card>
    </>
  )
}
