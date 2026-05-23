-- ============================================================
-- Apex Fiction Studio — Supabase Schema & Security Setup
-- Paste this entire file into the Supabase SQL Editor and run.
-- ============================================================


-- ── 1. PROFILES ──────────────────────────────────────────────
-- Extends auth.users. Supabase Auth owns credentials/passwords;
-- this table holds writer-specific metadata only.
create table public.profiles (
  id         uuid        primary key references auth.users(id) on delete cascade,
  name       text        not null,
  email      text        not null,
  created_at timestamptz not null default now()
);


-- ── 2. PROJECTS ───────────────────────────────────────────────
create table public.projects (
  id                uuid          primary key default gen_random_uuid(),
  writer_id         uuid          not null references public.profiles(id) on delete cascade,
  title             text          not null,
  word_count        integer       not null default 0,
  revenue_generated numeric(10,2) not null default 0.00,
  created_at        timestamptz   not null default now(),
  updated_at        timestamptz   not null default now()
);


-- ── 3. EARNINGS ───────────────────────────────────────────────
-- One row per writer per day (or per transaction — your choice).
-- Only your server-side admin functions should INSERT here;
-- writers only ever SELECT their own rows.
create table public.earnings (
  id            uuid          primary key default gen_random_uuid(),
  writer_id     uuid          not null references public.profiles(id) on delete cascade,
  project_id    uuid          references public.projects(id) on delete set null,
  date          date          not null default current_date,
  amount_earned numeric(10,2) not null check (amount_earned >= 0),
  created_at    timestamptz   not null default now()
);


-- ── 4. ROW LEVEL SECURITY ─────────────────────────────────────
-- RLS is the core security guarantee. Even if a bug in your
-- front-end code requests the wrong writer_id, Postgres will
-- reject the query at the database level.

alter table public.profiles enable row level security;
alter table public.projects  enable row level security;
alter table public.earnings  enable row level security;

-- profiles: each writer sees and edits only their own row
create policy "profiles: select own"
  on public.profiles for select
  using (auth.uid() = id);

create policy "profiles: update own"
  on public.profiles for update
  using (auth.uid() = id)
  with check (auth.uid() = id);

-- projects: full CRUD, scoped to the owning writer
create policy "projects: select own"
  on public.projects for select
  using (auth.uid() = writer_id);

create policy "projects: insert own"
  on public.projects for insert
  with check (auth.uid() = writer_id);

create policy "projects: update own"
  on public.projects for update
  using (auth.uid() = writer_id)
  with check (auth.uid() = writer_id);

create policy "projects: delete own"
  on public.projects for delete
  using (auth.uid() = writer_id);

-- earnings: writers can only read — inserts come from your admin/server
create policy "earnings: select own"
  on public.earnings for select
  using (auth.uid() = writer_id);


-- ── 5. AUTO-PROVISION PROFILE ON SIGNUP ──────────────────────
-- Whenever a new user signs up via Supabase Auth, this trigger
-- creates their corresponding profiles row automatically.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, name, email)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'name', split_part(new.email, '@', 1)),
    new.email
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();


-- ── 6. SEED DATA (optional — for local testing) ───────────────
-- After creating a test writer account, paste their UUID below
-- and uncomment this block to populate sample data.
--
-- do $$
-- declare w uuid := 'PASTE-YOUR-WRITER-UUID-HERE';
-- begin
--
--   insert into public.projects (writer_id, title, word_count, revenue_generated)
--   values
--     (w, 'The Alpha''s Forbidden Mate',  42000, 284.50),
--     (w, 'Claimed by the Silver Wolf',   18500,  97.20),
--     (w, 'Bound to the Moon King',        6200,  18.00);
--
--   -- 30 days of random daily earnings between $2 and $32
--   insert into public.earnings (writer_id, date, amount_earned)
--   select w, current_date - s, round((random() * 30 + 2)::numeric, 2)
--   from generate_series(0, 29) s;
--
-- end $$;
