import { describe, it, expect } from 'vitest'
import { buildSupplierOrderGroups, suggestedOrderQuantity, recalculateLine, type OrderCandidateProduct, type SupplierContact } from '../supplierOrderList'
import type { PurchaseSummary } from '../purchaseComparison'

function summary(overrides: Partial<PurchaseSummary> = {}): PurchaseSummary {
  return {
    product_id: 'p1',
    ek_count: 1,
    newest_net: null,
    newest_gross: null,
    newest_supplier: null,
    newest_on: null,
    min_gross: null,
    min_supplier: null,
    min_on: null,
    max_gross: null,
    effective_tax_rate: null,
    ...overrides,
  }
}

describe('suggestedOrderQuantity', () => {
  it('suggests the deficit to reach min stock', () => {
    expect(suggestedOrderQuantity({ product_id: 'p1', product_name: 'A', total_quantity: 2, min_stock: 10 })).toBe(8)
  })

  it('suggests at least 1 even when already at or above min stock', () => {
    expect(suggestedOrderQuantity({ product_id: 'p1', product_name: 'A', total_quantity: 10, min_stock: 10 })).toBe(1)
    expect(suggestedOrderQuantity({ product_id: 'p1', product_name: 'A', total_quantity: 0, min_stock: 0 })).toBe(1)
  })
})

describe('buildSupplierOrderGroups', () => {
  const suppliers: SupplierContact[] = [
    { id: 's1', name: 'Acme GmbH', email: 'acme@example.com', phone: null, address: null, customer_number: 'C-1' },
    { id: 's2', name: 'Beta Foods', email: null, phone: '+49 123', address: null, customer_number: null },
  ]

  it('groups products by their cheapest known supplier (case-insensitive match)', () => {
    const products: OrderCandidateProduct[] = [
      { product_id: 'p1', product_name: 'Cola', total_quantity: 1, min_stock: 5 },
      { product_id: 'p2', product_name: 'Chips', total_quantity: 0, min_stock: 3 },
    ]
    const summaries: Record<string, PurchaseSummary> = {
      p1: summary({ product_id: 'p1', min_gross: 0.5, min_supplier: 'acme gmbh', effective_tax_rate: 0.19 }),
      p2: summary({ product_id: 'p2', min_gross: 1.2, min_supplier: 'Beta Foods', effective_tax_rate: 0.19 }),
    }

    const groups = buildSupplierOrderGroups(products, summaries, suppliers)

    expect(groups).toHaveLength(2)
    expect(groups.map(g => g.supplier_name)).toEqual(['Acme GmbH', 'Beta Foods'])
    const acme = groups.find(g => g.supplier_id === 's1')!
    expect(acme.lines).toHaveLength(1)
    expect(acme.lines[0]!.suggested_quantity).toBe(4)
    expect(acme.lines[0]!.line_total_gross).toBeCloseTo(2.0)
    expect(acme.subtotal_gross).toBeCloseTo(2.0)
  })

  it('falls back to the newest price when no historical minimum is recorded', () => {
    const products: OrderCandidateProduct[] = [
      { product_id: 'p1', product_name: 'Cola', total_quantity: 1, min_stock: 5 },
    ]
    const summaries: Record<string, PurchaseSummary> = {
      p1: summary({ product_id: 'p1', newest_gross: 0.8, newest_net: 0.67, newest_supplier: 'Acme GmbH' }),
    }

    const groups = buildSupplierOrderGroups(products, summaries, suppliers)

    expect(groups).toHaveLength(1)
    expect(groups[0]!.lines[0]!.unit_price_gross).toBe(0.8)
    expect(groups[0]!.lines[0]!.unit_price_net).toBe(0.67)
  })

  it('buckets products with no purchase-price history into a single unassigned group, listed last', () => {
    const products: OrderCandidateProduct[] = [
      { product_id: 'p1', product_name: 'Cola', total_quantity: 1, min_stock: 5 },
      { product_id: 'p2', product_name: 'Water', total_quantity: 0, min_stock: 2 },
      { product_id: 'p3', product_name: 'Chips', total_quantity: 0, min_stock: 3 },
    ]
    const summaries: Record<string, PurchaseSummary> = {
      p1: summary({ product_id: 'p1', min_gross: 0.5, min_supplier: 'Acme GmbH', effective_tax_rate: 0.19 }),
      // p2, p3 have no recorded purchase price at all
    }

    const groups = buildSupplierOrderGroups(products, summaries, suppliers)

    expect(groups).toHaveLength(2)
    expect(groups[0]!.supplier_id).toBe('s1')
    const unassigned = groups[1]!
    expect(unassigned.supplier_id).toBeNull()
    expect(unassigned.lines.map(l => l.product_id).sort()).toEqual(['p2', 'p3'])
    expect(unassigned.subtotal_gross).toBeNull()
  })

  it('resolves supplier contact info even when the product supplier name has no matching row', () => {
    const products: OrderCandidateProduct[] = [
      { product_id: 'p1', product_name: 'Cola', total_quantity: 1, min_stock: 5 },
    ]
    const summaries: Record<string, PurchaseSummary> = {
      p1: summary({ product_id: 'p1', min_gross: 0.5, min_supplier: 'Unknown Supplier Ltd', effective_tax_rate: 0.19 }),
    }

    const groups = buildSupplierOrderGroups(products, summaries, suppliers)

    expect(groups).toHaveLength(1)
    expect(groups[0]!.supplier_id).toBeNull()
    expect(groups[0]!.supplier_name).toBe('Unknown Supplier Ltd')
    expect(groups[0]!.contact).toBeNull()
  })
})

describe('recalculateLine', () => {
  it('recomputes totals from a new quantity', () => {
    const line = {
      product_id: 'p1',
      product_name: 'Cola',
      current_quantity: 1,
      min_stock: 5,
      suggested_quantity: 4,
      unit_price_net: 0.5,
      unit_price_gross: 0.6,
      line_total_net: 2,
      line_total_gross: 2.4,
    }
    const updated = recalculateLine(line, 10)
    expect(updated.suggested_quantity).toBe(10)
    expect(updated.line_total_net).toBeCloseTo(5)
    expect(updated.line_total_gross).toBeCloseTo(6)
  })

  it('clamps negative quantities to zero', () => {
    const line = {
      product_id: 'p1',
      product_name: 'Cola',
      current_quantity: 1,
      min_stock: 5,
      suggested_quantity: 4,
      unit_price_net: 0.5,
      unit_price_gross: 0.6,
      line_total_net: 2,
      line_total_gross: 2.4,
    }
    const updated = recalculateLine(line, -3)
    expect(updated.suggested_quantity).toBe(0)
    expect(updated.line_total_net).toBe(0)
  })
})
