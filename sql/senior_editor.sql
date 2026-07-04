-- ============================================================
-- Senior Editor: role, symmetric prompt review, signed-books
-- view, and PIN-based access. Run in Supabase → SQL Editor.
--
-- ADDITIVE + NON-BREAKING: review_status defaults to 'approved',
-- so existing prompts and the current admin insert path keep
-- publishing live. The approval gate only engages once the admin
-- insert path is switched to 'pending' (done when the SE dashboard
-- ships).
-- ============================================================

-- pgcrypto powers the PIN hashing used by the Edge Function.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ── 1. Senior Editor role flag ──────────────────────────────────
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS is_senior_editor boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION public.is_senior_editor()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE((SELECT is_senior_editor FROM public.profiles WHERE id = auth.uid()), false);
$$;

-- ── 2. Prompt review workflow ───────────────────────────────────
ALTER TABLE public.writing_prompts
  ADD COLUMN IF NOT EXISTS review_status   text NOT NULL DEFAULT 'approved'
    CHECK (review_status IN ('pending', 'approved', 'denied')),
  ADD COLUMN IF NOT EXISTS review_note     text,
  ADD COLUMN IF NOT EXISTS created_by_role text NOT NULL DEFAULT 'admin'
    CHECK (created_by_role IN ('admin', 'senior_editor')),
  ADD COLUMN IF NOT EXISTS reviewed_by     uuid,
  ADD COLUMN IF NOT EXISTS reviewed_at     timestamptz;

-- Anything created before this migration stays live.
UPDATE public.writing_prompts SET review_status = 'approved' WHERE review_status IS NULL;

-- ── 3. Writer feed only surfaces APPROVED + active prompts ───────
CREATE OR REPLACE FUNCTION public.get_writer_prompt_feed()
RETURNS TABLE (
  id uuid, title text, brief text, genre text, banner_url text,
  sort_order int, claim_state text, my_claim_id uuid, my_expires_at timestamptz
) LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM public.release_expired_prompt_claims();
  RETURN QUERY
  SELECT
    p.id, p.title, p.brief, p.genre, p.banner_url, p.sort_order,
    CASE WHEN mine.id IS NOT NULL THEN 'mine'
         WHEN taken.id IS NOT NULL THEN 'taken'
         ELSE 'available' END AS claim_state,
    mine.id AS my_claim_id, mine.expires_at AS my_expires_at
  FROM public.writing_prompts p
  LEFT JOIN public.prompt_claims mine
         ON mine.prompt_id = p.id AND mine.status = 'active' AND mine.writer_id = auth.uid()
  LEFT JOIN public.prompt_claims taken
         ON taken.prompt_id = p.id AND taken.status = 'active'
  WHERE p.is_active = true AND p.review_status = 'approved'
  ORDER BY p.sort_order ASC, p.created_at DESC;
END;
$$;

-- ── 4. Review queue: pending prompts created by the OTHER party ──
-- Admin sees the Senior Editor's pending prompts; the SE sees the
-- admin's. Each reviews the other's — symmetric approval.
CREATE OR REPLACE FUNCTION public.get_prompts_pending_review()
RETURNS SETOF public.writing_prompts LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_is_admin boolean := EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true);
  v_is_se    boolean := public.is_senior_editor();
BEGIN
  IF v_is_admin THEN
    RETURN QUERY SELECT * FROM public.writing_prompts
      WHERE review_status = 'pending' AND created_by_role = 'senior_editor'
      ORDER BY created_at DESC;
  ELSIF v_is_se THEN
    RETURN QUERY SELECT * FROM public.writing_prompts
      WHERE review_status = 'pending' AND created_by_role = 'admin'
      ORDER BY created_at DESC;
  END IF;
END;
$$;

-- ── 5. Approve / deny a prompt (with optional note) ──────────────
CREATE OR REPLACE FUNCTION public.review_prompt(p_id uuid, p_decision text, p_note text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_is_admin  boolean := EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true);
  v_is_se     boolean := public.is_senior_editor();
  v_creator   text;
BEGIN
  IF p_decision NOT IN ('approved', 'denied') THEN
    RAISE EXCEPTION 'Decision must be approved or denied.';
  END IF;
  IF NOT (v_is_admin OR v_is_se) THEN
    RAISE EXCEPTION 'Not authorised.';
  END IF;

  SELECT created_by_role INTO v_creator FROM public.writing_prompts WHERE id = p_id AND review_status = 'pending';
  IF v_creator IS NULL THEN
    RAISE EXCEPTION 'Prompt not found or already reviewed.';
  END IF;
  -- You may only review the OTHER party's prompt.
  IF v_is_admin AND v_creator <> 'senior_editor' THEN RAISE EXCEPTION 'You can only review the Senior Editor''s prompts.'; END IF;
  IF v_is_se    AND v_creator <> 'admin'         THEN RAISE EXCEPTION 'You can only review the admin''s prompts.'; END IF;

  UPDATE public.writing_prompts
     SET review_status = p_decision,
         review_note   = p_note,
         reviewed_by   = auth.uid(),
         reviewed_at   = now()
   WHERE id = p_id;
END;
$$;

-- ── 6. Senior Editor's signed-books wall (covers/titles only) ────
CREATE OR REPLACE FUNCTION public.get_se_books()
RETURNS TABLE (id uuid, title text, cover_url text, updated_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_senior_editor() THEN
    RAISE EXCEPTION 'Senior Editors only.';
  END IF;
  RETURN QUERY
  SELECT b.id, b.title, b.cover_url, b.updated_at
  FROM public.books b
  WHERE b.is_signed = true
  ORDER BY b.updated_at DESC NULLS LAST;
END;
$$;

-- ── 7. Senior Editor's view of active prompt development ─────────
-- Prompt title + time remaining, no writer identity.
CREATE OR REPLACE FUNCTION public.get_se_active_prompts()
RETURNS TABLE (prompt_id uuid, title text, genre text, banner_url text, expires_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_senior_editor() THEN
    RAISE EXCEPTION 'Senior Editors only.';
  END IF;
  PERFORM public.release_expired_prompt_claims();
  RETURN QUERY
  SELECT p.id, p.title, p.genre, p.banner_url, c.expires_at
  FROM public.prompt_claims c
  JOIN public.writing_prompts p ON p.id = c.prompt_id
  WHERE c.status = 'active'
  ORDER BY c.expires_at ASC;
END;
$$;

-- ── 8. PIN store (accessed only by the Edge Function / service role)
CREATE TABLE IF NOT EXISTS public.se_pins (
  user_id         uuid        PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  pin_hash        text        NOT NULL,
  failed_attempts int         NOT NULL DEFAULT 0,
  locked_until    timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
-- RLS on, no policies → unreachable via anon/authenticated keys.
-- The se-access Edge Function uses the service role, which bypasses RLS.
ALTER TABLE public.se_pins ENABLE ROW LEVEL SECURITY;

-- ── 9. Admin can reset the Senior Editor's PIN ──────────────────
-- Also clears her onboarding flag, so the first-run spotlight tour
-- automatically replays the next time she logs in with a new PIN
-- (the tour gate in editor.html reads profiles.onboarded fresh on
-- every login, so no client-side change is needed for this).
CREATE OR REPLACE FUNCTION public.admin_reset_se_pin()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true) THEN
    RAISE EXCEPTION 'Admins only.';
  END IF;
  DELETE FROM public.se_pins
   WHERE user_id IN (SELECT id FROM public.profiles WHERE is_senior_editor = true);
  UPDATE public.profiles
     SET onboarded = false
   WHERE is_senior_editor = true;
END;
$$;
