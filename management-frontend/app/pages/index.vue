<script setup lang="ts">
definePageMeta({ middleware: 'auth' })

import SectionCards from "@/components/SectionCards.vue"
import DashboardMachineList from "@/components/DashboardMachineList.vue"
import DashboardRecentSales from "@/components/DashboardRecentSales.vue"
import DashboardActivityFeed from "@/components/DashboardActivityFeed.vue"
import type { DashboardMachine } from "@/components/DashboardMachineList.vue"
import type { RecentSale } from "@/components/DashboardRecentSales.vue"
import type { ActivityEntry } from "@/components/DashboardActivityFeed.vue"
import { expirationStatus } from '@/composables/useWarehouse'
import { getProductImageUrl } from '@/composables/useProducts'

const supabase = useSupabaseClient()
const { fetchOrganization } = useOrganization()
const { onResume } = useAppResume()

// ── KPI state ─────────────────────────────────────────────────────────────────
const todaySales = ref(0)
const todaySalesCount = ref(0)
const yesterdayRevenue = ref(0)
const weekSales = ref(0)
const lastWeekSales = ref(0)
const monthSales = ref(0)
const lastMonthSales = ref(0)
const machinesOnline = ref(0)
const totalMachines = ref(0)
const stockCritical = ref(0)
const stockLow = ref(0)
const warehouseBelowMin = ref(0)
const warehouseExpiringSoon = ref(0)

// ── Chart + sections ──────────────────────────────────────────────────────────
const dashboardMachines = ref<DashboardMachine[]>([])
const recentSales = ref<RecentSale[]>([])
const recentActivity = ref<ActivityEntry[]>([])


// Re-fetch all dashboard data when app resumes from background (iOS PWA etc.)
onResume(() => loadDashboard())
usePullToRefresh(() => loadDashboard())

// Track realtime channel for cleanup
let realtimeChannel: ReturnType<typeof supabase.channel> | null = null
onUnmounted(() => { if (realtimeChannel) supabase.removeChannel(realtimeChannel) })

onMounted(async () => {
  await fetchOrganization()
  await loadDashboard()

  // Subscribe to live updates
  const channel = supabase
    .channel('dashboard-realtime')
    .on(
      'postgres_changes',
      { event: 'INSERT', schema: 'public', table: 'sales' },
      (payload) => {
        const sale = payload.new as Record<string, any>
        const price = sale.item_price ?? 0

        // Update KPI totals
        const saleDate = new Date(sale.created_at)
        const now = new Date()
        const todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate())
        const weekStart = new Date(now.getTime() - 7 * 24 * 60 * 60 * 1000)
        const monthStart = new Date(now.getFullYear(), now.getMonth(), 1)

        if (saleDate >= todayStart) {
          todaySales.value += price
          todaySalesCount.value += 1
        }
        if (saleDate >= weekStart) weekSales.value += price
        if (saleDate >= monthStart) monthSales.value += price

        // Update machine revenue in list
        if (sale.machine_id) {
          const m = dashboardMachines.value.find(dm => dm.id === sale.machine_id)
          if (m && saleDate >= todayStart) {
            m.today_revenue += price
            m.last_sale_at = sale.created_at
          }
        }

        // Prepend to recent sales (resolve product name async)
        const newSale: RecentSale = {
          id: sale.id,
          created_at: sale.created_at,
          item_price: price,
          item_number: sale.item_number ?? 0,
          channel: sale.channel ?? '',
          machine_name: sale.machine_id
            ? (dashboardMachines.value.find(dm => dm.id === sale.machine_id)?.name ?? null)
            : null,
          product_name: null,
          product_image_url: null,
        }
        // Try to resolve product from machine_trays
        if (sale.machine_id && sale.item_number != null) {
          supabase
            .from('machine_trays')
            .select('products(name, image_path)')
            .eq('machine_id', sale.machine_id)
            .eq('item_number', sale.item_number)
            .maybeSingle()
            .then(({ data }) => {
              const p = (data as any)?.products
              if (p) {
                newSale.product_name = p.name
                newSale.product_image_url = p.image_path ? getProductImageUrl(p.image_path) : null
                recentSales.value = [...recentSales.value]
              }
            })
        }
        recentSales.value.unshift(newSale)
        if (recentSales.value.length > 10) recentSales.value.pop()
      }
    )
    .on(
      'postgres_changes',
      { event: 'UPDATE', schema: 'public', table: 'embeddeds' },
      (payload) => {
        const oldStatus = payload.old?.status
        const newStatus = payload.new?.status
        if (oldStatus === newStatus) return
        const isConnected = (s: string | undefined) => s != null && s !== 'offline'
        const wasConnected = isConnected(oldStatus)
        const nowConnected = isConnected(newStatus)
        if (!wasConnected && nowConnected) machinesOnline.value++
        if (wasConnected && !nowConnected) machinesOnline.value = Math.max(0, machinesOnline.value - 1)

        // Update machine list status
        const embeddedId = payload.new?.id
        if (embeddedId) {
          const m = dashboardMachines.value.find(dm => (dm as any)._embeddedId === embeddedId)
          if (m) m.status = newStatus
        }
      }
    )
    .on(
      'postgres_changes',
      { event: 'INSERT', schema: 'public', table: 'vendingMachine' },
      () => {
        totalMachines.value++
      }
    )
    .on(
      'postgres_changes',
      { event: 'INSERT', schema: 'public', table: 'activity_log' },
      (payload) => {
        const entry = payload.new as ActivityEntry
        const userDisplay = (entry.metadata as any)?._user_display
          || (entry.metadata as any)?._user_email
          || 'System'
        recentActivity.value.unshift({ ...entry, user_display: userDisplay })
        if (recentActivity.value.length > 8) recentActivity.value.pop()
      }
    )
    .subscribe((_status, err) => {
      if (err) console.error('[realtime] dashboard channel error:', err)
    })

  realtimeChannel = channel
})

