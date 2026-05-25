-- ── AFS Chat Role Patch ──────────────────────────────────────────────────────
-- Adds a sent_as column so the UI can tell writer messages from admin messages
-- even when both roles use the same account.
-- Run this in Supabase SQL Editor.

ALTER TABLE messages ADD COLUMN IF NOT EXISTS sent_as text NOT NULL DEFAULT 'writer';

-- Notify PostgREST to reload schema cache
NOTIFY pgrst, 'reload schema';
