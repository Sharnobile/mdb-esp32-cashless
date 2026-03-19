import { ref, useSupabaseClient } from '#imports'

export interface InsightRecommendation {
    type: 'product_swap' | 'capacity_increase' | 'remove_slot' | 'refill_optimization' | 'conversion_alert' | 'general'
    priority: 'high' | 'medium' | 'low'
    title: string
    detail: string
    item_number: number | null
}

export interface InsightsResponse {
    generated_at: string
    period_days: number
    machine: { id: string; name: string }
    recommendations: InsightRecommendation[]
    summary: string
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
        general: 'insights.general',
    }
    return map[type] ?? 'insights.general'
}

export function sortedRecommendations(recs: InsightRecommendation[]): InsightRecommendation[] {
    return [...recs].sort((a, b) => (PRIORITY_ORDER[a.priority] ?? 9) - (PRIORITY_ORDER[b.priority] ?? 9))
}

export function useInsights() {
    const supabase = useSupabaseClient()

    const data = ref<InsightsResponse | null>(null)
    const loading = ref(false)
    const error = ref('')

    async function fetchInsights(machineId: string, days = 30) {
        loading.value = true
        error.value = ''
        data.value = null

        try {
            const { data: result, error: fnError } = await (supabase as any).functions.invoke('machine-insights', {
                body: { machine_id: machineId, days },
            })

            if (fnError) {
                // Edge function errors come as FunctionsHttpError with context
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

    return {
        data,
        loading,
        error,
        fetchInsights,
    }
}
