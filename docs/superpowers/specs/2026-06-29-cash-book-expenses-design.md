# Kassenbuch: Barausgaben mit Kategorien

**Datum:** 2026-06-29
**Status:** Design approved (user), pending spec review

## Problem

Das Kassenbuch (`cash_book_entries`) kennt heute fünf Buchungsarten:
`initial`, `withdrawal` (Geld aus Automat in die Kasse, positiv), `payout`
(Bankeinzahlung, negativ), `correction` (signiert), `reversal` (Storno).

Geld verlässt die Barkasse damit ausschließlich als **Bankeinzahlung**. Für
eine zweckgebundene Barentnahme – z.B. Miete in bar bezahlt – gibt es keine
eigene Buchungsart und keine Kategorie. Behelfslösungen (`payout` mit Freitext
oder `correction`) verfälschen die KPI „letzte Bankeinzahlung" und sind
GoBD-technisch unsauber (eine Barausgabe ist kein Bankgang).

## Ziel

Generelle **Barausgaben** mit fester Kategorienliste + Pflicht-Belegverweis,
GoBD-konform, auf PWA und nativer iOS-App. Rückwärtskompatibel zu Altdaten und
zu im Feld laufenden App-Versionen.

## Entscheidungen (mit dem Nutzer abgestimmt)

