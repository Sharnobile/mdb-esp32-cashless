# Machine Location Editor — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a modal editor where admins set a vending machine's location via address search + an interactive Leaflet map with a draggable pin, and expose the same editor as an optional section in the create-machine flow.

**Architecture:** A new `useGeocoding` composable wraps Nominatim's `/search` and `/reverse` endpoints (submit-on-Enter, no autocomplete, policy-compliant). A new `LocationPicker.vue` component renders Leaflet, handles pin interactions, and emits a location model via `v-model`. A new `MachineSettingsModal.vue` wraps the picker plus a country-code dropdown and persists changes via a new `updateMachineSettings` helper in `useMachines`. The machine detail page's ⚙ button becomes a shadcn DropdownMenu with two entries ("Automat-Einstellungen" and "Device-Info"); the inline country dropdown moves into the new modal. The create-machine modal gains a collapsible LocationPicker section. All new columns are nullable, so legacy machines and old firmware continue to work unchanged.

**Tech Stack:** Nuxt 4, Vue 3 SFC, shadcn-nuxt (Dialog + DropdownMenu), TailwindCSS 4, Leaflet 1.9 (raw, no wrapper), OpenStreetMap tiles, Nominatim public API, `@nuxtjs/supabase`, `@nuxtjs/i18n`, `@vueuse/core`, Vitest + happy-dom, Supabase CLI migrations.

**Spec:** `docs/superpowers/specs/2026-04-10-machine-location-editor-design.md`

**Working directory for all frontend commands:** `/Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend`

**Key conventions you must follow (from project CLAUDE.md):**
- **NEVER run `supabase db reset`** — the dev DB holds live test data. Use `supabase migration up` only.
- **Backward compatibility is mandatory** — production ESP32 devices and existing frontend builds must keep working. All DB changes are additive (new nullable columns). No MQTT/edge-function payload format changes.
- **Multi-tenancy:** All DB work honors the existing `vendingmachine_update` RLS policy (admin-gated). No new RLS policies are required.
- **No generated DB types:** `~/types/database.types.ts` does not exist. Supabase client returns `never` for unknown tables. Cast results with `as { ... }[]` at the query site — see existing code in `useMachines.ts`.
- **Frontend must not break SSR:** Leaflet uses `window`/`document`; wrap it in `<ClientOnly>` at the consumer side.

---

## File Structure

**New files (create):**

| Path | Responsibility | Est. size |
|---|---|---|
| `Docker/supabase/migrations/20260410120000_machine_address_fields.sql` | Add 5 nullable address columns to `vendingMachine` | ~20 lines |
| `management-frontend/app/composables/useGeocoding.ts` | Nominatim wrapper: forward/reverse geocoding, city picker helper, policy-compliant headers, base URL constant | ~120 lines |
| `management-frontend/app/composables/__tests__/useGeocoding.test.ts` | Unit tests: pure `pickCity` helper + mocked-fetch `search`/`reverse` | ~180 lines |
| `management-frontend/app/components/LocationPicker.vue` | Reusable location editor: search input, results list, Leaflet map, draggable pin, reverse-geocoding on drag/click | ~350 lines |
| `management-frontend/app/components/MachineSettingsModal.vue` | Modal wrapper: LocationPicker + country-code dropdown + save/clear/cancel | ~180 lines |

**Modified files:**

| Path | Change | Reason |
|---|---|---|
| `management-frontend/package.json` | Add `leaflet@^1.9.4` + `@types/leaflet@^1.9.12` | New map dep |
| `management-frontend/app/composables/useMachines.ts` | Extend `VendingMachine` interface; extend SELECT (~line 70); extend realtime UPDATE handler (~line 462); extend `createMachine` signature; add `updateMachineSettings` helper | Data access layer for the new fields |
| `management-frontend/app/pages/machines/[id].vue` | Replace ⚙ button with `DropdownMenu`, remove inline country dropdown, render `MachineSettingsModal`, extend 4 SELECT strings | New entry point + model update |
| `management-frontend/app/pages/machines/index.vue` | Add collapsible LocationPicker section to create-machine modal, pass fields to `createMachine` | Optional location at creation time |
| `management-frontend/app/i18n/locales/de.json` | Add `machineSettings.*` keys (German) | i18n |
| `management-frontend/app/i18n/locales/en.json` | Add `machineSettings.*` keys (English) | i18n |

Each file has a single responsibility. `LocationPicker.vue` is the largest new file (~350 lines) and sits near but below the "too big" threshold; its responsibilities (search, map, pin drag, reverse-geocoding) are tightly coupled and splitting would create noisy interfaces. Keep as one file.

---

## Chunk 1: Database Migration + useMachines Data Layer

Goal: the schema has the new columns, the composable knows about them, and realtime updates propagate them. After this chunk, the backend is ready even though no UI yet uses the new fields.

### Task 1.1: Create the migration file

**Files:**
- Create: `Docker/supabase/migrations/20260410120000_machine_address_fields.sql`

- [ ] **Step 1: Write the migration SQL**

Create the file with exactly this content:

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
-- Backward-compatible: no firmware or edge-function changes
-- are required.
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

- [ ] **Step 2: Apply the migration**

Run from the repo root:

```bash
cd Docker/supabase && supabase migration up
```

Expected output: a line showing the new migration applied, no errors. **Do not run `supabase db reset`** — that is destructive and forbidden for this project.

- [ ] **Step 3: Verify the columns exist**

```bash
cd Docker/supabase && supabase db execute --local "SELECT column_name, data_type, is_nullable FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'vendingMachine' AND column_name LIKE 'address_%' OR column_name = 'formatted_address' ORDER BY column_name;"
```

Expected output: 5 rows — `address_city`, `address_house_number`, `address_postal_code`, `address_street`, `formatted_address` — all `text`, all `YES` nullable.

If `supabase db execute` isn't available in the CLI version, use Supabase Studio (http://localhost:54323) → Table Editor → `vendingMachine` and confirm the 5 new columns visually.

- [ ] **Step 4: Verify no legacy machines broke**

```bash
cd Docker/supabase && supabase db execute --local "SELECT id, name, location_lat, location_lon, country_code, address_street, formatted_address FROM public.\"vendingMachine\" LIMIT 5;"
```

Expected: existing rows return with `NULL` for the 5 new columns and unchanged values for the old ones.

- [ ] **Step 5: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless && git add Docker/supabase/migrations/20260410120000_machine_address_fields.sql && git commit -m "$(cat <<'EOF'
feat(db): add structured address fields to vendingMachine

Adds address_street, address_house_number, address_postal_code,
address_city, and formatted_address columns. All nullable, so
legacy machines and the existing createMachine(name, company) flow
continue to work. No firmware or edge-function changes required.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 1.2: Extend the VendingMachine TypeScript interface

**Files:**
- Modify: `management-frontend/app/composables/useMachines.ts` (interface block around lines 18-48)

- [ ] **Step 1: Add the new fields to the interface**

Find the existing `interface VendingMachine` declaration. Add the five new fields directly under `country_code: string | null` so the new block reads:

```ts
interface VendingMachine {
  id: string
  name: string
  location_lat: number | null
  location_lon: number | null
  embedded: string | null
  country_code: string | null
  // NEW: structured address (added 2026-04-10)
  address_street: string | null
  address_house_number: string | null
  address_postal_code: string | null
  address_city: string | null
  formatted_address: string | null
  embeddeds: Embedded | null
  // ... existing runtime fields (last_sale_at, today_revenue, etc.) stay unchanged
```

Leave every other field in the interface exactly as it is.

- [ ] **Step 2: Run the TypeScript check**

```bash
cd management-frontend && npx vue-tsc --noEmit 2>&1 | tail -30
```

