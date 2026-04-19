export interface DealKeyword {
  id: string
  label: string | null
  terms: string[]
  product_ids: string[]
  created_at: string
  updated_at: string
}

export interface Deal {
  id: string
  product_id: string | null
  keyword_id: string | null
  matched_term: string | null
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
    id: string
    name: string
    image_path: string | null
    sellprice: number | null
  } | null
  deal_keywords: {
    id: string
    label: string | null
    terms: string[]
    deal_keyword_products: Array<{
      products: { id: string; name: string; image_path: string | null; sellprice: number | null }
    }>
  } | null
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

  // ── Keyword groups ─────────────────────────────────────────────────────────

  const keywords = useState<DealKeyword[]>('deal-keywords', () => [])

  async function fetchKeywords() {
    const { data, error: err } = await supabase
      .from('deal_keywords')
      .select('id, label, terms, created_at, updated_at, deal_keyword_products(product_id)')
      .order('label', { ascending: true, nullsFirst: false })

    if (err) {
      console.error('[useDeals] fetchKeywords failed:', err)
      keywords.value = []
      return
    }
    keywords.value = (data ?? []).map((row: any) => ({
      id: row.id,
      label: row.label,
      terms: row.terms ?? [],
      product_ids: (row.deal_keyword_products ?? []).map((kp: any) => kp.product_id),
      created_at: row.created_at,
      updated_at: row.updated_at,
    }))
  }

  async function createKeyword(input: {
    label?: string | null
    terms: string[]
    product_ids: string[]
  }): Promise<DealKeyword | null> {
    // Reuse the already-captured `organization` ref at the top of `useDeals()` —
    // do NOT call useOrganization() again inside this function (existing pattern
    // in this composable is to destructure once at the top).
    if (!organization.value) return null

    const { data, error: err } = await supabase
      .from('deal_keywords')
      .insert({
        company_id: organization.value.id,
        label: input.label ?? null,
        terms: input.terms,
      })
      .select('id, label, terms, created_at, updated_at')
      .single()

    if (err || !data) {
      console.error('[useDeals] createKeyword failed:', err)
      return null
    }

    if (input.product_ids.length > 0) {
      const { error: linkErr } = await supabase
        .from('deal_keyword_products')
        .insert(input.product_ids.map((pid) => ({ keyword_id: data.id, product_id: pid })))
      if (linkErr) console.error('[useDeals] createKeyword link failed:', linkErr)
    }

    await fetchKeywords()
    return keywords.value.find((k) => k.id === data.id) ?? null
  }

  async function updateKeyword(
    id: string,
    patch: { label?: string | null; terms?: string[] },
  ) {
    const { error: err } = await supabase
      .from('deal_keywords')
      .update(patch)
      .eq('id', id)
    if (err) {
      console.error('[useDeals] updateKeyword failed:', err)
      return
    }
    await fetchKeywords()
  }

  async function setKeywordProducts(id: string, productIds: string[]) {
    // Simple strategy: delete all + insert fresh. deal_keyword_products is
    // a PK-only junction, so no lost metadata.
    const { error: delErr } = await supabase
      .from('deal_keyword_products')
      .delete()
      .eq('keyword_id', id)
    if (delErr) {
      console.error('[useDeals] setKeywordProducts delete failed:', delErr)
      return
    }
    if (productIds.length > 0) {
      const { error: insErr } = await supabase
        .from('deal_keyword_products')
        .insert(productIds.map((pid) => ({ keyword_id: id, product_id: pid })))
      if (insErr) console.error('[useDeals] setKeywordProducts insert failed:', insErr)
    }
    await fetchKeywords()
  }

  async function deleteKeyword(id: string) {
    const { error: err } = await supabase
      .from('deal_keywords')
      .delete()
      .eq('id', id)
    if (err) {
      console.error('[useDeals] deleteKeyword failed:', err)
      return
    }
    await fetchKeywords()
  }

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
    keywords,
    fetchKeywords,
    createKeyword,
    updateKeyword,
    setKeywordProducts,
    deleteKeyword,
  }
}
