import { describe, it, expect } from 'vitest'

// useProducts.getProductImageUrl is only called at runtime (not module load),
// but useMachineAnalysis imports it — stub so the import graph resolves cleanly.
import { vi } from 'vitest'
vi.mock('../useProducts', () => ({ getProductImageUrl: (p: string) => `https://example.test/${p}` }))

import { slotRowCol, computeSlotWidths, scoreSlot, buildSuggestionPool } from '../useMachineAnalysis'

describe('slotRowCol — iOS layout parity', () => {
  it('maps item_number to (row, column)', () => {
    expect(slotRowCol(10)).toEqual({ row: 0, column: 0 })
    expect(slotRowCol(15)).toEqual({ row: 0, column: 5 })
    expect(slotRowCol(23)).toEqual({ row: 1, column: 3 })
    expect(slotRowCol(30)).toEqual({ row: 2, column: 0 })
  })

  it('clamps single-digit slots to row 0', () => {
    expect(slotRowCol(5)).toEqual({ row: 0, column: 5 })
    expect(slotRowCol(0)).toEqual({ row: 0, column: 0 })
  })
})

describe('computeSlotWidths — gaps widen the preceding slot', () => {
  it('width = gap to next occupied slot, last slot stretches to row end', () => {
    const widths = computeSlotWidths([10, 12, 13, 15, 20])
    expect(widths.get(10)).toBe(2) // 12 - 10
    expect(widths.get(12)).toBe(1) // 13 - 12
    expect(widths.get(13)).toBe(2) // 15 - 13
    expect(widths.get(15)).toBe(5) // 10 columns - column 5
    expect(widths.get(20)).toBe(10) // lone slot in its row
  })

  it('never produces a width below 1', () => {
    const widths = computeSlotWidths([19])
    expect(widths.get(19)).toBeGreaterThanOrEqual(1)
  })
})

describe('scoreSlot', () => {
  const opts = { days: 30 }

  it('returns empty for unassigned slots', () => {
    expect(scoreSlot({ product_id: null, units_sold: 0, sell_through_pct: 0, days_in_slot: 30 }, opts)).toBe('empty')
  })

  it('flags long-occupied zero-sale slots as dead', () => {
    expect(scoreSlot({ product_id: 'p', units_sold: 0, sell_through_pct: 0, days_in_slot: 30 }, opts)).toBe('dead')
  })

  it('keeps recently-stocked slots in a testing grace period instead of condemning them', () => {
    expect(scoreSlot({ product_id: 'p', units_sold: 0, sell_through_pct: 0, days_in_slot: 5 }, opts)).toBe('testing')
    expect(scoreSlot({ product_id: 'p', units_sold: 1, sell_through_pct: 8, days_in_slot: 3 }, opts)).toBe('testing')
  })

  it('classifies established slots by sell-through', () => {
    expect(scoreSlot({ product_id: 'p', units_sold: 2, sell_through_pct: 8, days_in_slot: 30 }, opts)).toBe('weak')
    expect(scoreSlot({ product_id: 'p', units_sold: 5, sell_through_pct: 25, days_in_slot: 30 }, opts)).toBe('ok')
    expect(scoreSlot({ product_id: 'p', units_sold: 20, sell_through_pct: 60, days_in_slot: 30 }, opts)).toBe('strong')
  })
})

describe('buildSuggestionPool', () => {
  const products = [
    { id: 'a', name: 'Cola', image_url: null, discontinued: false },
    { id: 'b', name: 'Water', image_url: null, discontinued: false },
    { id: 'c', name: 'Apple', image_url: null, discontinued: false },   // never sold
    { id: 'd', name: 'Banana', image_url: null, discontinued: false },  // never sold
    { id: 'e', name: 'OldBar', image_url: null, discontinued: true },   // discontinued
    { id: 'f', name: 'InMachine', image_url: null, discontinued: false },
  ]
  const velocity = new Map<string, number>([['a', 4.2], ['b', 1.1], ['f', 9.9]])
  const productsInMachine = new Set<string>(['f'])

  it('ranks bestsellers by fleet velocity and excludes machine + discontinued', () => {
    const { bestsellers } = buildSuggestionPool({ products, velocity, productsInMachine })
    expect(bestsellers.map(s => s.product_id)).toEqual(['a', 'b'])
    expect(bestsellers[0]).toMatchObject({ kind: 'bestseller', velocity: 4.2 })
  })

  it('surfaces never-sold products as test candidates (newcomers)', () => {
    const { newcomers } = buildSuggestionPool({ products, velocity, productsInMachine })
    expect(newcomers.map(s => s.product_id).sort()).toEqual(['c', 'd'])
    expect(newcomers.every(s => s.kind === 'newcomer' && s.velocity === 0)).toBe(true)
  })

  it('respects the max limits', () => {
    const { bestsellers, newcomers } = buildSuggestionPool({ products, velocity, productsInMachine, maxBestsellers: 1, maxNewcomers: 1 })
    expect(bestsellers).toHaveLength(1)
    expect(newcomers).toHaveLength(1)
  })
})