Expected: no NEW errors specifically referencing `address_street`, `address_house_number`, `address_postal_code`, `address_city`, or `formatted_address`. (Pre-existing errors unrelated to these fields are acceptable — note them but don't fix them in this task.)

### Task 1.3: Extend the 5 SELECT strings

**Files:**
- Modify: `management-frontend/app/composables/useMachines.ts` (around line 70)
- Modify: `management-frontend/app/pages/machines/[id].vue` (around lines 170, 182, 404, 435)

Approach: grep for every occurrence of `location_lat, location_lon` across these two files, and in each SELECT string append `, country_code, address_street, address_house_number, address_postal_code, address_city, formatted_address` if it's not already there.

- [ ] **Step 1: Find all SELECT strings**

```bash
cd management-frontend && grep -n "location_lat, location_lon" app/composables/useMachines.ts app/pages/machines/\[id\].vue
```

Expected output: exactly 5 line numbers — 1 from `useMachines.ts`, 4 from `[id].vue`.

- [ ] **Step 2: Update `useMachines.ts` SELECT (line ~70)**

Before:
```ts
.select(`
  id, name, location_lat, location_lon, embedded, country_code,
  embeddeds(id, status, status_at, subdomain, mac_address, firmware_version, firmware_build_date, mdb_diagnostics, last_restart_reason, last_restart_at, online_since)
`)
```

After:
```ts
.select(`
  id, name, location_lat, location_lon, embedded, country_code,
  address_street, address_house_number, address_postal_code, address_city, formatted_address,
  embeddeds(id, status, status_at, subdomain, mac_address, firmware_version, firmware_build_date, mdb_diagnostics, last_restart_reason, last_restart_at, online_since)
`)
```

- [ ] **Step 3: Update each SELECT in `app/pages/machines/[id].vue`**

There are 4 SELECT strings in this file. Each one looks like:

```ts
.select('id, name, location_lat, location_lon, embedded, country_code, embeddeds(id, status, ... online_since)')
```

For each of them, insert the new fields so it becomes:

```ts
.select('id, name, location_lat, location_lon, embedded, country_code, address_street, address_house_number, address_postal_code, address_city, formatted_address, embeddeds(id, status, ... online_since)')
```

Use the Edit tool with enough surrounding context to make each edit unique (the four occurrences may differ slightly in formatting).

- [ ] **Step 4: Verify every SELECT was updated**

```bash
cd management-frontend && grep -n "location_lat, location_lon" app/composables/useMachines.ts app/pages/machines/\[id\].vue
```

Expected: all 5 lines now also contain `formatted_address`. Run:

```bash
cd management-frontend && grep -c "formatted_address" app/composables/useMachines.ts app/pages/machines/\[id\].vue
```

Expected: `useMachines.ts:1`, `[id].vue:4` (total 5 occurrences).

- [ ] **Step 5: TypeScript check**

```bash
cd management-frontend && npx vue-tsc --noEmit 2>&1 | tail -30
```

Expected: no new errors relating to the new fields.

### Task 1.4: Extend the realtime UPDATE handler

**Files:**
- Modify: `management-frontend/app/composables/useMachines.ts` (around lines 460-474)

- [ ] **Step 1: Locate the UPDATE handler**

Find the block in `subscribeToStatusUpdates` that handles `{ event: 'UPDATE', schema: 'public', table: 'vendingMachine' }`. It currently reads:

```ts
(payload) => {
  const updated = payload.new as Record<string, any>
  const machine = machines.value.find(m => m.id === updated.id)
  if (machine) {
    machine.name = updated.name
    machine.location_lat = updated.location_lat
    machine.location_lon = updated.location_lon
    // If embedded link changed, re-fetch to get the joined data
    if (machine.embedded !== updated.embedded) {
      fetchMachines()
    }
  }
}
```

- [ ] **Step 2: Copy the new fields onto the local cache**

Extend the handler to also copy `country_code` and the 5 new address columns. New body:

```ts
(payload) => {
  const updated = payload.new as Record<string, any>
  const machine = machines.value.find(m => m.id === updated.id)
  if (machine) {
    machine.name = updated.name
    machine.location_lat = updated.location_lat
    machine.location_lon = updated.location_lon
    machine.country_code = updated.country_code ?? null
    machine.address_street = updated.address_street ?? null
    machine.address_house_number = updated.address_house_number ?? null
    machine.address_postal_code = updated.address_postal_code ?? null
    machine.address_city = updated.address_city ?? null
    machine.formatted_address = updated.formatted_address ?? null
    // If embedded link changed, re-fetch to get the joined data
    if (machine.embedded !== updated.embedded) {
      fetchMachines()
    }
  }
}
```

- [ ] **Step 3: TypeScript check**

```bash
cd management-frontend && npx vue-tsc --noEmit 2>&1 | tail -30
```

Expected: no new errors.

- [ ] **Step 4: Commit Tasks 1.2–1.4 together**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless && git add management-frontend/app/composables/useMachines.ts management-frontend/app/pages/machines/\[id\].vue && git commit -m "$(cat <<'EOF'
feat(frontend): add address fields to VendingMachine data layer

- Extend VendingMachine interface with 5 new nullable address fields
- Add new columns to all 5 SELECT strings that read vendingMachine
- Extend realtime UPDATE handler to propagate new fields onto cache

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Chunk 2: useGeocoding Composable + Leaflet Dependency

Goal: a tested, policy-compliant Nominatim wrapper ready to be consumed by `LocationPicker`.

### Task 2.1: Install Leaflet

**Files:**
- Modify: `management-frontend/package.json`
- Modify: `management-frontend/package-lock.json`

- [ ] **Step 1: Install the runtime dep and types**

```bash
cd management-frontend && npm install leaflet@^1.9.4 && npm install -D @types/leaflet@^1.9.12
```

Expected: both packages added to `package.json`, lockfile updated, no peer-dep warnings that reference Vue or Nuxt.

- [ ] **Step 2: Verify the install**

```bash
cd management-frontend && node -e "console.log(require('leaflet/package.json').version, require('@types/leaflet/package.json').version)"
```

Expected: two version strings printed, both `1.9.x`.

- [ ] **Step 3: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless && git add management-frontend/package.json management-frontend/package-lock.json && git commit -m "$(cat <<'EOF'
chore(frontend): add leaflet + @types/leaflet for map editor

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 2.2: Write failing tests for `pickCity`

**Files:**
- Create: `management-frontend/app/composables/__tests__/useGeocoding.test.ts`

- [ ] **Step 1: Write the test file with pure helper tests first**

```ts
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { pickCity, NOMINATIM_BASE } from '../useGeocoding'

// ── pickCity: pure helper ────────────────────────────────────────────────

describe('pickCity', () => {
  it('returns city when present', () => {
    expect(pickCity({ city: 'Berlin', town: 'Ignored' })).toBe('Berlin')
  })

  it('falls back to town when city missing', () => {
    expect(pickCity({ town: 'Musterstadt' })).toBe('Musterstadt')
  })

  it('falls back to village when city and town missing', () => {
    expect(pickCity({ village: 'Musterdorf' })).toBe('Musterdorf')
  })

  it('falls back to municipality when city, town, village all missing', () => {
    expect(pickCity({ municipality: 'Musterdistrikt' })).toBe('Musterdistrikt')
  })

  it('returns null when none of the fields are present', () => {
    expect(pickCity({})).toBeNull()
  })

  it('prefers order city > town > village > municipality', () => {
    expect(pickCity({
      city: 'A',
      town: 'B',
      village: 'C',
      municipality: 'D',
    })).toBe('A')
  })

  it('treats empty strings as missing', () => {
    expect(pickCity({ city: '', town: 'B' })).toBe('B')
  })
})
```

Note: `NOMINATIM_BASE` is imported to force the module to load; it's also tested later in the fetch-based tests.

- [ ] **Step 2: Run the tests to confirm they fail**

```bash
cd management-frontend && npx vitest run app/composables/__tests__/useGeocoding.test.ts 2>&1 | tail -30
```

Expected: FAIL with "Cannot find module '../useGeocoding'" or equivalent (the file doesn't exist yet).

### Task 2.3: Implement `pickCity` + module scaffold

**Files:**
- Create: `management-frontend/app/composables/useGeocoding.ts`

- [ ] **Step 1: Write the module skeleton with `pickCity` only**

```ts
/**
 * Nominatim geocoding wrapper.
 *
 * Policy-compliant by design:
 * - No autocomplete (prohibited by Nominatim usage policy)
 * - All calls triggered by discrete user actions (Enter / click)
 * - Identifying User-Agent per policy
 * - Single in-flight request via caller-supplied AbortController
 *
 * Swap base URL to a self-hosted instance by changing NOMINATIM_BASE.
 */

import { useI18n } from '#imports'

export const NOMINATIM_BASE = 'https://nominatim.openstreetmap.org'

const USER_AGENT = 'MDBCashless-Management/1.0 (+https://github.com/LucienKerl/mdb-esp32-cashless)'

export interface GeocodingAddress {
  road?: string
  house_number?: string
  postcode?: string
  city?: string
  town?: string
  village?: string
  municipality?: string
  country_code?: string // lowercase ISO 3166-1 alpha-2
}

export interface GeocodingResult {
  lat: number
  lon: number
  display_name: string
  address: GeocodingAddress
}

/**
 * Pick the best city-like field from a Nominatim address object.
 * Preference: city > town > village > municipality. Treats empty strings as missing.
 */
export function pickCity(address: GeocodingAddress): string | null {
  if (address.city && address.city.length > 0) return address.city
  if (address.town && address.town.length > 0) return address.town
  if (address.village && address.village.length > 0) return address.village
  if (address.municipality && address.municipality.length > 0) return address.municipality
  return null
}

export function useGeocoding() {
  // Forward and reverse geocoding wrappers are added in Task 2.5.
  return { pickCity }
}
```

- [ ] **Step 2: Run the tests to confirm `pickCity` passes**

```bash
cd management-frontend && npx vitest run app/composables/__tests__/useGeocoding.test.ts 2>&1 | tail -30
```

Expected: all `pickCity` tests PASS. No other failures.

### Task 2.4: Write failing tests for `search` and `reverse`

**Files:**
- Modify: `management-frontend/app/composables/__tests__/useGeocoding.test.ts`

- [ ] **Step 1: Append fetch-mocked tests for `search` and `reverse`**

Add this block at the end of the existing test file:

```ts
// ── search + reverse: mocked fetch ───────────────────────────────────────

// Stub #imports so useGeocoding's `useI18n` resolves inside vitest.
vi.mock('#imports', () => {
  return {
    useI18n: () => ({
      locale: { value: 'de' },
    }),
  }
})

// Re-import to get the hoisted-mocked version of the composable.
// (Vitest hoists vi.mock() above imports, so the static import at
// the top of this file already uses the mocked #imports.)
import { useGeocoding } from '../useGeocoding'

const originalFetch = globalThis.fetch

describe('useGeocoding.search', () => {
  beforeEach(() => {
    globalThis.fetch = vi.fn()
  })
  afterEach(() => {
    globalThis.fetch = originalFetch
  })

  it('hits /search with q, format, addressdetails, limit params', async () => {
    ;(globalThis.fetch as any).mockResolvedValue({
      ok: true,
      json: async () => [],
    })
    const { search } = useGeocoding()
    await search('Berlin')
    const call = (globalThis.fetch as any).mock.calls[0]
    const url = call[0] as string
    expect(url.startsWith(`${NOMINATIM_BASE}/search?`)).toBe(true)
    expect(url).toContain('q=Berlin')
    expect(url).toContain('format=json')
    expect(url).toContain('addressdetails=1')
    expect(url).toContain('limit=5')
  })

  it('sends User-Agent and Accept-Language headers', async () => {
    ;(globalThis.fetch as any).mockResolvedValue({
      ok: true,
      json: async () => [],
    })
    const { search } = useGeocoding()
    await search('Berlin')
    const init = (globalThis.fetch as any).mock.calls[0][1] as RequestInit
    const headers = init.headers as Record<string, string>
    expect(headers['User-Agent']).toContain('MDBCashless-Management')
    expect(headers['Accept-Language']).toBe('de')
  })

  it('URL-encodes the query', async () => {
    ;(globalThis.fetch as any).mockResolvedValue({
      ok: true,
      json: async () => [],
    })
    const { search } = useGeocoding()
    await search('Musterstraße 1, Berlin')
    const url = (globalThis.fetch as any).mock.calls[0][0] as string
    expect(url).toContain('Musterstra%C3%9Fe')
    expect(url).toContain('%2C') // comma
  })

  it('parses results into GeocodingResult[]', async () => {
    ;(globalThis.fetch as any).mockResolvedValue({
      ok: true,
      json: async () => [
        {
          lat: '52.53',
          lon: '13.38',
          display_name: 'Musterstraße 1, 10115 Berlin, Deutschland',
          address: {
            road: 'Musterstraße',
            house_number: '1',
            postcode: '10115',
            city: 'Berlin',
            country_code: 'de',
          },
        },
      ],
    })
    const { search } = useGeocoding()
    const results = await search('Berlin')
    expect(results).toHaveLength(1)
    expect(results[0].lat).toBe(52.53)
    expect(results[0].lon).toBe(13.38)
    expect(results[0].address.city).toBe('Berlin')
    expect(results[0].address.country_code).toBe('de')
  })

  it('returns [] when the response is not ok', async () => {
    ;(globalThis.fetch as any).mockResolvedValue({
      ok: false,
      status: 503,
      json: async () => [],
    })
    const { search } = useGeocoding()
    const results = await search('Berlin')
    expect(results).toEqual([])
  })

  it('passes through an AbortSignal', async () => {
    ;(globalThis.fetch as any).mockResolvedValue({
      ok: true,
      json: async () => [],
    })
    const controller = new AbortController()
    const { search } = useGeocoding()
    await search('Berlin', controller.signal)
    const init = (globalThis.fetch as any).mock.calls[0][1] as RequestInit
    expect(init.signal).toBe(controller.signal)
  })

  it('returns [] for empty or too-short queries without fetching', async () => {
    ;(globalThis.fetch as any).mockResolvedValue({ ok: true, json: async () => [] })
    const { search } = useGeocoding()
    expect(await search('')).toEqual([])
    expect(await search('a')).toEqual([])
    expect((globalThis.fetch as any).mock.calls).toHaveLength(0)
  })
})

describe('useGeocoding.reverse', () => {
  beforeEach(() => {
    globalThis.fetch = vi.fn()
  })
  afterEach(() => {
    globalThis.fetch = originalFetch
  })

  it('hits /reverse with lat, lon, format, addressdetails', async () => {
    ;(globalThis.fetch as any).mockResolvedValue({
      ok: true,
      json: async () => ({
        lat: '52.53',
        lon: '13.38',
        display_name: 'Musterstraße 1, Berlin',
        address: { road: 'Musterstraße', city: 'Berlin', country_code: 'de' },
      }),
    })
    const { reverse } = useGeocoding()
    await reverse(52.53, 13.38)
    const url = (globalThis.fetch as any).mock.calls[0][0] as string
    expect(url.startsWith(`${NOMINATIM_BASE}/reverse?`)).toBe(true)
    expect(url).toContain('lat=52.53')
    expect(url).toContain('lon=13.38')
    expect(url).toContain('format=json')
    expect(url).toContain('addressdetails=1')
  })

  it('parses the response into a GeocodingResult', async () => {
    ;(globalThis.fetch as any).mockResolvedValue({
      ok: true,
      json: async () => ({
        lat: '48.85',
        lon: '2.35',
        display_name: '1 Rue de Rivoli, 75004 Paris, France',
        address: { road: 'Rue de Rivoli', house_number: '1', postcode: '75004', city: 'Paris', country_code: 'fr' },
      }),
    })
    const { reverse } = useGeocoding()
    const result = await reverse(48.85, 2.35)
    expect(result).not.toBeNull()
    expect(result!.lat).toBe(48.85)
    expect(result!.address.city).toBe('Paris')
    expect(result!.address.country_code).toBe('fr')
  })

  it('returns null when the response is not ok', async () => {
    ;(globalThis.fetch as any).mockResolvedValue({
      ok: false,
      status: 503,
      json: async () => ({}),
    })
    const { reverse } = useGeocoding()
    expect(await reverse(0, 0)).toBeNull()
  })

  it('passes through an AbortSignal', async () => {
    ;(globalThis.fetch as any).mockResolvedValue({
      ok: true,
      json: async () => ({ lat: '0', lon: '0', display_name: '', address: {} }),
    })
    const controller = new AbortController()
    const { reverse } = useGeocoding()
    await reverse(0, 0, controller.signal)
    const init = (globalThis.fetch as any).mock.calls[0][1] as RequestInit
    expect(init.signal).toBe(controller.signal)
  })
})
```

- [ ] **Step 2: Run the tests to confirm the new ones fail**

```bash
cd management-frontend && npx vitest run app/composables/__tests__/useGeocoding.test.ts 2>&1 | tail -40
```

Expected: `pickCity` tests still PASS, all `search`/`reverse` tests FAIL with "search is not a function" or equivalent. The `vi.mock('#imports', ...)` block must not cause import errors — if it does, move it above the static `import { pickCity, ... }` line at the top of the file (vitest hoists `vi.mock` automatically but keeping a consistent ordering helps readability).

### Task 2.5: Implement `search` and `reverse`

**Files:**
- Modify: `management-frontend/app/composables/useGeocoding.ts`

- [ ] **Step 1: Replace the stub `useGeocoding()` body with the full implementation**

Replace the existing `useGeocoding` function with:

```ts
export function useGeocoding() {
  const { locale } = useI18n()

  function buildHeaders(): Record<string, string> {
    return {
      'User-Agent': USER_AGENT,
      'Accept-Language': locale.value || 'en',
    }
  }

  /**
   * Forward geocoding. Called once per user action (Enter / Search button).
   * Returns [] for empty or too-short queries (no request sent).
   * Returns [] on non-2xx responses rather than throwing.
   */
  async function search(query: string, signal?: AbortSignal): Promise<GeocodingResult[]> {
    const q = query.trim()
    if (q.length < 2) return []
    // Truncate extremely long queries client-side (policy: keep requests small)
    const clipped = q.length > 200 ? q.slice(0, 200) : q
    const params = new URLSearchParams({
      q: clipped,
      format: 'json',
      addressdetails: '1',
      limit: '5',
    })
    const url = `${NOMINATIM_BASE}/search?${params.toString()}`
    try {
      const res = await fetch(url, { headers: buildHeaders(), signal })
      if (!res.ok) return []
      const data = (await res.json()) as Array<{
        lat: string
        lon: string
        display_name: string
        address?: GeocodingAddress
      }>
      return data.map(d => ({
        lat: Number(d.lat),
        lon: Number(d.lon),
        display_name: d.display_name,
        address: d.address ?? {},
      }))
    } catch (err) {
      // AbortError and network failures both surface as thrown errors;
      // callers only care about the result list, so swallow and return [].
      if ((err as Error).name === 'AbortError') return []
      console.warn('[useGeocoding.search] failed:', err)
      return []
    }
  }

  /**
   * Reverse geocoding. Called once per user action (pin dragend, map click).
   * Returns null on error or non-2xx.
   */
  async function reverse(lat: number, lon: number, signal?: AbortSignal): Promise<GeocodingResult | null> {
    const params = new URLSearchParams({
      lat: String(lat),
      lon: String(lon),
      format: 'json',
      addressdetails: '1',
    })
    const url = `${NOMINATIM_BASE}/reverse?${params.toString()}`
    try {
      const res = await fetch(url, { headers: buildHeaders(), signal })
      if (!res.ok) return null
      const d = (await res.json()) as {
        lat: string
        lon: string
        display_name: string
        address?: GeocodingAddress
      }
      return {
        lat: Number(d.lat),
        lon: Number(d.lon),
        display_name: d.display_name,
        address: d.address ?? {},
      }
    } catch (err) {
      if ((err as Error).name === 'AbortError') return null
      console.warn('[useGeocoding.reverse] failed:', err)
      return null
    }
  }

  return { search, reverse, pickCity }
}
```

- [ ] **Step 2: Run the tests — everything should pass**

```bash
cd management-frontend && npx vitest run app/composables/__tests__/useGeocoding.test.ts 2>&1 | tail -40
```

Expected: all tests PASS (pickCity + search + reverse). The "returns [] for empty or too-short queries without fetching" test specifically verifies no fetch call for `''` or `'a'`.

- [ ] **Step 3: TypeScript check**

```bash
cd management-frontend && npx vue-tsc --noEmit 2>&1 | tail -20
```

Expected: no new errors from the new file.

- [ ] **Step 4: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless && git add management-frontend/app/composables/useGeocoding.ts management-frontend/app/composables/__tests__/useGeocoding.test.ts && git commit -m "$(cat <<'EOF'
feat(frontend): add useGeocoding composable (Nominatim wrapper)

Policy-compliant Nominatim client: no autocomplete, identifying
User-Agent, i18n-aware Accept-Language, AbortSignal passthrough,
2-char minimum, 200-char clip. Returns [] / null on errors instead
of throwing, so callers stay simple.

Includes unit tests for pickCity helper and mocked-fetch tests for
search/reverse covering URL shape, headers, encoding, parsing,
error handling, and AbortSignal.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Chunk 3: LocationPicker Component

Goal: a self-contained reusable editor that exposes `v-model` for location data, renders a search box + Leaflet map with a draggable pin, and triggers geocoding on the right user actions.

### Task 3.1: Create the component skeleton

**Files:**
- Create: `management-frontend/app/components/LocationPicker.vue`

- [ ] **Step 1: Create the file with the static structure + script setup**

Create a minimum viable component so the file exists and Vite/TypeScript can find it. We'll flesh out the map next.

```vue
<script setup lang="ts">
import { ref, onMounted, onBeforeUnmount } from 'vue'
import { useI18n } from '#imports'
import { useGeocoding, pickCity, type GeocodingResult } from '~/composables/useGeocoding'
import 'leaflet/dist/leaflet.css'
import L from 'leaflet'

export interface LocationModel {
  location_lat: number | null
  location_lon: number | null
  address_street: string | null
  address_house_number: string | null
  address_postal_code: string | null
  address_city: string | null
  formatted_address: string | null
  country_code: string | null
}

const props = defineProps<{
  modelValue: LocationModel
}>()

const emit = defineEmits<{
  (e: 'update:modelValue', value: LocationModel): void
  (e: 'clear'): void
}>()

const { t } = useI18n()
const { search, reverse } = useGeocoding()

// Search state
const query = ref('')
const results = ref<GeocodingResult[]>([])
const searching = ref(false)
const searchError = ref<string | null>(null)

// Shared AbortController for in-flight requests
let abortController: AbortController | null = null

// Map state
const mapContainer = ref<HTMLDivElement | null>(null)
let map: L.Map | null = null
let marker: L.Marker | null = null

// Lifecycle — stub for now, implemented in Task 3.2
onMounted(() => {
  // initMap()  — filled in Task 3.2
})

onBeforeUnmount(() => {
  abortController?.abort()
  if (map) {
    map.remove()
    map = null
  }
})
</script>

<template>
  <div class="flex flex-col gap-3">
    <!-- Search input -->
    <div>
      <label class="text-xs font-medium text-muted-foreground">
        {{ t('machineSettings.addressLabel') }}
      </label>
      <div class="mt-1 flex gap-2">
        <input
          v-model="query"
          type="text"
          :placeholder="t('machineSettings.addressPlaceholder')"
          class="flex-1 h-9 rounded-md border border-input bg-background px-3 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          @keydown.enter.prevent="onSearchSubmit"
        />
        <button
          type="button"
          class="h-9 rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow hover:bg-primary/90 disabled:opacity-50"
          :disabled="searching || query.trim().length < 2"
          @click="onSearchSubmit"
        >
          {{ searching ? t('machineSettings.searching') : t('machineSettings.searchButton') }}
        </button>
      </div>
      <p v-if="searchError" class="mt-1 text-xs text-destructive">{{ searchError }}</p>

      <!-- Results list (only after submit) -->
      <ul v-if="results.length > 0" class="mt-2 max-h-48 overflow-y-auto rounded-md border border-input bg-popover shadow-sm">
        <li
          v-for="(r, i) in results"
          :key="i"
          class="cursor-pointer border-b border-border px-3 py-2 text-sm last:border-b-0 hover:bg-accent"
          @click="onPickResult(r)"
        >
          <div class="font-medium">{{ r.display_name }}</div>
          <div class="text-xs text-muted-foreground">
            {{ r.address.city ?? r.address.town ?? '' }}{{ r.address.country_code ? `, ${r.address.country_code.toUpperCase()}` : '' }}
          </div>
        </li>
      </ul>
      <p v-else-if="results.length === 0 && !searching && query.trim().length >= 2 && hasSubmitted" class="mt-1 text-xs text-muted-foreground">
        {{ t('machineSettings.noResults') }}
      </p>
    </div>

    <!-- Map -->
    <div ref="mapContainer" class="h-[200px] w-full rounded-md border border-input sm:h-[280px]" />
    <p v-if="modelValue.location_lat && modelValue.location_lon" class="text-xs text-muted-foreground">
      {{ t('machineSettings.pinHint') }}
    </p>

    <!-- Detected address preview -->
    <div
      v-if="modelValue.formatted_address || modelValue.address_street || modelValue.address_city"
      class="rounded-md border border-input bg-muted/30 p-3 text-xs"
    >
      <div class="mb-1 text-[10px] font-medium uppercase tracking-wide text-muted-foreground">
        {{ t('machineSettings.detectedAddress') }}
      </div>
      <div class="grid grid-cols-2 gap-x-3 gap-y-1">
        <div><span class="text-muted-foreground">{{ t('machineSettings.street') }}:</span> {{ modelValue.address_street ?? '—' }} {{ modelValue.address_house_number ?? '' }}</div>
        <div><span class="text-muted-foreground">{{ t('machineSettings.postalCode') }}:</span> {{ modelValue.address_postal_code ?? '—' }}</div>
        <div><span class="text-muted-foreground">{{ t('machineSettings.city') }}:</span> {{ modelValue.address_city ?? '—' }}</div>
        <div><span class="text-muted-foreground">{{ t('machineSettings.country') }}:</span> {{ modelValue.country_code ?? '—' }}</div>
      </div>
      <div v-if="modelValue.location_lat && modelValue.location_lon" class="mt-1 font-mono text-[10px] text-muted-foreground">
        {{ modelValue.location_lat.toFixed(5) }}, {{ modelValue.location_lon.toFixed(5) }}
      </div>
    </div>
  </div>
</template>
```

Add a `hasSubmitted` ref and the `onSearchSubmit` / `onPickResult` stubs after `searchError`:

```ts
const hasSubmitted = ref(false)

async function onSearchSubmit() {
  // implemented in Task 3.3
}

function onPickResult(_r: GeocodingResult) {
  // implemented in Task 3.3
}
```

- [ ] **Step 2: Type-check that the skeleton compiles**

```bash
cd management-frontend && npx vue-tsc --noEmit 2>&1 | tail -20
```

Expected: no new errors. If Leaflet complains about types, make sure `@types/leaflet` is installed (Task 2.1 should have covered that).

### Task 3.2: Implement map initialization

**Files:**
- Modify: `management-frontend/app/components/LocationPicker.vue` (replace the `onMounted` stub)

- [ ] **Step 1: Implement `initMap` with the three modes from the spec**

Add an `initMap` function directly above `onMounted` and have `onMounted` call it:

```ts
function initMap() {
  if (!mapContainer.value) return

  // Default: mid-Europe wide view, no pin
  let initialCenter: [number, number] = [51.0, 10.0]
  let initialZoom = 4

  // If we already have coordinates, center on them with a close zoom and place a pin
  const hasCoords = props.modelValue.location_lat != null && props.modelValue.location_lon != null
  if (hasCoords) {
    initialCenter = [props.modelValue.location_lat!, props.modelValue.location_lon!]
    initialZoom = 17
  }

  map = L.map(mapContainer.value).setView(initialCenter, initialZoom)

  L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
    maxZoom: 19,
    attribution: '© <a href="https://www.openstreetmap.org/copyright">OpenStreetMap contributors</a>',
  }).addTo(map)

  if (hasCoords) {
    placePin(props.modelValue.location_lat!, props.modelValue.location_lon!)
  } else if (typeof navigator !== 'undefined' && navigator.geolocation) {
    // Try browser geolocation as a convenience (admin probably near the machine)
    navigator.geolocation.getCurrentPosition(
      (pos) => {
        if (map) map.setView([pos.coords.latitude, pos.coords.longitude], 15)
      },
      () => {
        // Silently ignore — user denied or timed out
      },
      { timeout: 5000 },
    )
  }

  // Click on empty map places a pin and triggers reverse geocoding
  map.on('click', (e: L.LeafletMouseEvent) => {
    const { lat, lng } = e.latlng
    placePin(lat, lng)
    updateCoords(lat, lng)
    void runReverseGeocoding(lat, lng)
  })
}

function placePin(lat: number, lng: number) {
  if (!map) return
  if (marker) {
    marker.setLatLng([lat, lng])
  } else {
    marker = L.marker([lat, lng], { draggable: true }).addTo(map)
    marker.on('dragend', () => {
      if (!marker) return
      const { lat: newLat, lng: newLng } = marker.getLatLng()
      updateCoords(newLat, newLng)
      void runReverseGeocoding(newLat, newLng)
    })
  }
}

function updateCoords(lat: number, lng: number) {
  emit('update:modelValue', {
    ...props.modelValue,
    location_lat: lat,
    location_lon: lng,
  })
}

async function runReverseGeocoding(lat: number, lng: number) {
  abortController?.abort()
  abortController = new AbortController()
  const result = await reverse(lat, lng, abortController.signal)
  if (!result) return
  applyGeocodingResult(result, { keepCoords: true })
}

function applyGeocodingResult(r: GeocodingResult, opts: { keepCoords: boolean }) {
  emit('update:modelValue', {
    ...props.modelValue,
    location_lat: opts.keepCoords ? props.modelValue.location_lat : r.lat,
    location_lon: opts.keepCoords ? props.modelValue.location_lon : r.lon,
    address_street: r.address.road ?? null,
    address_house_number: r.address.house_number ?? null,
    address_postal_code: r.address.postcode ?? null,
    address_city: pickCity(r.address),
    formatted_address: r.display_name,
    country_code: r.address.country_code ? r.address.country_code.toUpperCase() : null,
  })
}
```

Then update `onMounted`:

```ts
onMounted(() => {
  initMap()
})
```

- [ ] **Step 2: Type-check**

```bash
cd management-frontend && npx vue-tsc --noEmit 2>&1 | tail -20
```

Expected: no new errors.

### Task 3.3: Implement search submit and result pick

**Files:**
- Modify: `management-frontend/app/components/LocationPicker.vue` (replace the `onSearchSubmit` and `onPickResult` stubs)

- [ ] **Step 1: Implement the two handlers**

Replace the stub functions with:

```ts
async function onSearchSubmit() {
  const q = query.value.trim()
  if (q.length < 2) {
    searchError.value = t('machineSettings.geocodingError')
    return
  }
  abortController?.abort()
  abortController = new AbortController()
  searching.value = true
  searchError.value = null
  hasSubmitted.value = true
  try {
    const found = await search(q, abortController.signal)
    results.value = found
    if (found.length === 0) {
      searchError.value = null // "no results" hint is rendered inline in template
    }
  } catch (err) {
    searchError.value = t('machineSettings.geocodingError')
    console.warn('[LocationPicker] search failed', err)
  } finally {
    searching.value = false
  }
}

function onPickResult(r: GeocodingResult) {
  // Place pin on the map and center on it
  if (map) {
    map.setView([r.lat, r.lon], 17)
    placePin(r.lat, r.lon)
  }
  // Apply all the fields, including fresh coordinates from the search result
  applyGeocodingResult(r, { keepCoords: false })
  // Clear the results list so the user can see the preview
  results.value = []
  hasSubmitted.value = false
}
```

- [ ] **Step 2: Commit the LocationPicker so far**

Don't run tests yet — this component is manually-tested. Run the build to make sure the SFC compiles.

```bash
cd management-frontend && npm run build 2>&1 | tail -30
```

Expected: build succeeds. If Leaflet CSS import triggers an SSR warning, that's expected — the component is rendered inside `<ClientOnly>` at consumption time (Task 4.5, 5.2).

- [ ] **Step 3: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless && git add management-frontend/app/components/LocationPicker.vue && git commit -m "$(cat <<'EOF'
feat(frontend): add LocationPicker component

Reusable v-model component for editing a machine's location:
- Search input with submit-on-Enter (no autocomplete)
- Post-submit results list
- Leaflet map with OSM tiles and ODbL attribution
- Empty-state: no pin, tries browser geolocation, falls back to Europe
- Draggable pin with reverse geocoding on dragend
- Map click places pin + reverse geocodes
- Shared AbortController cancels in-flight requests

Must be wrapped in <ClientOnly> by the parent (Leaflet uses window).

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Chunk 4: i18n + MachineSettingsModal + useMachines Write Paths

Goal: the picker is wrapped in a modal and connected to Supabase via a new composable helper; strings are localized in DE and EN.

### Task 4.1: Add i18n keys

**Files:**
- Modify: `management-frontend/app/i18n/locales/de.json`
- Modify: `management-frontend/app/i18n/locales/en.json`

- [ ] **Step 1: Locate the machineDetail-adjacent section in both files**

```bash
cd management-frontend && grep -n '"machineDetail"' app/i18n/locales/de.json app/i18n/locales/en.json
```

Expected: one line per file.

- [ ] **Step 2: Insert a new top-level `machineSettings` object in `de.json`**

Add this object as a sibling of `machineDetail` (typically immediately after it; pick a spot that fits the file's existing alphabetical or grouped order):

```json
"machineSettings": {
  "title": "Automat-Einstellungen",
  "addressLabel": "Adresse suchen",
  "addressPlaceholder": "z. B. Musterstraße 1, Berlin",
  "searchButton": "Suchen",
  "searching": "Suche läuft…",
  "detectedAddress": "Erkannte Adresse",
  "street": "Straße",
  "postalCode": "PLZ",
  "city": "Stadt",
  "country": "Land",
  "clearLocation": "Standort entfernen",
  "pinHint": "Pin ziehen für exakte Position",
  "mapLoading": "Karte wird geladen…",
  "geocodingError": "Adresse konnte nicht gefunden werden",
  "noResults": "Keine Treffer",
  "countryAutoHint": "Aus Adresse übernommen, manuell überschreibbar",
  "setLocationOptional": "Standort jetzt festlegen (optional)",
  "save": "Speichern",
  "cancel": "Abbrechen"
}
```

- [ ] **Step 3: Insert the same structure in `en.json` with English values**

```json
"machineSettings": {
  "title": "Machine settings",
  "addressLabel": "Search address",
  "addressPlaceholder": "e.g. Main Street 1, Berlin",
  "searchButton": "Search",
  "searching": "Searching…",
  "detectedAddress": "Detected address",
  "street": "Street",
  "postalCode": "Postal code",
  "city": "City",
  "country": "Country",
  "clearLocation": "Clear location",
  "pinHint": "Drag pin for exact position",
  "mapLoading": "Loading map…",
  "geocodingError": "Address not found",
  "noResults": "No results",
  "countryAutoHint": "Derived from address, can be overridden",
  "setLocationOptional": "Set location now (optional)",
  "save": "Save",
  "cancel": "Cancel"
}
```

- [ ] **Step 4: Verify JSON validity**

```bash
cd management-frontend && node -e "JSON.parse(require('fs').readFileSync('app/i18n/locales/de.json','utf8'))" && node -e "JSON.parse(require('fs').readFileSync('app/i18n/locales/en.json','utf8'))" && echo OK
```

Expected: `OK` printed, no parse errors.

- [ ] **Step 5: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless && git add management-frontend/app/i18n/locales/de.json management-frontend/app/i18n/locales/en.json && git commit -m "$(cat <<'EOF'
feat(i18n): add machineSettings keys for location editor

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 4.2: Add `updateMachineSettings` to `useMachines`

**Files:**
- Modify: `management-frontend/app/composables/useMachines.ts`

- [ ] **Step 1: Add the helper function near `createMachine`**

Insert this function right after the existing `createMachine`:

```ts
export interface MachineSettingsPatch {
  location_lat: number | null
  location_lon: number | null
  address_street: string | null
  address_house_number: string | null
  address_postal_code: string | null
  address_city: string | null
  formatted_address: string | null
  country_code: string | null
}

async function updateMachineSettings(machineId: string, patch: MachineSettingsPatch): Promise<void> {
  const supabase = useSupabaseClient()
  const { error } = await supabase
    .from('vendingMachine')
    .update(patch as any)
    .eq('id', machineId)
  if (error) throw error
  // Optimistically update the local cache so the list re-renders without
  // waiting for the realtime subscription to fire.
  const machine = machines.value.find(m => m.id === machineId)
  if (machine) {
    machine.location_lat = patch.location_lat
    machine.location_lon = patch.location_lon
    machine.country_code = patch.country_code
    machine.address_street = patch.address_street
    machine.address_house_number = patch.address_house_number
    machine.address_postal_code = patch.address_postal_code
    machine.address_city = patch.address_city
    machine.formatted_address = patch.formatted_address
  }
}
```

- [ ] **Step 2: Extend `createMachine` to accept an optional location**

Replace the existing function body:

```ts
async function createMachine(
  name: string,
  companyId: string,
  location?: MachineSettingsPatch & { location_lat: number; location_lon: number },
): Promise<void> {
  const supabase = useSupabaseClient()
  const insertRow: Record<string, any> = { name, company: companyId }
  if (location) {
    insertRow.location_lat = location.location_lat
    insertRow.location_lon = location.location_lon
    insertRow.address_street = location.address_street
    insertRow.address_house_number = location.address_house_number
    insertRow.address_postal_code = location.address_postal_code
    insertRow.address_city = location.address_city
    insertRow.formatted_address = location.formatted_address
    insertRow.country_code = location.country_code
  }
  const { error } = await supabase.from('vendingMachine').insert(insertRow)
  if (error) throw error
  await fetchMachines()
}
```

- [ ] **Step 3: Export `updateMachineSettings` from `useMachines()`**

Extend the return object at the bottom of `useMachines()`:

```ts
return {
  machines, loading, fetchMachines, fetchUnassignedEmbeddeds, swapDevice, subscribeToStatusUpdates,
  createMachine, updateMachineSettings,
  pendingTokens, fetchPendingTokens, deletePendingToken,
}
```

Also export the `MachineSettingsPatch` type at module level if it's not already exported (the `export interface` declaration in Step 1 handles that).

- [ ] **Step 4: TypeScript check**

```bash
cd management-frontend && npx vue-tsc --noEmit 2>&1 | tail -20
```

Expected: no new errors. Existing call sites of `createMachine(name, companyId)` still compile because the third parameter is optional.

### Task 4.3: Write and pass a test for `updateMachineSettings`

**Files:**
- Create: `management-frontend/app/composables/__tests__/useMachines.test.ts`

Testing the full `useMachines` composable is heavy (many side-effect calls and date logic). We'll add a focused test that only exercises `updateMachineSettings` using the same mocked-Supabase pattern as `useMdbLog.test.ts`.

- [ ] **Step 1: Write the test file**

```ts
import { describe, it, expect, vi, beforeEach } from 'vitest'

// Build a mock Supabase client with chainable from().update().eq() and
// a resolved error of null. We also capture the .update() payload.
const capturedUpdates: Array<Record<string, any>> = []
const mockFrom = {
  update: vi.fn((payload: Record<string, any>) => {
    capturedUpdates.push(payload)
    return mockFrom
  }),
  eq: vi.fn().mockResolvedValue({ error: null }),
  insert: vi.fn().mockResolvedValue({ error: null }),
  select: vi.fn().mockResolvedValue({ data: [], error: null }),
}
const mockSupabase = {
  from: vi.fn(() => mockFrom),
  channel: vi.fn().mockReturnValue({ on: vi.fn().mockReturnThis(), subscribe: vi.fn().mockReturnThis() }),
  removeChannel: vi.fn(),
}

vi.mock('#imports', () => {
  const { ref } = require('vue')
  return {
    ref,
    useState: <T>(_k: string, init?: () => T) => ref(init ? init() : undefined),
    useSupabaseClient: () => mockSupabase,
  }
})

// Lib import is fine because useMachines pulls from lib/stock-health which
// is pure-TS and has no Nuxt/Supabase side effects.
import { useMachines } from '../useMachines'

describe('useMachines.updateMachineSettings', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    capturedUpdates.length = 0
    mockFrom.eq.mockResolvedValue({ error: null })
  })

  it('sends an UPDATE on vendingMachine with the full patch', async () => {
    const { updateMachineSettings } = useMachines()
    await updateMachineSettings('machine-123', {
      location_lat: 52.53,
      location_lon: 13.38,
      address_street: 'Musterstraße',
      address_house_number: '1',
      address_postal_code: '10115',
      address_city: 'Berlin',
      formatted_address: 'Musterstraße 1, 10115 Berlin, Deutschland',
      country_code: 'DE',
    })
    expect(mockSupabase.from).toHaveBeenCalledWith('vendingMachine')
    expect(capturedUpdates).toHaveLength(1)
    expect(capturedUpdates[0]).toMatchObject({
      location_lat: 52.53,
      location_lon: 13.38,
      address_city: 'Berlin',
      country_code: 'DE',
    })
    expect(mockFrom.eq).toHaveBeenCalledWith('id', 'machine-123')
  })

  it('sends nulls on clear', async () => {
    const { updateMachineSettings } = useMachines()
    await updateMachineSettings('machine-123', {
      location_lat: null,
      location_lon: null,
      address_street: null,
      address_house_number: null,
      address_postal_code: null,
      address_city: null,
      formatted_address: null,
      country_code: null,
    })
    expect(capturedUpdates[0]).toMatchObject({
      location_lat: null,
      location_lon: null,
      address_city: null,
      country_code: null,
    })
  })

  it('throws when Supabase returns an error', async () => {
    mockFrom.eq.mockResolvedValueOnce({ error: { message: 'boom' } })
    const { updateMachineSettings } = useMachines()
    await expect(
      updateMachineSettings('machine-123', {
        location_lat: 0,
        location_lon: 0,
        address_street: null,
        address_house_number: null,
        address_postal_code: null,
        address_city: null,
        formatted_address: null,
        country_code: null,
      }),
    ).rejects.toBeDefined()
  })
})
```

- [ ] **Step 2: Run the test**

```bash
cd management-frontend && npx vitest run app/composables/__tests__/useMachines.test.ts 2>&1 | tail -40
```

Expected: all 3 tests PASS. If there's a "useState is not a function" error, the `#imports` mock needs the extra `useState` entry — it's included above, but double-check that the mock file matches.

- [ ] **Step 3: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless && git add management-frontend/app/composables/useMachines.ts management-frontend/app/composables/__tests__/useMachines.test.ts && git commit -m "$(cat <<'EOF'
feat(frontend): add updateMachineSettings + extend createMachine

- New updateMachineSettings(machineId, patch) helper in useMachines,
  with optimistic local cache update for instant UI refresh
- createMachine(name, companyId, location?) accepts an optional
  location payload so the create-machine modal can persist address
  in the same insert
- Unit tests for updateMachineSettings via mocked Supabase client

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 4.4: Create the MachineSettingsModal component

**Files:**
- Create: `management-frontend/app/components/MachineSettingsModal.vue`

- [ ] **Step 1: Create the file**

```vue
<script setup lang="ts">
import { ref, watch } from 'vue'
import { useI18n } from '#imports'
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
} from '~/components/ui/dialog'
import LocationPicker, { type LocationModel } from '~/components/LocationPicker.vue'
import { useMachines, type MachineSettingsPatch } from '~/composables/useMachines'

// Country option list — copy the existing COUNTRY_OPTIONS structure from
// app/pages/machines/[id].vue. If that file exports it, import instead.
const COUNTRY_OPTIONS: { code: string; label: string }[] = [
  { code: 'DE', label: 'Deutschland' },
  { code: 'AT', label: 'Österreich' },
  { code: 'CH', label: 'Schweiz' },
  { code: 'FR', label: 'France' },
  { code: 'IT', label: 'Italia' },
  { code: 'NL', label: 'Nederland' },
  { code: 'BE', label: 'België' },
  { code: 'LU', label: 'Luxembourg' },
  { code: 'PL', label: 'Polska' },
  { code: 'CZ', label: 'Česko' },
  { code: 'ES', label: 'España' },
  { code: 'GB', label: 'United Kingdom' },
]

const props = defineProps<{
  open: boolean
  machineId: string
  initial: Partial<LocationModel>
}>()

const emit = defineEmits<{
  (e: 'update:open', value: boolean): void
  (e: 'saved'): void
}>()

const { t } = useI18n()
const { updateMachineSettings } = useMachines()

const form = ref<LocationModel>(cloneInitial())
const saving = ref(false)
const errorMsg = ref<string | null>(null)

function cloneInitial(): LocationModel {
  return {
    location_lat: props.initial.location_lat ?? null,
    location_lon: props.initial.location_lon ?? null,
    address_street: props.initial.address_street ?? null,
    address_house_number: props.initial.address_house_number ?? null,
    address_postal_code: props.initial.address_postal_code ?? null,
    address_city: props.initial.address_city ?? null,
    formatted_address: props.initial.formatted_address ?? null,
    country_code: props.initial.country_code ?? null,
  }
}

// Reset the form every time the modal opens fresh
watch(
  () => props.open,
  (isOpen) => {
    if (isOpen) {
      form.value = cloneInitial()
      errorMsg.value = null
    }
  },
)

async function save() {
  saving.value = true
  errorMsg.value = null
  try {
    await updateMachineSettings(props.machineId, form.value as MachineSettingsPatch)
    emit('saved')
    emit('update:open', false)
  } catch (err) {
    errorMsg.value = (err as Error).message ?? 'Unknown error'
  } finally {
    saving.value = false
  }
}

function clearLocation() {
  form.value.location_lat = null
  form.value.location_lon = null
  form.value.address_street = null
  form.value.address_house_number = null
  form.value.address_postal_code = null
  form.value.address_city = null
  form.value.formatted_address = null
  form.value.country_code = null
}

function cancel() {
  emit('update:open', false)
}
</script>

<template>
  <Dialog :open="open" @update:open="(v) => emit('update:open', v)">
    <DialogContent class="max-h-[90vh] overflow-y-auto sm:max-w-2xl">
      <DialogHeader>
        <DialogTitle>{{ t('machineSettings.title') }}</DialogTitle>
      </DialogHeader>

      <div class="flex flex-col gap-4 py-2">
        <ClientOnly>
          <LocationPicker v-model="form" />
          <template #fallback>
            <div class="flex h-[200px] w-full items-center justify-center rounded-md border border-dashed text-sm text-muted-foreground">
              {{ t('machineSettings.mapLoading') }}
            </div>
          </template>
        </ClientOnly>

        <!-- Country code override -->
        <div>
          <label class="text-xs font-medium text-muted-foreground">{{ t('machineSettings.country') }}</label>
          <select
            v-model="form.country_code"
            class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          >
            <option :value="null">—</option>
            <option v-for="c in COUNTRY_OPTIONS" :key="c.code" :value="c.code">
              {{ c.code }} — {{ c.label }}
            </option>
          </select>
          <p class="mt-1 text-[10px] text-muted-foreground">{{ t('machineSettings.countryAutoHint') }}</p>
        </div>

        <p v-if="errorMsg" class="text-xs text-destructive">{{ errorMsg }}</p>
      </div>

      <DialogFooter class="flex items-center justify-between gap-2 sm:justify-between">
        <button
          v-if="form.location_lat != null"
          type="button"
          class="text-xs text-destructive hover:underline"
          :disabled="saving"
          @click="clearLocation"
        >
          🗑 {{ t('machineSettings.clearLocation') }}
        </button>
        <div v-else />
        <div class="flex gap-2">
          <button
            type="button"
            class="h-9 rounded-md border border-input bg-background px-4 text-sm font-medium shadow-sm hover:bg-accent"
            :disabled="saving"
            @click="cancel"
          >
            {{ t('machineSettings.cancel') }}
          </button>
          <button
            type="button"
            class="h-9 rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow hover:bg-primary/90 disabled:opacity-50"
            :disabled="saving"
            @click="save"
          >
            {{ t('machineSettings.save') }}
          </button>
        </div>
      </DialogFooter>
    </DialogContent>
  </Dialog>
</template>
```

- [ ] **Step 2: Verify the dialog and dropdown-menu shadcn components exist**

```bash
cd management-frontend && ls app/components/ui/dialog app/components/ui/dropdown-menu 2>&1
```

Expected: both directories list `Dialog*.vue` / `DropdownMenu*.vue` files. If `dropdown-menu` doesn't exist yet, add it via shadcn-nuxt's CLI:

```bash
cd management-frontend && npx shadcn-vue@latest add dropdown-menu
```

- [ ] **Step 3: Type-check and build**

```bash
cd management-frontend && npx vue-tsc --noEmit 2>&1 | tail -20
cd management-frontend && npm run build 2>&1 | tail -30
```

Expected: no new errors, build succeeds. Leaflet should appear as a separate async chunk in `dist/` because it's only loaded inside `<ClientOnly>`.

- [ ] **Step 4: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless && git add management-frontend/app/components/MachineSettingsModal.vue && git commit -m "$(cat <<'EOF'
feat(frontend): add MachineSettingsModal component

Wraps LocationPicker + country-code dropdown in a shadcn Dialog.
<ClientOnly> guards the Leaflet-dependent picker to preserve SSR.
Save path goes through useMachines.updateMachineSettings.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Chunk 5: Page Wiring + Manual Verification

Goal: users can actually open the modal, edit location, and create machines with an optional location. Also run through the spec's full verification plan.

### Task 5.1: Wire the settings modal into `machines/[id].vue`

**Files:**
- Modify: `management-frontend/app/pages/machines/[id].vue`

- [ ] **Step 1: Import the new components and modal state**

In the `<script setup>` block, add the new imports near the existing component imports:

```ts
import MachineSettingsModal from '~/components/MachineSettingsModal.vue'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from '~/components/ui/dropdown-menu'
```

Then add the new reactive state near other `ref()` declarations (e.g., after `showDeviceInfoModal`):

```ts
const showMachineSettingsModal = ref(false)
```

- [ ] **Step 2: Remove the inline country_code dropdown from the header**

Find the block that renders a `<select>` bound to `machine.country_code` and calls `updateMachineCountry` (identified by the `@change="updateMachineCountry(...)"` handler). Delete the entire `<div class="mt-1.5 flex items-center gap-2">…</div>` block that wraps the label + select.

Also delete the `updateMachineCountry` function in `<script setup>` — it's replaced by `updateMachineSettings` via the modal.

- [ ] **Step 3: Replace the ⚙ button with a DropdownMenu**

Find the existing button that sets `showDeviceInfoModal = true` (the gear icon, identified by `:title="t('machineDetail.deviceDetails')"`). Replace it with:

```vue
<DropdownMenu>
  <DropdownMenuTrigger as-child>
    <button
      class="inline-flex h-8 w-8 items-center justify-center rounded-md border text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
      :title="t('machineDetail.settings')"
    >
      <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z"/><circle cx="12" cy="12" r="3"/></svg>
    </button>
  </DropdownMenuTrigger>
  <DropdownMenuContent align="end">
    <DropdownMenuItem v-if="isAdmin" @click="showMachineSettingsModal = true">
      {{ t('machineSettings.title') }}
    </DropdownMenuItem>
    <DropdownMenuItem @click="showDeviceInfoModal = true">
      {{ t('machineDetail.deviceDetails') }}
    </DropdownMenuItem>
  </DropdownMenuContent>
</DropdownMenu>
```

- [ ] **Step 4: Make the coordinates text clickable**

Find the existing `<p>` that renders `machine.location_lat.toFixed(5)`. Wrap it in a `<button>` so it also opens the settings modal when clicked. Keep it visually the same (no underline, same color) but add `@click="isAdmin && (showMachineSettingsModal = true)"` and a `cursor-pointer` class when `isAdmin`.

```vue
<p
  v-if="machine.location_lat && machine.location_lon"
  class="mt-1 text-sm text-muted-foreground"
  :class="{ 'cursor-pointer hover:text-foreground transition-colors': isAdmin }"
  @click="isAdmin && (showMachineSettingsModal = true)"
>
  {{ machine.location_lat.toFixed(5) }}, {{ machine.location_lon.toFixed(5) }}
</p>
```

- [ ] **Step 5: Render the modal at the bottom of the template**

Just before the closing `</template>` of the main page template, add:

```vue
<MachineSettingsModal
  v-if="machine"
  v-model:open="showMachineSettingsModal"
  :machine-id="machine.id"
  :initial="{
    location_lat: machine.location_lat,
    location_lon: machine.location_lon,
    address_street: (machine as any).address_street ?? null,
    address_house_number: (machine as any).address_house_number ?? null,
    address_postal_code: (machine as any).address_postal_code ?? null,
    address_city: (machine as any).address_city ?? null,
    formatted_address: (machine as any).formatted_address ?? null,
    country_code: machine.country_code,
  }"
  @saved="refreshMachine"
/>
```

(The `refreshMachine` function already exists in `[id].vue`; if it's named differently, pick the one that re-fetches the page's `machine` ref.)

- [ ] **Step 6: Add the i18n key for the settings label**

In both locale files, add `"settings": "Einstellungen"` / `"settings": "Settings"` under the existing `machineDetail` object so the gear button's tooltip resolves:

```json
"machineDetail": {
  ...
  "settings": "Einstellungen",  // de.json
  ...
}
```

- [ ] **Step 7: Type-check**

```bash
cd management-frontend && npx vue-tsc --noEmit 2>&1 | tail -30
```

Expected: no new errors. (You may see existing type errors in `[id].vue` due to the `as any` casts on the new fields — that's consistent with the file's existing style and acceptable.)

- [ ] **Step 8: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless && git add management-frontend/app/pages/machines/\[id\].vue management-frontend/app/i18n/locales/de.json management-frontend/app/i18n/locales/en.json && git commit -m "$(cat <<'EOF'
feat(frontend): wire MachineSettingsModal into machine detail page

- Replace ⚙ icon with DropdownMenu (Automat-Einstellungen + Device-Info)
- Remove inline country_code dropdown from header (moved into modal)
- Make coordinates display clickable (admin-only shortcut to modal)
- Modal pre-fills from current machine row and refreshes on save

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 5.2: Add optional location to the create-machine modal

**Files:**
- Modify: `management-frontend/app/pages/machines/index.vue`

- [ ] **Step 1: Import LocationPicker and extend `machineForm`**

In `<script setup>`, add:

```ts
import LocationPicker, { type LocationModel } from '~/components/LocationPicker.vue'

// Collapsible location section state
const includeLocation = ref(false)
const locationForm = ref<LocationModel>({
  location_lat: null,
  location_lon: null,
  address_street: null,
  address_house_number: null,
  address_postal_code: null,
  address_city: null,
  formatted_address: null,
  country_code: null,
})
```

- [ ] **Step 2: Reset the location form when the create modal closes**

Find the existing `useModalForm` / `closeModal` logic and add a reset for `includeLocation` + `locationForm` in the close handler. If `useModalForm` handles name-field reset via its `form` option, add a separate `watch` on `showMachineModal`:

```ts
watch(showMachineModal, (isOpen) => {
  if (!isOpen) {
    includeLocation.value = false
    locationForm.value = {
      location_lat: null,
      location_lon: null,
      address_street: null,
      address_house_number: null,
      address_postal_code: null,
      address_city: null,
      formatted_address: null,
      country_code: null,
    }
  }
})
```

- [ ] **Step 3: Update `submitCreateMachine` to pass the location**

Change the existing call:

```ts
await submit(() => createMachine(machineForm.value.name.trim(), organization.value!.id))
```

to:

```ts
const locationPayload = includeLocation.value && locationForm.value.location_lat != null && locationForm.value.location_lon != null
  ? {
      location_lat: locationForm.value.location_lat!,
      location_lon: locationForm.value.location_lon!,
      address_street: locationForm.value.address_street,
      address_house_number: locationForm.value.address_house_number,
      address_postal_code: locationForm.value.address_postal_code,
      address_city: locationForm.value.address_city,
      formatted_address: locationForm.value.formatted_address,
      country_code: locationForm.value.country_code,
    }
  : undefined
await submit(() => createMachine(machineForm.value.name.trim(), organization.value!.id, locationPayload))
```

- [ ] **Step 4: Add the collapsible section to the template**

Inside the create-machine modal body (below the name input but above the submit button), add:

```vue
<div class="mt-4 border-t pt-4">
  <button
    type="button"
    class="flex w-full items-center justify-between text-sm font-medium text-muted-foreground hover:text-foreground"
    @click="includeLocation = !includeLocation"
  >
    <span>{{ t('machineSettings.setLocationOptional') }}</span>
    <span>{{ includeLocation ? '−' : '+' }}</span>
  </button>
  <div v-if="includeLocation" class="mt-3">
    <ClientOnly>
      <LocationPicker v-model="locationForm" />
      <template #fallback>
        <div class="flex h-[200px] w-full items-center justify-center rounded-md border border-dashed text-sm text-muted-foreground">
          {{ t('machineSettings.mapLoading') }}
        </div>
      </template>
    </ClientOnly>
  </div>
</div>
```

- [ ] **Step 5: Type-check and build**

```bash
cd management-frontend && npx vue-tsc --noEmit 2>&1 | tail -20
cd management-frontend && npm run build 2>&1 | tail -30
```

Expected: no new errors, successful build.

- [ ] **Step 6: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless && git add management-frontend/app/pages/machines/index.vue && git commit -m "$(cat <<'EOF'
feat(frontend): add optional location picker to create-machine modal

Collapsible 'Standort jetzt festlegen (optional)' section embeds
LocationPicker (wrapped in ClientOnly). When expanded and a pin is
placed, the full address patch is inserted into vendingMachine in
the same request.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 5.3: Manual verification (full spec Verification Plan)

**Files:**
- None (runtime checks only)

Run the dev server and walk through every item from the spec's Verification Plan. For each item, tick the box once you've confirmed it passes.

- [ ] **Step 1: Start the dev server**

```bash
cd management-frontend && npm run dev
```

Leave it running. Open http://localhost:3000 (or the LAN IP that gets printed).

- [ ] **Step 2: (Verification 1) Migration applied**

Already verified in Task 1.1, Step 3. Confirm the dev server starts without schema-mismatch errors and the `/machines` list renders.

- [ ] **Step 3: (Verification 2) Backward compatibility — ESP32 firmware**

Confirm an existing ESP32 device can still publish `sale` events:
- Open Supabase Studio → `sales` table and watch for inserts.
- Trigger a vend on a physical device (or simulate with the master ESP32 or a manual MQTT publish).
- Expected: the sale row still gets inserted, `machine_id` populated correctly, and the machines list reflects today's revenue.

If no physical hardware is available, skip the hardware test and instead confirm via grep that no migration/edge-function changed any MQTT topic or payload format:

```bash
grep -r "address_street\|address_city\|formatted_address" Docker/supabase/functions/ 2>&1
```

Expected: no matches (edge functions untouched).

- [ ] **Step 4: (Verification 3) Build succeeds, Leaflet is code-split**

```bash
cd management-frontend && npm run build 2>&1 | tail -20 && ls -lh .output/public/_nuxt/ 2>/dev/null | grep -i leaflet
```

Expected: build succeeds; a `leaflet.*.js` chunk appears in the output directory. Exact name/path depends on Nitro config.

- [ ] **Step 5: (Verification 4) SSR render**

Open http://localhost:3000/machines/<some-id> with browser DevTools → Network → disable JS. Reload.
Expected: the page's non-interactive parts render (machine name, tabs) without hydration errors. The map area shows the fallback "Karte wird geladen…" placeholder.
Re-enable JS and reload: the map appears.

- [ ] **Step 6: (Verification 5 + 6) Create machine without / with location**

Navigate to `/machines`. Click "Automat hinzufügen".
- Without location: fill name, submit. Expected: new row appears in the list with no pin.
- With location: open the collapsible "Standort jetzt festlegen" section, search "Brandenburger Tor Berlin", pick a result, drag the pin slightly, click "Speichern" in the outer form. Expected: new row appears, and opening the machine detail shows the coords and address.

- [ ] **Step 7: (Verification 7) Edit legacy machine**

Navigate to a machine that already has `location_lat`/`location_lon` but no address fields (any machine from before this migration).
Click ⚙ → "Automat-Einstellungen". Expected: modal opens, map centers on the existing pin with zoom 17, structured fields are empty.
Drag the pin. Expected: reverse geocoding fills in the address fields. Save. Expected: modal closes, the coordinates under the name reflect the new location.

- [ ] **Step 8: (Verification 8) Clear location**

On a machine that has a location, open the modal, click "🗑 Standort entfernen", then Save. Expected: pin is removed locally, coords + all address fields are saved as NULL, back on the detail page the coordinates line is hidden.

- [ ] **Step 9: (Verification 9) Country code auto-fill**

Open the modal, search "Paris, France", pick the first result. Expected: the country dropdown below the map switches to `FR — France` automatically. Click the dropdown, manually pick `DE — Deutschland`. Save. Expected: country is persisted as `DE`, overriding the geocoded value.

- [ ] **Step 10: (Verification 10) Mobile / iOS Safari PWA**

If iOS Safari is available, open the site on an iPhone, install as PWA, navigate to a machine detail, open the settings modal. Expected:
- Modal fills most of the screen
- Map is touch-draggable
- Search input pans the modal correctly when the soft keyboard opens
- Results list scrolls

If no iPhone is available, skip and mark as "N/A — to verify on staging".

- [ ] **Step 11: (Verification 11) Offline behavior**

In DevTools → Network → set to Offline. Open the settings modal, try to search. Expected:
- Map tiles render as a gray grid
- Search shows the geocoding error inline
- A machine that already had coords can still be saved (the UPDATE won't go through while offline — that's expected; verify that the save button is non-destructive: it shows an error and keeps the modal open)

- [ ] **Step 12: (Verification 12) Permission check**

Log in as a `viewer` (non-admin) user. Navigate to a machine detail. Expected:
- The ⚙ dropdown either shows no "Automat-Einstellungen" item, or the whole dropdown is hidden.
- The coordinates under the name are NOT clickable.
- Try to call `updateMachineSettings` directly in the DevTools console — it should throw an RLS error.

- [ ] **Step 13: (Verification 13) No autocomplete regression**

Open the settings modal, open DevTools → Network filter to `nominatim`. Type "Musterstraße 1, Berlin" slowly in the search input without pressing Enter or clicking Search. Expected: zero network requests. Only after pressing Enter / clicking Search does exactly one request go out.

- [ ] **Step 14: (Verification 14) AbortController**

In the DevTools Network panel, click Search, then immediately drag the pin before the search response arrives. Expected: the forward-geocoding request shows as "canceled" in the network panel, and the address fields in the preview reflect the reverse-geocoded location, not the search result.

- [ ] **Step 15: (Verification 15) Realtime sync**

Open two browsers (or a browser + incognito window), both logged in as admins. Both navigate to `/machines`. In browser A, open a machine and change the location. Expected: browser B's machine list updates the coordinates without a manual refresh (via the extended realtime UPDATE handler).

- [ ] **Step 16: (Verification 16) Attribution visible**

Inspect the map in both light and dark mode. Expected: "© OpenStreetMap contributors" text is rendered in the bottom-right corner of the map in both themes (Leaflet renders it automatically from the `TileLayer` `attribution` option).

- [ ] **Step 17: Run all unit tests one final time**

```bash
cd management-frontend && npx vitest run 2>&1 | tail -40
```

Expected: all tests pass (the new `useGeocoding.test.ts` and `useMachines.test.ts` tests + any pre-existing tests).

- [ ] **Step 18: Final commit (verification notes, if any)**

If any verification step revealed a bug, fix it (additional Edit + commit). If all pass, no extra commit is needed — mark Chunk 5 complete.

---

## Done

After all chunks pass their review and the verification plan is green, the feature is ready to merge. The next natural follow-up (not in this plan) is a public discovery map that reads the address fields — see the "Out of Scope" section of the spec.
