import { useState, type FormEvent } from 'react'
import { useNavigate } from 'react-router-dom'
import { supabase } from '@/lib/supabase'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Alert } from '@/components/ui/alert'

/** Destino do link de convite / redefinição de senha enviado pelo Supabase. */
export default function ResetPassword() {
  const navigate = useNavigate()
  const [password, setPassword] = useState('')
  const [confirm, setConfirm] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    if (password.length < 10) return setError('Use pelo menos 10 caracteres.')
    if (password !== confirm) return setError('As senhas não conferem.')
    setBusy(true)
    const { error } = await supabase.auth.updateUser({ password })
    setBusy(false)
    if (error) setError(error.message)
    else navigate('/', { replace: true })
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-sidebar p-4">
      <form onSubmit={onSubmit} className="w-full max-w-sm space-y-4 rounded-xl bg-card p-8 shadow-xl">
        <h1 className="text-lg font-semibold">Definir nova senha</h1>
        <div className="space-y-1.5">
          <Label htmlFor="p1">Nova senha</Label>
          <Input id="p1" type="password" autoComplete="new-password" value={password} onChange={(e) => setPassword(e.target.value)} />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="p2">Confirmar senha</Label>
          <Input id="p2" type="password" autoComplete="new-password" value={confirm} onChange={(e) => setConfirm(e.target.value)} />
        </div>
        {error && <Alert tone="error">{error}</Alert>}
        <Button type="submit" className="w-full" disabled={busy}>Salvar senha</Button>
      </form>
    </div>
  )
}
