import { useSupabaseClient } from '#imports'
import { useWarehouse } from './useWarehouse'
import { usePurchasePrices } from './usePurchasePrices'
import {
  buildSupplierOrderGroups,
  type SupplierOrderGroup,
  type SupplierContact,
  type OrderCandidateProduct,
} from '~/lib/supplierOrderList'

/**
 * Aggregates low-stock / out-of-stock warehouse products into a supplier-grouped
 * purchase list, so an operator knows what to order and from whom before placing
 * a supplier order. Read-only: does not create any order/tracking record — actual
 * restocking still happens via useWarehouse()'s existing stock-intake flow.
 */
export function useSupplierOrderList() {
  const supabase = useSupabaseClient()
  const { fetchProductSummaries, productSummaries } = useWarehouse()
  const { fetchSummaries } = usePurchasePrices()

  const groups = ref<SupplierOrderGroup[]>([])
  const loading = ref(false)

  async function fetchSupplierContacts(): Promise<SupplierContact[]> {
    const { data, error } = await (supabase as any)
      .from('suppliers')
      .select('id, name, email, phone, address, customer_number')
      .order('name')
    if (error) throw error
    return (data ?? []) as SupplierContact[]
  }

  async function fetchOrderList(warehouseId: string) {
    loading.value = true
    try {
      await fetchProductSummaries(warehouseId)

      const candidates: OrderCandidateProduct[] = productSummaries.value
        .filter(p => !p.discontinued && (p.is_below_min || p.total_quantity === 0))
        .map(p => ({
          product_id: p.product_id,
          product_name: p.product_name,
          total_quantity: p.total_quantity,
          min_stock: p.min_stock,
        }))

      const [purchaseSummaries, suppliers] = await Promise.all([
        fetchSummaries(candidates.map(p => p.product_id)),
        fetchSupplierContacts(),
      ])

      groups.value = buildSupplierOrderGroups(candidates, purchaseSummaries, suppliers)
    } finally {
      loading.value = false
    }
  }

  return { groups, loading, fetchOrderList }
}
