import * as React from 'react'
import { cva, type VariantProps } from 'class-variance-authority'
import { cn } from '@/lib/utils'

const badgeVariants = cva('inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium', {
  variants: {
    variant: {
      default: 'bg-primary/10 text-primary',
      secondary: 'bg-secondary text-secondary-foreground',
      success: 'bg-emerald-100 text-emerald-800',
      warning: 'bg-amber-100 text-amber-800',
      danger: 'bg-red-100 text-red-800',
      outline: 'border text-muted-foreground',
    },
  },
  defaultVariants: { variant: 'default' },
})

export function Badge({ className, variant, ...p }: React.HTMLAttributes<HTMLSpanElement> & VariantProps<typeof badgeVariants>) {
  return <span className={cn(badgeVariants({ variant }), className)} {...p} />
}
