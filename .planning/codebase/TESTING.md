# Testing Patterns

**Analysis Date:** 2026-03-13

## Test Framework

**Runner:**
- Vitest 4.0.18
- Config: `management-frontend/vitest.config.ts`
- Environment: happy-dom (lightweight DOM simulation for Vue components)

**Assertion Library:**
- Vitest built-in expect API (similar to Jest)

**Run Commands:**
```bash
cd management-frontend
npm run test            # Run all tests once
npm run test:watch     # Watch mode with auto-rerun
```

## Test File Organization

**Location:**
- Co-located in `app/composables/__tests__/` directory alongside source
- Single test file per composable: `useMdbLog.ts` → `useMdbLog.test.ts`

**Naming:**
- `.test.ts` suffix for test files

**Structure:**
```
management-frontend/
├── app/
│   ├── composables/
│   │   ├── useMdbLog.ts
│   │   ├── useMachines.ts
│   │   ├── ...
│   │   └── __tests__/
│   │       └── useMdbLog.test.ts     # Only this exists
│   └── test-helpers/
│       └── nuxt-stubs.ts             # Mock utilities
```

## Test Structure

**Suite Organization:**

```typescript
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { stateLabel, stateVariant } from '../useMdbLog'

// Pure helper tests
describe('stateLabel', () => {
    it('maps known MDB states to human-readable labels', () => {
        expect(stateLabel('INACTIVE')).toBe('Inactive')
    })
})

// Composable tests (with mocks)
describe('useMdbLog composable', () => {
    beforeEach(() => {
        vi.clearAllMocks()
    })

    it('fetchLogs queries mdb_log table with correct filters', async () => {
        // Test implementation
    })
})
```

**Patterns:**
- Separate describe blocks for pure functions vs. composables
- `beforeEach` clears all mocks before each test
- Re-wire mock return chains after `vi.clearAllMocks()` to restore chainability

## Mocking

**Framework:** Vitest `vi` module

**Patterns:**

Mock Supabase client (from `useMdbLog.test.ts`):

```typescript
const mockChannel = {
    on: vi.fn().mockReturnThis(),
    subscribe: vi.fn().mockReturnThis(),
}
const mockSupabase = {
    from: vi.fn().mockReturnThis(),
    select: vi.fn().mockReturnThis(),
    eq: vi.fn().mockReturnThis(),
    lt: vi.fn().mockReturnThis(),
    order: vi.fn().mockReturnThis(),
    limit: vi.fn().mockResolvedValue({ data: [], error: null }),
    channel: vi.fn().mockReturnValue(mockChannel),
    removeChannel: vi.fn(),
}

// Mock the import alias
vi.mock('#imports', () => {
    const { ref } = require('vue')
    return {
        ref,
        useSupabaseClient: () => mockSupabase,
    }
})
```

**What to Mock:**
- Supabase client (all database queries)
- Composable imports via Nuxt aliases (`#imports`)
- Timers if testing debounce/throttle patterns (use `vi.useFakeTimers()`)

**What NOT to Mock:**
- Vue reactivity primitives (`ref`, `computed`, `watch`) — test with real implementations
- Pure utility functions like `stateLabel()`, `formatCurrency()` — test directly
- Simple state reads — test through the actual composable API

## Fixtures and Factories

**Test Data:**

From `useMdbLog.test.ts`, inline test data:

```typescript
const testData = [
    {
        id: '1',
        created_at: '2026-03-05T10:00:00Z',
        embedded_id: 'dev-1',
        state: 'ENABLED',
        prev_state: 'DISABLED',
        addr: '0x10',
        polls: 100,
        chk_err: 0,
        last_cmd: 'READER_ENABLE',
        raw: {},
    },
]
mockSupabase.limit.mockResolvedValueOnce({ data: testData, error: null })
```

**Location:**
- No shared fixture files — define test data inline in each test
- Use meaningful sample data (real IDs, timestamps) rather than generic placeholders
- Cursor-based pagination tests: Create arrays of 50 items to test PAGE_SIZE boundaries

**Example (pagination boundary):**

```typescript
const page1 = Array.from({ length: 50 }, (_, i) => ({
    id: `id-${i}`,
    created_at: i === 49 ? OLDEST_TIMESTAMP : `2026-03-05T09:${String(59 - i).padStart(2, '0')}:00Z`,
    // ...
}))
```

## Coverage

**Requirements:** None enforced

**View Coverage:**
```bash
# No coverage tool configured
# Tests exist only for composables as of 2026-03-13
```

## Test Types

**Unit Tests:**
- Scope: Individual composables and pure utility functions
- Approach: Mock external dependencies (Supabase), test composable logic in isolation
- Focus: State management (refs, reactive collections), pagination, event subscriptions

**Integration Tests:**
- Scope: Not configured — rely on unit tests + manual UI testing
- Approach: N/A

**E2E Tests:**
- Framework: Not used
- Approach: Manual testing in browser or via PWA on device

