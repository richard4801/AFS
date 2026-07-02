-- ============================================================
-- Writing Prompts + 72-hour claim system
-- Run in Supabase Dashboard → SQL Editor
--
-- Admin uploads verified writing prompts (banner + brief) to the
-- writer home feed. A writer taps "Develop Prompt" to claim one;
-- that starts an exclusive 72-hour timer. If they don't deliver in
-- time the claim is auto-released back to the pool (hard enforcement
-- via pg_cron + a defensive lazy sweep on every feed read).
-- ============================================================

-- ── 1. Tables ───────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.writing_prompts (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  title       text        NOT NULL,
  brief       text        NOT NULL,
  genre       text,
  banner_url  text,
  sort_order  int         NOT NULL DEFAULT 0,
  is_active   boolean     NOT NULL DEFAULT true,
  created_by  uuid        REFERENCES auth.users(id),
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.prompt_claims (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  prompt_id    uuid        NOT NULL REFERENCES public.writing_prompts(id) ON DELETE CASCADE,
  writer_id    uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  claimed_at   timestamptz NOT NULL DEFAULT now(),
  expires_at   timestamptz NOT NULL,
  status       text        NOT NULL DEFAULT 'active'
                           CHECK (status IN ('active', 'completed', 'expired', 'released')),
  book_id      uuid        REFERENCES public.books(id) ON DELETE SET NULL,
  released_at  timestamptz,
  completed_at timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now()
);

-- Exclusivity: at most one ACTIVE claim per prompt, and one per writer.
CREATE UNIQUE INDEX IF NOT EXISTS one_active_claim_per_prompt
  ON public.prompt_claims (prompt_id) WHERE status = 'active';
CREATE UNIQUE INDEX IF NOT EXISTS one_active_claim_per_writer
  ON public.prompt_claims (writer_id) WHERE status = 'active';

-- Sweep + lookup indexes
CREATE INDEX IF NOT EXISTS prompt_claims_expiry
  ON public.prompt_claims (status, expires_at);
CREATE INDEX IF NOT EXISTS prompt_claims_writer
  ON public.prompt_claims (writer_id);

-- ── 2. Row-level security ───────────────────────────────────────

ALTER TABLE public.writing_prompts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.prompt_claims   ENABLE ROW LEVEL SECURITY;

-- Prompts: everyone signed-in sees active prompts; admins manage all.
DROP POLICY IF EXISTS "prompts_read_active" ON public.writing_prompts;
CREATE POLICY "prompts_read_active" ON public.writing_prompts
  FOR SELECT USING (
    is_active = true
    OR EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true)
  );

DROP POLICY IF EXISTS "prompts_admin_all" ON public.writing_prompts;
CREATE POLICY "prompts_admin_all" ON public.writing_prompts
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true)
  );

-- Claims: a writer sees only their own; admins see all.
-- (Inserts happen through claim_prompt(), a SECURITY DEFINER fn, so
--  there is deliberately no writer INSERT policy.)
DROP POLICY IF EXISTS "claims_read_own" ON public.prompt_claims;
CREATE POLICY "claims_read_own" ON public.prompt_claims
  FOR SELECT USING (auth.uid() = writer_id);

DROP POLICY IF EXISTS "claims_admin_all" ON public.prompt_claims;
CREATE POLICY "claims_admin_all" ON public.prompt_claims
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true)
  );

-- ── 3. Expiry sweep (hard 72h enforcement) ──────────────────────
-- Marks any active claim past its deadline as expired and frees the
-- prompt. Called by pg_cron AND lazily on every feed read, so it is
-- correct even if cron is ever paused.

CREATE OR REPLACE FUNCTION public.release_expired_prompt_claims()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  n integer;
BEGIN
  UPDATE public.prompt_claims
     SET status = 'expired', released_at = now()
   WHERE status = 'active' AND expires_at <= now();
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$$;

-- ── 4. Claim a prompt (writer) ──────────────────────────────────
-- Atomically claims a free prompt for the caller and starts the
-- 72-hour countdown. Raises a friendly error if the prompt is
-- already taken or the writer already has an active claim.

CREATE OR REPLACE FUNCTION public.claim_prompt(p_prompt_id uuid)
RETURNS public.prompt_claims LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_claim public.prompt_claims;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  -- Free up anything that has timed out before we test availability.
  PERFORM public.release_expired_prompt_claims();

  IF NOT EXISTS (SELECT 1 FROM public.writing_prompts WHERE id = p_prompt_id AND is_active = true) THEN
    RAISE EXCEPTION 'This prompt is no longer available.';
  END IF;

  IF EXISTS (SELECT 1 FROM public.prompt_claims WHERE writer_id = v_uid AND status = 'active') THEN
    RAISE EXCEPTION 'You already have an active prompt. Finish or release it first.';
  END IF;

  BEGIN
    INSERT INTO public.prompt_claims (prompt_id, writer_id, expires_at)
    VALUES (p_prompt_id, v_uid, now() + interval '72 hours')
    RETURNING * INTO v_claim;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'Someone just claimed this prompt. Please pick another.';
  END;

  RETURN v_claim;
