# Frontend Code Deduplication Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract shared components, composables, and utilities from 8+ management frontend pages to eliminate ~800 lines of duplicated code.

**Architecture:** Install shadcn Dialog + Command components, then build 3 shared components (ProductCombobox, AppModal, FormError), 1 composable (useModalForm), and 2 utility functions (formatDate, formatDateTime). Migrate pages one-by-one preserving identical behavior. Use `@vueuse/core` useClipboard instead of custom implementation.

**Tech Stack:** Nuxt 4, shadcn-nuxt (reka-ui), TailwindCSS 4, TypeScript, @vueuse/core

**Spec:** `docs/superpowers/specs/2026-03-14-frontend-deduplication-design.md`

---

## File Structure

### New Files
| File | Responsibility |
|------|---------------|
| `app/components/ui/dialog/Dialog.vue` | shadcn Dialog (installed via CLI) |
| `app/components/ui/dialog/DialogContent.vue` | shadcn Dialog content |
| `app/components/ui/dialog/DialogHeader.vue` | shadcn Dialog header |
| `app/components/ui/dialog/DialogTitle.vue` | shadcn Dialog title |
| `app/components/ui/dialog/DialogDescription.vue` | shadcn Dialog description |
| `app/components/ui/dialog/DialogFooter.vue` | shadcn Dialog footer |
| `app/components/ui/dialog/DialogClose.vue` | shadcn Dialog close |
| `app/components/ui/dialog/DialogOverlay.vue` | shadcn Dialog overlay |
| `app/components/ui/dialog/DialogPortal.vue` | shadcn Dialog portal |
| `app/components/ui/dialog/DialogTrigger.vue` | shadcn Dialog trigger |
| `app/components/ui/dialog/DialogScrollContent.vue` | shadcn Dialog scroll content |
| `app/components/ui/dialog/index.ts` | shadcn Dialog exports |
| `app/components/ui/command/Command.vue` | shadcn Command (installed via CLI) |
| `app/components/ui/command/*` | shadcn Command sub-components |
| `app/components/ui/popover/Popover.vue` | shadcn Popover (dependency of Command combobox pattern) |
| `app/components/ui/popover/*` | shadcn Popover sub-components |
| `app/components/ProductCombobox.vue` | Reusable product selection combobox |
| `app/components/AppModal.vue` | Reusable modal wrapper around shadcn Dialog |
| `app/components/FormError.vue` | Inline error message display |
| `app/composables/useModalForm.ts` | Modal form state management composable |

### Modified Files
| File | Changes |
|------|---------|
| `app/lib/utils.ts` | Add `formatDate()` and `formatDateTime()` |
| `app/pages/warehouse/index.vue` | Replace 2x autocomplete, modals, formatDate, error handling |
| `app/pages/machines/[id].vue` | Replace tray-select, modals, formatDate, error handling |
| `app/pages/products/index.vue` | Replace modals, error handling |
| `app/pages/machines/index.vue` | Replace modal |
| `app/pages/devices/index.vue` | Replace modals, formatDate |
| `app/pages/api-keys/index.vue` | Replace modal, clipboard, formatDate |
| `app/pages/firmware/index.vue` | Replace modal, formatDate |
| `app/pages/members/index.vue` | Replace modal, clipboard, formatDate |
| `app/pages/settings/index.vue` | Replace formatDate if applicable |
| `app/pages/history/index.vue` | Replace formatDate |
| `app/components/DashboardRecentSales.vue` | Replace formatDateTime |

---

## Chunk 1: Foundation

### Task 1: Install shadcn Dialog, Command, and Popover

- [ ] **Step 1: Install shadcn components via CLI**

**Important:** Run from the `management-frontend/` directory (not the repo root):
```bash
cd management-frontend
npx shadcn-vue@latest add dialog command popover
```

This installs `dialog/`, `command/`, and `popover/` directories under `app/components/ui/` with all sub-components.

- [ ] **Step 2: Verify installation**

