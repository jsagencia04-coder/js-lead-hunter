import { useCallback, useEffect, useState, type FormEvent, type ReactNode } from 'react'
import { Loader2, Plus, RefreshCw, Save, Trash2 } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { ROLE_LABEL, type AppRole, type Profile } from '@/lib/types'
import { cn, formatCnpj, formatDateTime, normalizeCnpj } from '@/lib/utils'
import { useAuth } from '@/hooks/useAuth'
import { PageHeader } from '@/components/layout/AppLayout'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Select } from '@/components/ui/select'
import { Label } from '@/components/ui/label'
import { Badge } from '@/components/ui/badge'
import { Alert } from '@/components/ui/alert'
import { Table, TBody, TD, TH, THead, TR } from '@/components/ui/table'

const TABS = [
  { key: 'usuarios', label: 'Usuários' },
  { key: 'bloqueios', label: 'Oposição ao contato' },
  { key: 'regras', label: 'Serviços e pontuação' },
  { key: 'arquivamento', label: 'Arquivamento' },
  { key: 'auditoria', label: 'Auditoria' },
] as const
type Tab = (typeof TABS)[number]['key']

export default function Admin() {
  const [tab, setTab] = useState<Tab>('usuarios')
  return (
    <>
      <PageHeader title="Administração" description="Usuários, permissões, bloqueios, regras comerciais e auditoria." />
      <div className="mb-6 flex gap-1 overflow-x-auto border-b">
        {TABS.map((t) => (
          <button
            key={t.key}
            onClick={() => setTab(t.key)}
            className={cn(
              'whitespace-nowrap border-b-2 px-4 py-2 text-sm',
              tab === t.key ? 'border-primary font-medium text-primary' : 'border-transparent text-muted-foreground hover:text-foreground',
            )}
          >
            {t.label}
          </button>
        ))}
      </div>
      {tab === 'usuarios' && <Users />}
      {tab === 'bloqueios' && <Suppressions />}
      {tab === 'regras' && <Rules />}
      {tab === 'arquivamento' && <Archive />}
      {tab === 'auditoria' && <Audit />}
    </>
  )
}

function useFeedback() {
  const [error, setError] = useState<string | null>(null)
  const [ok, setOk] = useState<string | null>(null)
  const view = (
    <>
      {error && <Alert tone="error" className="mb-4">{error}</Alert>}
      {ok && <Alert tone="info" className="mb-4">{ok}</Alert>}
    </>
  )
  return { setError, setOk, view, reset: () => { setError(null); setOk(null) } }
}

