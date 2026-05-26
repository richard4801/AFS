import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// Requires RESEND_API_KEY set as a Supabase Edge Function secret.
// Set it in: Supabase Dashboard → Edge Functions → Manage Secrets

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

type EventType = 'income_posted' | 'chapter_approved'

interface Payload {
  type: EventType
  writerId: string
  writerEmail: string
  writerName: string
  data: Record<string, string | number>
}

const templates: Record<EventType, (p: Payload) => { subject: string; html: string }> = {
  income_posted: ({ writerName, data }) => ({
    subject: `Your earnings have been updated — Apex Fiction Studio`,
    html: `
      <div style="background:#121212;color:#fff;font-family:Inter,sans-serif;max-width:520px;margin:0 auto;padding:40px 32px;">
        <div style="font-family:Georgia,serif;font-size:22px;color:#C9A84C;margin-bottom:8px;">Apex Fiction Studio</div>
        <div style="height:1px;background:linear-gradient(90deg,transparent,#C9A84C,transparent);opacity:.4;margin-bottom:32px;"></div>
        <h1 style="font-family:Georgia,serif;font-size:28px;color:#fff;margin:0 0 16px;">Earnings Updated</h1>
        <p style="color:#7A7A7A;font-size:15px;line-height:1.7;margin:0 0 24px;">
          Hi ${writerName}, a new earnings entry has been recorded for you.
        </p>
        <div style="background:#1C1C1C;border:1px solid #2E2E2E;border-radius:12px;padding:20px 24px;margin-bottom:28px;">
          <p style="margin:0 0 8px;color:#7A7A7A;font-size:11px;letter-spacing:.18em;text-transform:uppercase;">Amount</p>
          <p style="margin:0;color:#C9A84C;font-family:Georgia,serif;font-size:32px;font-weight:bold;">$${Number(data.amount).toFixed(2)}</p>
          <p style="margin:8px 0 0;color:#7A7A7A;font-size:13px;">for ${data.date}</p>
        </div>
        <a href="https://apexfictionstudio.com/dashboard/index.html"
           style="display:inline-block;background:#C9A84C;color:#121212;font-size:13px;font-weight:700;padding:12px 24px;border-radius:8px;text-decoration:none;">
          View Your Dashboard →
        </a>
        <p style="color:#3A3A3A;font-size:11px;margin-top:40px;">© 2026 Apex Fiction Studio</p>
      </div>`,
  }),

  chapter_approved: ({ writerName, data }) => ({
    subject: `Chapter approved — ${data.title || `Chapter ${data.chapterNumber}`}`,
    html: `
      <div style="background:#121212;color:#fff;font-family:Inter,sans-serif;max-width:520px;margin:0 auto;padding:40px 32px;">
        <div style="font-family:Georgia,serif;font-size:22px;color:#C9A84C;margin-bottom:8px;">Apex Fiction Studio</div>
        <div style="height:1px;background:linear-gradient(90deg,transparent,#C9A84C,transparent);opacity:.4;margin-bottom:32px;"></div>
        <h1 style="font-family:Georgia,serif;font-size:28px;color:#fff;margin:0 0 16px;">Chapter Approved</h1>
        <p style="color:#7A7A7A;font-size:15px;line-height:1.7;margin:0 0 24px;">
          Hi ${writerName}, your chapter has been reviewed and approved.
        </p>
        <div style="background:#1C1C1C;border:1px solid #2E2E2E;border-radius:12px;padding:20px 24px;margin-bottom:28px;">
          <p style="margin:0 0 4px;color:#fff;font-family:Georgia,serif;font-size:18px;">Chapter ${data.chapterNumber}${data.title ? `: "${data.title}"` : ''}</p>
          <p style="margin:0;color:#7A7A7A;font-size:13px;">${data.wordCount ? Number(data.wordCount).toLocaleString() + ' words' : ''}</p>
        </div>
        <a href="https://apexfictionstudio.com/dashboard/index.html"
           style="display:inline-block;background:#C9A84C;color:#121212;font-size:13px;font-weight:700;padding:12px 24px;border-radius:8px;text-decoration:none;">
          View Your Dashboard →
        </a>
        <p style="color:#3A3A3A;font-size:11px;margin-top:40px;">© 2026 Apex Fiction Studio</p>
      </div>`,
  }),
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  try {
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) throw new Error('Unauthorized')

    const adminClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    )

    // Verify caller is admin
    const callerClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: authHeader } } },
    )
    const { data: { user } } = await callerClient.auth.getUser()
    if (!user) throw new Error('Unauthorized')
    const { data: prof } = await adminClient.from('profiles').select('is_admin').eq('id', user.id).single()
    if (!prof?.is_admin) throw new Error('Forbidden')

    const payload: Payload = await req.json()
    const { subject, html } = templates[payload.type](payload)

    const resendKey = Deno.env.get('RESEND_API_KEY')
    if (!resendKey) throw new Error('RESEND_API_KEY not configured')

    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${resendKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        from: 'Apex Fiction Studio <notifications@apexfictionstudio.com>',
        to: [payload.writerEmail],
        subject,
        html,
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
    const message = err instanceof Error ? err.message : 'Unknown error'
    return new Response(JSON.stringify({ error: message }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 400,
    })
  }
})
