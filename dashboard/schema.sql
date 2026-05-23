-- ============================================================
-- Apex Fiction Studio — Full Multi-User Schema
-- Run in Supabase SQL Editor (Dashboard → SQL Editor → New Query)
--
-- SAFE TO RE-RUN: every object uses CREATE IF NOT EXISTS / OR REPLACE.
-- If you already ran setup.sql, the profiles table exists — the
-- ALTER TABLE at the bottom adds the new columns non-destructively.
-- ============================================================


-- ── 0. TYPES ─────────────────────────────────────────────────
-- Custom enums keep status values validated at the database level.

do $$ begin
  create type public.book_status    as enum ('draft', 'submitted', 'approved');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.chapter_status as enum ('draft', 'submitted', 'approved', 'revision_requested');
exception when duplicate_object then null; end $$;


-- ── 1. PROFILES ───────────────────────────────────────────────
-- One row per auth.users entry. Supabase Auth owns passwords/tokens;
-- this table owns all application-level writer metadata.

create table if not exists public.profiles (
  id         uuid        primary key references auth.users(id) on delete cascade,
  name       text        not null,
  email      text        not null,
  is_admin   boolean     not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Non-destructively add is_admin to an existing profiles table
-- (no-op if the column already exists)
do $$ begin
  alter table public.profiles add column is_admin boolean not null default false;
exception when duplicate_column then null; end $$;


-- ── 2. BOOKS ─────────────────────────────────────────────────

create table if not exists public.books (
  id          uuid              primary key default gen_random_uuid(),
  author_id   uuid              not null references public.profiles(id) on delete cascade,
  title       text              not null,
  description text,
  cover_url   text,
  status      public.book_status not null default 'draft',
  created_at  timestamptz       not null default now(),
  updated_at  timestamptz       not null default now()
);


-- ── 3. CHAPTERS ──────────────────────────────────────────────

create table if not exists public.chapters (
  id             uuid                  primary key default gen_random_uuid(),
  book_id        uuid                  not null references public.books(id)    on delete cascade,
  author_id      uuid                  not null references public.profiles(id) on delete cascade,
  chapter_number integer               not null,
  title          text,
  content        text,
  word_count     integer               not null default 0,
  status         public.chapter_status not null default 'draft',
  created_at     timestamptz           not null default now(),
  updated_at     timestamptz           not null default now(),

  -- A book cannot have two chapters with the same number
  unique (book_id, chapter_number),
  -- author_id must match the book's author (enforced by trigger below)
  constraint chapter_number_positive check (chapter_number > 0)
);


-- ── 4. COMMENTS ──────────────────────────────────────────────
-- Stores editorial feedback. paragraph_ref is a 0-based index of
-- the paragraph within the chapter content the comment targets;
-- NULL means a general chapter-level comment.

create table if not exists public.comments (
  id            uuid        primary key default gen_random_uuid(),
  chapter_id    uuid        not null references public.chapters(id) on delete cascade,
  reviewer_id   uuid        not null references public.profiles(id) on delete cascade,
  paragraph_ref integer,
  body          text        not null,
  resolved      boolean     not null default false,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  constraint paragraph_ref_non_negative check (paragraph_ref is null or paragraph_ref >= 0)
);


-- ── 5. EARNINGS ──────────────────────────────────────────────
-- One row per author per day (or per transaction, your choice).
-- Only admin/server-side code should INSERT; writers only SELECT.

create table if not exists public.earnings (
  id            uuid          primary key default gen_random_uuid(),
  author_id     uuid          not null references public.profiles(id) on delete cascade,
  book_id       uuid          references public.books(id) on delete set null,
  date          date          not null default current_date,
  amount_earned numeric(10,2) not null,
  note          text,
  created_at    timestamptz   not null default now(),

  constraint amount_non_negative check (amount_earned >= 0)
);


-- ── 6. INDEXES ───────────────────────────────────────────────
-- Supabase creates indexes on PKs and FKs automatically, but these
-- support the most common dashboard queries.

create index if not exists idx_books_author      on public.books(author_id);
create index if not exists idx_chapters_book     on public.chapters(book_id);
create index if not exists idx_chapters_author   on public.chapters(author_id);
create index if not exists idx_comments_chapter  on public.comments(chapter_id);
create index if not exists idx_earnings_author   on public.earnings(author_id);
create index if not exists idx_earnings_date     on public.earnings(date);


-- ── 7. ADMIN HELPER FUNCTION ─────────────────────────────────
-- A security-definer function that checks the is_admin flag for the
-- current JWT user. Using a function rather than an inline subquery
-- means Postgres can cache the result once per transaction, so the
-- profiles table is only hit once no matter how many RLS policies fire.

create or replace function public.is_admin()
returns boolean
language sql
stable          -- result is constant within a single query
security definer -- runs as the function owner, bypassing RLS on profiles
set search_path = public
as $$
  select coalesce(
    (select is_admin from public.profiles where id = auth.uid()),
    false
  );
$$;


-- ── 8. ROW LEVEL SECURITY ─────────────────────────────────────
-- Pattern:
--   Admin  → full access via is_admin() helper on every table
--   Writer → scoped to rows they own (author_id = auth.uid())

alter table public.profiles enable row level security;
alter table public.books     enable row level security;
alter table public.chapters  enable row level security;
alter table public.comments  enable row level security;
alter table public.earnings  enable row level security;


-- ── profiles ─────────────────────────────────────────────────

drop policy if exists "profiles: admin full access"    on public.profiles;
drop policy if exists "profiles: writer select own"    on public.profiles;
drop policy if exists "profiles: writer update own"    on public.profiles;

create policy "profiles: admin full access"
  on public.profiles for all
  using      (public.is_admin())
  with check (public.is_admin());

-- Writers read their own row (needed to populate the dashboard header)
create policy "profiles: writer select own"
  on public.profiles for select
  using (auth.uid() = id);

-- Writers may update their own display name etc., but NOT is_admin
create policy "profiles: writer update own"
  on public.profiles for update
  using      (auth.uid() = id)
  with check (auth.uid() = id and is_admin = false);


-- ── books ─────────────────────────────────────────────────────

drop policy if exists "books: admin full access"  on public.books;
drop policy if exists "books: writer select own"  on public.books;
drop policy if exists "books: writer insert own"  on public.books;
drop policy if exists "books: writer update own"  on public.books;

create policy "books: admin full access"
  on public.books for all
  using      (public.is_admin())
  with check (public.is_admin());

create policy "books: writer select own"
  on public.books for select
  using (auth.uid() = author_id);

create policy "books: writer insert own"
  on public.books for insert
  with check (auth.uid() = author_id);

-- Writers may only edit books that are still in draft status.
-- Once an admin marks a book 'submitted' or 'approved', the writer
-- can no longer alter it without admin intervention.
create policy "books: writer update draft only"
  on public.books for update
  using      (auth.uid() = author_id and status = 'draft')
  with check (auth.uid() = author_id);


-- ── chapters ─────────────────────────────────────────────────

drop policy if exists "chapters: admin full access"      on public.chapters;
drop policy if exists "chapters: writer select own"      on public.chapters;
drop policy if exists "chapters: writer insert own"      on public.chapters;
drop policy if exists "chapters: writer update draft"    on public.chapters;

create policy "chapters: admin full access"
  on public.chapters for all
  using      (public.is_admin())
  with check (public.is_admin());

create policy "chapters: writer select own"
  on public.chapters for select
  using (auth.uid() = author_id);

create policy "chapters: writer insert own"
  on public.chapters for insert
  with check (auth.uid() = author_id);

-- Writers can edit their own chapters only while in draft or
-- revision_requested state (i.e. not after admin approval).
create policy "chapters: writer update own"
  on public.chapters for update
  using (
    auth.uid() = author_id
    and status in ('draft', 'revision_requested')
  )
  with check (auth.uid() = author_id);


-- ── comments ─────────────────────────────────────────────────
-- Admins write feedback; writers read feedback on their own chapters.

drop policy if exists "comments: admin full access"       on public.comments;
drop policy if exists "comments: writer select on own"    on public.comments;

create policy "comments: admin full access"
  on public.comments for all
  using      (public.is_admin())
  with check (public.is_admin());

-- Writers can see all comments left on chapters they authored
create policy "comments: writer select on own chapters"
  on public.comments for select
  using (
    exists (
      select 1 from public.chapters c
      where c.id = chapter_id
        and c.author_id = auth.uid()
    )
  );


-- ── earnings ─────────────────────────────────────────────────
-- Admins insert; writers only read their own rows.

drop policy if exists "earnings: admin full access"  on public.earnings;
drop policy if exists "earnings: writer select own"  on public.earnings;

create policy "earnings: admin full access"
  on public.earnings for all
  using      (public.is_admin())
  with check (public.is_admin());

create policy "earnings: writer select own"
  on public.earnings for select
  using (auth.uid() = author_id);


-- ── 9. AUTO-PROVISION PROFILE ON SIGNUP ──────────────────────
-- Creates a profiles row automatically whenever a new auth.users row
-- is inserted. is_admin defaults to false for all self-signups.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, name, email, is_admin)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'name', split_part(new.email, '@', 1)),
    new.email,
    false  -- never grant admin via self-signup
  )
  on conflict (id) do nothing;  -- idempotent: safe to re-run
  return new;