```bash
ls app/components/ui/dialog/
ls app/components/ui/command/
ls app/components/ui/popover/
```

Expected: Each directory has `index.ts` plus Vue sub-component files.

- [ ] **Step 3: Verify the dev server starts without errors**

```bash
npm run dev
```

Expected: No import/type errors. The new components are auto-discovered by Nuxt.

- [ ] **Step 4: Commit**

```bash
git add app/components/ui/dialog/ app/components/ui/command/ app/components/ui/popover/
git commit -m "feat: install shadcn dialog, command, and popover components"
```

---

### Task 2: Add `formatDate()` and `formatDateTime()` to `lib/utils.ts`

**Files:**
- Modify: `app/lib/utils.ts`

- [ ] **Step 1: Add the utility functions**

Add to the end of `app/lib/utils.ts`:

```ts
export function formatDate(dt: string | null | undefined, locale?: string): string {
  if (!dt) return '\u2014'
  return new Date(dt).toLocaleDateString(locale, {
    day: '2-digit',
    month: '2-digit',
    year: 'numeric',
  })
}

export function formatDateTime(dt: string | null | undefined, locale?: string): string {
  if (!dt) return '\u2014'
  return new Date(dt).toLocaleString(locale, {
    day: '2-digit',
    month: '2-digit',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  })
}
```

- [ ] **Step 2: Verify no type errors**

```bash
cd management-frontend && npx vue-tsc --noEmit 2>&1 | head -20
```

Expected: No new errors related to utils.ts.

- [ ] **Step 3: Commit**

```bash
git add app/lib/utils.ts
git commit -m "feat: add formatDate and formatDateTime utilities"
```

---

### Task 3: Create `FormError.vue`

**Files:**
- Create: `app/components/FormError.vue`

- [ ] **Step 1: Create the component**

Create `app/components/FormError.vue`:

```vue
<script setup lang="ts">
defineProps<{
  message?: string
}>()
</script>

<template>
  <p v-if="message" class="text-sm text-destructive">
    {{ message }}
  </p>
</template>
```

- [ ] **Step 2: Commit**

```bash
git add app/components/FormError.vue
git commit -m "feat: add FormError component"
```

---

### Task 4: Create `useModalForm` composable

**Files:**
- Create: `app/composables/useModalForm.ts`

- [ ] **Step 1: Create the composable**

Create `app/composables/useModalForm.ts`:

```ts
import { ref, type Ref } from 'vue'

export function useModalForm<T extends Record<string, unknown>>(defaults: T) {
  const open = ref(false)
  const form = ref<T>({ ...defaults }) as Ref<T>
  const loading = ref(false)
  const error = ref('')

  function openModal(initial?: Partial<T>) {
    form.value = { ...defaults, ...initial } as T
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

- [ ] **Step 2: Commit**

```bash
git add app/composables/useModalForm.ts
git commit -m "feat: add useModalForm composable"
```

---

### Task 5: Create `AppModal.vue`

**Files:**
- Create: `app/components/AppModal.vue`

- [ ] **Step 1: Create the component**

Create `app/components/AppModal.vue`:

```vue
<script setup lang="ts">
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { cn } from '@/lib/utils'

const props = withDefaults(
  defineProps<{
    open: boolean
    title: string
    description?: string
    size?: 'sm' | 'md' | 'lg'
  }>(),
  {
    size: 'md',
  },
)

const emit = defineEmits<{
  'update:open': [value: boolean]
}>()

const sizeClasses: Record<string, string> = {
  sm: 'max-w-sm',
  md: 'max-w-md',
  lg: 'max-w-lg',
}
</script>

<template>
  <Dialog :open="open" @update:open="emit('update:open', $event)">
    <DialogContent :class="cn(sizeClasses[size])">
      <DialogHeader>
        <DialogTitle>{{ title }}</DialogTitle>
        <DialogDescription v-if="description">{{ description }}</DialogDescription>
      </DialogHeader>

      <slot />

      <div v-if="$slots.footer" class="flex gap-2 pt-2">
        <slot name="footer" />
      </div>
    </DialogContent>
  </Dialog>
