-- Fix: the auto-generated "initial balance" cash-book entry hardcoded the
-- German literal 'Anfangsbestand' as its description, which showed up
-- untranslated on every non-German client (the iOS app's type badge already
-- shows a properly localized "Initial balance" label — the description
-- column duplicated it in German only). Make new/backfilled rows carry no
-- description at all; clients derive the label from entry type instead.

-- 1. Stop writing the hardcoded literal going forward.
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
    NULL,
    NEW.created_by
  );

  RETURN NEW;
END;
$$;

-- 2. Backfill only the exact auto-generated default — never touches a row
--    where someone has since edited the description to something else.
UPDATE public.cash_book_entries
SET description = NULL
WHERE type = 'initial'
  AND description = 'Anfangsbestand';
