-- =========================================================
-- Manual sales management: delete + insert RPCs
-- =========================================================

-- A. Update the existing trigger to support manual inserts
-- When machine_id is already set (manual insert), skip the embedded_id lookup
-- but still decrement tray stock. Backward-compatible: ESP sales have
-- machine_id = NULL at INSERT time, so behavior is unchanged for them.
CREATE OR REPLACE FUNCTION public.stamp_machine_and_decrement_stock()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_machine_id uuid;
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
  END IF;

  RETURN NEW;
END
$$;


-- B. RPC: delete a sale and restore tray stock (admin only)
CREATE OR REPLACE FUNCTION public.delete_sale_and_restore_stock(p_sale_id uuid)
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

  -- Restore tray stock (+1, capped at capacity)
  IF v_sale.machine_id IS NOT NULL AND v_sale.item_number IS NOT NULL THEN
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
    'channel', v_sale.channel
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.delete_sale_and_restore_stock(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_sale_and_restore_stock(uuid) TO service_role;


-- C. RPC: manually insert a sale (admin only)
-- The updated trigger above will detect that machine_id is already set,
-- skip the embedded_id lookup, and decrement tray stock normally.
CREATE OR REPLACE FUNCTION public.insert_manual_sale(
  p_machine_id uuid,
  p_item_number integer,
  p_item_price float8,
  p_channel text,
  p_created_at timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_company_id uuid;
  v_new_sale RECORD;
BEGIN
  -- Verify caller is admin
  IF NOT public.i_am_admin() THEN
    RAISE EXCEPTION 'only admins can insert manual sales';
  END IF;

  -- Verify the machine belongs to the caller's company
  SELECT vm.company INTO v_company_id
  FROM public."vendingMachine" vm
  WHERE vm.id = p_machine_id;

  IF v_company_id IS NULL OR v_company_id != public.my_company_id() THEN
    RAISE EXCEPTION 'machine does not belong to your company';
  END IF;

  -- Insert the sale with machine_id pre-set.
  -- The BEFORE INSERT trigger will see machine_id is NOT NULL,
  -- skip embedded_id lookup, and decrement tray stock.
  INSERT INTO public.sales (machine_id, item_number, item_price, channel, created_at)
  VALUES (p_machine_id, p_item_number, p_item_price, p_channel, p_created_at)
  RETURNING id, created_at, machine_id, item_number, item_price, channel
  INTO v_new_sale;

  RETURN jsonb_build_object(
    'id', v_new_sale.id,
    'created_at', v_new_sale.created_at,
    'machine_id', v_new_sale.machine_id,
    'item_number', v_new_sale.item_number,
    'item_price', v_new_sale.item_price,
    'channel', v_new_sale.channel
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.insert_manual_sale(uuid, integer, float8, text, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.insert_manual_sale(uuid, integer, float8, text, timestamptz) TO service_role;

-- D. Set REPLICA IDENTITY FULL on sales so DELETE events include the old row data in realtime
ALTER TABLE public.sales REPLICA IDENTITY FULL;
