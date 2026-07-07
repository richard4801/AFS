-- ============================================================
-- Sub-tags on prompts (e.g. "Enemies to Lovers", "Slow Burn"),
-- entered right after Genre on both prompt-creation forms and shown
-- to writers on the prompt detail screen, same spot.
-- Run in Supabase → SQL Editor.
-- ============================================================

ALTER TABLE public.writing_prompts
  ADD COLUMN IF NOT EXISTS tags text[] NOT NULL DEFAULT '{}'::text[];

-- Christine's se_add_prompt() gains another parameter -- same reason
-- as the sample_chapter_url migration: a changed argument list is a
-- different function identity to Postgres, so the old 6-arg version
-- has to be dropped first or this would create a second, ambiguous
-- overload instead of actually replacing it.
DROP FUNCTION IF EXISTS public.se_add_prompt(text, text, text, text, text, int);
CREATE FUNCTION public.se_add_prompt(
  p_title text, p_brief text, p_genre text DEFAULT NULL,
  p_banner_url text DEFAULT NULL, p_sample_chapter_url text DEFAULT NULL,
  p_tags text[] DEFAULT '{}'::text[], p_sort_order int DEFAULT 0
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid;
BEGIN
  IF NOT public.is_senior_editor() THEN RAISE EXCEPTION 'Senior Editors only.'; END IF;
  IF p_title IS NULL OR length(trim(p_title)) = 0 THEN RAISE EXCEPTION 'Title is required.'; END IF;
  IF p_brief IS NULL OR length(trim(p_brief)) = 0 THEN RAISE EXCEPTION 'Brief is required.'; END IF;
  INSERT INTO public.writing_prompts
    (title, brief, genre, banner_url, sample_chapter_url, tags, sort_order, is_active, created_by, created_by_role, review_status)
  VALUES
    (trim(p_title), trim(p_brief), NULLIF(trim(COALESCE(p_genre, '')), ''), p_banner_url,
     NULLIF(trim(COALESCE(p_sample_chapter_url, '')), ''), COALESCE(p_tags, '{}'::text[]),
     COALESCE(p_sort_order, 0), true, auth.uid(), 'senior_editor', 'pending')
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- Canonical writer feed gains tags. DROP first: the column list
-- changes.
DROP FUNCTION IF EXISTS public.get_writer_prompt_feed();
CREATE FUNCTION public.get_writer_prompt_feed()
RETURNS TABLE (
  id            uuid,
  title         text,
  brief         text,
  genre         text,
  banner_url    text,
  sample_chapter_url text,
  tags          text[],
  sort_order    int,
  claim_state   text,
  my_claim_id   uuid,
  my_expires_at timestamptz
) LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM public.release_expired_prompt_claims();
  RETURN QUERY
  SELECT
    p.id, p.title, p.brief, p.genre, p.banner_url, p.sample_chapter_url, p.tags, p.sort_order,
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
