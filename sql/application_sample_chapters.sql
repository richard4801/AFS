-- Replace test_scene with a file URL for 3-chapter writing samples
ALTER TABLE public.applications
  ADD COLUMN IF NOT EXISTS sample_chapters_url text;

-- Storage bucket policies (run after creating the 'applications' bucket in Storage dashboard)
-- INSERT INTO storage.buckets (id, name, public) VALUES ('applications', 'applications', true)
-- ON CONFLICT (id) DO NOTHING;

INSERT INTO storage.buckets (id, name, public)
VALUES ('applications', 'applications', true)
ON CONFLICT (id) DO NOTHING;

-- Allow anonymous uploads (public applicants are not signed in)
DROP POLICY IF EXISTS "anon_upload_applications" ON storage.objects;
CREATE POLICY "anon_upload_applications" ON storage.objects
  FOR INSERT TO anon
  WITH CHECK (bucket_id = 'applications');

-- Allow public reads so admin can download the files
DROP POLICY IF EXISTS "public_read_applications" ON storage.objects;
CREATE POLICY "public_read_applications" ON storage.objects
  FOR SELECT TO public
  USING (bucket_id = 'applications');
