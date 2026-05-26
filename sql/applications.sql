-- ============================================================
-- Applications table
-- Run this in Supabase Dashboard → SQL Editor
-- ============================================================

CREATE TABLE IF NOT EXISTS public.applications (
  id           uuid        DEFAULT gen_random_uuid() PRIMARY KEY,
  name         text        NOT NULL,
  email        text        NOT NULL,
  experience   text,
  logline      text        NOT NULL,
  test_scene   text        NOT NULL,
  status       text        NOT NULL DEFAULT 'pending',  -- pending | approved | rejected
  notes        text,
  created_at   timestamptz DEFAULT now(),
  reviewed_at  timestamptz,
  reviewed_by  uuid
);

ALTER TABLE public.applications ENABLE ROW LEVEL SECURITY;

-- Anyone (unauthenticated) can submit an application
CREATE POLICY "public_insert" ON public.applications
  FOR INSERT WITH CHECK (true);

-- Only admins can read applications
CREATE POLICY "admins_read" ON public.applications
  FOR SELECT USING (
    (SELECT is_admin FROM public.profiles WHERE id = auth.uid()) = true
  );

-- Only admins can update application status
CREATE POLICY "admins_update" ON public.applications
  FOR UPDATE USING (
    (SELECT is_admin FROM public.profiles WHERE id = auth.uid()) = true
  );

-- ============================================================
-- Auto-create profile row when a new auth user is invited/created
-- ============================================================

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.profiles (id, name, email, is_admin)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'full_name', split_part(NEW.email, '@', 1)),
    NEW.email,
    false
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();
