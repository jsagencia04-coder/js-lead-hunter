import * as React from 'react'
import { cn } from '@/lib/utils'

export function Table({ className, ...p }: React.TableHTMLAttributes<HTMLTableElement>) {
  return (
    <div className="w-full overflow-x-auto">
      <table className={cn('w-full caption-bottom text-sm', className)} {...p} />
    </div>
  )
}
export function THead(p: React.HTMLAttributes<HTMLTableSectionElement>) {
  return <thead className="border-b bg-muted/50" {...p} />
}
export function TBody(p: React.HTMLAttributes<HTMLTableSectionElement>) {
  return <tbody className="divide-y" {...p} />
}
export function TR({ className, ...p }: React.HTMLAttributes<HTMLTableRowElement>) {
  return <tr className={cn('hover:bg-muted/30', className)} {...p} />
}
export function TH({ className, ...p }: React.ThHTMLAttributes<HTMLTableCellElement>) {
  return <th className={cn('h-10 px-3 text-left align-middle text-xs font-semibold text-muted-foreground', className)} {...p} />
}
export function TD({ className, ...p }: React.TdHTMLAttributes<HTMLTableCellElement>) {
  return <td className={cn('px-3 py-2.5 align-middle', className)} {...p} />
}
