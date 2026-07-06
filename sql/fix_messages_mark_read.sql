-- Fixes message-tampering via the mark-read path. The old
-- "messages_mark_read" UPDATE policy restricted WHO could update a message
-- (the recipient) but not WHICH columns — so a recipient could PATCH the
-- body/sender_id/sent_as/parent_id of any message addressed to them via a
-- raw PostgREST call, forging chat history after the fact.
--
-- Replaced with a narrow SECURITY DEFINER RPC that only ever sets read_at,
-- and only on messages addressed to the caller. The broad UPDATE policy is
-- dropped so raw column writes are no longer possible at all. (edit_message,
-- the legitimate body-edit path, is a separate sender-only RPC and is
-- unaffected.) Run once in Supabase SQL Editor — safe to re-run.

CREATE OR REPLACE FUNCTION public.mark_messages_read(p_sender_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;
  UPDATE public.messages
     SET read_at = now()
   WHERE sender_id = p_sender_id
     AND recipient_id = auth.uid()
     AND read_at IS NULL;
END;
$$;
GRANT EXECUTE ON FUNCTION public.mark_messages_read(uuid) TO authenticated;

-- Remove the over-broad UPDATE policy now that mark-read goes through the
-- RPC above. (Kept the read + insert policies; edit_message is its own RPC.)
DROP POLICY IF EXISTS "messages_mark_read" ON public.messages;

NOTIFY pgrst, 'reload schema';
