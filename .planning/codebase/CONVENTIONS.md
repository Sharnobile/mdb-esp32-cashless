# Coding Conventions

**Analysis Date:** 2026-03-13

## Naming Patterns

**Files:**
- Vue components: PascalCase (e.g., `BarcodeScanner.vue`, `AppSidebar.vue`)
- Composables: `use{Name}` prefix (e.g., `useOrganization.ts`, `useMachineTrays.ts`)
- Utilities: camelCase (e.g., `utils.ts`)
- Edge functions: kebab-case directories matching function name (e.g., `send-credit/index.ts`, `mqtt-webhook/index.ts`)
- C source files: snake_case (e.g., `mdb-slave-esp32s3.c`, `nimble.c`, `webui_server.c`)

**Functions:**
- camelCase for all functions (Vue, TypeScript, and JavaScript)
- Composables are uppercase use patterns: `useOrganization()`, `useMachineTrays()`, `useMdbLog()`
- Prefix helper functions that are pure/exported from composables clearly: `stateLabel()`, `stateVariant()`, `expirationStatus()`
- No underscore prefixes — encapsulation done via file structure, not naming

**Variables:**
- camelCase for all local variables and state refs: `machines`, `loading`, `hasMore`, `machineError`
- Prefix reactive state with intent: `pending*` for pending operations (e.g., `pendingStockTimers`, `pendingStockTrays`)
- Cache maps prefixed with intent: `machineNameCache`, `warehouseStock`
- Booleans prefixed with verb or state: `loading`, `hasMore`, `manualInput`, `creatingMachine`

**Types:**
- PascalCase for interfaces and type definitions (e.g., `MdbLogEntry`, `Organization`, `VendingMachine`, `Warehouse`)
- Enum values: SCREAMING_SNAKE_CASE for C enums (e.g., `INACTIVE_STATE`, `VEND_STATE`)
- Enum names: camelCase suffix `_t` in C (e.g., `machine_state_t`)
- Interface properties: snake_case matching database column names (e.g., `created_at`, `embedded_id`, `current_stock`)

## Code Style

**Formatting:**
- No ESLint or Prettier config files — codebase follows implicit conventions
- Indentation: 2 spaces (Vue, TypeScript)
- Indentation: 4 spaces (C firmware)
- Line breaks: Unix (LF)
- Max line length: ~100 characters for readability (not enforced)

**Linting:**
- No active linter configured — code relies on TypeScript compiler and convention adherence
- TypeScript strict mode implied (interface contracts, type annotations on public functions)

## Import Organization

**Order (TypeScript/Vue):**
1. Vue/Nuxt framework imports: `import { ref, computed } from 'vue'`
2. External packages: `import { createClient } from '@supabase/supabase-js'`
3. Internal imports by layer: `import { useOrganization } from './useOrganization'`
4. Local imports (same file): None — keep local to file unless reusable

**Path Aliases:**
- `#imports` — Nuxt auto-import stub, resolves to `app/test-helpers/nuxt-stubs.ts` for testing
- `@/components` — Components in `app/components/`
- `@/composables` — Composables in `app/composables/`
- `@/lib` — Utilities in `app/lib/`

**Barrel Files:**
- Not used — import directly from source files: `import { useOrganization } from '@/composables/useOrganization'`

## Error Handling

**Patterns:**
- Try/catch blocks with `finally` to guarantee cleanup (especially in composables managing state)
- Error extraction: `if (error) throw error` after Supabase queries
- User-facing errors: Cast to `Error` before returning: `err instanceof Error ? err.message : 'fallback'`
- Suppress errors gracefully in non-critical paths: `catch { warehouseStock.value = new Map() }`

**Example from composables:**
```typescript
async function fetchLogs(embeddedId: string) {
    loading.value = true
    try {
        const { data, error } = await supabase.from('mdb_log').select('*')...
        if (error) throw error
        logs.value = (data ?? []) as MdbLogEntry[]
    } finally {
        loading.value = false
    }
}
```

