-- ============================================================
-- Lets admin close the public application form (landing page shows
-- "not currently receiving applications" instead) and collects an
-- email waitlist to notify automatically when it reopens.
-- ============================================================

-- ── Site-wide settings (single row) ─────────────────────────────────
CREATE TABLE IF NOT EXISTS public.site_settings (
  id                 int PRIMARY KEY DEFAULT 1,
  applications_open  boolean NOT NULL DEFAULT true,
  CONSTRAINT site_settings_single_row CHECK (id = 1)
);
INSERT INTO public.site_settings (id, applications_open)
VALUES (1, true)
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.site_settings ENABLE ROW LEVEL SECURITY;

-- The landing page reads this before the visitor is ever signed in.
DROP POLICY IF EXISTS "public_read_site_settings" ON public.site_settings;
CREATE POLICY "public_read_site_settings" ON public.site_settings
  FOR SELECT USING (true);

-- No direct UPDATE policy -- the toggle goes through the narrow RPC
-- below, same reasoning as sign_contract()/submit_kyc() elsewhere in
-- this schema.

CREATE OR REPLACE FUNCTION public.admin_set_applications_open(p_open boolean)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true) THEN
    RAISE EXCEPTION 'Forbidden';
  END IF;
  UPDATE public.site_settings SET applications_open = p_open WHERE id = 1;
  RETURN p_open;
END;
$$;
GRANT EXECUTE ON FUNCTION public.admin_set_applications_open(boolean) TO authenticated;

-- ── Waitlist: "notify me when applications reopen" ──────────────────
CREATE TABLE IF NOT EXISTS public.application_waitlist (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  email       text        NOT NULL UNIQUE,
  created_at  timestamptz NOT NULL DEFAULT now(),
  notified_at timestamptz
);

ALTER TABLE public.application_waitlist ENABLE ROW LEVEL SECURITY;

-- Anyone (unauthenticated visitor) can join the waitlist, same as
-- applying itself.
DROP POLICY IF EXISTS "public_insert_waitlist" ON public.application_waitlist;
CREATE POLICY "public_insert_waitlist" ON public.application_waitlist
  FOR INSERT WITH CHECK (true);

-- Only admins can read the list (it's a list of real email addresses).
DROP POLICY IF EXISTS "admin_read_waitlist" ON public.application_waitlist;
CREATE POLICY "admin_read_waitlist" ON public.application_waitlist
  FOR SELECT USING (
    (SELECT is_admin FROM public.profiles WHERE id = auth.uid()) = true
  );

-- Marking a batch as notified goes through a narrow RPC (no direct
-- UPDATE grant) so a client can only ever set notified_at = now(),
-- never forge an arbitrary timestamp or touch someone else's email.
CREATE OR REPLACE FUNCTION public.admin_mark_waitlist_notified(p_ids uuid[])
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true) THEN
    RAISE EXCEPTION 'Forbidden';
  END IF;
  UPDATE public.application_waitlist SET notified_at = now() WHERE id = ANY(p_ids);
END;
$$;
GRANT EXECUTE ON FUNCTION public.admin_mark_waitlist_notified(uuid[]) TO authenticated;

NOTIFY pgrst, 'reload schema';
