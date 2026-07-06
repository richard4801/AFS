-- Enforces the writer name-lock server-side. The lock ("a name, once set,
-- can't be changed") was previously enforced only by disabling the input
-- field in the browser (nameInput.disabled) — trivially bypassed via
-- devtools (`document.getElementById('profile-name-input').disabled =
-- false`) since saveProfile() decided whether to include `name` in the
-- update payload by reading that same client-side disabled state, and the
-- raw `profiles` UPDATE itself had no server-side check at all.
--
-- This trigger keeps the old name whenever an update attempts to change an
-- already-set name, unless the caller is an admin (who can still correct a
-- writer's name if genuinely needed). Run once in Supabase SQL Editor.

CREATE OR REPLACE FUNCTION public.enforce_writer_name_lock()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.name IS DISTINCT FROM OLD.name
     AND COALESCE(OLD.name, '') <> ''
     AND NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true)
  THEN
    NEW.name := OLD.name;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_writer_name_lock ON public.profiles;
CREATE TRIGGER trg_enforce_writer_name_lock
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.enforce_writer_name_lock();
