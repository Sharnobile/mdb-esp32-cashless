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
  source_url: string | null
  external_url: string | null
  matched_by: string
  confidence: number
  matched_tokens: string[] | null
  requires_app: boolean
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

// Country presets — must stay in sync with edge function COUNTRY_PRESETS
export interface DealsConfig {
  generic_terms: string[]
  wildcard_phrases: string[]
  app_detection_patterns: string[]
}

export const DEALS_COUNTRY_PRESETS: Record<string, DealsConfig> = {
  DE: {
    generic_terms: [
      'verschiedene', 'sorten', 'versch', 'diverse', 'oder', 'und', 'z.b',
      'zb', 'jede', 'jeder', 'je',
      'stück', 'packung', 'dose', 'flasche', 'dosen', 'flaschen',
      'kasten', 'kiste', 'krat', 'tray', 'pack', 'beutel', 'becher',
      'tafel', 'riegel', 'tube', 'glas',
      'drink', 'drinks', 'getränk', 'getränke',
      'light', 'free', 'sugar',
      'bio', 'vegan',
      'ml', 'cl', 'liter', 'kg', 'gr',
    ],
    wildcard_phrases: [
      'verschiedene', 'versch', 'diverse', 'sorten', 'sort',
      'alle sorten', 'viele sorten', 'mehrere sorten',
    ],
    app_detection_patterns: [
      'mit app', 'in der app',
      'netto-app', 'netto app',
      'lidl plus', 'lidl-plus',
      'rewe bonus', 'rewe-bonus',
      'penny app', 'penny-app',
      'kaufland card', 'kaufland-card',
      'app-preis', 'app preis', 'apppreis',
      'nur mit',
      'app-coupon', 'app coupon',
      'digital-coupon', 'digital coupon',
    ],
  },
  AT: {
    generic_terms: [
      'verschiedene', 'sorten', 'versch', 'diverse', 'oder', 'und', 'z.b',
      'zb', 'jede', 'jeder', 'je',
      'stück', 'packung', 'dose', 'flasche', 'dosen', 'flaschen',
      'kasten', 'kiste', 'krat', 'tray', 'pack', 'beutel', 'becher',
      'tafel', 'riegel', 'tube', 'glas',
      'drink', 'drinks', 'getränk', 'getränke',
      'light', 'free', 'sugar',
      'bio', 'vegan',
      'ml', 'cl', 'liter', 'kg', 'gr',
    ],
    wildcard_phrases: [
      'verschiedene', 'versch', 'diverse', 'sorten', 'sort',
      'alle sorten', 'viele sorten', 'mehrere sorten',
    ],
    app_detection_patterns: [
      'mit app', 'in der app',
      'billa plus', 'billa-plus',
      'jö bonus', 'jö-bonus', 'jö app',
      'spar app', 'spar-app',
      'lidl plus', 'lidl-plus',
      'app-preis', 'app preis',
      'nur mit',
    ],
  },
}

export function getDealsPreset(countryCode: string): DealsConfig {
  return DEALS_COUNTRY_PRESETS[countryCode] ?? DEALS_COUNTRY_PRESETS['DE']
}

export function useDeals() {
  const supabase = useSupabaseClient()
  const { organization } = useOrganization()

  const deals = ref<Deal[]>([])
  const loading = ref(false)
  const error = ref('')
  const fromCache = ref(false)
  const searchedProducts = ref(0)
  const lastFetchedAt = ref<string | null>(null)

  // Deal search settings
  const dealsEnabled = ref(false)
  const dealsZipCode = ref('')
  const settingsLoading = ref(false)
  const settingsError = ref('')
  const settingsSuccess = ref('')

  // Configurable keyword lists (null = use country defaults)
  interface DealsConfigOverrides {
    generic_terms: string[] | null
    wildcard_phrases: string[] | null
    app_detection_patterns: string[] | null
    retailer_prospekt_urls: Record<string, string> | null
  }
  const dealsConfig = ref<DealsConfigOverrides>({
    generic_terms: null,
    wildcard_phrases: null,
    app_detection_patterns: null,
    retailer_prospekt_urls: null,
  })
  const hasCustomConfig = computed(() => {
    const c = dealsConfig.value
    return c.generic_terms !== null || c.wildcard_phrases !== null
      || c.app_detection_patterns !== null || c.retailer_prospekt_urls !== null
  })

  async function loadSettings() {
    if (!organization.value?.id) return
    const { data } = await supabase
      .from('companies')
      .select('deals_enabled, deals_zip_code, deals_config')
      .eq('id', organization.value.id)
      .single()
    if (data) {
      dealsEnabled.value = (data as any).deals_enabled ?? false
      dealsZipCode.value = (data as any).deals_zip_code ?? ''
      const cfg = (data as any).deals_config
      if (cfg) {
        dealsConfig.value = {
          generic_terms: cfg.generic_terms ?? null,
          wildcard_phrases: cfg.wildcard_phrases ?? null,
          app_detection_patterns: cfg.app_detection_patterns ?? null,
          retailer_prospekt_urls: cfg.retailer_prospekt_urls ?? null,
        }
      }
    }
  }

  async function saveSettings() {
    settingsError.value = ''
    settingsSuccess.value = ''
    if (!organization.value?.id) return

    // Build config: only include non-null overrides
    const cfg = dealsConfig.value
    const configToSave = (cfg.generic_terms || cfg.wildcard_phrases || cfg.app_detection_patterns || cfg.retailer_prospekt_urls)
      ? {
          ...(cfg.generic_terms ? { generic_terms: cfg.generic_terms } : {}),
          ...(cfg.wildcard_phrases ? { wildcard_phrases: cfg.wildcard_phrases } : {}),
          ...(cfg.app_detection_patterns ? { app_detection_patterns: cfg.app_detection_patterns } : {}),
          ...(cfg.retailer_prospekt_urls ? { retailer_prospekt_urls: cfg.retailer_prospekt_urls } : {}),
        }
      : null

    settingsLoading.value = true
    try {
      const { error: err } = await supabase
        .from('companies')
        .update({
          deals_enabled: dealsEnabled.value,
          deals_zip_code: dealsZipCode.value.trim() || null,
          deals_config: configToSave,
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

  function resetConfig() {
    dealsConfig.value = {
      generic_terms: null,
      wildcard_phrases: null,
      app_detection_patterns: null,
      retailer_prospekt_urls: null,
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
      // Use the fetched_at from the first deal, or current time for fresh data
      if (deals.value.length > 0 && deals.value[0].fetched_at) {
        lastFetchedAt.value = deals.value[0].fetched_at
      } else if (!res.fromCache) {
        lastFetchedAt.value = new Date().toISOString()
      }
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
    lastFetchedAt,
    dealsEnabled,
    dealsZipCode,
    dealsConfig,
    hasCustomConfig,
    settingsLoading,
    settingsError,
    settingsSuccess,
    loadSettings,
    saveSettings,
    resetConfig,
    fetchDeals,
    dealsByRetailer,
    dealsByProduct,
    totalDeals,
    uniqueRetailers,
    avgDiscount,
  }
}
