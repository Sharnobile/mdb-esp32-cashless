-- =========================================================
-- Cash Book (Kassenbuch / Barkasse) — GoBD-compliant
--
-- A company has 1-n Barkassen, each with 0-n vending machines.
-- Entries are immutable with a SHA256 hash chain.
--
-- Changes:
-- 1. New table: cash_books (Barkassen per company)
-- 2. New table: cash_book_entries (immutable, hash-chained)
-- 3. New column: vendingMachine.cash_book_id (machine → Barkasse)
-- 4. Trigger: auto entry_number, balance_after, hash
-- 5. Trigger: auto initial entry on cash_book creation
-- 6. RPC: get_theoretical_cash (aggregates across assigned machines)
-- =========================================================

-- Required for SHA256 hash chain
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- =========================================================
-- A. cash_books — Barkassen per company
-- =========================================================
CREATE TABLE IF NOT EXISTS public.cash_books (
  id              uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  created_at      timestamptz NOT NULL DEFAULT now(),
  company_id      uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  name            text NOT NULL,
  initial_balance float8 NOT NULL DEFAULT 0,
  activated_at    timestamptz NOT NULL DEFAULT now(),
  created_by      uuid NOT NULL REFERENCES auth.users(id),
  is_active       boolean NOT NULL DEFAULT true,
  UNIQUE (company_id, name)
);

ALTER TABLE public.cash_books ENABLE ROW LEVEL SECURITY;

CREATE POLICY "cash_books_select" ON public.cash_books
  FOR SELECT TO authenticated
  USING (company_id = public.my_company_id());

CREATE POLICY "cash_books_insert" ON public.cash_books
  FOR INSERT TO authenticated
  WITH CHECK (company_id = public.my_company_id());

CREATE POLICY "cash_books_update" ON public.cash_books
  FOR UPDATE TO authenticated
  USING (company_id = public.my_company_id())
  WITH CHECK (company_id = public.my_company_id());

-- No DELETE policy: GoBD — Barkassen cannot be deleted

GRANT SELECT, INSERT, UPDATE ON public.cash_books TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.cash_books TO service_role;


-- =========================================================
-- B. cash_book_entries — immutable, hash-chained entries
-- =========================================================
CREATE TABLE IF NOT EXISTS public.cash_book_entries (
  id                uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  created_at        timestamptz NOT NULL DEFAULT now(),
  cash_book_id      uuid NOT NULL REFERENCES public.cash_books(id) ON DELETE RESTRICT,
  company_id        uuid NOT NULL REFERENCES public.companies(id),
  entry_number      integer NOT NULL DEFAULT 0,
  type              text NOT NULL,
  amount            float8 NOT NULL,
  balance_after     float8 NOT NULL DEFAULT 0,
  description       text,
  machine_id        uuid REFERENCES public."vendingMachine"(id) ON DELETE SET NULL,
  counted_amount    float8,
  expected_amount   float8,
  corrects_entry_id uuid REFERENCES public.cash_book_entries(id),
  is_reversed       boolean NOT NULL DEFAULT false,
  created_by        uuid NOT NULL REFERENCES auth.users(id),
  hash              text NOT NULL DEFAULT '',
  UNIQUE (cash_book_id, entry_number),
  CONSTRAINT valid_type CHECK (type IN ('initial', 'withdrawal', 'correction', 'payout', 'reversal')),
  CONSTRAINT reversal_requires_reference CHECK (
    (type = 'reversal' AND corrects_entry_id IS NOT NULL)
    OR (type != 'reversal' AND corrects_entry_id IS NULL)
  )
);

ALTER TABLE public.cash_book_entries ENABLE ROW LEVEL SECURITY;

CREATE POLICY "cash_book_entries_select" ON public.cash_book_entries
  FOR SELECT TO authenticated
  USING (company_id = public.my_company_id());

CREATE POLICY "cash_book_entries_insert" ON public.cash_book_entries
  FOR INSERT TO authenticated
  WITH CHECK (company_id = public.my_company_id());

-- No UPDATE policy: GoBD — entries are immutable
-- No DELETE policy: GoBD — entries cannot be deleted

GRANT SELECT, INSERT ON public.cash_book_entries TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.cash_book_entries TO service_role;

-- Index for fast lookups
CREATE INDEX idx_cash_book_entries_book_id ON public.cash_book_entries(cash_book_id, entry_number);
CREATE INDEX idx_cash_book_entries_company ON public.cash_book_entries(company_id);


-- =========================================================
-- C. Add cash_book_id to vendingMachine
-- =========================================================
ALTER TABLE public."vendingMachine"
  ADD COLUMN cash_book_id uuid REFERENCES public.cash_books(id) ON DELETE SET NULL;

CREATE INDEX idx_vending_machine_cash_book ON public."vendingMachine"(cash_book_id);


