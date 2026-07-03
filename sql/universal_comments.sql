-- ============================================================
-- Universal chapter comments: one identity-masked feed, one
-- posting RPC, used by admin, writer, and Senior Editor alike.
-- Run in Supabase → SQL Editor.
--
-- Additive only — the existing paragraph_ref-based columns/rows and
-- the earlier se_post_comment() function are untouched. This adds
-- the shared reading/writing/moderation path the new universal
-- editor UI (admin + writer, replacing the old read-only view) and
-- the Senior Editor's reader both call.
-- ============================================================

-- ── 1. Identity-masked comment feed for a chapter ─────────────────
-- Caller must be: an admin, the chapter's own writer, or a Senior
-- Editor (signed book only) — enforced here, independent of RLS, so
-- Realtime's own row-level checks are a second, not the only, gate.
CREATE OR REPLACE FUNCTION public.get_chapter_comments(p_chapter_id uuid)
RETURNS TABLE (
  id uuid, parent_id uuid, body text, resolved boolean,
  start_offset int, end_offset int, quoted_text text,
  author_role text, author_label text, author_id uuid, is_own boolean,
  created_at timestamptz
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  -- Qualified with the "pr" alias: this function's RETURNS TABLE declares an
  -- output column named "id", which plpgsql exposes as a variable throughout
  -- the function body — a bare "id" here is ambiguous against that variable.
  IF NOT (
    EXISTS (SELECT 1 FROM public.profiles pr WHERE pr.id = auth.uid() AND pr.is_admin = true)
    OR EXISTS (
      SELECT 1 FROM public.chapters c JOIN public.books b ON b.id = c.book_id
      WHERE c.id = p_chapter_id AND b.author_id = auth.uid()
    )
    OR (public.is_senior_editor() AND public.chapter_book_is_signed(p_chapter_id))
  ) THEN
    RAISE EXCEPTION 'Not authorized.';
  END IF;

  RETURN QUERY
  SELECT cm.id, cm.parent_id, cm.body, cm.resolved,
         cm.start_offset, cm.end_offset, cm.quoted_text,
         COALESCE(cm.author_role, 'writer')::text,
         CASE
           WHEN cm.author_role = 'senior_editor' THEN 'God Mother'
           WHEN cm.author_role = 'admin'         THEN 'Editor'
           ELSE COALESCE(p.name, p.email, 'Writer')
         END::text,
         cm.reviewer_id, (cm.reviewer_id = auth.uid()),
         cm.created_at
  FROM public.comments cm
  LEFT JOIN public.profiles p ON p.id = cm.reviewer_id
  WHERE cm.chapter_id = p_chapter_id AND cm.start_offset IS NOT NULL
  ORDER BY cm.start_offset ASC, cm.created_at ASC;
END;
$$;

-- ── 2. Universal posting RPC ──────────────────────────────────────
-- Determines the caller's role itself (never trusts a client-supplied
-- role) and enforces: writers cannot reply to a Senior Editor's
-- comment — only the admin can.
CREATE OR REPLACE FUNCTION public.post_chapter_comment(
  p_chapter_id uuid, p_start_offset int, p_end_offset int, p_quoted_text text,
  p_body text, p_parent_id uuid DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_role text;
  v_id uuid;
  v_parent_role text;
BEGIN
  IF p_body IS NULL OR length(trim(p_body)) = 0 THEN
    RAISE EXCEPTION 'Comment cannot be empty.';
  END IF;

  IF EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true) THEN
    v_role := 'admin';
  ELSIF public.is_senior_editor() THEN
    v_role := 'senior_editor';
    IF NOT public.chapter_book_is_signed(p_chapter_id) THEN
      RAISE EXCEPTION 'Chapter not found.';
    END IF;
  ELSIF EXISTS (
    SELECT 1 FROM public.chapters c JOIN public.books b ON b.id = c.book_id
    WHERE c.id = p_chapter_id AND b.author_id = auth.uid()
  ) THEN
    v_role := 'writer';
  ELSE
    RAISE EXCEPTION 'Not authorized to comment on this chapter.';
  END IF;

  IF p_parent_id IS NOT NULL THEN
    SELECT author_role INTO v_parent_role FROM public.comments WHERE id = p_parent_id;
    IF v_role = 'writer' AND v_parent_role = 'senior_editor' THEN
      RAISE EXCEPTION 'Only the admin can reply to the Senior Editor''s notes.';
    END IF;
  END IF;

  INSERT INTO public.comments (chapter_id, reviewer_id, author_role, start_offset, end_offset, quoted_text, parent_id, body)
  VALUES (p_chapter_id, auth.uid(), v_role, p_start_offset, p_end_offset, p_quoted_text, p_parent_id, p_body)
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

-- ── 3. Resolve / reopen — admin can moderate any comment; everyone
-- else only their own. ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.set_comment_resolved(p_id uuid, p_resolved boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true)
    OR EXISTS (SELECT 1 FROM public.comments WHERE id = p_id AND reviewer_id = auth.uid())
  ) THEN
    RAISE EXCEPTION 'Not authorized.';
  END IF;
  UPDATE public.comments SET resolved = p_resolved, updated_at = now() WHERE id = p_id;
END;
$$;

-- ── 4. Delete — same rule as resolve ──────────────────────────────
CREATE OR REPLACE FUNCTION public.delete_own_comment(p_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true)
    OR EXISTS (SELECT 1 FROM public.comments WHERE id = p_id AND reviewer_id = auth.uid())
  ) THEN
    RAISE EXCEPTION 'Not authorized.';
  END IF;
  DELETE FROM public.comments WHERE id = p_id;
END;
$$;
