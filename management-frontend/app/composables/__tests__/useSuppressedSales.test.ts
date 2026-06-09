import { describe, it, expect, vi, beforeEach } from 'vitest'
import { ref as vueRef } from 'vue'

// The composable uses bare ref(...) via Nuxt auto-import.
;(globalThis as any).ref = vueRef

const rpc = vi.fn()

vi.mock('#imports', () => {
  const { ref } = require('vue')
  return {
    ref,
    useSupabaseClient: () => ({ rpc }),
  }
})

import { useSuppressedSales, suppressedReasonParts, buildSalesFeedDays } from '../useSuppressedSales'

beforeEach(() => {
  vi.clearAllMocks()
})

describe('useSuppressedSales.restore', () => {
  it('calls the RPC with { p_suppressed_id } and removes the row on success', async () => {
    rpc.mockResolvedValueOnce({ data: { id: 's1' }, error: null })
    const s = useSuppressedSales()
    // seed two rows
    s.rows.value = [
      { id: 's1' } as any,
      { id: 's2' } as any,
    ]
    await s.restore('s1')
    expect(rpc).toHaveBeenCalledWith('restore_suppressed_sale', { p_suppressed_id: 's1' })
    expect(s.rows.value.map(r => r.id)).toEqual(['s2'])
  })

  it('throws and leaves rows untouched on RPC error', async () => {
    rpc.mockResolvedValueOnce({ data: null, error: { message: 'nope' } })
    const s = useSuppressedSales()
    s.rows.value = [{ id: 's1' } as any]
    await expect(s.restore('s1')).rejects.toBeTruthy()
    expect(s.rows.value.map(r => r.id)).toEqual(['s1'])
  })
})

describe('suppressedReasonParts', () => {
  it('clock not synced when device_created_at present', () => {
    const r = suppressedReasonParts({ device_created_at: '2026-06-05T10:00:00Z', received_at: '2026-06-05T10:00:03Z', matched: { created_at: '2026-06-05T10:00:00Z' } } as any)
    expect(r.clock).toBe('unsynced')
    expect(r.gapSeconds).toBe(3)
  })
  it('no clock when device_created_at is null', () => {
    const r = suppressedReasonParts({ device_created_at: null, received_at: '2026-06-05T10:00:05Z', matched: { created_at: '2026-06-05T10:00:00Z' } } as any)
    expect(r.clock).toBe('noclock')
    expect(r.gapSeconds).toBe(5)
  })
  it('gapSeconds null when matched missing', () => {
    const r = suppressedReasonParts({ device_created_at: '2026-06-05T10:00:00Z', received_at: '2026-06-05T10:00:03Z', matched: null } as any)
    expect(r.gapSeconds).toBeNull()
  })
})

describe('buildSalesFeedDays', () => {
  const dayKey = (ts: number) => new Date(ts).toISOString().slice(0, 10)
  const now = Date.parse('2026-06-05T12:00:00Z')
  const windowMs = 30 * 24 * 60 * 60 * 1000

  it('interleaves real + suppressed by time desc; saleCount counts real only', () => {
    const sales = [
      { id: 'a', created_at: '2026-06-05T10:00:00Z' },
      { id: 'b', created_at: '2026-06-05T10:00:05Z' },
    ]
    const suppressed = [{ id: 's1', received_at: '2026-06-05T10:00:03Z' }]
    const groups = buildSalesFeedDays(sales as any, suppressed as any, { nowMs: now, windowMs, dayKey })
    expect(groups).toHaveLength(1)
    expect(groups[0].items.map(i => i.key)).toEqual(['sale-b', 'sup-s1', 'sale-a'])
    expect(groups[0].saleCount).toBe(2)
  })

  it('drops suppressed older than the window', () => {
    const sales = [{ id: 'a', created_at: '2026-06-05T10:00:00Z' }]
    const old = new Date(now - windowMs - 1000).toISOString()
    const suppressed = [{ id: 'sOld', received_at: old }]
    const groups = buildSalesFeedDays(sales as any, suppressed as any, { nowMs: now, windowMs, dayKey })
    const keys = groups.flatMap(g => g.items.map(i => i.key))
    expect(keys).not.toContain('sup-sOld')
    expect(keys).toContain('sale-a')
  })

  it('groups by day, days sorted desc', () => {
    const sales = [
      { id: 'a', created_at: '2026-06-05T10:00:00Z' },
      { id: 'b', created_at: '2026-06-04T10:00:00Z' },
    ]
    const groups = buildSalesFeedDays(sales as any, [] as any, { nowMs: now, windowMs, dayKey })
    expect(groups.map(g => g.key)).toEqual(['2026-06-05', '2026-06-04'])
  })
})
