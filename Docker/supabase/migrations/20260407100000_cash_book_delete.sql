-- =========================================================
-- Allow deletion of cash books (with all entries)
--
-- Adds DELETE policies on cash_books and cash_book_entries.
-- cash_book_entries FK is ON DELETE RESTRICT, so entries
-- must be deleted first (handled by RPC function).
-- =========================================================

-- Allow authenticated users to delete their own company's entries
CREATE POLICY "cash_book_entries_delete" ON public.cash_book_entries
  FOR DELETE TO authenticated
  USING (company_id = public.my_company_id());

-- Allow authenticated users to delete their own company's cash books
CREATE POLICY "cash_books_delete" ON public.cash_books
  FOR DELETE TO authenticated
  USING (company_id = public.my_company_id());

-- Grant DELETE permissions
GRANT DELETE ON public.cash_book_entries TO authenticated;
GRANT DELETE ON public.cash_books TO authenticated;

-- RPC: delete_cash_book — deletes all entries first, then the cash book
CREATE OR REPLACE FUNCTION public.delete_cash_book(p_cash_book_id uuid, p_company_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_company uuid;
BEGIN
  -- Verify caller belongs to the company
  SELECT om.company_id INTO v_user_company
    FROM public.organization_members om
   WHERE om.user_id = auth.uid()
     AND om.company_id = p_company_id
   LIMIT 1;

  IF v_user_company IS NULL THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  -- Verify cash book belongs to company
  PERFORM id FROM public.cash_books
   WHERE id = p_cash_book_id AND company_id = p_company_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Cash book not found';
  END IF;

  -- Unassign all machines from this cash book
  UPDATE public."vendingMachine"
     SET cash_book_id = NULL
   WHERE cash_book_id = p_cash_book_id;

  -- Delete all entries first (FK is RESTRICT)
  DELETE FROM public.cash_book_entries
   WHERE cash_book_id = p_cash_book_id;

  -- Delete the cash book
  DELETE FROM public.cash_books
   WHERE id = p_cash_book_id;

  RETURN true;
END;
$$;
