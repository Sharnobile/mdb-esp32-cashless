import { ref, computed, useSupabaseClient } from '#imports'
import { useOrganization } from './useOrganization'
import { getProductImageUrl } from './useProducts'

// ─────────────────────────────────────────────────────────────────────────────
// Machine performance analysis
//
// Combines three data sources to surface poorly-performing product slots and
// suggest replacements:
//   • get_machine_insights_kpis  → per-slot units_sold / sell-through / dead-stock
//   • get_product_sales_velocity → fleet-wide avg daily units per product
//   • machine_trays.created_at   → how long a product has occupied the slot
//
// The slot layout (rows / columns / wide slots) is replicated 1:1 from the
// native iOS app (ios/VMflow/Views/Refill/MachineLayoutGrid.swift): a fleet of
// 10-column machines where item_number encodes position as
//   row    = max(0, floor(item_number / 10) - 1)
//   column = item_number % 10
// and a slot's physical width is the gap to the next occupied slot in its row.
// ─────────────────────────────────────────────────────────────────────────────

export type SlotTier = 'empty' | 'testing' | 'dead' | 'weak' | 'ok' | 'strong'

/** Raw per-tray KPI row as returned by get_machine_insights_kpis. */
export interface TrayKpi {
  item_number: number
  product_name: string
  product_id: string | null
  capacity: number
  current_stock: number
  units_sold: number
  revenue_eur: number
  sell_through_pct: number
  avg_daily_units: number
  days_until_empty: number | null
  is_dead_stock: boolean
}

export interface Suggestion {
  product_id: string
  name: string
  image_url: string | null
  /** 'bestseller' = proven fleet-wide performer; 'newcomer' = never sold yet. */
  kind: 'bestseller' | 'newcomer'
  /** Fleet-wide avg daily units (0 for newcomers). */
  velocity: number
}

export interface SlotAnalysis {
  trayId: string
  item_number: number
  row: number
  column: number
  width: number
  product_id: string | null
  product_name: string | null
  image_url: string | null
  capacity: number
  current_stock: number
  units_sold: number
  revenue_eur: number
  sell_through_pct: number
  avg_daily_units: number
  days_until_empty: number | null
  /** Days since the tray (slot) was created — proxy for product tenure. */
  days_in_slot: number | null
  tier: SlotTier
  suggestions: Suggestion[]
}

const COLUMNS_PER_ROW = 10

// ── Pure helpers (exported for unit testing) ────────────────────────────────

/** Map a flat item_number to its (row, column) grid position — iOS parity. */
export function slotRowCol(itemNumber: number): { row: number; column: number } {
  return {
    row: Math.max(0, Math.floor(itemNumber / 10) - 1),
    column: ((itemNumber % 10) + 10) % 10,
  }
}

/**
 * Compute the physical width (in columns) of each slot. A slot spans from its
 * own column to the next occupied slot in the same row; the last slot in a row
 * stretches to the end of the row. Gaps in the item_number sequence therefore
 * widen the preceding slot — matching the iOS layout algorithm.
 */
export function computeSlotWidths(items: number[]): Map<number, number> {
  const byRow = new Map<number, number[]>()
  for (const item of items) {
    const { row } = slotRowCol(item)
    if (!byRow.has(row)) byRow.set(row, [])
    byRow.get(row)!.push(item)
  }
  const widths = new Map<number, number>()
  for (const rowItems of byRow.values()) {
    rowItems.sort((a, b) => a - b)
    for (let i = 0; i < rowItems.length; i++) {
      const item = rowItems[i]!
      const { column } = slotRowCol(item)
      const next = i + 1 < rowItems.length ? rowItems[i + 1]! : null
      const width = next != null ? next - item : COLUMNS_PER_ROW - column
      widths.set(item, Math.max(1, Math.min(COLUMNS_PER_ROW - column, width)))
    }
  }
  return widths
}

export interface ScoreOpts {
  /** Lookback window the KPIs were computed over. */
  days: number
  /** Slots occupied for fewer days than this are kept in a "testing" grace period. */
  gracePeriodDays?: number
  /** sell-through below this (%) is "weak". */
  weakSellThrough?: number
  /** sell-through at/above this (%) is "strong". */
  strongSellThrough?: number
}

/**
 * Classify a slot's performance. Newly-stocked slots (occupied < grace period)
 * that would otherwise score dead/weak are surfaced as "testing" instead, so a
 * product that was only just placed isn't condemned before it has had a fair
 * chance — this is also how brand-new test products are tracked.
 */
export function scoreSlot(
  row: Pick<SlotAnalysis, 'product_id' | 'units_sold' | 'sell_through_pct' | 'days_in_slot'>,
  opts: ScoreOpts,
): SlotTier {
  if (!row.product_id) return 'empty'
  const weak = opts.weakSellThrough ?? 15
  const strong = opts.strongSellThrough ?? 40
  const grace = opts.gracePeriodDays ?? 14

  let base: SlotTier
  if (row.units_sold <= 0) base = 'dead'
  else if (row.sell_through_pct < weak) base = 'weak'
  else if (row.sell_through_pct < strong) base = 'ok'
  else base = 'strong'

  if ((base === 'dead' || base === 'weak') && row.days_in_slot != null && row.days_in_slot < grace) {
    return 'testing'
  }
  return base
}

