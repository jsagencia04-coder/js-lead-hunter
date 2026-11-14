import { useCallback, useEffect, useState, type ReactNode } from 'react'
import { BookmarkPlus, ChevronLeft, ChevronRight, Download, Loader2, Search, Trash2, X } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { STAGES, STAGE_LABEL, type LeadRow, type Profile } from '@/lib/types'
import { brl, formatCnpj, formatDate, nf, PORTE_LABEL, UFS } from '@/lib/utils'
import { PageHeader } from '@/components/layout/AppLayout'
import { Card, CardContent } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Select } from '@/components/ui/select'
import { Label } from '@/components/ui/label'
import { Badge } from '@/components/ui/badge'
import { Alert } from '@/components/ui/alert'
import { Table, TBody, TD, TH, THead, TR } from '@/components/ui/table'
import { LeadDrawer } from '@/components/LeadDrawer'
import { useAuth } from '@/hooks/useAuth'

interface SavedSearch { id: string; name: string; filters: Filters; is_shared: boolean; owner_id: string }

const PAGE_SIZE = 50
const EXPORT_LIMIT = 20000

interface Filters {
  abertura_de: string
  abertura_ate: string
  uf: string
  municipio: string
  cnae: string
  cnae_sec: string
  situacao: string
  porte: string
  capital_min: string
  capital_max: string
  simples: string
  mei: string
  telefone: boolean
  email: boolean
  site: boolean
  prioridade: string
  etapa: string
  responsavel: string
}

const EMPTY: Filters = {
  abertura_de: '', abertura_ate: '', uf: '', municipio: '', cnae: '', cnae_sec: '', situacao: '',
  porte: '', capital_min: '', capital_max: '', simples: '', mei: '', telefone: false, email: false,
  site: false, prioridade: '', etapa: '', responsavel: '',
}

const COLUMNS =
  'id,cnpj,cnpj_basico,stage,score,priority,owner_name,razao_social,nome_fantasia,porte,capital_social,' +
  'data_inicio_atividade,cnae_principal,cnae_descricao,uf,municipio,ddd1,telefone1,email,has_phone,has_email,' +
  'opcao_simples,opcao_mei'

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function applyFilters(q: any, f: Filters) {
  if (f.abertura_de) q = q.gte('data_inicio_atividade', f.abertura_de)
  if (f.abertura_ate) q = q.lte('data_inicio_atividade', f.abertura_ate)
  if (f.uf) q = q.eq('uf', f.uf)
  if (f.municipio.trim()) q = q.ilike('municipio', `%${f.municipio.trim()}%`)
  const cnae = f.cnae.replace(/\D/g, '')
  if (cnae) q = cnae.length === 7 ? q.eq('cnae_principal', cnae) : q.like('cnae_principal', `${cnae}%`)
  const cnae2 = f.cnae_sec.replace(/\D/g, '')
  if (cnae2.length === 7) q = q.contains('cnaes_secundarios', [cnae2])
  if (f.situacao) q = q.eq('situacao_cadastral', f.situacao)
  if (f.porte) q = q.eq('porte', f.porte)
  if (f.capital_min) q = q.gte('capital_social', Number(f.capital_min))
  if (f.capital_max) q = q.lte('capital_social', Number(f.capital_max))
  if (f.simples) q = q.eq('opcao_simples', f.simples === 'sim')
  if (f.mei) q = q.eq('opcao_mei', f.mei === 'sim')
  if (f.telefone) q = q.eq('has_phone', true)
  if (f.email) q = q.eq('has_email', true)
  if (f.site) q = q.not('website', 'is', null)
  if (f.prioridade) q = q.eq('priority', f.prioridade)
  if (f.etapa) q = q.eq('stage', f.etapa)
  if (f.responsavel === '__none__') q = q.is('owner_id', null)
  else if (f.responsavel) q = q.eq('owner_id', f.responsavel)
  return q
}

