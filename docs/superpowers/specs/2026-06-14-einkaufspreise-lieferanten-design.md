# Einkaufspreise & Lieferanten — Design

**Datum:** 2026-06-14
**Status:** Design (Brainstorming abgeschlossen, bereit für Implementierungsplan)
**Betroffen:** Supabase-Migrationen + RPCs + eine geteilte Edge-Function (`deal-search`), `management-frontend` (PWA) **und** die native iOS-App (`ios/VMflow`, SwiftUI). Keine Firmware-/MQTT-/Android-Änderungen in v1.

---

## 1. Problem & Ziel

Der Betreiber möchte zu jedem Produkt den **üblichen Einkaufspreis (EK)** hinterlegen, um auf der **Deals-Seite** (Marktguru-Angebote) auf einen Blick zu sehen, ob ein Angebot gegenüber dem eigenen Großhändler-EK **wirklich einen Vorteil bringt** oder nicht.

Kernanforderungen aus dem Gespräch:
1. **Netto und Brutto** müssen beide abbildbar sein: Marktguru-Angebote sind **brutto**, Großhändler-Rechnungen **netto**.
2. **Mehrere Lieferantenpreise** pro Produkt, mit Historie — um zu sehen, ob ein anderer Händler schon mal günstiger war.
3. Vergleich der Angebote gegen den EK auf der Deals-Seite.
4. **Volle Parität** zwischen PWA und nativer iOS-App.

## 2. Ziele / Nicht-Ziele

**Ziele (v1 — „Kern + Marge“, PWA **und** iOS):**
- EK-Pflege pro Produkt: mehrere Lieferanten, Historie, netto **und** brutto.
- Firmenweite, wiederverwendbare **Lieferanten**-Liste, **inline** beim Tippen angelegt (Autocomplete).
- **Margenanzeige** am Produkt (Verkaufspreis vs. üblicher EK, auf Netto-Basis).
- **Angebots-Vergleich** auf der Deals-Seite (Karte + Detail) inkl. **Plausibilitäts-Filter** (Angebote über dem teuersten EK ausblenden und **nicht** als „neue Deals“ zählen/pushen).

**Nicht-Ziele (bewusst ausgeklammert, YAGNI):**
- Kein Erfassen des EK beim Wareneingang/Refill (späteres Folge-Feature).
- Keine Gebinde-/Packungslogik — **direkter Stückpreis**; Karton→Stück rechnet der Nutzer selbst.
- Keine eigene Lieferanten-Verwaltungsseite (Kontaktdaten, CRUD-Seite) in v1.
- Keine Normalisierung von Angebots-Packungsgrößen („Multipack“) — Vergleich ist roh, Stück-EK gegen Angebotspreis.
- Keine Firmware-/MQTT-/Android-Änderungen. Keine Realtime-Publication-Änderung (EK braucht kein Realtime).

## 3. Festgelegte Entscheidungen (aus dem Brainstorming)

| Thema | Entscheidung |
|-------|--------------|
| Netto/Brutto-Pflege | **Ein Wert wird getippt, der andere berechnet** über den Steuersatz des Produkts. Beide werden gespeichert. |
| Mengenbasis | **Direkter Stückpreis** (kein Gebinde-Feld). |
| Lieferanten | Firmenweite Liste, **inline per Autocomplete** angelegt (kein Freitext, keine separate Pflegeseite). |
| Scope | **Kern + Marge**, **volle iOS-Parität**. |
| „Üblicher EK“ | = **neuester** EK-Eintrag (über alle Lieferanten). |
| Marge | auf **Netto-Basis** (USt. ist Durchlaufposten): `VK_netto − EK_netto`. |
| Plausibilitäts-Filter | Angebot (brutto) **> teuerster** erfasster EK (brutto) → unplausibel/Fehl-Match → **ausblenden mit Zähler + Aufklappen**. |
| Ausgeblendete Deals | zählen **nicht** als „X neue Deals“ und lösen **keine** Push-Benachrichtigung aus (server-seitig durchgesetzt). |

## 4. Datenmodell (geteilt — eine Quelle für PWA & iOS)

