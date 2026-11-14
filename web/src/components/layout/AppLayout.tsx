import { useState, type ReactNode } from 'react'
import { NavLink, Outlet } from 'react-router-dom'
import {
  LayoutDashboard, Users, Map, KanbanSquare, DatabaseZap, ShieldCheck, LogOut, Menu, X, Crosshair,
} from 'lucide-react'
import { useAuth } from '@/hooks/useAuth'
import { ROLE_LABEL, type AppRole } from '@/lib/types'
import { cn } from '@/lib/utils'
import { Button } from '@/components/ui/button'

interface NavItem {
  to: string
  label: string
  icon: typeof LayoutDashboard
  roles?: AppRole[]
}

const NAV: NavItem[] = [
  { to: '/', label: 'Dashboard', icon: LayoutDashboard },
  { to: '/leads', label: 'Leads', icon: Users },
  { to: '/mapa', label: 'Mapa do Brasil', icon: Map },
  { to: '/crm', label: 'CRM', icon: KanbanSquare },
  { to: '/importacao', label: 'Central de importação', icon: DatabaseZap, roles: ['admin', 'gestor'] },
  { to: '/admin', label: 'Administração', icon: ShieldCheck, roles: ['admin'] },
]

export function AppLayout() {
  const { profile, signOut, hasRole } = useAuth()
  const [open, setOpen] = useState(false)

  const items = NAV.filter((i) => !i.roles || hasRole(...i.roles))

  const sidebar = (
    <nav className="flex h-full flex-col gap-1 p-3">
      <div className="mb-4 flex items-center gap-2 px-2 py-3">
        <div className="flex h-8 w-8 items-center justify-center rounded-md bg-primary">
          <Crosshair className="h-4 w-4 text-white" />
        </div>
        <div>
          <p className="text-sm font-semibold text-white">JS Lead Hunter</p>
          <p className="text-[11px] text-sidebar-foreground/60">JS Designer</p>
        </div>
      </div>
      {items.map((item) => (
          <NavLink
            key={item.to}
            to={item.to}
            end={item.to === '/'}
            onClick={() => setOpen(false)}
            className={({ isActive }) =>
              cn(
                'flex items-center gap-3 rounded-md px-3 py-2 text-sm transition-colors',
                isActive ? 'bg-white/10 font-medium text-white' : 'text-sidebar-foreground hover:bg-white/5 hover:text-white',
              )
            }
          >
            <item.icon className="h-4 w-4" />
            {item.label}
          </NavLink>
      ))}
      <div className="mt-auto border-t border-white/10 px-2 pt-3">
        <p className="truncate text-sm text-white">{profile?.full_name ?? profile?.email}</p>
        <p className="mb-3 text-xs text-sidebar-foreground/60">{profile ? ROLE_LABEL[profile.role] : ''}</p>
        <button
          onClick={signOut}
          className="flex w-full items-center gap-2 rounded-md px-1 py-1.5 text-sm text-sidebar-foreground hover:text-white"
        >
          <LogOut className="h-4 w-4" /> Sair
        </button>
      </div>
    </nav>
  )

  return (
    <div className="flex min-h-screen">
      <aside className="hidden w-64 shrink-0 bg-sidebar lg:block">
        <div className="sticky top-0 h-screen">{sidebar}</div>
      </aside>

      {open && (
        <div className="fixed inset-0 z-40 lg:hidden">
          <div className="absolute inset-0 bg-black/40" onClick={() => setOpen(false)} />
          <aside className="absolute left-0 top-0 h-full w-64 bg-sidebar">{sidebar}</aside>
        </div>
      )}

      <div className="flex min-w-0 flex-1 flex-col">
        <header className="flex h-14 items-center gap-3 border-b bg-card px-4 lg:hidden">
          <Button variant="ghost" size="icon" onClick={() => setOpen(!open)} aria-label="Abrir menu">
            {open ? <X className="h-5 w-5" /> : <Menu className="h-5 w-5" />}
          </Button>
          <span className="font-semibold">JS Lead Hunter</span>
        </header>
        <main className="flex-1 p-4 md:p-8">
          <Outlet />
        </main>
      </div>
    </div>
  )
}

export function PageHeader({ title, description, actions }: { title: string; description?: string; actions?: ReactNode }) {
  return (
    <div className="mb-6 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">{title}</h1>
        {description && <p className="mt-1 text-sm text-muted-foreground">{description}</p>}
      </div>
      {actions && <div className="flex flex-wrap gap-2">{actions}</div>}
    </div>
  )
}
