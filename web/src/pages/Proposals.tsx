import { useCallback, useEffect, useState } from 'react'
import { Download, Loader2, RefreshCw } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { brl, formatDate, formatDateTime, nf } from '@/lib/utils'
import { downloadCsv, useOpenLead } from '@/lib/crm'
import { PageHeader } from '@/components/layout/AppLayout'
import { Button } from '@/components/ui/button'
import { Select } from '@/components/ui/select'
import { Badge } from '@/components/ui/badge'
import { Alert } from '@/components/ui/alert'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Table, TBody, TD, TH, THead, TR } from '@/components/ui/table'

const STATUS: Record<string, { label: string; v: 'outline' | 'secondary' | 'warning' | 'success' | 'danger' }> = {
  rascunho: { label: 'Rascunho', v: 'outline' }, enviada: { label: 'Enviada', v: 'secondary' },
  em_negociacao: { label: 'Em negociação', v: 'warning' }, aceita: { label: 'Aceita', v: 'success' },
  recusada: { label: 'Recusada', v: 'danger' }, expirada: { label: 'Expirada', v: 'outline' },
}

interface Row {
  id: string; lead_id: string; title: string; amount: number | null; status: string; sent_at: string | null
  valid_until: string | null; decided_at: string | null; created_at: string
  leads: { cnpj: string; establishments: { nome_fantasia: string | null; uf: string | null }; companies: { razao_social: string | null } }
}

export default function Proposals() {
  const openLead = useOpenLead()
  const [status, setStatus] = useState('')
  const [rows, setRows] = useState<Row[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(async () => {
    setLoading(true)
    let q = supabase.from('lead_proposals')
      .select('id,lead_id,title,amount,status,sent_at,valid_until,decided_at,created_at, leads!inner(cnpj, establishments!inner(nome_fantasia,uf), companies!inner(razao_social))')
    if (status) q = q.eq('status', status)
    const { data, error } = await q.order('created_at', { ascending: false }).limit(500)
    if (error) setError(error.message)
    setRows((data as unknown as Row[]) ?? [])
    setLoading(false)
  }, [status])
  useEffect(() => { load() }, [load])

  const sum = (f: (r: Row) => boolean) => rows.filter(f).reduce((a, r) => a + Number(r.amount ?? 0), 0)
  const today = new Date().toISOString().slice(0, 10)

  return (
    <>
      <PageHeader title="Propostas" description="Todas as propostas comerciais. Para criar, abra a ficha da empresa."
        actions={<>
          <Select value={status} onChange={(e) => setStatus(e.target.value)} className="w-44" aria-label="Situação">
            <option value="">Todas as situações</option>
            {Object.entries(STATUS).map(([k, v]) => <option key={k} value={k}>{v.label}</option>)}
          </Select>
          <Button variant="outline" onClick={() => downloadCsv('propostas.csv', [['Empresa', 'CNPJ', 'Proposta', 'Valor', 'Situação', 'Enviada', 'Válida até', 'Decidida'],
            ...rows.map((r) => [r.leads.establishments.nome_fantasia || r.leads.companies.razao_social, r.leads.cnpj, r.title, r.amount,
              STATUS[r.status]?.label, r.sent_at, r.valid_until, r.decided_at])])}><Download className="h-4 w-4" /> Excel</Button>
          <Button variant="outline" onClick={load} disabled={loading}>{loading ? <Loader2 className="h-4 w-4 animate-spin" /> : <RefreshCw className="h-4 w-4" />}</Button>
        </>} />
      {error && <Alert tone="error" className="mb-4">{error}</Alert>}
      <div className="mb-4 grid grid-cols-2 gap-4 md:grid-cols-4">
        {[['Propostas', nf.format(rows.length)], ['Em aberto (enviadas + negociação)', brl.format(sum((r) => ['enviada', 'em_negociacao'].includes(r.status)))],
          ['Aceitas', brl.format(sum((r) => r.status === 'aceita'))], ['Recusadas', brl.format(sum((r) => r.status === 'recusada'))]].map(([k, v]) => (
          <Card key={k}><CardHeader><CardDescription>{k}</CardDescription><CardTitle className="text-xl">{v}</CardTitle></CardHeader></Card>
        ))}
      </div>
      <Card>
        <Table>
          <THead><tr><TH>Empresa</TH><TH>Proposta</TH><TH>Valor</TH><TH>Situação</TH><TH>Enviada</TH><TH>Validade</TH><TH>Decisão</TH></tr></THead>
          <TBody>
            {rows.length === 0 && <tr><TD colSpan={7} className="py-8 text-center text-muted-foreground">Nenhuma proposta.</TD></tr>}
            {rows.map((r) => (
              <TR key={r.id} className="cursor-pointer" onClick={() => openLead(r.lead_id)}>
                <TD className="font-medium">{r.leads.establishments.nome_fantasia || r.leads.companies.razao_social}</TD>
                <TD>{r.title}</TD>
                <TD className="tabular-nums">{r.amount != null ? brl.format(r.amount) : '—'}</TD>
                <TD><Badge variant={STATUS[r.status]?.v}>{STATUS[r.status]?.label}</Badge></TD>
                <TD className="text-xs">{formatDateTime(r.sent_at)}</TD>
                <TD className={`text-xs ${r.valid_until && r.valid_until < today && ['enviada', 'em_negociacao'].includes(r.status) ? 'text-red-700' : ''}`}>{formatDate(r.valid_until)}</TD>
                <TD className="text-xs">{formatDateTime(r.decided_at)}</TD>
              </TR>
            ))}
          </TBody>
        </Table>
        <CardContent className="pt-3 text-xs text-muted-foreground">Validade em vermelho: proposta em aberto com prazo vencido.</CardContent>
      </Card>
    </>
  )
}
