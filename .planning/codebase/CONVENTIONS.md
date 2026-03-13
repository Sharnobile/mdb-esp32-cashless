# Coding Conventions

**Analysis Date:** 2026-03-13

## Naming Patterns

**Files:**
- Composables: `use[Feature].ts` (e.g., `useProducts.ts`, `useMachines.ts`, `useMdbLog.ts`)
- Components: `[Feature].vue` or `[Feature]/[Component].vue` (e.g., `BarcodeScanner.vue`, `ui/card/Card.vue`)
- Pages: `[feature]/index.vue` or `[feature]/[id].vue` (Nuxt 4 app directory convention) — e.g., `pages/machines/[id].vue`, `pages/products/index.vue`
- Middleware: `[name].ts` (e.g., `auth.ts`)
- Test files: `__tests__/[name].test.ts` or adjacent to source as `[name].test.ts`
- Utilities/helpers: `[domain]/[feature].ts` — e.g., `lib/utils.ts`

**Functions & Composables:**
- Use camelCase: `fetchProducts()`, `uploadProductImage()`, `subscribeToStatusUpdates()`
- Prefix query/fetch functions with `fetch`: `fetchMachines()`, `fetchFirmwareVersions()`, `fetchLogs()`
- Prefix subscription functions with `subscribe`: `subscribeToStatusUpdates()`, `subscribe()`
- Prefix helper predicates with `is`: `isReleaseImported()`, `isOutOfWarehouseStock()`, `isPacked()`
- Prefix aggregation/calculation functions with descriptive verbs: `effectiveDeficit()`, `effectiveStockHealth()`, `expirationStatus()`

**Variables:**
- Reactive state (ref/useState): descriptive nouns: `machines`, `loading`, `organization`, `packedItems`, `selectedWarehouseId`
- Loading/status flags: `loading`, `hasMore`, `githubLoading`, `creatingMachine`
- Error state: `error`, `machineError`, `deductError` (object for multiple errors per resource)
- Map/Set collections: suffixed with descriptor: `todayMap`, `trayProductMap`, `packedItems`

**Types/Interfaces:**
- PascalCase: `Organization`, `Product`, `VendingMachine`, `MdbLogEntry`, `GitHubRelease`
- Suffixed with purpose when needed: `...Summary`, `...Entry`, `...Response` (e.g., `WarehouseProductSummary`, `ActivityEntry`, `DashboardMachine`)
- Shared types in composables: exported inline above composable function

## Code Style

**Formatting:**
- No explicit formatter configured (no .eslintrc, .prettierrc found); inferred from codebase:
  - 2-space indentation (TypeScript/Vue)
  - Single quotes for strings in TypeScript (both observed and shadcn-nuxt convention)
  - Double quotes for JSX/Vue attributes
  - No semicolons in Vue template/script blocks (optional); included in standalone `.ts` files
  - Line breaks before `>` in Vue templates for readability

**Linting:**
- No ESLint rules explicitly configured in repo
- Type safety: TypeScript strict mode implied (all files typed, no implicit `any`)
- Unused imports: not explicitly pruned in current code, but imports are generally clean

**Vue/TypeScript conventions in components:**
- `<script setup lang="ts">` — all pages/components use this syntax
- Type imports: `import type { ... }` for types, regular `import` for runtime values
- definePageMeta for route middleware and page metadata
- Inline JSDoc/comments for complex logic sections

## Import Organization

**Order:**
1. Vue core (`import { ref, computed, ... } from 'vue'`)
2. Nuxt utilities (`import { definePageMeta, useRouter, ... } from '#app'` or via auto-imports)
3. Component/UI imports (`import { Card, ... } from '@/components/ui/card'`)
4. Composable imports (`import { useProducts, ... } from '@/composables/useProducts'`)
5. Type imports (`import type { Product, ... }`)
6. Local/third-party utilities (`import { cn, formatCurrency } from '@/lib/utils'`)

**Path Aliases:**
- `@/` — absolute alias for `./app/` (Nuxt default)
- Components auto-imported via shadcn-nuxt and Nuxt auto-import

**Example from `/machines/index.vue`:**
```typescript
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Separator } from '@/components/ui/separator'
import { getProductImageUrl } from '@/composables/useProducts'
import { formatCurrency } from '@/lib/utils'

const { t } = useI18n()
const { organization } = useOrganization()
const { machines, loading, fetchMachines, ... } = useMachines()
```

## Error Handling

**Patterns:**
- Try-catch blocks in async functions with finally cleanup: `loading.value = false` in finally
- Throw Error objects with descriptive messages: `throw new Error('No organization')`
- Check for Supabase errors inline: `if (error) throw error`
- Null coalescing for optional fields: `(data?.field ?? fallback)`
- No global error boundary; page-level error handling with user-visible messages
- Error state in component state: `machineError`, `deductError` (map for multiple errors)

