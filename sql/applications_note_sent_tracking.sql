-- ============================================================
-- Tracks when admin last sent a note to an applicant, so a still-
-- pending application that's been noted drops out of the active
-- Pending queue -- it's waiting to hear back, not something to keep
-- re-reviewing. It stays fully visible under "All".
--
-- The applications table's existing "admins_update" policy already
-- grants admins broad UPDATE access (unlike contracts/messages, which
-- were hardened behind narrow RPCs) -- this column is set the same
-- way admin.html already sets status/reviewed_at on approve/reject,
-- so no new RPC or policy is needed.
-- ============================================================

ALTER TABLE public.applications ADD COLUMN IF NOT EXISTS last_note_sent_at timestamptz;
