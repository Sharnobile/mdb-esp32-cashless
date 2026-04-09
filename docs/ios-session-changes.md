# iOS App Changes — Session 2026-04-09

Reference for implementing the same features on Android (Jetpack Compose).

## 1. Push Notification APNs Fix (Backend + iOS)

**Problem:** `DeviceTokenNotForTopic` error — debug builds use different bundle ID than release.

**Solution:** Store `apns_topic` (bundle ID) per push subscription and use it when sending.

**Files:**
- `Docker/supabase/migrations/20260409100000_push_subscriptions_add_apns_topic.sql` — adds `apns_topic text` column
- `Docker/supabase/functions/register-push/index.ts` — stores `bundle_id` from request body as `apns_topic`
- `Docker/supabase/functions/_shared/web-push.ts` — uses per-subscription `apns_topic` when sending APNs
- `ios/VMflow/Services/NotificationService.swift` — sends `Bundle.main.bundleIdentifier` during registration

**Android equivalent:** Send the FCM sender ID / package name during push registration. FCM doesn't have the same topic issue, but storing the package name is still useful for debug/release distinction.

## 2. Tab Bar Restructure

**Layout:** 4 tabs — Dashboard, Machines, Refill, More (contains Products, Warehouse, Settings).

**Key pattern:**
- `AppTab` enum for tab selection
- Dashboard buttons switch tabs via `@Binding var selectedTab: AppTab`
- Dynamic text: "Continue Refill" vs "Start Refill" based on `RefillWizardViewModel.hasSavedTourState`

**Android equivalent:** Bottom navigation with `NavHost`, shared `selectedTab` state in a parent composable or ViewModel.

## 3. Product Review Step (Refill Wizard)

**New step before packing:** Detects discontinued (+ empty), expired, and out-of-stock products in machine trays. Lets user pick replacements or skip.

**Data model:**
```
ReplacementReason: .discontinued, .expired, .noStock
ReplacementSuggestion: trayId, machineId, machineName, slotNumber, reason, 
                        currentProductName/Image, currentStock,
                        replacementProductId (nullable), isSkipped
```

**Detection criteria (run after warehouse data loads):**
1. `discontinued == true` AND `currentStock == 0`
2. All warehouse batches for the product are expired (compare `expiration_date` with today)
3. `currentStock == 0` AND no warehouse stock available (`warehouseStockMap[productId] == nil`)

**UI flow:**
- Card per suggestion: slot badge, product image (strikethrough name), reason badge, stock count
- Three states: needs action (Replace/Skip buttons), replacement selected (Change), skipped (Undo)
- Sheet-based product picker with fuzzy search
- Bottom bar: "Skip Rest" (skips unhandled only) + "Apply & Continue"

**Step navigation:** Users can go back to Review from Packing via tappable step bubbles.

## 4. Packing Step Visual States Fix

**Problem:** Packed products looked identical to out-of-stock (both greyed out).

**Solution — 3 distinct visual states:**

| State | Card opacity | Border | Icon | Machine row text |
|-------|-------------|--------|------|-----------------|
| Needs packing | 1.0 | none | grey circle | primary color |
| Packed | 1.0 | green 1.5pt stroke | green checkmark | primary color, no strikethrough |
| Out of stock | 0.5 | none | red X | secondary color |

## 5. Machine Cards — Warehouse Stock Awareness

**New data flow:** `MachineListViewModel` fetches `warehouse_stock_batches` (qty > 0), builds `productId -> totalStock` map.

**New model fields:**
```
WarehouseAvailability: .inStock, .noStock, .needsSwap, .unknown
TrayDeficit: + isDiscontinued, warehouseAvailability
MachineStats: + swapNeededCount, noStockCount
```

**Card layout (matching web frontend):**
- Summary badges row: "X Empty" (red), "X Low" (orange), "X Swap" (orange), "X No Stock" (grey)
- Product deficit rows (not pills): product image + name + deficit + trailing label:
  - "In Stock" (green) — product available in warehouse
  - "Swap" (orange) — tray empty + no warehouse stock
  - "No Stock" (grey, dimmed 50%) — low stock + no warehouse stock
  - "DC" badge for discontinued products

## 6. Machine Cards — Extended Sales Stats

**2x2 grid replacing old 3-column row:**
- Today: revenue + sales count
- Yesterday: revenue + sales count  
- This Week: revenue + sales count (Monday-based)
- Last Week: revenue + sales count

**Query change:** Sales fetched from `startOfLastWeek` (2 weeks back) instead of just yesterday.

**Week calculation:** Monday-based: `daysSinceMonday = (weekday + 5) % 7` (where weekday 1=Sun).

## 7. Stock Bar Threshold Markers

**StockBar component** gains optional `minStock: Int?` and `fillWhenBelow: Int?` parameters.

**Visual:** Thin vertical lines on the bar:
- Amber/orange line at `minStock` position
- Blue line at `fillWhenBelow` position
- Only shown when value > 0 and < capacity

**Applied to:** TrayRow (list), TrayEditSheet (edit dialog with legend).

## 8. "Full" Button Removed from TrayRow

Removed the "Full" fill-to-capacity button from tray rows. Only +/- buttons remain for manual corrections. Refilling happens through the refill wizard.

## 9. Manual Machine Selection During Refill

Tappable machine name header with chevron opens a half-sheet picker showing remaining machines with tray/item counts.

## 10. Fuzzy Search in Product Pickers

Both `ProductPickerView` (tray edit) and `ReplacementProductPicker` (review step) use fuzzy matching: sequential character matching with gap-distance scoring.

```
func fuzzyMatch(query: String, target: String) -> Int?
  - Returns nil if any query char not found in order
  - Returns score (lower = better) based on gap distances
```
