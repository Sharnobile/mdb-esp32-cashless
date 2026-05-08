-- =========================================================
-- Per-Barkasse toggle for tracking individual machines on
-- withdrawal entries. When false (default), the
-- "Aus welchem Automat?" selector is hidden in the UI and
-- machine_id is left null on new withdrawal entries.
-- Existing entries keep their machine_id unchanged.
-- =========================================================

ALTER TABLE public.cash_books
  ADD COLUMN IF NOT EXISTS track_per_machine boolean NOT NULL DEFAULT false;