</template>
```

**Note on `devices/index.vue` bottom-sheet modals:** The `position="bottom"` prop from the spec is dropped from `AppModal` because shadcn Dialog positions content via the overlay, not the content element — applying `items-end` to `DialogContent` has no effect. The project already has shadcn `Sheet` (`app/components/ui/sheet/`) which is designed for bottom-sheet behavior. The `devices/index.vue` bottom-sheet modals should either continue using their current hand-rolled implementation or be migrated to use `Sheet` directly (not via `AppModal`). This keeps `AppModal` simple and correct for all other pages.

- [ ] **Step 2: Verify the dev server renders the component correctly**

Quick smoke test: temporarily add `<AppModal :open="true" title="Test" />` to a page, check it renders, then remove.

- [ ] **Step 3: Commit**

```bash
git add app/components/AppModal.vue
git commit -m "feat: add AppModal component wrapping shadcn Dialog"
```

---

### Task 6: Create `ProductCombobox.vue`

**Files:**
- Create: `app/components/ProductCombobox.vue`

This component needs to check what sub-components exist after `npx shadcn-vue@latest add command popover`. The implementation wraps Command inside a Popover (standard shadcn combobox pattern).

- [ ] **Step 1: Check installed Command and Popover exports**

```bash
cat app/components/ui/command/index.ts
cat app/components/ui/popover/index.ts
```

Note the exact exported component names — they may differ slightly from the spec.

- [ ] **Step 2: Create the component**

Create `app/components/ProductCombobox.vue`:

```vue
<script setup lang="ts">
import { ref, computed } from 'vue'
import { Check, ChevronsUpDown, Plus } from 'lucide-vue-next'
import {
  Command,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
} from '@/components/ui/command'
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from '@/components/ui/popover'
import { cn } from '@/lib/utils'

const { t } = useI18n()

interface Product {
  id: string
  name: string
  image_path?: string | null
}

const props = withDefaults(
  defineProps<{
    modelValue: string | null
    products: Product[]
    placeholder?: string
    allowCreate?: boolean
    disabled?: boolean
  }>(),
  {
    placeholder: '',
    allowCreate: false,
    disabled: false,
  },
)

const emit = defineEmits<{
  'update:modelValue': [id: string | null]
  'create': [query: string]
  'select': [id: string | null]
}>()

const open = ref(false)
const searchQuery = ref('')

const selectedProduct = computed(() =>
  props.products.find((p) => p.id === props.modelValue),
)

function selectProduct(id: string | null) {
  emit('update:modelValue', id)
  emit('select', id)
  open.value = false
}
</script>

<template>
  <Popover v-model:open="open">
    <PopoverTrigger as-child>
      <button
        role="combobox"
        :aria-expanded="open"
        :disabled="disabled"
        :class="cn(
          'flex h-9 w-full items-center justify-between rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm hover:bg-accent hover:text-accent-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring disabled:cursor-not-allowed disabled:opacity-50',
        )"
      >
        <span :class="{ 'text-muted-foreground': !selectedProduct }">
          {{ selectedProduct?.name || placeholder }}
        </span>
        <ChevronsUpDown class="ml-2 size-4 shrink-0 opacity-50" />
      </button>
    </PopoverTrigger>
    <PopoverContent class="w-[--reka-popover-trigger-width] p-0" align="start">
      <Command v-model:search-term="searchQuery">
        <CommandInput :placeholder="placeholder" />
        <CommandList>
          <CommandEmpty>
            <span class="text-muted-foreground text-sm">{{ t('common.noResults') }}</span>
          </CommandEmpty>
          <CommandGroup>
            <CommandItem
              value="__none__"
              @select="selectProduct(null)"
            >
              <Check :class="cn('mr-2 size-4', modelValue ? 'opacity-0' : 'opacity-100')" />
              <span class="text-muted-foreground">{{ t('machineDetail.none') }}</span>
            </CommandItem>
            <CommandItem
              v-for="product in products"
              :key="product.id"
              :value="product.name"
              @select="selectProduct(product.id)"
            >
              <Check :class="cn('mr-2 size-4', modelValue === product.id ? 'opacity-100' : 'opacity-0')" />
              {{ product.name }}
            </CommandItem>
          </CommandGroup>
          <CommandGroup v-if="allowCreate">
            <CommandItem value="__create__" @select="emit('create', searchQuery)">
              <Plus class="mr-2 size-4" />
              {{ t('warehouse.createNewProduct') }}
            </CommandItem>
          </CommandGroup>
        </CommandList>
      </Command>
    </PopoverContent>
  </Popover>
