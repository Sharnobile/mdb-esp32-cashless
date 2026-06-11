# iOS Dashboard: "Letzte Aktivität" Feed (Design)

**Datum:** 2026-06-11
**Status:** Approved by user
**Scope:** iOS native app (VMflow) + kleine PWA-Schreibpfad-Ergänzungen. Keine DB-Migration.

## Ziel

Die Sektion „Recent Sales" auf dem iOS-Dashboard wird zu „Letzte Aktivität" (en: "Recent Activity"). Sales erscheinen unverändert (gleiche Zeile, gleicher Tap → ProductDetailSheet, gleiche Tagesgruppierung). Zusätzlich erscheinen drei neue Ereignistypen in derselben Timeline:

1. **Automat gefüllt** — vorhandene `activity_log`-Einträge `stock_refill_tour` (rückwirkend sichtbar)
2. **Ware eingebucht** — vorhandene `warehouse_transactions` mit `transaction_type IN ('incoming', 'intake')` (PWA schreibt `incoming`, iOS `intake`; rückwirkend sichtbar)
3. **Tour gestartet** — neues `activity_log`-Event `tour_started`, das beide Refill-Wizards (iOS + PWA) ab jetzt beim Tour-Start schreiben

Außerdem ersetzt eine Endlos-Liste (Infinite Scroll) den „Load more"-Button.

## Kontext / Ist-Zustand

- `DashboardView.recentSalesSection` ([DashboardView.swift](../../../ios/VMflow/Views/Dashboard/DashboardView.swift)) rendert tagesgruppierte `SaleWithMachine`-Zeilen aus `DashboardViewModel.recentSales`; Fenster: heute → +7 Tage pro „Load more"-Tap (`recentSalesDaysBack`).
- Refills werden von **beiden** Clients pro Maschine als `activity_log`-Eintrag `stock_refill_tour` geschrieben. Metadaten: `tour_id`, `machine_id`, `machine_name`, `trays_refilled`, `total_added`, `products[] {product_id, product_name, quantity}`, `_user_display`, `_user_email`, optional `warehouse_id`. Skips als `stock_refill_tour_skip`.
- Ein „Tour gestartet"-Event existiert **nicht**. Die `tour_id` wird in `useRefillWizard.startTour()` (PWA, `useRefillWizard.ts` ~Z.546) bzw. `RefillWizardViewModel.startTour()` (iOS, ~Z.1614) erzeugt.
- Wareneinbuchungen landen **nur** in `warehouse_transactions` (`transaction_type: 'incoming'`, eine Zeile pro Produkt/Charge, `user_id`, `quantity_change` > 0, FK-Joins `products(name)` / `warehouses(name)` via PostgREST möglich). Kein `activity_log`-Eintrag.
- Lager-Ausbuchungen der Tour (`deduct_warehouse_stock_fifo`) bekommen die `tour_id` heute **nicht** mit — nur `p_reference_id = machine_id`, `p_notes = 'Refill tour'`. Beide Clients übergeben bereits `p_metadata` (nur `_user_email`).
- iOS `RealtimeService` nutzt ein Version-Counter-Muster (`salesVersion`, `machinesVersion`, …) über einen gemeinsamen Channel. `activity_log` ist bereits in der `supabase_realtime`-Publication, `warehouse_transactions` nicht.

## Entscheidung: Ansatz A — client-seitiger Merge

Das iOS-Dashboard lädt drei Quellen parallel im selben Zeitfenster und merged sie client-seitig. Begründung: rückwirkend vollständig (Refills + Intakes existieren bereits als Daten), keine Migration, Sales-Pfad unangetastet, konsistent mit dem bestehenden Dashboard-Muster paralleler Queries. Verworfen: Dual-Write ins activity_log (alte Intakes fehlen, Konsistenzrisiko) und Server-RPC (Migration + doppelte Anreicherungslogik; erst sinnvoll, wenn die PWA denselben Feed bekommt).

## 1. Datenmodell (iOS)

Neues Enum, sortier- und gruppierbar über ein gemeinsames `date`:

```swift
enum ActivityFeedItem: Identifiable {
    case sale(SaleWithMachine)            // unverändert
    case machineRefilled(RefillActivity)  // activity_log: stock_refill_tour
    case tourStarted(TourActivity)        // activity_log: tour_started
    case stockIntake(IntakeGroup)         // warehouse_transactions: incoming, gruppiert
}
```

- `RefillActivity`: `id`, `createdAt`, `machineName`, `traysRefilled`, `totalAdded`, `userDisplay`, `tourId`, `products[] (name, quantity)`
- `TourActivity`: `id`, `createdAt`, `userDisplay`, `machineCount`, `machineNames[]`, `warehouseName?`, `tourId`
- `IntakeGroup`: deterministische `id` (= ID der ältesten Transaktion der Gruppe — stabil über Reloads, damit Aufklapp-Zustand und LazyVStack-Identität nicht springen), `date` (= jüngste Transaktion der Gruppe), `userDisplay`, `warehouseName?`, `productCount` (distinct Produkte), `totalUnits` (Σ `quantity_change`), `products[] (name, quantity)`

