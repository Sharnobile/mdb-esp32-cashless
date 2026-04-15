import { describe, it, expect, vi, beforeEach } from 'vitest'
import { ref as vueRef } from 'vue'

// The composable uses bare `ref(...)` via Nuxt auto-import.
// In tests, Nuxt doesn't transform imports, so we expose ref globally.
;(globalThis as any).ref = vueRef

// Per-table fixtures the tests will mutate
const fixtures = {
  products: { data: null as any, error: null as any },
  product_barcodes: { data: [] as any[], error: null as any },
  warehouse_stock_batches: { data: [] as any[], error: null as any },
  product_min_stock: { data: [] as any[], error: null as any },
  machine_trays: { data: [] as any[], error: null as any },
  sales: { data: [] as any[], error: null as any },
  warehouse_transactions: { data: [] as any[], error: null as any },
  users: { data: [] as any[], error: null as any },
  // chart re-fetches sales — use a separate fixture switched in by call order
  sales_chart: { data: [] as any[], error: null as any },
  rpc_kpis: { data: null as any, error: null as any },
}

let salesCallCount = 0 // first sales call = recentSales (limit 50), second = chart

function makeBuilder(tableKey: keyof typeof fixtures) {
  // chainable; resolves on the terminal method (.maybeSingle) or via thenable
  const builder: any = {}
  const chain = ['select', 'eq', 'gt', 'gte', 'in', 'order', 'limit']
  for (const m of chain) builder[m] = vi.fn(() => builder)
  builder.maybeSingle = vi.fn(() => Promise.resolve(fixtures[tableKey]))
  // For bare awaits (non-maybeSingle), make the builder thenable
  builder.then = (resolve: any) => resolve(fixtures[tableKey])
  return builder
}

const mockSupabase = {
  from: vi.fn((table: string) => {
    if (table === 'sales') {
      salesCallCount++
      return makeBuilder(salesCallCount === 1 ? 'sales' : 'sales_chart')
    }
    return makeBuilder(table as keyof typeof fixtures)
  }),
  rpc: vi.fn(() => Promise.resolve(fixtures.rpc_kpis)),
}

vi.mock('#imports', () => {
  const { ref } = require('vue')
  return {
    ref,
    useState: <T,>(_k: string, init?: () => T) => ref(init?.()),
    useSupabaseClient: () => mockSupabase,
  }
})

vi.mock('../useProducts', () => ({
  getProductImageUrl: (p: string) => `https://example.test/${p}`,
}))

import { ref } from 'vue'
import { useProductDetail } from '../useProductDetail'

beforeEach(() => {
  vi.clearAllMocks()
  salesCallCount = 0
  // reset all fixtures to empty/null
  for (const k of Object.keys(fixtures) as (keyof typeof fixtures)[]) {
    if (k === 'products' || k === 'rpc_kpis') fixtures[k] = { data: null, error: null }
    else fixtures[k] = { data: [], error: null }
  }
})

