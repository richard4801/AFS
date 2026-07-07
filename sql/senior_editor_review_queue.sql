-- ============================================================
-- Senior Editor: pre-signing review queue with sequential unlock.
-- Run in Supabase → SQL Editor.
--
-- Separate from the existing "Signed books" wall (get_se_books,
-- unchanged by this file) — this is a second, independent list for
-- books that haven't been signed yet but that the admin has already
-- judged worth Christine's review. Admin sends a book in with
-- admin_send_book_to_se(); she can only open the earliest book that
-- isn't yet complete. A book is marked complete the moment she has
-- scrolled to the end of every one of its (non-draft) chapters,
-- which automatically unlocks the next one in line.
--
-- Reuses her existing reader + per-chapter recommend flow
-- (get_se_book_chapters / get_se_chapter_content / se_recommend_chapters)
-- rather than duplicating it — their gate is widened from
-- "book is signed" to "book is signed OR is her current/completed
-- queue entry", via the _se_book_unlocked() helper below.
-- ============================================================

-- ── 1. Queue ─────────────────────────────────────────────────────
CREATE SEQUENCE IF NOT EXISTS public.se_review_queue_order_seq;

CREATE TABLE IF NOT EXISTS public.se_review_queue (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  book_id      uuid        NOT NULL UNIQUE REFERENCES public.books(id) ON DELETE CASCADE,
  queue_order  bigint      NOT NULL DEFAULT nextval('public.se_review_queue_order_seq'),
  status       text        NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'completed')),
  added_by     uuid        REFERENCES auth.users(id),
  added_at     timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz
);
ALTER TABLE public.se_review_queue ENABLE ROW LEVEL SECURITY;
-- No policies — reachable only through the SECURITY DEFINER RPCs below,
-- same posture as se_pins / se_setup_token.

CREATE INDEX IF NOT EXISTS idx_se_review_queue_status_order ON public.se_review_queue(status, queue_order);

-- ── 2. Per-chapter read receipts within a queue entry ─────────────
CREATE TABLE IF NOT EXISTS public.se_chapter_reads (
  queue_id   uuid        NOT NULL REFERENCES public.se_review_queue(id) ON DELETE CASCADE,
  chapter_id uuid        NOT NULL REFERENCES public.chapters(id) ON DELETE CASCADE,
  read_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (queue_id, chapter_id)
);
ALTER TABLE public.se_chapter_reads ENABLE ROW LEVEL SECURITY;

