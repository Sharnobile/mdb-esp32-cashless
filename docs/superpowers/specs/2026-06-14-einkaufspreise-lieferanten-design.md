# Einkaufspreise & Lieferanten — Design

**Datum:** 2026-06-14
**Status:** Design (Brainstorming abgeschlossen, bereit für Implementierungsplan)
**Betroffen:** Supabase-Migrationen + RPCs, `management-frontend` (PWA). Keine Firmware-, MQTT- oder iOS-Änderungen in v1.

---

## 1. Problem & Ziel

Der Betreiber möchte zu jedem Produkt den **üblichen Einkaufspreis (EK)** hinterlegen, um auf der **Deals-Seite** (Marktguru-Angebote) auf einen Blick zu sehen, ob ein Angebot gegenüber dem eigenen Großhändler-EK **wirklich einen Vorteil bringt** oder nicht.

Kernanforderungen aus dem Gespräch:

1. **Netto und Brutto** müssen beide abbildbar sein: Marktguru-Angebote sind **brutto**, Großhändler-Rechnungen **netto**.
2. **Mehrere Lieferantenpreise** pro Produkt, mit Historie — um zu sehen, ob ein anderer Händler schon mal günstiger war.
3. Vergleich der Angebote gegen den EK auf der Deals-Seite.

## 2. Ziele / Nicht-Ziele

**Ziele (v1 — „Kern + Marge“):**
- EK-Pflege pro Produkt: mehrere Lieferanten, Historie, netto **und** brutto.
- Firmenweite, wiederverwendbare **Lieferanten**-Liste, **inline** beim Tippen angelegt (Autocomplete).
- **Margenanzeige** am Produkt (Verkaufspreis vs. üblicher EK, auf Netto-Basis).
- **Angebots-Vergleich** auf der Deals-Seite (Karte + Detail) inkl. **Plausibilitäts-Filter** (Angebote über dem teuersten EK ausblenden).

**Nicht-Ziele (bewusst ausgeklammert, YAGNI):**
- Kein Erfassen des EK beim Wareneingang/Refill (späteres Folge-Feature).
- Keine Gebinde-/Packungslogik — es wird der **direkte Stückpreis** erfasst; Karton→Stück rechnet der Nutzer selbst.
- Keine eigene Lieferanten-Verwaltungsseite (Kontaktdaten, CRUD-Seite) in v1.
- Keine Normalisierung von Angebots-Packungsgrößen (z. B. „Multipack“) — Vergleich ist roh, Stück-EK gegen Angebotspreis.
- Keine Firmware-/MQTT-/iOS-Änderungen. Keine Realtime-Publication-Änderung (EK braucht kein Realtime).

## 3. Festgelegte Entscheidungen (aus dem Brainstorming)

| Thema | Entscheidung |
|-------|--------------|
| Netto/Brutto-Pflege | **Ein Wert wird getippt, der andere berechnet** über den Steuersatz des Produkts. Beide werden gespeichert. |
| Mengenbasis | **Direkter Stückpreis** (kein Gebinde-Feld). |
| Lieferanten | Firmenweite Liste, **inline per Autocomplete** angelegt (kein Freitext, keine separate Pflegeseite). |
| Scope | **Kern + Marge.** |
| „Üblicher EK“ | = **neuester** EK-Eintrag (über alle Lieferanten). |
| Marge | auf **Netto-Basis** (USt. ist Durchlaufposten): `VK_netto − EK_netto`. |
| Plausibilitäts-Filter | Angebot (brutto) **> teuerster** erfasster EK (brutto) → unplausibel/Fehl-Match → **ausblenden mit Zähler + Aufklappen**. |
| Ausgeblendete Deals | zählen **nicht** als „X neue Deals“ und lösen keine Benachrichtigung aus. |

## 4. Datenmodell

Zwei neue Tabellen, beide firmen-gescoped mit RLS analog zu `tax_classes`. Geldbeträge als `numeric(10,4)` (wie `sales.price_net`), Steuersatz als `numeric(6,4)` (wie `tax_rates.rate`).

