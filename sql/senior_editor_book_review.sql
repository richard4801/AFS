-- ============================================================
-- Senior Editor: open signed books, read chapters, approve or
-- request changes. Run in Supabase → SQL Editor.
--
-- Scope: review applies to SIGNED books only (same set as her
-- existing "signed books" wall). Content access is READ-ONLY and
-- granted exclusively through these SECURITY DEFINER RPCs — she has
-- no RLS grant on books/chapters, so raw table queries still return
-- nothing for her.
-- ============================================================

-- ── 1. Review state on books ─────────────────────────────────────
ALTER TABLE public.books
  ADD COLUMN IF NOT EXISTS se_review_status text NOT NULL DEFAULT 'pending'
    CHECK (se_review_status IN ('pending', 'approved', 'changes_requested')),
  ADD COLUMN IF NOT EXISTS se_review_note   text,
  ADD COLUMN IF NOT EXISTS se_reviewed_by   uuid REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS se_reviewed_at   timestamptz;

-- ── 2. Her book wall — now with review state + basic stats ──────
-- DROP first: this changes the column list of the get_se_books() that
-- senior_editor.sql originally created (4 columns → 9), and Postgres
-- refuses CREATE OR REPLACE across a return-type change.
DROP FUNCTION IF EXISTS public.get_se_books();
CREATE OR REPLACE FUNCTION public.get_se_books()
RETURNS TABLE (
  id uuid, title text, cover_url text, updated_at timestamptz,
  se_review_status text, se_review_note text, se_reviewed_at timestamptz,
  chapter_count bigint, total_words bigint
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_senior_editor() THEN
    RAISE EXCEPTION 'Senior Editors only.';
  END IF;
  RETURN QUERY
  SELECT b.id, b.title, b.cover_url, b.updated_at,
         b.se_review_status, b.se_review_note, b.se_reviewed_at,
         COUNT(c.id) FILTER (WHERE c.status <> 'draft')          AS chapter_count,
         COALESCE(SUM(c.word_count) FILTER (WHERE c.status <> 'draft'), 0) AS total_words
  FROM public.books b
  LEFT JOIN public.chapters c ON c.book_id = b.id
  WHERE b.is_signed = true
  GROUP BY b.id
  ORDER BY b.updated_at DESC NULLS LAST;
END;
$$;

-- ── 3. Chapter list for a signed book (submitted+ only) ──────────
CREATE OR REPLACE FUNCTION public.get_se_book_chapters(p_book_id uuid)
RETURNS TABLE (id uuid, chapter_number int, title text, status text, word_count int, updated_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_senior_editor() THEN RAISE EXCEPTION 'Senior Editors only.'; END IF;
  -- Qualified with the "b" alias: this function's RETURNS TABLE declares an
  -- output column named "id", which plpgsql exposes as a variable throughout
  -- the function body — a bare "id" here is ambiguous against that variable.
  IF NOT EXISTS (SELECT 1 FROM public.books b WHERE b.id = p_book_id AND b.is_signed = true) THEN
    RAISE EXCEPTION 'Book not found.';
  END IF;
  RETURN QUERY
  SELECT c.id, c.chapter_number, c.title, c.status, c.word_count, c.updated_at
  FROM public.chapters c
  WHERE c.book_id = p_book_id AND c.status <> 'draft'
  ORDER BY c.chapter_number ASC;
END;
$$;

-- ── 4. Read-only chapter content ──────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_se_chapter_content(p_chapter_id uuid)
RETURNS TABLE (id uuid, title text, content text, chapter_number int, status text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_senior_editor() THEN RAISE EXCEPTION 'Senior Editors only.'; END IF;
  RETURN QUERY
  SELECT c.id, c.title, c.content, c.chapter_number, c.status
  FROM public.chapters c
  JOIN public.books b ON b.id = c.book_id
  WHERE c.id = p_chapter_id AND b.is_signed = true;
END;
$$;

-- ── 5. Approve or request changes ─────────────────────────────────
CREATE OR REPLACE FUNCTION public.se_review_book(p_book_id uuid, p_decision text, p_note text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_senior_editor() THEN RAISE EXCEPTION 'Senior Editors only.'; END IF;
  IF p_decision NOT IN ('approved', 'changes_requested') THEN
    RAISE EXCEPTION 'Decision must be approved or changes_requested.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.books WHERE id = p_book_id AND is_signed = true) THEN
    RAISE EXCEPTION 'Book not found.';
  END IF;
  UPDATE public.books
     SET se_review_status = p_decision,
         se_review_note   = p_note,
         se_reviewed_by   = auth.uid(),
         se_reviewed_at   = now()
   WHERE id = p_book_id;
END;
$$;

-- ── 6. Writer-side visibility of her verdict on their own books ──
-- Existing writer RLS on books already scopes to author_id = auth.uid(),
-- so no new policy is needed — se_review_status/note are just additional
-- columns writers can already select on their own rows.
