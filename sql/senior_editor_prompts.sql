-- ============================================================
-- Senior Editor: create/list own prompts + banner upload rights
-- Run in Supabase → SQL Editor (after senior_editor.sql).
-- ============================================================

-- Senior Editor submits a prompt → lands in the admin's review queue.
CREATE OR REPLACE FUNCTION public.se_add_prompt(
  p_title text, p_brief text, p_genre text DEFAULT NULL,
  p_banner_url text DEFAULT NULL, p_sort_order int DEFAULT 0
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid;
BEGIN
  IF NOT public.is_senior_editor() THEN RAISE EXCEPTION 'Senior Editors only.'; END IF;
  IF p_title IS NULL OR length(trim(p_title)) = 0 THEN RAISE EXCEPTION 'Title is required.'; END IF;
  IF p_brief IS NULL OR length(trim(p_brief)) = 0 THEN RAISE EXCEPTION 'Brief is required.'; END IF;
  INSERT INTO public.writing_prompts
    (title, brief, genre, banner_url, sort_order, is_active, created_by, created_by_role, review_status)
  VALUES
    (trim(p_title), trim(p_brief), NULLIF(trim(COALESCE(p_genre, '')), ''), p_banner_url,
     COALESCE(p_sort_order, 0), true, auth.uid(), 'senior_editor', 'pending')
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- Senior Editor's own submissions + their current review state.
CREATE OR REPLACE FUNCTION public.get_se_my_prompts()
RETURNS SETOF public.writing_prompts LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_senior_editor() THEN RAISE EXCEPTION 'Senior Editors only.'; END IF;
  RETURN QUERY SELECT * FROM public.writing_prompts
    WHERE created_by_role = 'senior_editor' ORDER BY created_at DESC;
END;
$$;

-- Senior Editor may withdraw one of her own prompts while it is still pending.
CREATE OR REPLACE FUNCTION public.se_delete_prompt(p_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_senior_editor() THEN RAISE EXCEPTION 'Senior Editors only.'; END IF;
  DELETE FROM public.writing_prompts
   WHERE id = p_id AND created_by_role = 'senior_editor' AND review_status = 'pending';
END;
$$;

-- Let the Senior Editor upload prompt banners too (was admin-only).
DROP POLICY IF EXISTS "prompt_banners_admin_write" ON storage.objects;
CREATE POLICY "prompt_banners_admin_write" ON storage.objects
  FOR ALL USING (
    bucket_id = 'prompt-banners' AND (
      EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true)
      OR public.is_senior_editor()
    )
  )
  WITH CHECK (
    bucket_id = 'prompt-banners' AND (
      EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true)
      OR public.is_senior_editor()
    )
  );
