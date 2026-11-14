import { Navigate, useLocation } from 'react-router-dom'
import type { ReactNode } from 'react'
import { Loader2 } from 'lucide-react'
import { useAuth } from '@/hooks/useAuth'
import type { AppRole } from '@/lib/types'
import { Alert } from '@/components/ui/alert'

export function FullScreenLoader() {
  return (
    <div className="flex min-h-screen items-center justify-center">
      <Loader2 className="h-6 w-6 animate-spin text-primary" />
    </div>
  )
}

export function RequireAuth({ children }: { children: ReactNode }) {
  const { session, profile, loading } = useAuth()
  const location = useLocation()
  if (loading) return <FullScreenLoader />
  if (!session) return <Navigate to="/login" replace state={{ from: location.pathname }} />
  if (!profile) return <FullScreenLoader />
  if (!profile.active) {
    return (
      <div className="mx-auto max-w-md p-8">
        <Alert tone="warning" title="Acesso desativado">
          Seu usuário está inativo. Fale com o administrador do JS Lead Hunter.
        </Alert>
      </div>
    )
  }
  return <>{children}</>
}

export function RequireRole({ roles, children }: { roles: AppRole[]; children: ReactNode }) {
  const { hasRole } = useAuth()
  if (!hasRole(...roles)) {
    return (
      <Alert tone="warning" title="Sem permissão">
        Seu perfil de acesso não permite abrir esta área.
      </Alert>
    )
  }
  return <>{children}</>
}