async function loadDashboard() {
  const now = new Date()
  const todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate()).toISOString()
  const yesterdayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1).toISOString()
  const weekStart = new Date(now.getTime() - 7 * 24 * 60 * 60 * 1000).toISOString()
  const lastWeekStart = new Date(now.getTime() - 14 * 24 * 60 * 60 * 1000).toISOString()
  const thisMonthStart = new Date(now.getFullYear(), now.getMonth(), 1).toISOString()
  const lastMonthStart = new Date(now.getFullYear(), now.getMonth() - 1, 1).toISOString()
  const [
    todaySalesRes,
    yesterdaySalesRes,
    weekSalesRes,
    lastWeekSalesRes,
    monthSalesRes,
    lastMonthSalesRes,
    machinesRes,
    recentSalesRes,
    activityRes,
  ] = await Promise.all([
    supabase.from('sales').select('item_price').gte('created_at', todayStart),
    supabase.from('sales').select('item_price').gte('created_at', yesterdayStart).lt('created_at', todayStart),
    supabase.from('sales').select('item_price').gte('created_at', weekStart),
    supabase.from('sales').select('item_price').gte('created_at', lastWeekStart).lt('created_at', weekStart),
    supabase.from('sales').select('item_price').gte('created_at', thisMonthStart),
    supabase.from('sales').select('item_price').gte('created_at', lastMonthStart).lt('created_at', thisMonthStart),
    supabase.from('vendingMachine').select('id, name, embedded, embeddeds(id, status)'),
    supabase.from('sales').select('id, created_at, item_price, item_number, channel, machine_id').order('created_at', { ascending: false }).limit(10),
    (supabase as any).from('activity_log').select('*').order('created_at', { ascending: false }).limit(8),
  ])

  // ── Revenue KPIs ────────────────────────────────────────────────────────────
  const sumPrices = (rows: any[] | null) => (rows ?? []).reduce((s: number, r: any) => s + (r.item_price ?? 0), 0)

  todaySales.value = sumPrices(todaySalesRes.data)
  todaySalesCount.value = (todaySalesRes.data ?? []).length
  yesterdayRevenue.value = sumPrices(yesterdaySalesRes.data)
  weekSales.value = sumPrices(weekSalesRes.data)
  lastWeekSales.value = sumPrices(lastWeekSalesRes.data)
  monthSales.value = sumPrices(monthSalesRes.data)
  lastMonthSales.value = sumPrices(lastMonthSalesRes.data)

  // ── Machines ────────────────────────────────────────────────────────────────
  const machines = (machinesRes.data ?? []) as {
    id: string; name: string; embedded: string | null
    embeddeds: { id: string; status: string } | null
  }[]
  totalMachines.value = machines.length
  machinesOnline.value = machines.filter(m => m.embeddeds?.status && m.embeddeds.status !== 'offline').length

  // ── Per-machine today's revenue + last sale ─────────────────────────────────
  const machineIds = machines.map(m => m.id)
  let todayPerMachine = new Map<string, { revenue: number; count: number }>()
  let lastSalePerMachine = new Map<string, string>()

  if (machineIds.length > 0) {
    const [todayMachineRes, traysRes, ...lastSaleResults] = await Promise.all([
      supabase.from('sales').select('machine_id, item_price').in('machine_id', machineIds).gte('created_at', todayStart),
      supabase.from('machine_trays').select('machine_id, capacity, current_stock, min_stock').in('machine_id', machineIds),
      ...machines.map(m =>
        supabase.from('sales').select('created_at').eq('machine_id', m.id).order('created_at', { ascending: false }).limit(1).maybeSingle()
      ),
    ])

    // Today's revenue per machine
    for (const row of (todayMachineRes.data ?? []) as { machine_id: string; item_price: number }[]) {
      if (!row.machine_id) continue
      const entry = todayPerMachine.get(row.machine_id) ?? { revenue: 0, count: 0 }
      entry.revenue += row.item_price ?? 0
      entry.count += 1
      todayPerMachine.set(row.machine_id, entry)
    }

    // Last sale per machine
    for (let i = 0; i < machines.length; i++) {
      const saleData = lastSaleResults[i]?.data as { created_at: string } | null
      if (saleData) lastSalePerMachine.set(machines[i]!.id, saleData.created_at)
    }

    // Stock health per machine
    const trayRows = (traysRes.data ?? []) as {
      machine_id: string; capacity: number; current_stock: number; min_stock: number
    }[]
    const stockMap = new Map<string, { total: number; low: number; empty: number; totalStock: number; totalCapacity: number }>()
    for (const tray of trayRows) {
      if (!tray.machine_id) continue
      let entry = stockMap.get(tray.machine_id)
      if (!entry) {
        entry = { total: 0, low: 0, empty: 0, totalStock: 0, totalCapacity: 0 }
        stockMap.set(tray.machine_id, entry)
      }
      entry.total++
      entry.totalStock += tray.current_stock
      entry.totalCapacity += tray.capacity
      if (tray.current_stock === 0) entry.empty++
      else if (tray.min_stock > 0 && tray.current_stock <= tray.min_stock) entry.low++
    }

    // Count stock alerts
    let critCount = 0
    let lowCount = 0
    for (const [, stock] of stockMap) {
      if (stock.empty > 0) critCount++
      else if (stock.low > 0) lowCount++
    }
    stockCritical.value = critCount
    stockLow.value = lowCount

    // Build dashboard machine list (sorted by stock urgency)
    const healthOrder: Record<string, number> = { critical: 0, low: 1, ok: 2 }
    dashboardMachines.value = machines.map(m => {
      const stock = stockMap.get(m.id)
      const health: 'ok' | 'low' | 'critical' = stock
        ? (stock.empty > 0 ? 'critical' : (stock.low > 0 ? 'low' : 'ok'))
        : 'ok'
      const pct = stock && stock.totalCapacity > 0
        ? Math.round((stock.totalStock / stock.totalCapacity) * 100)
        : 100
      const dm: DashboardMachine & { _embeddedId?: string } = {
        id: m.id,
        name: m.name,
        status: m.embeddeds?.status ?? null,
        today_revenue: todayPerMachine.get(m.id)?.revenue ?? 0,
        stock_health: health,
        stock_percent: pct,
        last_sale_at: lastSalePerMachine.get(m.id) ?? null,
        _embeddedId: m.embeddeds?.id,
      }
      return dm
    }).sort((a, b) => {
      const ha = healthOrder[a.stock_health] ?? 2
      const hb = healthOrder[b.stock_health] ?? 2
      if (ha !== hb) return ha - hb
      return b.today_revenue - a.today_revenue
    }).slice(0, 6)
  }

  // ── Warehouse alerts ────────────────────────────────────────────────────────
  const [minStockRes, batchesRes] = await Promise.all([
    supabase.from('product_min_stock').select('product_id, min_quantity'),
    supabase.from('warehouse_stock_batches').select('product_id, quantity, expiration_date').gt('quantity', 0),
  ])

  if (minStockRes.data && batchesRes.data) {
    // Sum warehouse stock per product
    const warehouseStock = new Map<string, number>()
    let expiringSoon = 0
    for (const batch of batchesRes.data as { product_id: string; quantity: number; expiration_date: string | null }[]) {
      warehouseStock.set(batch.product_id, (warehouseStock.get(batch.product_id) ?? 0) + batch.quantity)
      if (batch.expiration_date) {
        const status = expirationStatus(batch.expiration_date)
        if (status === 'critical' || status === 'warning') expiringSoon++
      }
    }

    // Count products below min
    let belowMin = 0
    for (const rule of minStockRes.data as { product_id: string; min_quantity: number }[]) {
      const current = warehouseStock.get(rule.product_id) ?? 0
      if (current < rule.min_quantity) belowMin++
    }
    warehouseBelowMin.value = belowMin
    warehouseExpiringSoon.value = expiringSoon
  }

  // ── Recent sales ───────────────────────────────────────────────────────────
  const rawSales = (recentSalesRes.data ?? []) as {
    id: string; created_at: string; item_price: number; item_number: number
    channel: string; machine_id: string | null
  }[]

  // Build machine name map from already-fetched machines
  const machineNameMap = new Map<string, string>()
  for (const m of machines) machineNameMap.set(m.id, m.name)

  // Resolve product names via machine_trays for sales that have a machine_id
  const saleMachineIds = [...new Set(rawSales.filter(s => s.machine_id).map(s => s.machine_id!))]
  let trayProductMap = new Map<string, { name: string; image_path: string | null }>()
  if (saleMachineIds.length > 0) {
    const { data: trayData } = await supabase
      .from('machine_trays')
      .select('machine_id, item_number, products(name, image_path)')
      .in('machine_id', saleMachineIds)
    for (const t of (trayData ?? []) as { machine_id: string; item_number: number; products: { name: string; image_path: string | null } | null }[]) {
      if (t.products) trayProductMap.set(`${t.machine_id}:${t.item_number}`, { name: t.products.name, image_path: t.products.image_path })
    }
  }

  recentSales.value = rawSales.map(s => {
    const product = s.machine_id ? trayProductMap.get(`${s.machine_id}:${s.item_number}`) : null
    return {
      id: s.id,
      created_at: s.created_at,
      item_price: s.item_price,
      item_number: s.item_number,
      channel: s.channel,
      machine_name: s.machine_id ? (machineNameMap.get(s.machine_id) ?? null) : null,
      product_name: product?.name ?? null,
      product_image_url: product?.image_path ? getProductImageUrl(product.image_path) : null,
    }
  })

  // ── Activity feed ───────────────────────────────────────────────────────────
  recentActivity.value = ((activityRes.data ?? []) as ActivityEntry[]).map(e => ({
    ...e,
    user_display: (e.metadata as any)?._user_display
      || (e.metadata as any)?._user_email
      || (e.user_id ? e.user_id.slice(0, 8) : 'System'),
  }))
}
</script>

<template>
  <div class="flex flex-1 flex-col">
    <div class="@container/main flex flex-1 flex-col gap-2">
      <div class="flex flex-col gap-4 py-4 md:gap-6 md:py-6">
        <!-- KPI Cards -->
        <SectionCards
          :today-sales="todaySales"
          :today-sales-count="todaySalesCount"
          :yesterday-revenue="yesterdayRevenue"
          :week-sales="weekSales"
          :last-week-sales="lastWeekSales"
          :month-sales="monthSales"
          :last-month-sales="lastMonthSales"
          :stock-critical="stockCritical"
          :stock-low="stockLow"
          :warehouse-below-min="warehouseBelowMin"
          :warehouse-expiring-soon="warehouseExpiringSoon"
        />

        <!-- Machines -->
        <div class="px-4 lg:px-6">
          <DashboardMachineList :machines="dashboardMachines" />
        </div>

        <!-- Recent Sales -->
        <div class="px-4 lg:px-6">
          <DashboardRecentSales :sales="recentSales" />
        </div>

        <!-- Activity Feed -->
        <div class="px-4 lg:px-6">
          <DashboardActivityFeed :entries="recentActivity" />
        </div>
      </div>
    </div>
  </div>
</template>
