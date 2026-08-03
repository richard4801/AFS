-- ============================================================
-- Dual compensation model (Flat Rate vs. Shared Revenue) — schema
-- + backend logic only. This is step 1 of an incremental rollout;
-- admin UI, writer dashboard UI, and public/legal copy are separate
-- follow-up steps once this is verified.
-- Run in Supabase → SQL Editor.
--
-- Scope decisions, and why:
--
-- * "cumulative_word_count" is tracked per WRITER (via their signed
--   contract), not per-book. contracts.writer_id is the only link
--   this schema has — there's no contracts.book_id, and one writer
--   only ever has one active (status='signed') contract at a time.
--   If you actually want the 30k threshold scoped to a single book/
--   project rather than the writer's total output, that needs a
--   bigger structural change (contracts would need a book_id) —
--   flag it and we'll do that as its own step instead.
--
-- * transition_expires_at reuses the existing contracts.signed_at
--   column as its basis (signed_at + 30 days) rather than adding a
--   redundant "contract_signed_at" — signed_at already IS that
--   timestamp, set server-side in sign_contract() below.
--
-- * Expiry (both the 30-day window and the 30k-word threshold) is
--   enforced the same way prompt_claims' 72h expiry already is in
--   this codebase (see writing_prompts.sql): a SECURITY DEFINER
--   sweep function, called lazily at the top of every RPC that reads
--   or writes contract state, PLUS an optional pg_cron schedule for
--   near-real-time correctness. Neither is required for correctness
--   on its own — the lazy sweep alone is always eventually correct.
-- ============================================================

