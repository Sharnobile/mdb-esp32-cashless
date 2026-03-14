# Frontend Code Deduplication Design

**Date:** 2026-03-14
**Status:** Draft
**Scope:** management-frontend — extract shared components, composables, and utilities to eliminate duplicated code across 8+ pages

## Problem

The management frontend has accumulated significant code duplication:
- 3 identical custom autocomplete implementations for product selection (~400 lines duplicated)
- 8+ handmade modal overlay containers with identical structure
- 11+ inline `formatDate()` functions (each page defines its own)
- 6+ identical try-catch/loading/error modal submission patterns
- 13+ identical inline error display patterns
- 2 identical copy-to-clipboard implementations with fallback
- 15+ identical loading/empty-state template patterns

## Approach

Use shadcn-nuxt components (Dialog, Command) where available. Extract shared components, composables, and utility functions. Migrate page-by-page with identical behavior preserved.

## New shadcn Components to Install

- **Dialog** — replaces 8+ handmade modal overlays
- **Command** — provides Combobox/autocomplete with keyboard navigation and accessibility

## New Shared Components

### 1. `ProductCombobox.vue`

Reusable product selection component built on shadcn Command + Popover.

```
Location: app/components/ProductCombobox.vue

Props:
  modelValue: string | null        — selected product_id (v-model)
  products: Product[]              — product list (caller controls filtering)
  placeholder?: string             — trigger text when nothing selected
  allowCreate?: boolean            — shows "Create new product" action
  disabled?: boolean

Emits:
  update:modelValue(id: string | null)
  create()
  select(id: string | null)        — fired on selection (for immediate side effects)

Behavior:
  - Popover trigger displays selected product name or placeholder
  - Command input for text search (filters by product name)
  - Shows product image thumbnail if available
  - Keyboard navigation via shadcn Command (free)
  - "None" option to clear selection
  - Optional "Create new" action at bottom of list
  - @select emit enables callers to trigger side effects (e.g. save, focus next input)
```

**Replaces:**
- machines/[id].vue: native `<select>` in add-tray modal (lines 1876-1906)
- warehouse/index.vue: incoming product autocomplete (lines 144-212, ~1105-1145)
- warehouse/index.vue: barcode assignment autocomplete (lines 322-390, ~1046-1085)
- warehouse/index.vue: native `<select>` in barcode form (~line 1574)

**Does NOT replace** (kept as custom inline code):
- machines/[id].vue: inline tray-table autocomplete (lines 463-570, 1118-1159). This per-row edit-in-place control has unique Tab-to-next-input focus management and shared single-open state across table rows that doesn't map to a Popover-based component. The custom autocomplete stays but can reuse the `filteredProducts` logic via a small `useProductFilter()` helper if needed.

### 2. `AppModal.vue`

Wrapper around shadcn Dialog with standard layout.

```
Location: app/components/AppModal.vue

Props:
  open: boolean                    — v-model for visibility
  title: string                    — dialog title
  description?: string             — subtitle below title
  size?: 'sm' | 'md' | 'lg'       — max-width (sm=384, md=448, lg=512)
  position?: 'center' | 'bottom'  — center (default) or bottom-sheet on mobile (devices page)

Emits:
  update:open(value: boolean)      — v-model binding; fired on ESC, overlay click, or programmatic close

Slots:
  default                          — body content
  footer                           — action buttons (default: Cancel + primary slot)
```

**Replaces:** 8+ pages with `<div class="fixed inset-0 z-[60] flex items-center justify-center bg-black/40">` pattern in: machines/index, machines/[id], products/index, warehouse/index, devices/index, api-keys/index, firmware/index, members/index

Note: `devices/index.vue` uses bottom-sheet style (`items-end sm:items-center` + `safe-area-inset-bottom` padding) — use `position="bottom"` for those modals.

### 3. `FormError.vue`

Inline error message display.

```
Location: app/components/FormError.vue

Props:
  message?: string

Template:
  <p v-if="message" class="text-sm text-destructive">{{ message }}</p>
```

**Replaces:** 13+ identical inline error `<p>` tags across all pages.

## New Composables

### 4. `useModalForm<T>()`

Encapsulates the repeated modal form state management pattern.

