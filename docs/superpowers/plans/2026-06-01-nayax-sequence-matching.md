# Nayax Reconciliation: Order-Based (Sequence) Matching — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Nayax reconciliation's ±N-second timestamp matcher with a per-machine ordered-sequence diff (LCS keyed on slot), promote phantom (DB-only) rows to a highlighted bucket, and group the differences list by day.

**Architecture:** All matching logic lives in the `useNayaxReconciliation` composable as small, pure, unit-tested helpers (`alignSequences`, `alignMachine`, `bufferRange`, `groupDifferencesByDay`) orchestrated by `runMatch`. Time is used only to sort each machine's two sequences; matching is by slot order. The four Nayax components are thin views over the composable's reactive state.

**Tech Stack:** Nuxt 4 / Vue 3 `<script setup>` + TypeScript, Vitest (with `app/test-helpers/nuxt-stubs.ts` aliasing `#imports`), `@nuxtjs/i18n` (en/de), Tailwind 4, `@tabler/icons-vue`.

**Spec:** `docs/superpowers/specs/2026-06-01-nayax-sequence-matching-design.md`

**Skills to use:** @superpowers:test-driven-development for every pure-helper task; @superpowers:verification-before-completion before claiming done.

---

## File Structure

| File | Responsibility | Change |
|------|----------------|--------|
| `management-frontend/app/composables/useNayaxReconciliation.ts` | matching logic + state | add 4 pure helpers + types; rewrite `runMatch`; buffer in `loadDbSales`; drop `toleranceSeconds` |
| `management-frontend/app/composables/__tests__/useNayaxReconciliation.test.ts` | unit tests | add helper tests; rewrite `runMatch` block |
| `management-frontend/app/components/nayax/NayaxSettingsStep.vue` | settings form | remove tolerance field/clamp |
| `management-frontend/app/pages/reports/nayax-reconciliation.vue` | wizard page | remove tolerance localStorage + clamp |
| `management-frontend/app/components/nayax/NayaxResultsView.vue` | results header | method label + price-diff count + bucketed notice |
| `management-frontend/app/components/nayax/NayaxMatchedTable.vue` | matched table | price-differs badge |
| `management-frontend/app/components/nayax/NayaxDifferencesTable.vue` | differences table | phantom warning styling + day grouping |
| `management-frontend/i18n/locales/en.json`, `…/de.json` | strings | remove tolerance keys; add 5 result keys |

**All commands below run from `management-frontend/`** unless stated otherwise.

---

## Chunk 1: Core matching logic (composable + unit tests)

**End state of this chunk:** `npx vitest run app/composables/__tests__/useNayaxReconciliation.test.ts` is green. `toleranceSeconds` is intentionally still present in the types (removed in Chunk 2) so the `.vue` files keep type-checking; `runMatch` simply ignores it.

### Task 1.0: Pin the test timezone to UTC

