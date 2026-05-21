-- =========================================================
-- Fix: cash_book hash trigger fails with
--   42883: function digest(text, unknown) does not exist
--
-- pgcrypto in self-hosted Supabase lives in the `extensions`
-- schema, but before_insert_cash_book_entry was defined without
-- an explicit search_path. SECURITY DEFINER functions inherit
-- the caller's search_path unless one is set, and `extensions`
-- is typically not in the default path — so digest() fails to
-- resolve on cash_book INSERT (the after-insert trigger writes
-- the initial entry, which fires this before-insert trigger).
--
-- This migration re-declares the function with the body
-- unchanged but adds `SET search_path = public, extensions`.
-- =========================================================

CREATE OR REPLACE FUNCTION public.before_insert_cash_book_entry()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
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
