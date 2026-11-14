import { clsx, type ClassValue } from 'clsx'
import { twMerge } from 'tailwind-merge'

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs))
}

/** Formata CNPJ numérico ou alfanumérico: XX.XXX.XXX/XXXX-XX */
export function formatCnpj(cnpj: string | null | undefined) {
  if (!cnpj || cnpj.length !== 14) return cnpj ?? ''
  return `${cnpj.slice(0, 2)}.${cnpj.slice(2, 5)}.${cnpj.slice(5, 8)}/${cnpj.slice(8, 12)}-${cnpj.slice(12)}`
}

/** Normaliza entrada de CNPJ básico (8) ou completo (14), aceitando letras. */
export function normalizeCnpj(value: string) {
  return value.toUpperCase().replace(/[^0-9A-Z]/g, '')
}

export const nf = new Intl.NumberFormat('pt-BR')
export const brl = new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' })

export function formatDate(d: string | null | undefined) {
  if (!d) return '—'
  const [y, m, day] = d.slice(0, 10).split('-')
  return `${day}/${m}/${y}`
}

export function formatDateTime(d: string | null | undefined) {
  if (!d) return '—'
  return new Date(d).toLocaleString('pt-BR')
}

export const PORTE_LABEL: Record<string, string> = {
  '00': 'Não informado',
  '01': 'Microempresa',
  '03': 'Pequeno porte',
  '05': 'Demais',
}

export const UFS = [
  'AC', 'AL', 'AM', 'AP', 'BA', 'CE', 'DF', 'ES', 'GO', 'MA', 'MG', 'MS', 'MT', 'PA',
  'PB', 'PE', 'PI', 'PR', 'RJ', 'RN', 'RO', 'RR', 'RS', 'SC', 'SE', 'SP', 'TO',
]
