# Testing Patterns

**Analysis Date:** 2026-03-13

## Test Framework

**Runner:**
- Vitest 4.0.18
- Config: `vitest.config.ts`
- Environment: `happy-dom` (lightweight DOM simulation)

**Assertion Library:**
- Vitest built-in expect (Chai-style)

**Run Commands:**
```bash
npm run test              # Run all tests (single run)
npm run test:watch       # Watch mode
npx vitest run           # Explicit single run from management-frontend/
npx vitest               # Explicit watch mode from management-frontend/
```

## Test File Organization

**Location:**
- Co-located in `__tests__/` subdirectory next to source files: `app/composables/__tests__/useMdbLog.test.ts`
- Pattern: `__tests__/[composable-name].test.ts`

**Naming:**
- `.test.ts` suffix (not `.spec.ts`)

**Structure:**
```
app/
├── composables/
│   ├── useMdbLog.ts              (source)
│   └── __tests__/
│       └── useMdbLog.test.ts      (tests)
├── lib/
│   └── utils.ts
└── test-helpers/
    └── nuxt-stubs.ts             (Vitest mocking stubs)
```

## Test Structure

**Suite Organization:**
```typescript
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { stateLabel, stateVariant } from '../useMdbLog'

// ── Pure helper tests ─────────────────────────────────────────────────────────
describe('stateLabel', () => {
    it('maps known MDB states to human-readable labels', () => {
        expect(stateLabel('INACTIVE')).toBe('Inactive')
        expect(stateLabel('DISABLED')).toBe('Disabled')
    })

    it('returns the raw string for unrecognised states', () => {
        expect(stateLabel('CUSTOM_STATE')).toBe('CUSTOM_STATE')
    })
})

// ── Composable tests (with mocked Supabase) ─────────────────────────────────
describe('useMdbLog composable', () => {
    beforeEach(() => {
        vi.clearAllMocks()
        // Re-setup mocks after clear
    })

    it('fetchLogs queries mdb_log table with correct filters', async () => {
        // arrange
        const testData = [{ id: '1', ... }]
        mockSupabase.limit.mockResolvedValueOnce({ data: testData, error: null })

        // act
        const { useMdbLog } = await import('../useMdbLog')
        const { logs, fetchLogs } = useMdbLog()
        await fetchLogs('dev-1')

        // assert
        expect(mockSupabase.from).toHaveBeenCalledWith('mdb_log')
        expect(logs.value).toHaveLength(1)
    })
})
```

**Patterns:**
- Setup: `beforeEach()` clears and re-wires mocks
- Teardown: implicit via `vi.clearAllMocks()`
- Assertions: `expect(value).toBe(...)`, `expect(fn).toHaveBeenCalledWith(...)`

## Mocking

**Framework:** Vitest `vi` module

**Patterns:**

1. **Mock auto-imports via path alias:**
   - Vitest alias in `vitest.config.ts` redirects `#imports` to `app/test-helpers/nuxt-stubs.ts`
   - Composables use `import { useSupabaseClient } from '#imports'`
   - Tests mock `#imports` to inject test doubles:

```typescript
vi.mock('#imports', () => {
    const { ref } = require('vue')
    return {
        ref,
        useSupabaseClient: () => mockSupabase,
    }
})
```

2. **Supabase client mock:**
   - Fluent query builder pattern: `.from().select().eq().order().limit()`
   - Each method returns `this` for chaining, last call resolves to `{ data, error }`
   - Mock with `vi.fn().mockReturnThis()` to allow chaining

```typescript
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
```

3. **Realtime channel mock:**
   - Similar fluent pattern for `.on()` and `.subscribe()`
   - Callback functions passed to `.on()` are inspected to verify event filtering

```typescript
const mockChannel = {
    on: vi.fn().mockReturnThis(),
    subscribe: vi.fn().mockReturnThis(),
}
```

4. **Re-wiring mocks after `vi.clearAllMocks()`:**
   - `clearAllMocks()` resets mock implementation but not return values
   - Must manually re-set fluent method chains in `beforeEach()`:

```typescript
beforeEach(() => {
    vi.clearAllMocks()
    mockSupabase.from.mockReturnThis()
    mockSupabase.select.mockReturnThis()
    mockSupabase.eq.mockReturnThis()
    // ... repeat for all methods
    mockChannel.on.mockReturnThis()
    mockChannel.subscribe.mockReturnThis()
})
```

**What to Mock:**
- Supabase client queries (database access)
- Realtime subscriptions (websocket channels)
- Imported Nuxt composables (useSupabaseClient, useState)

**What NOT to Mock:**
- Pure helper functions (`stateLabel()`, `expirationStatus()`) — test directly
- Vue reactivity primitives (`ref`, `computed`, `watch`) — use real implementations

## Fixtures and Factories

**Test Data:**
- Inline literal objects with realistic field values
- Factory pattern not used; compose test data directly in test

```typescript
it('fetchLogs queries mdb_log table with correct filters', async () => {
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
})
```

**Location:**
- Fixtures: inline in test file (no shared fixture files currently)
- Test data lives in `__tests__/` directory alongside test file

## Coverage

**Requirements:** Not enforced (no coverage threshold configured)

