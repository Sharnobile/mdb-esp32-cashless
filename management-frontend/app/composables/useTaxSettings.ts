import { useSupabaseClient } from '#imports'

export interface TaxClass {
  id: string
  name: string
  description: string | null
  sort_order: number
}

export interface TaxRate {
  id: string
  tax_class_id: string
  tax_class_name?: string
  country_code: string
  rate: number
  name: string
  valid_from: string
  valid_to: string | null
  is_inclusive: boolean
}

export interface SystemTaxRate {
  id: number
  country_code: string
  tax_class_name: string
  rate: number
  name: string
  valid_from: string
}

export const COUNTRY_OPTIONS = [
  { code: 'DE', label: 'Deutschland' },
  { code: 'AT', label: 'Österreich' },
  { code: 'CH', label: 'Schweiz' },
  { code: 'FR', label: 'France' },
  { code: 'IT', label: 'Italia' },
  { code: 'ES', label: 'España' },
  { code: 'NL', label: 'Nederland' },
  { code: 'BE', label: 'Belgique' },
  { code: 'PL', label: 'Polska' },
  { code: 'CZ', label: 'Česko' },
  { code: 'PT', label: 'Portugal' },
  { code: 'LU', label: 'Luxembourg' },
] as const

export function useTaxSettings() {
  const taxClasses = useState<TaxClass[]>('tax-classes', () => [])
  const taxRates = useState<TaxRate[]>('tax-rates', () => [])
  const systemRates = useState<SystemTaxRate[]>('system-tax-rates', () => [])
  const companyCountry = useState<string>('company-country', () => 'DE')
  const loading = ref(false)

  async function fetchTaxClasses() {
    const supabase = useSupabaseClient()
    const { data, error } = await supabase
      .from('tax_classes')
      .select('id, name, description, sort_order')
      .order('sort_order')
    if (error) throw error
    taxClasses.value = (data ?? []) as TaxClass[]
  }

  async function fetchTaxRates() {
    const supabase = useSupabaseClient()
    const { data, error } = await supabase
      .from('tax_rates')
      .select('id, tax_class_id, country_code, rate, name, valid_from, valid_to, is_inclusive, tax_classes(name)')
      .order('country_code')
      .order('tax_class_id')
    if (error) throw error
    taxRates.value = ((data ?? []) as any[]).map((r) => ({
      id: r.id,
      tax_class_id: r.tax_class_id,
      tax_class_name: r.tax_classes?.name ?? null,
      country_code: r.country_code,
      rate: r.rate,
      name: r.name,
      valid_from: r.valid_from,
      valid_to: r.valid_to,
      is_inclusive: r.is_inclusive,
    }))
  }

  async function fetchSystemRates() {
    const supabase = useSupabaseClient()
    const { data, error } = await supabase
      .from('system_tax_rates')
      .select('id, country_code, tax_class_name, rate, name, valid_from')
      .order('country_code')
      .order('tax_class_name')
    if (error) throw error
    systemRates.value = (data ?? []) as SystemTaxRate[]
  }

  async function fetchCompanyCountry(companyId: string) {
    const supabase = useSupabaseClient()
    const { data } = await supabase
      .from('companies')
      .select('country_code')
      .eq('id', companyId)
      .single()
    companyCountry.value = (data as any)?.country_code ?? 'DE'
  }

  async function fetchAll(companyId: string) {
    loading.value = true
    try {
      await Promise.all([
        fetchTaxClasses(),
        fetchTaxRates(),
        fetchSystemRates(),
        fetchCompanyCountry(companyId),
      ])
    } finally {
      loading.value = false
    }
  }

  async function createTaxClass(name: string, description?: string) {
    const supabase = useSupabaseClient()
    const { organization } = useOrganization()
    const { error } = await supabase.from('tax_classes').insert({
      name,
      description: description || null,
      company_id: organization.value!.id,
    })
    if (error) throw error
    await fetchTaxClasses()
  }

  async function updateTaxClass(id: string, name: string, description?: string) {
    const supabase = useSupabaseClient()
    const { error } = await supabase.from('tax_classes').update({
      name,
      description: description || null,
    }).eq('id', id)
    if (error) throw error
    await fetchTaxClasses()
  }

  async function deleteTaxClass(id: string) {
    const supabase = useSupabaseClient()
    const { error } = await supabase.from('tax_classes').delete().eq('id', id)
    if (error) throw error
    await Promise.all([fetchTaxClasses(), fetchTaxRates()])
  }

  async function createTaxRate(taxClassId: string, countryCode: string, rate: number, name: string, validFrom: string, validTo?: string) {
    const supabase = useSupabaseClient()
    const { organization } = useOrganization()
    const { error } = await supabase.from('tax_rates').insert({
      tax_class_id: taxClassId,
      country_code: countryCode,
      rate,
      name,
      valid_from: validFrom,
      valid_to: validTo || null,
      company_id: organization.value!.id,
    })
    if (error) throw error
    await fetchTaxRates()
  }

  async function updateTaxRate(id: string, updates: Partial<Pick<TaxRate, 'rate' | 'name' | 'valid_from' | 'valid_to'>>) {
    const supabase = useSupabaseClient()
    const { error } = await supabase.from('tax_rates').update(updates).eq('id', id)
    if (error) throw error
    await fetchTaxRates()
  }

  async function deleteTaxRate(id: string) {
    const supabase = useSupabaseClient()
    const { error } = await supabase.from('tax_rates').delete().eq('id', id)
    if (error) throw error
    await fetchTaxRates()
  }

  async function updateCompanyCountry(countryCode: string) {
    const supabase = useSupabaseClient()
    const { organization } = useOrganization()
    const { error } = await supabase
      .from('companies')
      .update({ country_code: countryCode })
      .eq('id', organization.value!.id)
    if (error) throw error
    companyCountry.value = countryCode
  }

  async function seedFromSystem(countryCode: string) {
    const supabase = useSupabaseClient()
    const { organization } = useOrganization()
    const companyId = organization.value!.id

    // Get system rates for this country
    const countryRates = systemRates.value.filter(r => r.country_code === countryCode)
    if (countryRates.length === 0) return

    // Get unique class names
    const classNames = [...new Set(countryRates.map(r => r.tax_class_name))]

    // Create tax classes that don't exist yet
    for (const className of classNames) {
      const exists = taxClasses.value.find(tc => tc.name === className)
      if (!exists) {
        await supabase.from('tax_classes').insert({
          name: className,
          company_id: companyId,
          sort_order: className === 'standard' ? 0 : className === 'reduced' ? 1 : 2,
        })
      }
    }

    // Re-fetch to get IDs
    await fetchTaxClasses()

    // Create tax rates
    for (const sysRate of countryRates) {
      const taxClass = taxClasses.value.find(tc => tc.name === sysRate.tax_class_name)
      if (!taxClass) continue

      // Check if rate already exists for this class + country + valid_from
      const exists = taxRates.value.find(
        r => r.tax_class_id === taxClass.id && r.country_code === countryCode && r.valid_from === sysRate.valid_from
      )
      if (!exists) {
        await supabase.from('tax_rates').insert({
          tax_class_id: taxClass.id,
          country_code: countryCode,
          rate: sysRate.rate,
          name: sysRate.name,
          valid_from: sysRate.valid_from,
          company_id: companyId,
        })
      }
    }

    await fetchTaxRates()
  }

  /** Get the current rate for a tax class in the company country */
  function getCurrentRate(taxClassId: string): number | null {
    const now = new Date().toISOString().split('T')[0]!
    const matching = taxRates.value
      .filter(
        r => r.tax_class_id === taxClassId
          && r.country_code === companyCountry.value
          && r.valid_from <= now
          && (r.valid_to === null || r.valid_to >= now)
      )
      .sort((a, b) => b.valid_from.localeCompare(a.valid_from))
    return matching[0]?.rate ?? null
  }

  /** Format tax class for display: "Standard (19%)" */
  function formatTaxClassLabel(tc: TaxClass): string {
    const rate = getCurrentRate(tc.id)
    if (rate !== null) {
      return `${tc.name} (${(rate * 100).toFixed(rate * 100 % 1 === 0 ? 0 : 1)}%)`
    }
    return tc.name
  }

  return {
    taxClasses,
    taxRates,
    systemRates,
    companyCountry,
    loading,
    fetchTaxClasses,
    fetchTaxRates,
    fetchSystemRates,
    fetchCompanyCountry,
    fetchAll,
    createTaxClass,
    updateTaxClass,
    deleteTaxClass,
    createTaxRate,
    updateTaxRate,
    deleteTaxRate,
    updateCompanyCountry,
    seedFromSystem,
    getCurrentRate,
    formatTaxClassLabel,
  }
}
