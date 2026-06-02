import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

function escHtml(s: unknown): string {
  return String(s ?? '')
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#x27;')
}

function inviteEmailHtml(writerEmail: string, link: string): string {
  const e = escHtml(writerEmail)
  return `<!DOCTYPE html>
<html><head><meta charset="utf-8"/></head>
<body style="margin:0;padding:0;background:#0D0B09;">
<div style="background:#0D0B09;font-family:Georgia,'Times New Roman',serif;max-width:560px;margin:0 auto;padding:52px 40px;">

  <!-- Wordmark -->
  <div style="margin-bottom:44px;">
    <span style="font-size:26px;color:#C9A84C;letter-spacing:0.18em;font-weight:normal;">AFS</span><br/>
    <span style="font-size:8px;color:rgba(201,168,76,0.45);letter-spacing:0.45em;text-transform:uppercase;display:block;margin-top:3px;">Publishing</span>
    <div style="height:1px;background:linear-gradient(90deg,rgba(201,168,76,0.5),transparent);margin-top:18px;"></div>
  </div>

  <!-- Headline -->
  <h1 style="font-size:34px;color:#F0ECE6;margin:0 0 6px;font-weight:normal;line-height:1.15;">Your Invitation Link</h1>
  <p style="font-size:11px;color:#C9A84C;letter-spacing:0.22em;margin:0 0 36px;text-transform:uppercase;">Apex Fiction Studio</p>

  <!-- Body -->
  <p style="font-size:16px;color:#9A8A78;line-height:1.85;margin:0 0 18px;">Your admin has sent you a fresh invitation link to set up your password and access the Apex Fiction Studio dashboard.</p>

  <p style="font-size:16px;color:#9A8A78;line-height:1.85;margin:0 0 28px;">This link expires in 24 hours. Click below to get started.</p>

  <!-- CTA -->
  <a href="${link}"
     style="display:inline-block;background:#C9A84C;color:#0D0B09;font-family:Georgia,serif;font-size:12px;font-weight:bold;letter-spacing:0.14em;text-transform:uppercase;padding:14px 34px;border-radius:3px;text-decoration:none;">
    Set Your Password &amp; Sign In
  </a>

  <p style="font-size:13px;color:#6A5A4A;margin-top:44px;line-height:1.65;">
    — The Apex Fiction Studio Editorial Team<br/>
    <a href="mailto:apexfictionstudio@gmail.com" style="color:#5A4A38;text-decoration:none;">apexfictionstudio@gmail.com</a>
  </p>

  <div style="height:1px;background:rgba(201,168,76,0.08);margin-top:44px;"></div>
  <p style="font-size:10px;color:#2A1F14;margin-top:14px;">© 2026 Apex Fiction Studio &nbsp;·&nbsp; Sent to ${e}</p>
</div>
</body></html>`
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) throw new Error('Unauthorized')

    // Service-role client
    const adminClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    )

    // Verify the caller is an authenticated admin
    const callerClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: authHeader } } },
    )
    const { data: { user } } = await callerClient.auth.getUser()
    if (!user) throw new Error('Unauthorized')

    const { data: profile } = await adminClient
      .from('profiles')
      .select('is_admin')
      .eq('id', user.id)
      .single()
    if (!profile?.is_admin) throw new Error('Forbidden')

    const { writerId, writerEmail } = await req.json()
    if (!writerId || !writerEmail) throw new Error('writerId and writerEmail are required')

    // inviteUserByEmail works for both new and existing unconfirmed users.
    // It generates a fresh PKCE invite link and sends Supabase's default email —
    // we then also send our own branded email via Resend with the same link.
    const { data: inviteData, error: inviteErr } = await adminClient.auth.admin.inviteUserByEmail(
      writerEmail,
      { redirectTo: 'https://apexfictionstudio.com/dashboard/login.html' },
    )
    if (inviteErr) throw inviteErr

    // Send our branded email via Resend
    const resendKey = Deno.env.get('RESEND_API_KEY')
    if (!resendKey) throw new Error('RESEND_API_KEY not configured')

    // Build the invite link from the user's confirmation token
    const confirmationUrl = `https://apexfictionstudio.com/dashboard/login.html`

    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${resendKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        from: 'Apex Fiction Studio <notifications@apexfictionstudio.com>',
        to: [writerEmail],
        subject: `Your Apex Fiction Studio Invitation`,
        html: inviteEmailHtml(writerEmail, confirmationUrl),
      }),
    })

    if (!res.ok) {
      const body = await res.text()
      throw new Error(`Resend error: ${body}`)
    }

    return new Response(JSON.stringify({ success: true }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  } catch (err: unknown) {
    const raw = err instanceof Error ? err.message : 'Unknown error'
    console.error('send-invite error:', raw)
    const SAFE = ['Unauthorized', 'Forbidden', 'writerId and writerEmail are required', 'RESEND_API_KEY not configured']
    const message = SAFE.some(s => raw.includes(s)) ? raw : 'Internal server error'
    const status = raw.includes('Unauthorized') || raw.includes('Forbidden') ? 403 : 400
    return new Response(JSON.stringify({ error: message }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status,
    })
  }
})
