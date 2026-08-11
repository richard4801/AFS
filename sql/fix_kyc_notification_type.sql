-- ============================================================
-- Defensive fix for "writers don't get notified when their KYC is
-- reviewed". The `notifications` table (and its RLS) predate this
-- repo's tracked migrations, so its exact shape isn't visible here --
-- if `type` is constrained to a fixed list (a CHECK constraint or an
-- enum), an INSERT using the new 'kyc_approved'/'kyc_rejected' values
-- fails, and the client-side call swallows that error, so nothing
-- shows up in the UI and nothing looks wrong until you check the
-- actual row. This drops any CHECK constraint on notifications.type --
-- a no-op if none exists, safe to re-run.
-- ============================================================

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT con.conname
    FROM pg_constraint con
    JOIN pg_class rel     ON rel.oid = con.conrelid
    JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
    JOIN pg_attribute att ON att.attrelid = rel.oid AND att.attnum = ANY(con.conkey)
    WHERE nsp.nspname = 'public'
      AND rel.relname = 'notifications'
      AND att.attname = 'type'
      AND con.contype = 'c'
  LOOP
    EXECUTE format('ALTER TABLE public.notifications DROP CONSTRAINT %I', r.conname);
    RAISE NOTICE 'Dropped constraint % on notifications.type', r.conname;
  END LOOP;
END $$;

NOTIFY pgrst, 'reload schema';
