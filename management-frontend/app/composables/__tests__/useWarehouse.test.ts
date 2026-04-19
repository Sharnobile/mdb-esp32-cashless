import { describe, it, expect, vi, beforeEach } from 'vitest'
import { ref as vueRef } from 'vue'

;(globalThis as any).ref = vueRef
// useWarehouse uses `useState(...)` as a bare Nuxt auto-import — expose it globally for tests
;(globalThis as any).useState = <T,>(_k: string, init?: () => T) => vueRef(init ? init() : undefined)

// Captures of write calls so the test can assert on them
const captured = {
  batchUpdates: [] as { id: string; quantity: number }[],
  transactionInserts: [] as any[],
}

// Fixture for the "fetch current batch" read
const batchFixture = {
  data: null as { quantity: number; batch_number: string | null; expiration_date: string | null } | null,
  error: null as any,
}

// Fixture for the authenticated session
const sessionFixture = {
  data: { session: { user: { id: 'user-1', email: 'tester@example.com' } } },
  error: null as any,
}

function makeBatchBuilder() {
  const b: any = {}
  b.select = vi.fn(() => b)
  b.eq = vi.fn(() => b)
  b.single = vi.fn(() => Promise.resolve(batchFixture))
  // update(...).eq(id) — capture and return { error: null }
  b.update = vi.fn((row: any) => {
    const child: any = {}
    child.eq = vi.fn((_col: string, id: string) => {
      captured.batchUpdates.push({ id, quantity: row.quantity })
      return Promise.resolve({ error: null })
    })
    return child
  })
  return b
}

function makeTransactionBuilder() {
  const b: any = {}
  b.insert = vi.fn((row: any) => {
    captured.transactionInserts.push(row)
    return Promise.resolve({ error: null })
  })
  return b
}

const mockSupabase = {
  from: vi.fn((table: string) => {
    if (table === 'warehouse_stock_batches') return makeBatchBuilder()
    if (table === 'warehouse_transactions') return makeTransactionBuilder()
    // Unused paths in this test
    const passthrough: any = {}
    for (const m of ['select', 'eq', 'gt', 'order']) passthrough[m] = vi.fn(() => passthrough)
    passthrough.then = (resolve: any) => resolve({ data: [], error: null })
    return passthrough
  }),
  auth: {
    getSession: vi.fn(() => Promise.resolve(sessionFixture)),
  },
}

vi.mock('#imports', () => {
  const { ref } = require('vue')
  return {
    ref,
    // useState is used at composable setup for `velocityDays` — must be stubbed
    useState: <T,>(_k: string, init?: () => T) => ref(init?.()),
    useSupabaseClient: () => mockSupabase,
  }
})

vi.mock('../useOrganization', () => ({
  useOrganization: () => ({ organization: { value: { id: 'company-1' } } }),
}))

import { useWarehouse } from '../useWarehouse'

beforeEach(() => {
  vi.clearAllMocks()
  captured.batchUpdates = []
  captured.transactionInserts = []
  batchFixture.data = null
  batchFixture.error = null
})

describe('useWarehouse.adjustStock', () => {
  it('adds quantity for a positive refill-return adjustment', async () => {
    batchFixture.data = { quantity: 10, batch_number: 'LOT-1', expiration_date: '2026-12-31' }

    const { adjustStock } = useWarehouse()
    await adjustStock({
      batch_id: 'batch-1',
      warehouse_id: 'wh-1',
      product_id: 'p-1',
      quantity_change: 3,
      reason: 'adjustment_refill_return',
      notes: 'Brought 3 back from refill',
    })

    expect(captured.batchUpdates).toEqual([{ id: 'batch-1', quantity: 13 }])
    expect(captured.transactionInserts).toHaveLength(1)
    const tx = captured.transactionInserts[0]
    expect(tx.transaction_type).toBe('adjustment_refill_return')
    expect(tx.quantity_change).toBe(3)
    expect(tx.quantity_before).toBe(10)
    expect(tx.quantity_after).toBe(13)
    expect(tx.batch_id).toBe('batch-1')
    expect(tx.company_id).toBe('company-1')
    expect(tx.notes).toBe('Brought 3 back from refill')
  })

  it('subtracts quantity for a negative damage adjustment and clamps at zero', async () => {
    batchFixture.data = { quantity: 2, batch_number: null, expiration_date: null }

    const { adjustStock } = useWarehouse()
    await adjustStock({
      batch_id: 'batch-2',
      warehouse_id: 'wh-1',
      product_id: 'p-1',
      quantity_change: -5, // would be -3, clamped to 0
      reason: 'adjustment_damage',
    })

    expect(captured.batchUpdates).toEqual([{ id: 'batch-2', quantity: 0 }])
    const tx = captured.transactionInserts[0]
    expect(tx.transaction_type).toBe('adjustment_damage')
    expect(tx.quantity_change).toBe(-5)
    expect(tx.quantity_before).toBe(2)
    expect(tx.quantity_after).toBe(0)
  })
})
