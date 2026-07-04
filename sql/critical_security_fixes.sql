-- Run this once in Supabase → SQL Editor to apply three critical fixes from
-- the security audit. Every statement below is idempotent (CREATE OR
-- REPLACE / IF NOT EXISTS / DROP IF EXISTS) — safe to run more than once.
--
-- Fix 1: admin_set_writer_rank had no caller check at all — any writer
--        could grant themselves the top bonus tier.
-- Fix 2: four contract/writer-management functions (admin_send_contract,
--        admin_get_contracts, admin_delete_contract, admin_delete_writer)
--        only checked "is someone logged in," not "is this person an
--        admin" — any writer could delete any other writer's account or
--        dump every writer's PII. These also moved out of dashboard/
--        (a folder your live site serves) into sql/.
-- Fix 3: Christine's PIN "setup" step had no secret gating it — whoever
--        called it first, in the window right after a reset, could claim
--        her account. Resetting her PIN now also issues a one-time setup
--        code you relay to her; she needs it to create her new PIN.
--
-- After running this, also: (a) redeploy the se-access Edge Function with
-- its updated code, and (b) tell Christine she'll need a setup code from
-- you next time she resets her PIN — the "Reset SE PIN" button in the
-- admin dashboard now shows it to you right after you click it.

-- ── Fix 1 ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_bronze_on_contract_sign()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.status = 'signed' AND (OLD.status IS DISTINCT FROM 'signed') THEN
    UPDATE public.profiles
    SET rank = 'bronze'
    WHERE id = NEW.writer_id AND rank = 'unranked';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION admin_set_writer_rank(p_user_id uuid, p_rank text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true) THEN
    RAISE EXCEPTION 'Admins only.';
  END IF;
  IF p_rank NOT IN ('unranked', 'bronze', 'gold', 'platinum') THEN
    RAISE EXCEPTION 'Invalid rank: %', p_rank;
  END IF;
  UPDATE public.profiles SET rank = p_rank WHERE id = p_user_id;
END;
$$;

-- ── Fix 2 ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_send_contract(
  p_writer_id  uuid,
  p_doc_version text DEFAULT 'v1'
)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true) THEN
    RAISE EXCEPTION 'Admins only.';
  END IF;
  IF EXISTS (SELECT 1 FROM contracts WHERE writer_id = p_writer_id AND status = 'pending') THEN
    RAISE EXCEPTION 'Writer already has a pending contract';
  END IF;
  INSERT INTO contracts (writer_id, doc_version, status, sent_at, sent_by)
  VALUES (p_writer_id, p_doc_version, 'pending', now(), auth.uid());
  RETURN json_build_object('success', true);
END;
$$;
GRANT EXECUTE ON FUNCTION admin_send_contract(uuid, text) TO authenticated;

CREATE OR REPLACE FUNCTION admin_get_contracts()
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true) THEN
    RAISE EXCEPTION 'Admins only.';
  END IF;
  RETURN COALESCE(
    (SELECT json_agg(json_build_object(
        'id', c.id, 'writer_id', c.writer_id, 'writer_name', p.name, 'writer_email', p.email,
        'doc_version', c.doc_version, 'sent_at', c.sent_at, 'sent_by', c.sent_by,
        'signed_at', c.signed_at, 'name_signed', c.name_signed, 'ip_address', c.ip_address,
        'user_agent', c.user_agent, 'status', c.status, 'created_at', c.created_at
      ) ORDER BY c.sent_at DESC)
     FROM contracts c LEFT JOIN profiles p ON p.id = c.writer_id),
    '[]'::json
  );
END;
$$;
GRANT EXECUTE ON FUNCTION admin_get_contracts() TO authenticated;

CREATE OR REPLACE FUNCTION admin_delete_contract(p_contract_id uuid)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true) THEN
    RAISE EXCEPTION 'Admins only.';
  END IF;
  DELETE FROM contracts WHERE id = p_contract_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Contract not found'; END IF;
  RETURN json_build_object('success', true);
END;
$$;
GRANT EXECUTE ON FUNCTION admin_delete_contract(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION admin_delete_writer(p_writer_id uuid)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true) THEN
    RAISE EXCEPTION 'Admins only.';
  END IF;
  IF p_writer_id = auth.uid() THEN
    RAISE EXCEPTION 'Cannot delete your own account';
  END IF;
  DELETE FROM auth.users WHERE id = p_writer_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Writer not found'; END IF;
  RETURN json_build_object('success', true);
END;
$$;
GRANT EXECUTE ON FUNCTION admin_delete_writer(uuid) TO authenticated;

-- ── Fix 3 ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.se_setup_token (
  id          boolean      PRIMARY KEY DEFAULT true CHECK (id = true),
  token_hash  text,
  expires_at  timestamptz,
  updated_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.se_setup_token ENABLE ROW LEVEL SECURITY;

DROP FUNCTION IF EXISTS public.admin_reset_se_pin();
CREATE FUNCTION public.admin_reset_se_pin()
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_token text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true) THEN
    RAISE EXCEPTION 'Admins only.';
  END IF;
  DELETE FROM public.se_pins
   WHERE user_id IN (SELECT id FROM public.profiles WHERE is_senior_editor = true);
  UPDATE public.profiles
     SET onboarded = false
   WHERE is_senior_editor = true;
  v_token := encode(gen_random_bytes(16), 'hex');
  INSERT INTO public.se_setup_token (id, token_hash, expires_at, updated_at)
  VALUES (true, encode(digest(v_token, 'sha256'), 'hex'), now() + interval '1 hour', now())
  ON CONFLICT (id) DO UPDATE
    SET token_hash = EXCLUDED.token_hash, expires_at = EXCLUDED.expires_at, updated_at = now();
  RETURN v_token;
END;
$$;
