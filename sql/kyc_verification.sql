-- ============================================================
-- KYC (identity verification) for writers.
--
-- A writer must upload a valid government-issued ID (National ID
-- Card, NIN Slip, International Passport, Driver's License, or
-- Voter's Card) before they can use the dashboard, starting
-- immediately after they sign their contract. Existing writers who
-- already signed a contract before this feature shipped are gated
-- the same way -- the client blocks on "contract signed + no valid
-- KYC on file", so they get the same forced prompt on their next
-- visit with no separate backfill needed.
--
-- One row per writer (writer_id is the primary key) -- a rejected
-- submission is resubmitted by overwriting the same row rather than
-- keeping a history table, since only the *current* verification
-- state matters for gating access; nothing in this app needs to
-- browse a writer's past rejected attempts.
--
-- Writers never get raw table INSERT/UPDATE grants on this table --
-- same reasoning as sign_contract() in fix_contract_signing.sql: a
-- narrow SECURITY DEFINER RPC that only ever sets the columns it
-- means to set (never a client-supplied status/reviewed_by/etc.)
-- closes off any chance of a writer forging their own "approved"
-- status. Run once in Supabase SQL Editor -- safe to re-run.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.kyc_verifications (
  writer_id        uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  id_type          text NOT NULL CHECK (id_type IN ('national_id','nin_slip','passport','drivers_license','voters_card')),
  id_image_path    text NOT NULL,
  status            text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected')),
  rejection_reason text,
  submitted_at      timestamptz NOT NULL DEFAULT now(),
  reviewed_at       timestamptz,
  reviewed_by       uuid REFERENCES public.profiles(id)
);

ALTER TABLE public.kyc_verifications ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "writer_read_own_kyc" ON public.kyc_verifications;
CREATE POLICY "writer_read_own_kyc" ON public.kyc_verifications
  FOR SELECT TO authenticated
  USING (writer_id = auth.uid());

DROP POLICY IF EXISTS "admin_read_all_kyc" ON public.kyc_verifications;
CREATE POLICY "admin_read_all_kyc" ON public.kyc_verifications
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true));

-- No INSERT/UPDATE/DELETE policies at all -- every write goes through
-- the RPCs below.

-- ── Private storage bucket for uploaded ID images ──────────────────
INSERT INTO storage.buckets (id, name, public)
VALUES ('kyc-documents', 'kyc-documents', false)
ON CONFLICT (id) DO UPDATE SET public = false;

DROP POLICY IF EXISTS "writer_upload_own_kyc_doc" ON storage.objects;
CREATE POLICY "writer_upload_own_kyc_doc" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'kyc-documents' AND (storage.foldername(name))[1] = auth.uid()::text);

DROP POLICY IF EXISTS "writer_read_own_kyc_doc" ON storage.objects;
CREATE POLICY "writer_read_own_kyc_doc" ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'kyc-documents' AND (storage.foldername(name))[1] = auth.uid()::text);

DROP POLICY IF EXISTS "admin_read_all_kyc_docs" ON storage.objects;
CREATE POLICY "admin_read_all_kyc_docs" ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'kyc-documents'
    AND EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true)
  );

-- ── Writer: submit / resubmit an ID ─────────────────────────────────
CREATE OR REPLACE FUNCTION public.submit_kyc(
  p_id_type       text,
  p_id_image_path text
)
RETURNS SETOF public.kyc_verifications
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;
  IF p_id_type NOT IN ('national_id','nin_slip','passport','drivers_license','voters_card') THEN
    RAISE EXCEPTION 'Invalid ID type.';
  END IF;
  IF p_id_image_path IS NULL OR length(trim(p_id_image_path)) = 0 THEN
    RAISE EXCEPTION 'Missing ID image.';
  END IF;
  -- The path must actually be this writer's own storage folder --
  -- otherwise a writer could point their KYC row at someone else's
  -- already-uploaded (and possibly already-approved) document.
  IF split_part(p_id_image_path, '/', 1) <> auth.uid()::text THEN
    RAISE EXCEPTION 'Invalid image path.';
  END IF;

  RETURN QUERY
  INSERT INTO public.kyc_verifications (writer_id, id_type, id_image_path, status, rejection_reason, submitted_at, reviewed_at, reviewed_by)
  VALUES (auth.uid(), p_id_type, p_id_image_path, 'pending', NULL, now(), NULL, NULL)
  ON CONFLICT (writer_id) DO UPDATE
    SET id_type          = EXCLUDED.id_type,
        id_image_path    = EXCLUDED.id_image_path,
        status            = 'pending',
        rejection_reason = NULL,
        submitted_at      = now(),
        reviewed_at       = NULL,
        reviewed_by       = NULL
  RETURNING *;
END;
$$;
GRANT EXECUTE ON FUNCTION public.submit_kyc(text, text) TO authenticated;

-- ── Admin: list every writer's verification state ──────────────────
CREATE OR REPLACE FUNCTION public.admin_get_kyc_verifications()
RETURNS TABLE (
  writer_id         uuid,
  writer_name       text,
  writer_email      text,
  id_type           text,
  id_image_path     text,
  status             text,
  rejection_reason  text,
  submitted_at       timestamptz,
  reviewed_at        timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true) THEN
    RAISE EXCEPTION 'Forbidden';
  END IF;
  RETURN QUERY
  SELECT k.writer_id, p.name, p.email, k.id_type, k.id_image_path, k.status, k.rejection_reason, k.submitted_at, k.reviewed_at
  FROM public.kyc_verifications k
  JOIN public.profiles p ON p.id = k.writer_id
  ORDER BY k.submitted_at DESC;
END;
$$;
GRANT EXECUTE ON FUNCTION public.admin_get_kyc_verifications() TO authenticated;

-- ── Admin: approve / reject ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_review_kyc(
  p_writer_id         uuid,
  p_approve           boolean,
  p_rejection_reason  text DEFAULT NULL
)
RETURNS SETOF public.kyc_verifications
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rows int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true) THEN
    RAISE EXCEPTION 'Forbidden';
  END IF;
  IF NOT p_approve AND (p_rejection_reason IS NULL OR length(trim(p_rejection_reason)) = 0) THEN
    RAISE EXCEPTION 'A rejection reason is required.';
  END IF;

  RETURN QUERY
  UPDATE public.kyc_verifications
     SET status            = CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END,
         rejection_reason  = CASE WHEN p_approve THEN NULL ELSE p_rejection_reason END,
         reviewed_at        = now(),
         reviewed_by        = auth.uid()
   WHERE writer_id = p_writer_id
     AND status = 'pending'
  RETURNING *;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN
    RAISE EXCEPTION 'Verification record not found or already reviewed.';
  END IF;
END;
$$;
GRANT EXECUTE ON FUNCTION public.admin_review_kyc(uuid, boolean, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
