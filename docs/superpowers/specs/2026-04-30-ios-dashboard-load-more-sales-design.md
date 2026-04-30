# iOS Dashboard — "Load More" für Recent Sales

**Date:** 2026-04-30
**Surface:** `ios/VMflow` (SwiftUI native iOS app)
**Affected files:** `DashboardViewModel.swift`, `DashboardView.swift`

## Goal

Auf der iOS-Dashboard-Seite zeigt die "Recent Sales"-Sektion zurzeit nur die letzten 10 Sales (gefetcht werden 20). Ziel: Eine zeit-basierte "Mehr laden"-Funktion, mit der man theoretisch unbegrenzt weit in die Vergangenheit zurück scrollen kann.

## Non-Goals

- Keine Pagination oder "Load more" auf anderen Listen (Sales-Detail-Seite, Inbox, etc.) — nur die Dashboard-"Recent Sales".
- Kein Cursor-basiertes Append (siehe "Alternatives Considered").
- Kein Persisting des Pagination-State über App-Sessions hinweg — nach App-Restart startet die Liste wieder bei "heute".
- Keine Änderungen am Realtime-Mechanismus selbst, nur am Verhalten von `loadDashboard()`.

## User-facing Behavior

**Initial-State (nach App-Start oder Pull-to-Refresh):**
Die Recent-Sales-Sektion zeigt **alle Sales von heute**, gruppiert nach Tag (in dem Fall nur "Today"-Section).

**Tap auf "Mehr laden":**
- 1. Tap → Fenster wächst auf **die letzten 7 Tage** (heute + 6 Tage zurück)
- 2. Tap → **letzte 14 Tage** (heute + 13 zurück)
- 3. Tap → **letzte 21 Tage**
- N. Tap (N≥1) → letzte (7×N) Tage, also `daysBack = 7N − 1` (Tage rückwärts vom Start of Today)

Die Tag-Gruppierung ("Today", "Yesterday", "Wednesday, 23 April", …) wird wie bisher gerendert.

**Edge-Cases:**
- Wenn ein Tap keinen einzigen neuen Sale liefert → Button verschwindet (Historie ausgeschöpft).
- Wenn heute null Sales sind → "No recent sales"-Text wie bisher, **aber** der "Mehr laden"-Button wird trotzdem angezeigt (sofern noch Historie existiert).
- Während des Ladens: Button disabled + ProgressView ersetzt das Icon.

**Realtime-Verhalten:**
Wenn ein neuer Sale via `RealtimeService` reinkommt (ausgelöst über `onChange(of: realtimeVersion)`), wird `loadDashboard()` aufgerufen. Das aktuelle `recentSalesDaysBack`-Window bleibt **erhalten** — der Nutzer verliert seinen "Mehr laden"-Fortschritt nicht.

## Architecture

### Pagination-Strategie: Window Re-Fetch

Bei jedem Tap auf "Mehr laden" wird die **gesamte sichtbare Zeitspanne** neu vom Server gefetcht und ersetzt die bisherige `recentSales`-Liste. Es wird kein Cursor-State gehalten und keine Append-Logik benötigt.

```
Initial:    SELECT … WHERE created_at >= start_of_today
Tap 1:      SELECT … WHERE created_at >= start_of_today − 6 days
Tap 2:      SELECT … WHERE created_at >= start_of_today − 13 days
Tap N≥1:    SELECT … WHERE created_at >= start_of_today − (7N−1) days
```

**Warum Re-Fetch statt Cursor-Append:**
Datenvolumen sind klein (~50 Sales/Tag/Company in Production). Selbst ein Jahres-Fenster wären ~18.000 Rows — Postgres handelt das in <100 ms; das Netzwerk ist der Flaschenhals und ~18 k Sales-Records sind über LTE noch okay (≪ 1 MB JSON). Ein Cursor-basierter Append-Ansatz wäre komplexer (Merge-Logik, Realtime-Sonderfall) ohne realen Performance-Gewinn.

### State im ViewModel

Neue `@Published`-Properties in `DashboardViewModel`:

