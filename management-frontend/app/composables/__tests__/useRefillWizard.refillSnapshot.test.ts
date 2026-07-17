import { describe, it, expect } from 'vitest'
import { buildRefillSnapshot } from '../useRefillWizard'

describe('buildRefillSnapshot', () => {
  const traysToRefill = [
    { id: 'tray-1', item_number: 3, product_id: 'p-1', product_name: 'Coca-Cola', fill_amount: 5 },
    { id: 'tray-2', item_number: 7, product_id: 'p-2', product_name: 'Sprite', fill_amount: 2 },
  ] as any

  it('joins RPC results with tray metadata by tray_id', () => {
    const results = [
      { tray_id: 'tray-1', old_stock: 3, new_stock: 8, fill_amount: 5, was_already_applied: false },
      { tray_id: 'tray-2', old_stock: 10, new_stock: 12, fill_amount: 2, was_already_applied: false },
    ] as any

    expect(buildRefillSnapshot(results, traysToRefill)).toEqual([
      { id: 'tray-1', item_number: 3, product_name: 'Coca-Cola', product_id: 'p-1', old_stock: 3, new_stock: 8 },
      { id: 'tray-2', item_number: 7, product_name: 'Sprite', product_id: 'p-2', old_stock: 10, new_stock: 12 },
    ])
  })

  it('tolerates a result row whose tray_id has no matching input tray', () => {
    const results = [
      { tray_id: 'tray-missing', old_stock: 1, new_stock: 4, fill_amount: 3, was_already_applied: false },
    ] as any

    expect(buildRefillSnapshot(results, traysToRefill)).toEqual([
      { id: 'tray-missing', item_number: undefined, product_name: undefined, product_id: undefined, old_stock: 1, new_stock: 4 },
    ])
  })

  it('returns an empty array for no results', () => {
    expect(buildRefillSnapshot([], traysToRefill)).toEqual([])
  })
})
