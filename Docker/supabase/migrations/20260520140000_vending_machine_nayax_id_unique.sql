-- Enforce that within a company, a Nayax machine ID can map to at most
-- one of our machines. Without this, two vendingMachine rows can share
-- the same nayax_machine_id and the reconciliation mapping silently
-- attributes Nayax sales to one of them at random.
--
-- Partial index → NULL values do not collide.
CREATE UNIQUE INDEX IF NOT EXISTS vending_machine_nayax_id_per_company_uq
  ON public."vendingMachine" (company, nayax_machine_id)
  WHERE nayax_machine_id IS NOT NULL;

-- The non-unique index from 20260520120000 is now redundant for lookup
-- purposes (the unique index also serves as a btree lookup) but we keep
-- it because dropping it would be a separate migration concern and the
-- storage cost is negligible.
