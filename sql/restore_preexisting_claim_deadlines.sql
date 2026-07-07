-- ============================================================
-- Restores a real, ticking deadline for every claim that was already
-- active before the delayed-countdown feature shipped -- the
-- retroactive reset in sql/prompt_claim_delayed_countdown.sql wiped
-- expires_at to NULL indiscriminately, which was correct for a
-- genuinely brand-new, not-yet-opened assignment but wrong for
-- someone like Hamzat, who'd already been actively writing against
-- his real 72-hour deadline for a while.
--
-- Deliberately does NOT try to reconstruct the exact original
-- deadline from claimed_at (claimed_at + 72h) -- for anyone who'd
-- already been at it for a while, that calculation could easily land
-- in the past, which would make this "restore" migration instantly
-- EXPIRE their claim the moment it runs. That's the opposite of what
-- was asked for. Every currently-null active claim gets a full fresh
-- 72 hours starting now instead -- always safe, never risks cutting
-- anyone off, and undoes the "frozen at Not started" state the same
-- way the admin "Start Clock" button (sql/admin_start_prompt_claim.sql)
-- already does for one claim at a time -- this just does it for all
-- of them at once, in one pass.
--
-- Does NOT touch the delayed-start behavior itself. Any prompt
-- claimed or assigned AFTER this migration runs still correctly
-- starts as NULL and waits for the writer to actually open it --
-- claim_prompt() and admin_assign_prompt() are unchanged.
-- Run in Supabase → SQL Editor.
-- ============================================================

UPDATE public.prompt_claims
   SET expires_at = now() + interval '72 hours'
 WHERE status = 'active' AND expires_at IS NULL;