**Example from `useFirmware.ts`:**
```typescript
async function uploadFirmware(file: File, versionLabel: string, notes?: string) {
  if (!organization.value) throw new Error('No organization')

  const { error: uploadError } = await supabase.storage.from('firmware').upload(filePath, file, ...)
  if (uploadError) throw uploadError

  const { error: insertError } = await supabase.from('firmware_versions').insert(...)
  if (insertError) {
    // Rollback: cleanup uploaded file
    await supabase.storage.from('firmware').remove([filePath])
    throw insertError
  }

  await fetchFirmwareVersions()
}
```

**Example from `machines/index.vue`:**
```typescript
try {
  await createMachine(machineName.value.trim(), organization.value!.id)
  showMachineModal.value = false
} catch (err: unknown) {
  machineError.value = err instanceof Error ? err.message : t('machines.failedToCreate')
} finally {
  creatingMachine.value = false
}
```

## Logging

**Framework:** Browser `console` only; no structured logging library

**Patterns:**
- Realtime channel errors: `console.error('[realtime] channel-name error:', err)`
- External API failures: `console.error('Failed to fetch resource:', e)`
- Debug info not in production code (only error-level logging)

## Comments

**When to Comment:**
- Complex business logic (e.g., multi-phase stock calculation in `useMachines.ts`)
- Non-obvious algorithms (e.g., cursor-based pagination logic)
- Gotchas or SSR caveat (middleware note about Supabase URL rewriting)
- Section headers for large functions: `// ── [Section Name] ────────────────`

**JSDoc/TSDoc:**
- Exported helper functions have JSDoc: `/** Check if a GitHub release tag has already been imported */`
- Interface documentation: minimal; type name + field names are self-documenting

**Example from `machines/index.vue`:**
```typescript
// ── Warehouse stock awareness ────────────────────────────────────────────────
// Returns available warehouse stock for a product, or null if no warehouse selected
function getWarehouseAvailable(item: { product_id: string | null }): number | null {
  if (!selectedWarehouseId.value || !item.product_id) return null
  return warehouseStock.value.get(item.product_id) ?? 0
}
```

## Function Design

**Size:**
- Composables: 30–150 lines typical (e.g., `useOrganization` ~28 lines, `useMachines` ~496 lines for complex aggregation)
- Helper functions: <30 lines
- Pages: 100–400 lines (logic + template combined)

**Parameters:**
- Destructured object params for functions with 3+ params: `deductForRefill({ warehouse_id, product_id, quantity, machine_id })`
- Positional params acceptable for <3 args: `createMachine(name, companyId)`

**Return Values:**
- Composables return object with named exports: `return { products, loading, fetchProducts, ... }`
- Helper functions return typed values: `expirationStatus()` returns `'ok' | 'warning' | 'critical'`
- Functions that may fail throw exceptions (no Result<T, E> pattern)

## Module Design

**Exports:**
- Composables export a single default function: `export function useMachines() { ... }`
- Shared helpers/types exported individually: `export function expirationStatus(...) { ... }`, `export interface Warehouse { ... }`
- No barrel files (`index.ts` re-exports); imports reference source directly: `import { useProducts } from '@/composables/useProducts'`

**Barrel Files:**
- Used only for shadcn-nuxt UI components: `components/ui/card/index.ts` re-exports Card, CardHeader, CardTitle, CardContent
- Not used for composables, pages, or utilities

## State Management

**Pattern:** Nuxt `useState` + Supabase realtime subscriptions

- Page-level state initialized on mount: `const { machines, loading, fetchMachines, subscribeToStatusUpdates } = useMachines()`
- Realtime channels subscribed in `onMounted()`, cleanup in `onUnmounted()`
- Local-only UI state (e.g., modals, form inputs): `ref()` scoped to component
- Shared state across pages: `useState('key')` in composables (cached in global store)

**Example from `/machines/index.vue`:**
```typescript
onMounted(async () => {
  await Promise.all([fetchMachines(), fetchWarehouses()])
  if (warehouses.value.length > 0) selectedWarehouseId.value = warehouses.value[0].id
  await loadWarehouseStock()
  const unsubscribe = subscribeToStatusUpdates()
  onUnmounted(unsubscribe)  // cleanup on unmount
})
```

## Data Type Casting

**Pattern:** Manual casting via `as` when Supabase returns `unknown`

Reason: No generated database types (`database.types.ts`), so Supabase client returns `never` by default.

**Example from `useMachines.ts`:**
```typescript
const todayRows = (todaySalesRes.data ?? []) as { machine_id: string; item_price: number }[]
for (const row of todayRows) { ... }
```

---

*Convention analysis: 2026-03-13*
