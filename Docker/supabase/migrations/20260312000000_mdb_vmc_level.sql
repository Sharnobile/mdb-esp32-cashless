-- Add VMC feature level to MDB log history.
-- Nullable: old firmware won't send this field.
ALTER TABLE public.mdb_log ADD COLUMN vmc_level smallint;
