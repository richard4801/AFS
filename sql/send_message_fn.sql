-- ============================================================
-- Definitive chat fix: SECURITY DEFINER send_message function
-- Run in Supabase Dashboard → SQL Editor
-- ============================================================
-- Root cause: if admin is logged in on another tab of the same
-- browser, localStorage session gets overwritten. Then auth.uid()
-- no longer equals the sender_id the client tries to insert,
-- causing "new row violates row-level security" on the 2nd message.
-- This function always sets sender_id = auth.uid() server-side,
-- so the session state of other tabs is irrelevant.

CREATE OR REPLACE FUNCTION send_message(
  p_recipient_id uuid,
  p_body         text,
  p_sent_as      text DEFAULT 'writer'
)
RETURNS SETOF messages
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;
  IF length(trim(p_body)) = 0 THEN
    RAISE EXCEPTION 'Message body cannot be empty';
  END IF;
  RETURN QUERY
  INSERT INTO messages (sender_id, recipient_id, body, sent_as)
  VALUES (auth.uid(), p_recipient_id, p_body, p_sent_as)
  RETURNING *;
END;
$$;

-- Allow any authenticated user to call it
GRANT EXECUTE ON FUNCTION send_message(uuid, text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