/* ------------------------------ Usuários ------------------------------ */
function Users() {
  const { profile: me } = useAuth()
  const fb = useFeedback()
  const [users, setUsers] = useState<Profile[]>([])
  const [email, setEmail] = useState('')
  const [name, setName] = useState('')
  const [role, setRole] = useState<AppRole>('comercial')
  const [busy, setBusy] = useState(false)

  const load = useCallback(async () => {
    const { data, error } = await supabase.from('profiles').select('*').order('created_at')
    if (error) fb.setError(error.message)
    setUsers((data as Profile[]) ?? [])
  }, []) // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { load() }, [load])

  async function update(id: string, patch: Partial<Profile>) {
    fb.reset()
    const { error } = await supabase.from('profiles').update(patch).eq('id', id)
    if (error) fb.setError(error.message)
    load()
  }

  async function invite(e: FormEvent) {
    e.preventDefault()
    fb.reset()
    setBusy(true)
    const { data, error } = await supabase.functions.invoke('invite-user', {
      body: { email: email.trim(), full_name: name.trim(), role, redirect_to: `${window.location.origin}/redefinir-senha` },
    })
    setBusy(false)
    if (error) {
      fb.setError(`Convite não enviado: ${error.message}. Verifique se a Edge Function "invite-user" foi implantada.`)
      return
    }
    if (data?.error) { fb.setError(data.error); return }
    fb.setOk(`Convite enviado para ${email}.`)
    setEmail(''); setName('')
    load()
  }

  return (
    <>
      {fb.view}
      <Card className="mb-6">
        <CardHeader>
          <CardTitle>Convidar usuário</CardTitle>
          <CardDescription>O convite é enviado pela Edge Function <code>invite-user</code>; a chave service_role nunca chega ao navegador.</CardDescription>
        </CardHeader>
        <CardContent>
          <form onSubmit={invite} className="grid gap-3 md:grid-cols-[1fr_1fr_12rem_auto] md:items-end">
            <div className="space-y-1"><Label>E-mail</Label><Input type="email" required value={email} onChange={(e) => setEmail(e.target.value)} /></div>
            <div className="space-y-1"><Label>Nome</Label><Input value={name} onChange={(e) => setName(e.target.value)} /></div>
            <div className="space-y-1">
              <Label>Perfil</Label>
              <Select value={role} onChange={(e) => setRole(e.target.value as AppRole)}>
                {Object.entries(ROLE_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
              </Select>
            </div>
            <Button type="submit" disabled={busy}>{busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <Plus className="h-4 w-4" />} Convidar</Button>
          </form>
        </CardContent>
      </Card>

      <Card>
        <Table>
          <THead><tr><TH>Nome</TH><TH>E-mail</TH><TH>Perfil</TH><TH>Status</TH><TH>Desde</TH></tr></THead>
          <TBody>
            {users.map((u) => (
              <TR key={u.id}>
                <TD>{u.full_name ?? '—'}</TD>
                <TD>{u.email}</TD>
                <TD>
                  <Select value={u.role} disabled={u.id === me?.id} className="w-40"
                    onChange={(e) => update(u.id, { role: e.target.value as AppRole })}>
                    {Object.entries(ROLE_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
                  </Select>
                </TD>
                <TD>
                  <Button variant="outline" size="sm" disabled={u.id === me?.id} onClick={() => update(u.id, { active: !u.active })}>
                    {u.active ? 'Ativo · desativar' : 'Inativo · reativar'}
                  </Button>
                </TD>
                <TD className="text-xs text-muted-foreground">{formatDateTime(u.created_at)}</TD>
              </TR>
            ))}
          </TBody>
        </Table>
      </Card>
    </>
  )
}

/* -------------------------- Oposição ao contato -------------------------- */
interface Suppression { id: string; cnpj_basico: string; reason: string; origin: string; created_at: string }

function Suppressions() {
  const { session } = useAuth()
  const fb = useFeedback()
  const [items, setItems] = useState<Suppression[]>([])
  const [cnpj, setCnpj] = useState('')
  const [reason, setReason] = useState('')
  const [origin, setOrigin] = useState('pedido_titular')

  const load = useCallback(async () => {
    const { data, error } = await supabase.from('contact_suppressions').select('*').order('created_at', { ascending: false }).limit(500)
    if (error) fb.setError(error.message)
    setItems((data as Suppression[]) ?? [])
  }, []) // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { load() }, [load])

  async function add(e: FormEvent) {
    e.preventDefault()
    fb.reset()
    const basico = normalizeCnpj(cnpj).slice(0, 8)
    if (basico.length !== 8) return fb.setError('Informe o CNPJ completo ou os 8 primeiros caracteres.')
    const { error } = await supabase.from('contact_suppressions').insert({
      cnpj_basico: basico, reason: reason.trim(), origin, created_by: session!.user.id,
    })
    if (error) return fb.setError(error.code === '23505' ? 'Esta empresa já está bloqueada.' : error.message)
    fb.setOk('Empresa bloqueada. Leads existentes foram movidos para “Perdido” e novos leads não serão criados.')
    setCnpj(''); setReason('')
    load()
  }

  async function remove(id: string) {
    fb.reset()
    const { error } = await supabase.from('contact_suppressions').delete().eq('id', id)
    if (error) fb.setError(error.message)
    load()
  }

  return (
    <>
      {fb.view}
      <Card className="mb-6">
        <CardHeader>
          <CardTitle>Bloquear empresa para contato</CardTitle>
          <CardDescription>O bloqueio vale para a pessoa jurídica inteira (CNPJ básico), inclusive antes de ela ser importada.</CardDescription>
        </CardHeader>
        <CardContent>
          <form onSubmit={add} className="grid gap-3 md:grid-cols-[14rem_1fr_12rem_auto] md:items-end">
            <div className="space-y-1"><Label>CNPJ</Label><Input required value={cnpj} onChange={(e) => setCnpj(e.target.value)} placeholder="Aceita alfanumérico" /></div>
            <div className="space-y-1"><Label>Motivo</Label><Input required value={reason} onChange={(e) => setReason(e.target.value)} /></div>
            <div className="space-y-1">
              <Label>Origem</Label>
              <Select value={origin} onChange={(e) => setOrigin(e.target.value)}>
                <option value="pedido_titular">Pedido do titular</option>
                <option value="interno">Decisão interna</option>
                <option value="juridico">Jurídico</option>
              </Select>
            </div>
            <Button type="submit" variant="destructive">Bloquear</Button>
          </form>
        </CardContent>
      </Card>
      <Card>
        <Table>
          <THead><tr><TH>CNPJ básico</TH><TH>Motivo</TH><TH>Origem</TH><TH>Data</TH><TH /></tr></THead>
          <TBody>
            {items.length === 0 && <tr><TD colSpan={5} className="py-8 text-center text-muted-foreground">Nenhum bloqueio cadastrado.</TD></tr>}
            {items.map((s) => (
              <TR key={s.id}>
                <TD className="font-mono">{formatCnpj(s.cnpj_basico)}</TD>
                <TD>{s.reason}</TD>
                <TD>{s.origin.replace('_', ' ')}</TD>
                <TD className="text-xs">{formatDateTime(s.created_at)}</TD>
                <TD><Button variant="ghost" size="sm" onClick={() => remove(s.id)}><Trash2 className="h-4 w-4" /> Remover</Button></TD>
              </TR>
            ))}
          </TBody>
        </Table>
      </Card>
    </>
  )
}

/* ------------------------ Serviços e pontuação ------------------------ */
interface Service { id: string; code: string; name: string; description: string | null; active: boolean }
interface ScoringRule { key: string; label: string; description: string | null; points: number; active: boolean }
interface CnaeRule { id: string; cnae_prefix: string; service_id: string; relevance: number; reason: string | null; active: boolean }

function Rules() {
  const fb = useFeedback()
  const [services, setServices] = useState<Service[]>([])
  const [scoring, setScoring] = useState<ScoringRule[]>([])
  const [cnaeRules, setCnaeRules] = useState<CnaeRule[]>([])
  const [newRule, setNewRule] = useState({ cnae_prefix: '', service_id: '', relevance: 60, reason: '' })
  const [recalc, setRecalc] = useState(false)

  const load = useCallback(async () => {
    const [s, r, c] = await Promise.all([
      supabase.from('service_catalog').select('*').order('sort_order'),
      supabase.from('scoring_rules').select('*').order('points', { ascending: false }),
      supabase.from('cnae_service_rules').select('*').order('cnae_prefix'),
    ])
    const err = s.error ?? r.error ?? c.error
    if (err) fb.setError(err.message)
    setServices((s.data as Service[]) ?? [])
    setScoring((r.data as ScoringRule[]) ?? [])
    setCnaeRules((c.data as CnaeRule[]) ?? [])
  }, []) // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { load() }, [load])

  const total = scoring.filter((r) => r.active).reduce((a, r) => a + Number(r.points), 0)

  async function saveScoring() {
    fb.reset()
    if (total !== 100) return fb.setError(`A soma dos pesos ativos deve ser 100 (atual: ${total}).`)
    for (const r of scoring) {
      const { error } = await supabase.from('scoring_rules').update({ points: r.points, active: r.active }).eq('key', r.key)
      if (error) return fb.setError(error.message)
    }
    fb.setOk('Pesos salvos. Use “Recalcular todos os leads” para aplicar agora, ou aguarde a próxima importação.')
    load()
  }

  async function toggleService(s: Service) {
    fb.reset()
    const { error } = await supabase.from('service_catalog').update({ active: !s.active }).eq('id', s.id)
    if (error) fb.setError(error.message)
    load()
  }

  async function addCnaeRule(e: FormEvent) {
    e.preventDefault()
    fb.reset()
    const prefix = newRule.cnae_prefix.trim() === '*' ? '*' : newRule.cnae_prefix.replace(/\D/g, '')
    if (prefix !== '*' && (prefix.length < 2 || prefix.length > 7)) return fb.setError('Prefixo de CNAE deve ter de 2 a 7 dígitos, ou * para todos.')
    const { error } = await supabase.from('cnae_service_rules').insert({ ...newRule, cnae_prefix: prefix })
    if (error) return fb.setError(error.code === '23505' ? 'Já existe regra para este prefixo e serviço.' : error.message)
    setNewRule({ cnae_prefix: '', service_id: '', relevance: 60, reason: '' })
    load()
  }

  async function removeCnaeRule(id: string) {
    fb.reset()
    const { error } = await supabase.from('cnae_service_rules').delete().eq('id', id)
    if (error) fb.setError(error.message)
    load()
  }

  async function recalculate() {
    fb.reset()
    setRecalc(true)
    const { data, error } = await supabase.rpc('admin_recalculate_leads')
    setRecalc(false)
    if (error) return fb.setError(error.message)
    const r = data as { pontuacoes_alteradas: number; recomendacoes: number }
    fb.setOk(`Recálculo concluído: ${r.pontuacoes_alteradas} pontuações alteradas, ${r.recomendacoes} recomendações geradas.`)
  }

  const serviceName = (id: string) => services.find((s) => s.id === id)?.name ?? '—'

  return (
    <>
      {fb.view}
      <div className="grid gap-6 xl:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>Pesos da pontuação (0 a 100)</CardTitle>
            <CardDescription>Alta: 70–100 · Média: 40–69 · Baixa: 0–39. Soma dos ativos: <strong className={total === 100 ? '' : 'text-destructive'}>{total}</strong></CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            {scoring.map((r, idx) => (
              <div key={r.key} className="grid grid-cols-[1fr_5rem_auto] items-center gap-3 text-sm">
                <div>
                  <p>{r.label}</p>
                  <p className="text-xs text-muted-foreground">{r.description}</p>
                </div>
                <Input type="number" min={0} max={100} value={r.points}
                  onChange={(e) => setScoring(scoring.map((x, i) => i === idx ? { ...x, points: Number(e.target.value) } : x))} />
                <input type="checkbox" className="h-4 w-4 accent-primary" checked={r.active} aria-label={`Ativar ${r.label}`}
                  onChange={(e) => setScoring(scoring.map((x, i) => i === idx ? { ...x, active: e.target.checked } : x))} />
              </div>
            ))}
            <div className="flex flex-wrap gap-2">
              <Button onClick={saveScoring}><Save className="h-4 w-4" /> Salvar pesos</Button>
              <Button variant="outline" onClick={recalculate} disabled={recalc}>
                {recalc ? <Loader2 className="h-4 w-4 animate-spin" /> : <RefreshCw className="h-4 w-4" />} Recalcular todos os leads
              </Button>
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Serviços da JS Designer</CardTitle>
            <CardDescription>Serviços inativos deixam de ser recomendados.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-2">
            {services.map((s) => (
              <div key={s.id} className="flex items-center justify-between gap-3 text-sm">
                <span>{s.name}</span>
                <Button variant="outline" size="sm" onClick={() => toggleService(s)}>
                  {s.active ? <Badge variant="success">Ativo</Badge> : <Badge variant="outline">Inativo</Badge>}
                </Button>
              </div>
            ))}
          </CardContent>
        </Card>
      </div>

      <Card className="mt-6">
        <CardHeader>
          <CardTitle>Regras de recomendação por CNAE</CardTitle>
          <CardDescription>Use * para todas as empresas, 2–6 dígitos para divisão/grupo/classe ou 7 dígitos para a subclasse. A regra mais específica prevalece.</CardDescription>
        </CardHeader>
        <CardContent>
          <form onSubmit={addCnaeRule} className="mb-4 grid gap-3 md:grid-cols-[8rem_1fr_6rem_1fr_auto] md:items-end">
            <div className="space-y-1"><Label>CNAE</Label><Input required value={newRule.cnae_prefix} onChange={(e) => setNewRule({ ...newRule, cnae_prefix: e.target.value })} placeholder="ex.: 47" /></div>
            <div className="space-y-1">
              <Label>Serviço</Label>
              <Select required value={newRule.service_id} onChange={(e) => setNewRule({ ...newRule, service_id: e.target.value })}>
                <option value="">Selecione</option>
                {services.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
              </Select>
            </div>
            <div className="space-y-1"><Label>Relevância</Label><Input type="number" min={0} max={100} value={newRule.relevance} onChange={(e) => setNewRule({ ...newRule, relevance: Number(e.target.value) })} /></div>
            <div className="space-y-1"><Label>Justificativa</Label><Input value={newRule.reason} onChange={(e) => setNewRule({ ...newRule, reason: e.target.value })} /></div>
            <Button type="submit"><Plus className="h-4 w-4" /> Adicionar</Button>
          </form>
        </CardContent>
        <Table>
          <THead><tr><TH>CNAE</TH><TH>Serviço</TH><TH>Relevância</TH><TH>Justificativa</TH><TH /></tr></THead>
          <TBody>
            {cnaeRules.map((r) => (
              <TR key={r.id}>
                <TD className="font-mono">{r.cnae_prefix}</TD>
                <TD>{serviceName(r.service_id)}</TD>
                <TD>{r.relevance}</TD>
                <TD className="text-xs">{r.reason}</TD>
                <TD><Button variant="ghost" size="sm" onClick={() => removeCnaeRule(r.id)}><Trash2 className="h-4 w-4" /></Button></TD>
              </TR>
            ))}
          </TBody>
        </Table>
      </Card>
    </>
  )
}

/* ---------------------------- Arquivamento ---------------------------- */
interface ArchiveCfg { ativo: boolean; dias: number; dias_alta: number; liberar_espaco_na_importacao: boolean;
  ultima_execucao?: string; ultimo_resultado?: { leads: number } }
interface ArchiveRow { cnpj: string; razao_social: string | null; nome_fantasia: string | null; uf: string | null;
  municipio: string | null; cnae_principal: string | null; data_inicio_atividade: string | null; telefone: string | null;
  email: string | null; score: number | null; priority: string | null; archived_at: string; motivo: string }

function Archive() {
  const fb = useFeedback()
  const [cfg, setCfg] = useState<ArchiveCfg | null>(null)
  const [summary, setSummary] = useState<{ total: number; ultimo: string | null; banco_mb: number } | null>(null)
  const [term, setTerm] = useState('')
  const [rows, setRows] = useState<ArchiveRow[]>([])
  const [searched, setSearched] = useState(false)

  const load = useCallback(async () => {
    const [c, s] = await Promise.all([
      supabase.from('app_settings').select('value').eq('key', 'arquivamento').single(),
      supabase.rpc('archive_summary'),
    ])
    if (c.error) fb.setError(c.error.message)
    setCfg(c.data?.value as ArchiveCfg)
    setSummary(s.data as { total: number; ultimo: string | null; banco_mb: number })
  }, []) // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { load() }, [load])

  async function save() {
    if (!cfg) return
    fb.reset()
    if (cfg.dias < 7 || cfg.dias_alta < cfg.dias) return fb.setError('Use pelo menos 7 dias, e dias da alta prioridade ≥ dias gerais.')
    const { error } = await supabase.from('app_settings').update({ value: cfg, updated_at: new Date().toISOString() }).eq('key', 'arquivamento')
    if (error) return fb.setError(error.message)
    fb.setOk('Regras de arquivamento salvas. Valem a partir da próxima execução do worker.')
  }

  function query() {
    let q = supabase.from('lead_archive').select('*')
    const t = term.trim()
    if (t) {
      const digits = normalizeCnpj(t)
      q = digits.length >= 8 && /^[0-9A-Z]+$/.test(digits)
        ? q.like('cnpj', `${digits}%`)
        : q.or(`razao_social.ilike.%${t.replace(/[,()]/g, ' ')}%,nome_fantasia.ilike.%${t.replace(/[,()]/g, ' ')}%`)
    }
    return q.order('archived_at', { ascending: false })
  }

  async function search(e?: FormEvent) {
    e?.preventDefault()
    fb.reset()
    const { data, error } = await query().limit(100)
    if (error) return fb.setError(error.message)
    setRows((data as ArchiveRow[]) ?? [])
    setSearched(true)
  }

  async function exportCsv() {
    fb.reset()
    const all: ArchiveRow[] = []
    for (let from = 0; from < 20000; from += 1000) {
      const { data, error } = await query().range(from, from + 999)
      if (error) return fb.setError(error.message)
      all.push(...((data as ArchiveRow[]) ?? []))
      if (!data || data.length < 1000) break
    }
    const esc = (v: unknown) => `"${String(v ?? '').replace(/"/g, '""')}"`
    const header = ['CNPJ', 'Razão social', 'Nome fantasia', 'UF', 'Município', 'CNAE', 'Abertura', 'Telefone', 'E-mail', 'Pontuação', 'Prioridade', 'Arquivado em', 'Motivo']
    const lines = all.map((r) => [formatCnpj(r.cnpj), r.razao_social, r.nome_fantasia, r.uf, r.municipio, r.cnae_principal,
      r.data_inicio_atividade, r.telefone, r.email, r.score, r.priority, formatDateTime(r.archived_at), r.motivo].map(esc).join(';'))
    const blob = new Blob(['\uFEFF' + [header.map(esc).join(';'), ...lines].join('\r\n')], { type: 'text/csv;charset=utf-8' })
    const a = document.createElement('a')
    a.href = URL.createObjectURL(blob)
    a.download = `js-lead-hunter-arquivo-${new Date().toISOString().slice(0, 10)}.csv`
    a.click()
    URL.revokeObjectURL(a.href)
  }

  return (
    <>
      {fb.view}
      <div className="grid gap-6 xl:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>Regras de arquivamento</CardTitle>
            <CardDescription>
              Só são arquivados leads sem nenhuma ação comercial: etapa “Novo lead”, sem responsável, sem follow-up,
              sem anotação e sem contato. A ficha resumida continua consultável abaixo.
            </CardDescription>
          </CardHeader>
          {cfg && (
            <CardContent className="space-y-3 text-sm">
              <label className="flex items-center gap-2">
                <input type="checkbox" className="h-4 w-4 accent-primary" checked={cfg.ativo}
                  onChange={(e) => setCfg({ ...cfg, ativo: e.target.checked })} /> Arquivamento automático ativo
              </label>
              <div className="grid grid-cols-2 gap-3">
                <div className="space-y-1"><Label>Arquivar após (dias)</Label>
                  <Input type="number" min={7} value={cfg.dias} onChange={(e) => setCfg({ ...cfg, dias: Number(e.target.value) })} /></div>
                <div className="space-y-1"><Label>Alta prioridade após (dias)</Label>
                  <Input type="number" min={7} value={cfg.dias_alta} onChange={(e) => setCfg({ ...cfg, dias_alta: Number(e.target.value) })} /></div>
              </div>
              <label className="flex items-center gap-2">
                <input type="checkbox" className="h-4 w-4 accent-primary" checked={cfg.liberar_espaco_na_importacao}
                  onChange={(e) => setCfg({ ...cfg, liberar_espaco_na_importacao: e.target.checked })} />
                Se faltar espaço numa importação, arquivar leads sem contato (exceto alta prioridade)
              </label>
              <Button onClick={save}><Save className="h-4 w-4" /> Salvar regras</Button>
            </CardContent>
          )}
        </Card>
        <Card>
          <CardHeader><CardTitle>Situação</CardTitle></CardHeader>
          <CardContent className="space-y-1 text-sm">
            <p><span className="text-muted-foreground">Tamanho do banco: </span><strong>{summary?.banco_mb ?? '—'} MB</strong>
              <span className="text-muted-foreground"> (plano gratuito do Supabase: 500 MB)</span></p>
            <p><span className="text-muted-foreground">Leads arquivados: </span><strong>{summary ? summary.total.toLocaleString('pt-BR') : '—'}</strong></p>
            <p><span className="text-muted-foreground">Último arquivamento: </span><strong>{formatDateTime(summary?.ultimo)}</strong></p>
            <p><span className="text-muted-foreground">Última verificação automática: </span><strong>{formatDateTime(cfg?.ultima_execucao)}</strong></p>
          </CardContent>
        </Card>
      </div>

      <Card className="mt-6">
        <CardHeader><CardTitle>Consultar arquivo</CardTitle></CardHeader>
        <CardContent>
          <form onSubmit={search} className="flex flex-col gap-2 md:flex-row">
            <Input value={term} onChange={(e) => setTerm(e.target.value)} placeholder="CNPJ, razão social ou nome fantasia (vazio = mais recentes)" />
            <Button type="submit">Buscar</Button>
            <Button type="button" variant="outline" onClick={exportCsv}>Exportar para Excel (CSV)</Button>
          </form>
        </CardContent>
        {searched && (
          <Table>
            <THead><tr><TH>Empresa</TH><TH>Local</TH><TH>Contato</TH><TH>Pontuação</TH><TH>Arquivado</TH></tr></THead>
            <TBody>
              {rows.length === 0 && <tr><TD colSpan={5} className="py-8 text-center text-muted-foreground">Nada encontrado.</TD></tr>}
              {rows.map((r) => (
                <TR key={r.cnpj}>
                  <TD><p className="font-medium">{r.nome_fantasia || r.razao_social}</p><p className="text-xs text-muted-foreground">{formatCnpj(r.cnpj)}</p></TD>
                  <TD>{r.municipio ?? '—'} / {r.uf ?? '—'}</TD>
                  <TD className="text-xs">{r.telefone ?? '—'}<br />{r.email ?? ''}</TD>
                  <TD>{r.score ?? '—'}</TD>
                  <TD className="text-xs">{formatDateTime(r.archived_at)}<br /><Muted>{r.motivo}</Muted></TD>
                </TR>
              ))}
            </TBody>
          </Table>
        )}
      </Card>
    </>
  )
}

/* ------------------------------ Auditoria ------------------------------ */
interface AuditRow { id: number; actor_id: string | null; action: string; table_name: string; record_id: string | null; created_at: string }

function Audit() {
  const [rows, setRows] = useState<AuditRow[]>([])
  const [actors, setActors] = useState<Record<string, string>>({})
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    Promise.all([
      supabase.from('audit_logs').select('id,actor_id,action,table_name,record_id,created_at').order('id', { ascending: false }).limit(200),
      supabase.from('profiles').select('id,full_name,email'),
    ]).then(([a, p]) => {
      if (a.error) setError(a.error.message)
      setRows((a.data as AuditRow[]) ?? [])
      setActors(Object.fromEntries((p.data ?? []).map((x) => [x.id, x.full_name ?? x.email])))
    })
  }, [])

  return (
    <>
      {error && <Alert tone="error" className="mb-4">{error}</Alert>}
      <Card>
        <CardHeader><CardTitle>Últimos 200 registros</CardTitle></CardHeader>
        <Table>
          <THead><tr><TH>Data</TH><TH>Usuário</TH><TH>Ação</TH><TH>Tabela</TH><TH>Registro</TH></tr></THead>
          <TBody>
            {rows.map((r) => (
              <TR key={r.id}>
                <TD className="whitespace-nowrap text-xs">{formatDateTime(r.created_at)}</TD>
                <TD>{r.actor_id ? actors[r.actor_id] ?? r.actor_id : <Muted>sistema</Muted>}</TD>
                <TD><Badge variant={r.action === 'DELETE' ? 'danger' : r.action === 'INSERT' ? 'success' : 'secondary'}>{r.action}</Badge></TD>
                <TD className="font-mono text-xs">{r.table_name}</TD>
                <TD className="font-mono text-xs">{r.record_id}</TD>
              </TR>
            ))}
          </TBody>
        </Table>
      </Card>
    </>
  )
}

function Muted({ children }: { children: ReactNode }) {
  return <span className="text-muted-foreground">{children}</span>
}
