import * as React from 'react'
import { AlertTriangle, Info, XCircle } from 'lucide-react'
import { cn } from '@/lib/utils'

const styles = {
  info: 'border-blue-200 bg-blue-50 text-blue-900',
  warning: 'border-amber-200 bg-amber-50 text-amber-900',
  error: 'border-red-200 bg-red-50 text-red-900',
}
const icons = { info: Info, warning: AlertTriangle, error: XCircle }

export function Alert({
  tone = 'info', title, children, className,
}: { tone?: keyof typeof styles; title?: string; children?: React.ReactNode; className?: string }) {
  const Icon = icons[tone]
  return (
    <div className={cn('flex gap-3 rounded-lg border p-4 text-sm', styles[tone], className)}>
      <Icon className="mt-0.5 h-4 w-4 shrink-0" />
      <div className="space-y-1">
        {title && <p className="font-semibold">{title}</p>}
        {children && <div className="leading-relaxed">{children}</div>}
      </div>
    </div>
  )
}
