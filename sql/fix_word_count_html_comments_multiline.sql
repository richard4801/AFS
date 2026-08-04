-- ============================================================
-- Follow-up to sql/fix_word_count_html_comments.sql -- that fix's
-- regex ('<!--.*?-->') never actually matched anything, because `.`
-- doesn't match newlines by default (same as Python, JavaScript, most
-- regex engines), and real Word/MSO comment blocks are almost always
-- multi-line. So the previous migration's backfill silently stripped
-- zero comments from existing chapters -- the counting function
-- itself was still correct in *intent*, just never actually matched
-- real-world multi-line comments. Confirmed this directly: a
-- multi-line comment run through that exact pattern comes back
-- completely untouched, hidden text and all.
--
-- Fix: '<!--[\s\S]*?-->' instead of '<!--.*?-->' -- [\s\S] matches
-- any character (whitespace or not) regardless of dot-all mode, so
-- this works across newlines unconditionally. Re-running the backfill
-- with the corrected function actually strips the comments this time.
--
-- The client-side paste sanitizer fix (both editors, from the same
-- prior migration's commit) was never affected by this bug -- it
-- removes actual DOM comment nodes, not a regex match, so it was
-- already stripping comments correctly on every paste since it
-- shipped. This migration only fixes the server-side backfill path
-- for chapters that were pasted before that fix went live.
-- ============================================================

CREATE OR REPLACE FUNCTION public._compute_word_count(p_content text)
RETURNS int LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v_stripped text;
BEGIN
  IF p_content IS NULL THEN RETURN 0; END IF;
  v_stripped := trim(both from regexp_replace(regexp_replace(regexp_replace(p_content, '<!--[\s\S]*?-->', ' ', 'g'), '<[^>]*>', ' ', 'g'), '\s+', ' ', 'g'));
  IF v_stripped = '' THEN RETURN 0; END IF;
  RETURN array_length(regexp_split_to_array(v_stripped, '\s+'), 1);
END;
$$;

UPDATE public.chapters SET word_count = public._compute_word_count(content);
