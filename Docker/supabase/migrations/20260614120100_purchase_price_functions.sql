-- Purchase-price functions. All SECURITY DEFINER, fully-qualified names,
-- search_path=public (none use pgcrypto). Reuse the sales-trigger tax logic,
-- adapted product-centrically (company/country from products.company +
-- companies.country_code, NOT vendingMachine).

-- resolve_product_tax_rate ----------------------------------------------------
CREATE OR REPLACE FUNCTION public.resolve_product_tax_rate(
  p_product_id uuid, p_on date DEFAULT CURRENT_DATE
) RETURNS numeric
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_company uuid; v_country char(2); v_class uuid; v_rate numeric(6,4);
BEGIN
  SELECT p.company, COALESCE(p.tax_class_id, pc.tax_class_id)
    INTO v_company, v_class
  FROM public.products p
  LEFT JOIN public.product_category pc ON pc.id = p.category
  WHERE p.id = p_product_id;

  IF v_company IS NULL OR v_class IS NULL THEN RETURN NULL; END IF;

  SELECT COALESCE(c.country_code, 'DE') INTO v_country
  FROM public.companies c WHERE c.id = v_company;

  SELECT tr.rate INTO v_rate
  FROM public.tax_rates tr
  WHERE tr.company_id = v_company AND tr.tax_class_id = v_class
    AND tr.country_code = v_country
    AND tr.valid_from <= p_on
    AND (tr.valid_to IS NULL OR tr.valid_to >= p_on)
  ORDER BY tr.valid_from DESC LIMIT 1;

  RETURN v_rate;
END $$;

-- add_purchase_price ----------------------------------------------------------
CREATE OR REPLACE FUNCTION public.add_purchase_price(
  p_product_id uuid, p_supplier_name text, p_price numeric, p_basis text,
  p_observed_on date DEFAULT CURRENT_DATE, p_note text DEFAULT NULL,
  p_tax_rate_override numeric DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_company uuid := public.my_company_id();
  v_name text := btrim(coalesce(p_supplier_name, ''));
  v_supplier uuid; v_rate numeric(6,4); v_net numeric(10,4); v_gross numeric(10,4); v_id uuid;
BEGIN
  IF v_company IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF p_basis NOT IN ('net','gross') THEN RAISE EXCEPTION 'invalid basis: %', p_basis; END IF;
  IF v_name = '' THEN RAISE EXCEPTION 'supplier name required'; END IF;
  PERFORM 1 FROM public.products WHERE id = p_product_id AND company = v_company;
  IF NOT FOUND THEN RAISE EXCEPTION 'product not found or access denied'; END IF;

  SELECT id INTO v_supplier FROM public.suppliers
  WHERE company_id = v_company AND lower(btrim(name)) = lower(v_name);
  IF v_supplier IS NULL THEN
    INSERT INTO public.suppliers (company_id, name) VALUES (v_company, v_name)
    RETURNING id INTO v_supplier;
  END IF;

  v_rate := COALESCE(p_tax_rate_override, public.resolve_product_tax_rate(p_product_id, p_observed_on));
  IF v_rate IS NULL THEN RAISE EXCEPTION 'tax_rate_required'; END IF;

  IF p_basis = 'net' THEN
    v_net := round(p_price::numeric, 4);
    v_gross := round(p_price::numeric * (1 + v_rate), 4);
  ELSE
    v_gross := round(p_price::numeric, 4);
    v_net := round(p_price::numeric / (1 + v_rate), 4);
  END IF;

  INSERT INTO public.product_purchase_prices
    (company_id, product_id, supplier_id, price_net, price_gross, price_basis, tax_rate, observed_on, note)
  VALUES (v_company, p_product_id, v_supplier, v_net, v_gross, p_basis, v_rate, p_observed_on, p_note)
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'id', v_id, 'product_id', p_product_id, 'supplier_id', v_supplier, 'supplier_name', v_name,
    'price_net', v_net, 'price_gross', v_gross, 'price_basis', p_basis, 'tax_rate', v_rate,
    'observed_on', p_observed_on, 'note', p_note
  );
END $$;

