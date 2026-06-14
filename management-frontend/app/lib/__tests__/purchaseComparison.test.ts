import { describe, it, expect } from 'vitest'
import {
  counterpart, marginNet, classifyDeal, marginDelta, isCardSuppressed,
  type PurchaseSummary,
} from '../purchaseComparison'

function summary(over: Partial<PurchaseSummary>): PurchaseSummary {
  return {
    product_id: 'p', ek_count: 1,
    newest_net: 0.50, newest_gross: 0.54, newest_supplier: 'Müller', newest_on: '2026-06-01',
    min_gross: 0.51, min_supplier: 'Metro', min_on: '2026-03-01',
    max_gross: 0.55, effective_tax_rate: 0.07, ...over,
  }
}

describe('counterpart', () => {
  it('net → gross at 7%', () => expect(counterpart(0.50, 'net', 0.07)).toBeCloseTo(0.535, 4))
  it('gross → net at 7%', () => expect(counterpart(0.535, 'gross', 0.07)).toBeCloseTo(0.50, 4))
})

describe('marginNet', () => {
  it('VK_net − EK_net on net basis', () => {
    const m = marginNet(1.20, 0.50, 0.07)!
    expect(m.rohertrag).toBeCloseTo(1.20 / 1.07 - 0.50, 4)
    expect(m.spannePct).toBeGreaterThan(40)
  })
  it('returns null when sellprice missing', () => expect(marginNet(null, 0.50, 0.07)).toBeNull())
})

describe('classifyDeal', () => {
  it('no_ek when summary empty', () =>
    expect(classifyDeal(0.45, summary({ ek_count: 0, max_gross: null, newest_gross: null })).verdict).toBe('no_ek'))
  it('implausible when above max', () =>
    expect(classifyDeal(2.99, summary({})).verdict).toBe('implausible'))
  it('good_best when at/below min', () =>
    expect(classifyDeal(0.45, summary({})).verdict).toBe('good_best'))
  it('good when below usual beyond tolerance', () =>
    expect(classifyDeal(0.52, summary({ min_gross: 0.40 })).verdict).toBe('good'))
  it('similar within ±3% of newest', () =>
    expect(classifyDeal(0.545, summary({ min_gross: 0.40 })).verdict).toBe('similar'))
  it('worse above usual but ≤ max', () =>
    expect(classifyDeal(0.549, summary({ min_gross: 0.40, newest_gross: 0.50, max_gross: 0.60 })).verdict).toBe('worse'))
  it('single-EK: equal value is good_best, just above is implausible', () => {
    const single = summary({ min_gross: 0.54, max_gross: 0.54, newest_gross: 0.54, ek_count: 1 })
    expect(classifyDeal(0.54, single).verdict).toBe('good_best')
    expect(classifyDeal(0.541, single).verdict).toBe('implausible')
  })
})

describe('isCardSuppressed', () => {
  it('all implausible → suppressed', () => expect(isCardSuppressed(['implausible', 'implausible'])).toBe(true))
  it('one no_ek keeps it visible', () => expect(isCardSuppressed(['implausible', 'no_ek'])).toBe(false))
  it('empty → not suppressed', () => expect(isCardSuppressed([])).toBe(false))
})

describe('marginDelta', () => {
  it('computes current vs deal margin on net basis', () => {
    const md = marginDelta(1.20, 0.45, summary({}))!
    // VK_net = 1.20/1.07 ≈ 1.1215; current = (1.1215-0.50)/1.1215; deal uses dealNet 0.45/1.07
    expect(md.dealPct).toBeGreaterThan(md.currentPct)
  })
  it('null when sellprice missing', () => expect(marginDelta(null, 0.45, summary({}))).toBeNull())
})
