-- ============================================================
-- Bug Fixes: messages RLS clean-reset + notifications DELETE
-- Run in Supabase Dashboard → SQL Editor
-- ============================================================

-- 1. Drop ALL existing policies on messages (avoids conflicts from
--    multiple SQL runs) then recreate the correct three policies.
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT policyname
    FROM pg_policies
    WHERE tablename = 'messages' AND schemaname = 'public'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON messages', r.policyname);
  END LOOP;
END;
$$;

ALTER TABLE messages ENABLE ROW LEVEL SECURITY;

CREATE POLICY "msg_read" ON messages
  FOR SELECT USING (auth.uid() = sender_id OR auth.uid() = recipient_id);

CREATE POLICY "msg_insert" ON messages
  FOR INSERT WITH CHECK (auth.uid() = sender_id);

CREATE POLICY "msg_update" ON messages
  FOR UPDATE USING  (auth.uid() = recipient_id)
  WITH CHECK (auth.uid() = recipient_id);

-- 2. Notifications: add DELETE policy so client-side dismiss/clear
--    actually removes rows instead of silently returning 0 rows.
DROP POLICY IF EXISTS "notif_delete" ON notifications;
CREATE POLICY "notif_delete" ON notifications
  FOR DELETE USING (auth.uid() = user_id);

-- Reload PostgREST schema cache
NOTIFY pgrst, 'reload schema';
