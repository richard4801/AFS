// Senior Editor PIN access.
// Provisions a single hidden SE account and gates it behind a 4-digit PIN
// (PBKDF2-hashed, rate-limited with lockout). On success it mints a real
// Supabase session for the SE account and returns the tokens to the client.
//
// Required secrets (Supabase → Edge Functions → Manage secrets):
//   SE_EMAIL         e.g. senior-editor@apexfictionstudio.com  (she never sees it)
//   SE_PASSWORD      a long random string (the account's real password)
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / SUPABASE_ANON_KEY are auto-provided.
// (SE_SETUP_TOKEN is no longer used — PIN setup is allowed whenever no PIN is
//  set, which the admin controls via the "Reset SE PIN" button.)

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const enc = new TextEncoder()

function b64(bytes: Uint8Array): string { return btoa(String.fromCharCode(...bytes)) }
function unb64(s: string): Uint8Array { return Uint8Array.from(atob(s), c => c.charCodeAt(0)) }

async function derive(pin: string, salt: Uint8Array, iterations: number): Promise<string> {
  const key = await crypto.subtle.importKey('raw', enc.encode(pin), 'PBKDF2', false, ['deriveBits'])
  const bits = await crypto.subtle.deriveBits({ name: 'PBKDF2', salt, iterations, hash: 'SHA-256' }, key, 256)
  return b64(new Uint8Array(bits))
}
async function hashPin(pin: string): Promise<string> {
  const salt = crypto.getRandomValues(new Uint8Array(16))
  const iterations = 120000
  const hash = await derive(pin, salt, iterations)
  return `pbkdf2$${iterations}$${b64(salt)}$${hash}`
}
async function verifyPin(pin: string, stored: string): Promise<boolean> {
  const [algo, iterStr, saltB64, hashB64] = String(stored).split('$')
  if (algo !== 'pbkdf2') return false
  const got = await derive(pin, unb64(saltB64), parseInt(iterStr, 10))
  // length-safe constant-time-ish compare
  if (got.length !== hashB64.length) return false
  let diff = 0
  for (let i = 0; i < got.length; i++) diff |= got.charCodeAt(i) ^ hashB64.charCodeAt(i)
  return diff === 0
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  try {
    const url        = Deno.env.get('SUPABASE_URL')!
    const service    = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const anon        = Deno.env.get('SUPABASE_ANON_KEY')!
    const seEmail     = Deno.env.get('SE_EMAIL')
    const sePassword  = Deno.env.get('SE_PASSWORD')
    if (!seEmail || !sePassword) throw new Error('Senior Editor access is not configured yet.')

    const admin = createClient(url, service, { auth: { persistSession: false } })
    const { action, pin } = await req.json().catch(() => ({}))

    async function getSeUser() {
      const { data } = await admin.auth.admin.listUsers({ page: 1, perPage: 200 })
      return data.users.find(u => u.email?.toLowerCase() === seEmail!.toLowerCase()) ?? null
    }
    async function ensureSeUser() {
      let u = await getSeUser()
      if (!u) {
        const { data, error } = await admin.auth.admin.createUser({
          email: seEmail, password: sePassword, email_confirm: true,
          user_metadata: { full_name: 'Christine Franklin' },
        })
        if (error) throw error
        u = data.user
      }
      await admin.from('profiles').update({ is_senior_editor: true, name: 'Christine Franklin' }).eq('id', u!.id)
      return u!
    }
    async function mintSession() {
      const c = createClient(url, anon, { auth: { persistSession: false } })
      const { data, error } = await c.auth.signInWithPassword({ email: seEmail!, password: sePassword! })
      if (error || !data.session) throw new Error('Could not establish a session.')
      return { access_token: data.session.access_token, refresh_token: data.session.refresh_token }
    }

    // Has a PIN been set yet?
    if (action === 'status') {
      const u = await getSeUser()
      if (!u) return json({ pinSet: false })
      const { data: row } = await admin.from('se_pins').select('user_id').eq('user_id', u.id).maybeSingle()
      return json({ pinSet: !!row })
    }

    // PIN creation. Allowed only when no PIN is set — which is the case on
    // first setup and after the admin resets it. No code for her to type.
    if (action === 'setup') {
      if (!/^\d{4}$/.test(pin || '')) throw new Error('Your PIN must be 4 digits.')
      const u = await ensureSeUser()
      const { data: existing } = await admin.from('se_pins').select('user_id').eq('user_id', u.id).maybeSingle()
      if (existing) throw new Error('A PIN is already set. Sign in with it, or ask your admin to reset it.')
      await admin.from('se_pins').insert({ user_id: u.id, pin_hash: await hashPin(pin) })
      return json({ ok: true, session: await mintSession() })
    }

    // Returning: verify PIN, rate-limited with lockout
    if (action === 'verify') {
      if (!/^\d{4}$/.test(pin || '')) throw new Error('Your PIN must be 4 digits.')
      const u = await getSeUser()
      if (!u) throw new Error('Senior Editor access has not been set up yet.')
      const { data: row } = await admin.from('se_pins').select('*').eq('user_id', u.id).maybeSingle()
      if (!row) throw new Error('No PIN set yet.')

      if (row.locked_until && new Date(row.locked_until) > new Date()) {
        const mins = Math.ceil((new Date(row.locked_until).getTime() - Date.now()) / 60000)
        return json({ ok: false, error: `Too many attempts. Try again in ${mins} minute${mins === 1 ? '' : 's'}.` }, 429)
      }
      if (await verifyPin(pin, row.pin_hash)) {
        await admin.from('se_pins').update({ failed_attempts: 0, locked_until: null, updated_at: new Date().toISOString() }).eq('user_id', u.id)
        return json({ ok: true, session: await mintSession() })
      }
      const attempts = (row.failed_attempts || 0) + 1
      const locked = attempts >= 5
      await admin.from('se_pins').update({
        failed_attempts: locked ? 0 : attempts,
        locked_until: locked ? new Date(Date.now() + 15 * 60000).toISOString() : null,
        updated_at: new Date().toISOString(),
      }).eq('user_id', u.id)
      return json({ ok: false, error: locked ? 'Too many attempts. Locked for 15 minutes.' : `Incorrect PIN — ${5 - attempts} attempt${5 - attempts === 1 ? '' : 's'} left.` }, 401)
    }

    throw new Error('Unknown action.')
  } catch (e) {
    return json({ ok: false, error: (e as Error).message }, 400)
  }
})
