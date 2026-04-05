-- =========================================================
-- Tax Backfill Function
--
-- Stamps historical sales with tax data based on current
-- tax configuration. Only updates sales where
-- tax_rate_snapshot IS NULL.
-- =========================================================

CREATE OR REPLACE FUNCTION public.backfill_sales_tax(p_company_id uuid)
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_updated integer;
BEGIN
  -- Verify caller belongs to this company
  IF p_company_id != public.my_company_id() THEN
    RAISE EXCEPTION 'Access denied';
  END IF;

  UPDATE public.sales s
  SET
    tax_rate_snapshot = sub.rate,
    price_net = ROUND(s.item_price::numeric / (1 + sub.rate), 4),
    tax_amount = ROUND(s.item_price::numeric - ROUND(s.item_price::numeric / (1 + sub.rate), 4), 4)
  FROM (
    SELECT DISTINCT ON (s2.id)
      s2.id AS sale_id,
      tr.rate
    FROM public.sales s2
    JOIN public."vendingMachine" vm ON vm.id = s2.machine_id
    JOIN public.companies c ON c.id = vm.company
    JOIN public.machine_trays mt ON mt.machine_id = vm.id AND mt.item_number = s2.item_number
    JOIN public.products p ON p.id = mt.product_id
    LEFT JOIN public.product_category pc ON pc.id = p.category
    JOIN public.tax_rates tr
      ON tr.company_id = p_company_id
      AND tr.tax_class_id = COALESCE(p.tax_class_id, pc.tax_class_id)
      AND tr.country_code = COALESCE(vm.country_code, c.country_code, 'DE')
      AND tr.valid_from <= s2.created_at::date
      AND (tr.valid_to IS NULL OR tr.valid_to >= s2.created_at::date)
    WHERE s2.tax_rate_snapshot IS NULL
      AND s2.item_price IS NOT NULL
      AND vm.company = p_company_id
      AND COALESCE(p.tax_class_id, pc.tax_class_id) IS NOT NULL
    ORDER BY s2.id, tr.valid_from DESC
  ) sub
  WHERE s.id = sub.sale_id;

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated;
END
$$;
