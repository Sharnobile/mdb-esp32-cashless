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
  product_id: string | null
  products?: { name: string; image_path: string | null } | null
  matched?: { created_at: string } | null
}

/** Pure: derive the removal-reason parts from a suppressed row (no i18n here). */
export function suppressedReasonParts(row: {
  device_created_at: string | null
  received_at: string
  matched?: { created_at: string } | null
}): { clock: 'unsynced' | 'noclock'; gapSeconds: number | null } {
  const clock = row.device_created_at == null ? 'noclock' : 'unsynced'
  let gapSeconds: number | null = null
  const matchedTs = row.matched?.created_at ? Date.parse(row.matched.created_at) : NaN
  if (!Number.isNaN(matchedTs)) {
    gapSeconds = Math.round(Math.abs(Date.parse(row.received_at) - matchedTs) / 1000)
  }
  return { clock, gapSeconds }
}

export type SalesFeedItem =
  | { kind: 'sale'; key: string; ts: number; sale: any }
  | { kind: 'suppressed'; key: string; ts: number; row: any }
export interface SalesFeedDay { key: string; items: SalesFeedItem[]; saleCount: number }

/**
 * Pure: merge real sales + suppressed rows into day groups (days desc, items
 * desc within a day). Suppressed older than nowMs - windowMs are dropped so an
 * old suppressed-only day group can't dangle past the sales window. `dayKey`
 * is injected (the caller passes the SAME locale-based key salesByDay uses, so
 * a suppressed row buckets into the same calendar day as its sibling sale —
 * never use toISOString().slice for the real key, it can differ near midnight).
 * saleCount counts real sales only.
 */
export function buildSalesFeedDays(
  sales: any[],
  suppressed: any[],
  opts: { nowMs: number; windowMs: number; dayKey: (ts: number) => string },
): SalesFeedDay[] {
  const items: SalesFeedItem[] = []
  for (const s of sales) {
    items.push({ kind: 'sale', key: `sale-${s.id}`, ts: Date.parse(s.created_at), sale: s })
  }
  const cutoff = opts.nowMs - opts.windowMs
  for (const r of suppressed) {
    const ts = Date.parse(r.received_at)
    if (ts >= cutoff) items.push({ kind: 'suppressed', key: `sup-${r.id}`, ts, row: r })
  }
  items.sort((a, b) => b.ts - a.ts)
  const days: SalesFeedDay[] = []
  let cur: SalesFeedDay | null = null
  let curKey = ''
  for (const it of items) {
    const k = opts.dayKey(it.ts)
    if (k !== curKey) { curKey = k; cur = { key: k, items: [], saleCount: 0 }; days.push(cur) }
    cur!.items.push(it)
    if (it.kind === 'sale') cur!.saleCount++
  }
  return days
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
        .select('*, products(name, image_path), matched:sales!matched_sale_id(created_at)')
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
    const oldest = rows.value[rows.value.length - 1]?.received_at
    if (!oldest) return
    loading.value = true
    try {
      const { data, error } = await (supabase as any)
        .from('suppressed_sales')
        .select('*, products(name, image_path), matched:sales!matched_sale_id(created_at)')
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

  async function restore(id: string) {
    const { error } = await (supabase as any).rpc('restore_suppressed_sale', { p_suppressed_id: id })
    if (error) throw error
    // Optimistically drop it from the local list (mirrors the delete-sale flow).
    rows.value = rows.value.filter(r => r.id !== id)
  }

  return { rows, loading, hasMore, fetchRows, fetchMore, restore }
}