```
Location: app/composables/useModalForm.ts

function useModalForm<T extends Record<string, unknown>>(defaults: T) {
  const open = ref(false)
  const form = ref<T>({ ...defaults })
  const loading = ref(false)
  const error = ref('')

  function openModal(initial?: Partial<T>) {
    form.value = { ...defaults, ...initial }
    error.value = ''
    loading.value = false
    open.value = true
  }

  function closeModal() {
    open.value = false
  }

  async function submit(fn: () => Promise<void>, opts?: { closeOnSuccess?: boolean }) {
    loading.value = true
    error.value = ''
    try {
      await fn()
      if (opts?.closeOnSuccess !== false) closeModal()
    } catch (err: unknown) {
      error.value = err instanceof Error ? err.message : String(err)
    } finally {
      loading.value = false
    }
  }

  return { open, form, loading, error, openModal, closeModal, submit }
}
```

**Replaces:** 6+ pages with identical loading/error/try-catch/close patterns (machines/[id], warehouse, products, devices, api-keys, firmware, members).

Note: `api-keys/index.vue` and `members/index.vue` have two-step modal flows (success shows a "copy key/link" step instead of closing). These use `submit(fn, { closeOnSuccess: false })` and close manually via `closeModal()` when the user clicks "Done".

### 5. `useClipboard()` — Use `@vueuse/core`

The project already depends on `@vueuse/core` (used in `useTheme` via `useDark`). VueUse ships a `useClipboard` composable with the same API we need. Use it directly instead of writing a custom one:

```ts
import { useClipboard } from '@vueuse/core'

const { copy, copied } = useClipboard({ copiedDuring: 2000 })
```

If the VueUse version lacks the `execCommand` fallback for insecure contexts (HTTP without TLS), add a thin wrapper in `app/composables/useClipboardWithFallback.ts` that tries VueUse first and falls back to `execCommand`. Evaluate during implementation.

**Replaces:** api-keys/index.vue (lines 78-92) and members/index.vue (lines 78-93).

## New Utility Functions

### 6. `formatDate()` and `formatDateTime()` in `lib/utils.ts`

```
formatDate(dt: string | null, locale?: string): string
  — Returns localized date: "14.03.2026" or "—" for null
  — Optional locale param (defaults to browser locale)
  — warehouse uses formatDate(dt, 'de-DE') to preserve current hardcoded behavior

formatDateTime(dt: string | null, locale?: string): string
  — Returns localized date+time: "14.03.2026, 15:30" or "—" for null
  — Optional locale param (defaults to browser locale)
```

**Replaces:** 11+ inline `formatDate()` / `new Date().toLocaleString()` calls across: devices, warehouse, members, history, machines/[id], api-keys, firmware, settings.

**Also replaces:** `DashboardRecentSales.vue` inline `formatDateTime` (line 12).

Note: `timeAgo()` already exists in utils.ts and stays for relative timestamps. `firmware/index.vue` uses `formatDate` for tooltip titles that include time — these should use `formatDateTime` instead.

## Migration Strategy

Each page migrated individually, tested, and committed separately. No feature changes — behavior-preserving refactoring only.

### Phase 1: Foundation
1. Install shadcn Dialog + Command (`npx shadcn-vue@latest add dialog command`)
2. Create `ProductCombobox.vue`
3. Create `AppModal.vue`
4. Create `FormError.vue`
5. Create `useModalForm.ts`
6. Create `useClipboard.ts`
7. Add `formatDate()` + `formatDateTime()` to `lib/utils.ts`

### Phase 2: High-Impact Page Migration
8. Migrate `warehouse/index.vue` (2x autocomplete, modals, formatDate, error handling)
9. Migrate `machines/[id].vue` (1x autocomplete, tray-select, modals, formatDate)
10. Migrate `products/index.vue` (modals, category select, error handling)

### Phase 3: Remaining Pages
11. Migrate `machines/index.vue` (modal)
12. Migrate `devices/index.vue` (modals, formatDate)
13. Migrate `api-keys/index.vue` (modal, clipboard, formatDate)
14. Migrate `firmware/index.vue` (modal, formatDate)
15. Migrate `members/index.vue` (modal, clipboard, formatDate)
16. Migrate `settings/index.vue` (formatDate if applicable)
17. Migrate `history/index.vue` (formatDate)
18. Migrate `DashboardRecentSales.vue` component (formatDateTime)

### Phase 4: Cleanup
19. Remove all dead inline code (old autocomplete state vars, old format functions, old modal markup)
20. Verify no regressions across all pages

## Constraints

- **No feature changes** — this is purely structural refactoring
- **Backward compatible** — no API/DB changes involved
- **i18n preserved** — all `t()` translation keys stay the same
- **Each page independently deployable** — partial migration is safe

## Expected Impact

- ~800+ lines of duplicated code removed
- 6 new reusable units (3 components, 2 composables, 2 utility functions)
- Consistent UI behavior (keyboard nav, accessibility) across all product selection points
- Future product selection points require ~5 lines instead of ~150
