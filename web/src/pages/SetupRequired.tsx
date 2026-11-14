import { Alert } from '@/components/ui/alert'

export default function SetupRequired() {
  return (
    <div className="mx-auto max-w-xl p-8">
      <h1 className="mb-4 text-2xl font-semibold">JS Lead Hunter — configuração pendente</h1>
      <Alert tone="warning" title="Supabase não configurado">
        <p>
          O frontend não encontrou as variáveis <code>VITE_SUPABASE_URL</code> e{' '}
          <code>VITE_SUPABASE_ANON_KEY</code>. Copie <code>.env.example</code> para <code>.env.local</code>,
          preencha com os dados do projeto Supabase e reinicie o servidor.
        </p>
        <p className="mt-2">Nenhum dado é exibido enquanto a conexão não estiver configurada.</p>
      </Alert>
    </div>
  )
}