> **Migrations-Immutabilität:** Alle Änderungen kommen in **neue** Migrationsdateien mit Zeitstempel ≥ `20260614…`. Bestehende Migrationen (insb. `20260406000000_tax_infrastructure.sql` und der Sales-Trigger) werden **nicht** editiert.

### 4.1 `suppliers` (NEU)

```sql
CREATE TABLE public.suppliers (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  name       text NOT NULL,
  CONSTRAINT suppliers_name_not_blank CHECK (length(btrim(name)) > 0)
);
-- case-insensitive eindeutig je Firma → verhindert "Metro" vs "metro"
CREATE UNIQUE INDEX suppliers_company_lower_name_uq
  ON public.suppliers (company_id, lower(btrim(name)));
```

RLS: SELECT/INSERT/UPDATE/DELETE für `authenticated` mit `company_id = public.my_company_id()` (Muster aus `tax_classes`). Kein Löschen-UI in v1; FK von Preisen ist `ON DELETE RESTRICT`.

### 4.2 `product_purchase_prices` (NEU)

```sql
CREATE TABLE public.product_purchase_prices (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at  timestamptz NOT NULL DEFAULT now(),
  company_id  uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  product_id  uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  supplier_id uuid NOT NULL REFERENCES public.suppliers(id) ON DELETE RESTRICT,
  price_net   numeric(10,4) NOT NULL,
  price_gross numeric(10,4) NOT NULL,
  price_basis text NOT NULL CHECK (price_basis IN ('net','gross')),  -- vom Nutzer getippte Quelle der Wahrheit
  tax_rate    numeric(6,4) NOT NULL,   -- Snapshot des verwendeten Satzes (z. B. 0.0700)
  observed_on date NOT NULL DEFAULT CURRENT_DATE,  -- Rechnungs-/Angebotsdatum
  note        text
);
CREATE INDEX product_purchase_prices_product_idx
  ON public.product_purchase_prices (product_id, observed_on DESC);
```

RLS: CRUD für `authenticated` mit `company_id = public.my_company_id()`.

- `price_basis` hält fest, welcher Wert getippt wurde (der andere ist berechnet) — wichtig für späteres Re-Berechnen beim Bearbeiten.
- Beide Geldwerte sind **immer** befüllt → Sortierung/Vergleich auf `price_gross` ist immer möglich, keine NULL-Lücken.

## 5. Steuersatz-Auflösung & Netto↔Brutto

Die Auflösung existiert heute nur **inline** im Sales-Trigger (`stamp_machine_and_decrement_stock`). Wir extrahieren sie in eine **wiederverwendbare** Funktion (der Trigger bleibt unangetastet — keine Migration editieren):

```sql
CREATE OR REPLACE FUNCTION public.resolve_product_tax_rate(
  p_product_id uuid,
  p_on date DEFAULT CURRENT_DATE
) RETURNS numeric          -- gibt rate (z. B. 0.0700) oder NULL zurück
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_company uuid; v_country char(2); v_class uuid; v_rate numeric(6,4);
BEGIN
  SELECT p.company, COALESCE(p.tax_class_id, pc.tax_class_id)
    INTO v_company, v_class
  FROM public.products p
  LEFT JOIN public.product_category pc ON pc.id = p.category
  WHERE p.id = p_product_id;

  SELECT COALESCE(c.country_code,'DE') INTO v_country
  FROM public.companies c WHERE c.id = v_company;

  IF v_class IS NULL OR v_company IS NULL THEN RETURN NULL; END IF;

  SELECT tr.rate INTO v_rate
  FROM public.tax_rates tr
  WHERE tr.company_id = v_company AND tr.tax_class_id = v_class
    AND tr.country_code = v_country
    AND tr.valid_from <= p_on
    AND (tr.valid_to IS NULL OR tr.valid_to >= p_on)
  ORDER BY tr.valid_from DESC LIMIT 1;

  RETURN v_rate;  -- NULL falls kein passender Satz
END $$;
```

