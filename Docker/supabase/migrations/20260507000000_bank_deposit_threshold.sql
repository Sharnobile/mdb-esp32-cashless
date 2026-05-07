-- =========================================================
-- Per-Barkasse threshold for highlighting the "Geld auf
-- Bank einzahlen" CTA. Default 500 EUR; minimum 1 EUR
-- enforced at the application layer.
-- =========================================================

ALTER TABLE public.cash_books
  ADD COLUMN IF NOT EXISTS bank_deposit_threshold float8 NOT NULL DEFAULT 500;