END;
$$;

-- ── 5. Release a claim (writer gives up, or admin frees it) ──────

CREATE OR REPLACE FUNCTION public.release_prompt_claim(p_claim_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid      uuid := auth.uid();
  v_is_admin boolean := EXISTS (SELECT 1 FROM public.profiles WHERE id = v_uid AND is_admin = true);
  v_owner    uuid;
BEGIN
  SELECT writer_id INTO v_owner FROM public.prompt_claims WHERE id = p_claim_id AND status = 'active';
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'Claim not found or already closed.';
  END IF;
  IF NOT v_is_admin AND v_owner <> v_uid THEN
    RAISE EXCEPTION 'You can only release your own claim.';
  END IF;

  UPDATE public.prompt_claims
     SET status = 'released', released_at = now()
   WHERE id = p_claim_id;
END;
$$;

-- ── 6. Mark a claim completed (admin) ───────────────────────────

CREATE OR REPLACE FUNCTION public.complete_prompt_claim(p_claim_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true) THEN
    RAISE EXCEPTION 'Admins only.';
  END IF;
  UPDATE public.prompt_claims
     SET status = 'completed', completed_at = now()
   WHERE id = p_claim_id AND status = 'active';
END;
$$;

-- ── 7. Writer feed (release-expired first, then annotate) ───────
-- Returns every active prompt plus this caller's relationship to it:
--   claim_state = 'available' | 'mine' | 'taken'
-- Only the caller's own expiry/claim id are exposed (others' privacy).

CREATE OR REPLACE FUNCTION public.get_writer_prompt_feed()
RETURNS TABLE (
  id           uuid,
  title        text,
  brief        text,
  genre        text,
  banner_url   text,
  sort_order   int,
  claim_state  text,
  my_claim_id  uuid,
  my_expires_at timestamptz
) LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM public.release_expired_prompt_claims();

  RETURN QUERY
  SELECT
    p.id, p.title, p.brief, p.genre, p.banner_url, p.sort_order,
    CASE
      WHEN mine.id IS NOT NULL         THEN 'mine'
      WHEN taken.id IS NOT NULL        THEN 'taken'
      ELSE 'available'
    END AS claim_state,
    mine.id          AS my_claim_id,
    mine.expires_at  AS my_expires_at
  FROM public.writing_prompts p
  LEFT JOIN public.prompt_claims mine
         ON mine.prompt_id = p.id AND mine.status = 'active' AND mine.writer_id = auth.uid()
  LEFT JOIN public.prompt_claims taken
         ON taken.prompt_id = p.id AND taken.status = 'active'
  WHERE p.is_active = true
  ORDER BY p.sort_order ASC, p.created_at DESC;
END;
$$;

-- ── 8. pg_cron: hard auto-release every 15 minutes ──────────────
-- Requires the pg_cron extension (Supabase: Database → Extensions →
-- enable "pg_cron"). Wrapped so that if pg_cron is unavailable the
-- migration still succeeds — get_writer_prompt_feed()'s lazy sweep
-- keeps expiry correct regardless. Safe to run repeatedly.

DO $$
BEGIN
  EXECUTE 'CREATE EXTENSION IF NOT EXISTS pg_cron';
  PERFORM cron.unschedule('release-expired-prompts')
    WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'release-expired-prompts');
  PERFORM cron.schedule(
    'release-expired-prompts',
    '*/15 * * * *',
    $cron$ SELECT public.release_expired_prompt_claims(); $cron$
  );
  RAISE NOTICE 'pg_cron scheduled: release-expired-prompts every 15 min.';
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_cron not scheduled (%). Lazy sweep on feed read still enforces the 72h expiry.', SQLERRM;
END $$;

-- ── 9. Storage bucket for prompt banners ────────────────────────
-- Public-read bucket; only admins can write. (You can also create
-- the bucket in Dashboard → Storage and skip the insert below.)

INSERT INTO storage.buckets (id, name, public)
VALUES ('prompt-banners', 'prompt-banners', true)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "prompt_banners_public_read" ON storage.objects;
CREATE POLICY "prompt_banners_public_read" ON storage.objects
  FOR SELECT USING (bucket_id = 'prompt-banners');

DROP POLICY IF EXISTS "prompt_banners_admin_write" ON storage.objects;
CREATE POLICY "prompt_banners_admin_write" ON storage.objects
  FOR ALL USING (
    bucket_id = 'prompt-banners'
    AND EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true)
  )
  WITH CHECK (
    bucket_id = 'prompt-banners'
    AND EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true)
  );