> **Konvention:** Alle Tabellen werden im Funktionskörper **voll qualifiziert** (`public.*`), damit die `search_path`-Wahl nicht tragend ist. Da keine dieser Funktionen pgcrypto (`digest()`/`gen_random_bytes()` aus `extensions`) nutzt, genügt `SET search_path = public` — die Namensqualifizierung bleibt aber erhalten.

Umrechnung (in den RPCs):
- `price_basis='net'` → `price_gross = round(price_net * (1 + rate), 4)`
- `price_basis='gross'` → `price_net = round(price_gross / (1 + rate), 4)`

**Fallback ohne Steuersatz:** Liefert `resolve_product_tax_rate` NULL (Produkt hat keine Steuerklasse / kein gültiger `tax_rates`-Satz), verlangt der Erfassen-Dialog einmalig einen Prozentsatz (Vorbelegung = häufigster Steuersatz der Firma, sonst 19 %). Dieser Override wird an den RPC durchgereicht; ein Satz ist **Pflicht**, damit immer netto+brutto vorliegen.

## 6. Backend — RPCs

Alle RPCs: `SECURITY DEFINER`, `SET search_path = public`, prüfen Zugehörigkeit über `public.my_company_id()`. (Begründung für `search_path`: Konvention für SECURITY-DEFINER-Funktionen in diesem Self-hosted-Supabase.)

### 6.1 `add_purchase_price(...)`
Signatur: `(p_product_id uuid, p_supplier_name text, p_price numeric, p_basis text, p_observed_on date, p_note text, p_tax_rate_override numeric DEFAULT NULL) RETURNS product_purchase_prices`

Ablauf:
1. `v_company := my_company_id()`; prüfen, dass `p_product_id` zu `v_company` gehört (sonst Exception).
2. **Lieferant find-or-create:** `SELECT id FROM suppliers WHERE company_id=v_company AND lower(btrim(name))=lower(btrim(p_supplier_name))`; falls keiner → INSERT. (Leerer Name → Exception.)
3. `v_rate := COALESCE(p_tax_rate_override, resolve_product_tax_rate(p_product_id, p_observed_on))`; falls NULL → `RAISE EXCEPTION 'tax_rate_required'` (Frontend stellt sicher, dass bei fehlendem Satz ein Override mitkommt).
4. Netto/Brutto aus `p_basis` + `v_rate` berechnen.
5. Zeile einfügen (`company_id`, `product_id`, `supplier_id`, `price_net`, `price_gross`, `price_basis=p_basis`, `tax_rate=v_rate`, `observed_on`, `note`) und zurückgeben.

### 6.2 `update_purchase_price(...)`
Wie `add_…`, aber per `p_id`; prüft `company_id = my_company_id()`, löst Lieferant erneut auf, berechnet netto/brutto neu. (Löschen läuft direkt über RLS-`DELETE`, kein RPC nötig.)

### 6.3 `get_product_purchase_summary(p_product_ids uuid[])`
Liefert je Produkt eine Zeile für Listen-/Deals-Ansicht (Batch, kein PostgREST-Row-Limit-Problem):

```
product_id,
ek_count            int,
newest_net, newest_gross, newest_supplier, newest_on,   -- "üblicher EK"
min_gross, min_supplier, min_on,                          -- günstigster je
max_gross,                                                -- für Plausibilitäts-Filter
effective_tax_rate                                        -- resolve_product_tax_rate(id) für Margen-/deal_net-Berechnung
```

Filtert intern auf `company_id = my_company_id()`. Produkte ohne EK liefern `ek_count = 0` (übrige Felder NULL). **„Neuester“ deterministisch:** `observed_on` ist ein `date` ohne Uhrzeit → Sortierung `ORDER BY observed_on DESC, created_at DESC`, damit zwei Preise vom selben Tag stabil geordnet sind.

## 7. Frontend — Pflege & Marge

