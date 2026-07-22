-- Track which supplier a warehouse stock batch (and the intake transaction that
-- created it) came from — additive, nullable, opt-in. Needed for traceability:
-- a product's supplier can vary between deliveries, so this is tracked per batch
-- rather than derived from the product's most recent purchase price (the app
-- still prefills the picker from that as a convenience default).

ALTER TABLE public.warehouse_stock_batches
  ADD COLUMN IF NOT EXISTS supplier_id uuid REFERENCES public.suppliers(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_wsb_supplier ON public.warehouse_stock_batches (supplier_id);

-- Denormalized onto the transaction row too, mirroring the existing
-- batch_number/expiration_date columns on warehouse_transactions — lets the
-- "Recent Intakes" list show the supplier without a second join through the
-- (possibly since-modified) batch.
ALTER TABLE public.warehouse_transactions
  ADD COLUMN IF NOT EXISTS supplier_id uuid REFERENCES public.suppliers(id) ON DELETE SET NULL;
