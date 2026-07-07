-- ============================================================
-- Admin override to manually start a claim's 72-hour clock.
-- Needed for claims that were already genuinely in progress before
-- sql/prompt_claim_delayed_countdown.sql's retroactive reset ran --
-- a writer already deep into writing a book has no natural reason to
-- ever revisit the prompt's detail modal again, so the automatic
-- "start on open" trigger (and the dashboard-load fallback in
-- loadPrompts()) may never fire for her. This gives admin a direct
-- way to start it right now instead of waiting on either.
-- Run in Supabase → SQL Editor.
-- ============================================================

CREATE OR REPLACE FUNCTION public.admin_start_prompt_claim(p_claim_id uuid)
RETURNS timestamptz LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_expires_at timestamptz;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true) THEN
    RAISE EXCEPTION 'Admins only.';
  END IF;
  UPDATE public.prompt_claims
     SET expires_at = COALESCE(expires_at, now() + interval '72 hours')
   WHERE id = p_claim_id AND status = 'active'
   RETURNING expires_at INTO v_expires_at;
  IF v_expires_at IS NULL THEN
    RAISE EXCEPTION 'Claim not found or no longer active.';
  END IF;
  RETURN v_expires_at;
END;
$$;
