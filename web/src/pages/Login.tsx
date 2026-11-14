import { useState, type FormEvent } from 'react'
import { Navigate, useLocation } from 'react-router-dom'
import { Crosshair, Loader2 } from 'lucide-react'
import { useAuth } from '@/hooks/useAuth'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Alert } from '@/components/ui/alert'

export default function Login() {
  const { session, signIn, sendPasswordReset } = useAuth()
  const location = useLocation()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [mode, setMode] = useState<'login' | 'reset'>('login')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [info, setInfo] = useState<string | null>(null)

  if (session) {
    const from = (location.state as { from?: string } | null)?.from ?? '/'
    return <Navigate to={from} replace />
  }

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError(null)
    setInfo(null)
    if (mode === 'login') {
      const err = await signIn(email.trim(), password)
      if (err) setError(err)
    } else {
      const err = await sendPasswordReset(email.trim())
      if (err) setError(err)
      else setInfo('Se o e-mail estiver cadastrado, você receberá um link para criar uma nova senha.')
    }
    setBusy(false)
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-sidebar p-4">
      <div className="w-full max-w-sm rounded-xl bg-card p-8 shadow-xl">
        <div className="mb-6 flex items-center gap-3">
          <div className="flex h-10 w-10 items-center justify-center rounded-lg bg-primary">
            <Crosshair className="h-5 w-5 text-white" />
          </div>
          <div>
            <h1 className="text-lg font-semibold">JS Lead Hunter</h1>
            <p className="text-xs text-muted-foreground">Inteligência comercial · JS Designer</p>
          </div>
        </div>

        <form onSubmit={onSubmit} className="space-y-4">
          <div className="space-y-1.5">
            <Label htmlFor="email">E-mail</Label>
            <Input id="email" type="email" autoComplete="email" required value={email}
              onChange={(e) => setEmail(e.target.value)} />
          </div>
          {mode === 'login' && (
            <div className="space-y-1.5">
              <Label htmlFor="password">Senha</Label>
              <Input id="password" type="password" autoComplete="current-password" required value={password}
                onChange={(e) => setPassword(e.target.value)} />
            </div>
          )}
          {error && <Alert tone="error">{error}</Alert>}
          {info && <Alert tone="info">{info}</Alert>}
          <Button type="submit" className="w-full" disabled={busy}>
            {busy && <Loader2 className="h-4 w-4 animate-spin" />}
            {mode === 'login' ? 'Entrar' : 'Enviar link de redefinição'}
          </Button>
        </form>

        <button
          type="button"
          onClick={() => { setMode(mode === 'login' ? 'reset' : 'login'); setError(null); setInfo(null) }}
          className="mt-4 w-full text-center text-xs text-muted-foreground hover:text-foreground"
        >
          {mode === 'login' ? 'Esqueci minha senha' : 'Voltar ao login'}
        </button>
        <p className="mt-6 text-center text-[11px] text-muted-foreground">
          Acesso restrito. Novos usuários são convidados pelo administrador.
        </p>
      </div>
    </div>
  )
}
