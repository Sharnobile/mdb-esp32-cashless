-- Add requires_app flag to deal_cache
-- Some retailer offers require their loyalty app for the deal price
-- (e.g. Netto-App, Lidl Plus, REWE Bonus).

ALTER TABLE public.deal_cache
  ADD COLUMN IF NOT EXISTS requires_app boolean NOT NULL DEFAULT false;
