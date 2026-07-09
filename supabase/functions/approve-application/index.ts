import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

function escHtml(s: unknown): string {
  return String(s ?? '')
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#x27;')
}

function acceptanceEmailHtml(name: string, email: string, actionLink: string): string {
  const n = escHtml(name)
  const e = escHtml(email)
  const link = escHtml(actionLink)
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
  <h1 style="font-size:34px;color:#F0ECE6;margin:0 0 6px;font-weight:normal;line-height:1.15;">You've been selected.</h1>
  <p style="font-size:11px;color:#C9A84C;letter-spacing:0.22em;margin:0 0 36px;text-transform:uppercase;">Apex Fiction Studio</p>

  <!-- Body -->
  <p style="font-size:16px;color:#9A8A78;line-height:1.85;margin:0 0 18px;">Dear ${n},</p>
  <p style="font-size:16px;color:#9A8A78;line-height:1.85;margin:0 0 18px;">We received hundreds of applications. Yours stood out.</p>
  <p style="font-size:16px;color:#9A8A78;line-height:1.85;margin:0 0 36px;">After careful review, we are delighted to welcome you to Apex Fiction Studio as a commissioned writer. The work you create here will reach readers around the world — and you will be compensated for every word you deliver.</p>

  <div style="height:1px;background:rgba(201,168,76,0.12);margin-bottom:32px;"></div>

  <!-- CTA — invite link embedded directly -->
  <a href="${link}"
     style="display:inline-block;background:#C9A84C;color:#0D0B09;font-family:Georgia,serif;font-size:12px;font-weight:bold;letter-spacing:0.14em;text-transform:uppercase;padding:14px 34px;border-radius:3px;text-decoration:none;">
    Set Up Your Account
  </a>

  <p style="font-size:13px;color:#7A6A58;margin-top:52px;line-height:1.65;">
    — The Apex Fiction Studio Editorial Team<br/>
    <a href="mailto:admin@apexfictionstudio.com" style="color:#C9A84C;text-decoration:none;">admin@apexfictionstudio.com</a>
  </p>

  <div style="height:1px;background:rgba(201,168,76,0.08);margin-top:44px;"></div>
  <p style="font-size:10px;color:#5A4A38;margin-top:14px;">© 2026 Apex Fiction Studio &nbsp;·&nbsp; Sent to ${e}</p>
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

    // Service-role client — can create users and bypass RLS
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

    const { applicationId, redirectTo } = await req.json()
    const loginUrl = redirectTo || 'https://apexfictionstudio.com/dashboard/login.html'

    // Load the application
    const { data: app, error: appErr } = await adminClient
      .from('applications')
      .select('*')
      .eq('id', applicationId)
      .single()
    if (appErr || !app) throw new Error('Application not found')
    if (app.status !== 'pending') throw new Error('Application already processed')

    // Generate invite link without sending Supabase's own email.
    // This creates the user account and returns the action link so we can
    // embed it directly in our single branded email below.
    let actionLink: string
    const { data: linkData, error: inviteErr } = await adminClient.auth.admin.generateLink({
      type: 'invite',
      email: app.email,
      options: {
        data: { full_name: app.name },
        redirectTo: loginUrl,
      },
    })

    if (inviteErr) {
      console.error('generateLink error:', inviteErr.message, inviteErr)
      // If user already exists, fall back to a recovery (password reset) link
      if (inviteErr.message?.includes('already') || inviteErr.message?.includes('registered')) {
        const { data: recData, error: recErr } = await adminClient.auth.admin.generateLink({
          type: 'recovery',
          email: app.email,
          options: { redirectTo: loginUrl },
        })
        if (recErr) {
          console.error('recovery link error:', recErr.message, recErr)
          throw recErr
        }
        const link = recData?.properties?.action_link
        if (!link) throw new Error('Failed to generate recovery link')
        actionLink = link
      } else {
        throw inviteErr
      }
    } else {
      const link = linkData?.properties?.action_link
      if (!link) throw new Error('Failed to generate invite link — action_link missing')
      actionLink = link
    }

    // Ensure a profiles row exists for this writer
    if (linkData?.user?.id) {
      await adminClient.from('profiles').upsert({
        id:    linkData.user.id,
        name:  app.name,
        email: app.email,
      }, { onConflict: 'id', ignoreDuplicates: true })
    }

    // Mark as approved
    await adminClient
      .from('applications')
      .update({
        status: 'approved',
        reviewed_at: new Date().toISOString(),
        reviewed_by: user.id,
      })
      .eq('id', applicationId)

    // Send single branded acceptance email with invite link embedded
    const resendKey = Deno.env.get('RESEND_API_KEY')
    if (resendKey) {
      await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { 'Authorization': `Bearer ${resendKey}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          from: 'Apex Fiction Studio <notifications@apexfictionstudio.com>',
          reply_to: ['admin@apexfictionstudio.com'],
          to: [app.email],
          subject: `You've been selected — Apex Fiction Studio`,
          html: acceptanceEmailHtml(app.name, app.email, actionLink),
        }),
      })
    }

    return new Response(JSON.stringify({ success: true }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  } catch (err: unknown) {
    const raw = err instanceof Error ? err.message : 'Unknown error'
    console.error('approve-application top-level error:', raw, err)
    const SAFE = ['Unauthorized', 'Forbidden', 'Application not found', 'Application already processed']
    const message = SAFE.some(s => raw.includes(s)) ? raw : 'Internal server error'
    return new Response(JSON.stringify({ error: message }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: raw.includes('Unauthorized') || raw.includes('Forbidden') ? 403 : 400,
    })
  }
})
