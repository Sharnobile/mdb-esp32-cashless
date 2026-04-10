# Machine Location Editor

**Date:** 2026-04-10
**Scope:** Management Frontend (Nuxt 4) + Supabase Migration

## Problem

The `vendingMachine` table has `location_lat` and `location_lon` columns, but the frontend only **displays** them — there is no UI to set or edit a machine's location. Admins must currently open Supabase Studio and edit the row directly. We want a proper editor with:

1. **Address search** (submit-on-Enter) that resolves to coordinates
2. **Interactive map** with a draggable pin for precise positioning
3. **Structured address fields** (street, house number, postal code, city) persisted alongside coordinates
4. **Automatic country_code** population (currently a separate dropdown in the page header)
5. **Optional location entry** when creating a new machine

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Map library | Leaflet | Lightweight (~45 KB), no API key, matches self-hosted project philosophy |
| Tile provider | OpenStreetMap (tile.openstreetmap.org) | Free, fits the rest of the OSS stack |
| Geocoding provider | Nominatim (public `nominatim.openstreetmap.org`) | Free, no key, returns structured address data. Upgrade path: self-host later by swapping base URL. |
| Data model | Structured fields + `formatted_address` cache | User chose C over "single text field only" — allows future filtering by city/PLZ without a schema change |
| Editor location | Modal dialog via dropdown from existing ⚙ icon in page header | Focused, platform-consistent; keeps Machine-Settings separate from Device-Info |
| Header dropdown entries | "Automat-Einstellungen" + "Device-Info" | Semantic split: vendingMachine vs embedded |
| Search UX | **Submit-on-Enter / Search button** — not as-you-type | Nominatim's public usage policy explicitly prohibits autocomplete (*"you must not implement such a service on the client side using the API"*). Submit-on-Enter produces exactly one request per user action and is fully compliant. |
| Pin UX | Draggable, reverse-geocodes on `dragend` (single request per release) | Two-way sync between map and address. No debounce needed — dragend is a discrete user action, same compliance argument as search submit. |
| Empty-state map | No initial pin; center via `navigator.geolocation`, fall back to Europe | Admin usually sits near the machine; pin only appears after user action |
| Legacy machines | Not migrated; stay without address fields | YAGNI — opening the modal just shows an empty editor |
| country_code dropdown | Moved from page header into settings modal | Header becomes cleaner; auto-filled from geocoding with manual override |
| Create-machine flow | Optional location picker (collapsible section) | User explicitly requested this; keeps simple-case fast |
| Permissions | Admin only (`v-if="isAdmin"` + RLS) | Consistent with device/tray editing |

## Data Model

### Migration: `20260410120000_machine_address_fields.sql`

```sql
-- =========================================================
-- Machine Address Fields
--
-- Adds structured address columns + formatted_address cache
-- to vendingMachine. Coordinates (location_lat/location_lon)
-- and country_code already exist from prior migrations.
--
-- All columns nullable — legacy machines and the existing
-- createMachine(name, company) flow continue to work.
-- =========================================================

ALTER TABLE public."vendingMachine"
  ADD COLUMN address_street       text,
  ADD COLUMN address_house_number text,
  ADD COLUMN address_postal_code  text,
  ADD COLUMN address_city         text,
  ADD COLUMN formatted_address    text;

COMMENT ON COLUMN public."vendingMachine".address_street       IS 'Street name from Nominatim address.road';
COMMENT ON COLUMN public."vendingMachine".address_house_number IS 'House number from Nominatim address.house_number';
COMMENT ON COLUMN public."vendingMachine".address_postal_code  IS 'Postal code from Nominatim address.postcode';
COMMENT ON COLUMN public."vendingMachine".address_city         IS 'City/town/village from Nominatim address (first of city/town/village/municipality)';
COMMENT ON COLUMN public."vendingMachine".formatted_address    IS 'Cached display_name from Nominatim, full human-readable address';
```