```swift
/// Wie viele Tage rückwärts vom Start of Today das Fenster reicht.
/// 0 = nur heute; 6 = letzte 7 Tage; 13 = letzte 14 Tage; …
@Published var recentSalesDaysBack: Int = 0

/// Wird false, wenn ein "Mehr laden"-Tap keinen neuen Sale liefert.
@Published var hasMoreSales: Bool = true

/// True während eines "Mehr laden"-Fetch — Button-Spinner-State.
@Published var isLoadingMoreSales: Bool = false
```

Neue Methode:

```swift
func loadMoreRecentSales() async {
    guard !isLoadingMoreSales, hasMoreSales else { return }

    let nextDaysBack = recentSalesDaysBack == 0 ? 6 : recentSalesDaysBack + 7
    isLoadingMoreSales = true
    defer { isLoadingMoreSales = false }

    let countBefore = recentSales.count
    recentSalesDaysBack = nextDaysBack

    do {
        try await loadRecentSales()
        if recentSales.count == countBefore {
            hasMoreSales = false
        }
    } catch {
        // Auf Fehler: Fenster zurücksetzen, damit ein erneuter Tap es nochmal versucht
        recentSalesDaysBack = recentSalesDaysBack == 6 ? 0 : recentSalesDaysBack - 7
        self.error = error.localizedDescription
    }
}
```

Umbau von `loadRecentSales()`:
- Statt `.limit(20)` → `.gte("created_at", value: ...)` mit dem berechneten Window-Start.
- Window-Start: `Calendar.current.date(byAdding: .day, value: -recentSalesDaysBack, to: Calendar.current.startOfDay(for: Date()))!`.
- Bei `recentSalesDaysBack == 0` ist Window-Start exakt `start_of_today` → die Query liefert nur heutige Sales (keine letzten 24 h, sondern alles seit Mitternacht).
- Kein Limit mehr — alle Sales im Zeitfenster werden geladen.
- Order bleibt `.order("created_at", ascending: false)`.

`loadRecentSales()` bleibt `private` — wird ausschließlich von `loadDashboard()` (parallel via `async let`) und von `loadMoreRecentSales()` aufgerufen, beide leben in der gleichen Klasse.

**Concurrency:** Wenn ein Realtime-Trigger während eines laufenden `loadMoreRecentSales`-Calls feuert, läuft `loadDashboard()` parallel und kann auf `recentSales` racen. Das ist konsistent mit dem bestehenden Verhalten (Dashboard-Reloads stacken bereits via Realtime); akzeptiert wird *last-write-wins* auf `recentSales`. SwiftUI canceled bestehende `refreshable`-Tasks bei Bedarf via `CancellationError`.

`loadDashboard()` ändert sich konzeptionell nicht — `loadRecentSales()` wird wie gehabt parallel aufgerufen und nutzt automatisch den aktuellen `recentSalesDaysBack`-Wert.

**Wichtig:** `loadDashboard()` setzt `recentSalesDaysBack` und `hasMoreSales` **nicht** zurück. Damit:
- Pull-to-Refresh: lädt das aktuelle Fenster neu (User-Erwartung, da sie das Fenster bewusst gesetzt haben).
- Realtime-Trigger: lädt das aktuelle Fenster neu, ohne den State zu resetten.
- App-Restart resettet implizit (frisches `DashboardViewModel` mit `daysBack = 0`).

**`hasMoreSales` Recovery:** Wenn ein Reload (Pull-to-Refresh oder Realtime) **mehr** Sales zurückbringt als zuvor (z. B. neuer Sale via Realtime kam rein, oder ein Backfill), wird `hasMoreSales = true` gesetzt — egal ob es vorher false war. Das verhindert, dass der Button für immer verschwindet, wenn das Konto initial leer war und später Sales reinkommen.

### UI in `DashboardView`

Änderungen in `recentSalesSection`:

1. **`prefix(10)`-Cap entfernen:** Die View rendert alle `viewModel.recentSales`. Die Begrenzung kommt jetzt aus dem Zeitfenster, nicht aus einem hartem Slice.