Metadaten-Decodierung des `activity_log` erfolgt tolerant (fehlende Felder → Fallbacks), da alte Einträge weniger Felder haben können.

## 2. Laden & Merge (DashboardViewModel)

`loadRecentSales()` wird zu `loadRecentActivity()` erweitert (Fensterberechnung über `recentSalesDaysBack` bleibt identisch):

- **Query A (unverändert):** Sales + Maschinen-/Produktanreicherung wie heute.
- **Query B:** `activity_log` mit `action in ('stock_refill_tour', 'tour_started')`, `created_at >= windowStart`, sortiert desc. RLS scoped auf die Company.
- **Query C:** `warehouse_transactions` mit `transaction_type IN ('incoming', 'intake')`, `created_at >= windowStart`, Select inkl. `products(name)` und `warehouses(name)`. (Cross-Client-Inkonsistenz: die PWA schreibt `'incoming'`, die iOS-App `'intake'` für denselben Vorgang — der Feed muss beide lesen.)

**Intake-Gruppierung:** Transaktionen aufsteigend nach Zeit sortieren, dann konsekutiv gruppieren, solange (gleicher `user_id` UND gleiche `warehouse_id` UND Lücke zur vorherigen Transaktion ≤ 15 min). Gruppen, die Mitternacht überschreiten, dürfen splitten (Tagesgruppierung des Feeds; selten, akzeptiert).

**Nutzernamen für Intakes:** `warehouse_transactions` trägt nur `user_id`. Auflösung wie in der PWA über `users (id, email, first_name, last_name)` für die im Fenster vorkommenden IDs, mit In-Memory-Cache im ViewModel. Fallback: E-Mail, sonst „System"/gekürzte ID. Refill-/Tour-Einträge nutzen das bereits eingebettete `_user_display`.

**Merge:** Alle Quellen → `[ActivityFeedItem]`, absteigend nach `date`, publiziert als `recentActivity` (ersetzt `recentSales` als View-Quelle; `recentSales` kann intern bestehen bleiben).

**Erschöpfung (`hasMoreSales` → `hasMoreActivity`):** Wie heute per Anzahl-Vergleich, aber über die Summe der **rohen Quell-Zeilen** (Sales + activity_log-Zeilen + Transaktions-Zeilen), nicht über die gemergte Item-Anzahl — neue Transaktionen, die in eine bestehende Rand-`IntakeGroup` einfließen, würden die Merge-Anzahl sonst unverändert lassen und fälschlich „erschöpft" signalisieren. Recovery bei Realtime-Zuwachs bleibt erhalten.

**Fehlerverhalten:** Wie heute — schlägt eine der drei Quellen fehl, schlägt der gesamte Load fehl (Fenster-Revert + `error`, bestehendes Muster). Kein Degradieren auf Sales-only.

## 3. Neue Schreibpfade

### 3.1 `tour_started`-Event (iOS + PWA)

Geschrieben in `startTour()`, aber erst **nachdem die Lager-Ausbuchungen erfolgreich waren** (also wenn die Tour tatsächlich in den Refill-Schritt übergeht) — sonst stünde bei einem Ausbuchungs-Fehler ein verwaister „Tour gestartet"-Eintrag im Feed. Genau einmal pro Tour: der Resume-Pfad einer gespeicherten Tour ruft `startTour()` nicht erneut auf.

- **iOS:** in `RefillWizardViewModel.startTour()` nach erfolgreichem `deductWarehouseStock`. Die bestehende `writeActivityLog`-Hilfsfunktion wird generalisiert (machineId optional), Schreiben non-blocking wie bisher.
- **PWA:** in `useRefillWizard.startTour()` nach erfolgreichen Deductions, Insert in `activity_log` nach dem Muster der bestehenden Refill-Inserts.

Eintragsformat:

```
entity_type: 'stock'
entity_id:   <tour_id>
action:      'tour_started'
metadata: {
  tour_id, machine_count,
  machine_ids: [...], machine_names: [...],   // die eingeplanten (gepackten) Automaten
  warehouse_id?, warehouse_name?,
  _user_display, _user_email
}
```

### 3.2 Tour ↔ Lager-Ausbuchung verknüpfen

Beide Clients ergänzen die `tour_id` im bestehenden `p_metadata`-Objekt der `deduct_warehouse_stock_fifo`-Aufrufe (PWA `useRefillWizard.ts` ~Z.583, iOS `RefillWizardViewModel.deductWarehouseStock()` ~Z.1724):

```
p_metadata: { _user_email, tour_id: <tour_id> }
```

Rein additiv (jsonb), keine Funktions- oder Schemaänderung. Eine spätere Touren-Übersicht kann darüber exakt nachvollziehen, was in welcher Tour ausgebucht wurde.

### 3.3 PWA-Kosmetik

