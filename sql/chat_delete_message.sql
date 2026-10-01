-- ============================================================
-- Lets admin delete a message in any writer conversation they're part
-- of -- their own sent messages, or ones the writer sent them. Any
-- other user (writer, senior editor) can still only delete their own
-- sent message, matching edit_message()'s existing sender-only rule.
--
-- A hard delete, not a soft/tombstone one -- messages.parent_id already
-- has ON DELETE SET NULL (sql/private_chat.sql), so a reply quoting a
-- deleted message just loses its preview rather than breaking.
-- ============================================================

CREATE OR REPLACE FUNCTION public.delete_message(p_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin boolean;
  v_rows     int;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  SELECT is_admin INTO v_is_admin FROM public.profiles WHERE id = auth.uid();

  DELETE FROM public.messages
   WHERE id = p_id
     AND (sender_id = auth.uid() OR (v_is_admin AND recipient_id = auth.uid()));
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN
    RAISE EXCEPTION 'Message not found or not permitted.';
  END IF;
END;
$$;
GRANT EXECUTE ON FUNCTION public.delete_message(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
