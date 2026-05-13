-- Fix `refill_machine_trays`: "column reference 'tray_id' is ambiguous".
--
-- The function declares `RETURNS TABLE (tray_id uuid, old_stock int,
-- new_stock int, fill_amount int, was_already_applied bool)`, which
-- creates PL/pgSQL OUT parameters with those exact names. Inside the
-- function body, the INSERT into `refill_tour_tray_applications` uses
-- `RETURNING tray_id, fill_amount, old_stock, new_stock` — each of
-- those bare names matches both the OUT parameter and the target
-- table's column, so PL/pgSQL refuses to guess and raises:
--
--   ERROR: column reference "tray_id" is ambiguous
--
-- Field impact: every refill attempt in the wizard fails after 3
-- retries with the "Refill could not be saved" toast.
--
-- Fix: add `#variable_conflict use_column` so unqualified names inside
-- embedded SQL resolve to table columns, not OUT parameters. The IN/
-- DECLARE variables (`p_*`, `v_*`) are uniquely prefixed and always
-- referenced by their prefixed names, so this directive only changes
-- the behaviour of the colliding OUT-parameter names — which is what
-- we want.

CREATE OR REPLACE FUNCTION public.refill_machine_trays(
  p_machine_id uuid,
  p_tour_id    text,
  p_trays      jsonb  -- [{"tray_id": "<uuid>", "fill_amount": <int>}, ...]
)
RETURNS TABLE (
  tray_id              uuid,
  old_stock            integer,
  new_stock            integer,
  fill_amount          integer,
  was_already_applied  boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
#variable_conflict use_column
DECLARE
  v_user_id    uuid := auth.uid();
  v_company_id uuid;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501';
  END IF;

  IF p_tour_id IS NULL OR length(trim(p_tour_id)) = 0 THEN
    RAISE EXCEPTION 'tour_id required' USING ERRCODE = '22023';
  END IF;

  IF p_trays IS NULL OR jsonb_typeof(p_trays) <> 'array' THEN
    RAISE EXCEPTION 'trays must be a JSON array' USING ERRCODE = '22023';
  END IF;

  -- Authorize: caller must be an admin of the machine's company.
  -- Matches the existing machine_trays UPDATE RLS policy.
  SELECT vm.company INTO v_company_id
    FROM public."vendingMachine" vm
   WHERE vm.id = p_machine_id;

  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'machine not found' USING ERRCODE = '42704';
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM public.organization_members om
     WHERE om.company_id = v_company_id
       AND om.user_id    = v_user_id
       AND om.role       = 'admin'
  ) THEN
    RAISE EXCEPTION 'not authorized for this machine' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH
  inputs AS (
    SELECT
      (elem->>'tray_id')::uuid    AS tray_id,
      (elem->>'fill_amount')::int AS fill_amount
    FROM jsonb_array_elements(p_trays) AS elem
    WHERE (elem->>'fill_amount')::int > 0
  ),
  locked AS (
    SELECT mt.id, mt.capacity, mt.current_stock, i.fill_amount
      FROM public.machine_trays mt
      JOIN inputs i ON i.tray_id = mt.id
     WHERE mt.machine_id = p_machine_id
     ORDER BY mt.id
       FOR UPDATE OF mt
  ),
  new_app AS (
    INSERT INTO public.refill_tour_tray_applications AS rtta (
      tour_id, tray_id, fill_amount, old_stock, new_stock,
      applied_by, company_id
    )
    SELECT
      p_tour_id,
      l.id,
      l.fill_amount,
      l.current_stock,
      LEAST(l.capacity, l.current_stock + l.fill_amount),
      v_user_id,
      v_company_id
    FROM locked l
    ON CONFLICT (tour_id, tray_id) DO NOTHING
    RETURNING rtta.tray_id, rtta.fill_amount, rtta.old_stock, rtta.new_stock
  ),
  applied AS (
    UPDATE public.machine_trays mt
       SET current_stock = n.new_stock
      FROM new_app n
     WHERE mt.id = n.tray_id
     RETURNING mt.id
  ),
  prior AS (
    SELECT a.tray_id, a.fill_amount, a.old_stock, a.new_stock
      FROM public.refill_tour_tray_applications a
     WHERE a.tour_id = p_tour_id
       AND a.tray_id IN (SELECT i.tray_id FROM inputs i)
       AND a.tray_id NOT IN (SELECT n.tray_id FROM new_app n)
  ),
  applied_count AS (
    SELECT count(*) AS n FROM applied
  )
  SELECT n.tray_id, n.old_stock, n.new_stock, n.fill_amount, false AS was_already_applied
    FROM new_app n
    CROSS JOIN applied_count
  UNION ALL
  SELECT p.tray_id, p.old_stock, p.new_stock, p.fill_amount, true  AS was_already_applied
    FROM prior p;
END;
$$;

GRANT EXECUTE ON FUNCTION public.refill_machine_trays(uuid, text, jsonb) TO authenticated;