Zwei neue Tabellen, beide firmen-gescoped mit RLS analog zu `tax_classes`. Geldbeträge als `numeric(10,4)` (wie `sales.price_net`), Steuersatz als `numeric(6,4)` (wie `tax_rates.rate`).

> **Migrations-Immutabilität:** Alle Änderungen kommen in **neue** Migrationsdateien mit Zeitstempel ≥ `20260614…`. Bestehende Migrationen (insb. `20260406000000_tax_infrastructure.sql`, der Sales-Trigger und `20260530120000_daily_deal_refresh.sql`) werden **nicht** editiert — geänderte Funktionen via `CREATE OR REPLACE` in neuer Datei.

### 4.1 `suppliers` (NEU)
```sql
CREATE TABLE public.suppliers (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  name       text NOT NULL,
  CONSTRAINT suppliers_name_not_blank CHECK (length(btrim(name)) > 0)
);
CREATE UNIQUE INDEX suppliers_company_lower_name_uq
  ON public.suppliers (company_id, lower(btrim(name)));  -- "Metro" == "metro"
```
RLS: CRUD für `authenticated` mit `company_id = public.my_company_id()` (Muster `tax_classes`). Kein Löschen-UI in v1; FK von Preisen ist `ON DELETE RESTRICT`.

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
  price_basis text NOT NULL CHECK (price_basis IN ('net','gross')),  -- getippte Quelle der Wahrheit
  tax_rate    numeric(6,4) NOT NULL,   -- Snapshot des verwendeten Satzes (z. B. 0.0700)
  observed_on date NOT NULL DEFAULT CURRENT_DATE,  -- Rechnungs-/Angebotsdatum
  note        text
);
CREATE INDEX product_purchase_prices_product_idx
  ON public.product_purchase_prices (product_id, observed_on DESC, created_at DESC);
```
RLS: CRUD für `authenticated` mit `company_id = public.my_company_id()`. Beide Geldwerte sind **immer** befüllt → Vergleich/Sortierung auf `price_gross` ohne NULL-Lücken.

## 5. Steuersatz-Auflösung & Netto↔Brutto

Die Tarif-Auflösung existiert heute nur **inline** im Sales-Trigger (`stamp_machine_and_decrement_stock`). Wir übernehmen daraus die **Steuerklassen- + Satz-Logik** (`COALESCE(product.tax_class_id, category.tax_class_id)` → `tax_rates` nach Firma/Land/Gültigkeit), **adaptieren** sie aber **produkt-zentrisch**: Firma/Land kommen aus `products.company` + `companies.country_code` (**nicht** aus `vendingMachine` wie im Trigger — ein EK ist nicht maschinen-gebunden). Der Trigger bleibt unangetastet; die neue Funktion ist eine eigenständige, wiederverwendbare Variante:

```sql
CREATE OR REPLACE FUNCTION public.resolve_product_tax_rate(
  p_product_id uuid, p_on date DEFAULT CURRENT_DATE
) RETURNS numeric          -- rate (z. B. 0.0700) oder NULL
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_company uuid; v_country char(2); v_class uuid; v_rate numeric(6,4);
BEGIN
  SELECT p.company, COALESCE(p.tax_class_id, pc.tax_class_id) INTO v_company, v_class
  FROM public.products p
  LEFT JOIN public.product_category pc ON pc.id = p.category
  WHERE p.id = p_product_id;

  SELECT COALESCE(c.country_code,'DE') INTO v_country
  FROM public.companies c WHERE c.id = v_company;

  IF v_class IS NULL OR v_company IS NULL THEN RETURN NULL; END IF;

  SELECT tr.rate INTO v_rate FROM public.tax_rates tr
  WHERE tr.company_id = v_company AND tr.tax_class_id = v_class
    AND tr.country_code = v_country
    AND tr.valid_from <= p_on
    AND (tr.valid_to IS NULL OR tr.valid_to >= p_on)
  ORDER BY tr.valid_from DESC LIMIT 1;
  RETURN v_rate;  -- NULL falls kein passender Satz