export default function Leads() {
  const { profile } = useAuth()
  const [openId, setOpenId] = useState<string | null>(null)
  const [saved, setSaved] = useState<SavedSearch[]>([])
  const [savedId, setSavedId] = useState('')
  const [saveName, setSaveName] = useState('')
  const [shareSearch, setShareSearch] = useState(false)
  const [draft, setDraft] = useState<Filters>(EMPTY)
  const [filters, setFilters] = useState<Filters>(EMPTY)
  const [page, setPage] = useState(0)
  const [rows, setRows] = useState<LeadRow[]>([])
  const [count, setCount] = useState(0)
  const [loading, setLoading] = useState(true)
  const [exporting, setExporting] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [owners, setOwners] = useState<Pick<Profile, 'id' | 'full_name' | 'email'>[]>([])

  useEffect(() => {
    supabase.from('profiles').select('id,full_name,email').eq('active', true).order('full_name')
      .then(({ data }) => setOwners(data ?? []))
  }, [])

  const loadSaved = useCallback(async () => {
    const { data } = await supabase.from('lead_searches').select('*').order('name')
    setSaved((data as SavedSearch[]) ?? [])
  }, [])
  useEffect(() => { loadSaved() }, [loadSaved])

  function applySaved(id: string) {
    setSavedId(id)
    const s = saved.find((x) => x.id === id)
    if (!s) return
    const f = { ...EMPTY, ...s.filters }
    setDraft(f); setFilters(f); setPage(0)
  }

  async function saveSearch() {
    if (!saveName.trim() || !profile) return
    setError(null)
    const { data, error } = await supabase.from('lead_searches')
      .upsert({ owner_id: profile.id, name: saveName.trim(), filters: draft, is_shared: shareSearch }, { onConflict: 'owner_id,name' })
      .select().single()
    if (error) return setError(error.message)
    setSaveName('')
    await loadSaved()
    setSavedId((data as SavedSearch).id)
  }

  async function deleteSearch() {
    if (!savedId) return
    const { error } = await supabase.from('lead_searches').delete().eq('id', savedId)
    if (error) return setError(error.message)
    setSavedId('')
    loadSaved()
  }

  const load = useCallback(async () => {
    setLoading(true)
    setError(null)
    const q = applyFilters(supabase.from('lead_list_v').select(COLUMNS, { count: 'exact' }), filters)
      .order('score', { ascending: false })
      .order('data_inicio_atividade', { ascending: false })
      .range(page * PAGE_SIZE, page * PAGE_SIZE + PAGE_SIZE - 1)
    const { data, count, error } = await q
    if (error) setError(error.message)
    setRows((data as LeadRow[]) ?? [])
    setCount(count ?? 0)
    setLoading(false)
  }, [filters, page])

  useEffect(() => { load() }, [load])

  function set<K extends keyof Filters>(k: K, v: Filters[K]) {
    setDraft((d) => ({ ...d, [k]: v }))
  }

  async function exportCsv() {
    setExporting(true)
    setError(null)
    const all: LeadRow[] = []
    const total = Math.min(count, EXPORT_LIMIT)
    for (let from = 0; from < total; from += 1000) {
      const { data, error } = await applyFilters(supabase.from('lead_list_v').select(COLUMNS), filters)
        .order('score', { ascending: false })
        .order('id')
        .range(from, Math.min(from + 999, total - 1))
      if (error) { setError(error.message); setExporting(false); return }
      all.push(...((data as LeadRow[]) ?? []))
    }
    const header = ['CNPJ', 'Razão social', 'Nome fantasia', 'Abertura', 'UF', 'Município', 'CNAE', 'Descrição CNAE',
      'Porte', 'Capital social', 'Simples', 'MEI', 'Telefone', 'E-mail', 'Pontuação', 'Prioridade', 'Etapa', 'Responsável']
    const esc = (v: unknown) => `"${String(v ?? '').replace(/"/g, '""')}"`
    const lines = all.map((r) => [
      formatCnpj(r.cnpj), r.razao_social, r.nome_fantasia, formatDate(r.data_inicio_atividade), r.uf, r.municipio,
      r.cnae_principal, r.cnae_descricao, PORTE_LABEL[r.porte ?? ''] ?? '', r.capital_social ?? '',
      r.opcao_simples == null ? '' : r.opcao_simples ? 'Sim' : 'Não', r.opcao_mei == null ? '' : r.opcao_mei ? 'Sim' : 'Não',
      r.telefone1 ? `(${r.ddd1 ?? ''}) ${r.telefone1}` : '', r.email, r.score, r.priority, STAGE_LABEL[r.stage], r.owner_name,
    ].map(esc).join(';'))
    // BOM + ponto e vírgula: abre corretamente no Excel em português
    const blob = new Blob(['﻿' + [header.map(esc).join(';'), ...lines].join('\r\n')], { type: 'text/csv;charset=utf-8' })
    const a = document.createElement('a')
    a.href = URL.createObjectURL(blob)
    a.download = `js-lead-hunter-leads-${new Date().toISOString().slice(0, 10)}.csv`
    a.click()
    URL.revokeObjectURL(a.href)
    setExporting(false)
  }

  const pages = Math.max(1, Math.ceil(count / PAGE_SIZE))

  return (
    <>
      <PageHeader
        title="Leads"
        description="Pesquisa avançada com paginação no servidor."
        actions={
          <Button variant="outline" onClick={exportCsv} disabled={exporting || count === 0}>
            {exporting ? <Loader2 className="h-4 w-4 animate-spin" /> : <Download className="h-4 w-4" />}
            Exportar para Excel (CSV)
          </Button>
        }
      />

      <Card className="mb-4">
        <CardContent className="flex flex-col gap-3 pt-5 md:flex-row md:items-end">
          <div className="flex-1 space-y-1">
            <Label>Pesquisas salvas</Label>
            <div className="flex gap-2">
              <Select value={savedId} onChange={(e) => applySaved(e.target.value)}>
                <option value="">Selecione…</option>
                {saved.map((s) => <option key={s.id} value={s.id}>{s.name}{s.is_shared ? ' (compartilhada)' : ''}</option>)}
              </Select>
              {savedId && saved.find((s) => s.id === savedId)?.owner_id === profile?.id && (
                <Button variant="ghost" size="icon" onClick={deleteSearch} aria-label="Excluir pesquisa"><Trash2 className="h-4 w-4" /></Button>
              )}
            </div>
          </div>
          <div className="flex-1 space-y-1">
            <Label>Salvar filtros atuais como</Label>
            <div className="flex items-center gap-2">
              <Input value={saveName} onChange={(e) => setSaveName(e.target.value)} placeholder="Ex.: Varejo SP com telefone" />
              <label className="flex items-center gap-1 whitespace-nowrap text-xs">
                <input type="checkbox" className="accent-primary" checked={shareSearch} onChange={(e) => setShareSearch(e.target.checked)} /> Compartilhar
              </label>
              <Button variant="outline" onClick={saveSearch} disabled={!saveName.trim()}><BookmarkPlus className="h-4 w-4" /> Salvar</Button>
            </div>
          </div>
        </CardContent>
      </Card>

      <Card className="mb-6">
        <CardContent className="pt-5">
          <form
            onSubmit={(e) => { e.preventDefault(); setPage(0); setFilters(draft) }}
            className="grid grid-cols-2 gap-3 md:grid-cols-4 xl:grid-cols-6"
          >
            <Field label="Abertura de"><Input type="date" value={draft.abertura_de} onChange={(e) => set('abertura_de', e.target.value)} /></Field>
            <Field label="Abertura até"><Input type="date" value={draft.abertura_ate} onChange={(e) => set('abertura_ate', e.target.value)} /></Field>
            <Field label="UF">
              <Select value={draft.uf} onChange={(e) => set('uf', e.target.value)}>
                <option value="">Todas</option>
                {UFS.map((u) => <option key={u}>{u}</option>)}
              </Select>
            </Field>
            <Field label="Município"><Input value={draft.municipio} onChange={(e) => set('municipio', e.target.value)} placeholder="Nome" /></Field>
            <Field label="CNAE principal"><Input value={draft.cnae} onChange={(e) => set('cnae', e.target.value)} placeholder="Código ou prefixo" /></Field>
            <Field label="CNAE secundário"><Input value={draft.cnae_sec} onChange={(e) => set('cnae_sec', e.target.value)} placeholder="7 dígitos" /></Field>
            <Field label="Situação cadastral">
              <Select value={draft.situacao} onChange={(e) => set('situacao', e.target.value)}>
                <option value="">Todas</option>
                <option value="02">Ativa</option>
                <option value="03">Suspensa</option>
                <option value="04">Inapta</option>
                <option value="08">Baixada</option>
              </Select>
            </Field>
            <Field label="Porte">
              <Select value={draft.porte} onChange={(e) => set('porte', e.target.value)}>
                <option value="">Todos</option>
                {Object.entries(PORTE_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
              </Select>
            </Field>
            <Field label="Capital mín. (R$)"><Input type="number" min={0} value={draft.capital_min} onChange={(e) => set('capital_min', e.target.value)} /></Field>
            <Field label="Capital máx. (R$)"><Input type="number" min={0} value={draft.capital_max} onChange={(e) => set('capital_max', e.target.value)} /></Field>
            <Field label="Simples Nacional"><YesNo value={draft.simples} onChange={(v) => set('simples', v)} /></Field>
            <Field label="MEI"><YesNo value={draft.mei} onChange={(v) => set('mei', v)} /></Field>
            <Field label="Prioridade">
              <Select value={draft.prioridade} onChange={(e) => set('prioridade', e.target.value)}>
                <option value="">Todas</option>
                <option value="alta">Alta (70–100)</option>
                <option value="media">Média (40–69)</option>
                <option value="baixa">Baixa (0–39)</option>
              </Select>
            </Field>
            <Field label="Etapa comercial">
              <Select value={draft.etapa} onChange={(e) => set('etapa', e.target.value)}>
                <option value="">Todas</option>
                {STAGES.map((s) => <option key={s.value} value={s.value}>{s.label}</option>)}
              </Select>
            </Field>
            <Field label="Responsável">
              <Select value={draft.responsavel} onChange={(e) => set('responsavel', e.target.value)}>
                <option value="">Todos</option>
                <option value="__none__">Sem responsável</option>
                {owners.map((o) => <option key={o.id} value={o.id}>{o.full_name ?? o.email}</option>)}
              </Select>
            </Field>
            <div className="col-span-2 flex flex-wrap items-end gap-4 pb-2 text-sm md:col-span-4 xl:col-span-6">
              <Check label="Com telefone" checked={draft.telefone} onChange={(v) => set('telefone', v)} />
              <Check label="Com e-mail" checked={draft.email} onChange={(v) => set('email', v)} />
              <Check label="Site identificado" checked={draft.site} onChange={(v) => set('site', v)} />
              <div className="ml-auto flex gap-2">
                <Button type="button" variant="ghost" onClick={() => { setDraft(EMPTY); setFilters(EMPTY); setPage(0) }}>
                  <X className="h-4 w-4" /> Limpar
                </Button>
                <Button type="submit"><Search className="h-4 w-4" /> Pesquisar</Button>
              </div>
            </div>
          </form>
        </CardContent>
      </Card>

      {error && <Alert tone="error" title="Erro na consulta" className="mb-4">{error}</Alert>}

      <Card>
        <div className="flex items-center justify-between border-b px-4 py-3 text-sm">
          <span className="text-muted-foreground">{loading ? 'Carregando…' : `${nf.format(count)} lead(s)`}</span>
          <div className="flex items-center gap-2">
            <Button variant="outline" size="icon" disabled={page === 0 || loading} onClick={() => setPage(page - 1)} aria-label="Página anterior">
              <ChevronLeft className="h-4 w-4" />
            </Button>
            <span className="tabular-nums">{page + 1} / {pages}</span>
            <Button variant="outline" size="icon" disabled={page + 1 >= pages || loading} onClick={() => setPage(page + 1)} aria-label="Próxima página">
              <ChevronRight className="h-4 w-4" />
            </Button>
          </div>
        </div>
        <Table>
          <THead>
            <tr>
              <TH>Empresa</TH><TH>Abertura</TH><TH>Local</TH><TH>CNAE</TH><TH>Porte / capital</TH>
              <TH>Contato</TH><TH>Pontuação</TH><TH>Etapa</TH>
            </tr>
          </THead>
          <TBody>
            {!loading && rows.length === 0 && (
              <tr><TD colSpan={8} className="py-12 text-center text-muted-foreground">
                Nenhum lead encontrado. Os leads são criados automaticamente pelas importações oficiais.
              </TD></tr>
            )}
            {rows.map((r) => (
              <TR key={r.id} className="cursor-pointer" onClick={() => setOpenId(r.id)}>
                <TD>
                  <p className="font-medium">{r.nome_fantasia || r.razao_social || '—'}</p>
                  <p className="text-xs text-muted-foreground">{formatCnpj(r.cnpj)}</p>
                </TD>
                <TD className="whitespace-nowrap">{formatDate(r.data_inicio_atividade)}</TD>
                <TD className="whitespace-nowrap">{r.municipio ?? '—'} / {r.uf ?? '—'}</TD>
                <TD className="max-w-[16rem]"><p className="truncate" title={r.cnae_descricao ?? ''}>{r.cnae_principal} · {r.cnae_descricao ?? ''}</p></TD>
                <TD className="whitespace-nowrap text-xs">
                  {PORTE_LABEL[r.porte ?? ''] ?? '—'}<br />
                  <span className="text-muted-foreground">{r.capital_social != null ? brl.format(r.capital_social) : '—'}</span>
                  {r.opcao_mei && <Badge variant="secondary" className="ml-1">MEI</Badge>}
                </TD>
                <TD className="text-xs">
                  {r.telefone1 ? `(${r.ddd1 ?? ''}) ${r.telefone1}` : <span className="text-muted-foreground">sem telefone</span>}<br />
                  {r.email ? r.email.toLowerCase() : <span className="text-muted-foreground">sem e-mail</span>}
                </TD>
                <TD>
                  <Badge variant={r.priority === 'alta' ? 'success' : r.priority === 'media' ? 'warning' : 'outline'}>
                    {r.score} · {r.priority === 'media' ? 'média' : r.priority}
                  </Badge>
                </TD>
                <TD className="whitespace-nowrap text-xs">{STAGE_LABEL[r.stage]}</TD>
              </TR>
            ))}
          </TBody>
        </Table>
      </Card>
      <LeadDrawer leadId={openId} onClose={() => setOpenId(null)} onChanged={load} />
      {count > EXPORT_LIMIT && (
        <p className="mt-2 text-xs text-muted-foreground">A exportação traz até {nf.format(EXPORT_LIMIT)} linhas; refine os filtros para exportar o restante.</p>
      )}
    </>
  )
}

function Field({ label, children }: { label: string; children: ReactNode }) {
  return <div className="space-y-1"><Label>{label}</Label>{children}</div>
}

function YesNo({ value, onChange }: { value: string; onChange: (v: string) => void }) {
  return (
    <Select value={value} onChange={(e) => onChange(e.target.value)}>
      <option value="">Indiferente</option>
      <option value="sim">Sim</option>
      <option value="nao">Não</option>
    </Select>
  )
}

function Check({ label, checked, onChange }: { label: string; checked: boolean; onChange: (v: boolean) => void }) {
  return (
    <label className="flex cursor-pointer items-center gap-2">
      <input type="checkbox" className="h-4 w-4 accent-primary" checked={checked} onChange={(e) => onChange(e.target.checked)} />
      {label}
    </label>
  )
}
