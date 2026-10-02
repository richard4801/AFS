-- ============================================================
-- Fixes admin_transfer_book() leaving every existing chapter's
-- author_id pointing at the OLD writer after a book hand-over.
--
-- chapters.author_id is a real, separately-stored column (set at
-- chapter creation -- see dashboard/index.html's saveFSChapter() and
-- dashboard/admin.html's addNewChapter()), not derived from
-- books.author_id through a join, despite admin_transfer_book()'s own
-- comment claiming otherwise. Since the chapters RLS policies (the
-- writer's own SELECT and "chapters: writer update own" policies)
-- scope access by chapters.author_id = auth.uid() directly, a book
-- handed over by admin_transfer_book() left every one of its existing
-- chapters still owned by the OLD writer at the row level -- the new
-- writer's "my chapters" queries returned nothing and the book
-- appeared completely empty, while the old writer separately lost the
-- book from their own list (filtered by books.author_id) and could no
-- longer reach the chapters either way. Nothing was deleted; every
-- row stayed exactly where it was, just invisible to both writers
-- through the normal app.
-- ============================================================

-- One-time repair: every chapter already left mismatched by a past
-- transfer gets its author_id corrected to match its book's current
-- owner, restoring it to view immediately. Safe to re-run -- the
-- WHERE clause only ever touches rows that are actually out of sync.
UPDATE public.chapters c
   SET author_id = b.author_id
  FROM public.books b
 WHERE c.book_id = b.id
   AND c.author_id IS DISTINCT FROM b.author_id;

-- Going forward: admin_transfer_book() now moves chapters.author_id
-- along with books.author_id in the same call, so this can't recur.
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

  -- chapters.author_id is its own stored column -- it has to move
  -- with the book explicitly, or every existing chapter stays owned
  -- by the old writer at the row level and becomes invisible to the
  -- new writer through RLS, which is exactly the bug this migration
  -- fixes.
  UPDATE public.chapters SET author_id = p_new_writer_id WHERE book_id = p_book_id;

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

NOTIFY pgrst, 'reload schema';