2. **"Mehr laden"-Button am Ende der Sektion:**
   - Nur sichtbar, wenn `viewModel.hasMoreSales == true`.
   - Zentriert, mit `.bordered`-Style (subtiler als die Quick-Actions).
   - Während Load (`isLoadingMoreSales`): disabled, Icon ersetzt durch `ProgressView`.
   - Caption darunter zeigt das nächste Fenster: "Letzte 7 Tage anzeigen" / "Letzte 14 Tage anzeigen" / …

3. **Wenn `hasMoreSales == false`:** Button verschwindet komplett (kein Footer-Text, silent end).

Pseudocode:

```swift
private var recentSalesSection: some View {
    VStack(alignment: .leading, spacing: 12) {
        Text("Recent Sales").font(.headline)

        if viewModel.recentSales.isEmpty && !viewModel.isLoading {
            Text("No recent sales")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 20)
        } else {
            let grouped = groupDashboardSalesByDay(viewModel.recentSales)
            ForEach(grouped, id: \.date) { group in
                DaySectionHeader(label: dayLabel(for: group.date), count: group.sales.count)
                ForEach(group.sales) { item in
                    RecentSaleRow(item: item)
                }
            }
        }

        if viewModel.hasMoreSales {
            loadMoreButton
        }
    }
    .padding(16)
    .background(...)
}

private var loadMoreButton: some View {
    let nextDaysTotal = viewModel.recentSalesDaysBack == 0 ? 7 : (viewModel.recentSalesDaysBack + 1) + 7
    return VStack(spacing: 4) {
        Button {
            Task { await viewModel.loadMoreRecentSales() }
        } label: {
            HStack(spacing: 6) {
                if viewModel.isLoadingMoreSales {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.down.circle")
                }
                Text("Load more")
            }
        }
        .buttonStyle(.bordered)
        .disabled(viewModel.isLoadingMoreSales)

        Text("Show last \(nextDaysTotal) days")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 8)
}
```

**i18n-Konvention:** Base-Sprache der iOS-App ist Englisch — die Strings "Load more", "Show last X days" werden mit `String(localized: ...)` deklariert. Lokalisierte deutsche Varianten ("Mehr laden", "Letzte X Tage anzeigen") werden über `.strings`-Files / String Catalog gepflegt, konsistent mit den restlichen Dashboard-Strings ("Today", "Yesterday", "No recent sales", "Recent Sales", "Loading dashboard...").

## Data Flow

```
User-Aktion                      ViewModel-State                    Server-Query
──────────────────               ────────────────                   ────────────────────────────
App startet / Login    →         daysBack=0, hasMore=true     →    created_at >= start_of_today
                       ←         recentSales = [today's sales]
                       
User tippt "Mehr laden" →        isLoadingMoreSales=true
                                 daysBack=6                   →    created_at >= start_of_today − 6d
                       ←         recentSales = [last 7d sales]
                                 isLoadingMoreSales=false
                                 hasMoreSales=true (sofern neue Sales dabei waren)
                                 
User tippt nochmal      →        daysBack=13                  →    created_at >= start_of_today − 13d
                       ←         recentSales = [last 14d sales]

…irgendwann erreicht User die älteste Sale-Historie:
User tippt nochmal      →        daysBack=N+7
                       ←         recentSales = [N alte Sales] (gleiche Zahl wie vorher)
                                 hasMoreSales=false
                                 → Button verschwindet

Realtime: neuer Sale kommt rein
RealtimeService          →       loadDashboard()              →    created_at >= start_of_today − (current daysBack)
                       ←         recentSales aktualisiert, daysBack unverändert
```

## Error Handling

- **Server-Fehler beim "Mehr laden":** `recentSalesDaysBack` wird zum vorherigen Wert zurückgesetzt, damit ein erneuter Tap die gleiche Aktion wiederholt. Die `error`-Property wird gesetzt (aber nicht weiter UI-mäßig hervorgehoben — das bestehende Dashboard zeigt Errors auch nur über `error.localizedDescription`).
- **CancellationError:** Bestehender Pattern in `loadDashboard` (catch is CancellationError) bleibt — falls SwiftUI die Task während eines Refresh canceled, ist das kein User-Error.
- **Empty result auf erstem Tap (heute hat keine Sales und letzte 7 Tage auch keine):** `hasMoreSales` wird false, Button verschwindet. Recovery: Sobald via Realtime oder Pull-to-Refresh ein neuer Sale ins Window fällt und `recentSales.count` größer wird, wird `hasMoreSales = true` zurückgesetzt (siehe "`hasMoreSales` Recovery" oben). Im Worst Case (Account hat permanent null Sales) startet App-Restart implizit auch wieder bei 0.