## Common Patterns

**Async Testing:**

```typescript
it('fetchLogs queries mdb_log table with correct filters', async () => {
    mockSupabase.limit.mockResolvedValueOnce({ data: testData, error: null })

    const { useMdbLog } = await import('../useMdbLog')
    const { fetchLogs, logs } = useMdbLog()

    await fetchLogs('dev-1')

    expect(logs.value).toHaveLength(1)
})
```

- Import composable inside `async` test to use fresh mock setup
- Await composable method calls (`await fetchLogs(...)`)
- Assert state after await completes

**Error Testing:**

From the codebase, error handling is implicit:
```typescript
const { data, error } = await supabase...
if (error) throw error
```

Tests would assert errors are thrown and caught:
```typescript
it('throws on query error', async () => {
    mockSupabase.limit.mockResolvedValueOnce({
        data: null,
        error: new Error('DB error')
    })

    const { useMdbLog } = await import('../useMdbLog')
    const { fetchLogs } = useMdbLog()

    await expect(fetchLogs('dev-1')).rejects.toThrow('DB error')
})
```

(Not currently present in codebase, but pattern-based on existing try/catch flows)

**Pagination Testing:**

Cursor-based pagination (as seen in `useMdbLog`):

```typescript
it('fetchMore uses cursor-based pagination with lt()', async () => {
    // Page 1: exactly 50 items
    const page1 = Array.from({ length: 50 }, (_, i) => ({
        id: `id-${i}`,
        created_at: i === 49 ? OLDEST_TIMESTAMP : `...`,
        // ...
    }))

    mockSupabase.limit.mockResolvedValueOnce({ data: page1, error: null })

    const { useMdbLog } = await import('../useMdbLog')
    const { fetchLogs, fetchMore, hasMore } = useMdbLog()

    await fetchLogs('dev-1')
    expect(hasMore.value).toBe(true)  // PAGE_SIZE = 50, so exactly 50 means more

    // Page 2: fewer results
    mockSupabase.limit.mockResolvedValueOnce({
        data: [{ id: 'page2-1', state: 'IDLE', created_at: '...' }],
        error: null,
    })

    await fetchMore('dev-1')

    // Assert lt() was called with the oldest timestamp from page 1
    expect(mockSupabase.lt).toHaveBeenCalledWith('created_at', OLDEST_TIMESTAMP)
    expect(hasMore.value).toBe(false)  // < PAGE_SIZE means no more
})
```

**Mock Chain Restoration:**

After `vi.clearAllMocks()`, restore chaining:

```typescript
beforeEach(() => {
    vi.clearAllMocks()
    // Re-wire chaining since clearAllMocks resets mockReturnThis
    mockSupabase.from.mockReturnThis()
    mockSupabase.select.mockReturnThis()
    mockSupabase.eq.mockReturnThis()
    mockSupabase.lt.mockReturnThis()
    mockSupabase.order.mockReturnThis()
    mockChannel.on.mockReturnThis()
    mockChannel.subscribe.mockReturnThis()
    mockSupabase.channel.mockReturnValue(mockChannel)
})
```

## Test Utilities

**Helper File:**
- `management-frontend/app/test-helpers/nuxt-stubs.ts` — Stubs for Nuxt auto-imports

**Contents:**
```typescript
// Re-export Vue reactivity primitives
export { ref, computed, onMounted, onUnmounted, watch, reactive }

// Stub useSupabaseClient — tests provide their own mock
export function useSupabaseClient() {
    throw new Error('useSupabaseClient must be mocked in tests')
}

// Stub useState (simplified — returns a plain ref)
export function useState<T>(key: string, init?: () => T) {
    return ref(init ? init() : undefined) as ReturnType<typeof ref<T>>
}
```

## Edge Function Tests

**Location:**
- `Docker/supabase/functions/mqtt-webhook/mdb-log.test.ts` — Deno test for MQTT webhook handler

**Pattern:**
- Deno `Deno.test()` instead of Vitest
- Test MQTT payload decryption and Supabase writes

(Limited coverage as of 2026-03-13 — focus is on critical payment/webhook paths)

## Current Test Coverage

**Tests Present:**
- `management-frontend/app/composables/__tests__/useMdbLog.test.ts` — 8 test cases
  - Pure function tests: `stateLabel()`, `stateVariant()`
  - Composable API: `fetchLogs()`, `fetchMore()`, `subscribe()`, pagination, no-op guard

**Tests Missing:**
- useMachines, useMachineTrays, useProducts, useWarehouse — No unit tests
- Vue components — No component tests
- Edge functions (except mdb-log webhook) — No tests
- Frontend pages — No E2E tests

**Why Limited Coverage:**
- Rapid iteration phase — focus on correctness over automated test suite
- Manual testing via PWA/devices more valuable for UI/UX at this stage
- Infrastructure components (edge functions, MQTT) tested via integration with firmware

---

*Testing analysis: 2026-03-13*