`useActivityLog.actionLabel` bekommt ein Mapping `tour_started: 'Tour started'`. Der PWA-Dashboard-Feed zeigt neue Events automatisch (liest alle `activity_log`-Einträge).

## 4. UI (DashboardView)

- Sektionstitel: **„Letzte Aktivität" / "Recent Activity"**.
- Tagesgruppierung und `DaySectionHeader` bleiben; der Zähler zählt künftig **alle** Einträge des Tages.
- **Sale-Zeile:** unverändert (`RecentSaleRow`, Tap → ProductDetailSheet).
- **Neue Zeilen** im selben visuellen Rhythmus (36-pt-Leading, Titel, Caption, Zeit rechts), je ein getöntes SF-Symbol im Kreis statt Produktbild:
  - **Tour gestartet** (z. B. `figure.walk`/`map`, Indigo): Titel „Tour gestartet", Untertitel „{Nutzer} · {N} Automaten" — Tap klappt die Automatenliste auf
  - **Automat gefüllt** (`shippingbox.fill`, Grün): Titel = Maschinenname, Untertitel „Gefüllt von {Nutzer} · {N} Artikel" — Tap klappt die Produktliste (Name × Menge) auf
  - **Ware eingebucht** (`tray.and.arrow.down.fill`, Orange): Titel „Ware eingebucht", Untertitel „{Nutzer} · {N} Produkte · {Lager}" — Tap klappt die Produktliste auf
- Aufklappen ist ein lokaler `@State`-Toggle pro Zeile (Set expandierter IDs), kein Nachladen — alle Details stecken bereits in den geladenen Daten.

## 5. Endlos-Liste

- `loadMoreButton` entfällt. Ans Ende des `LazyVStack` kommt ein Sentinel-View: solange `hasMoreActivity`, ein kleiner zentrierter `ProgressView`, dessen `.onAppear` `loadMoreRecentActivity()` auslöst (Guards: nicht bereits ladend, `hasMoreActivity == true`).
- Fenstermechanik unverändert: heute → 7 → 14 → 21 Tage …; Fehler/Cancellation setzen das Fenster zurück (bestehende Logik).
- Da der Sentinel in einem `LazyVStack` liegt, erscheint er erst beim Scrollen ans Ende; bei anfangs (fast) leerem Feed lädt er automatisch nach, bis der Bildschirm gefüllt oder die Historie erschöpft ist — gewünschtes Verhalten.
- Bei erschöpfter Historie verschwindet der Sentinel ersatzlos.

## 6. Realtime

- `RealtimeService` erhält `activityVersion` (+ Listener/Consumer für `activity_log`-INSERTs nach bestehendem Muster) — Touren/Refills erscheinen live; die Publication enthält die Tabelle bereits.
- `DashboardView.realtimeVersion` nimmt `activityVersion` mit auf.
- `warehouse_transactions` bleibt ohne Realtime (nicht in der Publication; Migration dafür ist den Nutzen nicht wert). Einbuchungen erscheinen beim nächsten Reload/Pull-to-Refresh.

## 7. i18n

Neue Keys in `Localizable.xcstrings` (en + de), u. a.: "Recent Activity"/„Letzte Aktivität", "Tour started"/„Tour gestartet", "Filled by %@ · %lld items"/„Gefüllt von %@ · %lld Artikel", "Stock intake"/„Ware eingebucht", "%lld machines"/„%lld Automaten", "%lld products"/„%lld Produkte". Die Datei hat uncommittete Änderungen — Keys additiv ergänzen, nichts reformatieren.

## 8. Kompatibilität & Risiken

- **Keine DB-Migration.** Neue `action`-Strings und jsonb-Metadatenfelder sind additiv; RLS-Policies decken alle Reads (Company-Scope) ab.
- Alte App-/PWA-Versionen schreiben kein `tour_started` und keine `tour_id` in Ausbuchungen — der Feed zeigt für solche Touren schlicht keinen Start-Eintrag. Nichts bricht.
- `stock_refill_tour_skip`, `stock_updated`, `stock_refill_all` u. a. erscheinen bewusst **nicht** im Feed (Rauschen); Erweiterung später möglich.
- Mehrkosten: zwei zusätzliche, kleine Fenster-Queries pro Dashboard-Load — vernachlässigbar gegenüber den bestehenden Sales-Queries.

## 9. Tests / Verifikation

- **PWA:** Der `tour_started`-Payload-Builder wird als reine Helper-Funktion extrahiert und per Vitest getestet (bestehende Composable-Test-Muster wiederverwenden).
- **iOS:** Es existiert kein Unit-Test-Target; Merge- und Gruppierungslogik (Intake-Sessions, Erschöpfungslogik) als reine, von SwiftUI unabhängige Funktionen im ViewModel strukturieren. Verifikation manuell: Build + Simulator (Feed mit Bestandsdaten rückwirkend prüfen, Tour starten → Live-Eintrag, Einbuchung → nach Refresh sichtbar, Scrollen lädt Fenster nach, Erschöpfung beendet das Nachladen).
