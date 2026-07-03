-- ============================================================
-- Senior Editor: full board of live prompts (available + in dev)
-- Run in Supabase → SQL Editor.
-- ============================================================

-- Every approved, active prompt on the platform, tagged with whether
-- it's free to claim or currently being developed (with time left).
-- No writer identity is exposed.
CREATE OR REPLACE FUNCTION public.get_se_prompt_board()
RETURNS TABLE (id uuid, title text, brief text, genre text, banner_url text, claim_state text, expires_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_senior_editor() THEN RAISE EXCEPTION 'Senior Editors only.'; END IF;
  PERFORM public.release_expired_prompt_claims();
  RETURN QUERY
  SELECT p.id, p.title, p.brief, p.genre, p.banner_url,
         CASE WHEN c.id IS NOT NULL THEN 'taken' ELSE 'available' END AS claim_state,
         c.expires_at
  FROM public.writing_prompts p
  LEFT JOIN public.prompt_claims c ON c.prompt_id = p.id AND c.status = 'active'
  WHERE p.is_active = true AND p.review_status = 'approved'
  ORDER BY (c.id IS NOT NULL) DESC, p.sort_order ASC, p.created_at DESC;
END;
$$;
