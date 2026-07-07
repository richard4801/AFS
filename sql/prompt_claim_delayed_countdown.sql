-- ============================================================
-- The 72-hour countdown on a claimed/assigned prompt now starts the
-- moment the writer actually opens it, not the moment it's claimed
-- or assigned. Previously expires_at was stamped now()+72h at
-- INSERT time regardless of whether anyone had looked at it yet --
-- a writer who didn't check their dashboard for a day lost that day
-- for free, and a prompt assigned overnight could burn through most
-- of its window before she ever saw it.
-- Run in Supabase → SQL Editor.
-- ============================================================

-- ── 1. expires_at becomes "not started yet" until she opens it ───
ALTER TABLE public.prompt_claims
  ALTER COLUMN expires_at DROP NOT NULL;

-- ── 2. claim_prompt(): no longer stamps a deadline at claim time ─
CREATE OR REPLACE FUNCTION public.claim_prompt(p_prompt_id uuid)
RETURNS public.prompt_claims LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_claim public.prompt_claims;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  PERFORM public.release_expired_prompt_claims();

  IF NOT EXISTS (SELECT 1 FROM public.writing_prompts WHERE id = p_prompt_id AND is_active = true) THEN
    RAISE EXCEPTION 'This prompt is no longer available.';
  END IF;

  IF EXISTS (SELECT 1 FROM public.prompt_claims WHERE writer_id = v_uid AND status = 'active') THEN
    RAISE EXCEPTION 'You already have an active prompt. Finish or release it first.';
  END IF;

  BEGIN
    INSERT INTO public.prompt_claims (prompt_id, writer_id, expires_at)
    VALUES (p_prompt_id, v_uid, NULL)
    RETURNING * INTO v_claim;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'Someone just claimed this prompt. Please pick another.';
  END;

  RETURN v_claim;
END;
$$;

-- ── 3. admin_assign_prompt(): same change, rest of the function
--       (the briefs upsert + notification) unchanged ──────────────
CREATE OR REPLACE FUNCTION public.admin_assign_prompt(p_prompt_id uuid, p_writer_id uuid)
RETURNS public.prompt_claims LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_claim   public.prompt_claims;
  v_prompt  record;
  v_brief_id uuid;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true) THEN
    RAISE EXCEPTION 'Admins only.';
  END IF;

  PERFORM public.release_expired_prompt_claims();

  SELECT title, genre, brief, sample_chapter_url INTO v_prompt
  FROM public.writing_prompts
  WHERE id = p_prompt_id AND is_active = true AND review_status = 'approved';
  IF v_prompt IS NULL THEN
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
    VALUES (p_prompt_id, p_writer_id, NULL)
    RETURNING * INTO v_claim;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'This prompt was just claimed by someone else.';
  END;

  SELECT id INTO v_brief_id FROM public.briefs WHERE writer_id = p_writer_id AND status = 'active';
  IF v_brief_id IS NOT NULL THEN
    UPDATE public.briefs
       SET title = v_prompt.title,
           genre = COALESCE(v_prompt.genre, genre),
           synopsis = v_prompt.brief,
           sample_book_url = v_prompt.sample_chapter_url,
           updated_at = now()
     WHERE id = v_brief_id;
  ELSE
    INSERT INTO public.briefs (writer_id, created_by, title, genre, synopsis, sample_book_url)
    VALUES (p_writer_id, auth.uid(), v_prompt.title, COALESCE(v_prompt.genre, 'Werewolf Romance'),
            v_prompt.brief, v_prompt.sample_chapter_url);
  END IF;

  INSERT INTO public.notifications (user_id, type, title, body)
  VALUES (
    p_writer_id, 'brief_assigned', 'Project Brief Ready',
    'Your project brief "' || v_prompt.title || '" has been assigned. Open your dashboard to read it.'
  );

  RETURN v_claim;
END;
$$;

-- ── 4. Starts the clock the first (and only the first) time she
--       opens her claimed prompt's detail view ────────────────────
CREATE OR REPLACE FUNCTION public.mark_prompt_claim_opened(p_claim_id uuid)
RETURNS timestamptz LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_expires_at timestamptz;
BEGIN
  UPDATE public.prompt_claims
     SET expires_at = COALESCE(expires_at, now() + interval '72 hours')
   WHERE id = p_claim_id AND writer_id = auth.uid() AND status = 'active'
   RETURNING expires_at INTO v_expires_at;
  RETURN v_expires_at;
END;
$$;

-- ── 5. A claim that's never been opened has no deadline yet -------
CREATE OR REPLACE FUNCTION public.release_expired_prompt_claims()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  n integer;
BEGIN
  UPDATE public.prompt_claims
     SET status = 'expired', released_at = now()
   WHERE status = 'active' AND expires_at IS NOT NULL AND expires_at <= now();
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$$;

-- ── 6. Retroactively pause every claim that's already counting ───
-- Never disadvantages anyone -- this only ever gives back time that
-- was already ticking away unseen, including the one sent out just
-- before this migration. Her next open starts a fresh 72 hours.
UPDATE public.prompt_claims SET expires_at = NULL WHERE status = 'active';
