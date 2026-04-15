export interface TourMachineEntry {
  machine_id: string
  machine_name: string
  skipped: boolean
  trays_refilled: number
  total_added: number
  products: { product_id: string | null; product_name: string; quantity: number }[]
}

export interface TourHistoryEntry {
  tour_id: string
  date: string
  user_display: string
  user_id: string | null
  machines: TourMachineEntry[]
  total_machines: number
  total_items_added: number
  machines_skipped: number
}

interface RawLogEntry {
  id: string
  created_at: string
  user_id: string | null
  action: string
  metadata: Record<string, any> | null
}

// Cache user labels to avoid re-fetching
const userCache = new Map<string, string>()

export function useTourHistory() {
  const supabase = useSupabaseClient()

  const tours = ref<TourHistoryEntry[]>([])
  const loading = ref(false)

  async function enrichUsers(entries: RawLogEntry[]): Promise<void> {
    const unknownIds = [
      ...new Set(
        entries
          .map(e => e.user_id)
          .filter((id): id is string => !!id && !userCache.has(id) && !(entries.find(x => x.user_id === id)?.metadata as any)?._user_display)
      ),
    ]
    if (unknownIds.length === 0) return

    const { data: users } = await (supabase as any)
      .from('users')
      .select('id, email, first_name, last_name')
      .in('id', unknownIds)

    for (const u of users ?? []) {
      const name = [u.first_name, u.last_name].filter(Boolean).join(' ').trim()
      userCache.set(u.id, name || u.email || u.id.slice(0, 8))
    }
  }

  function getUserDisplay(entry: RawLogEntry): string {
    if (!entry.user_id) return 'System'
    const baked = (entry.metadata as any)?._user_display as string | undefined
    return baked || userCache.get(entry.user_id) || (entry.metadata as any)?._user_email || entry.user_id.slice(0, 8)
  }

  function buildMachineEntry(entry: RawLogEntry): TourMachineEntry {
    const m = entry.metadata ?? {}
    const isSkip = entry.action === 'stock_refill_tour_skip'
    return {
      machine_id: String(m.machine_id ?? ''),
      machine_name: String(m.machine_name ?? 'Unknown'),
      skipped: isSkip,
      trays_refilled: isSkip ? 0 : Number(m.trays_refilled ?? 0),
      total_added: isSkip ? 0 : Number(m.total_added ?? 0),
      products: isSkip
        ? []
        : (Array.isArray(m.products)
            ? m.products.map((p: any) => ({
                product_id: p.product_id ? String(p.product_id) : null,
                product_name: String(p.product_name ?? ''),
                quantity: Number(p.quantity ?? 0),
              }))
            : []),
    }
  }

  async function fetchTours() {
    loading.value = true
    try {
      const { data, error } = await (supabase as any)
        .from('activity_log')
        .select('id, created_at, user_id, action, metadata')
        .in('action', ['stock_refill_tour', 'stock_refill_tour_skip'])
        .order('created_at', { ascending: false })
        .limit(200)

      if (error) throw error
      const entries = (data ?? []) as RawLogEntry[]
      if (entries.length === 0) {
        tours.value = []
        return
      }

      await enrichUsers(entries)

      // Group by tour_id. Legacy entries without tour_id: group by user_id + 10min window
      const tourMap = new Map<string, RawLogEntry[]>()

      for (const entry of entries) {
        const tid = (entry.metadata as any)?.tour_id as string | undefined
        if (tid) {
          const group = tourMap.get(tid) ?? []
          group.push(entry)
          tourMap.set(tid, group)
        } else {
          // Legacy grouping: user_id + 10min window
          let matched = false
          for (const [key, group] of tourMap) {
            if (!key.startsWith('legacy-')) continue
            const first = group[0]!
            if (first.user_id !== entry.user_id) continue
            const timeDiff = Math.abs(new Date(first.created_at).getTime() - new Date(entry.created_at).getTime())
            if (timeDiff <= 10 * 60 * 1000) {
              group.push(entry)
              matched = true
              break
            }
          }
          if (!matched) {
            const legacyKey = `legacy-${entry.id}`
            tourMap.set(legacyKey, [entry])
          }
        }
      }

      // Convert groups to TourHistoryEntry
      const result: TourHistoryEntry[] = []
      for (const [tourKey, group] of tourMap) {
        // Sort group entries oldest-first for consistent ordering
        group.sort((a, b) => new Date(a.created_at).getTime() - new Date(b.created_at).getTime())

        const machines = group.map(buildMachineEntry)
        const firstEntry = group[0]!
        const totalAdded = machines.reduce((sum, m) => sum + m.total_added, 0)
        const skipped = machines.filter(m => m.skipped).length

        result.push({
          tour_id: tourKey,
          date: firstEntry.created_at,
          user_display: getUserDisplay(firstEntry),
          user_id: firstEntry.user_id,
          machines,
          total_machines: machines.length,
          total_items_added: totalAdded,
          machines_skipped: skipped,
        })
      }

      // Sort tours newest-first
      result.sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime())

      tours.value = result
    } finally {
      loading.value = false
    }
  }

  return {
    tours,
    loading,
    fetchTours,
  }
}
