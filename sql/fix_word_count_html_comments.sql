-- ============================================================
-- Fix: the server-side (authoritative) word-count function didn't
-- know about HTML comments, so content pasted from Word/Google Docs
-- could inflate the word count shown in chapter lists/previews vs.
-- the count shown live inside the editor while writing.
--
-- Root cause: Word's clipboard HTML embeds a lot of its metadata as
-- HTML comments (e.g. <!--[if gte mso 9]><xml>...</xml><![endif]-->).
-- The paste sanitizer (dashboard/index.html and dashboard/admin.html,
-- _sanitizePastedHtml) already strips <style>/<script>/<img> tags but
-- never removed comment nodes -- they were left in the saved content
-- string. The live in-editor word count reads the browser's rendered
-- DOM (innerText), which correctly never includes comment content --
-- but this function stripped HTML tags with a plain regex that has
-- no notion of "comment", so any text sitting inside one of those
-- comment blocks got counted as real words. Fixed the client-side
-- paste sanitizer separately (both editors) so this can't happen
-- again going forward; this migration fixes the server-side counting
-- function itself and backfills every existing chapter's word_count
-- so already-affected chapters show the correct number immediately,
-- without needing to be re-saved first.
-- ============================================================

CREATE OR REPLACE FUNCTION public._compute_word_count(p_content text)
RETURNS int LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v_stripped text;
BEGIN
  IF p_content IS NULL THEN RETURN 0; END IF;
  v_stripped := trim(both from regexp_replace(regexp_replace(regexp_replace(p_content, '<!--.*?-->', ' ', 'g'), '<[^>]*>', ' ', 'g'), '\s+', ' ', 'g'));
  IF v_stripped = '' THEN RETURN 0; END IF;
  RETURN array_length(regexp_split_to_array(v_stripped, '\s+'), 1);
END;
$$;

-- One-time backfill, same as the original word-count-source-of-truth
-- migration -- fixes every chapter already sitting on an inflated
-- count right now, rather than waiting for each one's next edit.
UPDATE public.chapters SET word_count = public._compute_word_count(content);
