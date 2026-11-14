import { useCallback, useEffect, useState, type DragEvent } from 'react'
import { CalendarClock, Loader2, Phone, RefreshCw } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { STAGES, type LeadRow, type LeadStage, type Profile } from '@/lib/types'
import { formatDateTime, nf, UFS } from '@/lib/utils'
import { useAuth } from '@/hooks/useAuth'
import { PageHeader } from '@/components/layout/AppLayout'
import { LeadDrawer } from '@/components/LeadDrawer'
import { Button } from '@/components/ui/button'
import { Select } from '@/components/ui/select'
import { Badge } from '@/components/ui/badge'
import { Alert } from '@/components/ui/alert'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'

const PER_COLUMN = 30
const CARD_COLUMNS = 'id,cnpj,cnpj_basico,stage,score,priority,owner_name,razao_social,nome_fantasia,uf,municipio,has_phone,has_email,next_follow_up_at'

type Card = Pick<LeadRow, 'id' | 'cnpj' | 'cnpj_basico' | 'stage' | 'score' | 'priority' | 'owner_name' | 'razao_social' |
  'nome_fantasia' | 'uf' | 'municipio' | 'has_phone' | 'has_email'> & { next_follow_up_at: string | null }

export default function Crm() {
  const { profile, hasRole } = useAuth()
  const canEdit = hasRole('admin', 'gestor', 'comercial')
  const [owner, setOwner] = useState<string>('todos')
  const [uf, setUf] = useState('')
  const [priority, setPriority] = useState('')
  const [columns, setColumns] = useState<Record<string, Card[]>>({})
  const [limits, setLimits] = useState<Record<string, number>>({})
  const [counts, setCounts] = useState<Record<string, number>>({})
  const [owners, setOwners] = useState<Pick<Profile, 'id' | 'full_name' | 'email'>[]>([])
  const [followUps, setFollowUps] = useState<Card[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [openId, setOpenId] = useState<string | null>(null)
  const [dragOver, setDragOver] = useState<string | null>(null)

  useEffect(() => {
    supabase.from('profiles').select('id,full_name,email').eq('active', true).order('full_name').then(({ data }) => setOwners(data ?? []))
  }, [])

  const load = useCallback(async () => {
    setLoading(true)
    setError(null)
    const ownerId = owner === 'meus' ? profile?.id : owner !== 'todos' && owner !== 'sem' ? owner : null
    const countsReq = supabase.rpc('crm_stage_counts', {
      p_owner: ownerId, p_unassigned: owner === 'sem', p_uf: uf || null, p_priority: priority || null,
    })
    const colReqs = STAGES.map((s) => {
      let q = supabase.from('lead_list_v').select(CARD_COLUMNS).eq('stage', s.value)
      if (ownerId) q = q.eq('owner_id', ownerId)
      if (owner === 'sem') q = q.is('owner_id', null)
      if (uf) q = q.eq('uf', uf)
      if (priority) q = q.eq('priority', priority)
      return q.order('score', { ascending: false }).order('id').limit(limits[s.value] ?? PER_COLUMN)
    })
    const fuReq = supabase.from('lead_list_v').select(CARD_COLUMNS)
      .eq('owner_id', profile!.id).not('next_follow_up_at', 'is', null)
      .order('next_follow_up_at').limit(15)
    const [c, f, ...cols] = await Promise.all([countsReq, fuReq, ...colReqs])
    const err = c.error ?? f.error ?? cols.find((x) => x.error)?.error
    if (err) setError(err.message)
    setCounts(Object.fromEntries(((c.data as { stage: string; total: number }[]) ?? []).map((r) => [r.stage, r.total])))
    setColumns(Object.fromEntries(STAGES.map((s, i) => [s.value, (cols[i].data as unknown as Card[]) ?? []])))
    setFollowUps((f.data as unknown as Card[]) ?? [])
    setLoading(false)
  }, [owner, uf, priority, limits, profile])

  useEffect(() => { load() }, [load])

  async function move(id: string, from: LeadStage, to: LeadStage) {
    if (from === to) return
    if (to === 'perdido') {
      setOpenId(id)
      setError('Para mover para “Perdido”, abra a ficha e informe o motivo da perda.')
      return
    }
    // atualização otimista
    setColumns((cols) => {
      const card = cols[from]?.find((c) => c.id === id)
      if (!card) return cols
      return { ...cols, [from]: cols[from].filter((c) => c.id !== id), [to]: [{ ...card, stage: to }, ...(cols[to] ?? [])] }
    })
    setCounts((c) => ({ ...c, [from]: (c[from] ?? 1) - 1, [to]: (c[to] ?? 0) + 1 }))
    const { error } = await supabase.from('leads').update({ stage: to }).eq('id', id)
    if (error) { setError(error.message); load() }
  }

  function onDrop(e: DragEvent, to: LeadStage) {
    e.preventDefault()
    setDragOver(null)
    const [id, from] = e.dataTransfer.getData('text/plain').split('|')
    if (id && from) move(id, from as LeadStage, to)
  }

  const now = Date.now()

  return (
    <>
      <PageHeader
        title="CRM"
        description={canEdit ? 'Arraste os cartões entre as etapas. Clique para abrir a ficha completa.' : 'Visualização do funil comercial.'}
        actions={
          <>
            <Select value={owner} onChange={(e) => setOwner(e.target.value)} className="w-48" aria-label="Responsável">
              <option value="todos">Todos os responsáveis</option>
              <option value="meus">Meus leads</option>
              <option value="sem">Sem responsável</option>
              {owners.map((o) => <option key={o.id} value={o.id}>{o.full_name ?? o.email}</option>)}
            </Select>
            <Select value={uf} onChange={(e) => setUf(e.target.value)} className="w-28" aria-label="UF">
              <option value="">Brasil</option>
              {UFS.map((u) => <option key={u}>{u}</option>)}
            </Select>
            <Select value={priority} onChange={(e) => setPriority(e.target.value)} className="w-40" aria-label="Prioridade">
              <option value="">Todas as prioridades</option>
              <option value="alta">Alta</option>
              <option value="media">Média</option>
              <option value="baixa">Baixa</option>
            </Select>
            <Button variant="outline" onClick={load} disabled={loading}>
              {loading ? <Loader2 className="h-4 w-4 animate-spin" /> : <RefreshCw className="h-4 w-4" />}
            </Button>
          </>
        }
      />
      {error && <Alert tone="warning" className="mb-4">{error}</Alert>}

      {followUps.length > 0 && (
        <Card className="mb-4">
          <CardHeader className="pb-2"><CardTitle className="flex items-center gap-2"><CalendarClock className="h-4 w-4" /> Meus próximos follow-ups</CardTitle></CardHeader>
          <CardContent className="flex gap-2 overflow-x-auto pb-4">
            {followUps.map((f) => {
              const late = new Date(f.next_follow_up_at!).getTime() < now
              return (
                <button key={f.id} onClick={() => setOpenId(f.id)}
                  className={`min-w-[14rem] rounded-md border p-2 text-left text-xs hover:bg-accent ${late ? 'border-red-300 bg-red-50' : ''}`}>
                  <p className="truncate font-medium">{f.nome_fantasia || f.razao_social}</p>
                  <p className={late ? 'text-red-700' : 'text-muted-foreground'}>{late ? 'Atrasado · ' : ''}{formatDateTime(f.next_follow_up_at)}</p>
                </button>
              )
            })}
          </CardContent>
        </Card>
      )}

      <div className="flex gap-3 overflow-x-auto pb-4">
        {STAGES.map((s) => {
          const cards = columns[s.value] ?? []
          const total = counts[s.value] ?? 0
          return (
            <div key={s.value}
              onDragOver={(e) => { if (canEdit) { e.preventDefault(); setDragOver(s.value) } }}
              onDragLeave={() => setDragOver(null)}
              onDrop={(e) => canEdit && onDrop(e, s.value)}
              className={`flex w-72 shrink-0 flex-col rounded-lg border bg-muted/40 ${dragOver === s.value ? 'ring-2 ring-primary' : ''}`}>
              <div className="flex items-center justify-between border-b px-3 py-2">
                <span className="text-sm font-medium">{s.label}</span>
                <Badge variant="secondary">{nf.format(total)}</Badge>
              </div>
              <div className="flex max-h-[70vh] flex-col gap-2 overflow-y-auto p-2">
                {cards.map((c) => (
                  <div key={c.id}
                    draggable={canEdit}
                    onDragStart={(e) => e.dataTransfer.setData('text/plain', `${c.id}|${c.stage}`)}
                    onClick={() => setOpenId(c.id)}
                    className="cursor-pointer rounded-md border bg-card p-2.5 text-xs shadow-sm hover:border-primary">
                    <div className="flex items-start justify-between gap-2">
                      <p className="line-clamp-2 text-sm font-medium">{c.nome_fantasia || c.razao_social || '—'}</p>
                      <Badge variant={c.priority === 'alta' ? 'success' : c.priority === 'media' ? 'warning' : 'outline'}>{c.score}</Badge>
                    </div>
                    <p className="mt-1 text-muted-foreground">{c.municipio ?? '—'} / {c.uf ?? '—'}</p>
                    <div className="mt-1 flex items-center gap-2 text-muted-foreground">
                      {c.has_phone && <Phone className="h-3 w-3" />}
                      {c.has_email && <span>@</span>}
                      <span className="ml-auto truncate">{c.owner_name ?? 'sem responsável'}</span>
                    </div>
                    {c.next_follow_up_at && (
                      <p className={`mt-1 ${new Date(c.next_follow_up_at).getTime() < now ? 'text-red-600' : 'text-muted-foreground'}`}>
                        Follow-up {formatDateTime(c.next_follow_up_at)}
                      </p>
                    )}
                  </div>
                ))}
                {!loading && cards.length === 0 && <p className="p-3 text-center text-xs text-muted-foreground">Nenhum lead</p>}
                {cards.length < total && (
                  <Button variant="ghost" size="sm"
                    onClick={() => setLimits((l) => ({ ...l, [s.value]: (l[s.value] ?? PER_COLUMN) + PER_COLUMN }))}>
                    Carregar mais ({nf.format(total - cards.length)})
                  </Button>
                )}
              </div>
            </div>
          )
        })}
      </div>

      <LeadDrawer leadId={openId} onClose={() => setOpenId(null)} onChanged={load} />
    </>
  )
}
