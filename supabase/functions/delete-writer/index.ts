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

    const { writerId } = await req.json()
    if (!writerId) throw new Error('writerId is required')

    // Prevent an admin from deleting themselves
    if (writerId === user.id) throw new Error('Cannot delete your own account')

    // Deleting from auth.users cascades to profiles and all related data
    const { error } = await adminClient.auth.admin.deleteUser(writerId)
    if (error) throw error

    return new Response(JSON.stringify({ success: true }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  } catch (err: unknown) {
    const raw = err instanceof Error ? err.message : 'Unknown error'
    const SAFE = ['Unauthorized', 'Forbidden', 'writerId is required', 'Cannot delete your own account']
    const message = SAFE.some(s => raw.includes(s)) ? raw : 'Internal server error'
    return new Response(JSON.stringify({ error: message }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: raw.includes('Unauthorized') || raw.includes('Forbidden') ? 403 : 400,
    })
  }
})