</template>
```

**Translation keys required:** Verify `common.noResults`, `machineDetail.none`, and `warehouse.createNewProduct` exist in both `en.json` and `de.json`. Add them if missing.

- [ ] **Step 3: Smoke test**

Add a temporary usage on any page to verify the popover opens, search filters, and selection works. Remove after testing.

- [ ] **Step 4: Commit**

```bash
git add app/components/ProductCombobox.vue
git commit -m "feat: add ProductCombobox component with shadcn Command"
```

---

## Chunk 2: High-Impact Page Migrations

### Task 7: Migrate `warehouse/index.vue`

**Files:**
- Modify: `app/pages/warehouse/index.vue`

This page has the most duplication: 2 custom autocompletes, multiple modals, inline formatDate, and error handling.

- [ ] **Step 1: Add imports at top of `<script setup>`**

Add these imports (keep existing ones):
```ts
import { formatDate, formatDateTime } from '@/lib/utils'
import { useClipboard } from '@vueuse/core'
```

- [ ] **Step 2: Replace incoming product autocomplete with ProductCombobox**

Find the template section for the incoming product autocomplete (the `<input>` with `v-model="incomingProductQuery"` and the dropdown `<ul>` below it). Replace the entire autocomplete block with:

```vue
<ProductCombobox
  v-model="incomingProductId"
  :products="products"
  :placeholder="t('warehouse.selectProduct')"
  :allow-create="true"
  @create="(query: string) => openQuickCreateProduct(query, 'incoming')"
  @select="onIncomingProductSelected"
/>
```

Note: `@create` now receives the search query string, which is passed to `openQuickCreateProduct(name, target)` to pre-fill the quick-create modal's name field (preserving existing behavior).

Remove the now-unused state variables and functions:
- `incomingProductQuery`, `incomingProductOpen`, `incomingHighlightedIndex`
- `incomingFilteredProducts` computed
- `handleIncomingProductKeydown()`, `openIncomingProductDropdown()`, `handleIncomingProductBlur()`
- `selectIncomingProduct()` (replace with `onIncomingProductSelected`)

Create a simple handler:
```ts
function onIncomingProductSelected(id: string | null) {
  incomingProductId.value = id ?? ''
}
```

- [ ] **Step 3: Replace barcode assignment autocomplete with ProductCombobox**

Find the template section for the barcode assignment autocomplete. Replace with:

```vue
<ProductCombobox
  v-model="assignBarcodeProductId"
  :products="productsWithoutBarcode"
  :placeholder="t('warehouse.selectProduct')"
  :allow-create="true"
  @create="(query: string) => openQuickCreateProduct(query, 'assign')"
/>
```

Remove the now-unused state variables and functions:
- `assignProductQuery`, `assignProductOpen`, `assignHighlightedIndex`
- `assignFilteredProducts` computed
- `handleAssignProductKeydown()`, `openAssignProductDropdown()`, `handleAssignProductBlur()`
- `selectAssignProduct()`

- [ ] **Step 4: Replace modals with AppModal**

For each modal in the page (find `<div v-if="show...Modal"` or similar), replace the outer `<div class="fixed inset-0...">` + inner `<div class="...rounded-xl border bg-card...">` wrapper with:

```vue
<AppModal v-model:open="showXxxModal" :title="t('warehouse.xxxTitle')">
  <!-- keep inner form content exactly as-is -->
  <template #footer>
    <!-- keep existing buttons but remove outer flex wrapper if AppModal provides one -->
  </template>
