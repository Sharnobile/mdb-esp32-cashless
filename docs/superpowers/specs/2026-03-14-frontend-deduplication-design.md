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

Behavior:
  - Popover trigger displays selected product name or placeholder
  - Command input for text search (filters by product name)
  - Shows product image thumbnail if available
  - Keyboard navigation via shadcn Command (free)
  - "None" option to clear selection
  - Optional "Create new" action at bottom of list
```

**Replaces:**
- machines/[id].vue: inline autocomplete (lines 463-570, 1118-1159, 1364-1411)
- machines/[id].vue: native `<select>` in add-tray modal (lines 1876-1906)
- warehouse/index.vue: incoming product autocomplete (lines 144-212, ~1105-1145)
- warehouse/index.vue: barcode assignment autocomplete (lines 322-390, ~1046-1085)
- warehouse/index.vue: native `<select>` in barcode form (~line 1574)

### 2. `AppModal.vue`

Wrapper around shadcn Dialog with standard layout.

```
Location: app/components/AppModal.vue

Props:
  open: boolean                    — v-model for visibility
  title: string                    — dialog title
  description?: string             — subtitle below title
  size?: 'sm' | 'md' | 'lg'       — max-width (sm=384, md=448, lg=512)

Slots:
  default                          — body content
  footer                           — action buttons (default: Cancel + primary slot)
```

**Replaces:** 8+ pages with `<div class="fixed inset-0 z-[60] flex items-center justify-center bg-black/40">` pattern in: machines/index, machines/[id], products/index, warehouse/index, devices/index, api-keys/index, firmware/index, members/index

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

  async function submit(fn: () => Promise<void>) {
    loading.value = true
    error.value = ''
    try {
      await fn()
      closeModal()
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

### 5. `useClipboard()`

Copy-to-clipboard with fallback for insecure contexts.

```
Location: app/composables/useClipboard.ts

function useClipboard() {
  const copied = ref(false)
  let timer: ReturnType<typeof setTimeout> | null = null

  async function copy(text: string) {
    try {
      await navigator.clipboard.writeText(text)
    } catch {
      // Fallback: textarea + execCommand
      const ta = document.createElement('textarea')
      ta.value = text
      document.body.appendChild(ta)
      ta.select()
      document.execCommand('copy')
      document.body.removeChild(ta)
    }
    copied.value = true
    if (timer) clearTimeout(timer)
    timer = setTimeout(() => { copied.value = false }, 2000)
  }

  return { copied, copy }
}
```

**Replaces:** api-keys/index.vue (lines 78-92) and members/index.vue (lines 78-93).

## New Utility Functions

### 6. `formatDate()` and `formatDateTime()` in `lib/utils.ts`

```
formatDate(dt: string | null): string
  — Returns localized date: "14.03.2026" or "—" for null

formatDateTime(dt: string | null): string
  — Returns localized date+time: "14.03.2026, 15:30" or "—" for null
```

**Replaces:** 11+ inline `formatDate()` / `new Date().toLocaleString()` calls across: devices, warehouse, members, history, machines/[id], api-keys, firmware, settings.

Note: `timeAgo()` already exists in utils.ts and stays for relative timestamps.

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

### Phase 4: Cleanup
18. Remove all dead inline code (old autocomplete state vars, old format functions, old modal markup)
19. Verify no regressions across all pages

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
