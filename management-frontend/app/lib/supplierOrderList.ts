// Pure, framework-free logic for the supplier purchase-list feature.
// Groups low-stock / out-of-stock products by their cheapest known supplier
// (from product_purchase_prices, via PurchaseSummary) so an operator can see
// what to order and from whom, without a formal purchase-order workflow.

import type { PurchaseSummary } from './purchaseComparison'

export interface OrderCandidateProduct {
  product_id: string
  product_name: string
  total_quantity: number
  min_stock: number
}

export interface SupplierContact {
  id: string
  name: string
  email: string | null
  phone: string | null
  address: string | null
  customer_number: string | null
}

export interface OrderLine {
  product_id: string
  product_name: string
  current_quantity: number
  min_stock: number
  suggested_quantity: number
  unit_price_net: number | null
  unit_price_gross: number | null
  line_total_net: number | null
  line_total_gross: number | null
}

export interface SupplierOrderGroup {
  supplier_id: string | null // null = no purchase-price history for any line in this group
  supplier_name: string
  contact: SupplierContact | null
  lines: OrderLine[]
  subtotal_net: number | null
  subtotal_gross: number | null
}

const UNASSIGNED_KEY = '__unassigned__'

/** Units needed to reach min_stock again; at least 1 so a listed item is never quantity 0. */
export function suggestedOrderQuantity(product: OrderCandidateProduct): number {
  return Math.max(product.min_stock - product.total_quantity, 1)
}

/** Cheapest known unit price for a product, preferring the historical minimum over the most recent price. */
function resolveUnitPrice(summary: PurchaseSummary | undefined): { supplierName: string | null; net: number | null; gross: number | null } {
  if (!summary || summary.ek_count === 0) return { supplierName: null, net: null, gross: null }
  if (summary.min_gross != null && summary.min_supplier) {
    const net = summary.effective_tax_rate != null ? summary.min_gross / (1 + summary.effective_tax_rate) : null
    return { supplierName: summary.min_supplier, net, gross: summary.min_gross }
  }
  return { supplierName: summary.newest_supplier, net: summary.newest_net, gross: summary.newest_gross }
}

/**
 * Groups reorder candidates (already filtered to low/out-of-stock, non-discontinued
 * products by the caller) by their cheapest known supplier, resolving contact info
 * from the suppliers table by case-insensitive name match (mirrors add_purchase_price's
 * own supplier-resolution rule). Products with no purchase-price history land in a
 * single "unassigned" group so the operator knows to add a price/supplier first.
 */
export function buildSupplierOrderGroups(
  products: OrderCandidateProduct[],
  purchaseSummaries: Record<string, PurchaseSummary>,
  suppliers: SupplierContact[],
): SupplierOrderGroup[] {
  const contactByName = new Map(suppliers.map(s => [s.name.trim().toLowerCase(), s]))
  const groups = new Map<string, SupplierOrderGroup>()

  for (const product of products) {
    const { supplierName, net, gross } = resolveUnitPrice(purchaseSummaries[product.product_id])
    const contact = supplierName ? contactByName.get(supplierName.trim().toLowerCase()) ?? null : null
    const key = contact?.id ?? UNASSIGNED_KEY

    let group = groups.get(key)
    if (!group) {
      group = {
        supplier_id: contact?.id ?? null,
        supplier_name: contact?.name ?? supplierName ?? '',
        contact,
        lines: [],
        subtotal_net: null,
        subtotal_gross: null,
      }
      groups.set(key, group)
    }

    const suggestedQuantity = suggestedOrderQuantity(product)
    group.lines.push({
      product_id: product.product_id,
      product_name: product.product_name,
      current_quantity: product.total_quantity,
      min_stock: product.min_stock,
      suggested_quantity: suggestedQuantity,
      unit_price_net: net,
      unit_price_gross: gross,
      line_total_net: net != null ? net * suggestedQuantity : null,
      line_total_gross: gross != null ? gross * suggestedQuantity : null,
    })
  }

  for (const group of groups.values()) {
    recalculateGroupSubtotals(group)
  }

  const unassigned = groups.get(UNASSIGNED_KEY)
  groups.delete(UNASSIGNED_KEY)
  const sorted = [...groups.values()].sort((a, b) => a.supplier_name.localeCompare(b.supplier_name))
  if (unassigned) sorted.push(unassigned)
  return sorted
}

/** Recomputes a line's totals after the operator edits the suggested quantity. */
export function recalculateLine(line: OrderLine, quantity: number): OrderLine {
  const suggested_quantity = Math.max(quantity, 0)
  return {
    ...line,
    suggested_quantity,
    line_total_net: line.unit_price_net != null ? line.unit_price_net * suggested_quantity : null,
    line_total_gross: line.unit_price_gross != null ? line.unit_price_gross * suggested_quantity : null,
  }
}

/** Recomputes a group's net/gross subtotals from its current lines (call after editing a line's quantity). */
export function recalculateGroupSubtotals(group: SupplierOrderGroup): SupplierOrderGroup {
  const netTotals = group.lines.map(l => l.line_total_net).filter((n): n is number => n != null)
  const grossTotals = group.lines.map(l => l.line_total_gross).filter((n): n is number => n != null)
  group.subtotal_net = netTotals.length > 0 ? netTotals.reduce((a, b) => a + b, 0) : null
  group.subtotal_gross = grossTotals.length > 0 ? grossTotals.reduce((a, b) => a + b, 0) : null
  return group
}