### 7.1 Pure Vergleichs-Helfer (`app/lib/purchaseComparison.ts`, NEU)
Reine, unit-getestete Funktionen (keine Nuxt-Abhängigkeit):

- `counterpart(value, basis, rate)` → berechneter Gegenwert (netto↔brutto).
- `marginNet(sellpriceGross, ekNet, rate)` → `{ rohertrag, spannePct }` (VK netto − EK netto).
- `classifyDeal(dealGross, summary, opts?)` → Verdikt für ein Produkt:
  - `summary.ek_count === 0` → `{ status: 'no_ek' }`
  - `dealGross > summary.max_gross` → `{ status: 'implausible' }`  *(Filter-Schwelle)*
  - `dealGross <= summary.min_gross` → `{ status: 'good_best', deltaPct }` („günstiger als je“)
  - `dealGross < newest_gross` (außerhalb Toleranz) → `{ status: 'good', deltaPct }`
  - innerhalb ±`tolerancePct` (Default **3 %**) um `newest_gross` → `{ status: 'similar', deltaPct }`
  - `dealGross > newest_gross` (≤ max_gross) → `{ status: 'worse', deltaPct }`
  - `deltaPct` relativ zu `newest_gross` (üblicher EK).

### 7.2 Composable `usePurchasePrices()` (NEU, `app/composables/`)
- `fetchSuppliers()` → firmenweite Liste (für Autocomplete).
- `fetchPurchasePrices(productId)` → Zeilen inkl. Lieferantenname, sortiert `observed_on DESC`.
- `addPurchasePrice(...)` / `updatePurchasePrice(...)` → rufen die RPCs.
- `deletePurchasePrice(id)` → direkter RLS-`delete`.
- `resolveTaxRate(productId)` → ruft `resolve_product_tax_rate` (für Live-Vorschau & Fallback-Erkennung im Formular).
- `summarize(rows)` → newest/min/max/count (für Marge & Formular, ohne Extra-RPC).

> Typen werden wie üblich manuell gecastet (es gibt keine generierten DB-Typen — sonst liefert der Supabase-Client `never`).

### 7.3 `ProductFormModal.vue` — Abschnitt „Einkauf & Lieferanten“
Eingefügt unterhalb von Preis/Kategorie. **Nur im Bearbeiten-Modus** sichtbar (braucht `product.id`); im Anlegen-Modus Hinweis „erst speichern, dann Einkaufspreise erfassen“ (bekannte v1-Einschränkung).

Inhalt (vgl. Mockup `product-form.html`):
- **Verlauf** der EK-Zeilen je Lieferant (netto + brutto), günstigster mit ★, neuester als „aktuell üblich“, je Zeile Bearbeiten/Löschen.
- **Erfassen-Block:** Lieferant-Autocomplete (Muster `ProductCombobox.vue`, neuer Name wird angelegt), ein Preisfeld + **netto/brutto-Umschalter** mit live berechnetem Gegenwert (`counterpart`), Datum (Default heute), optionale Notiz. Bei nicht auflösbarem Steuersatz: zusätzliches Pflicht-`%`-Feld (vorbelegt).
- **Marge** automatisch: `marginNet(sellprice, newest_net, rate)` → „Rohertrag X €/Stück · Spanne Y %“.

Schreibrechte folgen denselben Rollen-Regeln wie das übrige Produkt-Editieren (Plan prüft, ob admin-gated; UI + RPC entsprechend gaten).

### 7.4 `products/index.vue` — Spalte „üblicher EK / Spanne“ (Teil von „Marge“)
Optionale, sortierbare Spalte: lädt `get_product_purchase_summary` für alle gelisteten Produkte (ein Batch-Call), zeigt üblichen EK (brutto) und Spanne %. Produkte ohne EK: „—“.

## 8. Frontend — Deals-Integration

