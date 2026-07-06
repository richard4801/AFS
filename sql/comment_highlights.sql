-- ============================================================
-- Google-Docs-style highlight comments (Phase 2 — Senior Editor
-- first). Run in Supabase → SQL Editor.
--
-- Purely additive to the existing `comments` table — no existing
-- column, constraint, or policy is touched, so the current
-- paragraph_ref-based admin/writer comment UI keeps working exactly
-- as it does today. This adds a second, richer anchor (character
-- offset range) that coexists with it, plus threaded replies.
-- ============================================================

-- ── 1. New columns ────────────────────────────────────────────────
ALTER TABLE public.comments
  ADD COLUMN IF NOT EXISTS start_offset int,
  ADD COLUMN IF NOT EXISTS end_offset   int,
  ADD COLUMN IF NOT EXISTS quoted_text  text,
  ADD COLUMN IF NOT EXISTS parent_id    uuid REFERENCES public.comments(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS author_role  text CHECK (author_role IN ('admin', 'writer', 'senior_editor')),
  ADD COLUMN IF NOT EXISTS updated_at   timestamptz;

CREATE INDEX IF NOT EXISTS comments_chapter_offset ON public.comments (chapter_id, start_offset);
CREATE INDEX IF NOT EXISTS comments_parent          ON public.comments (parent_id);

-- ── 2. Senior Editor access — additive RLS policies ───────────────
-- Postgres RLS policies are OR'd together, so these only ADD her
-- access; they cannot narrow or override the existing admin/writer
-- policies already on this table.
ALTER TABLE public.comments ENABLE ROW LEVEL SECURITY;

-- Dedicated helper so the policy expressions below never reference the
-- comments table by name inside its own WITH CHECK/USING clause — takes
-- the chapter id as a plain parameter instead, which is unambiguous.
CREATE OR REPLACE FUNCTION public.chapter_book_is_signed(p_chapter_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.chapters c JOIN public.books b ON b.id = c.book_id
    WHERE c.id = p_chapter_id AND b.is_signed = true
  );
$$;

-- SUPERSEDED: a raw SELECT policy used to live here, but every client
-- reads comments exclusively through get_chapter_comments() (a SECURITY
-- DEFINER RPC that does its own authorization AND masks a writer's real
-- identity as generic "Writer" unless the viewer is admin). A raw SELECT
-- policy bypassed that masking entirely, exposing real reviewer_id/name.
-- Dropped in sql/fix_comments_se_read_masking.sql — no read policy is
-- needed here at all since nothing queries the table directly.
DROP POLICY IF EXISTS "comments_se_read" ON public.comments;

DROP POLICY IF EXISTS "comments_se_insert" ON public.comments;
CREATE POLICY "comments_se_insert" ON public.comments
  FOR INSERT WITH CHECK (
    public.is_senior_editor()
    AND reviewer_id = auth.uid()
    AND public.chapter_book_is_signed(chapter_id)
  );

DROP POLICY IF EXISTS "comments_se_update_own" ON public.comments;
CREATE POLICY "comments_se_update_own" ON public.comments
  FOR UPDATE USING (public.is_senior_editor() AND reviewer_id = auth.uid())
  WITH CHECK (public.is_senior_editor() AND reviewer_id = auth.uid());

DROP POLICY IF EXISTS "comments_se_delete_own" ON public.comments;
CREATE POLICY "comments_se_delete_own" ON public.comments
  FOR DELETE USING (public.is_senior_editor() AND reviewer_id = auth.uid());

-- ── 2b. RPC-gated insert (primary path — bypasses RLS-insert entirely) ──
-- Every other SE write in this app (se_recommend_chapters, se_add_prompt,
-- se_review_book, …) goes through a SECURITY DEFINER RPC rather than a
-- raw table insert, and all of those have worked reliably. Route comment
-- posting the same way instead of continuing to debug the direct-insert
-- RLS policy — the policy above stays in place as a defensive fallback,
-- but the client now calls this function.
CREATE OR REPLACE FUNCTION public.se_post_comment(
  p_chapter_id uuid, p_start_offset int, p_end_offset int, p_quoted_text text,
  p_body text, p_parent_id uuid DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_id uuid;
BEGIN
  IF NOT public.is_senior_editor() THEN RAISE EXCEPTION 'Senior Editors only.'; END IF;
  IF NOT public.chapter_book_is_signed(p_chapter_id) THEN RAISE EXCEPTION 'Chapter not found.'; END IF;
  IF p_body IS NULL OR length(trim(p_body)) = 0 THEN RAISE EXCEPTION 'Comment cannot be empty.'; END IF;

  INSERT INTO public.comments (chapter_id, reviewer_id, author_role, start_offset, end_offset, quoted_text, parent_id, body)
  VALUES (p_chapter_id, auth.uid(), 'senior_editor', p_start_offset, p_end_offset, p_quoted_text, p_parent_id, p_body)
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

-- ── 3. Enable Realtime on comments (non-fatal if already added) ──
DO $$
BEGIN
  EXECUTE 'ALTER PUBLICATION supabase_realtime ADD TABLE public.comments';
  RAISE NOTICE 'comments added to supabase_realtime publication.';
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'comments already in supabase_realtime publication, or publication unavailable (%). Skipping.', SQLERRM;
END $$;
