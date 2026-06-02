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


-- ── 2. Admin: fetch all contracts with writer names (bypasses RLS) ─────
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
      SELECT json_agg(
        json_build_object(
          'id',           c.id,
          'writer_id',    c.writer_id,
          'writer_name',  p.name,
          'writer_email', p.email,
          'doc_version',  c.doc_version,
          'sent_at',      c.sent_at,
          'sent_by',      c.sent_by,
          'signed_at',    c.signed_at,
          'name_signed',  c.name_signed,
          'ip_address',   c.ip_address,
          'user_agent',   c.user_agent,
          'status',       c.status,
          'created_at',   c.created_at
        ) ORDER BY c.sent_at DESC
      )
      FROM contracts c
      LEFT JOIN profiles p ON p.id = c.writer_id
    ),
    '[]'::json
  );
END;
$$;

GRANT EXECUTE ON FUNCTION admin_get_contracts() TO authenticated;
