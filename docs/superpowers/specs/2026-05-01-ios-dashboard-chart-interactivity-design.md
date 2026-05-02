# iOS Dashboard Chart — Interactivity, Average Line, Weekend Highlight

**Date:** 2026-05-01
**Surface:** `ios/VMflow` (SwiftUI native iOS app)
**Affected files:** `DashboardView.swift`, `DashboardViewModel.swift`, `Localizable.xcstrings`

## Goal

Erweitere das einzige Diagramm der iOS-App — die "Revenue (30 days)"-Bar-Chart auf dem Dashboard — um drei Features:

1. **Drag-to-Scrub-Tooltip** — Finger auf das Chart legen und nach links/rechts ziehen → Tooltip folgt zur jeweils nächsten Säule mit Datum, Umsatz und Anzahl Verkäufe.
2. **Durchschnitts-Linie** — gestrichelt orange, zeigt den Tagesdurchschnitt über alle 30 Tage (inkl. Null-Tagen) mit "Ø XX,XX €"-Beschriftung.
3. **Wochenend-Hervorhebung** — Sa+So-Säulen werden in einem helleren / desaturierten Blau gerendert, um Wochenenden visuell von Werktagen abzuheben.

## Non-Goals

- Keine zusätzlichen Charts. Es existiert genau ein Diagramm im iOS-App; `MachineDetailView.swift:2` importiert `Charts` ungenutzt — wird in dieser Spec nicht angefasst (Nebenaufgabe).
- Kein neuer Datenfetch. Avg + Wochenend-Flag werden aus dem bestehenden `dailySales`-Array berechnet.
- Keine Persistierung des selektierten Tages über App-Sessions hinweg.
- Kein Tap-to-Pin. Der Tooltip ist transient — verschwindet sobald der Finger losgelassen wird (drag-to-scrub-only).
- Kein Long-Press, kein Doppel-Tap, kein Force-Touch.
- Keine Sharing-Action ("Tag teilen"), kein Drill-Down zur Detail-Seite des Tages.

## User-facing Behavior

**Initial-State (nach Dashboard-Load):**
- Chart zeigt 30 Säulen wie bisher
- Wochenend-Säulen (Sa, So) sind in `Color.blue.opacity(0.45)` gerendert; Werktage in `Color.blue` (existing)
- Eine horizontale gestrichelte orangene Linie liegt auf Höhe `Σrevenue / 30` mit Beschriftung `"Ø 47,50 €"` (Beispielwert) rechts oben
- Kein Tooltip sichtbar

**Drag-to-Scrub:**
- Nutzer legt Finger irgendwo auf das Chart und zieht
- Eine vertikale graue Hilfslinie (`Color.gray.opacity(0.35)`) folgt dem Finger und rastet auf den nächsten Tag
- Über der getroffenen Säule erscheint ein Tooltip-Popover mit:
  ```
  Mi, 15. Apr
  Umsatz       78,50 €
  Verkäufe     23
  ```
- Beim Ziehen über andere Tage wird die Hilfslinie + Tooltip mit `.smooth`-Animation auf den nächsten Tag verschoben
- Sobald der Finger das Chart verlässt → Hilfslinie + Tooltip verschwinden

**Edge-Cases:**
- **Leere Daten** (`dailySales.isEmpty`): wie bisher graue "No sales data"-Box. Weder Avg-Linie noch Tooltip rendern.
- **Alle 30 Tage Null Umsatz**: `dailyAverage = 0` — Avg-Linie liegt auf der x-Achse, ist optisch unauffällig (akzeptabel).
- **Scrub auf Null-Tag**: Tooltip zeigt "Mi, 15. Apr / Umsatz 0,00 € / Verkäufe 0". Kein Special-Case.
- **Tooltip am Rand**: `overflowResolution: .init(x: .fit(to: .chart), y: .disabled)` clipped den Tooltip horizontal an den Chart-Rand, damit er nicht überlappt.

## Architecture

**Deployment-Target:** iOS 17+ (verifiziert in `ios/project.yml:5` → `iOS: "17.0"`). Damit sind die genutzten neuen APIs (`chartXSelection(value:)`, `RuleMark.annotation(overflowResolution:)`, `Animation.smooth`) verfügbar.

### Chart-Aufbau (`DashboardView.swift::chartSection`)

Bestehendes `Chart(viewModel.dailySales) { day in BarMark(...) }` wird ersetzt durch ein erweitertes Chart-Block. Die existierende Säulenfarbe `.blue.gradient` bleibt erhalten — Wochenend-Säulen verwenden `Color.blue.opacity(0.45).gradient` (gleicher Gradient-Effekt, niedrigerer Grundton):

