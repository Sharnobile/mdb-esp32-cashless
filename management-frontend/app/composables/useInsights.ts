import { ref, useSupabaseClient, useI18n } from '#imports'

export interface InsightRecommendation {
    type: 'product_swap' | 'capacity_increase' | 'remove_slot' | 'refill_optimization' | 'conversion_alert' | 'pricing_strategy' | 'cross_selling' | 'peak_hour_strategy' | 'day_pattern' | 'general'
    priority: 'high' | 'medium' | 'low'
    title: string
    detail: string
    item_number: number | null
}

export interface InsightsTrends {
    current_revenue_eur: number
    current_total_units: number
    prev_revenue_eur: number
    prev_total_units: number
    revenue_change_pct: number | null
    units_change_pct: number | null
}

export interface InsightsResponse {
    generated_at: string
    period_days: number
    type?: string
    machine?: { id: string; name: string }
    company?: { id: string; name: string }
    machines?: { id: string; name: string; revenue_eur: number; units: number; status: string }[]
    recommendations: InsightRecommendation[]
    summary: string
    trends?: InsightsTrends | null
    cached?: boolean
}

export interface InsightHistoryEntry {
    id: string
    machine_id: string | null
    period_days: number
    locale: string
    recommendations: InsightRecommendation[]
    summary: string
    trends: InsightsTrends | null
    generated_at: string
    created_at: string
}

const PRIORITY_ORDER: Record<string, number> = { high: 0, medium: 1, low: 2 }

export function priorityVariant(priority: string): 'default' | 'secondary' | 'destructive' {
    if (priority === 'high') return 'destructive'
    if (priority === 'medium') return 'default'
    return 'secondary'
}

export function recommendationTypeLabel(type: string): string {
    const map: Record<string, string> = {
        product_swap: 'insights.productSwap',
        capacity_increase: 'insights.capacityIncrease',
        remove_slot: 'insights.removeSlot',
        refill_optimization: 'insights.refillOptimization',
        conversion_alert: 'insights.conversionAlert',
        pricing_strategy: 'insights.pricingStrategy',
        cross_selling: 'insights.crossSelling',
        peak_hour_strategy: 'insights.peakHourStrategy',
        day_pattern: 'insights.dayPattern',
        general: 'insights.general',
    }
    return map[type] ?? 'insights.general'
}

export function sortedRecommendations(recs: InsightRecommendation[]): InsightRecommendation[] {
    return [...recs].sort((a, b) => (PRIORITY_ORDER[a.priority] ?? 9) - (PRIORITY_ORDER[b.priority] ?? 9))
}

export function useInsights() {
    const supabase = useSupabaseClient()
    const { locale } = useI18n()

    const data = ref<InsightsResponse | null>(null)
    const loading = ref(false)
    const error = ref('')

    const history = ref<InsightHistoryEntry[]>([])
    const historyLoading = ref(false)

    const companyData = ref<InsightsResponse | null>(null)
    const companyLoading = ref(false)
    const companyError = ref('')

    async function fetchInsights(machineId: string, days = 30, forceRefresh = false) {
        loading.value = true
        error.value = ''
        data.value = null

        try {
            const { data: result, error: fnError } = await (supabase as any).functions.invoke('machine-insights', {
                body: { machine_id: machineId, days, force_refresh: forceRefresh, locale: locale.value, type: 'machine' },
            })

            if (fnError) {
                const body = typeof fnError.context === 'object' ? fnError.context : null
                if (body?.json) {
                    const json = await body.json().catch(() => null)
                    error.value = json?.error ?? fnError.message
                } else {
                    error.value = fnError.message ?? 'Unknown error'
                }
                return
            }

            data.value = result as InsightsResponse
        } catch (err: unknown) {
            error.value = err instanceof Error ? err.message : 'Failed to fetch insights'
        } finally {
            loading.value = false
        }
    }

    async function fetchHistory(machineId?: string) {
        historyLoading.value = true
        try {
            const { data: result, error: fnError } = await (supabase as any).functions.invoke('machine-insights', {
                body: { machine_id: machineId ?? null, type: 'history', locale: locale.value },
            })

            if (!fnError && result?.history) {
                history.value = result.history as InsightHistoryEntry[]
            }
        } catch {
            // Silently fail — history is secondary
        } finally {
            historyLoading.value = false
        }
    }

    async function fetchCompanyInsights(days = 30, forceRefresh = false) {
        companyLoading.value = true
        companyError.value = ''
        companyData.value = null

        try {
            const { data: result, error: fnError } = await (supabase as any).functions.invoke('machine-insights', {
                body: { days, force_refresh: forceRefresh, locale: locale.value, type: 'company' },
            })

            if (fnError) {
                const body = typeof fnError.context === 'object' ? fnError.context : null
                if (body?.json) {
                    const json = await body.json().catch(() => null)
                    companyError.value = json?.error ?? fnError.message
                } else {
                    companyError.value = fnError.message ?? 'Unknown error'
                }
                return
            }

            companyData.value = result as InsightsResponse
        } catch (err: unknown) {
            companyError.value = err instanceof Error ? err.message : 'Failed to fetch company insights'
        } finally {
            companyLoading.value = false
        }
    }

    return {
        data,
        loading,
        error,
        fetchInsights,
        history,
        historyLoading,
        fetchHistory,
        companyData,
        companyLoading,
        companyError,
        fetchCompanyInsights,
    }
}
