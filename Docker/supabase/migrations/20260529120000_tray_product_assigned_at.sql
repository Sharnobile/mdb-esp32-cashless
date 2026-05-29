-- =========================================================
-- Track how long the CURRENT product has occupied a tray slot
-- =========================================================
-- `machine_trays.created_at` records when the *slot* was created, not when the
-- *product* in it was assigned. Without a separate timestamp we cannot tell a
-- product placed yesterday (few/no sales is expected) from one that has sat in
-- the slot for months (few/no sales is a real problem). This adds an explicit
-- `product_assigned_at` that is (re)stamped whenever the slot's product_id
-- changes, so the Analysis tab can give freshly-stocked products a fair trial
-- window before flagging them as dead stock.

-- A. Column (backward-compatible: nullable, populated by trigger going forward)
ALTER TABLE public.machine_trays
  ADD COLUMN IF NOT EXISTS product_assigned_at timestamptz;

-- B. Backfill existing occupied slots.
-- We have no historical record of when each product was actually assigned, so
-- fall back to the slot's creation time. This is the conservative choice: it
-- treats long-standing products as "established" (judged normally) rather than
-- granting them an undeserved trial window. Empty slots stay NULL.
UPDATE public.machine_trays
  SET product_assigned_at = created_at
  WHERE product_id IS NOT NULL
    AND product_assigned_at IS NULL;

-- C. Trigger: (re)stamp product_assigned_at on product assignment changes.
--    INSERT  → stamp now() if a product is assigned (and not explicitly given)
--    UPDATE  → if product_id changed, stamp now() (or clear to NULL when the
--              product was removed)
CREATE OR REPLACE FUNCTION public.stamp_tray_product_assigned_at()
  RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = ''
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.product_id IS NOT NULL AND NEW.product_assigned_at IS NULL THEN
      NEW.product_assigned_at := now();
    END IF;
  ELSIF TG_OP = 'UPDATE' THEN
    IF NEW.product_id IS DISTINCT FROM OLD.product_id THEN
      NEW.product_assigned_at := CASE
        WHEN NEW.product_id IS NULL THEN NULL
        ELSE now()
      END;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_tray_product_change_stamp_assigned_at ON public.machine_trays;
CREATE TRIGGER on_tray_product_change_stamp_assigned_at
  BEFORE INSERT OR UPDATE ON public.machine_trays
  FOR EACH ROW EXECUTE FUNCTION public.stamp_tray_product_assigned_at();
