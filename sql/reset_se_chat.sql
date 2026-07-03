-- ============================================================
-- One-off maintenance: wipe the private admin <-> Senior Editor
-- chat history clean, so Christine's account starts fresh once her
-- PIN is reset. Run once in Supabase -> SQL Editor.
--
-- Scoped precisely to the admin<->SE conversation via sent_as —
-- writer<->admin chats (sent_as: 'writer'/'admin' from that context)
-- and any other traffic are untouched. This does NOT touch her PIN
-- or profile row — reset her PIN separately from the admin dashboard
-- (Reset Senior Editor PIN) so she gets a clean sign-in on top of a
-- clean chat.
-- ============================================================

-- A message belongs to this conversation if either:
--   - it was sent BY Christine (sent_as:'senior_editor' — her only chat
--     partner is admin, so every one of these is this conversation), or
--   - it was sent BY admin specifically TO Christine (sent_as:'admin' is
--     also used for admin's per-writer chats, so this must be scoped by
--     recipient, not sent_as alone, or it would wipe admin<->writer chats too)
DELETE FROM public.messages
WHERE (sent_as = 'senior_editor' AND sender_id IN (SELECT id FROM public.profiles WHERE is_senior_editor = true))
   OR (sent_as = 'admin' AND recipient_id IN (SELECT id FROM public.profiles WHERE is_senior_editor = true));
