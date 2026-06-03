-- Writer Rank System Migration
-- Tiers: unranked → bronze → gold → platinum
-- Bronze: assigned on contract sign ($100 bonus)
-- Gold:   $500+/month consistently ($120 bonus)
-- Platinum: $1000+/month ($140 bonus)

-- 1. Add rank column to profiles
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS rank text NOT NULL DEFAULT 'unranked';

ALTER TABLE public.profiles
  DROP CONSTRAINT IF EXISTS profiles_rank_check;

ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_rank_check
  CHECK (rank IN ('unranked', 'bronze', 'gold', 'platinum'));

-- 2. Trigger: automatically set bronze when a contract is signed
CREATE OR REPLACE FUNCTION fn_bronze_on_contract_sign()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NEW.status = 'signed' AND (OLD.status IS DISTINCT FROM 'signed') THEN
    UPDATE public.profiles
    SET rank = 'bronze'
    WHERE id = NEW.user_id AND rank = 'unranked';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_bronze_on_sign ON public.contracts;
CREATE TRIGGER trg_bronze_on_sign
  AFTER UPDATE ON public.contracts
  FOR EACH ROW EXECUTE FUNCTION fn_bronze_on_contract_sign();

-- 3. Admin function: manually set a writer's rank
CREATE OR REPLACE FUNCTION admin_set_writer_rank(p_user_id uuid, p_rank text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF p_rank NOT IN ('unranked', 'bronze', 'gold', 'platinum') THEN
    RAISE EXCEPTION 'Invalid rank: %', p_rank;
  END IF;
  UPDATE public.profiles SET rank = p_rank WHERE id = p_user_id;
END;
$$;
