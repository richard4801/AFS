-- ============================================================
-- Phase 3: Schedule tracking helpers
-- Run in Supabase Dashboard → SQL Editor
-- ============================================================

-- Ensure chapters.created_at exists (should already be present by default)
ALTER TABLE public.chapters
  ADD COLUMN IF NOT EXISTS created_at timestamptz DEFAULT now();

-- View: daily chapter counts per writer (used by calendar)
CREATE OR REPLACE VIEW public.daily_chapter_counts AS
SELECT
  author_id,
  (created_at AT TIME ZONE 'UTC')::date        AS update_date,
  COUNT(*)                                      AS chapter_count
FROM public.chapters
WHERE status IN ('submitted', 'approved')
GROUP BY author_id, (created_at AT TIME ZONE 'UTC')::date;

-- RLS: writers can only see their own counts
ALTER VIEW public.daily_chapter_counts OWNER TO postgres;

-- Ensure earnings inserts can trigger notifications
-- (notifications table already created by existing setup)
