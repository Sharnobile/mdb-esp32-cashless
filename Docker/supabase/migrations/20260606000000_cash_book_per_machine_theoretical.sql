-- =========================================================
-- Cash Book: per-machine theoretical-cash anchoring
--
-- Problem
-- -------
-- get_theoretical_cash (20260407000000_cash_book.sql) summed every
-- assigned machine's cash sales since the *Barkasse's* last entry —
-- a single timestamp shared by all machines. That is correct only
-- when the operator always empties every machine at once.
--
-- A refill tour that visits a SUBSET of a Barkasse's machines breaks
-- that assumption. After collecting machine A (which writes a
-- withdrawal entry), a later tour that collects machine B would
-- compute B's expected cash since A's withdrawal — under-counting all
-- the cash B accumulated *before* A was collected.
--
-- Fix
-- ---
-- When a Barkasse has `track_per_machine = true`, anchor each machine
-- at the most recent event that actually emptied THAT machine:
--   * the 'initial' entry (always present — the floor), or
--   * a non-reversed 'withdrawal' that collected it: either
--     machine-specific (machine_id = the machine) or a whole-Barkasse
--     withdrawal (machine_id IS NULL, which empties every machine).
-- Bank deposits ('payout'), corrections and reversals are excluded on
-- purpose: they move the box balance but do not collect machine cash.
--
-- When `track_per_machine = false` (the default) the behaviour is
-- byte-for-byte unchanged: every machine keeps sharing the Barkasse's
-- last-entry timestamp. Since `machine_id` is always NULL on entries
-- of non-tracking Barkassen, no existing installation changes until a
-- Barkasse explicitly opts into per-machine tracking.
--
-- The JSON result shape is identical (same keys), so no firmware,
-- iOS, or web change is required — the figures simply become correct
-- for partial tours.
--
-- Balance consistency: theoretical_balance = last_balance + Σ(per-
-- machine cash since its anchor) still holds, because every withdrawal
-- credits its counted amount to the running balance AND advances that
-- machine's anchor, so collected cash is never double-counted.
--
-- Immutable-migration rule: the original function file is left
-- untouched; this CREATE OR REPLACE supersedes it on every existing
-- and fresh install via ordered apply.
-- =========================================================

CREATE OR REPLACE FUNCTION public.get_theoretical_cash(
  p_cash_book_id uuid,
  p_company_id   uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_company     uuid;
  v_last_balance     float8;
  v_last_entry_at    timestamptz;
  v_entry_count      integer;
  v_cash_sales       float8 := 0;
  v_machines         jsonb := '[]'::jsonb;
  v_machine          record;
  v_machine_sales    float8;
  v_track_per_machine boolean;
  v_anchor           timestamptz;
BEGIN
  -- Verify caller belongs to the company
  SELECT om.company_id INTO v_user_company
    FROM public.organization_members om
   WHERE om.user_id = auth.uid()
     AND om.company_id = p_company_id
   LIMIT 1;

  IF v_user_company IS NULL THEN
    RETURN NULL;
  END IF;

  -- Verify cash book belongs to company + read its per-machine toggle
  SELECT track_per_machine INTO v_track_per_machine
    FROM public.cash_books
   WHERE id = p_cash_book_id AND company_id = p_company_id;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  -- Get latest entry (Barkasse-wide — drives the box balance + output fields)
  SELECT balance_after, created_at
    INTO v_last_balance, v_last_entry_at
    FROM public.cash_book_entries
   WHERE cash_book_id = p_cash_book_id
   ORDER BY entry_number DESC
   LIMIT 1;

  IF v_last_balance IS NULL THEN
    RETURN NULL;
  END IF;

  -- Count total entries
  SELECT count(*) INTO v_entry_count
    FROM public.cash_book_entries
   WHERE cash_book_id = p_cash_book_id;

  -- Sum cash sales per assigned machine since that machine's anchor
  FOR v_machine IN
    SELECT vm.id AS machine_id, vm.name AS machine_name
      FROM public."vendingMachine" vm
     WHERE vm.cash_book_id = p_cash_book_id
  LOOP
    IF v_track_per_machine THEN
      -- Most recent event that actually emptied THIS machine.
      SELECT MAX(e.created_at)
        INTO v_anchor
        FROM public.cash_book_entries e
       WHERE e.cash_book_id = p_cash_book_id
         AND (
              e.type = 'initial'
           OR (e.type = 'withdrawal'
               AND e.is_reversed = false
               AND (e.machine_id IS NULL OR e.machine_id = v_machine.machine_id))
         );
      -- Defensive: an 'initial' entry always exists, but never trust NULL.
      v_anchor := COALESCE(v_anchor, v_last_entry_at);
    ELSE
      -- Unchanged pre-2026-06-06 behaviour: Barkasse-wide last entry.
      v_anchor := v_last_entry_at;
    END IF;

    SELECT COALESCE(SUM(s.item_price), 0)
      INTO v_machine_sales
      FROM public.sales s
     WHERE s.machine_id = v_machine.machine_id
       AND s.channel = 'cash'
       AND s.created_at > v_anchor;

    v_cash_sales := v_cash_sales + v_machine_sales;

    v_machines := v_machines || jsonb_build_object(
      'machine_id', v_machine.machine_id,
      'machine_name', v_machine.machine_name,
      'cash_sales', v_machine_sales
    );
  END LOOP;

  RETURN jsonb_build_object(
    'theoretical_balance', v_last_balance + v_cash_sales,
    'last_entry_balance', v_last_balance,
    'cash_sales_since', v_cash_sales,
    'last_entry_at', v_last_entry_at,
    'entry_count', v_entry_count,
    'machines', v_machines
  );
END;
$$;
