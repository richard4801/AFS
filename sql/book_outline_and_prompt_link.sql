-- ============================================================
-- Writer-entered outlines, prompt→book linkage, and a persistent
-- "unread book" signal for Christine's review queue.
-- Run in Supabase → SQL Editor.
-- ============================================================

-- ── 1. Outline field on books ──────────────────────────────────
ALTER TABLE public.books
  ADD COLUMN IF NOT EXISTS outline text;

-- ── 2. Link a claimed prompt to the book it produced ────────────
-- prompt_claims.book_id has existed since writing_prompts.sql but was
-- never written to from anywhere — this is the missing write path.
-- Writer-only, and only over their own claim/book (both checked).
CREATE OR REPLACE FUNCTION public.link_prompt_claim_to_book(p_claim_id uuid, p_book_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.prompt_claims WHERE id = p_claim_id AND writer_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Claim not found.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.books WHERE id = p_book_id AND author_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Book not found.';
  END IF;

  UPDATE public.prompt_claims SET book_id = p_book_id WHERE id = p_claim_id;
END;
$$;

-- ── 3. "Has she started this one yet?" — drives a persistent
--       reminder banner that only clears once she's actually opened
--       the current book, not just on a timer or a single scroll. ──
ALTER TABLE public.se_review_queue
  ADD COLUMN IF NOT EXISTS started_at timestamptz;

CREATE OR REPLACE FUNCTION public.se_start_reviewing(p_book_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_senior_editor() THEN RAISE EXCEPTION 'Senior Editors only.'; END IF;
  UPDATE public.se_review_queue
     SET started_at = COALESCE(started_at, now())
   WHERE book_id = p_book_id AND status = 'pending';
END;
$$;

-- ── 4. Widen get_se_books() with outline + prompt origin ────────
-- DROP first: column list changes (9 → 11 cols).
DROP FUNCTION IF EXISTS public.get_se_books();
CREATE OR REPLACE FUNCTION public.get_se_books()
RETURNS TABLE (
  id uuid, title text, cover_url text, updated_at timestamptz,
  se_review_status text, se_review_note text, se_reviewed_at timestamptz,
  chapter_count bigint, total_words bigint,
  outline text, prompt_title text
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
         COALESCE(SUM(c.word_count) FILTER (WHERE c.status <> 'draft'), 0) AS total_words,
         b.outline, prompt.title AS prompt_title
  FROM public.books b
  LEFT JOIN public.chapters c ON c.book_id = b.id
  LEFT JOIN LATERAL (
    SELECT wp.title FROM public.prompt_claims pc
    JOIN public.writing_prompts wp ON wp.id = pc.prompt_id
    WHERE pc.book_id = b.id LIMIT 1
  ) prompt ON true
  WHERE b.is_signed = true
  GROUP BY b.id, b.outline, prompt.title
  ORDER BY b.updated_at DESC NULLS LAST;
END;
$$;

-- ── 5. Widen get_se_review_queue() the same way, plus is_started ─
-- DROP first: column list changes.
DROP FUNCTION IF EXISTS public.get_se_review_queue();
CREATE OR REPLACE FUNCTION public.get_se_review_queue()
RETURNS TABLE (
  queue_id uuid, book_id uuid, title text, cover_url text,
  queue_order bigint, status text, is_current boolean, pending_position bigint,
  is_started boolean, added_at timestamptz, completed_at timestamptz,
  chapter_count bigint, total_words bigint,
  outline text, prompt_title text
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_senior_editor() THEN RAISE EXCEPTION 'Senior Editors only.'; END IF;

  RETURN QUERY
  WITH ranked AS (
    SELECT q.id, ROW_NUMBER() OVER (ORDER BY q.queue_order ASC) AS rn
    FROM public.se_review_queue q
    WHERE q.status = 'pending'
  )
  SELECT q.id, q.book_id, b.title, b.cover_url, q.queue_order, q.status,
         (r.rn = 1) AS is_current,
         r.rn AS pending_position,
         (q.started_at IS NOT NULL) AS is_started,
         q.added_at, q.completed_at,
         COUNT(c.id) FILTER (WHERE c.status <> 'draft')          AS chapter_count,
         COALESCE(SUM(c.word_count) FILTER (WHERE c.status <> 'draft'), 0) AS total_words,
         b.outline, prompt.title AS prompt_title
  FROM public.se_review_queue q
  JOIN public.books b ON b.id = q.book_id
  LEFT JOIN ranked r ON r.id = q.id
  LEFT JOIN public.chapters c ON c.book_id = b.id
  LEFT JOIN LATERAL (
    SELECT wp.title FROM public.prompt_claims pc
    JOIN public.writing_prompts wp ON wp.id = pc.prompt_id
    WHERE pc.book_id = b.id LIMIT 1
  ) prompt ON true
  GROUP BY q.id, b.title, b.cover_url, q.queue_order, q.status, r.rn, q.started_at,
           q.added_at, q.completed_at, b.outline, prompt.title
  ORDER BY q.queue_order ASC;
END;
$$;