### 8.1 `useDeals.ts`
- Nach dem Laden der Deals: `product_id`s aller Matches sammeln → **ein** `get_product_purchase_summary(ids)`-Call → Map `productId → summary`.
- Pro gematchtem Produkt `classifyDeal(deal.deal_price, summary)` berechnen.
- **`dedupedDeals`/`activeDeals`:** je Karte `visibleProducts` (Status ≠ `implausible`) und `implausibleProducts` trennen. Eine Karte ist **suppressed**, wenn sie gematchte Produkte hat **und alle** `implausible` sind. Produkte ohne EK (`no_ek`) gelten **nicht** als implausibel → halten die Karte sichtbar.
- Neue computed: `suppressedDeals`, `suppressedCount`.
- **`newDealsCount` / `isNew()` / Benachrichtigungen:** suppressed Deals werden **ausgeschlossen** (keine „X neue Deals“, kein Push).

### 8.2 `deals/index.vue`
- **Karte:** neue Zeile mit Verdikt-Pill des **besten** sichtbaren Produkt-Matches (🟢 `good`/`good_best` · 🟡 `similar` · 🔴 `worse`), Text z. B. „17 % günstiger als dein EK (0,54 €)“. Kein EK an allen Produkten → keine Pill (oder ⚪-Hinweis).
- **Detail → „Passende Produkte“:** pro Produkt eine Vergleichszeile: `Angebot X € brutto vs üblicher EK Y € brutto (Lieferant)`, Verdikt-Ampel, Kontext „günstigster je …“. Im grünen Fall **Marge-Effekt** („Spanne stiege von A % auf B %“, nur wenn `sellprice` gesetzt; `deal_net = deal_gross/(1+rate)`). Bei `no_ek`: „⚪ Kein EK hinterlegt“ + **„+ EK erfassen“** (öffnet `ProductFormModal` des Produkts).
- **Ausgeblendet-Bereich:** dezente Zeile „▸ N Angebote ausgeblendet — teurer als dein höchster EK (evtl. Fehl-Match) · anzeigen“. Aufgeklappt: die suppressed Karten, markiert „🔴 weit über EK – vermutlich falsch gematcht“. Aktionen v1: bestehendes **Archivieren**; bei Keyword-Matches Link zum **Keyword-Editor**. (Vollständiges Match-Correction-Tooling ist Nicht-Ziel.)

## 9. i18n

Neue Keys in `management-frontend/i18n/locales/de.json` **und** `en.json` (beide Sprachen, Konvention des Projekts): EK-/Lieferanten-/Marge-Begriffe, Verdikt-Labels, Ausgeblendet-Hinweis. Keine hartcodierten Strings.

## 10. Fehlerbehandlung & Randfälle

- **Kein Steuersatz auflösbar:** Pflicht-`%`-Feld im Erfassen-Dialog (vorbelegt). RPC wirft `tax_rate_required`, wenn weder Override noch Auflösung vorhanden — Frontend verhindert das vorab.
- **`sellprice` NULL:** Marge-Zeile entfällt (Form + Deal-Detail).
- **Produkt ohne EK:** Vergleich = `no_ek`, Karte bleibt sichtbar; „+ EK erfassen“.
- **Angebot = teuerster EK (Gleichstand):** **nicht** ausgeblendet (Schwelle ist strikt `>`). 
- **Lieferanten-Dubletten:** durch case-insensitiven Unique-Index + Trim verhindert; find-or-create matcht bestehende.
- **Bearbeiten einer EK-Zeile:** netto/brutto wird aus dem (ggf. geänderten) getippten Wert und dem aufgelösten Satz **neu** berechnet.
- **Marktguru-Packungsgrößen:** roher Vergleich, sichtbarer Mengen-Hinweis; keine Auto-Normalisierung (Nicht-Ziel).
- **Float vs numeric:** `products.sellprice` ist `float8` → in Margen-Berechnungen explizit nach `numeric` casten (Lehre aus dem Tax-Trigger-Bug `round(double precision,…)`).
- **Rundungspräzision:** `deal_cache.deal_price` ist `numeric(10,2)`, EK-Preise sind `numeric(10,4)`. Vergleiche (`dealGross > max_gross`) bleiben korrekt; `max_gross`/`min_gross` **nicht** auf 2 Nachkommastellen runden — sonst verschiebt sich die strikte `>`-Plausibilitätsschwelle an Cent-Grenzen.