No new RLS policies needed — the existing `vendingmachine_update` policy covers the new columns. No index needed yet (no filter/sort use case).

### TypeScript Interface Update

`app/composables/useMachines.ts` — extend the existing `VendingMachine` type:

```ts
export interface VendingMachine {
  id: string
  name: string | null
  location_lat: number | null
  location_lon: number | null
  country_code: string | null
  // NEW:
  address_street: string | null
  address_house_number: string | null
  address_postal_code: string | null
  address_city: string | null
  formatted_address: string | null
  // ... existing fields (embedded, stock_health, etc.)
}
```

All five SELECT strings that read `vendingMachine` columns must be extended to include the new address fields plus `country_code`:

| # | File | Line (at time of writing — verify at implementation time) | Purpose |
|---|---|---|---|
| 1 | `app/composables/useMachines.ts` | ~70 | `fetchMachines` initial load |
| 2 | `app/pages/machines/[id].vue` | ~170 | Machine detail initial fetch |
| 3 | `app/pages/machines/[id].vue` | ~182 | Fallback fetch (no embedded) |
| 4 | `app/pages/machines/[id].vue` | ~404 | Post-update re-fetch (admin path) |
| 5 | `app/pages/machines/[id].vue` | ~435 | Post-update re-fetch (alternate path) |

Implementation should grep for `location_lat, location_lon` to verify nothing was missed after the refactor.

**Realtime handler (`useMachines.ts` `subscribeToStatusUpdates`, line ~464):** The current UPDATE handler copies only `name`, `location_lat`, `location_lon` onto the local cache. Extend it to also copy `country_code`, `address_street`, `address_house_number`, `address_postal_code`, `address_city`, `formatted_address` so that concurrent edits from another admin reflect in open list pages without a full refetch.

## Frontend Changes

### New Files

#### `app/composables/useGeocoding.ts`

Nominatim wrapper. Exports:

```ts
interface GeocodingResult {
  lat: number
  lon: number
  display_name: string
  address: {
    road?: string
    house_number?: string
    postcode?: string
    city?: string
    town?: string
    village?: string
    municipality?: string
    country_code?: string  // lowercase ISO 3166-1 alpha-2
  }
}

function useGeocoding() {
  // Forward geocoding — called once per user action (Enter / Search button)
  // No internal debounce; caller decides when to invoke.
  async function search(query: string, signal?: AbortSignal): Promise<GeocodingResult[]>

  // Reverse geocoding — called once per user action (pin dragend, map click)
  async function reverse(lat: number, lon: number, signal?: AbortSignal): Promise<GeocodingResult | null>

  // Helper: pick city-like field in order of preference (city > town > village > municipality)
  function pickCity(address: GeocodingResult['address']): string | null

  return { search, reverse, pickCity }
}
```

**Nominatim Usage Policy compliance:**
- **No autocomplete.** Nominatim policy explicitly prohibits autocomplete-style clients. All requests are triggered by discrete user actions: pressing Enter / clicking the Search button, dragging the pin (`dragend`), or clicking on the empty map.
- `User-Agent` header: `MDBCashless-Management/1.0 (+https://github.com/LucienKerl/mdb-esp32-cashless)` (hard-coded; public policy requires an identifying UA)
- `Accept-Language` header: from `useI18n().locale.value` (`de` or `en`)
- Endpoints: `https://nominatim.openstreetmap.org/search` and `/reverse`
- Query params: `format=json&addressdetails=1&limit=5` (search); `format=json&addressdetails=1` (reverse)
- Max 1 request per second: because all triggers are discrete user actions, the realistic rate is ≪1 req/sec. No internal rate limiter needed.
- **Single shared `AbortController`** held by `LocationPicker.vue` and passed into both `search()` and `reverse()`. Starting a new request aborts whichever call (forward or reverse) is currently in-flight — this prevents stale responses from overwriting fresh user input.
- Base URL is a module-level constant (`const NOMINATIM_BASE = 'https://nominatim.openstreetmap.org'`) so the switch to a self-hosted instance later is a one-line change.

