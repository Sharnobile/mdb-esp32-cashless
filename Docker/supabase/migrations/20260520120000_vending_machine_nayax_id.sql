-- Adds nayax_machine_id to vendingMachine for Nayax sales reconciliation.
-- Nullable, additive, backward-compatible. Existing firmware and clients
-- ignore this column (they select * but don't depend on the field's
-- presence).
ALTER TABLE public."vendingMachine"
  ADD COLUMN IF NOT EXISTS nayax_machine_id text;

-- Sparse partial index — most rows are NULL until admins configure
-- mappings. Speeds up lookup by Nayax serial during reconciliation.
CREATE INDEX IF NOT EXISTS vending_machine_nayax_id_idx
  ON public."vendingMachine" (nayax_machine_id)
  WHERE nayax_machine_id IS NOT NULL;