export interface SuggestionPoolParams {
  products: { id: string; name: string; image_url: string | null; discontinued: boolean }[]
  /** product_id → fleet-wide avg daily units. */
  velocity: Map<string, number>
  /** product_ids already assigned to a slot in this machine. */
  productsInMachine: Set<string>
  maxBestsellers?: number
  maxNewcomers?: number
}

/**
 * Build the shared pool of replacement candidates for a machine:
 *   • bestsellers — products with proven fleet-wide velocity not yet in this machine
 *   • newcomers   — catalogue products that have never sold anywhere (test candidates)
 * Discontinued products and products already present in the machine are excluded.
 */
export function buildSuggestionPool(params: SuggestionPoolParams): {
  bestsellers: Suggestion[]
  newcomers: Suggestion[]
} {
  const maxBest = params.maxBestsellers ?? 5
  const maxNew = params.maxNewcomers ?? 5

  const eligible = params.products.filter(
    p => !p.discontinued && !params.productsInMachine.has(p.id),
  )

  const bestsellers: Suggestion[] = eligible
    .map(p => ({ p, v: params.velocity.get(p.id) ?? 0 }))
    .filter(({ v }) => v > 0)
    .sort((a, b) => b.v - a.v)
    .slice(0, maxBest)
    .map(({ p, v }) => ({ product_id: p.id, name: p.name, image_url: p.image_url, kind: 'bestseller' as const, velocity: v }))

  const newcomers: Suggestion[] = eligible
    .filter(p => (params.velocity.get(p.id) ?? 0) <= 0)
    .sort((a, b) => a.name.localeCompare(b.name))
    .slice(0, maxNew)
    .map(p => ({ product_id: p.id, name: p.name, image_url: p.image_url, kind: 'newcomer' as const, velocity: 0 }))

  return { bestsellers, newcomers }
}

// ── Composable ───────────────────────────────────────────────────────────────

