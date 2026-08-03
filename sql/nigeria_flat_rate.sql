-- ============================================================
-- Nigeria-focused flat rate: capture a country at application time
-- so it flows into the writer's profile on approval. Run in Supabase
-- → SQL Editor.
--
-- This does NOT add any per-writer currency-branching logic --
-- per product direction, the flat-rate program is NGN-only (the
-- studio's writer pool is overwhelmingly Nigerian and staying that
-- way), so the ₦2/word rate is uniform across every Flat Rate
-- contract. country is tracked as writer metadata / admin-visible
-- eligibility signal (self-declared at application, editable by the
-- writer in Payment Settings, visible to admin), not as an input to
-- any pay calculation. profiles.country already existed for this
-- (used today only in the contract template); this just starts
-- populating it earlier, from the application, instead of leaving it
-- blank until the writer fills in Payment Settings themselves.
-- ============================================================

ALTER TABLE public.applications
  ADD COLUMN IF NOT EXISTS country text;