-- ── 1. New columns on contracts ──────────────────────────────────
ALTER TABLE public.contracts
  ADD COLUMN IF NOT EXISTS compensation_model    text        NOT NULL DEFAULT 'FLAT_RATE',
  ADD COLUMN IF NOT EXISTS transition_expires_at timestamptz,
  ADD COLUMN IF NOT EXISTS cumulative_word_count int         NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS sign_in_bonus_amount  numeric(12,2),
  ADD COLUMN IF NOT EXISTS sign_in_bonus_status   text;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'contracts_compensation_model_check') THEN
    ALTER TABLE public.contracts
      ADD CONSTRAINT contracts_compensation_model_check
      CHECK (compensation_model IN ('FLAT_RATE', 'SHARED_REVENUE'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'contracts_sign_in_bonus_status_check') THEN
    ALTER TABLE public.contracts
      ADD CONSTRAINT contracts_sign_in_bonus_status_check
      CHECK (sign_in_bonus_status IS NULL OR sign_in_bonus_status IN ('ACTIVE', 'CLAIMED', 'EXPIRED', 'FORFEITED_WORD_LIMIT'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'contracts_cumulative_word_count_check') THEN
    ALTER TABLE public.contracts
      ADD CONSTRAINT contracts_cumulative_word_count_check
      CHECK (cumulative_word_count >= 0);
  END IF;
END $$;

-- ── 2. Lazy + cron expiry sweep ──────────────────────────────────
-- Flips an ACTIVE flat-rate sign-in bonus to FORFEITED_WORD_LIMIT
-- (writer crossed 30,000 cumulative words) or EXPIRED (30-day window
-- lapsed) — word-count forfeiture takes precedence when both are
-- true in the same pass, since it's the more informative status.
-- Once flipped, sign_in_bonus_status is never touched again by this
-- function (only an admin action, not implemented here, could
-- change it further) — this is a one-way lock, matching the
-- "permanently nullified" / "permanent lock-in" business rule.
CREATE OR REPLACE FUNCTION public.sweep_contract_compensation_locks()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  n integer;
BEGIN
  UPDATE public.contracts
     SET sign_in_bonus_status = CASE
           WHEN cumulative_word_count >= 30000 THEN 'FORFEITED_WORD_LIMIT'
           ELSE 'EXPIRED'
         END
   WHERE status = 'signed'
     AND compensation_model = 'FLAT_RATE'
     AND sign_in_bonus_status = 'ACTIVE'
     AND (
       cumulative_word_count >= 30000
       OR (transition_expires_at IS NOT NULL AND now() >= transition_expires_at)
     );
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$$;

-- ── 3. sign_contract(): start the 30-day window + bonus at signing ──
-- Same narrow, SECURITY DEFINER shape as before (fix_contract_signing.sql)
-- — still only ever sets status/signed_at/name_signed/user_agent plus
-- the two new fields below; signature is unchanged so no client update
-- is required for this to take effect.
CREATE OR REPLACE FUNCTION public.sign_contract(
  p_contract_id uuid,
  p_name_signed text,
  p_user_agent  text DEFAULT NULL
)
RETURNS SETOF public.contracts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rows int;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;
  IF length(trim(p_name_signed)) = 0 THEN
    RAISE EXCEPTION 'Please enter your full legal name.';
  END IF;
  RETURN QUERY
  UPDATE public.contracts
     SET status               = 'signed',
         signed_at            = now(),
         name_signed          = p_name_signed,
         user_agent           = p_user_agent,
         transition_expires_at = now() + interval '30 days',
         sign_in_bonus_status  = CASE WHEN sign_in_bonus_amount IS NOT NULL THEN 'ACTIVE' ELSE sign_in_bonus_status END
   WHERE id = p_contract_id
     AND writer_id = auth.uid()
     AND status = 'pending'
  RETURNING *;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN
    RAISE EXCEPTION 'Contract record not found, already signed, or not yours.';
  END IF;
END;
$$;
GRANT EXECUTE ON FUNCTION public.sign_contract(uuid, text, text) TO authenticated;

-- ── 4. admin_send_contract(): let admin set the initial model + bonus ──
-- New params are optional/trailing with defaults matching prior
-- behavior (FLAT_RATE, no bonus), so the existing 2-argument call
-- from admin.html keeps working unchanged until that UI is updated.
-- CREATE OR REPLACE alone would NOT replace the old 2-arg function in
-- place here — Postgres only replaces when parameter TYPES match
-- exactly, so adding trailing params would leave both the old 2-arg
-- and new 4-arg versions defined as separate overloads, which risks
-- PostgREST "could not choose the best candidate function" errors on
-- RPC calls. Drop the old signature explicitly first so there's only
-- ever one admin_send_contract.
DROP FUNCTION IF EXISTS public.admin_send_contract(uuid, text);

CREATE OR REPLACE FUNCTION public.admin_send_contract(
  p_writer_id             uuid,
  p_doc_version           text DEFAULT 'v1',
  p_compensation_model    text DEFAULT 'FLAT_RATE',
  p_sign_in_bonus_amount  numeric DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true) THEN
    RAISE EXCEPTION 'Admins only.';
  END IF;

  IF p_compensation_model NOT IN ('FLAT_RATE', 'SHARED_REVENUE') THEN
    RAISE EXCEPTION 'Invalid compensation model.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM contracts
    WHERE writer_id = p_writer_id AND status = 'pending'
  ) THEN
    RAISE EXCEPTION 'Writer already has a pending contract';
  END IF;

  INSERT INTO contracts (writer_id, doc_version, status, sent_at, sent_by, compensation_model, sign_in_bonus_amount)
  VALUES (p_writer_id, p_doc_version, 'pending', now(), auth.uid(), p_compensation_model, p_sign_in_bonus_amount);

  RETURN json_build_object('success', true);
END;
$$;
GRANT EXECUTE ON FUNCTION public.admin_send_contract(uuid, text, text, numeric) TO authenticated;

-- ── 5. Writer-initiated model switch, gated by window + word threshold ──
CREATE OR REPLACE FUNCTION public.request_model_switch(p_contract_id uuid)
RETURNS SETOF public.contracts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid  uuid := auth.uid();
  v_row  public.contracts;
  v_rows int;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  PERFORM public.sweep_contract_compensation_locks();

  SELECT * INTO v_row FROM public.contracts WHERE id = p_contract_id AND writer_id = v_uid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Contract not found or not yours.';
  END IF;
  IF v_row.status <> 'signed' THEN
    RAISE EXCEPTION 'Only a signed contract can switch models.';
  END IF;
  IF v_row.transition_expires_at IS NULL OR now() >= v_row.transition_expires_at THEN
    RAISE EXCEPTION 'Your 30-day window to switch compensation models has closed.';
  END IF;
  IF v_row.compensation_model = 'FLAT_RATE' AND v_row.cumulative_word_count >= 30000 THEN
    RAISE EXCEPTION 'This contract is locked to Flat Rate after 30,000 submitted words.';
  END IF;

  RETURN QUERY
  UPDATE public.contracts
     SET compensation_model = CASE WHEN compensation_model = 'FLAT_RATE' THEN 'SHARED_REVENUE' ELSE 'FLAT_RATE' END
   WHERE id = p_contract_id
  RETURNING *;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN
    RAISE EXCEPTION 'Switch failed.';
  END IF;
END;
$$;
GRANT EXECUTE ON FUNCTION public.request_model_switch(uuid) TO authenticated;

-- ── 6. Keep cumulative_word_count in sync with actual chapter output ──
-- Recomputes (doesn't delta-track, to avoid drift — same philosophy
-- as fix_word_count_source_of_truth.sql) the SUM of word_count across
-- every chapter the writer has authored, on any chapters insert/update,
-- and immediately re-sweeps so a bonus forfeits the moment 30,000 is
-- crossed rather than waiting for the next unrelated read.
CREATE OR REPLACE FUNCTION public.trg_sync_contract_word_count()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_author_id uuid;
  v_total     int;
BEGIN
  SELECT author_id INTO v_author_id FROM public.books WHERE id = COALESCE(NEW.book_id, OLD.book_id);
  IF v_author_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE(SUM(c.word_count), 0) INTO v_total
    FROM public.chapters c
    JOIN public.books b ON b.id = c.book_id
   WHERE b.author_id = v_author_id;

  UPDATE public.contracts
     SET cumulative_word_count = v_total
   WHERE writer_id = v_author_id AND status = 'signed';

  PERFORM public.sweep_contract_compensation_locks();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_contract_word_count ON public.chapters;
CREATE TRIGGER trg_sync_contract_word_count
  AFTER INSERT OR UPDATE ON public.chapters
  FOR EACH ROW EXECUTE FUNCTION public.trg_sync_contract_word_count();

-- ── 7. Surface the new fields to admin, and sweep on every admin read ──
CREATE OR REPLACE FUNCTION public.admin_get_contracts()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true) THEN
    RAISE EXCEPTION 'Admins only.';
  END IF;

  PERFORM public.sweep_contract_compensation_locks();

  RETURN COALESCE(
    (
      SELECT json_agg(
        json_build_object(
          'id',                    c.id,
          'writer_id',             c.writer_id,
          'writer_name',           p.name,
          'writer_email',          p.email,
          'doc_version',           c.doc_version,
          'sent_at',               c.sent_at,
          'sent_by',               c.sent_by,
          'signed_at',             c.signed_at,
          'name_signed',           c.name_signed,
          'ip_address',            c.ip_address,
          'user_agent',            c.user_agent,
          'status',                c.status,
          'created_at',            c.created_at,
          'compensation_model',    c.compensation_model,
          'transition_expires_at', c.transition_expires_at,
          'cumulative_word_count', c.cumulative_word_count,
          'sign_in_bonus_amount',  c.sign_in_bonus_amount,
          'sign_in_bonus_status',  c.sign_in_bonus_status
        ) ORDER BY c.sent_at DESC
      )
      FROM contracts c
      LEFT JOIN profiles p ON p.id = c.writer_id
    ),
    '[]'::json
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.admin_get_contracts() TO authenticated;

-- ── 8. Optional pg_cron sweep every 15 min ───────────────────────
-- Same graceful-degradation pattern as writing_prompts.sql's
-- release-expired-prompts job: if pg_cron isn't enabled on this
-- project, this block no-ops with a NOTICE instead of failing the
-- whole migration. The lazy sweeps above (every sign/admin-read/
-- chapter-save) keep things correct regardless.
DO $$
BEGIN
  EXECUTE 'CREATE EXTENSION IF NOT EXISTS pg_cron';
  PERFORM cron.unschedule('sweep-contract-compensation-locks')
    WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'sweep-contract-compensation-locks');
  PERFORM cron.schedule(
    'sweep-contract-compensation-locks',
    '*/15 * * * *',
    $cron$ SELECT public.sweep_contract_compensation_locks(); $cron$
  );
  RAISE NOTICE 'pg_cron scheduled: sweep-contract-compensation-locks every 15 min.';
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_cron not scheduled (%). Lazy sweeps on sign/admin-read/chapter-save still enforce this correctly.', SQLERRM;
END $$;

-- ── 9. Backfill existing signed contracts ────────────────────────
UPDATE public.contracts
   SET transition_expires_at = signed_at + interval '30 days'
 WHERE status = 'signed' AND signed_at IS NOT NULL AND transition_expires_at IS NULL;

UPDATE public.contracts c
   SET cumulative_word_count = COALESCE((
     SELECT SUM(ch.word_count) FROM public.chapters ch
     JOIN public.books b ON b.id = ch.book_id
     WHERE b.author_id = c.writer_id
   ), 0)
 WHERE c.status = 'signed';

SELECT public.sweep_contract_compensation_locks();

NOTIFY pgrst, 'reload schema';