-- update_purchase_price -------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_purchase_price(
  p_id uuid, p_supplier_name text, p_price numeric, p_basis text,
  p_observed_on date, p_note text DEFAULT NULL, p_tax_rate_override numeric DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_company uuid := public.my_company_id();
  v_name text := btrim(coalesce(p_supplier_name, ''));
  v_product uuid; v_supplier uuid; v_rate numeric(6,4); v_net numeric(10,4); v_gross numeric(10,4);
BEGIN
  IF v_company IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF p_basis NOT IN ('net','gross') THEN RAISE EXCEPTION 'invalid basis: %', p_basis; END IF;
  IF v_name = '' THEN RAISE EXCEPTION 'supplier name required'; END IF;

  SELECT product_id INTO v_product FROM public.product_purchase_prices
  WHERE id = p_id AND company_id = v_company;
  IF v_product IS NULL THEN RAISE EXCEPTION 'purchase price not found or access denied'; END IF;

  SELECT id INTO v_supplier FROM public.suppliers
  WHERE company_id = v_company AND lower(btrim(name)) = lower(v_name);
  IF v_supplier IS NULL THEN
    INSERT INTO public.suppliers (company_id, name) VALUES (v_company, v_name)
    RETURNING id INTO v_supplier;
  END IF;

  v_rate := COALESCE(p_tax_rate_override, public.resolve_product_tax_rate(v_product, p_observed_on));
  IF v_rate IS NULL THEN RAISE EXCEPTION 'tax_rate_required'; END IF;

  IF p_basis = 'net' THEN
    v_net := round(p_price::numeric, 4); v_gross := round(p_price::numeric * (1 + v_rate), 4);
  ELSE
    v_gross := round(p_price::numeric, 4); v_net := round(p_price::numeric / (1 + v_rate), 4);
  END IF;

  UPDATE public.product_purchase_prices
  SET supplier_id = v_supplier, price_net = v_net, price_gross = v_gross,
      price_basis = p_basis, tax_rate = v_rate, observed_on = p_observed_on, note = p_note
  WHERE id = p_id AND company_id = v_company;

  RETURN jsonb_build_object(
    'id', p_id, 'product_id', v_product, 'supplier_id', v_supplier, 'supplier_name', v_name,
    'price_net', v_net, 'price_gross', v_gross, 'price_basis', p_basis, 'tax_rate', v_rate,
    'observed_on', p_observed_on, 'note', p_note
  );
END $$;

-- get_product_purchase_summary ------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_product_purchase_summary(p_product_ids uuid[])
RETURNS TABLE (
  product_id uuid, ek_count int,
  newest_net numeric, newest_gross numeric, newest_supplier text, newest_on date,
  min_gross numeric, min_supplier text, min_on date,
  max_gross numeric, effective_tax_rate numeric
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH mine AS (
    SELECT p.id FROM public.products p
    WHERE p.id = ANY(p_product_ids) AND p.company = public.my_company_id()
  ),
  ranked AS (
    SELECT pp.product_id, pp.price_net, pp.price_gross, pp.observed_on, s.name AS supplier_name,
           row_number() OVER (PARTITION BY pp.product_id ORDER BY pp.observed_on DESC, pp.created_at DESC) AS rn_new,
           row_number() OVER (PARTITION BY pp.product_id ORDER BY pp.price_gross ASC, pp.observed_on DESC) AS rn_min
    FROM public.product_purchase_prices pp
    JOIN mine m ON m.id = pp.product_id
    JOIN public.suppliers s ON s.id = pp.supplier_id
  )
  SELECT
    m.id,
    (SELECT count(*) FROM ranked r WHERE r.product_id = m.id)::int,
    (SELECT r.price_net    FROM ranked r WHERE r.product_id = m.id AND r.rn_new = 1),
    (SELECT r.price_gross  FROM ranked r WHERE r.product_id = m.id AND r.rn_new = 1),
    (SELECT r.supplier_name FROM ranked r WHERE r.product_id = m.id AND r.rn_new = 1),
    (SELECT r.observed_on  FROM ranked r WHERE r.product_id = m.id AND r.rn_new = 1),
    (SELECT r.price_gross  FROM ranked r WHERE r.product_id = m.id AND r.rn_min = 1),
    (SELECT r.supplier_name FROM ranked r WHERE r.product_id = m.id AND r.rn_min = 1),
    (SELECT r.observed_on  FROM ranked r WHERE r.product_id = m.id AND r.rn_min = 1),
    (SELECT max(r.price_gross) FROM ranked r WHERE r.product_id = m.id),
    public.resolve_product_tax_rate(m.id)
  FROM mine m;
$$;

GRANT EXECUTE ON FUNCTION public.resolve_product_tax_rate(uuid, date)             TO authenticated;
GRANT EXECUTE ON FUNCTION public.add_purchase_price(uuid, text, numeric, text, date, text, numeric)    TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_purchase_price(uuid, text, numeric, text, date, text, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_product_purchase_summary(uuid[])             TO authenticated;
