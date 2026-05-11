-- Atomic, idempotent refill RPC.
--
-- Background: the iOS and web refill wizards used to issue one UPDATE per
-- tray in a loop. A failure on any single UPDATE (WiFi→LTE handover, brief
-- packet loss, mid-tour timeout) silently left that tray at its old stock
-- while the others succeeded. The wizard then marked the machine as
-- refilled and advanced — so the only visible trace was that one tray
-- looked unchanged. Warehouse stock had already been FIFO-deducted at
-- packing time, so the "missing" items effectively vanished from the
-- ledger.
--
-- This migration adds:
--   1. refill_tour_tray_applications — small audit/dedupe table keyed by
--      (tour_id, tray_id). Lets retries be safe: the second call sees
--      the row already exists and is a no-op.
--   2. refill_machine_trays(p_machine_id, p_tour_id, p_trays) — runs all
--      tray updates for a machine in a single transaction with row-level
--      locking, ON CONFLICT-based dedupe, and a typed return for the
--      client to mirror.
--
-- The old direct UPDATE path still works (RLS unchanged), so older client
-- versions continue to function until they're updated.

-- ── Dedupe / audit table ────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.refill_tour_tray_applications (
  tour_id      text        NOT NULL,
  tray_id      uuid        NOT NULL REFERENCES public.machine_trays(id) ON DELETE CASCADE,
  fill_amount  integer     NOT NULL CHECK (fill_amount > 0),
  old_stock    integer     NOT NULL,
  new_stock    integer     NOT NULL,
  applied_at   timestamptz NOT NULL DEFAULT now(),
  applied_by   uuid        REFERENCES auth.users(id) ON DELETE SET NULL,
  company_id   uuid        NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  PRIMARY KEY (tour_id, tray_id)
);

CREATE INDEX IF NOT EXISTS refill_tour_tray_applications_company_applied_idx
  ON public.refill_tour_tray_applications (company_id, applied_at DESC);

ALTER TABLE public.refill_tour_tray_applications ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON public.refill_tour_tray_applications TO authenticated;
GRANT ALL    ON public.refill_tour_tray_applications TO service_role;

-- Read-only for users in the owning company. The RPC writes via
-- SECURITY DEFINER, so no INSERT/UPDATE/DELETE policies are needed —
-- direct writes from authenticated users are denied by default.
DROP POLICY IF EXISTS refill_tour_tray_applications_select ON public.refill_tour_tray_applications;
CREATE POLICY refill_tour_tray_applications_select
  ON public.refill_tour_tray_applications
  FOR SELECT
  TO authenticated
  USING (company_id = (SELECT public.my_company_id()));

-- ── RPC ─────────────────────────────────────────────────────────────────────
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

  -- Pipeline:
  --   inputs  – parse JSON into (tray_id, fill_amount) rows
  --   locked  – lock target trays FOR UPDATE in deterministic id order
  --   new_app – record fresh applications, RETURNING the values we need
  --             (CTEs share one snapshot; we must surface them via RETURNING,
  --             a snapshot SELECT from refill_tour_tray_applications would
  --             NOT see rows just inserted in the same statement)
  --   applied – update machine_trays only for newly recorded trays
  --   prior   – snapshot-visible (= previously applied in earlier retry)
  --             rows for the same inputs
  -- Final SELECT: union of newly-applied (new_app) and previously-applied
  -- (prior). Each tray appears in exactly one branch because new_app only
  -- emits trays where the INSERT actually fired (ON CONFLICT DO NOTHING).
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
    INSERT INTO public.refill_tour_tray_applications (
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
    RETURNING tray_id, fill_amount, old_stock, new_stock
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
    -- Force evaluation of the `applied` UPDATE CTE so PostgreSQL doesn't
    -- prune it. Top-level data-modifying CTEs always execute per the
    -- docs, but referencing it explicitly makes the dependency clear.
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
