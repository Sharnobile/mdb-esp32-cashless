import { ref, useSupabaseClient } from '#imports'

export interface SuppressedSale {
  id: string
  embedded_id: string
  item_number: number | null
  item_price: number | null
  channel: string | null
  sale_seq: number | null
  device_created_at: string | null
  received_at: string
  matched_sale_id: string | null
  reason: string
}

const PAGE = 50

export function useSuppressedSales() {
  // Capture the client once (like useMdbLog) — calling useSupabaseClient()
  // after an await would be outside the Nuxt sync context.
  const supabase = useSupabaseClient()
  const rows = ref<SuppressedSale[]>([])
  const loading = ref(false)
  const hasMore = ref(false)

  async function fetchRows(embeddedId: string) {
    loading.value = true
    try {
      const { data, error } = await (supabase as any)
        .from('suppressed_sales')
        .select('*')
        .eq('embedded_id', embeddedId)
        .order('received_at', { ascending: false })
        .range(0, PAGE - 1)
      if (error) throw error
      rows.value = (data ?? []) as SuppressedSale[]
      hasMore.value = rows.value.length === PAGE
    } finally {
      loading.value = false
    }
  }

  async function fetchMore(embeddedId: string) {
    if (loading.value || !hasMore.value) return
    loading.value = true
    try {
      const oldest = rows.value[rows.value.length - 1]?.received_at
      if (!oldest) return

      const { data, error } = await (supabase as any)
        .from('suppressed_sales')
        .select('*')
        .eq('embedded_id', embeddedId)
        .lt('received_at', oldest)
        .order('received_at', { ascending: false })
        .limit(PAGE)
      if (error) throw error
      const next = (data ?? []) as SuppressedSale[]
      rows.value.push(...next)
      hasMore.value = next.length === PAGE
    } finally {
      loading.value = false
    }
  }

  return { rows, loading, hasMore, fetchRows, fetchMore }
}
