-- ============================================================
-- Senior Editor: chapter-level recommendations routed to the
-- ADMIN (not the writer). The admin then uses their existing
-- approve / request-revision actions to act officially — this
-- table only ever produces a notice for the admin, never a
-- writer-facing change by itself.
-- Run in Supabase → SQL Editor.
-- ============================================================

-- ── 1. Recommendations table ─────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.se_chapter_recommendations (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  chapter_id     uuid        NOT NULL REFERENCES public.chapters(id) ON DELETE CASCADE,
  book_id        uuid        NOT NULL REFERENCES public.books(id) ON DELETE CASCADE,
  recommendation text        NOT NULL CHECK (recommendation IN ('approve', 'needs_work')),
  note           text,
  batch_id       uuid        NOT NULL DEFAULT gen_random_uuid(), -- groups chapters flagged together in one action
  created_by     uuid        REFERENCES auth.users(id),
  created_at     timestamptz NOT NULL DEFAULT now(),
  admin_status   text        NOT NULL DEFAULT 'pending' CHECK (admin_status IN ('pending', 'actioned', 'dismissed')),
  actioned_by    uuid        REFERENCES auth.users(id),
  actioned_at    timestamptz
);

CREATE INDEX IF NOT EXISTS se_chapter_recs_chapter ON public.se_chapter_recommendations (chapter_id, created_at DESC);
CREATE INDEX IF NOT EXISTS se_chapter_recs_pending ON public.se_chapter_recommendations (admin_status) WHERE admin_status = 'pending';

ALTER TABLE public.se_chapter_recommendations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "se_recs_se_own" ON public.se_chapter_recommendations;
CREATE POLICY "se_recs_se_own" ON public.se_chapter_recommendations
  FOR SELECT USING (public.is_senior_editor() AND created_by = auth.uid());

DROP POLICY IF EXISTS "se_recs_admin_all" ON public.se_chapter_recommendations;
CREATE POLICY "se_recs_admin_all" ON public.se_chapter_recommendations
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true)
  );

-- ── 2. Senior Editor submits a batch recommendation ───────────────
-- One or many chapters, one note, one recommendation — never touches
-- chapters.status or notifies the writer. Admin-only, silent to writers.
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
    WHERE c.id = v_chapter_id AND b.is_signed = true;
    GET DIAGNOSTICS v_inserted = ROW_COUNT;
  END LOOP;
END;
$$;

-- ── 3. Admin's inbox of pending recommendations, grouped by batch ─
CREATE OR REPLACE FUNCTION public.get_admin_se_recommendations()
RETURNS TABLE (
  batch_id uuid, book_id uuid, writer_id uuid, book_title text, writer_name text,
  recommendation text, note text, created_at timestamptz,
  chapter_numbers int[], chapter_count bigint
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true) THEN
    RAISE EXCEPTION 'Admins only.';
  END IF;
  RETURN QUERY
  SELECT r.batch_id, b.id::uuid, b.author_id::uuid, b.title::text,
         COALESCE(p.name, p.email, 'Writer')::text,
         r.recommendation::text, MAX(r.note)::text, MIN(r.created_at),
         array_agg(c.chapter_number ORDER BY c.chapter_number),
         COUNT(*)::bigint
  FROM public.se_chapter_recommendations r
  JOIN public.books b ON b.id = r.book_id
  JOIN public.chapters c ON c.id = r.chapter_id
  LEFT JOIN public.profiles p ON p.id = b.author_id
  WHERE r.admin_status = 'pending'
  GROUP BY r.batch_id, b.id, b.title, p.name, p.email, r.recommendation
  ORDER BY MIN(r.created_at) DESC;
END;
$$;

-- ── 4. Admin dismisses a batch without further action ─────────────
CREATE OR REPLACE FUNCTION public.admin_dismiss_se_batch(p_batch_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true) THEN
    RAISE EXCEPTION 'Admins only.';
  END IF;
  UPDATE public.se_chapter_recommendations
     SET admin_status = 'dismissed', actioned_by = auth.uid(), actioned_at = now()
   WHERE batch_id = p_batch_id AND admin_status = 'pending';
END;
$$;

-- ── 5. Auto-clear when admin acts via their existing approve/reject ──
-- Called from approveChapter()/doReject() so a recommendation doesn't
-- sit "pending" forever once the admin has actually handled it.
CREATE OR REPLACE FUNCTION public.admin_mark_se_recs_actioned(p_chapter_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true) THEN
    RAISE EXCEPTION 'Admins only.';
  END IF;
  UPDATE public.se_chapter_recommendations
     SET admin_status = 'actioned', actioned_by = auth.uid(), actioned_at = now()
   WHERE chapter_id = p_chapter_id AND admin_status = 'pending';
END;
$$;

-- ── 6. Extend get_se_book_chapters with her own recommendation state ──
-- DROP first: return column list changes (adds my_recommendation /
-- my_recommendation_status), and Postgres refuses CREATE OR REPLACE
-- across a return-type change.
DROP FUNCTION IF EXISTS public.get_se_book_chapters(uuid);
CREATE OR REPLACE FUNCTION public.get_se_book_chapters(p_book_id uuid)
RETURNS TABLE (
  id uuid, chapter_number int, title text, status text, word_count int, updated_at timestamptz,
  my_recommendation text, my_recommendation_status text
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_senior_editor() THEN RAISE EXCEPTION 'Senior Editors only.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.books b WHERE b.id = p_book_id AND b.is_signed = true) THEN
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
