-- Fixes chat identity spoofing: send_message() trusted a client-supplied
-- p_sent_as value ('writer'/'admin'/'senior_editor'), so any authenticated
-- user could pass p_sent_as:'admin' and have their message render in
-- Christine's chat as if genuinely sent by the real admin. Run this once
-- in Supabase SQL Editor — safe to run any number of times, no client
-- code changes needed (the parameter stays in the signature, just no
-- longer trusted).

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
DECLARE
  v_sent_as text;
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

  SELECT CASE
           WHEN is_admin THEN 'admin'
           WHEN is_senior_editor THEN 'senior_editor'
           ELSE 'writer'
         END
    INTO v_sent_as
    FROM public.profiles
   WHERE id = auth.uid();

  RETURN QUERY
  INSERT INTO public.messages (sender_id, recipient_id, body, sent_as, parent_id)
  VALUES (auth.uid(), p_recipient_id, p_body, v_sent_as, p_parent_id)
  RETURNING *;
END;
$$;
GRANT EXECUTE ON FUNCTION public.send_message(uuid, text, text, uuid) TO authenticated;
