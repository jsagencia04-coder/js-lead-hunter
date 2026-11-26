import { useCallback, useEffect, useState } from 'react'
import { Loader2, Pause, Play, RefreshCw, Save } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { formatDateTime, nf } from '@/lib/utils'
import { CHANNEL_STATUS, PLATFORM } from '@/lib/crm'
import { useAuth } from '@/hooks/useAuth'
import { PageHeader } from '@/components/layout/AppLayout'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Badge } from '@/components/ui/badge'
import { Alert } from '@/components/ui/alert'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Table, TBody, TD, TH, THead, TR } from '@/components/ui/table'

interface Cfg {
  pausado: boolean; lote: number; concorrencia: number; enfileirar_por_rodada: number; cache_dias: number
  limites_diarios: Record<string, number>; custo_por_consulta_usd: Record<string, number>; custo_maximo_diario_usd: number
  reverificar_dias: Record<string, number>; confianca_verificado: number; confianca_possivel: number
}
interface Summary {
  fila: Record<string, number>; sem_fila: number; canais: Record<string, Record<string, number>>
  uso_hoje: Record<string, { consultas: number; custo_usd: number; erros: number }>
  uso_mes: Record<string, { consultas: number; custo_usd: number }>; config: Cfg
}
interface Run { id: string; started_at: string; finished_at: string | null; status: string; processed: number; errors: number; found: Record<string, number>; calls: Record<string, number>; cost_usd: number; worker_host: string | null; message: string | null }
interface Integration { key: string; label: string; status: string; last_seen_at: string | null; details: Record<string, unknown> }

