-- test_scene was replaced by sample_chapters_url.
-- Drop the NOT NULL constraint so old rows are unaffected and new inserts don't require it.
ALTER TABLE public.applications ALTER COLUMN test_scene DROP NOT NULL;
ALTER TABLE public.applications ALTER COLUMN test_scene SET DEFAULT '';
