-- Drops the comments_se_read RLS policy, which gave the Senior Editor raw
-- SELECT on public.comments — bypassing the identity masking that
-- get_chapter_comments() (the only path any client actually uses to read
-- comments) deliberately implements, masking a writer's real name/identity
-- as generic "Writer" unless the viewer is admin. A direct query on the
-- table exposed the real reviewer_id (and, via a join to profiles, real
-- names) regardless.
--
-- Confirmed no client reads public.comments directly anywhere (writer,
-- admin, and SE dashboards all call the get_chapter_comments RPC, which is
-- itself SECURITY DEFINER and does its own authorization) — this policy
-- had no legitimate use and can be dropped outright. Her insert/update/
-- delete-own policies are untouched. Run once in Supabase SQL Editor.

DROP POLICY IF EXISTS "comments_se_read" ON public.comments;
