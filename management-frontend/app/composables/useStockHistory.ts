import { ref, useSupabaseClient } from '#imports'

export interface StockHistoryEntry {
  id: string
  created_at: string
  type: 'sale' | 'manual_change' | 'decrement_failed'
  // sale fields
  item_price?: number
  channel?: string
  // manual change fields (from activity_log)
  old_stock?: number
  new_stock?: number
  action?: string
  user_display?: string
  source?: string
  // decrement_failed fields
  reason?: string
}

const PAGE_SIZE = 50

export function useStockHistory() {
  const supabase = useSupabaseClient()

  const entries = ref<StockHistoryEntry[]>([])
  const loading = ref(false)
  const hasMore = ref(true)

  /**
   * Fetches interleaved stock history for a specific tray:
   * 1. Sales for (machine_id, item_number) → stock decreased
   * 2. Activity log entries for this tray → manual changes
   * 3. stock_decrement_log for (machine_id, item_number) → failed decrements
   */
  async function fetchHistory(machineId: string, itemNumber: number, embeddedId: string | null) {
    loading.value = true
    hasMore.value = true
    try {
      const results = await Promise.all([
        // Sales for this slot
        (supabase as any)
          .from('sales')
          .select('id, created_at, item_price, channel')
          .eq('machine_id', machineId)
          .eq('item_number', itemNumber)
          .order('created_at', { ascending: false })
          .limit(PAGE_SIZE),

        // Activity log for stock changes on this tray
        (supabase as any)
          .from('activity_log')
          .select('id, created_at, action, metadata')
          .eq('entity_type', 'stock')
          .order('created_at', { ascending: false })
          .limit(PAGE_SIZE * 2), // fetch more since we filter client-side

        // Failed decrements for this slot
        (supabase as any)
          .from('stock_decrement_log')
          .select('id, created_at, reason, item_price')
          .eq('machine_id', machineId)
          .eq('item_number', itemNumber)
          .order('created_at', { ascending: false })
          .limit(PAGE_SIZE),
      ])

      const salesData = (results[0].data ?? []) as any[]
      const activityData = (results[1].data ?? []) as any[]
      const failedData = (results[2].data ?? []) as any[]

      const merged: StockHistoryEntry[] = []

      // Map sales
      for (const s of salesData) {
        merged.push({
          id: s.id,
          created_at: s.created_at,
          type: 'sale',
          item_price: s.item_price,
          channel: s.channel,
        })
      }

      // Map activity log (filter to matching item_number)
      for (const a of activityData) {
        const meta = a.metadata ?? {}
        if (meta.machine_id !== machineId) continue
        if (meta.item_number !== itemNumber) continue
        merged.push({
          id: a.id,
          created_at: a.created_at,
          type: 'manual_change',
          action: a.action,
          old_stock: meta.old_stock,
          new_stock: meta.new_stock,
          user_display: meta._user_display ?? meta._user_email ?? null,
          source: meta.source ?? undefined,
        })
      }

      // Map failed decrements
      for (const f of failedData) {
        merged.push({
          id: f.id,
          created_at: f.created_at,
          type: 'decrement_failed',
          reason: f.reason,
          item_price: f.item_price,
        })
      }

      // Sort by created_at descending
      merged.sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime())

      entries.value = merged.slice(0, PAGE_SIZE)
      hasMore.value = merged.length > PAGE_SIZE
    } finally {
      loading.value = false
    }
  }

  function reset() {
    entries.value = []
    hasMore.value = true
  }

  return {
    entries,
    loading,
    hasMore,
    fetchHistory,
    reset,
  }
}