#### `app/components/LocationPicker.vue`

Reusable child component — used by both the settings modal and the create-machine modal.

**Props:**
```ts
interface Props {
  modelValue: {
    location_lat: number | null
    location_lon: number | null
    address_street: string | null
    address_house_number: string | null
    address_postal_code: string | null
    address_city: string | null
    formatted_address: string | null
    country_code: string | null  // only updated on geocoding, not cleared
  }
}
```

**Emits:**
- `update:modelValue` — standard v-model
- `clear` — when the "Standort entfernen" button is clicked (parent decides what to do)

**Internal structure:**
- Top: `<input>` + "Suchen"-Button (or Enter-to-submit) — no autocomplete dropdown. Below the input, a results list (max 5 entries) is rendered only **after** submit. Clicking an entry places the pin and closes the list.
- Middle: Leaflet `<div ref="mapContainer">` — 200 px height on mobile, 280 px on desktop. Map renders `© OpenStreetMap contributors` attribution in the bottom-right corner via Leaflet's built-in `TileLayer` `attribution` option (ODbL compliance).
- Below map: read-only "Erkannte Adresse" grid showing the parsed structured fields
- Country-code: a separate `<select>` rendered by the PARENT (not inside LocationPicker), but populated from `modelValue.country_code`

**Leaflet loading:**
Leaflet is a client-only dependency (uses `window`, `document`). Handle this with a top-level SFC-level import guarded by Nuxt's client rendering:

```ts
// LocationPicker.vue is a <ClientOnly> component (wrapped by parent) OR
// uses `import.meta.client` guards. Recommended: let the parent wrap it:
//   <ClientOnly><LocationPicker v-model="form" /></ClientOnly>
// Inside LocationPicker.vue:
import 'leaflet/dist/leaflet.css'  // side-effect, bundled into the client chunk
import L from 'leaflet'            // tree-shakable default import
```

With `<ClientOnly>` wrapping, Vite splits Leaflet into a separate async chunk automatically because LocationPicker is only imported by parents that render it conditionally. The initial render shows the `<ClientOnly>` fallback (a placeholder "Karte wird geladen…") for ~100-200 ms on first open.

**Map initialization logic:**
1. If `modelValue.location_lat && modelValue.location_lon`: center on existing coords, zoom 17, place pin.
2. Else if `navigator.geolocation` is available and user grants permission: center on current position, zoom 15, **no pin**.
3. Else: center on `[51.0, 10.0]` (mid-Europe), zoom 4, no pin.

Pin is placed (on empty map) when:
- User picks a result from the post-submit results list
- User clicks anywhere on the map (`map.on('click')`) — triggers immediate reverse-geocoding to fill the address fields

**Pin-drag handler:**
```
pin.on('dragend', (e) => {
  const { lat, lng } = e.target.getLatLng()
  emit('update:modelValue', { ...modelValue, location_lat: lat, location_lon: lng })
  // Immediately start reverse geocoding (no debounce — dragend is discrete)
  runReverseGeocoding(lat, lng)
})
```

No debounce needed — every trigger (search submit, map click, pin dragend) is a discrete user action. `runReverseGeocoding` aborts any in-flight request via the shared `AbortController` before starting a new one.

**Accessibility:** Leaflet is not fully keyboard accessible for pin placement. As a fallback, the search field is keyboard-usable (type + Enter → arrow keys + Enter through the results list), and a keyboard user can set a location that way even if they can't drag the pin.

#### `app/components/MachineSettingsModal.vue`

The modal wrapper. Uses existing shadcn-nuxt `Dialog`. Contains:
- Title: "Automat-Einstellungen"
- `<LocationPicker v-model="form">`
- Country-code `<select>` (below the LocationPicker, uses the existing COUNTRY_OPTIONS import from `[id].vue`)
- Footer:
  - Left: "🗑 Standort entfernen" (only visible when `location_lat` is not null)
  - Right: "Abbrechen" + "Speichern"

