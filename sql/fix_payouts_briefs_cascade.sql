-- payouts.writer_id and briefs.writer_id were ON DELETE CASCADE from
-- auth.users, so deleting a writer's account (now admin-gated, but still a
-- normal admin action) silently destroyed their entire payout history and
-- brief records instead of retaining them for accounting/audit purposes.
-- Switched to ON DELETE SET NULL — the row survives, just no longer
-- "owned" by a live user (existing writer-read RLS naturally stops
-- matching a NULL writer_id, so only admins see the orphaned record
-- afterward, which is the intended outcome). Run once in Supabase SQL
-- Editor — safe to re-run.

ALTER TABLE public.payouts ALTER COLUMN writer_id DROP NOT NULL;
ALTER TABLE public.payouts DROP CONSTRAINT IF EXISTS payouts_writer_id_fkey;
ALTER TABLE public.payouts ADD CONSTRAINT payouts_writer_id_fkey
  FOREIGN KEY (writer_id) REFERENCES auth.users(id) ON DELETE SET NULL;

ALTER TABLE public.briefs ALTER COLUMN writer_id DROP NOT NULL;
ALTER TABLE public.briefs DROP CONSTRAINT IF EXISTS briefs_writer_id_fkey;
ALTER TABLE public.briefs ADD CONSTRAINT briefs_writer_id_fkey
  FOREIGN KEY (writer_id) REFERENCES auth.users(id) ON DELETE SET NULL;
