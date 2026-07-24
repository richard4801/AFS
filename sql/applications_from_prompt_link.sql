-- ============================================================
-- Route public prompt-share leads into the regular applications
-- pipeline, tagged with their source.
-- Run in Supabase → SQL Editor.
--
-- The first cut of the "share a prompt outside the platform" feature
-- (sql/prompt_share_leads.sql) wrote submissions to a separate
-- prompt_leads table. Admin wants these to show up as regular writer
-- applications instead -- reviewed and approved/rejected the same way,
-- just tagged so it's clear they came from a prompt's public link and
-- which prompt. This migration supersedes prompt_share_leads.sql:
-- it adds the tagging columns to applications and drops the old table.
-- ============================================================

ALTER TABLE public.applications
  ADD COLUMN IF NOT EXISTS source    text NOT NULL DEFAULT 'direct',
  ADD COLUMN IF NOT EXISTS prompt_id uuid REFERENCES public.writing_prompts(id) ON DELETE SET NULL;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'applications_source_check') THEN
    ALTER TABLE public.applications
      ADD CONSTRAINT applications_source_check CHECK (source IN ('direct', 'prompt_link'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'applications_prompt_link_requires_prompt') THEN
    ALTER TABLE public.applications
      ADD CONSTRAINT applications_prompt_link_requires_prompt
      CHECK ((source = 'prompt_link') = (prompt_id IS NOT NULL));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS applications_prompt_id ON public.applications (prompt_id) WHERE prompt_id IS NOT NULL;

-- Prompt-link submissions only collect name, email, and experience --
-- no logline yet (that's the point: a much lighter ask than the full
-- application). test_scene was already made nullable previously
-- (sql/drop_test_scene_not_null.sql); do the same for logline.
ALTER TABLE public.applications ALTER COLUMN logline DROP NOT NULL;

-- The standalone leads table from the first cut of this feature is no
-- longer used -- everything now flows into applications above.
DROP TABLE IF EXISTS public.prompt_leads;
