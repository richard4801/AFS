-- ============================================================
-- Admin: manually link a book to the prompt claim it was
-- developed from. Backfill tool for books created before
-- link_prompt_claim_to_book() started auto-linking new ones
-- (sql/book_outline_and_prompt_link.sql) -- those pre-existing
-- books have a claim sitting in prompt_claims with book_id still
-- null, and nothing writer-facing lets them fix that after the
-- fact (the auto-link only ever fires at book-creation time).
-- Run in Supabase → SQL Editor.
-- ============================================================

-- ── 1. List a writer's prompt claims, admin view ─────────────────
CREATE OR REPLACE FUNCTION public.admin_get_writer_prompt_claims(p_writer_id uuid)
RETURNS TABLE (claim_id uuid, prompt_id uuid, prompt_title text, status text, book_id uuid, claimed_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true) THEN
    RAISE EXCEPTION 'Admins only.';
  END IF;
  RETURN QUERY
  SELECT c.id, c.prompt_id, p.title, c.status, c.book_id, c.claimed_at
  FROM public.prompt_claims c
  JOIN public.writing_prompts p ON p.id = c.prompt_id
  WHERE c.writer_id = p_writer_id
  ORDER BY c.claimed_at DESC;
END;
$$;

-- ── 2. Link a claim to a book (admin) ────────────────────────────
-- Cross-checked against both records' owner so an admin can't
-- accidentally cross-wire a claim to a different writer's book.
CREATE OR REPLACE FUNCTION public.admin_link_prompt_claim_to_book(p_claim_id uuid, p_book_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_claim_writer uuid;
  v_book_author  uuid;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true) THEN
    RAISE EXCEPTION 'Admins only.';
  END IF;

  SELECT writer_id INTO v_claim_writer FROM public.prompt_claims WHERE id = p_claim_id;
  IF v_claim_writer IS NULL THEN
    RAISE EXCEPTION 'Claim not found.';
  END IF;

  SELECT author_id INTO v_book_author FROM public.books WHERE id = p_book_id;
  IF v_book_author IS NULL THEN
    RAISE EXCEPTION 'Book not found.';
  END IF;

  IF v_claim_writer <> v_book_author THEN
    RAISE EXCEPTION 'This prompt claim and book belong to different writers.';
  END IF;

  UPDATE public.prompt_claims SET book_id = p_book_id WHERE id = p_claim_id;
END;
$$;

-- ── 3. Undo a link (admin) ────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_unlink_prompt_claim(p_claim_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true) THEN
    RAISE EXCEPTION 'Admins only.';
  END IF;
  UPDATE public.prompt_claims SET book_id = NULL WHERE id = p_claim_id;
END;
$$;