**View Coverage:**
```bash
npx vitest run --coverage  # if coverage tool installed
```

Currently: coverage tracking not configured in vitest.config.ts

## Test Types

**Unit Tests:**
- Scope: Pure helper functions (`stateLabel()`, `stateVariant()`)
- Approach: Direct function calls with literal inputs, expect literal outputs
- Example from `useMdbLog.test.ts`:
```typescript
describe('stateLabel', () => {
    it('maps known MDB states to human-readable labels', () => {
        expect(stateLabel('INACTIVE')).toBe('Inactive')
        expect(stateLabel('DISABLED')).toBe('Disabled')
        expect(stateLabel('IDLE')).toBe('Idle')
        expect(stateLabel('VEND')).toBe('Vending')
    })
})
```

**Integration Tests:**
- Scope: Composable functions with mocked Supabase (e.g., `fetchLogs()`, `subscribe()`)
- Approach: Mock Supabase query builder, assert correct query parameters + state updates
- Example from `useMdbLog.test.ts`:
```typescript
describe('useMdbLog composable', () => {
    it('fetchLogs queries mdb_log table with correct filters', async () => {
        const testData = [{ id: '1', state: 'ENABLED', ... }]
        mockSupabase.limit.mockResolvedValueOnce({ data: testData, error: null })

        const { useMdbLog } = await import('../useMdbLog')
        const { logs, fetchLogs } = useMdbLog()
        await fetchLogs('dev-1')

        expect(mockSupabase.from).toHaveBeenCalledWith('mdb_log')
        expect(mockSupabase.eq).toHaveBeenCalledWith('embedded_id', 'dev-1')
        expect(logs.value).toHaveLength(1)
        expect(logs.value[0].state).toBe('ENABLED')
    })

    it('fetchMore uses cursor-based pagination with lt()', async () => {
        // Page 1: 50 items
        const page1 = Array.from({ length: 50 }, (_, i) => ({
            id: `id-${i}`,
            created_at: i === 49 ? '2026-03-05T08:30:00Z' : `2026-03-05T09:${...}:00Z`,
            ...
        }))
        mockSupabase.limit.mockResolvedValueOnce({ data: page1, error: null })

        const { useMdbLog } = await import('../useMdbLog')
        const { fetchLogs, fetchMore, hasMore } = useMdbLog()
        await fetchLogs('dev-1')
        expect(hasMore.value).toBe(true)

        // Page 2: fewer results
        mockSupabase.limit.mockResolvedValueOnce({
            data: [{ id: 'page2-1', state: 'IDLE', ... }],
            error: null,
        })
        await fetchMore('dev-1')

        expect(mockSupabase.lt).toHaveBeenCalledWith('created_at', '2026-03-05T08:30:00Z')
    })
})
```

**E2E Tests:**
- Status: Not implemented
- Framework: Would use Playwright or Cypress (not currently in package.json)

## Common Patterns

**Async Testing:**
- Use async/await syntax in test functions
- Await async composable methods: `await fetchLogs('dev-1')`
- No explicit done() callback required (Vitest handles Promise resolution)

```typescript
it('fetchLogs queries mdb_log table with correct filters', async () => {
    mockSupabase.limit.mockResolvedValueOnce({ data: testData, error: null })
    const { logs, fetchLogs } = useMdbLog()
    await fetchLogs('dev-1')  // await resolves Promise
    expect(logs.value).toHaveLength(1)
})
```

**Error Testing:**
- Mock Supabase error response: `{ data: null, error: new Error('...') }`
- Expect composable to throw: `expect(() => async fn()).rejects.toThrow(...)`
- Currently: errors tested implicitly (composables throw when error received)

```typescript
// Pattern (if error handling test needed):
mockSupabase.limit.mockResolvedValueOnce({
    data: null,
    error: new Error('Database error'),
})

const { fetchLogs } = useMdbLog()
await expect(fetchLogs('dev-1')).rejects.toThrow('Database error')
```

**State Verification:**
- Verify ref state after async operation: `expect(logs.value).toEqual([...])`
- Verify mutation effects: `expect(mockSupabase.from).toHaveBeenCalledWith('table_name')`

```typescript
it('subscribe creates realtime channel with correct filter and returns cleanup', async () => {
    const { subscribe } = useMdbLog()
    const cleanup = subscribe('dev-42')

    expect(mockSupabase.channel).toHaveBeenCalledWith('mdb-log-dev-42')
    expect(mockChannel.on).toHaveBeenCalledWith(
        'postgres_changes',
        expect.objectContaining({
            event: 'INSERT',
            schema: 'public',
            table: 'mdb_log',
            filter: 'embedded_id=eq.dev-42',
        }),
        expect.any(Function),
    )
    expect(typeof cleanup).toBe('function')

    cleanup()
    expect(mockSupabase.removeChannel).toHaveBeenCalled()
})
```

## Test Coverage Gaps

**Currently Untested:**
- Vue components (pages, UI components) — no unit tests for template logic
- Realtime event handlers (callbacks passed to `.on()` not invoked in tests)
- Error paths in composables (composables throw but error behavior not tested)
- Browser APIs (localStorage, sessionStorage, WebStorage)
- Nuxt middleware (`auth.ts`) — no tests

---

*Testing analysis: 2026-03-13*
