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

-- RLS: writers can only see their own counts.
-- security_invoker makes the view run as the querying user, so their own
-- row-level security on public.chapters applies (a writer sees only their
-- own rows). Without it the view ran with owner rights and, having no
-- author filter of its own, exposed every writer's activity to everyone.
-- (Requires Postgres 15+, which Supabase is on.)
ALTER VIEW public.daily_chapter_counts SET (security_invoker = true);

-- Ensure earnings inserts can trigger notifications
-- (notifications table already created by existing setup)