export default function Intelligence() {
  const { hasRole } = useAuth()
  const isAdmin = hasRole('admin')
  const isManager = hasRole('admin', 'gestor')
  const [s, setS] = useState<Summary | null>(null)
  const [cfg, setCfg] = useState<Cfg | null>(null)
  const [runs, setRuns] = useState<Run[]>([])
  const [ints, setInts] = useState<Integration[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [ok, setOk] = useState<string | null>(null)

  const load = useCallback(async () => {
    setLoading(true)
    const [a, r, i] = await Promise.all([
      supabase.rpc('intelligence_summary'),
      supabase.from('enrichment_runs').select('*').order('started_at', { ascending: false }).limit(15),
      supabase.from('integration_status').select('*').in('key', ['inteligencia', 'google_places', 'brave']),
    ])
    if (a.error) setError(a.error.message)
    setS(a.data as Summary)
    setCfg((a.data as Summary)?.config ?? null)
    setRuns((r.data as Run[]) ?? [])
    setInts((i.data as Integration[]) ?? [])
    setLoading(false)
  }, [])
  useEffect(() => { load() }, [load])

  async function pause(p: boolean) {
    const { error } = await supabase.rpc('set_intelligence_paused', { p_paused: p })
    if (error) setError(error.message); else load()
  }
  async function save() {
    if (!cfg) return
    setError(null); setOk(null)
    const { error } = await supabase.from('app_settings').update({ value: cfg, updated_at: new Date().toISOString() }).eq('key', 'inteligencia')
    if (error) setError(error.message); else setOk('Configuração salva. Vale a partir da próxima rodada do motor.')
  }

  const platforms = Object.keys(PLATFORM)
  return (
    <>
      <PageHeader title="Inteligência digital" description="Pesquisa de site, Instagram, Facebook, Perfil no Google, LinkedIn e WhatsApp, com índice de confiança e evidências."
        actions={<>
          {isAdmin && cfg && (cfg.pausado
            ? <Button onClick={() => pause(false)}><Play className="h-4 w-4" /> Retomar</Button>
            : <Button variant="outline" onClick={() => pause(true)}><Pause className="h-4 w-4" /> Pausar</Button>)}
          <Button variant="outline" onClick={load} disabled={loading}>{loading ? <Loader2 className="h-4 w-4 animate-spin" /> : <RefreshCw className="h-4 w-4" />}</Button>
        </>} />
      {error && <Alert tone="error" className="mb-4">{error}</Alert>}
      {ok && <Alert tone="info" className="mb-4">{ok}</Alert>}
      {cfg?.pausado && <Alert tone="warning" className="mb-4" title="Motor pausado">Nenhuma pesquisa nova é feita até um administrador retomar.</Alert>}

      <div className="mb-6 grid gap-4 md:grid-cols-3">
        {ints.map((i) => (
          <Card key={i.key}>
            <CardHeader><CardDescription>{i.label}</CardDescription>
              <CardTitle className="flex items-center gap-2 text-base">
                <Badge variant={i.status === 'ativo' ? 'success' : i.status === 'erro' ? 'danger' : 'outline'}>
                  {i.status === 'ativo' ? 'Ativo' : i.status === 'erro' ? 'Erro' : 'Não configurado'}</Badge>
              </CardTitle></CardHeader>
            <CardContent className="text-xs text-muted-foreground">
              {String(i.details?.descricao ?? '')}{i.last_seen_at ? ` · último sinal ${formatDateTime(i.last_seen_at)}` : ''}
              {i.key !== 'inteligencia' && s?.uso_hoje?.[i.key] && <p className="mt-1">Hoje: {nf.format(s.uso_hoje[i.key].consultas)} consultas · US$ {Number(s.uso_hoje[i.key].custo_usd).toFixed(2)} · {s.uso_hoje[i.key].erros} erros</p>}
              {i.key !== 'inteligencia' && s?.uso_mes?.[i.key] && <p>No mês: {nf.format(s.uso_mes[i.key].consultas)} consultas · US$ {Number(s.uso_mes[i.key].custo_usd).toFixed(2)}</p>}
            </CardContent>
          </Card>
        ))}
      </div>
      {ints.some((i) => i.key !== 'inteligencia' && i.status !== 'ativo') && (
        <Alert tone="info" className="mb-6" title="Provedores pagos não configurados">
          Sem as chaves, o motor só verifica o domínio do e-mail cadastral e audita o site encontrado: Instagram, Facebook, LinkedIn e Perfil no Google
          ficam <strong>pendentes</strong> (nunca “não localizado”). Para ativar, crie no servidor do worker as variáveis
          <code className="mx-1">GOOGLE_PLACES_API_KEY</code> e/ou <code className="mx-1">BRAVE_SEARCH_API_KEY</code> (no GitHub: Secrets do repositório). Os limites e o orçamento abaixo controlam o custo.
        </Alert>
      )}

      <div className="mb-6 grid gap-4 lg:grid-cols-3">
        <Card>
          <CardHeader><CardTitle>Fila de pesquisa</CardTitle></CardHeader>
          <CardContent className="space-y-1 text-sm">
            {[['pendente', 'Pendentes'], ['em_processamento', 'Em processamento'], ['concluido', 'Concluídas'], ['erro', 'Com erro (nova tentativa)']].map(([k, v]) => (
              <p key={k} className="flex justify-between"><span className="text-muted-foreground">{v}</span><span className="tabular-nums">{nf.format(s?.fila?.[k] ?? 0)}</span></p>
            ))}
            <p className="flex justify-between border-t pt-1"><span className="text-muted-foreground">Ainda fora da fila</span><span className="tabular-nums">{nf.format(s?.sem_fila ?? 0)}</span></p>
            <p className="pt-1 text-xs text-muted-foreground">Prioridade: empresas recém-abertas, maior pontuação e leads em atendimento.</p>
          </CardContent>
        </Card>
        <Card className="lg:col-span-2">
          <CardHeader><CardTitle>Resultados por canal</CardTitle></CardHeader>
          <CardContent>
            <Table>
              <THead><tr><TH>Canal</TH>{Object.values(CHANNEL_STATUS).map((c) => <TH key={c.label} className="text-right">{c.label}</TH>)}</tr></THead>
              <TBody>
                {platforms.map((p) => (
                  <TR key={p}><TD>{PLATFORM[p]}</TD>
                    {Object.keys(CHANNEL_STATUS).map((k) => <TD key={k} className="text-right tabular-nums">{nf.format(s?.canais?.[p]?.[k] ?? 0)}</TD>)}
                  </TR>
                ))}
              </TBody>
            </Table>
          </CardContent>
        </Card>
      </div>

      {isManager && cfg && (
        <Card className="mb-6">
          <CardHeader><CardTitle>Configuração</CardTitle><CardDescription>Lotes, concorrência, limites diários por provedor, custo e reverificação.</CardDescription></CardHeader>
          <CardContent className="grid gap-3 text-sm md:grid-cols-4">
            {([['lote', 'Empresas por lote'], ['concorrencia', 'Pesquisas simultâneas'], ['enfileirar_por_rodada', 'Novas na fila por rodada'], ['cache_dias', 'Cache (dias)'],
              ['confianca_verificado', 'Confiança p/ verificado'], ['confianca_possivel', 'Confiança p/ possível'], ['custo_maximo_diario_usd', 'Orçamento diário (US$)']] as [keyof Cfg, string][]).map(([k, label]) => (
              <div key={k} className="space-y-1"><Label>{label}</Label>
                <Input type="number" disabled={!isAdmin} value={Number(cfg[k])} onChange={(e) => setCfg({ ...cfg, [k]: Number(e.target.value) })} /></div>
            ))}
            {['google_places', 'brave'].map((p) => (
              <div key={p} className="space-y-1"><Label>Limite diário {p === 'brave' ? 'Brave' : 'Google Places'}</Label>
                <Input type="number" disabled={!isAdmin} value={cfg.limites_diarios?.[p] ?? 0}
                  onChange={(e) => setCfg({ ...cfg, limites_diarios: { ...cfg.limites_diarios, [p]: Number(e.target.value) } })} /></div>
            ))}
            {['google_places', 'brave'].map((p) => (
              <div key={p + 'c'} className="space-y-1"><Label>Custo por consulta {p === 'brave' ? 'Brave' : 'Google'} (US$)</Label>
                <Input type="number" step="0.001" disabled={!isAdmin} value={cfg.custo_por_consulta_usd?.[p] ?? 0}
                  onChange={(e) => setCfg({ ...cfg, custo_por_consulta_usd: { ...cfg.custo_por_consulta_usd, [p]: Number(e.target.value) } })} /></div>
            ))}
            {isAdmin && <div className="md:col-span-4"><Button onClick={save}><Save className="h-4 w-4" /> Salvar configuração</Button></div>}
          </CardContent>
        </Card>
      )}

      <Card>
        <CardHeader><CardTitle>Histórico de execução</CardTitle></CardHeader>
        <Table>
          <THead><tr><TH>Início</TH><TH>Situação</TH><TH>Empresas</TH><TH>Erros</TH><TH>Encontrados</TH><TH>Consultas</TH><TH>Custo</TH></tr></THead>
          <TBody>
            {runs.length === 0 && <tr><TD colSpan={7} className="py-6 text-center text-muted-foreground">Nenhuma rodada ainda.</TD></tr>}
            {runs.map((r) => (
              <TR key={r.id}>
                <TD className="text-xs">{formatDateTime(r.started_at)}</TD>
                <TD><Badge variant={r.status === 'concluido' ? 'success' : r.status === 'falhou' ? 'danger' : 'secondary'}>{r.status}</Badge>{r.message && <p className="text-xs text-red-700">{r.message}</p>}</TD>
                <TD className="tabular-nums">{nf.format(r.processed)}</TD>
                <TD className="tabular-nums">{nf.format(r.errors)}</TD>
                <TD className="text-xs">{Object.entries(r.found ?? {}).map(([k, v]) => `${PLATFORM[k] ?? k}: ${v}`).join(' · ') || '—'}</TD>
                <TD className="text-xs">{Object.entries(r.calls ?? {}).map(([k, v]) => `${k}: ${v}`).join(' · ') || '—'}</TD>
                <TD className="tabular-nums">US$ {Number(r.cost_usd).toFixed(2)}</TD>
              </TR>
            ))}
          </TBody>
        </Table>
      </Card>
    </>
  )
}
