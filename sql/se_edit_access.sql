-- ============================================================
-- Senior Editor "request edit access" flow. Run in Supabase →
-- SQL Editor.
--
-- She requests edit access to a specific chapter; the admin sees the
-- request in the SE Notes inbox and approves or denies it. Once
-- approved, her reader for that chapter becomes the same standard,
-- fully-mirrored editable editor writer/admin use — same overlay
-- highlights, same identity-masked comments — instead of read-only.
-- Purely additive; nothing about the existing read-only path changes
-- for chapters she hasn't been granted access to.
-- ============================================================

-- ── 1. Access table ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.se_edit_access (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  chapter_id   uuid NOT NULL REFERENCES public.chapters(id) ON DELETE CASCADE,
  book_id      uuid NOT NULL REFERENCES public.books(id) ON DELETE CASCADE,
  se_id        uuid NOT NULL REFERENCES public.profiles(id),
  status       text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'denied', 'revoked')),
  requested_at timestamptz NOT NULL DEFAULT now(),
  decided_at   timestamptz,
  decided_by   uuid REFERENCES public.profiles(id),
  UNIQUE (chapter_id, se_id)
);

ALTER TABLE public.se_edit_access ENABLE ROW LEVEL SECURITY;

-- No direct table policies — every access path goes through the
-- SECURITY DEFINER functions below, same pattern as every other
-- Senior Editor write in this app.

-- ── 2. SE requests access — idempotent (re-requesting after a denial
-- or revocation resets it back to pending; an existing pending/approved
-- request is left alone). ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.se_request_chapter_edit_access(p_chapter_id uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_book_id uuid;
  v_status  text;
BEGIN
  IF NOT public.is_senior_editor() THEN RAISE EXCEPTION 'Senior Editors only.'; END IF;
  SELECT c.book_id INTO v_book_id
  FROM public.chapters c JOIN public.books b ON b.id = c.book_id
  WHERE c.id = p_chapter_id AND b.is_signed = true;
  IF v_book_id IS NULL THEN RAISE EXCEPTION 'Chapter not found.'; END IF;

  INSERT INTO public.se_edit_access (chapter_id, book_id, se_id, status)
  VALUES (p_chapter_id, v_book_id, auth.uid(), 'pending')
  ON CONFLICT (chapter_id, se_id) DO UPDATE
    SET status = CASE WHEN public.se_edit_access.status IN ('denied', 'revoked') THEN 'pending' ELSE public.se_edit_access.status END,
        requested_at = CASE WHEN public.se_edit_access.status IN ('denied', 'revoked') THEN now() ELSE public.se_edit_access.requested_at END,
        decided_at = CASE WHEN public.se_edit_access.status IN ('denied', 'revoked') THEN NULL ELSE public.se_edit_access.decided_at END,
        decided_by = CASE WHEN public.se_edit_access.status IN ('denied', 'revoked') THEN NULL ELSE public.se_edit_access.decided_by END
  RETURNING status INTO v_status;

  RETURN v_status;
END;
$$;

-- ── 3. SE checks her own status for a chapter (drives the reader's UI) ──
CREATE OR REPLACE FUNCTION public.get_se_chapter_edit_access(p_chapter_id uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT status FROM public.se_edit_access WHERE chapter_id = p_chapter_id AND se_id = auth.uid();
$$;

-- ── 4. Admin inbox of pending requests ────────────────────────────
CREATE OR REPLACE FUNCTION public.get_admin_se_edit_requests()
RETURNS TABLE (
  id uuid, chapter_id uuid, book_id uuid, writer_id uuid,
  book_title text, writer_name text, chapter_number int, chapter_title text,
  requested_at timestamptz
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  -- Qualified with "pr": this function's RETURNS TABLE declares an output
  -- column named "id", which plpgsql exposes as a variable throughout the
  -- function body — a bare "id" here is ambiguous against that variable.
  IF NOT EXISTS (SELECT 1 FROM public.profiles pr WHERE pr.id = auth.uid() AND pr.is_admin = true) THEN
    RAISE EXCEPTION 'Admins only.';
  END IF;
  RETURN QUERY
  SELECT ea.id, ea.chapter_id, ea.book_id, b.author_id,
         b.title::text, COALESCE(p.name, p.email, 'Writer')::text,
         c.chapter_number::int, c.title::text, ea.requested_at
  FROM public.se_edit_access ea
  JOIN public.chapters c ON c.id = ea.chapter_id
  JOIN public.books b    ON b.id = ea.book_id
  LEFT JOIN public.profiles p ON p.id = b.author_id
  WHERE ea.status = 'pending'
  ORDER BY ea.requested_at ASC;
END;
$$;

-- ── 5. Admin approves or denies ───────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_decide_se_edit_access(p_chapter_id uuid, p_approve boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true) THEN
    RAISE EXCEPTION 'Admins only.';
  END IF;
  UPDATE public.se_edit_access
     SET status = CASE WHEN p_approve THEN 'approved' ELSE 'denied' END,
         decided_at = now(),
         decided_by = auth.uid()
   WHERE chapter_id = p_chapter_id AND status = 'pending';
  IF NOT FOUND THEN RAISE EXCEPTION 'No pending request for this chapter.'; END IF;
END;
$$;

-- ── 6. Admin can revoke previously-approved access ────────────────
CREATE OR REPLACE FUNCTION public.admin_revoke_se_edit_access(p_chapter_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true) THEN
    RAISE EXCEPTION 'Admins only.';
  END IF;
  UPDATE public.se_edit_access
     SET status = 'revoked', decided_at = now(), decided_by = auth.uid()
   WHERE chapter_id = p_chapter_id AND status = 'approved';
END;
$$;

-- ── 7. SE saves her edits — only once approved for that chapter ──
CREATE OR REPLACE FUNCTION public.se_save_chapter_content(p_chapter_id uuid, p_content text, p_word_count int)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_senior_editor() THEN RAISE EXCEPTION 'Senior Editors only.'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.se_edit_access
    WHERE chapter_id = p_chapter_id AND se_id = auth.uid() AND status = 'approved'
  ) THEN
    RAISE EXCEPTION 'You do not have edit access to this chapter.';
  END IF;
  UPDATE public.chapters
     SET content = p_content, word_count = p_word_count, updated_at = now()
   WHERE id = p_chapter_id;
END;
$$;
