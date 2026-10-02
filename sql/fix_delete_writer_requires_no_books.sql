-- ============================================================
-- admin_delete_writer() used to delete a writer's auth.users row
-- unconditionally, which cascades straight through profiles to
-- their books, chapters (author_id references profiles(id) on
-- delete cascade) and earnings -- permanently, with no recovery
-- path. That's by design for a writer who truly has nothing worth
-- keeping, but it's also exactly what destroyed 30 chapters after
-- a book transfer that (due to a separate, now-fixed bug) hadn't
-- actually finished moving chapter ownership to the new writer.
--
-- Now: deleting a writer who still owns any book is refused up
-- front, naming the book(s), so the admin has to explicitly
-- transfer or delete each one first -- a deliberate choice per
-- book, instead of a silent side effect of removing the account.
-- ============================================================

CREATE OR REPLACE FUNCTION public.admin_delete_writer(p_writer_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_book_titles text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true) THEN
    RAISE EXCEPTION 'Admins only.';
  END IF;
  IF p_writer_id = auth.uid() THEN
    RAISE EXCEPTION 'Cannot delete your own account';
  END IF;

  SELECT string_agg('"' || title || '"', ', ')
    INTO v_book_titles
    FROM public.books
   WHERE author_id = p_writer_id;

  IF v_book_titles IS NOT NULL THEN
    RAISE EXCEPTION
      'This writer still owns % — transfer each book to another writer or delete it first. Removing the account now would permanently destroy their chapters.',
      v_book_titles;
  END IF;

  DELETE FROM auth.users WHERE id = p_writer_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Writer not found'; END IF;
  RETURN json_build_object('success', true);
END;
$$;
GRANT EXECUTE ON FUNCTION public.admin_delete_writer(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
