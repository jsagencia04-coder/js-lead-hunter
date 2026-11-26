// Cache local das telas: ao recarregar a página, mostra na hora os últimos dados
// carregados e atualiza em segundo plano. Se a atualização falhar, os dados salvos
// continuam na tela com o horário em que foram carregados.
// Escopo por usuário; apagado ao sair do sistema (clearCache).
import { useCallback, useEffect, useRef, useState } from 'react'

const PREFIX = 'jslh:v1:'
const MAX_AGE_MS = 7 * 24 * 3600 * 1000
let scope = 'anon'

export function setCacheScope(userId: string | null | undefined) {
  scope = userId || 'anon'
}

interface Entry<T> { at: number; data: T }

function fullKey(key: string) {
  return `${PREFIX}${scope}:${key}`
}

export function readCache<T>(key: string): Entry<T> | null {
  try {
    const raw = window.localStorage.getItem(fullKey(key))
    if (!raw) return null
    const e = JSON.parse(raw) as Entry<T>
    if (!e || typeof e.at !== 'number' || Date.now() - e.at > MAX_AGE_MS) return null
    return e
  } catch {
    return null
  }
}

export function writeCache<T>(key: string, data: T) {
  try {
    window.localStorage.setItem(fullKey(key), JSON.stringify({ at: Date.now(), data }))
  } catch {
    // armazenamento cheio ou indisponível: segue sem cache, removendo entradas antigas
    try {
      Object.keys(window.localStorage).filter((k) => k.startsWith(PREFIX)).slice(0, 20)
        .forEach((k) => window.localStorage.removeItem(k))
    } catch { /* sem armazenamento */ }
  }
}

export function clearCache() {
  try {
    Object.keys(window.localStorage).filter((k) => k.startsWith(PREFIX)).forEach((k) => window.localStorage.removeItem(k))
  } catch { /* sem armazenamento */ }
}

export type Fetcher<T> = () => Promise<{ data: T | null; error: string | null }>

/**
 * Dados com cache: `data` começa com o que foi salvo (se houver) e é substituído
 * quando a consulta termina. `savedAt` = quando o dado exibido foi carregado.
 */
export function useCachedQuery<T>(key: string | null, fetcher: Fetcher<T>, deps: unknown[]) {
  const initial = key ? readCache<T>(key) : null
  const [data, setData] = useState<T | null>(initial?.data ?? null)
  const [savedAt, setSavedAt] = useState<number | null>(initial?.at ?? null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const seq = useRef(0)

  const run = useCallback(async () => {
    const my = ++seq.current
    if (key) {
      const c = readCache<T>(key)
      if (c) { setData(c.data); setSavedAt(c.at) }
    }
    setLoading(true)
    setError(null)
    let res: { data: T | null; error: string | null }
    try {
      res = await fetcher()
    } catch (e) {
      res = { data: null, error: e instanceof Error ? e.message : String(e) }
    }
    if (my !== seq.current) return
    if (res.error) {
      setError(res.error)
    } else if (res.data !== null && res.data !== undefined) {
      setData(res.data)
      setSavedAt(Date.now())
      if (key) writeCache(key, res.data)
    }
    setLoading(false)
  }, [key, ...deps]) // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => { run() }, [run])
  return { data, loading, error, savedAt, reload: run }
}

/** Traduz mensagens técnicas frequentes do banco para o usuário. */
export function friendlyError(msg: string | null | undefined): string | null {
  if (!msg) return null
  if (/statement timeout|canceling statement/i.test(msg)) {
    return 'A consulta demorou mais que o limite do banco e foi interrompida. Tente novamente em instantes.'
  }
  if (/Failed to fetch|NetworkError|Load failed/i.test(msg)) return 'Sem conexão com o servidor. Verifique a internet e tente novamente.'
  if (/does not exist|Could not find the function|schema cache/i.test(msg)) {
    return 'Esta tela depende de uma atualização do banco que ainda não foi aplicada pelo worker.'
  }
  return msg
}
