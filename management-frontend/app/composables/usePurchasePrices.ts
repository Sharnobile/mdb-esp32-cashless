import { useSupabaseClient } from '#imports'
import type { PurchaseSummary } from '~/lib/purchaseComparison'

export interface Supplier { id: string; name: string }

export interface PurchasePrice {
  id: string
  product_id: string
  supplier_id: string
  supplier_name: string
  price_net: number
  price_gross: number
  price_basis: 'net' | 'gross'
  tax_rate: number
  observed_on: string
  note: string | null
}

interface PriceInput {
  productId: string
  supplierName: string
  price: number
  basis: 'net' | 'gross'
  observedOn: string
  note?: string | null
  taxRateOverride?: number | null
}

export function usePurchasePrices() {
  const suppliers = useState<Supplier[]>('suppliers', () => [])

  async function fetchSuppliers() {
    const supabase = useSupabaseClient()
    const { data, error } = await supabase.from('suppliers').select('id, name').order('name')
    if (error) throw error
    suppliers.value = (data ?? []) as Supplier[]
  }

  async function fetchPurchasePrices(productId: string): Promise<PurchasePrice[]> {
    const supabase = useSupabaseClient()
    const { data, error } = await supabase
      .from('product_purchase_prices')
      .select('id, product_id, supplier_id, price_net, price_gross, price_basis, tax_rate, observed_on, note, suppliers(name)')
      .eq('product_id', productId)
      .order('observed_on', { ascending: false })
      .order('created_at', { ascending: false })
    if (error) throw error
    return ((data ?? []) as any[]).map((r) => ({
      id: r.id,
      product_id: r.product_id,
      supplier_id: r.supplier_id,
      supplier_name: r.suppliers?.name ?? '',
      price_net: Number(r.price_net),
      price_gross: Number(r.price_gross),
      price_basis: r.price_basis,
      tax_rate: Number(r.tax_rate),
      observed_on: r.observed_on,
      note: r.note,
    }))
  }

  async function resolveTaxRate(productId: string): Promise<number | null> {
    const supabase = useSupabaseClient()
    const { data, error } = await (supabase as any).rpc('resolve_product_tax_rate', { p_product_id: productId })
    if (error) throw error
    return data == null ? null : Number(data)
  }

  async function addPurchasePrice(input: PriceInput): Promise<PurchasePrice> {
    const supabase = useSupabaseClient()
    const { data, error } = await (supabase as any).rpc('add_purchase_price', {
      p_product_id: input.productId,
      p_supplier_name: input.supplierName,
      p_price: input.price,
      p_basis: input.basis,
      p_observed_on: input.observedOn,
      p_note: input.note ?? null,
      p_tax_rate_override: input.taxRateOverride ?? null,
    })
    if (error) throw error
    await fetchSuppliers()
    return data as PurchasePrice
  }

  async function updatePurchasePrice(id: string, input: PriceInput): Promise<PurchasePrice> {
    const supabase = useSupabaseClient()
    const { data, error } = await (supabase as any).rpc('update_purchase_price', {
      p_id: id,
      p_supplier_name: input.supplierName,
      p_price: input.price,
      p_basis: input.basis,
      p_observed_on: input.observedOn,
      p_note: input.note ?? null,
      p_tax_rate_override: input.taxRateOverride ?? null,
    })
    if (error) throw error
    await fetchSuppliers()
    return data as PurchasePrice
  }

  async function deletePurchasePrice(id: string) {
    const supabase = useSupabaseClient()
    const { error } = await supabase.from('product_purchase_prices').delete().eq('id', id)
    if (error) throw error
  }

  async function fetchSummaries(productIds: string[]): Promise<Record<string, PurchaseSummary>> {
    if (productIds.length === 0) return {}
    const supabase = useSupabaseClient()
    const { data, error } = await (supabase as any).rpc('get_product_purchase_summary', { p_product_ids: productIds })
    if (error) throw error
    const map: Record<string, PurchaseSummary> = {}
    for (const r of (data ?? []) as any[]) {
      map[r.product_id] = {
        product_id: r.product_id,
        ek_count: Number(r.ek_count),
        newest_net: r.newest_net == null ? null : Number(r.newest_net),
        newest_gross: r.newest_gross == null ? null : Number(r.newest_gross),
        newest_supplier: r.newest_supplier ?? null,
        newest_on: r.newest_on ?? null,
        min_gross: r.min_gross == null ? null : Number(r.min_gross),
        min_supplier: r.min_supplier ?? null,
        min_on: r.min_on ?? null,
        max_gross: r.max_gross == null ? null : Number(r.max_gross),
        effective_tax_rate: r.effective_tax_rate == null ? null : Number(r.effective_tax_rate),
      }
    }
    return map
  }

  return {
    suppliers,
    fetchSuppliers,
    fetchPurchasePrices,
    resolveTaxRate,
    addPurchasePrice,
    updatePurchasePrice,
    deletePurchasePrice,
    fetchSummaries,
  }
}
