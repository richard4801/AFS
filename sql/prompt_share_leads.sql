-- ============================================================
-- Public prompt-share leads
-- Run in Supabase → SQL Editor.
--
-- Backs a new "share this prompt outside the platform" feature:
-- admin copies a public link to a prompt (prompt.html?id=<uuid>),
-- anyone can open it without an account and read the full brief +
-- banner image. A few seconds in, a lightweight join popup asks for
-- just a name, email, and a line about their writing experience --
-- deliberately much lighter than the full writer application
-- (sql/applications.sql, which requires a logline + writing sample).
-- These land here for admin to triage and decide who to invite.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.prompt_leads (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  prompt_id    uuid        NOT NULL REFERENCES public.writing_prompts(id) ON DELETE CASCADE,
  name         text        NOT NULL,
  email        text        NOT NULL,
  experience   text,
  status       text        NOT NULL DEFAULT 'new' CHECK (status IN ('new', 'contacted', 'invited', 'dismissed')),
  created_at   timestamptz NOT NULL DEFAULT now(),
  reviewed_at  timestamptz,
  reviewed_by  uuid        REFERENCES auth.users(id)
);

CREATE INDEX IF NOT EXISTS prompt_leads_prompt ON public.prompt_leads (prompt_id, created_at DESC);

ALTER TABLE public.prompt_leads ENABLE ROW LEVEL SECURITY;

-- Anyone (unauthenticated) can submit a lead for a prompt that is
-- actually currently live -- stricter than applications.sql's own
-- unconditional public_insert, since here we can and should scope it
-- to the exact prompt being shared. Field length caps mirror the
-- client-side caps in prompt.html as defense in depth.
DROP POLICY IF EXISTS "prompt_leads_public_insert" ON public.prompt_leads;
CREATE POLICY "prompt_leads_public_insert" ON public.prompt_leads
  FOR INSERT WITH CHECK (
    char_length(name) BETWEEN 1 AND 120
    AND char_length(email) BETWEEN 3 AND 200
    AND (experience IS NULL OR char_length(experience) <= 2000)
    AND status = 'new'
    AND reviewed_at IS NULL
    AND reviewed_by IS NULL
    AND EXISTS (
      SELECT 1 FROM public.writing_prompts
       WHERE id = prompt_id AND is_active = true AND review_status = 'approved'
    )
  );

-- Only admins can read or triage leads.
DROP POLICY IF EXISTS "prompt_leads_admin_all" ON public.prompt_leads;
CREATE POLICY "prompt_leads_admin_all" ON public.prompt_leads
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true)
  );
