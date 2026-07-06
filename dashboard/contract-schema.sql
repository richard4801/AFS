-- ── AFS Contracts Table ────────────────────────────────────────────
-- Run this in the Supabase SQL Editor

create table if not exists public.contracts (
  id             uuid        primary key default gen_random_uuid(),
  writer_id      uuid        not null references public.profiles(id) on delete cascade,
  doc_version    text        not null default 'v1',
  sent_at        timestamptz not null default now(),
  sent_by        uuid,
  signed_at      timestamptz,
  name_signed    text,
  ip_address     text,
  user_agent     text,
  status         text        not null default 'pending'
                               check (status in ('pending', 'signed', 'voided')),
  created_at     timestamptz not null default now()
);

-- Row Level Security
alter table public.contracts enable row level security;

-- Writers can view only their own contract
create policy "writer_select_own_contract" on public.contracts
  for select using (auth.uid() = writer_id);

-- SUPERSEDED: writers used to get a raw UPDATE policy here to sign their
-- own contract, but WITH CHECK (auth.uid() = writer_id) alone didn't
-- constrain which columns a "sign" update could touch. Replaced by the
-- narrow sign_contract() RPC in sql/fix_contract_signing.sql, which also
-- drops this policy — writers get no raw UPDATE access on this table.
-- create policy "writer_sign_own_contract" on public.contracts
--   for update
--   using  (auth.uid() = writer_id and status = 'pending')
--   with check (auth.uid() = writer_id);

-- Index for fast per-writer lookups
create index if not exists contracts_writer_id_idx on public.contracts(writer_id);
create index if not exists contracts_status_idx    on public.contracts(status);