</AppModal>
```

- [ ] **Step 5: Replace modal state management with useModalForm where applicable**

For simple modals (e.g., the quick-create product modal), replace the hand-rolled state:

Before:
```ts
const showQuickCreateModal = ref(false)
const quickCreateForm = ref({ name: '', sellprice: null })
const quickCreateLoading = ref(false)
const quickCreateError = ref('')
```

After:
```ts
const quickCreate = useModalForm({ name: '', sellprice: null as number | null })
```

Then replace `showQuickCreateModal` with `quickCreate.open`, etc.

- [ ] **Step 6: Replace inline formatDate calls**

Find all `formatDate(...)` calls and ensure they use the imported `formatDate` from `@/lib/utils`. If the page had `formatDate` defined locally with `'de-DE'` locale, update calls to `formatDate(dt, 'de-DE')`.

Remove the local `formatDate` function definition.

- [ ] **Step 7: Replace inline error `<p>` tags with FormError**

Find all `<p v-if="...Error" class="text-sm text-destructive">` and replace with:

```vue
<FormError :message="xxxError" />
```

- [ ] **Step 8: Verify the page works**

```bash
npm run dev
```

Navigate to `/warehouse` and test:
- Incoming product selection (search, select, clear)
- Barcode assignment product selection
- "Create new product" flow from both comboboxes
- All modals open/close correctly
- Error states display correctly
- Date formatting is unchanged

- [ ] **Step 9: Commit**

```bash
git add app/pages/warehouse/index.vue
git commit -m "refactor: warehouse page - use shared components and composables"
```

---

### Task 8: Migrate `machines/[id].vue`

**Files:**
- Modify: `app/pages/machines/[id].vue`

This page has the add-tray modal's native `<select>`, other modals, and formatDate. The **inline tray-table autocomplete stays** (per spec — unique Tab/focus behavior).

- [ ] **Step 1: Add imports**

```ts
import { formatDate, formatDateTime } from '@/lib/utils'
```

- [ ] **Step 2: Replace native `<select>` in add-tray modal with ProductCombobox**

Find the `<select id="tray-product" v-model="trayForm.product_id">` inside the add-tray modal. Replace with:

```vue
<ProductCombobox
  v-model="trayForm.product_id"
  :products="products"
  :placeholder="t('machineDetail.selectProduct')"
