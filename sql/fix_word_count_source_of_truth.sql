-- ============================================================
-- Word count: make the database the single source of truth,
-- instead of trusting whatever count each client happens to send.
-- Run in Supabase → SQL Editor.
--
-- Root cause: word_count has always been a client-computed value
-- passed alongside content on every save (writer's autosave, admin's
-- fullscreen editor, admin's doReject(), Christine's
-- se_save_chapter_content RPC). Four different code paths, four
-- slightly different counting implementations (DOM innerText vs a
-- raw HTML string vs a plain textarea value) -- any one of them
-- drifting out of sync with the others shows up as "the editor says
-- one number, the list/other dashboard says another." One instance
-- of this (doReject() counting from an unrendered HTML string) was
-- already patched directly; this closes the entire class at once by
-- never trusting a client-supplied count again, no matter which path
-- writes to the row.
-- ============================================================

-- ── 1. Canonical word-count function ─────────────────────────────
-- Strips HTML tags, collapses whitespace, then counts tokens -- same
-- basic approach as the client-side sanitizer-then-count path
-- (_wordsFromHtml), just server-side and therefore authoritative.
CREATE OR REPLACE FUNCTION public._compute_word_count(p_content text)
RETURNS int LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v_stripped text;
BEGIN
  IF p_content IS NULL THEN RETURN 0; END IF;
  v_stripped := trim(both from regexp_replace(regexp_replace(p_content, '<[^>]*>', ' ', 'g'), '\s+', ' ', 'g'));
  IF v_stripped = '' THEN RETURN 0; END IF;
  RETURN array_length(regexp_split_to_array(v_stripped, '\s+'), 1);
END;
$$;

-- ── 2. Trigger: recompute on every write, ignore whatever the
--       client sent for word_count ───────────────────────────────
-- Not restricted to "UPDATE OF content" -- doReject() and other
-- status-only updates don't touch content in the same statement,
-- but should still leave word_count correct if it happened to be
-- wrong going in. Recomputing unconditionally is cheap and always
-- safe: it's a no-op in effect whenever content didn't change.
CREATE OR REPLACE FUNCTION public.trg_chapters_word_count()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.word_count := public._compute_word_count(NEW.content);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_chapters_word_count ON public.chapters;
CREATE TRIGGER trg_chapters_word_count
  BEFORE INSERT OR UPDATE ON public.chapters
  FOR EACH ROW EXECUTE FUNCTION public.trg_chapters_word_count();

-- ── 3. One-time backfill ──────────────────────────────────────────
-- Fixes every chapter already sitting on a wrong count, immediately,
-- rather than waiting for each one's next edit to correct it.
UPDATE public.chapters SET word_count = public._compute_word_count(content);
