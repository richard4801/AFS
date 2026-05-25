-- ── AFS Chat System Setup ──────────────────────────────────────────────────
-- Run this in your Supabase SQL editor.
-- After running, mark your admin profile: UPDATE profiles SET is_admin = true WHERE id = '<your-user-id>';

-- 1. Add is_admin flag to profiles
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS is_admin boolean NOT NULL DEFAULT false;

-- 2. Create messages table
CREATE TABLE IF NOT EXISTS messages (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  sender_id    uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  recipient_id uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  body         text        NOT NULL CHECK (char_length(trim(body)) > 0),
  created_at   timestamptz NOT NULL DEFAULT now(),
  read_at      timestamptz
);

-- 3. Indexes for fast conversation fetching
CREATE INDEX IF NOT EXISTS messages_sender_idx    ON messages (sender_id,    created_at DESC);
CREATE INDEX IF NOT EXISTS messages_recipient_idx ON messages (recipient_id, created_at DESC);

-- 4. Row-Level Security
ALTER TABLE messages ENABLE ROW LEVEL SECURITY;

-- Users can read any message they sent or received
CREATE POLICY "messages_read" ON messages
  FOR SELECT USING (auth.uid() = sender_id OR auth.uid() = recipient_id);

-- Users can insert messages only as themselves
CREATE POLICY "messages_insert" ON messages
  FOR INSERT WITH CHECK (auth.uid() = sender_id);

-- Only the recipient can mark a message as read
CREATE POLICY "messages_mark_read" ON messages
  FOR UPDATE USING  (auth.uid() = recipient_id)
  WITH CHECK (auth.uid() = recipient_id);

-- 5. Allow writers to read the is_admin flag on any profile
-- (needed so the writer can look up the admin's user id)
-- If you already have a permissive SELECT policy on profiles, skip this.
-- DROP POLICY IF EXISTS "profiles_read_is_admin" ON profiles;
-- CREATE POLICY "profiles_read_is_admin" ON profiles FOR SELECT USING (true);

-- 6. Enable Supabase Realtime on messages
ALTER PUBLICATION supabase_realtime ADD TABLE messages;