-- =========================================================
-- D. Trigger: before_insert_cash_book_entry
--    Auto-populate entry_number, balance_after, hash.
--    Handle reversals (mark original as reversed).
-- =========================================================
CREATE OR REPLACE FUNCTION public.before_insert_cash_book_entry()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_prev_balance   float8;
  v_prev_hash      text;
  v_prev_number    integer;
  v_ref_amount     float8;
  v_ref_reversed   boolean;
  v_ref_book_id    uuid;
BEGIN
  -- Lock the cash_book row to prevent concurrent inserts
  PERFORM id FROM public.cash_books WHERE id = NEW.cash_book_id FOR UPDATE;

  -- Get previous entry data
  SELECT entry_number, balance_after, hash
    INTO v_prev_number, v_prev_balance, v_prev_hash
    FROM public.cash_book_entries
   WHERE cash_book_id = NEW.cash_book_id
   ORDER BY entry_number DESC
   LIMIT 1;

  -- Calculate entry_number
  IF v_prev_number IS NULL THEN
    NEW.entry_number := 1;
    v_prev_balance := 0;
    v_prev_hash := '';
  ELSE
    NEW.entry_number := v_prev_number + 1;
  END IF;

  -- Handle reversal: validate + auto-set amount
  IF NEW.type = 'reversal' AND NEW.corrects_entry_id IS NOT NULL THEN
    SELECT amount, is_reversed, cash_book_id
      INTO v_ref_amount, v_ref_reversed, v_ref_book_id
      FROM public.cash_book_entries
     WHERE id = NEW.corrects_entry_id;

    IF v_ref_book_id IS NULL THEN
      RAISE EXCEPTION 'Referenced entry not found: %', NEW.corrects_entry_id;
    END IF;

    IF v_ref_book_id != NEW.cash_book_id THEN
      RAISE EXCEPTION 'Referenced entry belongs to a different cash book';
    END IF;

    IF v_ref_reversed THEN
      RAISE EXCEPTION 'Entry already reversed — cannot reverse twice (Doppel-Storno)';
    END IF;

    -- Auto-negate the referenced entry's amount
    NEW.amount := -v_ref_amount;

    -- Mark the original entry as reversed (SECURITY DEFINER bypasses RLS)
    UPDATE public.cash_book_entries
       SET is_reversed = true
     WHERE id = NEW.corrects_entry_id;
  END IF;

  -- Calculate balance_after
  NEW.balance_after := v_prev_balance + NEW.amount;

  -- Calculate SHA256 hash chain
  NEW.hash := encode(
    digest(
      NEW.entry_number::text || NEW.type || NEW.amount::text || NEW.balance_after::text || v_prev_hash,
      'sha256'
    ),
    'hex'
  );

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_before_insert_cash_book_entry
  BEFORE INSERT ON public.cash_book_entries
  FOR EACH ROW
  EXECUTE FUNCTION public.before_insert_cash_book_entry();


-- =========================================================
-- E. Trigger: after_insert_cash_book
--    Auto-create initial entry when a Barkasse is created.
-- =========================================================
CREATE OR REPLACE FUNCTION public.after_insert_cash_book()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  INSERT INTO public.cash_book_entries (
    cash_book_id,
    company_id,
    type,
    amount,
    description,
    created_by
  ) VALUES (
    NEW.id,
    NEW.company_id,
    'initial',
    NEW.initial_balance,
    'Anfangsbestand',
    NEW.created_by
  );

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_after_insert_cash_book
  AFTER INSERT ON public.cash_books
  FOR EACH ROW
  EXECUTE FUNCTION public.after_insert_cash_book();


-- =========================================================
-- F. RPC: get_theoretical_cash
--    Returns theoretical cash balance for a Barkasse by
--    summing cash sales across all assigned machines since
--    the last entry.
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
  v_user_company uuid;
  v_last_balance float8;
  v_last_entry_at timestamptz;
  v_entry_count  integer;
  v_cash_sales   float8 := 0;
  v_machines     jsonb := '[]'::jsonb;
  v_machine      record;
  v_machine_sales float8;
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

  -- Verify cash book belongs to company
  PERFORM id FROM public.cash_books
   WHERE id = p_cash_book_id AND company_id = p_company_id;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  -- Get latest entry
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

  -- Sum cash sales per assigned machine since last entry
  FOR v_machine IN
    SELECT vm.id AS machine_id, vm.name AS machine_name
      FROM public."vendingMachine" vm
     WHERE vm.cash_book_id = p_cash_book_id
  LOOP
    SELECT COALESCE(SUM(s.item_price), 0)
      INTO v_machine_sales
      FROM public.sales s
     WHERE s.machine_id = v_machine.machine_id
       AND s.channel = 'cash'
       AND s.created_at > v_last_entry_at;

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
