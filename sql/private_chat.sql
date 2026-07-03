-- ============================================================
-- Phase 3: reply-to and message editing for the existing 1:1
-- messages table, used both by the writer↔admin chat (unchanged
-- UI, still works exactly as before) and the new, dedicated
-- admin↔Senior Editor private chat.
-- Run in Supabase → SQL Editor.
-- ============================================================

-- 1. New columns — both nullable, so existing rows/behavior are untouched.
ALTER TABLE public.messages ADD COLUMN IF NOT EXISTS parent_id  uuid REFERENCES public.messages(id) ON DELETE SET NULL;
ALTER TABLE public.messages ADD COLUMN IF NOT EXISTS edited_at  timestamptz;

-- 2. send_message gains an optional p_parent_id (reply-to). The old
-- 3-arg signature is dropped first — Postgres treats a new trailing
-- argument as a distinct overload otherwise, and PostgREST would then
-- have two candidate functions to choose between for 3-arg calls.
DROP FUNCTION IF EXISTS public.send_message(uuid, text, text);
CREATE OR REPLACE FUNCTION public.send_message(
  p_recipient_id uuid,
  p_body         text,
  p_sent_as      text DEFAULT 'writer',
  p_parent_id    uuid DEFAULT NULL
)
RETURNS SETOF public.messages
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
  IF p_parent_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.messages m WHERE m.id = p_parent_id
      AND (m.sender_id = auth.uid() OR m.recipient_id = auth.uid())
  ) THEN
    RAISE EXCEPTION 'Cannot reply to a message outside this conversation.';
  END IF;
  RETURN QUERY
  INSERT INTO public.messages (sender_id, recipient_id, body, sent_as, parent_id)
  VALUES (auth.uid(), p_recipient_id, p_body, p_sent_as, p_parent_id)
  RETURNING *;
END;
$$;
GRANT EXECUTE ON FUNCTION public.send_message(uuid, text, text, uuid) TO authenticated;

-- 3. Edit — sender-only, any time. Enforced in the function body (same
-- SECURITY DEFINER pattern as send_message) rather than a new RLS
-- policy, so it doesn't interact with the existing recipient-only
-- "mark read" UPDATE policy on this table.
CREATE OR REPLACE FUNCTION public.edit_message(p_id uuid, p_body text)
RETURNS SETOF public.messages
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
  IF NOT EXISTS (SELECT 1 FROM public.messages WHERE id = p_id AND sender_id = auth.uid()) THEN
    RAISE EXCEPTION 'You can only edit your own messages.';
  END IF;
  RETURN QUERY
  UPDATE public.messages SET body = p_body, edited_at = now()
  WHERE id = p_id
  RETURNING *;
END;
$$;
GRANT EXECUTE ON FUNCTION public.edit_message(uuid, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
