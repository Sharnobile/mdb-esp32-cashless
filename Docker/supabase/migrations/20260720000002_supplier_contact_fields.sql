-- Add optional contact/reference fields to suppliers, beyond just the name —
-- email, phone, physical address, and the company's own customer/account
-- number with that supplier (useful for reordering or support calls).

ALTER TABLE public.suppliers
  ADD COLUMN IF NOT EXISTS email           text,
  ADD COLUMN IF NOT EXISTS phone           text,
  ADD COLUMN IF NOT EXISTS address         text,
  ADD COLUMN IF NOT EXISTS customer_number text;
