-- ============================================================
-- Fix: _compute_word_count() (shipped in
-- fix_word_count_source_of_truth.sql) didn't treat non-breaking
-- spaces as whitespace, so any chapter containing one -- a literal
-- U+00A0 byte, or the &nbsp; HTML entity in any of its written forms
-- -- undercounts: "word&nbsp;word" reads as one glued-together token
-- instead of two. This is the exact same non-breaking-space issue
-- _sanitizePastedHtml() already normalizes client-side (Word/Google
-- Docs paste routinely carries them) -- but that normalization only
-- runs on the paste path, not retroactively on already-stored
-- content, and Postgres's \s regex class is ASCII-only, unlike
-- JavaScript's (which does include U+00A0 per the ECMAScript spec).
-- That mismatch is why the migration could "run" without the number
-- actually changing: the trigger fired, but computed a different
-- wrong number, not the true one the browser's own live counter
-- shows.
-- Run in Supabase → SQL Editor.
-- ============================================================

CREATE OR REPLACE FUNCTION public._compute_word_count(p_content text)
RETURNS int LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v_stripped text;
BEGIN
  IF p_content IS NULL THEN RETURN 0; END IF;
  -- Normalize every written form of a non-breaking space to a real
  -- space before anything else: the named entity, decimal and hex
  -- numeric entities, and the raw character itself.
  v_stripped := regexp_replace(p_content, '&(nbsp|#160|#xa0|#x00a0);', ' ', 'gi');
  v_stripped := replace(v_stripped, chr(160), ' ');
  v_stripped := trim(both from regexp_replace(regexp_replace(v_stripped, '<[^>]*>', ' ', 'g'), '\s+', ' ', 'g'));
  IF v_stripped = '' THEN RETURN 0; END IF;
  RETURN array_length(regexp_split_to_array(v_stripped, '\s+'), 1);
END;
$$;

-- Re-run the backfill now that the function is corrected -- the
-- earlier backfill used the buggy version, so any chapter containing
-- a non-breaking space is still wrong even after that migration ran.
UPDATE public.chapters SET word_count = public._compute_word_count(content);
