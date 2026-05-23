-- ============================================================
-- Apex Fiction Studio — Edit Requests Schema
-- Run in Supabase SQL Editor after schema.sql
--
-- Writers use this to request permission to edit a chapter
-- that has already been submitted or approved. Admins review,
-- can reply, and either approve (chapter → draft) or reject.
-- ============================================================


-- ── TABLE ────────────────────────────────────────────────────

create table if not exists public.edit_requests (
  id          uuid        primary key default gen_random_uuid(),
  chapter_id  uuid        not null references public.chapters(id)  on delete cascade,
  author_id   uuid        not null references public.profiles(id)  on delete cascade,
  reason      text        not null,
  status      text        not null default 'pending'
              check (status in ('pending', 'approved', 'rejected')),
  admin_reply text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index if not exists idx_edit_requests_chapter on public.edit_requests(chapter_id);
create index if not exists idx_edit_requests_author  on public.edit_requests(author_id);
create index if not exists idx_edit_requests_status  on public.edit_requests(status);


-- ── ROW LEVEL SECURITY ────────────────────────────────────────

alter table public.edit_requests enable row level security;

-- Admins have full access (review, reply, approve/reject)
create policy "edit_requests: admin full access"
  on public.edit_requests for all
  using      (public.is_admin())
  with check (public.is_admin());

-- Writers can read their own requests (to see status + admin reply)
create policy "edit_requests: writer select own"
  on public.edit_requests for select
  using (auth.uid() = author_id);

-- Writers can only create new requests — no update/delete
create policy "edit_requests: writer insert own"
  on public.edit_requests for insert
  with check (auth.uid() = author_id);


-- ── SUPABASE STORAGE (run separately) ────────────────────────
-- Create a public "covers" bucket for book cover uploads:
--
--   1. Supabase Dashboard → Storage → New Bucket
--   2. Name: covers
--   3. Toggle "Public bucket" ON
--   4. Click Create
--
-- Then add this storage policy (Dashboard → Storage → Policies):
--
--   Bucket: covers
--   Policy name: "covers: authenticated upload"
--   Operation: INSERT
--   Target roles: authenticated
--   Policy definition: (bucket_id = 'covers')
--
-- This lets any authenticated writer upload a cover.
-- Public read is handled automatically by the public bucket flag.
