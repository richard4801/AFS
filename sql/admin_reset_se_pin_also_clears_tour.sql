-- Updates admin_reset_se_pin() so resetting Christine's PIN also clears
-- her onboarding flag, causing the first-run spotlight tour to
-- automatically replay the next time she logs in with a new PIN.
-- Safe to run any number of times (CREATE OR REPLACE, same signature).

CREATE OR REPLACE FUNCTION public.admin_reset_se_pin()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true) THEN
    RAISE EXCEPTION 'Admins only.';
  END IF;
  DELETE FROM public.se_pins
   WHERE user_id IN (SELECT id FROM public.profiles WHERE is_senior_editor = true);
  UPDATE public.profiles
     SET onboarded = false
   WHERE is_senior_editor = true;
END;
$$;