**Example from pages:**
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

**Framework:** `console` (no logging library configured)

**Patterns:**
- Frontend: No logs in UI code — errors shown in UI via state (`machineError`, `error` refs)
- Backend (edge functions): `console.log()` for debugging, structured via JSON
- Firmware (C): `ESP_LOG*` macros with TAG constant: `#define TAG "mdb_cashless"`, then `ESP_LOGI(TAG, "...")`

**When to Log:**
- Firmware diagnostics: State changes, error conditions, periodic heartbeats
- Backend: Authentication failures, payment processing errors, OTA operations
- Frontend: Never log to console in production code — use error state refs instead

## Comments

**When to Comment:**
- Complex algorithms: Explain "why" not "what" (code reads "what")
- Section markers: Use `// ── [Section Name] ──────────` for readability
- Async gotchas: Comment on intentional fire-and-forget patterns

**JSDoc/TSDoc:**
- Function signatures: Minimal — type annotations are documentation
- Complex functions: Optional JSDoc above public functions explaining inputs/outputs
- Interfaces: Optional descriptions where contract is non-obvious

**Example:**
```typescript
/**
 * i18n-aware timeAgo — pass the `t` function from useI18n().
 * Falls back to English if no `t` provided.
 */
export function timeAgo(dt: string | null | undefined, t?: (key: string, params?: Record<string, any>) => string): string
```

## Function Design

**Size:**
- Keep functions under 50 lines when possible
- Break complex logic into focused helper functions (see `useMachineTrays.ts` with `logActivity`, `getMachineName`)

**Parameters:**
- Destructure optional parameters: `async function fetchTrays(machineId: string, { silent = false } = {})`
- Avoid parameter objects for single/double parameters — use positional
- Named parameters with defaults for optional flags

**Return Values:**
- Return reactive refs from composables: `return { logs, loading, hasMore, fetchLogs, fetchMore, subscribe }`
- Null for missing data: `const name = data?.name ?? null`
- Falsy returns on empty queries: `if (!oldest) return`

## Module Design

**Exports:**
- Composables export single default function: `export function useMdbLog()`
- Utilities export named functions: `export function cn(...inputs)`, `export function timeAgo(...)`
- Interfaces alongside implementations: Define in the file where they're used

**Example structure (composable):**
```typescript
// Interfaces first
interface MdbLogEntry { ... }

// Helper functions (exported for testing)
export function stateLabel(state: string): string { ... }
export function stateVariant(state: string): ... { ... }

// Main composable function last
export function useMdbLog() { ... }
```

**Internal state patterns:**
- Cache with cleanup: `const machineNameCache = new Map<string, string>()`
- Debounced operations: `const pendingStockTimers = new Map<string, ReturnType<typeof setTimeout>>()`
- Reactive collections: `const pendingStockTrays = reactive(new Set<string>())`

## Database Column Naming

All database columns use **snake_case** (PostgreSQL default). Interface properties match exactly:
- Table: `organization_members` → Interface property: `organization_members`
- Column: `created_at` → Property: `created_at`
- Column: `embedded_id` → Property: `embedded_id`

This removes any mapping layer — types are direct mirrors of DB schema.

## Activity Logging Pattern

Critical operations (e.g., stock adjustments, refills, product updates) call a shared `logActivity()` helper:

```typescript
async function logActivity(action: string, entityId: string | null, metadata: Record<string, unknown>) {
    const { data: { session } } = await supabase.auth.getSession()
    // Insert to history table with user_id, action, entity_id, metadata
}
```

Called from composables like `useMachineTrays`, `useWarehouse` whenever user actions modify data.

## Deno/TypeScript Edge Functions

- Imports from CDN: `import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'`
- No npm dependencies in edge functions — use Deno standard library and remote imports
- Error responses: Always return JSON with appropriate status codes
- Authentication: Extract JWT from `Authorization: Bearer ...` header; hash API keys with SHA-256

---

*Convention analysis: 2026-03-13*