-- ── 3. Is this book currently open to her? ────────────────────────
-- True if it's on the existing signed wall, OR it's a queue entry
-- that's either completed already or the earliest still-pending one.
CREATE OR REPLACE FUNCTION public._se_book_unlocked(p_book_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT
    EXISTS (SELECT 1 FROM public.books WHERE id = p_book_id AND is_signed = true)
    OR EXISTS (
      SELECT 1 FROM public.se_review_queue q
      WHERE q.book_id = p_book_id
        AND (
          q.status = 'completed'
          OR q.id = (
            SELECT id FROM public.se_review_queue
            WHERE status = 'pending'
            ORDER BY queue_order ASC LIMIT 1
          )
        )
    );
$$;

-- ── 4. Admin sends a book into the queue ──────────────────────────
CREATE OR REPLACE FUNCTION public.admin_send_book_to_se(p_book_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true) THEN
    RAISE EXCEPTION 'Admins only.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.books WHERE id = p_book_id) THEN
    RAISE EXCEPTION 'Book not found.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.se_review_queue WHERE book_id = p_book_id) THEN
    RAISE EXCEPTION 'This book is already in Christine''s review queue.';
  END IF;

  INSERT INTO public.se_review_queue (book_id, added_by)
  VALUES (p_book_id, auth.uid());
END;
$$;

-- ── 5. Her queue, in order — locked entries included so she can see
--       what's coming, just not open them yet. ────────────────────
CREATE OR REPLACE FUNCTION public.get_se_review_queue()
RETURNS TABLE (
  queue_id uuid, book_id uuid, title text, cover_url text,
  queue_order bigint, status text, is_current boolean, pending_position bigint,
  added_at timestamptz, completed_at timestamptz,
  chapter_count bigint, total_words bigint
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
         q.added_at, q.completed_at,
         COUNT(c.id) FILTER (WHERE c.status <> 'draft')          AS chapter_count,
         COALESCE(SUM(c.word_count) FILTER (WHERE c.status <> 'draft'), 0) AS total_words
  FROM public.se_review_queue q
  JOIN public.books b ON b.id = q.book_id
  LEFT JOIN ranked r ON r.id = q.id
  LEFT JOIN public.chapters c ON c.book_id = b.id
  GROUP BY q.id, b.title, b.cover_url, q.queue_order, q.status, r.rn, q.added_at, q.completed_at
  ORDER BY q.queue_order ASC;
END;
$$;

-- ── 6. Admin's view of the same queue (to render button state) ───
CREATE OR REPLACE FUNCTION public.admin_get_se_queue()
RETURNS TABLE (
  queue_id uuid, book_id uuid, queue_order bigint, status text,
  pending_position bigint, added_at timestamptz, completed_at timestamptz
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true) THEN
    RAISE EXCEPTION 'Admins only.';
  END IF;
  RETURN QUERY
  WITH ranked AS (
    SELECT q.id, ROW_NUMBER() OVER (ORDER BY q.queue_order ASC) AS rn
    FROM public.se_review_queue q
    WHERE q.status = 'pending'
  )
  SELECT q.id, q.book_id, q.queue_order, q.status, r.rn, q.added_at, q.completed_at
  FROM public.se_review_queue q
  LEFT JOIN ranked r ON r.id = q.id
  ORDER BY q.queue_order ASC;
END;
$$;

-- ── 7. Widen the gate on her existing reading/recommend RPCs ──────
-- Same shape/signature as whichever migration last defined each of
-- these (se_chapter_recommendations.sql for get_se_book_chapters,
-- high_security_fixes.sql for get_se_chapter_content) — only the
-- is_signed check changes, to _se_book_unlocked().

CREATE OR REPLACE FUNCTION public.get_se_book_chapters(p_book_id uuid)
RETURNS TABLE (
  id uuid, chapter_number int, title text, status text, word_count int, updated_at timestamptz,
  my_recommendation text, my_recommendation_status text
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_senior_editor() THEN RAISE EXCEPTION 'Senior Editors only.'; END IF;
  IF NOT public._se_book_unlocked(p_book_id) THEN
    RAISE EXCEPTION 'Book not found.';
  END IF;
  RETURN QUERY
  SELECT c.id::uuid, c.chapter_number::int, c.title::text, c.status::text,
         c.word_count::int, c.updated_at::timestamptz,
         r.recommendation::text, r.admin_status::text
  FROM public.chapters c
  LEFT JOIN LATERAL (
    SELECT recommendation, admin_status FROM public.se_chapter_recommendations
    WHERE chapter_id = c.id AND created_by = auth.uid()
    ORDER BY created_at DESC LIMIT 1
  ) r ON true
  WHERE c.book_id = p_book_id AND c.status <> 'draft'
  ORDER BY c.chapter_number ASC;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_se_chapter_content(p_chapter_id uuid)
RETURNS TABLE (id uuid, title text, content text, chapter_number int, status text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_senior_editor() THEN RAISE EXCEPTION 'Senior Editors only.'; END IF;
  RETURN QUERY
  SELECT c.id::uuid, c.title::text, c.content::text, c.chapter_number::int, c.status::text
  FROM public.chapters c
  JOIN public.books b ON b.id = c.book_id
  WHERE c.id = p_chapter_id AND c.status <> 'draft' AND public._se_book_unlocked(b.id);
END;
$$;

CREATE OR REPLACE FUNCTION public.se_recommend_chapters(p_chapter_ids uuid[], p_recommendation text, p_note text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_batch      uuid := gen_random_uuid();
  v_chapter_id uuid;
  v_inserted   int := 0;
BEGIN
  IF NOT public.is_senior_editor() THEN RAISE EXCEPTION 'Senior Editors only.'; END IF;
  IF p_recommendation NOT IN ('approve', 'needs_work') THEN
    RAISE EXCEPTION 'Recommendation must be approve or needs_work.';
  END IF;
  IF p_chapter_ids IS NULL OR array_length(p_chapter_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'Select at least one chapter.';
  END IF;

  FOREACH v_chapter_id IN ARRAY p_chapter_ids LOOP
    INSERT INTO public.se_chapter_recommendations (chapter_id, book_id, recommendation, note, batch_id, created_by)
    SELECT c.id, c.book_id, p_recommendation, p_note, v_batch, auth.uid()
    FROM public.chapters c
    JOIN public.books b ON b.id = c.book_id
    WHERE c.id = v_chapter_id AND public._se_book_unlocked(b.id);
    GET DIAGNOSTICS v_inserted = ROW_COUNT;
  END LOOP;
END;
$$;

-- ── 8. Mark a chapter read; auto-advance the queue ────────────────
-- Called from the reader the moment she scrolls to the end of a
-- chapter. No-ops silently for signed-wall books (nothing to
-- advance) and for chapters outside the current queue entry.
CREATE OR REPLACE FUNCTION public.se_mark_chapter_read(p_chapter_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_book_id  uuid;
  v_queue_id uuid;
  v_total    bigint;
  v_read     bigint;
BEGIN
  IF NOT public.is_senior_editor() THEN RAISE EXCEPTION 'Senior Editors only.'; END IF;

  SELECT c.book_id INTO v_book_id FROM public.chapters c
   WHERE c.id = p_chapter_id AND c.status <> 'draft';
  IF v_book_id IS NULL THEN RETURN; END IF;

  SELECT id INTO v_queue_id FROM public.se_review_queue
   WHERE book_id = v_book_id AND status = 'pending';
  IF v_queue_id IS NULL THEN RETURN; END IF;
  IF NOT public._se_book_unlocked(v_book_id) THEN RETURN; END IF;

  INSERT INTO public.se_chapter_reads (queue_id, chapter_id)
  VALUES (v_queue_id, p_chapter_id)
  ON CONFLICT (queue_id, chapter_id) DO NOTHING;

  SELECT COUNT(*) INTO v_total FROM public.chapters WHERE book_id = v_book_id AND status <> 'draft';
  SELECT COUNT(*) INTO v_read  FROM public.se_chapter_reads WHERE queue_id = v_queue_id;

  IF v_total > 0 AND v_read >= v_total THEN
    UPDATE public.se_review_queue SET status = 'completed', completed_at = now() WHERE id = v_queue_id;
  END IF;
END;
$$;
