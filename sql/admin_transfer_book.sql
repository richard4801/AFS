-- ============================================================
-- Admin: hand a book over from one writer to another.
-- Run in Supabase → SQL Editor.
--
-- A single UPDATE on books.author_id handles chapter access and
-- content automatically (chapters have no author_id of their own --
-- everything derives through book_id → books.author_id), but it does
-- NOT fire the chapters-table trigger that keeps
-- contracts.cumulative_word_count in sync (sql/dual_compensation_model.sql),
-- since no chapters row actually changes. This function resyncs both
-- the old and new writer's word count explicitly so neither one's
-- Flat Rate progress / bonus status sits stale until their next
-- chapter save.
-- ============================================================

CREATE OR REPLACE FUNCTION public.admin_transfer_book(
  p_book_id       uuid,
  p_new_writer_id uuid
)
RETURNS public.books
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_old_writer_id uuid;
  v_book_title    text;
  v_new_writer_ok boolean;
  v_row           public.books;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true) THEN
    RAISE EXCEPTION 'Admins only.';
  END IF;

  SELECT author_id, title INTO v_old_writer_id, v_book_title FROM public.books WHERE id = p_book_id;
  IF v_old_writer_id IS NULL THEN
    RAISE EXCEPTION 'Book not found.';
  END IF;
  IF v_old_writer_id = p_new_writer_id THEN
    RAISE EXCEPTION 'That writer already owns this book.';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.profiles
     WHERE id = p_new_writer_id AND is_admin = false AND is_senior_editor = false
  ) INTO v_new_writer_ok;
  IF NOT v_new_writer_ok THEN
    RAISE EXCEPTION 'Target is not a valid writer account.';
  END IF;

  UPDATE public.books SET author_id = p_new_writer_id WHERE id = p_book_id
  RETURNING * INTO v_row;

  UPDATE public.contracts
     SET cumulative_word_count = COALESCE((
       SELECT SUM(c.word_count) FROM public.chapters c
       JOIN public.books b ON b.id = c.book_id
       WHERE b.author_id = contracts.writer_id
     ), 0)
   WHERE writer_id IN (v_old_writer_id, p_new_writer_id) AND status = 'signed';

  PERFORM public.sweep_contract_compensation_locks();

  INSERT INTO public.notifications (user_id, type, title, body)
  VALUES (
    p_new_writer_id, 'book_transferred', 'A Book Was Assigned to You',
    'You''ve been handed ownership of "' || v_book_title || '". It''s now in your Books tab.'
  );

  RETURN v_row;
END;
$$;
GRANT EXECUTE ON FUNCTION public.admin_transfer_book(uuid, uuid) TO authenticated;