END $$;
```

> **Konvention:** Tabellen im Funktionskörper **voll qualifizieren** (`public.*`), damit die `search_path`-Wahl nicht tragend ist. Keine dieser Funktionen nutzt pgcrypto → `SET search_path = public` genügt.

Umrechnung (in den RPCs):
- `price_basis='net'` → `price_gross = round(price_net * (1 + rate), 4)`
- `price_basis='gross'` → `price_net = round(price_gross / (1 + rate), 4)`

**Fallback ohne Steuersatz:** Liefert `resolve_product_tax_rate` NULL, verlangt der Erfassen-Dialog (beide Clients) einmalig einen Prozentsatz (Vorbelegung = häufigster Steuersatz der Firma, sonst 19 %). Dieser Override wird an den RPC durchgereicht; ein Satz ist **Pflicht**, damit immer netto+brutto vorliegen.

## 6. Backend — RPCs & Edge-Function

Alle neuen RPCs: `SECURITY DEFINER`, `SET search_path = public`, Zugehörigkeit über `public.my_company_id()`.

### 6.1 `add_purchase_price(p_product_id, p_supplier_name, p_price, p_basis, p_observed_on, p_note, p_tax_rate_override DEFAULT NULL)`
1. `v_company := my_company_id()`; prüfen, dass `p_product_id` zu `v_company` gehört.
2. **Lieferant find-or-create** über `lower(btrim(name))` (leerer Name → Exception).
3. `v_rate := COALESCE(p_tax_rate_override, resolve_product_tax_rate(p_product_id, p_observed_on))`; NULL → `RAISE EXCEPTION 'tax_rate_required'`.
4. netto/brutto aus `p_basis`+`v_rate` berechnen.
5. Zeile einfügen und zurückgeben.

### 6.2 `update_purchase_price(p_id, …)`
Wie `add_…`, per `p_id`, prüft `company_id = my_company_id()`, löst Lieferant erneut auf, rechnet neu. **Löschen** läuft direkt über RLS-`DELETE` (kein RPC).

### 6.3 `get_product_purchase_summary(p_product_ids uuid[])`
Batch, je Produkt eine Zeile:
```
product_id, ek_count int,
newest_net, newest_gross, newest_supplier, newest_on,   -- "üblicher EK"
min_gross, min_supplier, min_on,                          -- günstigster je
max_gross,                                                -- Plausibilitäts-Schwelle
effective_tax_rate                                        -- für Marge/deal_net
```
Filtert auf `company_id = my_company_id()`. „Neuester“ deterministisch: `ORDER BY observed_on DESC, created_at DESC`. Produkte ohne EK → `ek_count = 0` (übrige NULL).

### 6.4 `get_suppressed_offer_keys(p_company_id uuid)` (NEU — Plausibilitäts-Rollup)
Kapselt die Sperrlogik **an einer Stelle** (von RPC **und** Edge-Function genutzt). Gibt `(retailer, offer_id)` der **unterdrückten** Angebote einer Firma zurück.

Definition (pro `deal_cache`-Zeile → aufgelöste Produkte → Rollup je Angebot):
- **Produkt-Zeile** (`product_id`): genau ein Produkt. **Keyword-Zeile** (`keyword_id`): Produkte via `deal_keyword_products`.
- Eine Zeile ist **unplausibel**, wenn sie ≥1 Produkt auflöst **und alle** aufgelösten Produkte EK haben **und** für alle `max_ek_gross < deal_price` gilt. (Ein Produkt **ohne** EK oder mit `max_ek_gross >= deal_price` macht die Zeile plausibel.)
- Ein **Angebot** `(retailer, offer_id)` ist **unterdrückt**, wenn **alle** seine Zeilen unplausibel sind (`bool_and`).
- Zeilen ohne aufgelöste Produkte gelten als plausibel (keine Sperre ohne positives Fehl-Match-Indiz).

`SECURITY DEFINER`, `SET search_path = public`. **Grant:** nur `service_role` (für die Edge-Function); `get_new_deal_keys` ruft sie als Definer-Funktion ohne zusätzlichen Grant. Parametrisiert per `p_company_id` (kein `my_company_id()`-Zwang), damit der service-role-Kontext (kein JWT) sie nutzen kann.

### 6.5 `get_new_deal_keys()` — `CREATE OR REPLACE` (in neuer Migration)
Unverändert in Signatur/Semantik, **plus** Ausschluss unterdrückter Angebote:
```sql
... bestehende WHERE-Bedingungen ...
AND NOT EXISTS (
  SELECT 1 FROM public.get_suppressed_offer_keys(v_company) s
  WHERE s.retailer = dc.retailer AND s.offer_id = dc.offer_id
)
```
**Wichtig:** Das `CREATE OR REPLACE` muss den **kompletten** bestehenden Funktionskörper aus `20260530120000` wortgleich übernehmen (Baseline-Lazy-Insert + Read, `deal_offer_first_seen`-Join, das `NOT EXISTS … deal_user_state … (pinned_at OR archived_at)`) und **nur** die obige Sperr-Klausel ergänzen — nichts still weglassen. `get_new_deals_count()` (Dashboard-Banner) wrappt diese Funktion → erbt den Ausschluss automatisch.

### 6.6 `deal-search` Edge Function — Push-Zähler (geänderte Datei)
In `Docker/supabase/functions/deal-search/index.ts` werden nach dem Ermitteln der erstmals gesehenen Angebote (`inserted`) die **unterdrückten** entfernt, bevor `newOfferCount`/`newRetailers` für den `new_deals`-Push berechnet werden:
- service-role-`rpc('get_suppressed_offer_keys', { p_company_id })` holen → Set,
- `inserted` darauf filtern (Angebote, deren `(retailer, offer_id)` im Set liegt, raus).

Damit pusht der Cron-Lauf nie über unplausible Angebote. (Manuelle Refreshes pushen ohnehin nie.)

## 7. Geteilte Vergleichslogik (pure, **einmal definiert — zweimal portiert**)

Damit PWA und iOS **identisch** urteilen, wird die Logik als **reine Funktionen** definiert und in beiden Sprachen 1:1 portiert (TS: `purchaseComparison.ts`, Swift: `PurchaseComparison.swift`). Eingaben: `dealGross` (= `deal_price`), `summary` (aus 6.3), optional `sellpriceGross`.

- `counterpart(value, basis, rate)` → netto↔brutto.
- `marginNet(sellpriceGross, ekNet, rate)` → `{ rohertrag, spannePct }` (`VK_netto − EK_netto`).
- `classifyDeal(dealGross, summary, tolerancePct = 3)` → Verdikt:
  - `ek_count === 0` → `no_ek`
  - `dealGross > max_gross` → `implausible`  *(Sperr-Schwelle, strikt `>`)*
  - `dealGross <= min_gross` → `good_best` („günstiger als je“)
  - `dealGross < newest_gross` (außerhalb Toleranz) → `good`
  - innerhalb ±`tolerancePct` um `newest_gross` → `similar`
  - sonst (`> newest_gross`, ≤ `max_gross`) → `worse`
  - `deltaPct` relativ zu `newest_gross`.
- `marginDelta(...)` (grüner Fall): `dealNet = dealGross/(1+rate)` → neue Spanne vs. aktuelle.

**Verbindlich:** `max_gross`/`min_gross` **nicht** auf 2 Nachkommastellen runden (sonst verschiebt sich die strikte `>`-Schwelle an Cent-Grenzen). `deal_price` ist `numeric(10,2)`, EK `numeric(10,4)` — direkter Vergleich ist korrekt.

## 8. Frontend PWA

### 8.1 `usePurchasePrices()` (NEU) & `app/lib/purchaseComparison.ts` (NEU)
- `fetchSuppliers()`, `fetchPurchasePrices(productId)`, `addPurchasePrice`/`updatePurchasePrice` (RPCs), `deletePurchasePrice` (RLS-`delete`), `resolveTaxRate(productId)` (Live-Vorschau + Fallback-Erkennung), `summarize(rows)`.
- Reine Helfer in `purchaseComparison.ts` (unit-getestet) — siehe §7.
- Typen manuell casten (keine generierten DB-Typen).

### 8.2 `ProductFormModal.vue` — Abschnitt „Einkauf & Lieferanten“
Unter Preis/Kategorie, **nur im Bearbeiten-Modus** (braucht `product.id`; im Anlegen-Modus Hinweis „erst speichern“). Inhalt (Mockup `product-form.html`): Verlauf je Lieferant (netto+brutto, ★ günstigster, „aktuell üblich“, Bearbeiten/Löschen); Erfassen-Block mit Lieferant-Autocomplete (`ProductCombobox.vue`-Muster, neuer Name wird angelegt), Preisfeld + **netto/brutto-Umschalter** + live Gegenwert, Datum, Notiz, bei nicht auflösbarem Satz Pflicht-`%`-Feld; **Marge** (`marginNet`). Schreibrechte folgen den Produkt-Editier-Rollen.

### 8.3 `products/index.vue` — Spalte „üblicher EK / Spanne“
Sortierbare Spalte; lädt `get_product_purchase_summary` für alle gelisteten Produkte (ein Batch-Call). Ohne EK: „—“.

### 8.4 `useDeals.ts` + `deals/index.vue`
- `useDeals`: `product_id`s der Matches sammeln → ein `get_product_purchase_summary(ids)` → Map; pro Match `classifyDeal`. Karte **suppressed**, wenn sie Matches hat und **alle** `implausible` (Produkte ohne EK halten sie sichtbar). Neue computed `suppressedDeals`/`suppressedCount`. Der **„neue Deals“-Status kommt aus `get_new_deal_keys`** (jetzt server-seitig ohne unterdrückte). `newDealsCount` bleibt wie heute `activeDeals.filter(isNew).length` — da `activeDeals` bereits sperrfrei ist **und** `isNew` auf die server-bereinigten Keys gatet, sind unterdrückte doppelt ausgeschlossen; kein zusätzlicher Sonderfilter nötig.
- `deals/index.vue`: Karten-Pill (bestes sichtbares Verdikt), Detail-Vergleichszeile je Produkt + Marge-Effekt (grün, falls `sellprice`), „⚪ Kein EK“ → „+ EK erfassen“ (öffnet `ProductFormModal`), Ausgeblendet-Bereich „▸ N ausgeblendet … anzeigen“ mit Markierung „weit über EK – evtl. Fehl-Match“; Aktionen: bestehendes **Archivieren**, bei Keyword-Matches Link zum **Keyword-Editor**.

## 9. Native iOS (`ios/VMflow`) — Parität

Backend ist geteilt → reine Swift-Client-Arbeit. Supabase-Zugriff über `SupabaseService.shared.client` (`supabase-swift`): `.rpc(name, params:)`, `.from().select()`, `client.functions.invoke`. Company-Scoping wie bestehend über `organization_members`-Query + RLS.

### 9.1 Models (NEU, `ios/VMflow/Models/`)
- `Supplier.swift` — `{ id: UUID, name: String, companyId: UUID }` (Codable, snake_case `CodingKeys`).
- `PurchasePrice.swift` — `{ id, productId, supplierId, priceNet, priceGross, priceBasis, taxRate, observedOn, note, supplierName? }`.
- `ProductPurchaseSummary.swift` — dekodiert `get_product_purchase_summary` (Felder aus 6.3).

### 9.2 Vergleichslogik-Port (NEU)
- `ios/VMflow/Utilities/PurchaseComparison.swift` — **1:1-Port** der reinen Funktionen aus §7 (`counterpart`, `marginNet`, `classifyDeal`, `marginDelta`) mit identischen Schwellen/Toleranz. Enum `DealVerdict { noEk, implausible, goodBest, good, similar, worse }`.

### 9.3 Service / ViewModels (geändert)
- `ProductsViewModel` (oder neuer `PurchasePricesViewModel`): `loadSuppliers()`, `loadPurchasePrices(productId)`, `addPurchasePrice(...)`/`updatePurchasePrice(...)` (RPC via `AnyJSON`-Params), `deletePurchasePrice(id)`, `resolveTaxRate(productId)`.
- `DealsViewModel`: nach `deal-search` die `productId`s sammeln → `get_product_purchase_summary` (ein RPC) → Map; pro `DedupedDeal` Verdikt + `suppressed`-Rollup berechnen (gleiche Regel wie PWA). `suppressedDeals` getrennt halten; aktive Liste schließt sie aus. **„Neu“** stammt aus `get_new_deal_keys` (server-seitig bereinigt) — kein Nachfiltern nötig.

### 9.4 Views (geändert)
- **`ProductDetailSheet.swift`:** Abschnitt „Einkauf & Lieferanten“ — Zusammenfassung (üblicher EK brutto + Spanne) + Button „Einkaufspreise verwalten“ → **neues `PurchasePricesSheet.swift`** (Verlaufsliste + Hinzufügen/Bearbeiten/Löschen). Lieferant-Autocomplete via `.searchable()` (Muster `ReplacementProductPicker`), netto/brutto-`Picker`/`Toggle` mit live Gegenwert, Datum-`DatePicker`, Notiz, Fallback-`%`-Feld. Stock-Badge-Muster aus `DealDetailSheet` für EK-/Marge-Badges.
- **`DealCard.swift`:** Verdikt-Pill (bestes sichtbares Produkt), Ampel-Farbe.
- **`DealDetailSheet.swift`:** Vergleichszeile je gematchtem Produkt (Angebot vs. üblicher EK, Ampel, „günstigster je“), Marge-Effekt im grünen Fall, „Kein EK“ → „+ EK erfassen“ (öffnet `PurchasePricesSheet`); **Ausgeblendet-Bereich** (DisclosureGroup) mit den unterdrückten Karten + Archivieren/Keyword-Link.

### 9.5 Lokalisierung
Neue Strings via `String(localized:)` in `ios/VMflow/Resources/Localizable.xcstrings` (de **und** en) — analog zu den Web-i18n-Keys.

## 10. i18n (Web)
Neue Keys in `management-frontend/i18n/locales/de.json` **und** `en.json` (EK/Lieferant/Marge/Verdikt/Ausgeblendet). Keine hartcodierten Strings.

## 11. Fehlerbehandlung & Randfälle
- **Kein Steuersatz auflösbar:** Pflicht-`%`-Feld im Erfassen-Dialog (beide Clients); RPC wirft `tax_rate_required`, falls weder Override noch Auflösung.
- **`sellprice` NULL:** Marge-Zeile entfällt (Form + Deal-Detail) auf beiden Clients.
- **Produkt ohne EK:** Verdikt `no_ek`, Karte bleibt sichtbar; „+ EK erfassen“.
- **Angebot = teuerster EK (Gleichstand):** **nicht** ausgeblendet (Schwelle strikt `>`).
- **Keyword-Angebot:** Sperre nur, wenn **alle** verknüpften Produkte unplausibel (Produkt ohne EK hält das Angebot sichtbar). Keyword-Gruppe ohne verknüpfte Produkte → nie unterdrückt.
- **Lieferanten-Dubletten:** durch case-insensitiven Unique-Index + Trim verhindert; find-or-create matcht bestehende.
- **Bearbeiten einer EK-Zeile:** netto/brutto wird neu berechnet.
- **Float vs numeric:** `products.sellprice`/`sales.item_price` sind `float8` → in Margen-Berechnungen explizit nach `numeric` casten (Lehre aus dem Tax-Trigger-Bug `round(double precision,…)`).
- **Rundung:** `max_gross`/`min_gross` nicht auf 2 Nachkommastellen runden (siehe §7).

## 12. Rückwärtskompatibilität
- Nur **additive** DB-Änderungen (zwei neue Tabellen, neue Funktionen) + `CREATE OR REPLACE get_new_deal_keys` (gleiche Signatur). Keine Spalten/Trigger geändert, keine bestehende Migration editiert.
- **Kern-Eigenschaft:** Ohne EK-Daten ist `get_suppressed_offer_keys` **leer** → `get_new_deal_keys`, der Push und beide Client-Listen verhalten sich **exakt wie heute**. Das Feature greift nur dort, wo EK existiert.
- `deal-search`-Response-Form unverändert (nur interner Push-Zähler gefiltert) → alte Clients (PWA/iOS ohne EK-Code) funktionieren weiter.
- Firmware/MQTT/Android unberührt.

## 13. Tests
- **Vitest (pure):** `app/lib/purchaseComparison.ts` — alle Verdikt-Pfade inkl. `implausible`, Toleranzgrenzen, `no_ek`, Gleichstand = nicht ausgeblendet; **Einzel-EK-Fall** (`min == max == newest`: ein Angebot genau auf diesem Wert → `good_best`, knapp darüber → `implausible`); `counterpart`/`marginNet`.
- **SQL-Tests** (`Docker/supabase/tests/*.test.sql`, `run-sql-tests.sh`): `resolve_product_tax_rate`; `add_purchase_price` (netto-/brutto-Eingabe, Lieferant find-or-create, `tax_rate_required`); `get_product_purchase_summary` (newest/min/max/count, Scoping); **`get_suppressed_offer_keys`** (Produkt- und Keyword-Zeilen; Gleichstand nicht unterdrückt; Produkt ohne EK hält Angebot sichtbar); **`get_new_deal_keys`** schließt unterdrückte aus, ist aber bei leerem EK identisch zur alten Ausgabe.
- **iOS (pure):** Falls ein Test-Target existiert, Unit-Tests für `PurchaseComparison.swift` mit denselben Fällen wie Vitest (Parität). Sonst mindestens als reine, isoliert testbare Logik halten.

## 14. Produktions-Checkliste
- Keine neuen Env-Vars, kein neuer Storage-Bucket, keine ACL-Änderung.
- Neue Migrationen werden von `update.sh` automatisch angewandt (idempotent: `CREATE TABLE IF NOT EXISTS`, `CREATE OR REPLACE FUNCTION`).
- `deal-search` ist in **Prod** (`docker-compose`) **und** Dev (Supabase CLI) deploybar — beide Pfade verifizieren.
- `.githooks/pre-commit`: nur **neue** Migrationsdateien.

## 15. Datei-Touch-Liste

**Neu (Backend)**
- `Docker/supabase/migrations/20260614HHMMSS_suppliers_and_purchase_prices.sql`
- `Docker/supabase/migrations/20260614HHMMSS_purchase_price_functions.sql` (`resolve_product_tax_rate`, `add_/update_purchase_price`, `get_product_purchase_summary`)
- `Docker/supabase/migrations/20260614HHMMSS_deal_plausibility_filter.sql` (`get_suppressed_offer_keys`, `CREATE OR REPLACE get_new_deal_keys`)
- `Docker/supabase/tests/purchase_prices.test.sql`, `Docker/supabase/tests/deal_plausibility.test.sql`

**Geändert (Backend)**
- `Docker/supabase/functions/deal-search/index.ts` (Push-Zähler ohne unterdrückte)

**Neu (PWA)**
- `management-frontend/app/composables/usePurchasePrices.ts`
- `management-frontend/app/lib/purchaseComparison.ts` (+ `__tests__/purchaseComparison.test.ts`)
- ggf. `management-frontend/app/components/SupplierCombobox.vue`

**Geändert (PWA)**
- `ProductFormModal.vue`, `useProducts.ts`, `pages/products/index.vue`, `useDeals.ts`, `pages/deals/index.vue`, `i18n/locales/de.json` + `en.json`

**Neu (iOS)**
- `ios/VMflow/Models/Supplier.swift`, `PurchasePrice.swift`, `ProductPurchaseSummary.swift`
- `ios/VMflow/Utilities/PurchaseComparison.swift`
- `ios/VMflow/Views/Products/PurchasePricesSheet.swift`

**Geändert (iOS)**
- `ProductsViewModel.swift` (+ ggf. neuer `PurchasePricesViewModel`), `DealsViewModel.swift`
- `Views/Products/ProductDetailSheet.swift`, `Views/Deals/DealCard.swift`, `Views/Deals/DealDetailSheet.swift`
- `ios/VMflow/Resources/Localizable.xcstrings`

## 16. Spätere Ausbaustufen (nicht v1)
- EK beim Wareneingang/Refill miterfassen → üblicher EK aus echten Einkäufen.
- Eigene Lieferanten-Seite (Kontaktdaten, Artikelnummern, Mindestbestellmengen).
- Packungsgrößen-Normalisierung für den Angebotsvergleich.
- EK-Historie-Diagramm pro Produkt; Spannen-Report; Android-Parität.