```swift
Chart {
    ForEach(viewModel.dailySales) { day in
        BarMark(
            x: .value("Date", day.date, unit: .day),
            y: .value("Revenue", day.revenue)
        )
        .foregroundStyle(day.isWeekend ? Color.blue.opacity(0.45).gradient : Color.blue.gradient)
        .cornerRadius(3)
    }

    // Average line + label
    if viewModel.dailyAverage > 0 {
        RuleMark(y: .value("Avg", viewModel.dailyAverage))
            .foregroundStyle(.orange)
            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            .annotation(position: .topTrailing, alignment: .trailing, spacing: 2) {
                Text("Ø \(formatCurrency(viewModel.dailyAverage))")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
            }
    }

    // Drag-to-scrub selection indicator + tooltip
    if let selectedDate, let day = selectedDay {
        RuleMark(x: .value("Selected", day.date, unit: .day))
            .foregroundStyle(.gray.opacity(0.35))
            .annotation(
                position: .top,
                alignment: .center,
                spacing: 4,
                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
            ) {
                tooltipView(for: day)
            }
    }
}
.chartXSelection(value: $selectedDate)
.chartXAxis { /* unchanged */ }
.chartYAxis { /* unchanged */ }
.frame(height: 200)
.animation(.smooth, value: selectedDate)
```

### State

Im View:
```swift
@State private var selectedDate: Date?

private var selectedDay: DailySales? {
    guard let selectedDate else { return nil }
    return viewModel.dailySales.first {
        Calendar.current.isDate($0.date, inSameDayAs: selectedDate)
    }
}
```

### Computed Properties (`DashboardViewModel.swift`)

```swift
/// Average daily revenue over the loaded daily-chart window, including zero-revenue days.
/// Σ revenue / dailySales.count. The header says "30 days" but loadDailyChart() actually
/// pre-populates 31 daily buckets (`for dayOffset in 0..<31`, today + 30 prior). We divide
/// by the actual array count so the average matches what's visually rendered, regardless
/// of any future fence-post fix.
var dailyAverage: Double {
    guard !dailySales.isEmpty else { return 0 }
    return dailySales.reduce(0) { $0 + $1.revenue } / Double(dailySales.count)
}
```

### Model Extension (`ios/VMflow/Models/Sale.swift`)

`DailySales` ist als `struct DailySales: Identifiable, Equatable` an `Sale.swift:57` deklariert. Die `isWeekend`-Property kommt als Extension direkt unter den Struct in derselben Datei:

```swift
extension DailySales {
    var isWeekend: Bool {
        Calendar.current.isDateInWeekend(date)
    }
}
```

`Calendar.current.isDateInWeekend(_:)` respektiert die User-Locale — in DE/US Sa+So. Akzeptabel für unseren Use-Case.

### Tooltip-Subview

```swift
@ViewBuilder
private func tooltipView(for day: DailySales) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(formatTooltipDate(day.date))
            .font(.caption.weight(.semibold))
        HStack(spacing: 12) {
            Text("Revenue")
                .foregroundStyle(.secondary)
            Spacer()
            Text(formatCurrency(day.revenue))
                .monospacedDigit()
        }
        .font(.caption2)
        HStack(spacing: 12) {
            Text("Sales")
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(day.count)")
                .monospacedDigit()
        }
        .font(.caption2)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background {
        RoundedRectangle(cornerRadius: 8)
            .fill(.regularMaterial)
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }
    .frame(minWidth: 140)
}

private func formatTooltipDate(_ date: Date) -> String {
    // Date.FormatStyle is locale-aware out of the box (iOS 15+). Produces:
    // - en: "Wed, 15 Apr"
    // - de: "Mi., 15. Apr."
    return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
}
```

`"Revenue"` und `"Sales"` werden mit `String(localized:)` bzw. SwiftUI's automatischer `LocalizedStringKey`-Extraktion behandelt — Strings landen ins Catalog (siehe i18n-Sektion).

## Data Flow

```
Load Dashboard
     │
     ▼
loadDailyChart() pre-populates 30 days       (existing)
     │
     ▼
dailySales = [(date, revenue, count)] × 30   (existing — no schema change)
     │
     ├──► dailyAverage (computed)            (new)
     ├──► day.isWeekend (computed per-day)   (new)
     │
     ▼
Chart renders:
  - 30 BarMarks                              (color depends on isWeekend)
  - 1 RuleMark for avg                       (new, gated on avg > 0)
  - 0 or 1 RuleMark for selection            (new, gated on selectedDate != nil)
     │
     ▼
User drags finger across chart
     │
     ▼
.chartXSelection(value: $selectedDate)       (iOS 17+ built-in API)
     │
     ▼
selectedDate updates → SwiftUI re-renders the selection RuleMark + tooltip
     │
     ▼
Finger lifts → selectedDate = nil → selection RuleMark disappears
```

## i18n

Zwei neue Strings ins `Localizable.xcstrings`:

| Source key (en) | de translation |
|-----------------|----------------|
| `Revenue`       | `Umsatz`       |
| `Sales`         | `Verkäufe`     |

Die Avg-Beschriftung "Ø XX,XX €" wird via `"Ø \(formatCurrency(...))"` direkt im Swift-Code zusammengesetzt — der Text "Ø " ist ein Symbol und nicht übersetzungsbedürftig, der Currency-Teil rendert via existierendem `NumberFormatter` mit `.currency`-Style locale-aware (en: "Ø €47.50", de: "Ø 47,50 €").