**Props:**
```ts
interface Props {
  machineId: string
  initial: Partial<VendingMachine>  // pre-fill from current row
  open: boolean
}
```

**Emits:**
- `update:open`
- `saved` — with the updated machine row

**Save logic:**
```ts
async function save() {
  const { error } = await supabase
    .from('vendingMachine')
    .update({
      location_lat: form.location_lat,
      location_lon: form.location_lon,
      address_street: form.address_street,
      address_house_number: form.address_house_number,
      address_postal_code: form.address_postal_code,
      address_city: form.address_city,
      formatted_address: form.formatted_address,
      country_code: form.country_code,
    })
    .eq('id', props.machineId)
  if (error) throw error
  emit('saved', { ...props.initial, ...form })
  emit('update:open', false)
}
```

**Clear logic:**
```ts
function clearLocation() {
  form.location_lat = null
  form.location_lon = null
  form.address_street = null
  form.address_house_number = null
  form.address_postal_code = null
  form.address_city = null
  form.formatted_address = null
  form.country_code = null
  // User can click Save to persist the cleared state
}
```

### Modified Files

#### `app/pages/machines/[id].vue`

1. Remove the inline `country_code` dropdown (currently under the machine name heading; identified by the `COUNTRY_OPTIONS` loop + `updateMachineCountry` call). It moves into the settings modal.
2. Replace the single ⚙ button (the existing "device details" button that sets `showDeviceInfoModal = true`) with a shadcn-nuxt `DropdownMenu` containing:
   - "Automat-Einstellungen" → opens `MachineSettingsModal`
   - "Device-Info" → opens the existing `showDeviceInfoModal` (current behavior)
3. Add a state variable `showMachineSettingsModal` and render `<MachineSettingsModal>` at the page bottom.
4. Update all 4 SELECT strings in this file (see SELECT-string table above) to include new address fields and `country_code`.
5. The existing coordinates display under the heading stays as-is; additionally make it clickable to open the settings modal directly.

*(Line numbers referenced in the review are a moving target; at implementation time, find the elements by surrounding text — e.g. the `country_code` dropdown by `updateMachineCountry`, the device info button by `showDeviceInfoModal = true`.)*

#### `app/pages/machines/index.vue`

1. Extend the create-machine modal body: below the name input, add a collapsible section "Standort jetzt festlegen (optional)" that toggles the `LocationPicker`.
2. Pass all new fields to `createMachine()`.

#### `app/composables/useMachines.ts`

1. Extend `VendingMachine` interface (see Data Model section).
2. Update `createMachine()` signature — return type changes from `Promise<void>` to `Promise<void>` (unchanged), but accepts an optional location patch:
   ```ts
   async function createMachine(
     name: string,
     companyId: string,
     location?: {
       location_lat: number
       location_lon: number
       address_street: string | null
       address_house_number: string | null
       address_postal_code: string | null
       address_city: string | null
       formatted_address: string | null
       country_code: string | null
     }
   ): Promise<void>
   ```
   Insert the fields if `location` is provided, else insert only `{ name, company: companyId }` (existing behavior preserved). Callers continue to rely on `fetchMachines()` (already called at the end) to pick up the new row — no return-value change needed.
3. New helper `updateMachineSettings(machineId, patch)` — thin wrapper around a single `UPDATE vendingMachine`; the modal's `save()` calls it. After the update succeeds, it mutates the matching entry in the local `machines` ref so the list refreshes without a full refetch:
   ```ts
   async function updateMachineSettings(
     machineId: string,
     patch: {
       location_lat: number | null
       location_lon: number | null
       address_street: string | null
       address_house_number: string | null
       address_postal_code: string | null
       address_city: string | null
       formatted_address: string | null
       country_code: string | null
     }
   ): Promise<void>
   ```