end;
$$;

-- Drop and recreate so this file is idempotent
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();


-- ── 10. GRANT YOUR ACCOUNT ADMIN ACCESS ──────────────────────
-- After running this file, promote yourself to admin by running:
--
--   update public.profiles
--   set is_admin = true
--   where email = 'YOUR_EMAIL_HERE';
--
-- Do this once from the Supabase SQL Editor (which runs as the
-- service role and bypasses RLS). Never expose this update to
-- the client — is_admin can only be set server-side.


-- ── 11. SEED DATA (optional — for local testing) ─────────────
-- Uncomment after creating a test writer account and pasting their UUID.
--
-- do $$
-- declare
--   w uuid := 'WRITER-UUID-HERE';
--   b uuid;
-- begin
--
--   insert into public.books (author_id, title, status)
--   values (w, 'The Alpha''s Forbidden Mate', 'draft')
--   returning id into b;
--
--   insert into public.chapters (book_id, author_id, chapter_number, title, word_count, status)
--   values
--     (b, w, 1, 'The Encounter',   3200, 'approved'),
--     (b, w, 2, 'The Recognition', 2900, 'submitted'),
--     (b, w, 3, 'The Claim',       3100, 'draft');
--
--   insert into public.earnings (author_id, book_id, date, amount_earned)
--   select w, b, current_date - s, round((random() * 30 + 2)::numeric, 2)
--   from generate_series(0, 29) s;
--
-- end $$;