export function useMachineAnalysis() {
  const supabase = useSupabaseClient()
  const { organization } = useOrganization()

  const slots = ref<SlotAnalysis[]>([])
  const rowCount = ref(0)
  const loading = ref(false)
  const error = ref('')
  const days = ref(30)

  let currentMachineId: string | null = null

  const tierCounts = computed(() => {
    const counts: Record<SlotTier, number> = { empty: 0, testing: 0, dead: 0, weak: 0, ok: 0, strong: 0 }
    for (const s of slots.value) counts[s.tier]++
    return counts
  })

  /** Underperforming, replaceable slots, worst first. */
  const weakSlots = computed(() =>
    slots.value
      .filter(s => s.tier === 'dead' || s.tier === 'weak')
      .sort((a, b) => a.sell_through_pct - b.sell_through_pct || a.units_sold - b.units_sold),
  )

  /** Estimated revenue currently "wasted" by dead/weak slots over the window. */
  const lostRevenuePotential = computed(() => {
    // For each weak slot, the gap between its revenue and the median strong-slot
    // revenue is an (intentionally rough) opportunity estimate.
    const strong = slots.value.filter(s => s.tier === 'strong').map(s => s.revenue_eur).sort((a, b) => a - b)
    if (strong.length === 0) return 0
    const median = strong[Math.floor(strong.length / 2)]!
    return weakSlots.value.reduce((sum, s) => sum + Math.max(0, median - s.revenue_eur), 0)
  })

  async function analyze(machineId: string, windowDays = days.value) {
    currentMachineId = machineId
    days.value = windowDays
    loading.value = true
    error.value = ''
    try {
      const companyId = organization.value?.id
      if (!companyId) throw new Error('No organization')

      const [trayRes, kpiRes, velocityRes, productsRes] = await Promise.all([
        (supabase as any)
          .from('machine_trays')
          .select('id, item_number, product_id, capacity, current_stock, created_at, products(name, image_path)')
          .eq('machine_id', machineId)
          .order('item_number'),
        (supabase as any).rpc('get_machine_insights_kpis', {
          p_machine_id: machineId,
          p_company_id: companyId,
          p_days: windowDays,
        }),
        (supabase as any).rpc('get_product_sales_velocity', {
          p_company_id: companyId,
          p_days: windowDays,
        }),
        (supabase as any)
          .from('products')
          .select('id, name, image_path, discontinued')
          .order('name'),
      ])

      if (trayRes.error) throw trayRes.error
      if (kpiRes.error) throw kpiRes.error

      const trays = (trayRes.data ?? []) as any[]

      // KPI rows keyed by slot
      const kpiByItem = new Map<number, TrayKpi>()
      for (const k of (kpiRes.data?.trays ?? []) as any[]) {
        kpiByItem.set(k.item_number, {
          item_number: k.item_number,
          product_name: k.product_name,
          product_id: k.product_id,
          capacity: k.capacity,
          current_stock: k.current_stock,
          units_sold: Number(k.units_sold) || 0,
          revenue_eur: Number(k.revenue_eur) || 0,
          sell_through_pct: Number(k.sell_through_pct) || 0,
          avg_daily_units: Number(k.avg_daily_units) || 0,
          days_until_empty: k.days_until_empty == null ? null : Number(k.days_until_empty),
          is_dead_stock: !!k.is_dead_stock,
        })
      }

      // Fleet-wide velocity map
      const velocity = new Map<string, number>()
      for (const v of (velocityRes.data ?? []) as any[]) {
        if (v.product_id) velocity.set(v.product_id, parseFloat(v.avg_daily_units) || 0)
      }

      // Catalogue
      const products = ((productsRes.data ?? []) as any[]).map(p => ({
        id: p.id,
        name: p.name,
        image_url: p.image_path ? getProductImageUrl(p.image_path) : null,
        discontinued: !!p.discontinued,
      }))

      const productsInMachine = new Set<string>(
        trays.map(t => t.product_id).filter((id: string | null): id is string => !!id),
      )
      const { bestsellers, newcomers } = buildSuggestionPool({ products, velocity, productsInMachine })
      const sharedSuggestions = [...bestsellers.slice(0, 3), ...newcomers.slice(0, 2)]

      const widths = computeSlotWidths(trays.map(t => t.item_number))
      const now = Date.now()

      const result: SlotAnalysis[] = trays.map((t) => {
        const { row, column } = slotRowCol(t.item_number)
        const kpi = kpiByItem.get(t.item_number)
        const daysInSlot = t.created_at
          ? Math.floor((now - new Date(t.created_at).getTime()) / 86_400_000)
          : null
        const partial: SlotAnalysis = {
          trayId: t.id,
          item_number: t.item_number,
          row,
          column,
          width: widths.get(t.item_number) ?? 1,
          product_id: t.product_id ?? null,
          product_name: t.products?.name ?? null,
          image_url: t.products?.image_path ? getProductImageUrl(t.products.image_path) : null,
          capacity: t.capacity ?? 0,
          current_stock: t.current_stock ?? 0,
          units_sold: kpi?.units_sold ?? 0,
          revenue_eur: kpi?.revenue_eur ?? 0,
          sell_through_pct: kpi?.sell_through_pct ?? 0,
          avg_daily_units: kpi?.avg_daily_units ?? 0,
          days_until_empty: kpi?.days_until_empty ?? null,
          days_in_slot: daysInSlot,
          tier: 'empty',
          suggestions: [],
        }
        partial.tier = scoreSlot(partial, { days: windowDays })
        if (partial.tier === 'dead' || partial.tier === 'weak') {
          // Don't suggest the product that's already (under-performing) in the slot
          partial.suggestions = sharedSuggestions.filter(s => s.product_id !== partial.product_id)
        }
        return partial
      })

      slots.value = result
      rowCount.value = result.reduce((max, s) => Math.max(max, s.row + 1), 0)
    } catch (err: unknown) {
      error.value = err instanceof Error ? err.message : 'Failed to analyze machine'
    } finally {
      loading.value = false
    }
  }

  /**
   * Swap the product assigned to a slot. Resets stock to 0 (the old product is
   * physically removed) and re-runs the analysis. The page's tray realtime
   * subscription keeps the Trays & Stock tab in sync automatically.
   */
  async function applySwap(trayId: string, productId: string) {
    if (!currentMachineId) return
    const slot = slots.value.find(s => s.trayId === trayId)
    const { error: updErr } = await (supabase as any)
      .from('machine_trays')
      .update({ product_id: productId, current_stock: 0 })
      .eq('id', trayId)
    if (updErr) throw updErr

    // Best-effort audit log (mirrors useMachineTrays logging shape)
    try {
      const { data: { session } } = await supabase.auth.getSession()
      const u = session?.user ?? null
      const fullName = [u?.user_metadata?.first_name, u?.user_metadata?.last_name].filter(Boolean).join(' ').trim()
      await (supabase as any).from('activity_log').insert({
        company_id: organization.value?.id,
        user_id: u?.id ?? null,
        entity_type: 'stock',
        entity_id: trayId,
        action: 'product_swapped',
        metadata: {
          machine_id: currentMachineId,
          item_number: slot?.item_number ?? null,
          old_product_id: slot?.product_id ?? null,
          old_product_name: slot?.product_name ?? null,
          new_product_id: productId,
          source: 'analysis_swap',
          _user_email: u?.email ?? null,
          _user_display: fullName || u?.email || null,
        },
      })
    } catch { /* non-fatal */ }

    await analyze(currentMachineId, days.value)
  }

  return { slots, rowCount, loading, error, days, tierCounts, weakSlots, lostRevenuePotential, analyze, applySwap }
}
