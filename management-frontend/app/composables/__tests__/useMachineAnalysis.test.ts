import { describe, it, expect, vi } from 'vitest'

// useMachineAnalysis imports getProductImageUrl at module load (called only at
// runtime), so stub it to keep the import graph clean in the test environment.
vi.mock('../useProducts', () => ({ getProductImageUrl: (p: string) => `https://example.test/${p}` }))

import { slotRowCol, computeSlotWidths, scoreProduct, buildSuggestionPool, buildGridSlots } from '../useMachineAnalysis'

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

describe('scoreProduct', () => {
  const opts = { days: 30 }

  it('flags long-offered zero-sale products as dead', () => {
    expect(scoreProduct({ units_sold: 0, sell_through_pct: 0, tenure_days: 30 }, opts)).toBe('dead')
  })

  it('keeps recently-added products in a testing grace period (survives slot moves via tenure)', () => {
    expect(scoreProduct({ units_sold: 0, sell_through_pct: 0, tenure_days: 5 }, opts)).toBe('testing')
    expect(scoreProduct({ units_sold: 1, sell_through_pct: 8, tenure_days: 3 }, opts)).toBe('testing')
  })

  it('classifies established products by sell-through', () => {
    expect(scoreProduct({ units_sold: 2, sell_through_pct: 8, tenure_days: 30 }, opts)).toBe('weak')
    expect(scoreProduct({ units_sold: 5, sell_through_pct: 25, tenure_days: 30 }, opts)).toBe('ok')
    expect(scoreProduct({ units_sold: 20, sell_through_pct: 60, tenure_days: 30 }, opts)).toBe('strong')
  })

  it('does not grant grace once the product is established (good sell-through)', () => {
    expect(scoreProduct({ units_sold: 30, sell_through_pct: 70, tenure_days: 2 }, opts)).toBe('strong')
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
})

describe('buildGridSlots — colours each slot by its product tier', () => {
  const trays = [
    { id: 't10', item_number: 10, product_id: 'p1', product_name: 'Cola', image_url: null },
    { id: 't11', item_number: 11, product_id: 'p1', product_name: 'Cola', image_url: null }, // same product, 2nd slot
    { id: 't12', item_number: 12, product_id: 'p2', product_name: 'Water', image_url: null },
    { id: 't13', item_number: 13, product_id: null, product_name: null, image_url: null },   // empty
  ]
  const tierByProduct = new Map<string, { tier: any; sell_through_pct: number }>([
    ['p1', { tier: 'dead', sell_through_pct: 0 }],
    ['p2', { tier: 'strong', sell_through_pct: 70 }],
  ])

  it('applies the same product tier to every slot holding that product', () => {
    const slots = buildGridSlots(trays, tierByProduct)
    const byTray = Object.fromEntries(slots.map(s => [s.trayId, s.tier]))
    expect(byTray.t10).toBe('dead')
    expect(byTray.t11).toBe('dead') // a product in two slots colours both
    expect(byTray.t12).toBe('strong')
  })

  it('marks unassigned slots as empty', () => {
    const slots = buildGridSlots(trays, tierByProduct)
    expect(slots.find(s => s.trayId === 't13')!.tier).toBe('empty')
  })

  it('computes row/column/width from item_number', () => {
    const slots = buildGridSlots(trays, tierByProduct)
    const s10 = slots.find(s => s.trayId === 't10')!
    expect(s10).toMatchObject({ row: 0, column: 0 })
  })
})
