-- ============================================================
-- Phase 4: Onboarding, briefs, payment info, payout tracking
-- Run in Supabase Dashboard → SQL Editor
-- ============================================================

-- 1. Add onboarding flag + payment info to profiles
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS onboarded   boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS payment_info text;

-- 2. Payouts — admin records payments sent to writers
CREATE TABLE IF NOT EXISTS public.payouts (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  writer_id  uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  amount     numeric(10,2) NOT NULL CHECK (amount > 0),
  period     text        NOT NULL,         -- e.g. "May 2026"
  paid_at    timestamptz NOT NULL DEFAULT now(),
  notes      text,
  paid_by    uuid        REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.payouts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "payouts_writer_read" ON public.payouts;
CREATE POLICY "payouts_writer_read" ON public.payouts
  FOR SELECT USING (auth.uid() = writer_id);

DROP POLICY IF EXISTS "payouts_admin_all" ON public.payouts;
CREATE POLICY "payouts_admin_all" ON public.payouts
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true)
  );

-- 3. Briefs — admin assigns a project brief to each writer
CREATE TABLE IF NOT EXISTS public.briefs (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  writer_id        uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  created_by       uuid        REFERENCES auth.users(id),
  title            text        NOT NULL,
  genre            text        NOT NULL DEFAULT 'Werewolf Romance',
  synopsis         text,
  character_notes  text,
  plot_outline     text,
  status           text        NOT NULL DEFAULT 'active'
                               CHECK (status IN ('active', 'archived')),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.briefs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "briefs_writer_read" ON public.briefs;
CREATE POLICY "briefs_writer_read" ON public.briefs
  FOR SELECT USING (auth.uid() = writer_id);

DROP POLICY IF EXISTS "briefs_admin_all" ON public.briefs;
CREATE POLICY "briefs_admin_all" ON public.briefs
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true)
  );
