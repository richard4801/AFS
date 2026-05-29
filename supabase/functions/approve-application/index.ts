import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
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

    const { applicationId } = await req.json()

    // Load the application
    const { data: app, error: appErr } = await adminClient
      .from('applications')
      .select('*')
      .eq('id', applicationId)
      .single()
    if (appErr || !app) throw new Error('Application not found')
    if (app.status !== 'pending') throw new Error('Application already processed')

    // Invite the writer — creates their account and sends an invite email.
    // redirectTo must be in the Supabase allowed redirect URLs list.
    const { data: inviteData, error: inviteErr } = await adminClient.auth.admin.inviteUserByEmail(
      app.email,
      {
        data: { full_name: app.name },
        redirectTo: 'https://apexfictionstudio.com/dashboard/login.html',
      },
    )
    if (inviteErr) throw inviteErr

    // Ensure a profiles row exists for this writer (the DB trigger handles this
    // automatically, but we upsert here as a safety net).
    if (inviteData?.user?.id) {
      await adminClient.from('profiles').upsert({
        id:    inviteData.user.id,
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

    return new Response(JSON.stringify({ success: true }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  } catch (err: unknown) {
    const raw = err instanceof Error ? err.message : 'Unknown error'
    const SAFE = ['Unauthorized', 'Forbidden', 'Application not found', 'Application already processed', 'RESEND_API_KEY not configured']
    const message = SAFE.some(s => raw.includes(s)) ? raw : 'Internal server error'
    return new Response(JSON.stringify({ error: message }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: raw.includes('Unauthorized') || raw.includes('Forbidden') ? 403 : 400,
    })
  }
})
