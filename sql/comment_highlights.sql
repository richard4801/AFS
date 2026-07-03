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

DROP POLICY IF EXISTS "comments_se_read" ON public.comments;
CREATE POLICY "comments_se_read" ON public.comments
  FOR SELECT USING (
    public.is_senior_editor() AND EXISTS (
      SELECT 1 FROM public.chapters c JOIN public.books b ON b.id = c.book_id
      WHERE c.id = comments.chapter_id AND b.is_signed = true
    )
  );

DROP POLICY IF EXISTS "comments_se_insert" ON public.comments;
CREATE POLICY "comments_se_insert" ON public.comments
  FOR INSERT WITH CHECK (
    public.is_senior_editor() AND reviewer_id = auth.uid() AND EXISTS (
      SELECT 1 FROM public.chapters c JOIN public.books b ON b.id = c.book_id
      WHERE c.id = comments.chapter_id AND b.is_signed = true
    )
  );

DROP POLICY IF EXISTS "comments_se_update_own" ON public.comments;
CREATE POLICY "comments_se_update_own" ON public.comments
  FOR UPDATE USING (public.is_senior_editor() AND reviewer_id = auth.uid())
  WITH CHECK (public.is_senior_editor() AND reviewer_id = auth.uid());

DROP POLICY IF EXISTS "comments_se_delete_own" ON public.comments;
CREATE POLICY "comments_se_delete_own" ON public.comments
  FOR DELETE USING (public.is_senior_editor() AND reviewer_id = auth.uid());

-- ── 3. Enable Realtime on comments (non-fatal if already added) ──
DO $$
BEGIN
  EXECUTE 'ALTER PUBLICATION supabase_realtime ADD TABLE public.comments';
  RAISE NOTICE 'comments added to supabase_realtime publication.';
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'comments already in supabase_realtime publication, or publication unavailable (%). Skipping.', SQLERRM;
END $$;
