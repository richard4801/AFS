-- Locks down the 'applications' storage bucket. Its read policy was
-- "TO public" (anonymous included), so any file in it was downloadable by
-- anyone who had/guessed the path — an unauthenticated PII exposure.
--
-- The current apply form stores a pasted external link (in the test_scene
-- column), not an uploaded file, so nothing in the app reads bucket URLs
-- for applications — this can be tightened with no client change. Kept as
-- defense-in-depth in case the bucket ever holds files. Run once in
-- Supabase SQL Editor.

-- Make the bucket private (no anonymous object access by default).
UPDATE storage.buckets SET public = false WHERE id = 'applications';

-- Replace the public read policy with an admin-only one.
DROP POLICY IF EXISTS "public_read_applications" ON storage.objects;
CREATE POLICY "admin_read_applications" ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'applications'
    AND EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true)
  );

-- Anonymous applicants uploading a file remains allowed (harmless without
-- read access), but scope it to the applications bucket only — unchanged
-- from before, re-asserted here for completeness.
DROP POLICY IF EXISTS "anon_upload_applications" ON storage.objects;
CREATE POLICY "anon_upload_applications" ON storage.objects
  FOR INSERT TO anon
  WITH CHECK (bucket_id = 'applications');
