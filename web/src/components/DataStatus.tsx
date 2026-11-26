// Aviso padrão sobre os dados da tela: carregando, dados salvos ou erro.
import { Loader2 } from 'lucide-react'
import { friendlyError } from '@/lib/cache'
import { formatDateTime } from '@/lib/utils'
import { Alert } from '@/components/ui/alert'

export function DataStatus({ loading, error, savedAt, hasData, className = 'mb-4' }: {
  loading: boolean; error: string | null; savedAt: number | null; hasData: boolean; className?: string
}) {
  const msg = friendlyError(error)
  if (msg && hasData) {
    return (
      <Alert tone="warning" className={className}>
        Mostrando os dados carregados em {savedAt ? formatDateTime(new Date(savedAt).toISOString()) : '—'}. Não foi possível atualizar: {msg}
      </Alert>
    )
  }
  if (msg) return <Alert tone="error" className={className}>{msg}</Alert>
  if (loading && hasData) {
    return (
      <p className={`${className} flex items-center gap-2 text-xs text-muted-foreground`}>
        <Loader2 className="h-3 w-3 animate-spin" /> Atualizando… (exibindo dados de {savedAt ? formatDateTime(new Date(savedAt).toISOString()) : 'antes'})
      </p>
    )
  }
  return null
}