/>
```

- [ ] **Step 3: Replace modals with AppModal**

For each modal (add tray, batch add, edit tray, etc.), replace the hand-rolled overlay + card with `<AppModal>`. Keep inner form content.

- [ ] **Step 4: Replace modal state management with useModalForm where applicable**

For simple modals (add tray, batch add), replace hand-rolled `showXxxModal/xxxForm/xxxLoading/xxxError` groups with `useModalForm()`.

- [ ] **Step 5: Replace inline formatDate/formatDateTime**

Find all inline `new Date(...).toLocaleString(...)` or local `formatDate()` calls and replace with the imported utilities. Remove local function definitions.

- [ ] **Step 6: Replace inline error tags with FormError**

- [ ] **Step 7: Verify the page works**

Navigate to `/machines/[id]` and test:
- Add tray modal with product selection
- Batch add modal
- Inline tray editing (autocomplete should be UNCHANGED)
- Sales history date formatting
- All modals open/close/submit correctly

- [ ] **Step 8: Commit**

```bash
git add app/pages/machines/\\[id\\].vue
git commit -m "refactor: machine detail page - use shared components and composables"
```

---

### Task 9: Migrate `products/index.vue`

**Files:**
- Modify: `app/pages/products/index.vue`

- [ ] **Step 1: Add imports**

```ts
import { formatDate } from '@/lib/utils'
```

- [ ] **Step 2: Replace modals with AppModal**

Replace the product add/edit modal and category modals with `<AppModal>`.

- [ ] **Step 3: Replace modal state with useModalForm**

- [ ] **Step 4: Replace inline error tags with FormError**

- [ ] **Step 5: Verify and commit**

Test: Product CRUD, category CRUD, image upload, import flow.

```bash
git add app/pages/products/index.vue
git commit -m "refactor: products page - use shared components and composables"
```

---

## Chunk 3: Remaining Page Migrations

### Task 10: Migrate `machines/index.vue`

**Files:**
- Modify: `app/pages/machines/index.vue`

- [ ] **Step 1: Replace modal with AppModal + useModalForm**

Replace the "add machine" modal overlay with `<AppModal>` and hand-rolled state with `useModalForm()`.

- [ ] **Step 2: Replace inline error tags with FormError**

- [ ] **Step 3: Verify and commit**

Test: Add machine modal opens, submits, closes, shows errors.

```bash
git add app/pages/machines/index.vue
git commit -m "refactor: machines list page - use AppModal and useModalForm"
```

---

### Task 11: Migrate `devices/index.vue`

**Files:**
- Modify: `app/pages/devices/index.vue`

- [ ] **Step 1: Replace modals with AppModal**

Use `<AppModal>` for standard center-positioned modals. For bottom-sheet modals (the ones using `items-end sm:items-center` + `safe-area-inset-bottom`), keep the current hand-rolled implementation or migrate to shadcn `Sheet` directly — do NOT use `AppModal` for those.

- [ ] **Step 2: Replace modal state with useModalForm**

- [ ] **Step 3: Replace inline formatDate with imported utility**

Remove local `formatDate()` function, use imported one from `@/lib/utils`.

- [ ] **Step 4: Replace inline error tags with FormError**

- [ ] **Step 5: Verify and commit**

Test: Device provisioning, QR display, token management, all modals.

```bash
git add app/pages/devices/index.vue
git commit -m "refactor: devices page - use shared components and composables"
```

---

### Task 12: Migrate `api-keys/index.vue`

**Files:**
- Modify: `app/pages/api-keys/index.vue`

- [ ] **Step 1: Replace clipboard with @vueuse/core**

Remove the custom `copyKey()` function. Replace with:

```ts
import { useClipboard } from '@vueuse/core'

