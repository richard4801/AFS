-- High-severity audit fixes (pure SQL, no client-code changes needed).
-- Run once in Supabase → SQL Editor. Every statement is idempotent.
--
-- Fix 1: writing_prompts read policy leaked pending/denied prompts and the
--        admin's private review_note to any signed-in writer (it allowed
--        every is_active row regardless of review_status). Now non-admins
--        only see approved+active prompts; a creator still sees their own.
-- Fix 2: daily_chapter_counts view ran with owner (RLS-bypassing) rights and
--        never filtered by author, so any writer could read every other
--        writer's daily activity. Switched to security_invoker so the
--        querying user's own RLS on chapters applies.
-- Fix 3: get_se_chapter_content returned draft chapters for a guessed id
--        (its sibling get_se_book_chapters filters drafts out; this one
--        didn't). Added the same status <> 'draft' filter.
-- Fix 4: two conflicting get_writer_prompt_feed definitions existed; the
--        older one filtered only is_active (bypassing the approval gate).
--        Re-asserts the correct approved-filtering version so it's the one
--        that's live regardless of migration order.

-- ── Fix 1 ──────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "prompts_read_active" ON public.writing_prompts;
CREATE POLICY "prompts_read_active" ON public.writing_prompts
  FOR SELECT USING (
    (is_active = true AND review_status = 'approved')
    OR created_by = auth.uid()
    OR EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true)
  );

-- ── Fix 2 ──────────────────────────────────────────────────────────────
-- security_invoker makes the view run as the querying user, so their own
-- RLS on public.chapters applies (a writer sees only their own rows).
-- Requires Postgres 15+ (Supabase is on 15+).
ALTER VIEW public.daily_chapter_counts SET (security_invoker = true);

-- ── Fix 3 ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_se_chapter_content(p_chapter_id uuid)
RETURNS TABLE (id uuid, title text, content text, chapter_number int, status text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_senior_editor() THEN RAISE EXCEPTION 'Senior Editors only.'; END IF;
  RETURN QUERY
  SELECT c.id::uuid, c.title::text, c.content::text, c.chapter_number::int, c.status::text
  FROM public.chapters c
  JOIN public.books b ON b.id = c.book_id
  WHERE c.id = p_chapter_id AND b.is_signed = true AND c.status <> 'draft';
END;
$$;

-- ── Fix 4 ──────────────────────────────────────────────────────────────
-- Canonical approved-only feed, copied verbatim from senior_editor.sql so
-- this (not the older is_active-only version in writing_prompts.sql) is the
-- definition that's live regardless of which migration ran last.
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

NOTIFY pgrst, 'reload schema';
