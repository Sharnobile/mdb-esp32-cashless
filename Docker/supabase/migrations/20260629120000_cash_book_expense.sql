-- Barausgaben (cash expenses) für das Kassenbuch.
-- Neue Buchungsart 'expense': Geld verlässt die Barkasse für einen
-- betrieblichen Zweck (Miete, Wareneinkauf, ...). amount ist NEGATIV;
-- der bestehende before_insert-Trigger senkt balance_after automatisch.
-- Idempotent: kann auf bestehenden Installationen via update.sh laufen.

-- 1. 'expense' zur Buchungsart-Whitelist hinzufügen.
ALTER TABLE public.cash_book_entries DROP CONSTRAINT IF EXISTS valid_type;
ALTER TABLE public.cash_book_entries ADD CONSTRAINT valid_type
  CHECK (type IN ('initial','withdrawal','correction','payout','expense','reversal'));

-- 2. Kategorie + Belegverweis (nullable; Altzeilen bleiben unberührt).
ALTER TABLE public.cash_book_entries ADD COLUMN IF NOT EXISTS category text;
ALTER TABLE public.cash_book_entries ADD COLUMN IF NOT EXISTS receipt_reference text;

-- 3. GoBD: Ausgaben MÜSSEN Kategorie + Beleg haben (Defense-in-Depth gegen
--    rohe PostgREST-Inserts / künftige Schreib-Clients). No-op für alle
--    Nicht-Ausgaben, da Altzeilen type <> 'expense' sind.
ALTER TABLE public.cash_book_entries DROP CONSTRAINT IF EXISTS expense_requires_category_receipt;
ALTER TABLE public.cash_book_entries ADD CONSTRAINT expense_requires_category_receipt
  CHECK (type <> 'expense'
         OR (category IS NOT NULL AND receipt_reference IS NOT NULL));
