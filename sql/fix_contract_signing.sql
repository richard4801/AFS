-- Fixes contract-signing column forgery. The old "writer_sign_own_contract"
-- UPDATE policy (WITH CHECK (auth.uid() = writer_id) alone) let a writer's
-- "sign" UPDATE rewrite any column on their own contract row in the same
-- statement — not just flip status to signed, but also e.g. backdate
-- signed_at, or sign against a different doc_version than what was
-- actually sent.
--
-- Replaced with a narrow SECURITY DEFINER sign_contract() RPC that only
-- ever sets status/signed_at/name_signed/user_agent (signed_at derived
-- from now(), never client-supplied), and the broad UPDATE policy is
-- dropped so raw column writes are no longer possible at all. Run once in
-- Supabase SQL Editor — safe to re-run.

CREATE OR REPLACE FUNCTION public.sign_contract(
  p_contract_id uuid,
  p_name_signed text,
  p_user_agent  text DEFAULT NULL
)
RETURNS SETOF public.contracts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rows int;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;
  IF length(trim(p_name_signed)) = 0 THEN
    RAISE EXCEPTION 'Please enter your full legal name.';
  END IF;
  RETURN QUERY
  UPDATE public.contracts
     SET status      = 'signed',
         signed_at   = now(),
         name_signed = p_name_signed,
         user_agent  = p_user_agent
   WHERE id = p_contract_id
     AND writer_id = auth.uid()
     AND status = 'pending'
  RETURNING *;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN
    RAISE EXCEPTION 'Contract record not found, already signed, or not yours.';
  END IF;
END;
$$;
GRANT EXECUTE ON FUNCTION public.sign_contract(uuid, text, text) TO authenticated;

-- Writers no longer get any raw UPDATE access — signing goes through the
-- RPC above exclusively. (SELECT-own and admin policies are untouched.)
DROP POLICY IF EXISTS "writer_sign_own_contract" ON public.contracts;

NOTIFY pgrst, 'reload schema';
