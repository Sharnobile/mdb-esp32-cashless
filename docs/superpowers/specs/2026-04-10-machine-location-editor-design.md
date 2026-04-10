# Machine Location Editor

**Date:** 2026-04-10
**Scope:** Management Frontend (Nuxt 4) + Supabase Migration

## Problem

The `vendingMachine` table has `location_lat` and `location_lon` columns, but the frontend only **displays** them — there is no UI to set or edit a machine's location. Admins must currently open Supabase Studio and edit the row directly. We want a proper editor with:

1. **Address input** with autocomplete that resolves to coordinates
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
| Search UX | Autocomplete as-you-type, 500 ms debounce | Modern feel, familiar from Google Maps |
| Pin UX | Draggable, reverse-geocodes on `dragend` with 800 ms debounce | Two-way sync between map and address |
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

All SELECT strings in the composable (`fetchMachines`, realtime refetch, create-machine followup) must be extended to include the new columns. There are four such SELECT strings in `useMachines.ts` and `app/pages/machines/[id].vue`.

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
  // Forward geocoding with 500 ms debounce, AbortController for in-flight cancel
  async function search(query: string, signal?: AbortSignal): Promise<GeocodingResult[]>

  // Reverse geocoding with 800 ms debounce (managed by caller)
  async function reverse(lat: number, lon: number, signal?: AbortSignal): Promise<GeocodingResult | null>

  // Helper: pick city-like field in order of preference
  function pickCity(address: GeocodingResult['address']): string | null

  return { search, reverse, pickCity }
}
```

**Nominatim Usage Policy compliance:**
- `User-Agent` header: `MDBCashless-Management/1.0 (+https://github.com/LucienKerl/mdb-esp32-cashless)` (hard-coded; public policy requires an identifying UA)
- `Accept-Language` header: from `useI18n().locale.value` (`de` or `en`)
- Endpoints: `https://nominatim.openstreetmap.org/search` and `/reverse`
- Query params: `format=json&addressdetails=1&limit=5` (search); `format=json&addressdetails=1` (reverse)
- Rate limiting: debounce handled at component level; composable never queues requests internally
- Only **one in-flight request** at a time per caller via `AbortController` — new search cancels old one

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
- Top: `<input>` with autocomplete dropdown (absolute-positioned, max 5 results)
- Middle: Leaflet `<div ref="mapContainer">` — 200 px height on mobile, 280 px on desktop
- Below map: read-only "Erkannte Adresse" grid showing the parsed structured fields
- Country-code: a separate `<select>` rendered by the PARENT (not inside LocationPicker), but populated from `modelValue.country_code`

**Leaflet lazy loading:**
Leaflet must be dynamically imported to keep it out of the main bundle:
```ts
const L = await import('leaflet')
await import('leaflet/dist/leaflet.css')  // CSS import via Vite
```

This import happens in `onMounted()` inside LocationPicker. Initial render shows a placeholder "Karte wird geladen..." for ~100-200 ms.

**Map initialization logic:**
1. If `modelValue.location_lat && modelValue.location_lon`: center on existing coords, zoom 17, place pin.
2. Else if `navigator.geolocation` is available and user grants permission: center on current position, zoom 15, **no pin**.
3. Else: center on `[51.0, 10.0]` (mid-Europe), zoom 4, no pin.

Pin is placed (on empty map) when:
- User clicks a search result from autocomplete
- User clicks anywhere on the map (`map.on('click')`)

**Pin-drag handler:**
```
pin.on('dragend', (e) => {
  const { lat, lng } = e.target.getLatLng()
  emit('update:modelValue', { ...modelValue, location_lat: lat, location_lon: lng })
  // Start debounced reverse geocoding
})
```

Reverse geocoding debounce is managed by a `useDebounceFn` from `@vueuse/core` at 800 ms.

**Accessibility:** Leaflet is not fully keyboard accessible for pin placement. As a fallback, the autocomplete search field is keyboard-navigable (Arrow keys + Enter), and a keyboard user can set a location that way even if they can't drag the pin.

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

1. Remove the inline `country_code` dropdown (lines 1146-1156) — it moves into the settings modal.
2. Replace the single ⚙ button (lines 1187-1193) with a `DropdownMenu` (shadcn-nuxt) containing:
   - "Automat-Einstellungen" → opens `MachineSettingsModal`
   - "Device-Info" → opens the existing `showDeviceInfoModal` (current behavior)
3. Add a state variable `showMachineSettingsModal` and render `<MachineSettingsModal>` at the page bottom.
4. Update SELECT strings (4 occurrences) to include new address fields.
5. The existing coordinates display (lines 1143-1144) stays as-is; additionally make it clickable to open the settings modal directly.

#### `app/pages/machines/index.vue`

1. Extend the create-machine modal body: below the name input, add a collapsible section "Standort jetzt festlegen (optional)" that toggles the `LocationPicker`.
2. Pass all new fields to `createMachine()`.

#### `app/composables/useMachines.ts`

1. Extend `VendingMachine` interface (see Data Model section).
2. Update `createMachine()` signature:
   ```ts
   async function createMachine(name: string, companyId: string, location?: {
     location_lat: number
     location_lon: number
     address_street: string | null
     address_house_number: string | null
     address_postal_code: string | null
     address_city: string | null
     formatted_address: string | null
     country_code: string | null
   })
   ```
   Insert the fields if `location` is provided, else insert only `{ name, company: companyId }` (existing behavior preserved).
3. New helper `updateMachineSettings(machineId, patch)` — kept thin; the modal's `save()` calls it. This helper also updates the local `machines` ref so the list refreshes without a full refetch.
4. Extend all four SELECT strings in the file.

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
| User types >200 chars | Truncate client-side before sending |
| Nominatim returns 0 results | Show "Keine Treffer" in dropdown |
| Pin drag but reverse geocoding fails | Keep coords, leave address fields unchanged, show inline warning |
| Supabase update fails | Show error in modal footer, don't close modal |
| Leaflet dynamic import fails | Show error "Karte konnte nicht geladen werden", keep the rest of the form functional (address search + manual coord entry) |

## Edge Cases

- **Editing a machine with coords but no address (legacy):** Modal opens with map centered on existing pin, structured fields empty. User can either leave as-is (just save), click the pin to trigger reverse-geocode manually, or search a new address. No automatic reverse-geocode on open.
- **User places pin via click on empty map:** Triggers immediate reverse-geocode (not debounced — single action).
- **User types then drags pin before reverse finishes:** `AbortController` cancels in-flight reverse geocoding when a new search starts, and vice versa.
- **Modal closed mid-edit:** Unsaved changes discarded (no "unsaved changes" prompt in v1 — YAGNI).
- **Realtime update of the machine while modal is open:** Not a concern; the user's local form is authoritative while editing.
- **Create-machine success with location:** `createMachine` returns the row, `fetchMachines()` is called; new pin appears wherever the list is shown.

## Out of Scope (YAGNI)

- **Machine overview map** showing all machines at once — schema is ready, but no such page exists yet. Can be added later as a new page without changes to this feature.
- **Self-hosted Nominatim** — supported by keeping the base URL in a config var (env or hardcoded constant), but not actively set up.
- **Offline tile caching / PWA map support** — current PWA service worker does not cache tile.openstreetmap.org.
- **Geocoding result caching in DB** — small admin volume, not worth the complexity.
- **Address validation beyond Nominatim** — no postcode regex, no country-specific rules.
- **Bulk import of addresses for legacy machines** — not needed; admins can edit per-machine.
- **"Unsaved changes" guard on modal close.**
- **Undo after clearing location.**

## Verification Plan

1. **Migration:** `supabase migration up` applies cleanly on a dev DB with existing data. Legacy machines still load. Existing `country_code` dropdown (pre-remove) still works during transition.
2. **Build:** `npm run build` succeeds; Leaflet is code-split (check `dist/` for a separate chunk).
3. **Create machine without location:** Existing flow still works, row is inserted with NULL address fields.
4. **Create machine with location:** Location picker appears, geocoding works, pin is draggable, saved row has all fields populated.
5. **Edit existing machine:** Modal opens, legacy coords show a pin, search autocomplete works, pin drag reverse-geocodes, save persists changes.
6. **Clear location:** Button visible only when coords exist, clears all address fields + coords + country_code, save persists nulls.
7. **Country code auto-fill:** Search "Paris, France" → country_code becomes FR; manual override still possible.
8. **Mobile (iOS Safari PWA):** Modal is full-height, map is touch-draggable, autocomplete dropdown is usable.
9. **Offline behavior:** Tile grid renders gray, search shows error, form still saves (just without new geocoding).
10. **Permission check:** Non-admin user cannot open modal (no menu item shown); backend RLS rejects direct update attempt.
11. **Nominatim rate limit:** Typing fast does not issue >1 request per 500 ms (debounce) and >1 concurrent (abort on new).
