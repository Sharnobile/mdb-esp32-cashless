-- =========================================================
-- Fix stock decrement reliability
--
-- Problems fixed:
-- 1. When an embedded device is not assigned to any machine,
--    the trigger silently skips the stock decrement.
-- 2. When no matching tray exists for (machine_id, item_number),
--    the UPDATE hits 0 rows with no indication of failure.
-- 3. There is no audit trail when decrements are skipped.
--
-- Solution: log skipped decrements to a stock_decrement_log table
-- so operators can diagnose discrepancies. The sale is never
-- blocked — the trigger always returns NEW.
-- =========================================================

-- A. Create a log table for stock decrement issues
CREATE TABLE IF NOT EXISTS public.stock_decrement_log (
  id uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  created_at timestamptz NOT NULL DEFAULT now(),
  embedded_id uuid,
  machine_id uuid,
  item_number integer,
  item_price float8,
  reason text NOT NULL,
  sale_created_at timestamptz
);

ALTER TABLE public.stock_decrement_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY "stock_decrement_log_select" ON public.stock_decrement_log
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.embeddeds e
      WHERE e.id = stock_decrement_log.embedded_id
        AND e.company = public.my_company_id()
    )
    OR
    EXISTS (
      SELECT 1 FROM public."vendingMachine" vm
      WHERE vm.id = stock_decrement_log.machine_id
        AND vm.company = public.my_company_id()
    )
  );

-- B. Replace the trigger function with a version that logs failures
CREATE OR REPLACE FUNCTION public.stamp_machine_and_decrement_stock()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_machine_id uuid;
  v_rows_updated integer;
BEGIN
  IF NEW.machine_id IS NOT NULL THEN
    -- Manual insert: machine_id already set, use it directly
    v_machine_id := NEW.machine_id;
  ELSE
    -- Device insert: resolve machine_id from the embedded device
    SELECT vm.id INTO v_machine_id
    FROM public."vendingMachine" vm
    WHERE vm.embedded = NEW.embedded_id
    LIMIT 1;

    -- Stamp machine_id on the sale row
    NEW.machine_id := v_machine_id;
  END IF;

  -- Decrement tray stock if machine found
  IF v_machine_id IS NOT NULL THEN
    UPDATE public.machine_trays
    SET current_stock = greatest(0, current_stock - 1)
    WHERE machine_id = v_machine_id
      AND item_number = NEW.item_number;

    GET DIAGNOSTICS v_rows_updated = ROW_COUNT;

    IF v_rows_updated = 0 THEN
      INSERT INTO public.stock_decrement_log
        (embedded_id, machine_id, item_number, item_price, reason, sale_created_at)
      VALUES
        (NEW.embedded_id, v_machine_id, NEW.item_number, NEW.item_price,
         'no_matching_tray', NEW.created_at);
    END IF;
  ELSE
    -- No machine found for this device
    INSERT INTO public.stock_decrement_log
      (embedded_id, machine_id, item_number, item_price, reason, sale_created_at)
    VALUES
      (NEW.embedded_id, NULL, NEW.item_number, NEW.item_price,
       'no_machine_for_device', NEW.created_at);
  END IF;

  RETURN NEW;
END
$$;
