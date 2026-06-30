-- Fix: contracts table has a stale policy/trigger referencing 'user_id'
-- The column is actually named 'writer_id'. Drop all UPDATE policies and recreate.

DROP POLICY IF EXISTS "writer_sign_own_contract"  ON public.contracts;
DROP POLICY IF EXISTS "Users can sign own contract" ON public.contracts;
DROP POLICY IF EXISTS "writers_can_sign"            ON public.contracts;
DROP POLICY IF EXISTS "writer_update"               ON public.contracts;

-- Recreate with correct column name
CREATE POLICY "writer_sign_own_contract" ON public.contracts
  FOR UPDATE
  USING  (auth.uid() = writer_id AND status = 'pending')
  WITH CHECK (auth.uid() = writer_id);
