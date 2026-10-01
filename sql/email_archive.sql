-- ============================================================
-- A single running archive of every email address ever entered
-- anywhere on the site -- writer applications (including prompt-link
-- leads, which already land in `applications` tagged by source),
-- the "notify me when applications reopen" waitlist, and every real
-- account (profiles, created on signup/invite). Populated entirely by
-- triggers on each source table, so it keeps growing automatically as
-- new rows land there -- no application code has to remember to write
-- to it, and a future capture point just needs its own trigger added.
--
-- (prompt_leads, an earlier standalone table for prompt-share leads,
-- was already dropped in favor of routing those into `applications`
-- itself -- see sql/applications_from_prompt_link.sql -- so it isn't
-- one of the three source tables here.)
-- ============================================================

CREATE TABLE IF NOT EXISTS public.email_archive (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  email       text        NOT NULL,
  name        text,
  source      text        NOT NULL CHECK (source IN ('application', 'waitlist', 'profile')),
  source_id   uuid        NOT NULL,
  captured_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source, source_id)
);

CREATE INDEX IF NOT EXISTS email_archive_email_idx ON public.email_archive (lower(email));
CREATE INDEX IF NOT EXISTS email_archive_captured_idx ON public.email_archive (captured_at DESC);

ALTER TABLE public.email_archive ENABLE ROW LEVEL SECURITY;

-- Admin-only read. No INSERT/UPDATE/DELETE policy at all for any
-- role -- every row is written by the SECURITY DEFINER trigger
-- function below, which bypasses RLS; there is no client-side write
-- path into this table whatsoever.
DROP POLICY IF EXISTS "admin_read_email_archive" ON public.email_archive;
CREATE POLICY "admin_read_email_archive" ON public.email_archive
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true)
  );

-- One shared trigger function for all three source tables -- the
-- source tag comes from the trigger's own argument (TG_ARGV[0]), and
-- to_jsonb(NEW)->>'name' reads a "name" column if the firing table
-- has one (applications, profiles) and is a harmless NULL if it
-- doesn't (application_waitlist, email-only). ON CONFLICT makes both
-- the trigger and the one-time backfill below safe to run more than
-- once.
CREATE OR REPLACE FUNCTION public._archive_email()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.email IS NULL OR length(trim(NEW.email)) = 0 THEN
    RETURN NEW;
  END IF;
  INSERT INTO public.email_archive (email, name, source, source_id)
  VALUES (lower(trim(NEW.email)), to_jsonb(NEW)->>'name', TG_ARGV[0], NEW.id)
  ON CONFLICT (source, source_id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS archive_email_on_application ON public.applications;
CREATE TRIGGER archive_email_on_application
  AFTER INSERT ON public.applications
  FOR EACH ROW EXECUTE FUNCTION public._archive_email('application');

DROP TRIGGER IF EXISTS archive_email_on_waitlist ON public.application_waitlist;
CREATE TRIGGER archive_email_on_waitlist
  AFTER INSERT ON public.application_waitlist
  FOR EACH ROW EXECUTE FUNCTION public._archive_email('waitlist');

DROP TRIGGER IF EXISTS archive_email_on_profile ON public.profiles;
CREATE TRIGGER archive_email_on_profile
  AFTER INSERT ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public._archive_email('profile');

-- One-time backfill of every email already sitting in each source
-- table before this migration ran -- "every email", not just ones
-- captured from here on. Safe to re-run: ON CONFLICT no-ops rows
-- already archived.
INSERT INTO public.email_archive (email, name, source, source_id, captured_at)
SELECT lower(trim(email)), name, 'application', id, created_at
FROM public.applications
WHERE email IS NOT NULL AND length(trim(email)) > 0
ON CONFLICT (source, source_id) DO NOTHING;

INSERT INTO public.email_archive (email, name, source, source_id, captured_at)
SELECT lower(trim(email)), NULL, 'waitlist', id, created_at
FROM public.application_waitlist
WHERE email IS NOT NULL AND length(trim(email)) > 0
ON CONFLICT (source, source_id) DO NOTHING;

-- If profiles has no created_at column (its original schema predates
-- this repo's tracked migrations, so it isn't visible here to check),
-- replace `created_at` below with `now()` and re-run just this
-- statement.
INSERT INTO public.email_archive (email, name, source, source_id, captured_at)
SELECT lower(trim(email)), name, 'profile', id, created_at
FROM public.profiles
WHERE email IS NOT NULL AND length(trim(email)) > 0
ON CONFLICT (source, source_id) DO NOTHING;

NOTIFY pgrst, 'reload schema';
