-- Replace test_scene with a file URL for 3-chapter writing samples
ALTER TABLE public.applications
  ADD COLUMN IF NOT EXISTS sample_chapters_url text;

-- Storage bucket policies (run after creating the 'applications' bucket in Storage dashboard)
-- INSERT INTO storage.buckets (id, name, public) VALUES ('applications', 'applications', true)
-- ON CONFLICT (id) DO NOTHING;

-- Private bucket — objects are not anonymously readable. (See
-- sql/fix_applications_bucket_private.sql, which also flips any existing
-- public bucket to private; a public read policy here would expose every
-- applicant's file to anyone with the path.)
INSERT INTO storage.buckets (id, name, public)
VALUES ('applications', 'applications', false)
ON CONFLICT (id) DO NOTHING;

-- Allow anonymous uploads (public applicants are not signed in)
DROP POLICY IF EXISTS "anon_upload_applications" ON storage.objects;
CREATE POLICY "anon_upload_applications" ON storage.objects
  FOR INSERT TO anon
  WITH CHECK (bucket_id = 'applications');

-- Reads are admin-only (never public).
DROP POLICY IF EXISTS "public_read_applications" ON storage.objects;
DROP POLICY IF EXISTS "admin_read_applications" ON storage.objects;
CREATE POLICY "admin_read_applications" ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'applications'
    AND EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true)
  );