4. Extend the single SELECT string in this file (line ~70 — `fetchMachines`) to include the new columns + `country_code`.
5. Extend the realtime UPDATE handler in `subscribeToStatusUpdates` to copy the new fields onto the local cache (see "Realtime handler" note above).

### Dependencies to Add

```json
{
  "dependencies": {
    "leaflet": "^1.9.4"
  },
  "devDependencies": {
    "@types/leaflet": "^1.9.12"
  }
}
```

No separate `vue-leaflet` wrapper — we use raw Leaflet directly because we only need one map with one pin, and the wrappers add noise for little gain.

## i18n Keys

Add to `app/i18n/locales/de.json` and `en.json`:

```json
{
  "machineSettings": {
    "title": "Automat-Einstellungen" / "Machine settings",
    "addressLabel": "Adresse suchen" / "Search address",
    "addressPlaceholder": "z. B. Musterstraße 1, Berlin" / "e.g. Main Street 1, Berlin",
    "searchButton": "Suchen" / "Search",
    "searching": "Suche läuft…" / "Searching…",
    "detectedAddress": "Erkannte Adresse" / "Detected address",
    "street": "Straße" / "Street",
    "postalCode": "PLZ" / "Postal code",
    "city": "Stadt" / "City",
    "country": "Land" / "Country",
    "clearLocation": "Standort entfernen" / "Clear location",
    "pinHint": "Pin ziehen für exakte Position" / "Drag pin for exact position",
    "mapLoading": "Karte wird geladen…" / "Loading map…",
    "geocodingError": "Adresse konnte nicht gefunden werden" / "Address not found",
    "noResults": "Keine Treffer" / "No results",
    "countryAutoHint": "Aus Adresse übernommen, manuell überschreibbar" / "Derived from address, can be overridden",
    "setLocationOptional": "Standort jetzt festlegen (optional)" / "Set location now (optional)"
  }
}
```

Existing keys (`machineDetail.address` for the MDB address, `machines.country`) are **not** touched.

## Error Handling

| Failure mode | Handling |
|---|---|
| Nominatim 429 / 503 | Show inline error "Suchdienst temporär nicht verfügbar"; user can still manually place pin |
| Network offline | Same message; map tiles also won't load, Leaflet shows gray grid (acceptable) |
| Geolocation denied | Silently fall through to Europe-wide view; no error |
| Geolocation timeout (>5s) | Same fallback; don't block modal render |
| User search query empty / <2 chars | Don't submit; show inline hint "Bitte mindestens 2 Zeichen eingeben" |
| User search query >200 chars | Truncate client-side before sending |
| Nominatim returns 0 results | Show "Keine Treffer" under the search box |
| Pin drag but reverse geocoding fails | Keep coords, leave address fields unchanged, show inline warning |
| Supabase update fails | Show error in modal footer, don't close modal |
| Leaflet load fails (network) | Show error "Karte konnte nicht geladen werden", keep the rest of the form functional (address search still works, user can save coords from a search result without seeing the pin) |

## Edge Cases

- **Editing a machine with coords but no address (legacy):** Modal opens with map centered on existing pin, structured fields empty. User can either leave as-is (just save), drag the pin (triggers reverse-geocode), or search a new address. No automatic reverse-geocode on open.
- **User places pin via click on empty map:** Triggers immediate reverse-geocode (single user action, no debounce).
- **User submits search then drags pin before reverse finishes:** The shared `AbortController` held by LocationPicker aborts whichever request is in-flight (forward or reverse) when a new one starts. The LocationPicker holds a single `abortController` ref, calls `abortController.abort()` + creates a new one before each call into `useGeocoding`.
- **Modal closed mid-edit:** Unsaved changes discarded (no "unsaved changes" prompt in v1 — YAGNI).
- **Realtime update of the machine while modal is open:** Not a concern; the user's local form is authoritative while editing. On save, the user's form wins (last-write-wins). No merge logic.
- **Create-machine success with location:** `createMachine` inserts the row with all address fields + coordinates and then calls `fetchMachines()`. The new machine appears in the list with its pin location.