Datums-Format via `Date.FormatStyle` (`.dateTime.weekday(.abbreviated).day().month(.abbreviated)`) ist out-of-the-box locale-aware: "Wed, 15 Apr" (en) / "Mi., 15. Apr." (de). Kein Catalog-Eintrag nötig.

## Error Handling

- Es gibt nichts zu fehlen. Der Tooltip ist eine pure UI-Berechnung über schon im Speicher befindliche Daten.
- Wenn `selectedDate` einen Wert annimmt, der nicht zu einem Tag in `dailySales` matcht (sollte nicht passieren, weil `chartXSelection` auf die Chart-Daten snappt), zeigt `selectedDay = nil` → Tooltip rendert nicht. Akzeptable Defensive.

## Testing Strategy

Manual QA-Checkliste (kein XCTest-Setup für die iOS-App in diesem Repo):

1. **Initial-Load:** Dashboard öffnen → Chart zeigt 30 Säulen, Wochenend-Säulen sind erkennbar heller, gestrichelte orange Avg-Linie + "Ø XX,XX €"-Label rechts oben sichtbar.
2. **Drag-to-Scrub:** Finger auf das Chart legen → graue vertikale Linie + Tooltip erscheinen, beide rasten auf den nächsten Tag.
3. **Scrubben:** Finger nach rechts/links ziehen → Tooltip wandert smooth zur nächsten Säule mit aktualisierten Werten.
4. **Lift:** Finger loslassen → Hilfslinie + Tooltip verschwinden.
5. **Tooltip-Inhalt:** Korrekt formatiertes Datum (locale-aware), Umsatz mit zwei Nachkommastellen + €-Symbol, Verkaufsanzahl als Integer.
6. **Null-Tag scrubben:** Tooltip zeigt "0,00 €" und "0".
7. **Edge-Lokationen:** Scrubben auf den ersten und letzten Tag → Tooltip wird nicht am Chart-Rand abgeschnitten.
8. **Avg-Linien-Korrektheit:** Avg-Linie liegt sichtbar auf der korrekten Y-Höhe (manuell verifizierbar: Σrevenue / 30 ≈ angezeigter Wert).
9. **Wochenend-Erkennung:** Sa und So sind heller, alle anderen Tage normal blau (verifizierbar gegen Kalender).
10. **Empty-State:** Mit Test-Account ohne 30-Tage-Sales → graue "No sales data"-Box, weder Avg-Linie noch Tooltip rendern.
11. **Locale-Switch:** Simulator auf Deutsch → "Umsatz" / "Verkäufe" / "Mi., 15. Apr." (statt "Revenue" / "Sales" / "Wed, 15 Apr").

## Alternatives Considered

### A) Tap-to-Pin statt Drag-to-Scrub
Eine Säule antippen → Tooltip pinnt; Tap außerhalb dismisst.
- **Pro:** Diskoverabel, einfacher zu lernen, Screenshot-fähig.
- **Con:** Weniger iOS-nativ; weniger "natural feel" als die Health-/Stocks-App-Geste; bei 30 schmalen Säulen ist Tap-Präzision schwierig (Säule ist <15pt breit auf einem iPhone).
- **Verworfen:** Nutzer hat im Brainstorming für die nativere Variante (B = Drag-to-Scrub) entschieden.

### B) Hybrid (Tap pinnt, Drag scrubbt)
Standard-Swift-Charts-Pattern.
- **Pro:** Beide Welten.
- **Con:** Mehr Komplexität (zwei Gestures verwalten); für ein Dashboard-Quick-Look-Chart Overkill.
- **Verworfen:** YAGNI.

### C) Wochenend-Hintergrund-Bänder statt Säulenfarbe
Subtiles graues Rechteck im Chart-Hintergrund hinter Sa+So.
- **Pro:** Trennt Visual aus den Daten heraus; Säulenfarbe bleibt einheitlich.
- **Con:** Weniger auffällig auf kleinen Screens; Avg-Linie liegt im Hintergrund-Band und konkurriert.
- **Verworfen:** Nutzer hat Variante B (gefärbte Wochenend-Säulen) gepickt.

### D) Avg nur über Tage mit ≥1 Verkauf
`Σrevenue / count(daysWithSales)`.
- **Pro:** "Typischer Verkaufstag-Umsatz"; relevanter wenn Maschinen oft an einigen Tagen aus sind.
- **Con:** Bias nach oben; weniger ehrliche Zahl für Forecast/Planung.
- **Verworfen:** Nutzer wählte A (alle 30 Tage inkl. Nullen) im Brainstorming.

## Open Questions

Keine — alle drei Brainstorming-Sektionen wurden vom Nutzer abgenickt.

## Out of Scope (Future Work)

- Toten `import Charts` aus `MachineDetailView.swift:2` entfernen (aufräumen).
- Tooltip um zusätzliche Felder erweitern (z. B. "vs. Vortag", "Top-Produkt").
- Drill-Down vom Tooltip auf eine Tagesdetail-Seite.
- Sharing-Action ("Tag teilen").
- Vergleichs-Linie (z. B. "Avg letzte 7 Tage" zusätzlich zum 30-Tages-Avg).
- Variable Window-Größe (7d, 30d, 90d-Toggle).
- Export oder Screenshot des Charts.