const { copy, copied } = useClipboard({ copiedDuring: 2000 })
```

If the VueUse clipboard doesn't work on insecure contexts (HTTP without TLS), add fallback logic. Test on local dev.

Update template: replace `@click="copyKey()"` with `@click="copy(createdKey)"` and `copied` ref usage stays the same.

- [ ] **Step 2: Replace modal with AppModal + useModalForm**

Note: This is a **two-step modal** (success shows "copy key" step). Use `useModalForm` with `submit(fn, { closeOnSuccess: false })`.

- [ ] **Step 3: Replace inline formatDate**

Remove local `formatDate()`, use imported one.

- [ ] **Step 4: Replace inline error tags with FormError**

- [ ] **Step 5: Verify and commit**

Test: Create API key, copy key, two-step modal flow, date formatting.

```bash
git add app/pages/api-keys/index.vue
git commit -m "refactor: api-keys page - use shared components, clipboard, and composables"
```

---

### Task 13: Migrate `firmware/index.vue`

**Files:**
- Modify: `app/pages/firmware/index.vue`

- [ ] **Step 1: Replace modals with AppModal + useModalForm**

- [ ] **Step 2: Replace inline formatDate**

**Important:** This page uses `formatDate` for tooltip titles that include time (calls `toLocaleString()` not `toLocaleDateString()`). Replace these with `formatDateTime()` to preserve the time component in tooltips.

- [ ] **Step 3: Replace inline error tags with FormError**

- [ ] **Step 4: Verify and commit**

Test: Firmware upload, OTA deploy, tooltip date formats include time.

```bash
git add app/pages/firmware/index.vue
git commit -m "refactor: firmware page - use shared components and composables"
```

---

### Task 14: Migrate `members/index.vue`

**Files:**
- Modify: `app/pages/members/index.vue`

- [ ] **Step 1: Replace clipboard with @vueuse/core**

Same as api-keys migration:
```ts
import { useClipboard } from '@vueuse/core'
const { copy, copied } = useClipboard({ copiedDuring: 2000 })
```

- [ ] **Step 2: Replace modal with AppModal + useModalForm**

Note: This is also a **two-step modal** (success shows invite link). Use `submit(fn, { closeOnSuccess: false })`.

- [ ] **Step 3: Replace inline formatDate**

- [ ] **Step 4: Replace inline error tags with FormError**

- [ ] **Step 5: Verify and commit**

Test: Invite member, copy invite link, two-step modal, date formatting.

```bash
git add app/pages/members/index.vue
git commit -m "refactor: members page - use shared components, clipboard, and composables"
```

---

### Task 15: Migrate remaining pages

**Files:**
- Modify: `app/pages/settings/index.vue` (formatDate if present)
- Modify: `app/pages/history/index.vue` (formatDate)
- Modify: `app/components/DashboardRecentSales.vue` (formatDateTime)

- [ ] **Step 1: Migrate `settings/index.vue`**

If it has a local `formatDate`, replace with imported utility.

- [ ] **Step 2: Migrate `history/index.vue`**

Replace local `formatDate`/`formatDateTime` with imported utilities.

- [ ] **Step 3: Migrate `DashboardRecentSales.vue`**

Replace the inline `formatDateTime` (line 12) with imported `formatDateTime` from `@/lib/utils`. **Important:** The existing code uses `locale.value` (VueI18n reactive locale) and omits the `year` option. Pass the locale explicitly: `formatDateTime(dt, locale.value)`. Verify the output format is acceptable (the shared utility includes the year, which the local version does not). If the year is unwanted, keep the local implementation instead.

- [ ] **Step 4: Verify and commit**

```bash
git add app/pages/settings/index.vue app/pages/history/index.vue app/components/DashboardRecentSales.vue
git commit -m "refactor: settings, history, and DashboardRecentSales - use shared formatDate utilities"
```

---

## Chunk 4: Cleanup & Verification

### Task 16: Final cleanup and verification

- [ ] **Step 1: Search for remaining duplication**

```bash
# Check for any remaining local formatDate functions
grep -rn "function formatDate" app/pages/ app/components/

# Check for any remaining hand-rolled modal overlays
grep -rn "fixed inset-0.*z-\[60\]" app/pages/

# Check for any remaining inline error patterns (should all be FormError now)
grep -rn 'text-sm text-destructive' app/pages/ | grep -v 'FormError'
```

Expected: No results (all replaced).

- [ ] **Step 2: Remove any dead imports or unused variables**

Check for TypeScript warnings about unused variables after the migrations.

```bash
cd management-frontend && npx vue-tsc --noEmit 2>&1 | head -50
```

- [ ] **Step 3: Full dev server smoke test**

```bash
npm run dev
```

Navigate through ALL pages and verify:
- `/` (dashboard) — recent sales dates
- `/machines` — add machine modal
- `/machines/[id]` — tray management, sales history
- `/products` — product/category CRUD
- `/warehouse` — all product selections, incoming, barcodes
- `/devices` — provisioning, bottom-sheet modals
- `/api-keys` — create key, copy key flow
- `/firmware` — upload, OTA, tooltip dates
- `/members` — invite, copy link flow
- `/settings` — dates
- `/history` — dates

- [ ] **Step 4: Run existing tests**

```bash
cd management-frontend && npx vitest run
```

Expected: All existing tests pass.

- [ ] **Step 5: Final commit if any cleanup was needed**

```bash
git add -A
git commit -m "refactor: final cleanup after frontend deduplication"
```
