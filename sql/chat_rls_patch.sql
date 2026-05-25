-- ── AFS Chat RLS Patch ─────────────────────────────────────────────────────
-- Run this in Supabase SQL Editor to fix message sending.

-- 1. Create site_config table so writers can look up the admin ID
--    without needing to read other users' profiles (bypasses profiles RLS)
CREATE TABLE IF NOT EXISTS site_config (
  key   text PRIMARY KEY,
  value text NOT NULL
);
ALTER TABLE site_config ENABLE ROW LEVEL SECURITY;
-- Anyone authenticated can read config (needed by writer to find admin)
DROP POLICY IF EXISTS "site_config_read" ON site_config;
CREATE POLICY "site_config_read" ON site_config
  FOR SELECT USING (auth.role() = 'authenticated');
-- Only admin can write config (optional safety)
DROP POLICY IF EXISTS "site_config_write" ON site_config;
CREATE POLICY "site_config_write" ON site_config
  FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND is_admin = true)
  );

-- 2. Insert (or update) the admin ID into site_config
INSERT INTO site_config (key, value)
VALUES ('admin_id', 'c53092a9-a993-481a-becf-f8a5d600ceec')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;

-- 3. Drop and recreate messages RLS policies cleanly
DROP POLICY IF EXISTS "messages_read"      ON messages;
DROP POLICY IF EXISTS "messages_insert"    ON messages;
DROP POLICY IF EXISTS "messages_mark_read" ON messages;

ALTER TABLE messages ENABLE ROW LEVEL SECURITY;

CREATE POLICY "messages_read" ON messages
  FOR SELECT USING (auth.uid() = sender_id OR auth.uid() = recipient_id);

CREATE POLICY "messages_insert" ON messages
  FOR INSERT WITH CHECK (auth.uid() = sender_id);

CREATE POLICY "messages_mark_read" ON messages
  FOR UPDATE USING  (auth.uid() = recipient_id)
  WITH CHECK (auth.uid() = recipient_id);
