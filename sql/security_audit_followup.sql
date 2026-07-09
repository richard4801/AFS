-- ============================================================
-- Follow-up security fixes from a second audit pass (deferred
-- Low-severity backlog + a review of everything shipped since the
-- original audit). Run in Supabase → SQL Editor.
-- ============================================================

-- ── 1. CONFIRMED: a writer can self-grant Senior Editor access ───
-- profiles' own writer-update policy has protected is_admin since
-- the original audit, but is_senior_editor (added later, in
-- senior_editor.sql) was never added to the same check -- a writer
-- could call .update({is_senior_editor: true}).eq('id', myId) and
-- pass RLS, self-granting SE privileges (access to every signed
-- book, every writer's chapter content via the SE-only RPCs, etc).
DROP POLICY IF EXISTS "profiles: writer update own" ON public.profiles;
CREATE POLICY "profiles: writer update own"
  ON public.profiles FOR UPDATE
  USING      (auth.uid() = id)
  WITH CHECK (auth.uid() = id AND is_admin = false AND is_senior_editor = false);

-- Defensive: if the very first schema (dashboard/setup.sql, superseded
-- by schema.sql) ever ran directly against this database, its older
-- "profiles: update own" policy has no is_admin/is_senior_editor guard
-- at all -- RLS policies for the same operation are OR'd together, so
-- its mere presence would silently bypass the fix above regardless of
-- how tight the new policy is. Safe no-op if it was never applied.
DROP POLICY IF EXISTS "profiles: update own" ON public.profiles;

-- ── 2. CONFIRMED: a writer can self-approve their own chapter ────
-- The existing policy's USING clause requires the chapter to
-- currently be draft/revision_requested, but WITH CHECK never
-- constrained what status the writer could set it TO -- a writer
-- could .update({status: 'approved'}) directly on their own row,
-- bypassing the entire admin-approval workflow. 'submitted' stays
-- allowed (that's the real submit-for-review action); 'approved' is
-- now blocked -- only admin's own FOR ALL policy can set that.
DROP POLICY IF EXISTS "chapters: writer update own" ON public.chapters;
CREATE POLICY "chapters: writer update own"
  ON public.chapters FOR UPDATE
  USING (
    auth.uid() = author_id
    AND status IN ('draft', 'revision_requested')
  )
  WITH CHECK (
    auth.uid() = author_id
    AND status IN ('draft', 'submitted', 'revision_requested')
  );

-- ── 3. se_start_reviewing() skipped the unlock gate its sibling
--       functions all enforce ───────────────────────────────────
-- Without this, Christine could stamp started_at on a LOCKED, future
-- queue entry (not just the current unlocked one), corrupting the
-- "has she actually started this book" signal the whole feature
-- exists to track. Silently no-ops for a book that isn't currently
-- hers to open, matching se_mark_chapter_read()'s own pattern for
-- the same situation rather than raising an error for what's really
-- just a client calling this at a moment it doesn't apply.
CREATE OR REPLACE FUNCTION public.se_start_reviewing(p_book_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_senior_editor() THEN RAISE EXCEPTION 'Senior Editors only.'; END IF;
  IF NOT public._se_book_unlocked(p_book_id) THEN RETURN; END IF;
  UPDATE public.se_review_queue
     SET started_at = COALESCE(started_at, now())
   WHERE book_id = p_book_id AND status = 'pending';
END;
$$;

-- ── 4. _se_book_unlocked() had no caller-role check of its own ───
-- Every function that USES this helper already checks is_senior_editor()
-- first, so this was never exploitable through the normal app flow --
-- but the helper itself is a plain SECURITY DEFINER function with
-- default PUBLIC execute rights, directly callable via RPC by ANY
-- authenticated user (any writer). That let a writer learn whether an
-- arbitrary book is signed, or is the current head of Christine's
-- private review queue, by guessing/enumerating book UUIDs -- a real,
-- if minor, information leak about other writers' books. Adding the
-- same check inline is a no-op for every legitimate caller (which
-- already passed it before ever reaching here) and closes the direct-
-- call path.
CREATE OR REPLACE FUNCTION public._se_book_unlocked(p_book_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT
    public.is_senior_editor()
    AND (
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
      )
    );
$$;

-- ── 5. Word-count functions never pinned search_path ─────────────
-- Both only ever call fully-schema-qualified names today, so there's
-- no live exploit path -- but it's the one inconsistency against this
-- codebase's otherwise-universal SECURITY DEFINER SET search_path
-- convention, and a future edit that adds an unqualified call here
-- would silently become exploitable. Cheap to close now.
CREATE OR REPLACE FUNCTION public._compute_word_count(p_content text)
RETURNS int LANGUAGE plpgsql IMMUTABLE SET search_path = public AS $$
DECLARE
  v_stripped text;
BEGIN
  IF p_content IS NULL THEN RETURN 0; END IF;
  v_stripped := regexp_replace(p_content, '&(nbsp|#160|#xa0|#x00a0);', ' ', 'gi');
  v_stripped := replace(v_stripped, chr(160), ' ');
  v_stripped := trim(both from regexp_replace(regexp_replace(v_stripped, '<[^>]*>', ' ', 'g'), '\s+', ' ', 'g'));
  IF v_stripped = '' THEN RETURN 0; END IF;
  RETURN array_length(regexp_split_to_array(v_stripped, '\s+'), 1);
END;
$$;

CREATE OR REPLACE FUNCTION public.trg_chapters_word_count()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  NEW.word_count := public._compute_word_count(NEW.content);
  RETURN NEW;
END;
$$;
