-- ============================================================
-- Lets admin set/update the WhatsApp group invite link from the
-- dashboard, instead of it being a hardcoded constant in
-- dashboard/admin.html that needs a code change (and a redeploy) to
-- update. Reuses the single-row site_settings table added in
-- sql/applications_toggle_and_waitlist.sql.
-- ============================================================

ALTER TABLE public.site_settings ADD COLUMN IF NOT EXISTS whatsapp_group_link text;

-- No direct UPDATE policy -- same narrow-RPC pattern as
-- admin_set_applications_open(); public_read_site_settings (already in
-- place) covers reading the current link.
CREATE OR REPLACE FUNCTION public.admin_set_whatsapp_link(p_link text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_link text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true) THEN
    RAISE EXCEPTION 'Forbidden';
  END IF;
  v_link := NULLIF(trim(p_link), '');
  IF v_link IS NOT NULL AND v_link !~* '^https?://' THEN
    RAISE EXCEPTION 'Link must start with http:// or https://';
  END IF;
  UPDATE public.site_settings SET whatsapp_group_link = v_link WHERE id = 1;
  RETURN v_link;
END;
$$;
GRANT EXECUTE ON FUNCTION public.admin_set_whatsapp_link(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
