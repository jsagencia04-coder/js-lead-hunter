// Edge Function: convida um usuário para o JS Lead Hunter.
// A chave service_role fica só aqui (variável de ambiente do Supabase),
// nunca no frontend. Somente administradores ativos podem convidar.
import { createClient } from 'npm:@supabase/supabase-js@2'

const ROLES = ['admin', 'gestor', 'comercial', 'leitura']

const cors = {
  'Access-Control-Allow-Origin': Deno.env.get('ALLOWED_ORIGIN') ?? '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ error: 'Método não permitido' }, 405)

  const url = Deno.env.get('SUPABASE_URL')!
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

  // 1. Identifica quem chamou, com o JWT do próprio usuário
  const authHeader = req.headers.get('Authorization') ?? ''
  const caller = createClient(url, anonKey, { global: { headers: { Authorization: authHeader } } })
  const { data: userData, error: userErr } = await caller.auth.getUser()
  if (userErr || !userData.user) return json({ error: 'Não autenticado' }, 401)

  const { data: me } = await caller.from('profiles').select('role, active').eq('id', userData.user.id).single()
  if (!me || !me.active || me.role !== 'admin') return json({ error: 'Apenas administradores podem convidar usuários' }, 403)

  // 2. Valida a entrada
  const body = await req.json().catch(() => ({}))
  const email = String(body.email ?? '').trim().toLowerCase()
  const fullName = String(body.full_name ?? '').trim() || null
  const role = String(body.role ?? 'leitura')
  const redirectTo = typeof body.redirect_to === 'string' ? body.redirect_to : undefined
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return json({ error: 'E-mail inválido' }, 400)
  if (!ROLES.includes(role)) return json({ error: 'Perfil inválido' }, 400)

  // 3. Convida com a service_role e define o perfil
  const admin = createClient(url, serviceKey, { auth: { persistSession: false } })
  const { data: invited, error: invErr } = await admin.auth.admin.inviteUserByEmail(email, {
    data: { full_name: fullName },
    redirectTo,
  })
  if (invErr) return json({ error: invErr.message }, 400)

  const { error: profErr } = await admin
    .from('profiles')
    .update({ role, full_name: fullName, active: true })
    .eq('id', invited.user.id)
  if (profErr) return json({ error: `Usuário convidado, mas o perfil não foi ajustado: ${profErr.message}` }, 500)

  await admin.from('audit_logs').insert({
    actor_id: userData.user.id, action: 'INSERT', table_name: 'auth.users',
    record_id: invited.user.id, new_data: { email, role, via: 'invite-user' },
  })

  return json({ ok: true, user_id: invited.user.id })
})