## 11. Rückwärtskompatibilität

- Nur **additive** DB-Änderungen (zwei neue Tabellen, neue Funktionen). Keine Spalten/Trigger geändert, keine bestehende Migration editiert.
- Firmware/MQTT/Edge-Functions (außer neuen RPCs) unverändert → ältere Geräte und bestehende Clients unbeeinträchtigt.
- iOS/Android-Clients ignorieren die neuen Tabellen; kein Schema-Bruch.
- Deals ohne EK-Daten verhalten sich exakt wie heute (Filter & Vergleich greifen nur, wenn EK existiert).

## 12. Tests

- **Vitest (pure):** `app/lib/purchaseComparison.ts` — `counterpart`, `marginNet`, `classifyDeal` (alle Verdikt-Pfade inkl. `implausible`, Toleranzgrenzen, `no_ek`, Gleichstand = nicht ausgeblendet).
- **SQL-Tests** (`Docker/supabase/tests/*.test.sql`, `run-sql-tests.sh`): `resolve_product_tax_rate` (mit/ohne Klasse, Gültigkeitsfenster), `add_purchase_price` (netto- und brutto-Eingabe → korrekte Gegenwerte; Lieferant find-or-create; `tax_rate_required`-Fehler), `get_product_purchase_summary` (newest/min/max/count; Firmen-Scoping/RLS).
- **Composable-Smoke** (optional): `useDeals` Suppression schließt Karten korrekt aus `newDealsCount` aus (mit Stubs aus `test-helpers/nuxt-stubs.ts`).

## 13. Produktions-Checkliste

- Keine neuen Env-Vars, kein neuer Storage-Bucket, keine ACL-Änderung.
- Neue Migrationen werden von `update.sh` automatisch angewandt (idempotent: `CREATE TABLE IF NOT EXISTS`, `CREATE OR REPLACE FUNCTION`).
- `.githooks/pre-commit` beachten: nur **neue** Migrationsdateien, bestehende nicht anfassen.

## 14. Datei-Touch-Liste

**Neu**
- `Docker/supabase/migrations/20260614HHMMSS_suppliers_and_purchase_prices.sql` (Tabellen + RLS)
- `Docker/supabase/migrations/20260614HHMMSS_purchase_price_functions.sql` (`resolve_product_tax_rate`, `add_/update_purchase_price`, `get_product_purchase_summary`)
- `Docker/supabase/tests/purchase_prices.test.sql`
- `management-frontend/app/composables/usePurchasePrices.ts`
- `management-frontend/app/lib/purchaseComparison.ts` (+ `__tests__/purchaseComparison.test.ts`)
- ggf. `management-frontend/app/components/SupplierCombobox.vue` (oder `ProductCombobox.vue` generalisieren)

**Geändert**
- `management-frontend/app/components/ProductFormModal.vue` (EK-Abschnitt)
- `management-frontend/app/composables/useProducts.ts` (Summary für Liste/Marge, falls dort gebündelt)
- `management-frontend/app/pages/products/index.vue` (Spalte EK/Spanne)
- `management-frontend/app/composables/useDeals.ts` (Summary-Join, Suppression, newDeals-Ausschluss)
- `management-frontend/app/pages/deals/index.vue` (Pill, Detail-Vergleich, Ausgeblendet-Bereich)
- `management-frontend/i18n/locales/de.json` + `en.json`

## 15. Spätere Ausbaustufen (nicht v1)
- EK beim Wareneingang/Refill miterfassen → üblicher EK aus echten Einkäufen.
- Eigene Lieferanten-Seite (Kontaktdaten, Artikelnummern, Mindestbestellmengen).
- Packungsgrößen-Normalisierung für den Angebotsvergleich.
- EK-Historie-Diagramm pro Produkt; Spannen-Report über alle Produkte.
