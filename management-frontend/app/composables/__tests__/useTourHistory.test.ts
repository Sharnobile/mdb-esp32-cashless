import { describe, it, expect } from 'vitest'
import { buildMachineEntry } from '../useTourHistory'

describe('buildMachineEntry', () => {
  it('derives trays_refilled count and products from the new trays_detail array shape', () => {
    const entry = buildMachineEntry({
      id: 'e1', created_at: '2026-07-17T00:00:00Z', user_id: null,
      action: 'stock_refill_tour',
      metadata: {
        machine_id: 'm1', machine_name: 'Automat 1', total_added: 7,
        trays_refilled: 2,
        trays_detail: [
          { id: 't1', item_number: 3, product_id: 'p1', product_name: 'Coca-Cola', old_stock: 2, new_stock: 7 },
          { id: 't2', item_number: 5, product_id: 'p2', product_name: 'Sprite', old_stock: 0, new_stock: 2 },
        ],
      },
    })
    expect(entry.trays_refilled).toBe(2)
    expect(entry.products).toEqual([
      { product_id: 'p1', product_name: 'Coca-Cola', quantity: 5 },
      { product_id: 'p2', product_name: 'Sprite', quantity: 2 },
    ])
  })

  it('falls back to the legacy flat products array for historical rows', () => {
    const entry = buildMachineEntry({
      id: 'e1', created_at: '2026-07-01T00:00:00Z', user_id: null,
      action: 'stock_refill_tour',
      metadata: {
        machine_id: 'm1', machine_name: 'Automat 1', total_added: 5,
        trays_refilled: 2, // legacy plain-number shape
        products: [{ product_id: 'p1', product_name: 'Coca-Cola', quantity: 5 }],
      },
    })
    expect(entry.trays_refilled).toBe(2)
    expect(entry.products).toEqual([{ product_id: 'p1', product_name: 'Coca-Cola', quantity: 5 }])
  })

  it('returns zero/empty for a skipped machine', () => {
    const entry = buildMachineEntry({
      id: 'e1', created_at: '2026-07-17T00:00:00Z', user_id: null,
      action: 'stock_refill_tour_skip',
      metadata: { machine_id: 'm1', machine_name: 'Automat 1' },
    })
    expect(entry.trays_refilled).toBe(0)
    expect(entry.products).toEqual([])
  })
})