`groupDifferencesByDay` keys on the **browser-local** calendar day (correct for production, where it must match `formatDateTime`'s untimezoned display). That makes any day-boundary assertion runner-timezone-dependent — and no pair of distinct instants is safe for *every* offset (UTC+12/+13/−12 have a local midnight that can fall between any two same-UTC-day timestamps). Pin the test process to UTC so the grouping *logic* (membership, order, tiebreak) is tested deterministically.

**Files:** Modify `vitest.config.ts`.

- [ ] **Step 1: Add `env: { TZ: 'UTC' }`** to the `test` block:

```ts
  test: {
    environment: 'happy-dom',
    include: ['app/**/*.test.ts', 'app/**/*.spec.ts'],
    env: { TZ: 'UTC' },
  },
```

- [ ] **Step 2: Confirm the existing suite still passes under UTC**

Run: `npx vitest run`
Expected: PASS — the existing date tests use explicit IANA timezones (`Europe/Berlin`) via `date-fns-tz`, so pinning the *runner* TZ does not change them.

- [ ] **Step 3: Commit**

```bash
git add vitest.config.ts
git commit -m "test: pin vitest timezone to UTC for deterministic date logic"
```

### Task 1.1: Pure LCS aligner `alignSequences`

**Files:**
- Modify: `app/composables/useNayaxReconciliation.ts` (add exported function near the other top-level helpers, e.g. after `derivedChannelFromPaymentSource`)
- Test: `app/composables/__tests__/useNayaxReconciliation.test.ts`

- [ ] **Step 1: Write the failing tests** — append to the test file:

```ts
import { alignSequences } from '../useNayaxReconciliation'

describe('alignSequences', () => {
  it('aligns two identical sequences fully', () => {
    expect(alignSequences([1, 2, 3], [1, 2, 3])).toEqual({
      pairs: [[0, 0], [1, 1], [2, 2]], aOnly: [], bOnly: [],
    })
  })

  it('flags a gap in B as aOnly (in order)', () => {
    // A=[1,2,3], B=[1,3]  -> 2 is missing from B
    expect(alignSequences([1, 2, 3], [1, 3])).toEqual({
      pairs: [[0, 0], [2, 1]], aOnly: [1], bOnly: [],
    })
  })

  it('flags an extra in B as bOnly', () => {
    // A=[1,3], B=[1,2,3] -> 2 is extra in B
    expect(alignSequences([1, 3], [1, 2, 3])).toEqual({
      pairs: [[0, 0], [1, 2]], aOnly: [], bOnly: [1],
    })
  })

  it('handles repeats: one of two equal tokens is missing', () => {
    // A=[1,1,2], B=[1,2] -> one of the 1s is aOnly
    expect(alignSequences([1, 1, 2], [1, 2])).toEqual({
      pairs: [[0, 0], [2, 1]], aOnly: [1], bOnly: [],
    })
  })

  it('reports both directions for an adjacent swap of distinct tokens', () => {
    // A=[1,2], B=[2,1] -> LCS length 1
    const out = alignSequences([1, 2], [2, 1])
    expect(out.pairs).toEqual([[1, 0]]) // the 2s align
    expect(out.aOnly).toEqual([0])      // the leading 1 in A
    expect(out.bOnly).toEqual([1])      // the trailing 1 in B
  })

  it('handles empty inputs', () => {
    expect(alignSequences([], [5, 6])).toEqual({ pairs: [], aOnly: [], bOnly: [0, 1] })
    expect(alignSequences([5, 6], [])).toEqual({ pairs: [], aOnly: [0, 1], bOnly: [] })
  })
})
```

- [ ] **Step 2: Run to verify it fails**

Run: `npx vitest run app/composables/__tests__/useNayaxReconciliation.test.ts -t alignSequences`
Expected: FAIL — `alignSequences is not a function` / import error.

- [ ] **Step 3: Implement** — add to `useNayaxReconciliation.ts`:

```ts
/**
 * Longest-common-subsequence alignment of two integer sequences.
 * Returns matched index pairs (ascending) plus the unmatched indices on each
 * side. Pure and deterministic; used to reconcile Nayax vs DB sale order
 * keyed on slot/item number. Time is NOT consulted — callers pre-sort.
 *
 * Suffix DP (dp[i][j] = LCS length of a[i:], b[j:]) with a front backtrack.
 * O(n·m) time and space; see `alignMachine` for the size guard.
 */
export function alignSequences(
  a: number[],
  b: number[],
): { pairs: Array<[number, number]>; aOnly: number[]; bOnly: number[] } {
  const n = a.length
  const m = b.length
  const w = m + 1
  const dp = new Int32Array((n + 1) * w)
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      if (a[i] === b[j]) {
        dp[i * w + j] = dp[(i + 1) * w + (j + 1)] + 1
      } else {
        const down = dp[(i + 1) * w + j]
        const right = dp[i * w + (j + 1)]
        dp[i * w + j] = down >= right ? down : right
      }
    }
  }
  const pairs: Array<[number, number]> = []
  const aOnly: number[] = []
  const bOnly: number[] = []
  let i = 0
  let j = 0
  while (i < n && j < m) {
    if (a[i] === b[j]) {
      pairs.push([i, j]); i++; j++
    } else if (dp[(i + 1) * w + j] >= dp[i * w + (j + 1)]) {
      aOnly.push(i); i++
    } else {
      bOnly.push(j); j++
    }
  }
  while (i < n) { aOnly.push(i); i++ }
  while (j < m) { bOnly.push(j); j++ }
  return { pairs, aOnly, bOnly }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `npx vitest run app/composables/__tests__/useNayaxReconciliation.test.ts -t alignSequences`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add app/composables/useNayaxReconciliation.ts app/composables/__tests__/useNayaxReconciliation.test.ts
git commit -m "feat(nayax): pure LCS aligner for sequence reconciliation"
```

### Task 1.2: Machine aligner with size guard `alignMachine`

**Files:** same two files as Task 1.1.

- [ ] **Step 1: Write the failing tests**

```ts
import { alignMachine } from '../useNayaxReconciliation'

describe('alignMachine', () => {
  const days = (n: number, d = '2026-03-10') => Array(n).fill(d)

  it('uses a single LCS under the cell budget (bucketed=false)', () => {
    const out = alignMachine([1, 2, 3], days(3), [1, 3], days(2), 1_000_000)
    expect(out.bucketed).toBe(false)
    expect(out.pairs).toEqual([[0, 0], [2, 1]])
    expect(out.aOnly).toEqual([1])
    expect(out.bOnly).toEqual([])
  })

  it('falls back to per-UTC-day buckets over budget (bucketed=true), translating indices', () => {
    // Two days; force the fallback with a tiny budget.
    const aKeys = [1, 2, 9]
    const aDays = ['2026-03-10', '2026-03-10', '2026-03-11']
    const bKeys = [1, 2, 9]
    const bDays = ['2026-03-10', '2026-03-10', '2026-03-11']
    const out = alignMachine(aKeys, aDays, bKeys, bDays, 1)
    expect(out.bucketed).toBe(true)
    expect(out.pairs).toEqual([[0, 0], [1, 1], [2, 2]])
    expect(out.aOnly).toEqual([])
    expect(out.bOnly).toEqual([])
  })

  it('does not align identical tokens that fall in different day buckets (the fallback tradeoff)', () => {
    // Same token 5 but on different days -> cannot pair under day-bucketing.
    const out = alignMachine([5], ['2026-03-10'], [5], ['2026-03-11'], 1)
    expect(out.bucketed).toBe(true)
    expect(out.pairs).toEqual([])
    expect(out.aOnly).toEqual([0])
    expect(out.bOnly).toEqual([0])
  })
})
```

- [ ] **Step 2: Run to verify it fails**

Run: `npx vitest run app/composables/__tests__/useNayaxReconciliation.test.ts -t alignMachine`
Expected: FAIL — `alignMachine is not a function`.

- [ ] **Step 3: Implement** — add to `useNayaxReconciliation.ts` (below `alignSequences`):

```ts
/**
 * Align one machine's Nayax sequence (a) against its DB sequence (b), keyed on
 * slot. `aDays`/`bDays` are the per-element UTC day strings ("YYYY-MM-DD"),
 * positionally paired with `aKeys`/`bKeys` (both pre-sorted by time).
 *
 * Normally one `alignSequences` call. If the DP table would exceed `maxCells`
 * (a pathological single-machine upload), it falls back to aligning within
 * each UTC-day bucket and sets `bucketed: true`. Day-bucketing bounds cost but
 * cannot pair two equal slots that drifted across UTC midnight — an accepted
 * tradeoff that only ever applies to over-budget machines.
 */
export function alignMachine(
  aKeys: number[],
  aDays: string[],
  bKeys: number[],
  bDays: string[],
  maxCells: number,
): { pairs: Array<[number, number]>; aOnly: number[]; bOnly: number[]; bucketed: boolean } {
  const n = aKeys.length
  const m = bKeys.length
  if ((n + 1) * (m + 1) <= maxCells) {
    return { ...alignSequences(aKeys, bKeys), bucketed: false }
  }
  const dayKeys = [...new Set([...aDays, ...bDays])].sort()
  const pairs: Array<[number, number]> = []
  const aOnly: number[] = []
  const bOnly: number[] = []
  for (const day of dayKeys) {
    const aIdx: number[] = []
    for (let i = 0; i < n; i++) if (aDays[i] === day) aIdx.push(i)
    const bIdx: number[] = []
    for (let j = 0; j < m; j++) if (bDays[j] === day) bIdx.push(j)
    const sub = alignSequences(aIdx.map(i => aKeys[i]!), bIdx.map(j => bKeys[j]!))
    for (const [x, y] of sub.pairs) pairs.push([aIdx[x]!, bIdx[y]!])
    for (const x of sub.aOnly) aOnly.push(aIdx[x]!)
    for (const y of sub.bOnly) bOnly.push(bIdx[y]!)
  }
  return { pairs, aOnly, bOnly, bucketed: true }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `npx vitest run app/composables/__tests__/useNayaxReconciliation.test.ts -t alignMachine`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add app/composables/useNayaxReconciliation.ts app/composables/__tests__/useNayaxReconciliation.test.ts
git commit -m "feat(nayax): per-machine aligner with day-bucket size guard"
```

### Task 1.3: Query-window buffer `bufferRange`

**Files:** same two files.

- [ ] **Step 1: Write the failing test**

```ts
import { bufferRange } from '../useNayaxReconciliation'

describe('bufferRange', () => {
  it('pads both bounds by the given seconds without mutating inputs', () => {
    expect(bufferRange('2026-03-01T00:00:00.000Z', '2026-03-31T23:59:59.000Z', 120)).toEqual({
      gte: '2026-02-28T23:58:00.000Z',
      lte: '2026-04-01T00:01:59.000Z',
    })
  })
})
```

- [ ] **Step 2: Run to verify it fails**

Run: `npx vitest run app/composables/__tests__/useNayaxReconciliation.test.ts -t bufferRange`
Expected: FAIL — `bufferRange is not a function`.

- [ ] **Step 3: Implement** — add to `useNayaxReconciliation.ts`:

```ts
/**
 * Widen an ISO date range by `seconds` on both ends, for the DB query only.
 * Lets a sale that drifted just across the file's start/end still load and
 * align. The strict range (for ghost classification) is left untouched.
 */
export function bufferRange(
  fromUtc: string,
  toUtc: string,
  seconds: number,
): { gte: string; lte: string } {
  const pad = seconds * 1000
  return {
    gte: new Date(Date.parse(fromUtc) - pad).toISOString(),
    lte: new Date(Date.parse(toUtc) + pad).toISOString(),
  }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `npx vitest run app/composables/__tests__/useNayaxReconciliation.test.ts -t bufferRange`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(nayax): bufferRange helper for the DB query window"
```

### Task 1.4: Differences day-grouping `groupDifferencesByDay`

This moves the merge-sort that currently lives in `NayaxDifferencesTable.vue`'s `mergedRows` computed into a pure, tested composable helper, and adds day grouping on top.

**Files:** same two files.

- [ ] **Step 1: Write the failing tests**

```ts
import { groupDifferencesByDay } from '../useNayaxReconciliation'

describe('groupDifferencesByDay', () => {
  // vitest pins TZ=UTC (Task 1.0), so getFullYear/Month/Date == UTC parts —
  // grouping is by UTC day and these assertions are deterministic on any runner.
  it('groups by day, sorts chronologically, missing-before-ghost on ties', () => {
    const missing = [
      mkNayax({ txId: 'm-d2', utcDt: '2026-03-11T12:00:00.000Z' }),
      mkNayax({ txId: 'm-d1', utcDt: '2026-03-10T12:00:00.000Z' }),
    ]
    const ghosts = [
      mkSale({ id: 'g-d1', created_at: '2026-03-10T12:00:00.000Z' }),
    ]
    const groups = groupDifferencesByDay(missing, ghosts)
    expect(groups).toHaveLength(2)
    // Day 1 group: missing then ghost (same ts -> missing first)
    expect(groups[0]!.rows.map(r => r.kind)).toEqual(['missing', 'ghost'])
    expect(groups[0]!.rows[0]!.kind === 'missing' && groups[0]!.rows[0]!.payload.txId).toBe('m-d1')
    // Day 2 group: the later missing row
    expect(groups[1]!.rows).toHaveLength(1)
    expect(groups[1]!.rows[0]!.kind === 'missing' && groups[1]!.rows[0]!.payload.txId).toBe('m-d2')
  })

  it('returns one group when all rows share a day', () => {
    // TZ=UTC pinned, so these two same-UTC-day instants land in one group.
    const groups = groupDifferencesByDay(
      [mkNayax({ utcDt: '2026-03-10T08:00:00.000Z' }), mkNayax({ utcDt: '2026-03-10T20:00:00.000Z' })],
      [],
    )
    expect(groups).toHaveLength(1)
    expect(groups[0]!.rows).toHaveLength(2)
  })

  it('returns no groups for no differences', () => {
    expect(groupDifferencesByDay([], [])).toEqual([])
  })
})
```

- [ ] **Step 2: Run to verify it fails**

Run: `npx vitest run app/composables/__tests__/useNayaxReconciliation.test.ts -t groupDifferencesByDay`
Expected: FAIL — not a function.

- [ ] **Step 3: Implement** — add to `useNayaxReconciliation.ts` (types near the other interfaces; function near the helpers):

```ts
/** A single differences-table row: a Nayax gap or a DB phantom. */
export type DiffRow =
  | { kind: 'missing'; ts: string; payload: NayaxRow }
  | { kind: 'ghost'; ts: string; payload: DbSale }

/** Differences rows for one calendar day (browser-local), in chronological order. */
export interface DiffDayGroup { dayKey: string; rows: DiffRow[] }

/**
 * Merge the missing + ghost rows, sort chronologically (missing before ghost
 * on identical timestamps), and group into consecutive calendar-day buckets.
 *
 * The day key uses the BROWSER-LOCAL date (getFullYear/Month/Date) — the same
 * basis `formatDateTime`/`formatDate` render with (no `timeZone` option) — so a
 * row never groups under a day that differs from its displayed time.
 */
export function groupDifferencesByDay(
  missing: NayaxRow[],
  ghosts: DbSale[],
): DiffDayGroup[] {
  const rows: DiffRow[] = [
    ...missing.map(m => ({ kind: 'missing' as const, ts: m.utcDt, payload: m })),
    ...ghosts.map(g => ({ kind: 'ghost' as const, ts: g.created_at, payload: g })),
  ]
  rows.sort((a, b) => {
    const c = a.ts.localeCompare(b.ts)
    if (c !== 0) return c
    if (a.kind === b.kind) return 0
    return a.kind === 'missing' ? -1 : 1
  })
  const groups: DiffDayGroup[] = []
  for (const row of rows) {
    const d = new Date(row.ts)
    const dayKey = `${d.getFullYear()}-${d.getMonth()}-${d.getDate()}`
    const last = groups[groups.length - 1]
    if (last && last.dayKey === dayKey) last.rows.push(row)
    else groups.push({ dayKey, rows: [row] })
  }
  return groups
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `npx vitest run app/composables/__tests__/useNayaxReconciliation.test.ts -t groupDifferencesByDay`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(nayax): pure day-grouping helper for the differences list"
```

### Task 1.5: Rewrite `runMatch` to sequence matching + extend types

**Files:**
- Modify: `app/composables/useNayaxReconciliation.ts` — add `MAX_LCS_CELLS`; add `priceDiffers` to `MatchPair`; add `bucketedVmIds` to `ReconResult`; replace `runMatch` body.
- Modify test file: replace the entire `describe('runMatch', …)` block.

- [ ] **Step 1: Extend the types** in `useNayaxReconciliation.ts`.

In `MatchPair` add:
```ts
export interface MatchPair {
  nayax: NayaxRow
  db: DbSale
  deltaSeconds: number      // db.created_at - nayax.utcDt (informational only now)
  priceDiffers: boolean     // round2(nayax.priceGross) !== round2(db.item_price)
}
```
In `ReconResult` add `bucketedVmIds` (keep `settings.toleranceSeconds` for now — removed in Chunk 2):
```ts
export interface ReconResult {
  matched: MatchPair[]
  missingInDb: NayaxRow[]
  ghostInDb: DbSale[]
  unmapped: NayaxRow[]
  unparseable: NayaxRow[]
  fileDateRange: { fromUtc: string; toUtc: string } | null
  bucketedVmIds: string[]   // machines that hit the size guard (day-bucketed)
  settings: {
    timezone: string
    toleranceSeconds: number
  }
}
```
Add a module-level constant near `MAX_ROWS_SOFT_WARN`:
```ts
/**
 * DP cell budget per machine for the sequence aligner. ~20M Int32 cells ≈ 80MB
 * transient — comfortably covers a very busy machine's billing period
 * (~4500×4500). Beyond this, `alignMachine` day-buckets that one machine.
 */
export const MAX_LCS_CELLS = 20_000_000
```

- [ ] **Step 2: Write the failing tests** — replace the whole `describe('runMatch', …)` block (lines ~211–336) with:

```ts
describe('runMatch (sequence)', () => {
  it('matches an exact in-order subset; reports the single gap', () => {
    const r = setupRecon({
      rawRows: [
        mkNayax({ txId: 'A', itemNumber: 10, utcDt: '2026-03-10T08:00:00.000Z' }),
        mkNayax({ txId: 'B', itemNumber: 20, utcDt: '2026-03-10T09:00:00.000Z' }),
        mkNayax({ txId: 'C', itemNumber: 30, utcDt: '2026-03-10T10:00:00.000Z' }),
      ],
      mapping: { N1: 'vm1' },
      dbSales: [
        mkSale({ id: 's1', item_number: 10, created_at: '2026-03-10T08:00:05.000Z' }),
        mkSale({ id: 's3', item_number: 30, created_at: '2026-03-10T10:00:05.000Z' }),
      ],
    })
    r.runMatch()
    expect(r.result.value!.matched.map(m => m.nayax.txId)).toEqual(['A', 'C'])
    expect(r.result.value!.missingInDb.map(n => n.txId)).toEqual(['B'])
    expect(r.result.value!.ghostInDb).toHaveLength(0)
  })

  it('matches identical order even when timestamps are wildly off (drift regression)', () => {
    const r = setupRecon({
      rawRows: [
        mkNayax({ txId: 'A', itemNumber: 10, utcDt: '2026-03-10T08:00:00.000Z' }),
        mkNayax({ txId: 'B', itemNumber: 20, utcDt: '2026-03-10T09:00:00.000Z' }),
        mkNayax({ txId: 'C', itemNumber: 30, utcDt: '2026-03-10T10:00:00.000Z' }),
      ],
      mapping: { N1: 'vm1' },
      dbSales: [
        mkSale({ id: 's1', item_number: 10, created_at: '2026-03-10T08:03:00.000Z' }),
        mkSale({ id: 's2', item_number: 20, created_at: '2026-03-10T09:03:00.000Z' }),
        mkSale({ id: 's3', item_number: 30, created_at: '2026-03-10T10:03:00.000Z' }),
      ],
    })
    r.runMatch()
    expect(r.result.value!.matched).toHaveLength(3)
    expect(r.result.value!.missingInDb).toHaveLength(0)
    expect(r.result.value!.ghostInDb).toHaveLength(0)
  })

  it('flags a DB-only sale as a phantom (ghost) in range', () => {
    const r = setupRecon({
      rawRows: [mkNayax({ itemNumber: 10, utcDt: '2026-03-10T08:00:00.000Z' })],
      mapping: { N1: 'vm1' },
      dbSales: [
        mkSale({ id: 'ok',    item_number: 10, created_at: '2026-03-10T08:00:01.000Z' }),
        mkSale({ id: 'extra', item_number: 99, created_at: '2026-03-10T09:00:00.000Z' }),
      ],
    })
    r.runMatch()
    expect(r.result.value!.matched).toHaveLength(1)
    expect(r.result.value!.ghostInDb.map(s => s.id)).toEqual(['extra'])
  })

  it('handles a repeated slot: one of two equal sales is missing', () => {
    const r = setupRecon({
      rawRows: [
        mkNayax({ txId: 'A', itemNumber: 10, utcDt: '2026-03-10T08:00:00.000Z' }),
        mkNayax({ txId: 'B', itemNumber: 10, utcDt: '2026-03-10T08:05:00.000Z' }),
        mkNayax({ txId: 'C', itemNumber: 20, utcDt: '2026-03-10T08:10:00.000Z' }),
      ],
      mapping: { N1: 'vm1' },
      dbSales: [
        mkSale({ id: 's1', item_number: 10, created_at: '2026-03-10T08:00:30.000Z' }),
        mkSale({ id: 's2', item_number: 20, created_at: '2026-03-10T08:10:30.000Z' }),
      ],
    })
    r.runMatch()
    expect(r.result.value!.matched).toHaveLength(2)
    expect(r.result.value!.missingInDb.map(n => n.txId)).toEqual(['B'])
    expect(r.result.value!.ghostInDb).toHaveLength(0)
  })

  it('matches on slot but flags a price difference', () => {
    const r = setupRecon({
      rawRows: [mkNayax({ itemNumber: 10, priceGross: 2.5, utcDt: '2026-03-10T08:00:00.000Z' })],
      mapping: { N1: 'vm1' },
      dbSales: [mkSale({ item_number: 10, item_price: 3.0, created_at: '2026-03-10T08:00:02.000Z' })],
    })
    r.runMatch()
    expect(r.result.value!.matched).toHaveLength(1)
    expect(r.result.value!.matched[0]!.priceDiffers).toBe(true)
    expect(r.result.value!.missingInDb).toHaveLength(0)
  })

  it('does not flag price when slot and price both match', () => {
    const r = setupRecon({
      rawRows: [mkNayax({ itemNumber: 10, priceGross: 2.5, utcDt: '2026-03-10T08:00:00.000Z' })],
      mapping: { N1: 'vm1' },
      dbSales: [mkSale({ item_number: 10, item_price: 2.5001, created_at: '2026-03-10T08:00:02.000Z' })],
    })
    r.runMatch()
    expect(r.result.value!.matched[0]!.priceDiffers).toBe(false)
  })

  it('reports an adjacent order swap as one missing + one ghost', () => {
    const r = setupRecon({
      rawRows: [
        mkNayax({ txId: 'A', itemNumber: 10, utcDt: '2026-03-10T08:00:00.000Z' }),
        mkNayax({ txId: 'B', itemNumber: 20, utcDt: '2026-03-10T08:01:00.000Z' }),
      ],
      mapping: { N1: 'vm1' },
      dbSales: [
        mkSale({ id: 's-20', item_number: 20, created_at: '2026-03-10T08:00:30.000Z' }),
        mkSale({ id: 's-10', item_number: 10, created_at: '2026-03-10T08:01:30.000Z' }),
      ],
    })
    r.runMatch()
    expect(r.result.value!.matched).toHaveLength(1)
    expect(r.result.value!.missingInDb).toHaveLength(1)
    expect(r.result.value!.ghostInDb).toHaveLength(1)
  })

  it('aligns each machine independently (no cross-machine matching)', () => {
    const r = setupRecon({
      rawRows: [
        mkNayax({ txId: 'A', nayaxMachineId: 'N1', itemNumber: 10, utcDt: '2026-03-10T08:00:00.000Z' }),
        mkNayax({ txId: 'B', nayaxMachineId: 'N2', itemNumber: 10, utcDt: '2026-03-10T08:00:00.000Z' }),
      ],
      mapping: { N1: 'vm1', N2: 'vm2' },
      dbSales: [mkSale({ machine_id: 'vm1', item_number: 10, created_at: '2026-03-10T08:00:02.000Z' })],
    })
    r.runMatch()
    expect(r.result.value!.matched.map(m => m.nayax.txId)).toEqual(['A'])
    expect(r.result.value!.missingInDb.map(n => n.txId)).toEqual(['B'])
    expect(r.result.value!.ghostInDb).toHaveLength(0)
  })

  it('keeps a matched pair when the DB row is just outside the strict range (buffer)', () => {
    const r = setupRecon({
      rawRows: [mkNayax({ itemNumber: 10, utcDt: '2026-03-31T23:59:00.000Z' })],
      mapping: { N1: 'vm1' },
      // DB twin recorded one minute past the file's `toUtc` (still loaded via the
      // ±2-min query buffer). Must match, not become a ghost.
      dbSales: [mkSale({ item_number: 10, created_at: '2026-04-01T00:00:30.000Z' })],
      fromUtc: '2026-03-01T00:00:00.000Z',
      toUtc: '2026-03-31T23:59:59.000Z',
    })
    r.runMatch()
    expect(r.result.value!.matched).toHaveLength(1)
    expect(r.result.value!.missingInDb).toHaveLength(0)
    expect(r.result.value!.ghostInDb).toHaveLength(0)
  })

  it('routes unmapped and unparseable rows to their buckets', () => {
    const r = setupRecon({
      rawRows: [
        mkNayax({ txId: 'U', nayaxMachineId: 'UNKNOWN', itemNumber: 10 }),
        mkNayax({ txId: 'P', itemNumber: null }),
      ],
      mapping: { N1: 'vm1' },
      dbSales: [],
    })
    r.runMatch()
    expect(r.result.value!.unmapped.map(n => n.txId)).toEqual(['U'])
    expect(r.result.value!.unparseable.map(n => n.txId)).toEqual(['P'])
    expect(r.result.value!.missingInDb).toHaveLength(0)
  })

  it('flags a DB sale on a mapped machine absent from the file as a ghost', () => {
    const r = setupRecon({
      rawRows: [],
      mapping: { N1: 'vm1' },
      dbSales: [
        mkSale({ id: 'in',  item_number: 10, created_at: '2026-03-15T12:00:00.000Z' }),
        mkSale({ id: 'out', item_number: 10, created_at: '2026-04-15T12:00:00.000Z' }),
      ],
      fromUtc: '2026-03-01T00:00:00.000Z',
      toUtc:   '2026-03-31T23:59:59.000Z',
    })
    r.runMatch()
    expect(r.result.value!.ghostInDb.map(s => s.id)).toEqual(['in'])
  })
})
```

- [ ] **Step 3: Run to verify it fails**

Run: `npx vitest run app/composables/__tests__/useNayaxReconciliation.test.ts -t "runMatch (sequence)"`
Expected: FAIL — old `runMatch` produces different buckets / `priceDiffers` undefined.

- [ ] **Step 4: Replace the `runMatch` implementation** in `useNayaxReconciliation.ts`:

```ts
  function runMatch(): void {
    matching.value = true
    try {
      const tz = settings.value.timezone
      const fromMs = Date.parse(settings.value.fromUtc)
      const toMs = Date.parse(settings.value.toUtc)

      // Pre-filter: unmapped + unparseable (unchanged), then group eligible
      // Nayax rows by mapped VM.
      const unmapped: NayaxRow[] = []
      const unparseable: NayaxRow[] = []
      const eligibleByVm = new Map<string, NayaxRow[]>()
      for (const n of rawRows.value) {
        if (!n.nayaxMachineId || !(n.nayaxMachineId in mapping.value)) { unmapped.push(n); continue }
        if (n.itemNumber == null || n.priceGross <= 0) { unparseable.push(n); continue }
        const vmId = mapping.value[n.nayaxMachineId]!
        const list = eligibleByVm.get(vmId)
        if (list) list.push(n)
        else eligibleByVm.set(vmId, [n])
      }

      // Group loaded DB sales (incl. the ±buffer rows) by machine.
      const dbByVm = new Map<string, DbSale[]>()
      for (const s of dbSales.value) {
        if (s.machine_id == null) continue
        const list = dbByVm.get(s.machine_id)
        if (list) list.push(s)
        else dbByVm.set(s.machine_id, [s])
      }

      const matched: MatchPair[] = []
      const missingInDb: NayaxRow[] = []
      const ghostInDb: DbSale[] = []
      const bucketedVmIds: string[] = []

      const vmIds = new Set<string>([...eligibleByVm.keys(), ...dbByVm.keys()])
      for (const vmId of vmIds) {
        const aRows = (eligibleByVm.get(vmId) ?? []).slice()
          .sort((x, y) => x.utcDt.localeCompare(y.utcDt))
        const bRows = (dbByVm.get(vmId) ?? []).slice()
          .sort((x, y) => x.created_at.localeCompare(y.created_at))

        const aKeys = aRows.map(r => r.itemNumber as number)   // non-null (eligible)
        const bKeys = bRows.map(r => r.item_number ?? -1)      // null slot matches nothing
        const aDays = aRows.map(r => r.utcDt.slice(0, 10))
        const bDays = bRows.map(r => r.created_at.slice(0, 10))

        const { pairs, aOnly, bOnly, bucketed } = alignMachine(aKeys, aDays, bKeys, bDays, MAX_LCS_CELLS)
        if (bucketed) bucketedVmIds.push(vmId)

        for (const [ai, bi] of pairs) {
          const nrow = aRows[ai]!
          const srow = bRows[bi]!
          const delta = (Date.parse(srow.created_at) - Date.parse(nrow.utcDt)) / 1000
          const priceDiffers = srow.item_price == null
            || roundTo2(srow.item_price) !== roundTo2(nrow.priceGross)
          matched.push({ nayax: nrow, db: srow, deltaSeconds: delta, priceDiffers })
        }
        for (const ai of aOnly) missingInDb.push(aRows[ai]!)
        for (const bi of bOnly) {
          const srow = bRows[bi]!
          const t = Date.parse(srow.created_at)
          if (t >= fromMs && t <= toMs) ghostInDb.push(srow)   // strict range only
        }
      }

      result.value = {
        matched,
        missingInDb,
        ghostInDb,
        unmapped,
        unparseable,
        bucketedVmIds,
        fileDateRange: settings.value.fromUtc && settings.value.toUtc
          ? { fromUtc: settings.value.fromUtc, toUtc: settings.value.toUtc }
          : null,
        settings: {
          timezone: tz,
          toleranceSeconds: settings.value.toleranceSeconds,
        },
      }
    } finally {
      matching.value = false
    }
  }
```

- [ ] **Step 5: Run the whole test file to verify everything passes**

Run: `npx vitest run app/composables/__tests__/useNayaxReconciliation.test.ts`
Expected: PASS — the new `runMatch (sequence)` block, the three helper blocks, and the untouched `localDtToUtc` / `parseSelectionInfo` / `parseTitleDateRange` / `parseFile` / `derivedChannelFromPaymentSource` / `exportDiffCsv` blocks all green.

> Note: `exportDiffCsv` tests still pass — under sequence matching the seeded fixtures produce the same matched/missing/ghost split the assertions check.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(nayax): sequence-based runMatch (order over timestamps)"
```

### Task 1.6: Apply the ±2-minute buffer in `loadDbSales`

**Files:** Modify `app/composables/useNayaxReconciliation.ts` (`loadDbSales`).

- [ ] **Step 1: Edit `loadDbSales`** — replace the `.gte`/`.lte` bounds with buffered ones. Locate:

```ts
    const machineIds = [...new Set(Object.values(mapping.value))]
    if (machineIds.length === 0) {
      dbSales.value = []
      return
    }
```
Immediately after it, add:
```ts
    // Widen the QUERY window by ±2 min so a sale that drifted just across the
    // file boundary still loads and can align. `settings.fromUtc/toUtc` (the
    // strict range used by runMatch's ghost filter) are left untouched.
    const { gte, lte } = bufferRange(fromUtc, toUtc, 120)
```
Then change the query's bounds from `.gte('created_at', fromUtc)` / `.lte('created_at', toUtc)` to `.gte('created_at', gte)` / `.lte('created_at', lte)`.

- [ ] **Step 2: Verify the file still type-checks via the test run**

Run: `npx vitest run app/composables/__tests__/useNayaxReconciliation.test.ts`
Expected: PASS (no behavior change to tests — `loadDbSales` isn't unit-tested; this guards against a typo).

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat(nayax): ±2min DB query buffer for boundary drift"
```

> **Chunk 1 gate:** run `npx vitest run app/composables/__tests__/useNayaxReconciliation.test.ts` — fully green. Do NOT run a full typecheck yet; the `.vue` files still reference `toleranceSeconds`, which Chunk 2 removes.

---

## Chunk 2: UI wiring + i18n + final verification

**End state:** tolerance UI gone; phantom rows highlighted; day-grouped list; price-diff badges; full `npx vitest run` green; `npx nuxi typecheck` clean; preview verified.

### Task 2.1: i18n — remove tolerance keys, add result keys

**Files:** `i18n/locales/en.json`, `i18n/locales/de.json` (the two files are line-aligned in the `nayax.reconcile` block).

- [ ] **Step 1: Remove the two tolerance keys** under `nayax.reconcile.settings` (en + de):

en.json (lines ~1239–1240) and de.json (same) — delete:
```json
        "tolerance": "Time tolerance (seconds)",
        "toleranceHint": "Default 10 s. Allows a small drift between machine and MQTT timestamps.",
```
(de equivalents likewise.) Ensure the preceding `"tzHint"`/`"tz"` line keeps a valid trailing comma and `"runCta"` remains.

- [ ] **Step 2: Add five keys** under `nayax.reconcile.results` (insert after `"matchedShort"`/`"ghostShort"` group, anywhere inside the `results` object).

en.json:
```json
        "matchMethod": "matched by product order",
        "priceDiffers": "price differs",
        "priceDiffersN": "{n} price differences",
        "bucketGhostWarn": "DB only — likely false sale",
        "ghostExplain": "These sales are in the database but not in Nayax — likely false or double-counted sales. Review and remove them.",
```

de.json (informal *du*):
```json
        "matchMethod": "Abgleich nach Produkt-Reihenfolge",
        "priceDiffers": "Preis weicht ab",
        "priceDiffersN": "{n} Preisabweichungen",
        "bucketGhostWarn": "nur in DB — vermutlich Fehlverkauf",
        "ghostExplain": "Diese Verkäufe stehen in der Datenbank, aber nicht in Nayax — vermutlich fälschlich gezählte Doppelverkäufe. Bitte prüfen und entfernen.",
```

- [ ] **Step 3: Validate JSON**

Run: `node -e "JSON.parse(require('fs').readFileSync('i18n/locales/en.json','utf8'));JSON.parse(require('fs').readFileSync('i18n/locales/de.json','utf8'));console.log('ok')"`
Expected: `ok`.

- [ ] **Step 4: Commit**

```bash
git add i18n/locales/en.json i18n/locales/de.json
git commit -m "i18n(nayax): drop tolerance strings, add sequence-result strings"
```

### Task 2.2: Results header — method label, price-diff count, bucketed notice

**Files:** Modify `app/components/nayax/NayaxResultsView.vue`.

- [ ] **Step 1: Add a computed** in `<script setup>` (after `const result = …`):

```ts
const priceDiffN = computed(() => (result.value?.matched ?? []).filter(m => m.priceDiffers).length)
const bucketedNames = computed(() =>
  (result.value?.bucketedVmIds ?? []).map(id => machineNameByVmId.value.get(id) ?? id),
)
```

- [ ] **Step 2: Replace the meta line** that reads:

```vue
          <p class="text-xs text-muted-foreground mt-1">
            {{ fmtRange() }} · {{ result.settings.timezone }} · ±{{ result.settings.toleranceSeconds }}s
          </p>
```
with:
```vue
          <p class="text-xs text-muted-foreground mt-1">
            {{ fmtRange() }} · {{ result.settings.timezone }} · {{ t('nayax.reconcile.results.matchMethod') }}
            <span v-if="priceDiffN > 0"> · {{ t('nayax.reconcile.results.priceDiffersN', { n: priceDiffN }) }}</span>
          </p>
```

- [ ] **Step 3: Add a bucketed-fallback notice** just inside the header card, after the closing `</div>` of the flex row (before the card's closing `</div>`):

```vue
      <p
        v-if="bucketedNames.length > 0"
        class="mt-2 rounded-md bg-amber-50 px-3 py-1.5 text-xs text-amber-900 dark:bg-amber-950 dark:text-amber-200"
      >
        {{ t('nayax.reconcile.results.bucketedNotice', { machines: bucketedNames.join(', ') }) }}
      </p>
```
Add the matching i18n key in both locales under `nayax.reconcile.results` (Task 2.1 style):
- en: `"bucketedNotice": "Large dataset on {machines} — matched day by day.",`
- de: `"bucketedNotice": "Große Datenmenge bei {machines} — Abgleich erfolgte tageweise.",`

(Re-run the Step 3 JSON validation from Task 2.1 after editing the locales.)

- [ ] **Step 4: Verify build/typecheck of this component compiles** (full typecheck runs in Task 2.7; for now ensure no obvious template error by running the dev/test suite). Defer to Task 2.7 gate.

- [ ] **Step 5: Commit**

```bash
git add app/components/nayax/NayaxResultsView.vue i18n/locales/en.json i18n/locales/de.json
git commit -m "feat(nayax): results header shows match method + price-diff/bucketed notices"
```

### Task 2.3: Matched table — price-differs badge

**Files:** Modify `app/components/nayax/NayaxMatchedTable.vue`.

- [ ] **Step 1: Add the badge** in the Product cell. Replace:

```vue
            <td class="px-4 py-2">{{ m.db.product_name ?? m.nayax.productName }}</td>
```
with:
```vue
            <td class="px-4 py-2">
              {{ m.db.product_name ?? m.nayax.productName }}
              <span
                v-if="m.priceDiffers"
                class="ml-2 inline-flex items-center rounded-full bg-amber-100 px-2 py-0.5 text-[10px] font-medium text-amber-800 dark:bg-amber-950 dark:text-amber-200"
              >
                {{ t('nayax.reconcile.results.priceDiffers') }}
              </span>
            </td>
```

- [ ] **Step 2: Commit**

```bash
git add app/components/nayax/NayaxMatchedTable.vue
git commit -m "feat(nayax): flag price differences on matched rows"
```

### Task 2.4: Differences table — phantom highlight + day grouping

**Files:** Modify `app/components/nayax/NayaxDifferencesTable.vue`.

- [ ] **Step 1: Update imports.** Change the utils import to add `formatDate`:
```ts
import { formatCurrency, formatDate, formatDateTime } from '@/lib/utils'
```
Change the icon import to drop `IconInfoCircle` (now unused) — keep the rest:
```ts
import { IconAlertTriangle, IconChevronDown, IconChevronRight, IconTrash } from '@tabler/icons-vue'
```
Add `groupDifferencesByDay` to the composable type import:
```ts
import type { NayaxRow, DbSale } from '~/composables/useNayaxReconciliation'
import { groupDifferencesByDay } from '~/composables/useNayaxReconciliation'
```

- [ ] **Step 2: Replace the local merge logic with the grouped computed.** Delete the `type Row = …` block and the `const mergedRows = computed<Row[]>(…)` block. Add:
```ts
const dayGroups = computed(() => groupDifferencesByDay(props.missing, props.ghosts))
```
(Keep `total`, `allMissingSelected`, selection helpers, `runImport`, delete logic, `ghostMachineName`, `shortId` exactly as-is — selection is by `txId` and unaffected by grouping.)

- [ ] **Step 3: Replace the `<tbody>` content** (the single `<template v-for="row in mergedRows" …>` block) with a day-grouped version. The data-row markup is unchanged — only the wrapping `v-for` and the new divider row are added. Keep everything under ONE `<tbody>` so `last:border-0` still resolves to the final data row.

```vue
          <tbody>
            <template v-for="group in dayGroups" :key="group.dayKey">
              <!-- Day divider: light spacing + muted date label, spans all 10 columns -->
              <tr class="bg-muted/20">
                <td :colspan="10" class="border-t px-4 pt-3 pb-1 text-xs font-medium text-muted-foreground">
                  {{ formatDate(group.rows[0]!.ts, locale) }}
                </td>
              </tr>
              <template
                v-for="row in group.rows"
                :key="row.kind + ':' + (row.kind === 'missing' ? row.payload.txId : row.payload.id)"
              >
                <!-- Missing row -->
                <tr v-if="row.kind === 'missing'" class="border-b last:border-0">
                  <td class="px-4 py-2">
                    <input
                      type="checkbox"
                      :checked="selected.has(row.payload.txId)"
                      :disabled="!isAdmin"
                      :aria-label="t('nayax.reconcile.results.selectRowAria', {
                        product: row.payload.productName,
                        slot: row.payload.itemNumber,
                      })"
                      @change="toggleOne(row.payload.txId)"
                    />
                  </td>
                  <td class="px-4 py-2">{{ formatDateTime(row.payload.utcDt, locale) }}</td>
                  <td class="px-4 py-2">
                    <span class="inline-flex items-center rounded-full bg-red-100 px-2 py-0.5 text-xs font-medium text-red-800 dark:bg-red-950 dark:text-red-200">
                      <IconAlertTriangle class="mr-1 h-3 w-3" />
                      {{ t('nayax.reconcile.results.bucketMissing') }}
                    </span>
                  </td>
                  <td class="px-4 py-2">{{ row.payload.machineName }}</td>
                  <td class="px-4 py-2 tabular-nums">{{ row.payload.itemNumber }}</td>
                  <td class="px-4 py-2">{{ row.payload.productName }}</td>
                  <td class="px-4 py-2 tabular-nums">{{ formatCurrency(row.payload.priceGross, locale) }}</td>
                  <td class="px-4 py-2">{{ row.payload.paymentSource }}</td>
                  <td class="px-4 py-2 font-mono text-xs">{{ row.payload.txId }}</td>
                  <td class="px-4 py-2"></td>
                </tr>
                <!-- Ghost (phantom) row — highlighted as a likely false sale -->
                <tr v-else class="border-b last:border-0 bg-amber-50/60 dark:bg-amber-950/30">
                  <td class="px-4 py-2"><span class="text-muted-foreground">—</span></td>
                  <td class="px-4 py-2">{{ formatDateTime(row.payload.created_at, locale) }}</td>
                  <td class="px-4 py-2">
                    <span class="inline-flex items-center rounded-full bg-amber-200 px-2 py-0.5 text-xs font-medium text-amber-900 dark:bg-amber-900 dark:text-amber-100">
                      <IconAlertTriangle class="mr-1 h-3 w-3" />
                      {{ t('nayax.reconcile.results.bucketGhostWarn') }}
                    </span>
                  </td>
                  <td class="px-4 py-2">{{ ghostMachineName(row.payload) }}</td>
                  <td class="px-4 py-2 tabular-nums">{{ row.payload.item_number ?? '—' }}</td>
                  <td class="px-4 py-2">{{ row.payload.product_name ?? '—' }}</td>
                  <td class="px-4 py-2 tabular-nums">{{ formatCurrency(row.payload.item_price ?? null, locale) }}</td>
                  <td class="px-4 py-2">{{ row.payload.channel ?? '—' }}</td>
                  <td class="px-4 py-2 font-mono text-xs">{{ shortId(row.payload.id) }}</td>
                  <td class="px-4 py-2 text-right">
                    <button
                      v-if="isAdmin"
                      class="inline-flex h-8 items-center gap-1 rounded-md border border-red-200 px-2 text-xs text-red-700 hover:bg-red-50 dark:border-red-900 dark:text-red-300 dark:hover:bg-red-950"
                      @click="pendingDelete = row.payload"
                    >
                      <IconTrash class="h-3 w-3" />
                      {{ t('common.delete') }}
                    </button>
                  </td>
                </tr>
              </template>
            </template>
          </tbody>
```

- [ ] **Step 4: Add the phantom explanation line.** Inside `<div v-if="open" class="border-t">`, immediately before the `<!-- Empty state -->`/table area (and only when there are ghosts), add:
```vue
      <p
        v-if="ghosts.length > 0"
        class="flex items-start gap-2 border-b bg-amber-50/60 px-4 py-2 text-xs text-amber-900 dark:bg-amber-950/40 dark:text-amber-200"
      >
        <IconAlertTriangle class="mt-0.5 h-3.5 w-3.5 shrink-0" />
        <span>{{ t('nayax.reconcile.results.ghostExplain') }}</span>
      </p>
```

- [ ] **Step 5: Commit**

```bash
git add app/components/nayax/NayaxDifferencesTable.vue
git commit -m "feat(nayax): highlight phantom rows + group differences by day"
```

### Task 2.5: Remove the tolerance field from the settings UI

**Files:** Modify `app/components/nayax/NayaxSettingsStep.vue`.

- [ ] **Step 1: Delete the `tolerance` computed** (the `const tolerance = computed({ … })` block).

- [ ] **Step 2: Delete the tolerance form field** — the whole `<div class="space-y-1">` containing the `tolerance` number input and its `toleranceHint` paragraph.

- [ ] **Step 3: Drop the clamp line** in `submit()`:
```ts
  recon.settings.value.toleranceSeconds = Math.max(5, Math.min(600, Math.round(recon.settings.value.toleranceSeconds)))
```
(Leave the `fromUtc`/`toUtc` assignments and `emit('run')`.)

- [ ] **Step 4: Commit**

```bash
git add app/components/nayax/NayaxSettingsStep.vue
git commit -m "feat(nayax): remove obsolete time-tolerance setting field"
```

### Task 2.6: Remove tolerance from the page + composable types

**Files:** Modify `app/pages/reports/nayax-reconciliation.vue` and `app/composables/useNayaxReconciliation.ts` and the test helper in `…/__tests__/useNayaxReconciliation.test.ts`.

- [ ] **Step 1: Page — drop tolerance localStorage + clamp.** In `onMounted`, delete:
```ts
  const tol = localStorage.getItem('nayax-reconcile-tolerance')
  if (tol) recon.settings.value.toleranceSeconds = Math.max(5, Math.min(600, Number(tol)))
```
In `onSettingsRun`, delete:
```ts
  localStorage.setItem('nayax-reconcile-tolerance', String(recon.settings.value.toleranceSeconds))
```

- [ ] **Step 2: Composable — remove `toleranceSeconds`** from the `settings` `useState` initializer:
```ts
  const settings = useState('nayax-recon-settings', () => ({
    timezone: 'Europe/Berlin',
    fromUtc: '',
    toUtc: '',
  }))
```
Remove it from the `ReconResult.settings` type:
```ts
  settings: {
    timezone: string
  }
```
And from the `result.value = { … settings: { timezone: tz } }` build in `runMatch` (drop the `toleranceSeconds` line).

- [ ] **Step 3: Test helper — update `setupRecon`.** Remove the `toleranceSeconds?` param and the `toleranceSeconds: seed.toleranceSeconds ?? 10` line from the `settings` object it builds. (No remaining test passes `toleranceSeconds` — the `runMatch (sequence)` block was written without it in Chunk 1.)

- [ ] **Step 4: Run the full unit suite**

Run: `npx vitest run`
Expected: PASS (all files).

- [ ] **Step 5: Commit**

```bash
git add app/pages/reports/nayax-reconciliation.vue app/composables/useNayaxReconciliation.ts app/composables/__tests__/useNayaxReconciliation.test.ts
git commit -m "refactor(nayax): drop toleranceSeconds from settings + result"
```

### Task 2.7: Final verification

- [ ] **Step 1: Full unit tests**

Run: `npx vitest run`
Expected: all green.

- [ ] **Step 2: Type-check**

Run: `npx nuxi typecheck`
Expected: no errors. (If `nuxi typecheck` is unavailable in this repo, run `npx vue-tsc --noEmit`.) Fix any `toleranceSeconds`/import fallout before proceeding.

- [ ] **Step 3: Preview verification** (per the harness preview workflow — do NOT ask the user to check manually):
  1. `preview_start` the frontend dev server; log in (see memory: dev credentials).
  2. Navigate to `/reports/nayax-reconciliation`, upload `app/test-helpers/fixtures/nayax-sample.xlsx`.
  3. Confirm: the Settings step has **no** tolerance field; the results header reads "…· matched by product order"; the differences list shows **day dividers** with light spacing; phantom rows render with **amber warning** styling + the explanation line; a price-diff badge appears where applicable.
  4. `preview_screenshot` the results view and share it as proof.
  5. Toggle locale to German and confirm the new strings render (no raw `nayax.reconcile.*` keys).

- [ ] **Step 4: Final commit (if any preview fixes were needed)**

```bash
git add -A && git commit -m "fix(nayax): preview-verified polish for sequence reconciliation"
```

---

## Done criteria

- `npx vitest run` green (incl. the four new helper blocks and the rewritten `runMatch (sequence)` block).
- `npx nuxi typecheck` clean; no `toleranceSeconds` references remain (`git grep toleranceSeconds management-frontend` returns nothing).
- Preview shows: no tolerance field, day-grouped differences with light spacing, highlighted phantom rows + explanation, "matched by product order" header, price-diff badges, German strings present.
- Behavior unchanged for: bulk import of missing rows, per-row ghost delete, CSV export, mapping step, parser, activity logging.
