-- ============================================================
-- Security Patch: Server-side device trust tokens
-- Run in Supabase Dashboard → SQL Editor
-- ============================================================

-- Server-side device trust tokens
-- Replaces the purely client-side localStorage timestamp check.
-- A cryptographically random token is stored in both the DB and
-- the user's localStorage. Forging the localStorage entry no
-- longer bypasses OTP verification.
CREATE TABLE IF NOT EXISTS public.device_tokens (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  token      text        NOT NULL,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE device_tokens ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "device_tokens_own" ON device_tokens;
CREATE POLICY "device_tokens_own" ON device_tokens
  FOR ALL USING (auth.uid() = user_id);

CREATE INDEX IF NOT EXISTS device_tokens_lookup
  ON device_tokens (user_id, token, expires_at);
