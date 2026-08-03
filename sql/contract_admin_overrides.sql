-- ============================================================
-- Admin override actions for the dual compensation model
-- (follow-up to sql/dual_compensation_model.sql, needed for the
-- admin UI: Contract Management page). Run in Supabase → SQL Editor.
--
-- Note on "audit logs for bonus forfeiture": this step does NOT add a
-- separate audit-log table. sign_in_bonus_status plus signed_at /
-- transition_expires_at / cumulative_word_count already tell you
-- everything about a contract's CURRENT bonus state, which is what
-- the admin UI surfaces. If you want a full history of every status
-- transition (not just the current state), that's a real but bigger
-- addition (a contract_bonus_events table + trigger) -- say so and
-- we'll add it as its own step.
-- ============================================================

-- ── 1. Admin: force-set the compensation model, bypassing the
--       writer's own 30-day/word-count self-service gate ──────────
CREATE OR REPLACE FUNCTION public.admin_set_compensation_model(
  p_contract_id uuid,
  p_model       text
)
RETURNS SETOF public.contracts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rows int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true) THEN
    RAISE EXCEPTION 'Admins only.';
  END IF;
  IF p_model NOT IN ('FLAT_RATE', 'SHARED_REVENUE') THEN
    RAISE EXCEPTION 'Invalid compensation model.';
  END IF;

  RETURN QUERY
  UPDATE public.contracts
     SET compensation_model = p_model
   WHERE id = p_contract_id
  RETURNING *;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN
    RAISE EXCEPTION 'Contract not found.';
  END IF;
END;
$$;
GRANT EXECUTE ON FUNCTION public.admin_set_compensation_model(uuid, text) TO authenticated;

-- ── 2. Admin: reinstate a bonus that expired or was forfeited ──────
-- Manual correction path for a mistaken/disputed auto-forfeiture --
-- the sweep in dual_compensation_model.sql is otherwise a one-way
-- lock with no human override, which is exactly the failure mode
-- this exists to fix.
CREATE OR REPLACE FUNCTION public.admin_reinstate_bonus(p_contract_id uuid)
RETURNS SETOF public.contracts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rows int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true) THEN
    RAISE EXCEPTION 'Admins only.';
  END IF;

  RETURN QUERY
  UPDATE public.contracts
     SET sign_in_bonus_status = 'ACTIVE'
   WHERE id = p_contract_id
     AND sign_in_bonus_amount IS NOT NULL
     AND sign_in_bonus_status IN ('EXPIRED', 'FORFEITED_WORD_LIMIT')
  RETURNING *;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN
    RAISE EXCEPTION 'Contract not found, has no bonus configured, or bonus is not in an expired/forfeited state.';
  END IF;
END;
$$;
GRANT EXECUTE ON FUNCTION public.admin_reinstate_bonus(uuid) TO authenticated;

-- ── 3. Admin: mark an active bonus as paid out ─────────────────────
CREATE OR REPLACE FUNCTION public.admin_mark_bonus_claimed(p_contract_id uuid)
RETURNS SETOF public.contracts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rows int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true) THEN
    RAISE EXCEPTION 'Admins only.';
  END IF;

  RETURN QUERY
  UPDATE public.contracts
     SET sign_in_bonus_status = 'CLAIMED'
   WHERE id = p_contract_id
     AND sign_in_bonus_status = 'ACTIVE'
  RETURNING *;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN
    RAISE EXCEPTION 'Contract not found or bonus is not currently active.';
  END IF;
END;
$$;
GRANT EXECUTE ON FUNCTION public.admin_mark_bonus_claimed(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