## Testing Strategy

Manual QA-Checkliste (kein Vitest-Setup für die iOS App in diesem Repo):

1. **Initial-Load:** Dashboard öffnen → nur heutige Sales sichtbar, "Mehr laden"-Button mit Caption "Letzte 7 Tage anzeigen".
2. **1. Tap:** Button → Spinner kurz sichtbar → Liste wächst auf 7 Tage, neue Caption "Letzte 14 Tage anzeigen".
3. **Mehrere Taps:** N Taps führen zu N×7 Tagen sichtbar, Caption inkrementiert korrekt.
4. **End-of-History:** Mit Test-Account, der nur ~10 Tage Sales hat → nach genug Taps verschwindet der Button.
5. **Empty Today:** Mit Account ohne heutige Sales → "No recent sales" + Button trotzdem sichtbar → Tap lädt ältere Sales.
6. **Realtime-Preserve:** Window auf 14 Tage expandieren → manuell einen Sale via Backend einfügen → Realtime triggert reload → Window bleibt 14 Tage, neuer Sale erscheint in "Today".
7. **Pull-to-Refresh:** Window auf 14 Tage → Pull-to-Refresh → Liste lädt das 14-Tage-Fenster neu (Window bleibt erhalten).
8. **Network-Error:** Airplane-Mode-Simulation während Tap → Error wird in `viewModel.error` gesetzt, Window-State wird zurückgesetzt, erneuter Tap funktioniert.

## Alternatives Considered

### A) Cursor-basiertes Append
Statt das gesamte Window neu zu laden, würde jeder Tap nur die "neuen 7 Tage" laden und an die bestehende Liste anhängen. State: `oldestLoadedDate`-Cursor.
- **Pro:** Effizienter bei sehr großen Datenmengen.
- **Con:** Zusätzliche Merge-Logik; Realtime-Verhalten wird komplexer (heutiger Tag muss separat refresht werden, ohne ältere Daten zu verlieren); mehr Edge-Cases.
- **Verworfen:** Datenvolumen (~50 Sales/Tag/Company) machen diese Optimierung überflüssig (YAGNI). Re-Fetch des gesamten Fensters ist auch bei einem Jahres-Window unter 1 MB JSON über LTE.

### B) Klassisches Offset-Pagination (`limit + offset`)
Wie auf der Web-Frontend-Seite: pro Tap +20 Sales mehr.
- **Pro:** Simpel, keine Date-Math.
- **Con:** Passt nicht zur User-Anforderung ("alle heutigen Sales", "letzte 7 Tage"). Offset-Pagination ist kontextlos — der User würde Sale 21–40 sehen ohne Bezug zu Tagen, was die existierende Tag-Gruppierung visuell zerschießt.
- **Verworfen:** Widerspricht der expliziten User-Spec.

### C) Rein-clientseitiges Filtering eines initial großen Fetches
Initial alle Sales der letzten 90 Tage laden, dann clientseitig filtern.
- **Pro:** Keine Server-Roundtrips bei "Mehr laden".
- **Con:** Initial-Load-Cost steigt deutlich für alle User, auch die die nie "Mehr laden" tippen. Memory-Footprint wächst.
- **Verworfen:** Pessimiert den Common-Case (User tippt nie "Mehr laden").

## Open Questions

Keine — Design ist mit Nutzer in Sektionen 1–3 des Brainstormings explizit abgenickt.

## Out of Scope (Future Work)

- "Weniger anzeigen"-Button um das Window wieder zu verkleinern.
- Persisting des Window-State über App-Sessions (z. B. in `UserDefaults`).
- Datums-Picker, mit dem User direkt zu einem Tag springen können.
- Performance-Optimierung via Cursor-Append, falls Datenvolumen das jemals nötig macht.
- "Mehr laden" auf anderen Listen (Inbox, Machine-Detail-Sales).