describe('useProductDetail', () => {
  it('happy path: populates all refs from preset fixtures', async () => {
    fixtures.products.data = {
      id: 'p1',
      name: 'Coke',
      sellprice: 2.5,
      description: null,
      category: 'c1',
      image_path: 'p1.jpg',
      discontinued: false,
      product_category: { name: 'Drinks' },
    }
    fixtures.rpc_kpis.data = {
      warehouse_total_qty: 42,
      warehouse_count: 1,
      tray_total_stock: 5,
      tray_total_capacity: 10,
      machine_count: 2,
      sales_today_units: 3,
      sales_today_revenue: 7.5,
      sales_7d_units: 20,
      sales_7d_revenue: 50,
      velocity_units_per_day: 2.85,
      velocity_window_days: 7,
      top_machines: [{ machine_id: 'm1', machine_name: 'M1', units: 10, revenue: 25 }],
    }
    fixtures.warehouse_stock_batches.data = [
      {
        id: 'b1',
        warehouse_id: 'w1',
        batch_number: 'B1',
        expiration_date: '2026-12-31',
        quantity: 42,
        created_at: '2026-04-01T00:00:00Z',
        warehouses: { name: 'WH-1' },
      },
    ]
    fixtures.machine_trays.data = [
      {
        id: 't1',
        machine_id: 'm1',
        item_number: 5,
        current_stock: 5,
        capacity: 10,
        fill_when_below: 3,
        vendingMachine: { name: 'M1' },
      },
    ]
    fixtures.sales.data = [
      {
        id: 100,
        created_at: new Date().toISOString(),
        item_price: 2.5,
        channel: 'cashless',
        machine_id: 'm1',
        vendingMachine: { name: 'M1' },
      },
    ]

    const detail = useProductDetail(ref('p1'))
    await detail.refresh()

    expect(detail.notFound.value).toBe(false)
    expect(detail.product.value?.name).toBe('Coke')
    expect(detail.kpis.value?.warehouse_total_qty).toBe(42)
    expect(detail.warehouseStock.value).toHaveLength(1)
    expect(detail.warehouseStock.value[0]!.total_qty).toBe(42)
    expect(detail.machineTrays.value[0]!.last_sale_at).not.toBeNull() // backfilled from sales
    expect(detail.recentSales.value).toHaveLength(1)
  })

  it('not-found: products.maybeSingle returns null', async () => {
    fixtures.products.data = null
    const detail = useProductDetail(ref('missing'))
    await detail.refresh()
    expect(detail.notFound.value).toBe(true)
    expect(detail.product.value).toBeNull()
    expect(detail.recentSales.value).toEqual([])
  })

  it('user lookup: builds display name from first_name + last_name; null user_id shows dash', async () => {
    fixtures.products.data = {
      id: 'p1',
      name: 'X',
      sellprice: null,
      description: null,
      category: null,
      image_path: null,
      discontinued: false,
      product_category: null,
    }
    fixtures.rpc_kpis.data = {
      warehouse_total_qty: 0,
      warehouse_count: 0,
      tray_total_stock: 0,
      tray_total_capacity: 0,
      machine_count: 0,
      sales_today_units: 0,
      sales_today_revenue: 0,
      sales_7d_units: 0,
      sales_7d_revenue: 0,
      velocity_units_per_day: 0,
      velocity_window_days: 30,
      top_machines: [],
    }
    fixtures.warehouse_transactions.data = [
      {
        id: 't1',
        created_at: '2026-04-10T00:00:00Z',
        transaction_type: 'intake',
        quantity_change: 10,
        quantity_after: 10,
        warehouse_id: 'w1',
        user_id: 'u1',
        notes: null,
        warehouses: { name: 'WH-1' },
      },
      {
        id: 't2',
        created_at: '2026-04-09T00:00:00Z',
        transaction_type: 'refill',
        quantity_change: -5,
        quantity_after: 5,
        warehouse_id: 'w1',
        user_id: null,
        notes: null,
        warehouses: { name: 'WH-1' },
      },
    ]
    fixtures.users.data = [
      { id: 'u1', first_name: 'Anna', last_name: 'Berg', email: 'anna@example.com' },
    ]

    const detail = useProductDetail(ref('p1'))
    await detail.refresh()
    expect(detail.transactions.value[0]!.user_display).toBe('Anna Berg')
    expect(detail.transactions.value[1]!.user_display).toBe('—')
  })

  it('chart bucketing: a sale 3 days ago lands in the correct bucket index', async () => {
    fixtures.products.data = {
      id: 'p1',
      name: 'X',
      sellprice: null,
      description: null,
      category: null,
      image_path: null,
      discontinued: false,
      product_category: null,
    }
    fixtures.rpc_kpis.data = {
      warehouse_total_qty: 0,
      warehouse_count: 0,
      tray_total_stock: 0,
      tray_total_capacity: 0,
      machine_count: 0,
      sales_today_units: 0,
      sales_today_revenue: 0,
      sales_7d_units: 0,
      sales_7d_revenue: 0,
      velocity_units_per_day: 0,
      velocity_window_days: 30,
      top_machines: [],
    }
    const threeDaysAgo = new Date()
    threeDaysAgo.setDate(threeDaysAgo.getDate() - 3)
    threeDaysAgo.setHours(12, 0, 0, 0)
    fixtures.sales_chart.data = [
      { created_at: threeDaysAgo.toISOString(), item_price: 4.0 },
    ]

    const detail = useProductDetail(ref('p1'))
    await detail.refresh()

    // Buckets are 30 days, oldest first. Index 26 is "3 days ago" (29 - 3 = 26).
    expect(detail.chartUnits.value).toHaveLength(30)
    expect(detail.chartUnits.value[26]!.total).toBe(1)
    expect(detail.chartRevenue.value[26]!.total).toBe(4.0)
    // All other buckets are zero
    for (let i = 0; i < 30; i++) {
      if (i === 26) continue
      expect(detail.chartUnits.value[i]!.total).toBe(0)
    }
  })
})
