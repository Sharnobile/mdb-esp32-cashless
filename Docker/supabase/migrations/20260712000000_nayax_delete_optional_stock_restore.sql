-- Nayax reconciliation: allow deleting a ghost sale WITHOUT restoring tray stock.
--
-- Background: `delete_sale_and_restore_stock` always did `current_stock + 1`
-- (capped at capacity). For a phantom sale that never actually dispensed a
-- product that is correct — but when the physical stock already reflects
-- reality, bumping it back up over-counts. Add an optional `p_restore_stock`
-- flag (default true → unchanged behaviour for every existing caller, incl.
-- the /machines/[id] manual-sale delete which passes only p_sale_id).
--
-- Adding a defaulted second parameter would make the single-arg call ambiguous
-- against the existing 1-arg function, so drop the old signature first.

DROP FUNCTION IF EXISTS public.delete_sale_and_restore_stock(uuid);

CREATE OR REPLACE FUNCTION public.delete_sale_and_restore_stock(
  p_sale_id uuid,
  p_restore_stock boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sale RECORD;
  v_company_id uuid;
BEGIN
  -- Verify caller is admin
  IF NOT public.i_am_admin() THEN
    RAISE EXCEPTION 'only admins can delete sales';
  END IF;

  -- Fetch the sale
  SELECT s.id, s.created_at, s.machine_id, s.item_number, s.item_price, s.channel
  INTO v_sale
  FROM public.sales s
  WHERE s.id = p_sale_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'sale not found';
  END IF;

  -- Verify the sale belongs to the caller's company
  SELECT vm.company INTO v_company_id
  FROM public."vendingMachine" vm
  WHERE vm.id = v_sale.machine_id;

  IF v_company_id IS NULL OR v_company_id != public.my_company_id() THEN
    RAISE EXCEPTION 'sale does not belong to your company';
  END IF;

  -- Delete the sale
  DELETE FROM public.sales WHERE id = p_sale_id;

  -- Restore tray stock (+1, capped at capacity) unless the caller opted out.
  IF p_restore_stock
     AND v_sale.machine_id IS NOT NULL
     AND v_sale.item_number IS NOT NULL THEN
    UPDATE public.machine_trays
    SET current_stock = LEAST(current_stock + 1, capacity)
    WHERE machine_id = v_sale.machine_id
      AND item_number = v_sale.item_number;
  END IF;

  RETURN jsonb_build_object(
    'id', v_sale.id,
    'created_at', v_sale.created_at,
    'machine_id', v_sale.machine_id,
    'item_number', v_sale.item_number,
    'item_price', v_sale.item_price,
    'channel', v_sale.channel,
    'stock_restored', p_restore_stock
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.delete_sale_and_restore_stock(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_sale_and_restore_stock(uuid, boolean) TO service_role;
