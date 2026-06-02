-- ── AFS Contracts RLS Fix ────────────────────────────────────────────────
-- Run this in Supabase SQL Editor AFTER running contract-schema.sql
-- This creates SECURITY DEFINER functions so the admin can INSERT/SELECT
-- contracts without being blocked by row-level security.

-- ── 1. Admin: send a contract to a writer ──────────────────────────────
CREATE OR REPLACE FUNCTION admin_send_contract(
  p_writer_id  uuid,
  p_doc_version text DEFAULT 'v1'
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Must be authenticated
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  -- Block duplicate pending
  IF EXISTS (
    SELECT 1 FROM contracts
    WHERE writer_id = p_writer_id AND status = 'pending'
  ) THEN
    RAISE EXCEPTION 'Writer already has a pending contract';
  END IF;

  INSERT INTO contracts (writer_id, doc_version, status, sent_at, sent_by)
  VALUES (p_writer_id, p_doc_version, 'pending', now(), auth.uid());

  RETURN json_build_object('success', true);
END;
$$;

GRANT EXECUTE ON FUNCTION admin_send_contract(uuid, text) TO authenticated;


-- ── 2. Admin: fetch all contracts (bypasses RLS) ───────────────────────
CREATE OR REPLACE FUNCTION admin_get_contracts()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  RETURN COALESCE(
    (
      SELECT json_agg(row_to_json(c) ORDER BY c.sent_at DESC)
      FROM contracts c
    ),
    '[]'::json
  );
END;
$$;

GRANT EXECUTE ON FUNCTION admin_get_contracts() TO authenticated;
