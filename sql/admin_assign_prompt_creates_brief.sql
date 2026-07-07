-- ============================================================
-- Assigning a prompt to a writer now also becomes their "Project
-- Brief" -- previously admin_assign_prompt() only created a
-- prompt_claims row, which marks the prompt "mine" in the writer's
-- feed but has zero connection to the separate briefs table that
-- actually powers the Project Brief card on their dashboard home.
-- Those are two genuinely disconnected systems (no shared column,
-- no existing linkage) -- this makes the single "Assign" action do
-- both, instead of requiring a second manual trip through the
-- separate Brief editor to duplicate the same content by hand.
-- Run in Supabase → SQL Editor.
-- ============================================================

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
    VALUES (p_prompt_id, p_writer_id, now() + interval '72 hours')
    RETURNING * INTO v_claim;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'This prompt was just claimed by someone else.';
  END;

  -- Becomes the writer's Project Brief. A prompt's brief is one text
  -- blob where briefs.synopsis/character_notes/plot_outline are three
  -- distinct structured fields with no clean way to auto-split
  -- between them -- the whole brief lands in synopsis, leaving
  -- character_notes/plot_outline for admin to fill in by hand
  -- afterward if they want to (same as any other brief). If she
  -- already has an active brief, it's updated in place rather than
  -- left orphaned as a second row -- update only touches the fields
  -- a prompt can actually supply, so anything already filled in on
  -- character_notes/plot_outline/writing_instructions survives.
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

  -- In-app notification, matching the existing manual Brief flow's
  -- own notification exactly (same type/title/wording) -- the email
  -- side of that flow is a client-side fetch to an edge function and
  -- stays in admin.html, since a SQL function has no way to make that
  -- HTTP call itself.
  INSERT INTO public.notifications (user_id, type, title, body)
  VALUES (
    p_writer_id, 'brief_assigned', 'Project Brief Ready',
    'Your project brief "' || v_prompt.title || '" has been assigned. Open your dashboard to read it.'
  );

  RETURN v_claim;
END;
$$;
