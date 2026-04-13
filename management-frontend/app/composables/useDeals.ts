export interface Deal {
  id: string
  product_id: string
  retailer: string
  deal_title: string
  deal_price: number | null
  regular_price: number | null
  discount_pct: number | null
  valid_from: string | null
  valid_until: string | null
  image_url: string | null
  image_url_large: string | null
  external_url: string | null
  matched_by: string
  confidence: number
  matched_tokens: string[] | null
  fetched_at: string
  offer_id: string
  products: {
    name: string
    image_path: string | null
    sellprice: number | null
  }
}

interface DealSearchResponse {
  deals: Deal[]
  fromCache: boolean
  searchedProducts?: number
  totalDeals?: number
  error?: string
}

export function useDeals() {
  const supabase = useSupabaseClient()
  const { organization } = useOrganization()

  const deals = ref<Deal[]>([])
  const loading = ref(false)
  const error = ref('')
  const fromCache = ref(false)
  const searchedProducts = ref(0)

  // Deal search settings
  const dealsEnabled = ref(false)
  const dealsZipCode = ref('')
  const settingsLoading = ref(false)
  const settingsError = ref('')
  const settingsSuccess = ref('')

  async function loadSettings() {
    if (!organization.value?.id) return
    const { data } = await supabase
      .from('companies')
      .select('deals_enabled, deals_zip_code')
      .eq('id', organization.value.id)
      .single()
    if (data) {
      dealsEnabled.value = (data as any).deals_enabled ?? false
      dealsZipCode.value = (data as any).deals_zip_code ?? ''
    }
  }

  async function saveSettings() {
    settingsError.value = ''
    settingsSuccess.value = ''
    if (!organization.value?.id) return

    settingsLoading.value = true
    try {
      const { error: err } = await supabase
        .from('companies')
        .update({
          deals_enabled: dealsEnabled.value,
          deals_zip_code: dealsZipCode.value.trim() || null,
        })
        .eq('id', organization.value.id)
      if (err) throw err
      settingsSuccess.value = 'saved'
    } catch (err: unknown) {
      settingsError.value = err instanceof Error ? err.message : 'Failed to save settings'
    } finally {
      settingsLoading.value = false
    }
  }

  async function fetchDeals(forceRefresh = false) {
    if (!organization.value?.id) return
    loading.value = true
    error.value = ''
    try {
      const { data, error: fnError } = await supabase.functions.invoke('deal-search', {
        body: { forceRefresh, minConfidence: 0.5 },
      })
      if (fnError) throw fnError
      const res = data as DealSearchResponse
      if (res.error) throw new Error(res.error)
      deals.value = res.deals ?? []
      fromCache.value = res.fromCache ?? false
      searchedProducts.value = res.searchedProducts ?? 0
    } catch (err: unknown) {
      error.value = err instanceof Error ? err.message : 'Failed to fetch deals'
    } finally {
      loading.value = false
    }
  }

  // Group deals by retailer
  const dealsByRetailer = computed(() => {
    const grouped = new Map<string, Deal[]>()
    for (const deal of deals.value) {
      const existing = grouped.get(deal.retailer) ?? []
      existing.push(deal)
      grouped.set(deal.retailer, existing)
    }
    return grouped
  })

  // Group deals by product
  const dealsByProduct = computed(() => {
    const grouped = new Map<string, Deal[]>()
    for (const deal of deals.value) {
      const name = deal.products?.name ?? deal.product_id
      const existing = grouped.get(name) ?? []
      existing.push(deal)
      grouped.set(name, existing)
    }
    return grouped
  })

  // Stats
  const totalDeals = computed(() => deals.value.length)
  const uniqueRetailers = computed(() => new Set(deals.value.map((d) => d.retailer)).size)
  const avgDiscount = computed(() => {
    const withDiscount = deals.value.filter((d) => d.discount_pct != null && d.discount_pct > 0)
    if (withDiscount.length === 0) return 0
    return Math.round(withDiscount.reduce((sum, d) => sum + (d.discount_pct ?? 0), 0) / withDiscount.length)
  })

  return {
    deals,
    loading,
    error,
    fromCache,
    searchedProducts,
    dealsEnabled,
    dealsZipCode,
    settingsLoading,
    settingsError,
    settingsSuccess,
    loadSettings,
    saveSettings,
    fetchDeals,
    dealsByRetailer,
    dealsByProduct,
    totalDeals,
    uniqueRetailers,
    avgDiscount,
  }
}
