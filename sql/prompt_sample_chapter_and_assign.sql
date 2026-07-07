-- ============================================================
-- Writing prompts: a sample-chapter link writers can read before
-- claiming, and a way for admin to hand a specific prompt directly
-- to a specific writer instead of leaving it in the open pool.
-- Run in Supabase → SQL Editor.
-- ============================================================

-- ── 1. Sample chapter URL ─────────────────────────────────────────
ALTER TABLE public.writing_prompts
  ADD COLUMN IF NOT EXISTS sample_chapter_url text;

-- get_se_my_prompts() returns SETOF writing_prompts (the whole row),
-- so it picks up the new column automatically -- no change needed.

-- Christine's se_add_prompt() gains a new parameter. Postgres treats
-- a changed argument list as a different function identity, so a
-- plain CREATE OR REPLACE would create a second, ambiguous overload
-- rather than actually replacing it -- drop the old 5-arg version
-- first.
DROP FUNCTION IF EXISTS public.se_add_prompt(text, text, text, text, int);
CREATE FUNCTION public.se_add_prompt(
  p_title text, p_brief text, p_genre text DEFAULT NULL,
  p_banner_url text DEFAULT NULL, p_sample_chapter_url text DEFAULT NULL,
  p_sort_order int DEFAULT 0
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid;
BEGIN
  IF NOT public.is_senior_editor() THEN RAISE EXCEPTION 'Senior Editors only.'; END IF;
  IF p_title IS NULL OR length(trim(p_title)) = 0 THEN RAISE EXCEPTION 'Title is required.'; END IF;
  IF p_brief IS NULL OR length(trim(p_brief)) = 0 THEN RAISE EXCEPTION 'Brief is required.'; END IF;
  INSERT INTO public.writing_prompts
    (title, brief, genre, banner_url, sample_chapter_url, sort_order, is_active, created_by, created_by_role, review_status)
  VALUES
    (trim(p_title), trim(p_brief), NULLIF(trim(COALESCE(p_genre, '')), ''), p_banner_url,
     NULLIF(trim(COALESCE(p_sample_chapter_url, '')), ''),
     COALESCE(p_sort_order, 0), true, auth.uid(), 'senior_editor', 'pending')
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- Canonical writer feed gains sample_chapter_url. DROP first: the
-- column list changes.
DROP FUNCTION IF EXISTS public.get_writer_prompt_feed();
CREATE FUNCTION public.get_writer_prompt_feed()
RETURNS TABLE (
  id            uuid,
  title         text,
  brief         text,
  genre         text,
  banner_url    text,
  sample_chapter_url text,
  sort_order    int,
  claim_state   text,
  my_claim_id   uuid,
  my_expires_at timestamptz
) LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM public.release_expired_prompt_claims();
  RETURN QUERY
  SELECT
    p.id, p.title, p.brief, p.genre, p.banner_url, p.sample_chapter_url, p.sort_order,
    CASE
      WHEN mine.id IS NOT NULL  THEN 'mine'
      WHEN taken.id IS NOT NULL THEN 'taken'
      ELSE 'available'
    END AS claim_state,
    mine.id         AS my_claim_id,
    mine.expires_at AS my_expires_at
  FROM public.writing_prompts p
  LEFT JOIN public.prompt_claims mine
         ON mine.prompt_id = p.id AND mine.status = 'active' AND mine.writer_id = auth.uid()
  LEFT JOIN public.prompt_claims taken
         ON taken.prompt_id = p.id AND taken.status = 'active'
  WHERE p.is_active = true AND p.review_status = 'approved'
  ORDER BY p.sort_order ASC, p.created_at DESC;
END;
$$;

-- ── 2. Admin assigns a prompt directly to a specific writer ──────
-- Same exclusivity guarantees as claim_prompt() (both partial unique
-- indexes on prompt_claims apply regardless of who inserts the row),
-- just admin-gated and taking an explicit p_writer_id instead of
-- binding to auth.uid().
CREATE OR REPLACE FUNCTION public.admin_assign_prompt(p_prompt_id uuid, p_writer_id uuid)
RETURNS public.prompt_claims LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_claim public.prompt_claims;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true) THEN
    RAISE EXCEPTION 'Admins only.';
  END IF;

  PERFORM public.release_expired_prompt_claims();

  IF NOT EXISTS (
    SELECT 1 FROM public.writing_prompts
    WHERE id = p_prompt_id AND is_active = true AND review_status = 'approved'
  ) THEN
    RAISE EXCEPTION 'This prompt is not available to assign (inactive or not yet approved).';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_writer_id) THEN
    RAISE EXCEPTION 'Writer not found.';
  END IF;

  IF EXISTS (SELECT 1 FROM public.prompt_claims WHERE writer_id = p_writer_id AND status = 'active') THEN
    RAISE EXCEPTION 'This writer already has an active prompt. Release it first.';
  END IF;

  BEGIN
    INSERT INTO public.prompt_claims (prompt_id, writer_id, expires_at)
    VALUES (p_prompt_id, p_writer_id, now() + interval '72 hours')
    RETURNING * INTO v_claim;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'This prompt was just claimed by someone else.';
  END;

  RETURN v_claim;
END;
$$;