## Out of Scope (YAGNI)

- **Machine overview/discovery map** showing all machines at once — a public discovery map is on the project roadmap (see `Docker/supabase/migrations/20260410000000_public_listing.sql`, which introduces a `public_listing` flag, and the per-machine storefront at `app/pages/m/[machine_id].vue`). The address fields added by this spec are explicitly designed to be reusable by that future map without schema changes — that's the whole point of storing structured fields instead of a single text blob. But building the map itself is out of scope here.
- **Self-hosted Nominatim** — the base URL is a single module-level constant so the switch is a one-line change. Not set up in v1. Consider it when traffic grows or when the public instance becomes unreliable.
- **Autocomplete-as-you-type** — Nominatim policy prohibits it against the public instance. Stays out of scope until the project self-hosts Nominatim.
- **Offline tile caching / PWA map support** — current PWA service worker does not cache tile.openstreetmap.org.
- **Geocoding result caching in DB** — small admin volume, not worth the complexity.
- **Address validation beyond Nominatim** — no postcode regex, no country-specific rules.
- **Bulk import of addresses for legacy machines** — not needed; admins can edit per-machine.
- **"Unsaved changes" guard on modal close.**
- **Undo after clearing location.**

## Verification Plan

1. **Migration:** `supabase migration up` applies cleanly on a dev DB with existing data. Legacy machines still load. Existing `country_code` value on legacy rows is preserved.
2. **Backward compatibility (production safety):** Migration adds only nullable columns; existing firmware publishing `sale` / `status` / `paxcounter` / `mdb-log` events (which don't touch these columns) continues to work unchanged. The `claim-device` edge function (which inserts into `embeddeds`, not `vendingMachine`) is unaffected. Verify by running the full mosquitto→webhook→DB flow against an unchanged ESP32 firmware image after migration.
3. **Build:** `npm run build` succeeds; Leaflet is code-split (check `dist/` for a separate chunk, expected size ~45 KB gzipped).
4. **SSR render:** Machine detail page SSR render succeeds without hitting Leaflet (ClientOnly guard works); hydration replaces the placeholder with the map.
5. **Create machine without location:** Existing flow still works, row is inserted with NULL address fields, list refreshes normally.
6. **Create machine with location:** Location picker appears when the "Standort jetzt festlegen" section is expanded. Search returns results, pin is draggable, saved row has all fields populated.
7. **Edit existing machine (legacy, no address):** Modal opens, legacy coords show a pin, search works, pin drag reverse-geocodes, save persists changes including new address fields.
8. **Clear location:** Button visible only when coords exist, clears all address fields + coords + country_code, save persists nulls.
9. **Country code auto-fill:** Search "Paris, France" → country_code becomes FR; manual override via the dropdown still works and survives save.
10. **Mobile (iOS Safari PWA):** Modal is full-height, map is touch-draggable, search results list is usable, soft keyboard doesn't hide the search button.
11. **Offline behavior:** Tile grid renders gray, search shows "Suchdienst temporär nicht verfügbar", form still saves if the user already had coords.
12. **Permission check:** Non-admin user doesn't see the dropdown menu item; direct call to `updateMachineSettings` is rejected by the RLS policy `vendingmachine_update` (which requires `i_am_admin()`).
13. **No autocomplete regression:** Typing in the search field while holding it focused **does not** fire any network request to Nominatim (verify via DevTools network tab). Requests only appear after pressing Enter or clicking "Suchen".
14. **AbortController:** Click Search, then immediately drag the pin before search responds → only the reverse-geocoding result populates the address fields; the stale forward-geocoding response is discarded.
15. **Realtime sync:** Open the machines list page in two browsers as two admins, edit location in browser A, confirm browser B receives the update via the realtime handler and reflects the new location without a reload.
16. **Attribution visible:** The `© OpenStreetMap contributors` text is rendered in the bottom-right of the map in both light and dark mode.
