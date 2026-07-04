-- Fixes "function gen_random_bytes(integer) does not exist" from clicking
-- "Reset SE PIN". Supabase installs pgcrypto into the `extensions` schema,
-- not `public`, and admin_reset_se_pin() pins search_path to `public` —
-- so its calls to gen_random_bytes()/digest() need to be schema-qualified.
-- Safe to run any number of times (CREATE OR REPLACE, same signature).

CREATE OR REPLACE FUNCTION public.admin_reset_se_pin()
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
  v_token := encode(extensions.gen_random_bytes(16), 'hex');
  INSERT INTO public.se_setup_token (id, token_hash, expires_at, updated_at)
  VALUES (true, encode(extensions.digest(v_token, 'sha256'), 'hex'), now() + interval '1 hour', now())
  ON CONFLICT (id) DO UPDATE
    SET token_hash = EXCLUDED.token_hash, expires_at = EXCLUDED.expires_at, updated_at = now();
  RETURN v_token;
END;
$$;