1. **Umfang:** generelle Barausgaben mit Kategorien (nicht nur „Miete").
2. **Kategorien:** feste Liste im Code + Freitext-Pflicht bei „Sonstiges".
   Liste: **Miete (`rent`) · Wareneinkauf (`goods`) · Reinigung (`cleaning`) ·
   Gebühren (`fees`) · Sonstiges (`other`)**.
3. **Beleg:** Pflicht-Belegfeld (Text, z.B. Quittungs-/Rechnungsnummer). Kein
   Datei-Upload.
4. **Plattformen:** PWA + iOS.

## Datenmodell

Neue Migration `YYYYMMDDHHMMSS_cash_book_expense.sql` (bestehende Migrationen
sind immutable und werden NIE editiert). Alle Operationen idempotent.

### Änderungen an `cash_book_entries`

- **Neue Buchungsart `type = 'expense'`** (Geld raus für betrieblichen Zweck).
  Der bestehende CHECK heißt `valid_type` (Zeile 76 in
  `20260407000000_cash_book.sql`):

  ```sql
  ALTER TABLE public.cash_book_entries DROP CONSTRAINT IF EXISTS valid_type;
  ALTER TABLE public.cash_book_entries ADD CONSTRAINT valid_type
    CHECK (type IN ('initial','withdrawal','correction','payout','expense','reversal'));
  ```

- **`amount` negativ** (Geld raus, wie `payout`). Der `before_insert`-Trigger
  rechnet `balance_after = prev_balance + amount` → Bestand sinkt automatisch.
  **Kein Trigger-Eingriff nötig.** Insert setzt `amount = -abs(eingabe)`.

- **Neue Spalten** (beide `text`, nullable → Altzeilen unberührt):
  ```sql
  ALTER TABLE public.cash_book_entries ADD COLUMN IF NOT EXISTS category text;
  ALTER TABLE public.cash_book_entries ADD COLUMN IF NOT EXISTS receipt_reference text;
  ```
  - `category` – einer der Kategorie-Codes (`rent`/`goods`/`cleaning`/`fees`/`other`)
  - `receipt_reference` – Belegnummer (Pflicht bei Ausgabe)

- **GoBD-Integrität per DB-CHECK** (erzwingt Kategorie + Beleg bei Ausgaben
  auch über API/MCP-Pfade, nicht nur im UI; für alle Nicht-Ausgaben no-op, da
  Altzeilen `type <> 'expense'`):
  ```sql
  ALTER TABLE public.cash_book_entries DROP CONSTRAINT IF EXISTS expense_requires_category_receipt;
  ALTER TABLE public.cash_book_entries ADD CONSTRAINT expense_requires_category_receipt
    CHECK (type <> 'expense'
           OR (category IS NOT NULL AND receipt_reference IS NOT NULL));
  ```

### Hash-Kette: bewusst unverändert

Die Trigger-Formel (Zeile 185) hasht
`entry_number ‖ type ‖ amount ‖ balance_after ‖ prev_hash`. `type` und `amount`
bleiben damit manipulationssicher. `category`/`receipt_reference` werden NICHT
in den Hash aufgenommen, weil:

- die clientseitige `verifyIntegrity()` dieselbe Formel rechnet; eine Änderung
  würde die Verifikation für **alle bestehenden** Buchungen brechen;
- Kategorie/Beleg ohnehin durch die fehlende UPDATE/DELETE-RLS-Policy
  (Unveränderbarkeit) geschützt sind – reguläre Nutzer können sie nach dem
  Insert nicht ändern.

### Kein neues RPC

Buchung läuft wie heute über direkten INSERT (RLS-INSERT-Policy + Trigger). Der
DB-CHECK übernimmt die GoBD-Erzwingung. `get_theoretical_cash` braucht keine
Änderung: Ausgaben sind reguläre Einträge, die das `last_entry_balance`
absenken; die Theoretik aus Bar-Verkäufen bleibt korrekt.

## PWA-Frontend

- `app/composables/useCashBook.ts`:
  - `createExpense({ cashBookId, amount, category, receiptReference, description })`
    (Insert mit `type='expense'`, `amount = -abs(...)`).
  - `totalExpenses`-Computed (Summe `|amount|` über `type='expense'`).
  - Kategorie-Konstanten + i18n-Label-Mapping.
- Neue Komponente `app/components/cash-book/ExpenseModal.vue`: Betrag,
  Kategorie-Dropdown, **Belegnr. (Pflicht)**, Beschreibung (Pflicht bei `other`).
  Kein Automaten-Selektor (Ausgaben sind nicht automatenbezogen).
- Button „Barausgabe" in `app/components/cash-book/SecondaryToolbar.vue`.
- `app/components/cash-book/EntriesTable.vue`: Ausgabe-Label + Kategorie-Badge +
  Belegnr.; PDF-Export ergänzt Kategorie/Beleg in den Ausgabe-Zeilen.
- i18n: en/de Strings für Buchungsart, Kategorien, Modal.

## iOS (VMflow)

- `ios/VMflow/Models/CashBook.swift`:
  - `.expense` zu `CashBookEntryType`.
  - **`.unknown`-Fallback** via custom `init(from:)`, damit künftige neue Typen
    alte App-Versionen nie wieder beim Decoden der gesamten Buchungsliste
    werfen.
  - Felder `category`, `receiptReference` auf `CashBookEntry`.
- `ios/VMflow/ViewModels/CashBookViewModel.swift`: `recordExpense()`.
- Neues `ios/VMflow/Views/CashBook/ExpenseSheet.swift` (+ pbxproj-Registrierung
  an 4 Stellen: PBXBuildFile, PBXFileReference, group children, Sources phase).
- Button in `CashBookView.swift`, Anzeige in `EntriesListSection.swift`,
  deutsche Einträge in `Localizable.xcstrings`.
- Build-Check:
  `cd ios && xcodebuild -project VMflow.xcodeproj -scheme VMflow -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`.

## Rückwärtskompatibilität

- **Alte iOS-Versionen im Feld:** deren `CashBookEntryType` kennt `expense`
  nicht → eine gebuchte Ausgabe würde das Decoden der **gesamten** Buchungsliste
  werfen. Absicherung = `.unknown`-Fallback (s.o.). Empfehlung: den iOS-Build
  mit Fallback **zuerst** ausrollen, bevor produktiv die erste Ausgabe gebucht
  wird.
- **PWA** unkritisch (TS prüft Typen nicht zur Laufzeit; unbekannter Typ rendert
  generisch).
- **Altdaten** unberührt (neue Spalten nullable). `payout` / „letzte
  Bankeinzahlung" bleibt semantisch getrennt von `expense`.

## Nicht im Umfang (YAGNI)

- Datei-/Bild-Upload für Belege (nur Referenznummer).
- Benutzerdefinierte Kategorien je Firma (feste Liste reicht; eigene Tabelle
  wäre spätere Erweiterung).
- Automatenbezug für Ausgaben.
- Aufnahme von Kategorie/Beleg in die Hash-Kette.

## Testaspekte

- SQL: CHECK lässt `expense` mit Kategorie+Beleg zu, lehnt `expense` ohne
  beides ab; `balance_after` sinkt korrekt; Storno (`reversal`) einer Ausgabe
  funktioniert wie bei anderen Typen.
- PWA: `useCashBook` Vitest für `createExpense` (Vorzeichen, Pflichtfelder) und
  `totalExpenses`.
- iOS: `CashBookEntryType` decodet unbekannten Rohwert zu `.unknown` statt zu
  werfen (throwaway `swift`-Snippet, kein Test-Target im Projekt).
