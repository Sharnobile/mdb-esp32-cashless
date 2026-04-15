# Product Detail View Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a `/products/[id]` detail page that shows master data, stock across warehouses and machines, sales, and history for one product — and wire click-through from every product reference across the app except the refill wizard.

**Architecture:** One new Nuxt page + one new composable + one additive Supabase RPC + one extracted modal (`ProductFormModal.vue`). Single scrollable page, no tabs. Click-through uses `<NuxtLink>` on full rows where no row action exists, or on product name/image where the row already has actions. `/refill` is deliberately excluded. Sales → product resolution uses the stamped `sales.product_id` directly.

**Tech Stack:** Nuxt 4, Vue 3, `@nuxtjs/supabase`, TailwindCSS 4, shadcn-nuxt, `@unovis/vue` (charts via existing `ChartAreaInteractive.vue`), Supabase (Postgres + RLS + RPC), Vitest for unit tests, Deno for RPC tests.

**Spec:** [2026-04-14-product-detail-view-design.md](../specs/2026-04-14-product-detail-view-design.md)

**Reference prior art:**
- `management-frontend/app/pages/machines/[id].vue` — detail-page pattern
- `management-frontend/app/composables/useMachines.ts` — composable pattern with `Promise.all` fan-out
- `management-frontend/app/composables/__tests__/useMachines.test.ts` — composable test pattern
- `Docker/supabase/migrations/20260412000000_sales_product_id_snapshot.sql` — trigger that stamps `sales.product_id`

**Schema facts the plan relies on:**
- `sales.product_id uuid` nullable, FK → products(id) ON DELETE SET NULL. Stamped at INSERT by trigger. Old rows backfilled best-effort.
- `product_barcodes(id, product_id, barcode, format, company_id)`.
- `warehouse_stock_batches(id, warehouse_id, product_id, batch_number, expiration_date, quantity, company_id)`.
- `machine_trays(id, machine_id, item_number, product_id, capacity, current_stock)` — nullable `product_id`. `fill_when_below` added in a later migration (see `useMachineTrays`).
- `warehouse_transactions(id, created_at, company_id, warehouse_id, product_id, batch_id, user_id → auth.users(id), transaction_type, quantity_change, quantity_before, quantity_after, batch_number, expiration_date, reference_id, notes, metadata)`. **Important:** `user_id` points at `auth.users`, not `public.users`. PostgREST cannot embed `public.users` through this FK. Use a second query keyed by `user_id IN (…)` against `public.users(id, first_name, last_name, email)`.
- `product_min_stock(product_id, warehouse_id, min_quantity)` — column is `min_quantity`, not `min_qty`.
- `public.users(id, first_name, last_name, email)` — no `display_name` column. Build display name client-side: `first_name + ' ' + last_name`, fallback to `email`.
- `companies.velocity_days` int, default 30.

**Branching strategy:** Each chunk commits independently. The refactor (Chunk 1 Task 2) and the RPC migration (Chunk 1 Task 1) are safe to merge on their own — they don't make the product detail page reachable yet. Task 4 creates the route but there is no link pointing to it until Chunk 3. So every intermediate commit leaves the app in a working state.

---

## Chunk 1: Foundation (RPC, modal extraction, composable, page shell)

### Task 1: Add `get_product_detail_kpis` RPC migration

Serverside aggregate so the page doesn't spam the DB. Bundles KPIs **and** the top-machines ranking (30-day window, aggregated over all sales for the product — not biased by any client-side LIMIT).

**Files:**
- Create: `Docker/supabase/migrations/20260414120000_product_detail_kpis.sql`

- [ ] **Step 1: Write the migration**

```sql
-- Aggregates for the product detail page:
--   - totals across warehouses and trays
--   - sales today / last 7 days (units + revenue)
--   - velocity (units/day over companies.velocity_days)
--   - top machines by units sold over last 30 days
--
-- SECURITY DEFINER + explicit company check: RLS on sales already scopes
-- via machine_id → vendingMachine.company, but we verify the product's
-- company matches the caller's before any aggregation runs.
-- Additive-only — no existing callers affected.

CREATE OR REPLACE FUNCTION public.get_product_detail_kpis(
  p_product_id uuid,
  p_days int DEFAULT 30
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_company_id    uuid;
  v_caller_co     uuid := public.my_company_id();
  v_velocity_days int;
  v_result        jsonb;
BEGIN
  -- Guard: product must belong to caller's company
  SELECT p.company INTO v_company_id
  FROM public.products p
  WHERE p.id = p_product_id;

  IF v_company_id IS NULL OR v_company_id <> v_caller_co THEN
    RAISE EXCEPTION 'product not found or access denied';
  END IF;

  -- Velocity window (company setting, fallback 30)
  SELECT COALESCE(c.velocity_days, 30) INTO v_velocity_days
  FROM public.companies c
  WHERE c.id = v_caller_co;

  WITH
    wh AS (
      SELECT
        COALESCE(SUM(b.quantity), 0)::bigint                  AS warehouse_total_qty,
        COUNT(DISTINCT b.warehouse_id)::int                   AS warehouse_count
      FROM public.warehouse_stock_batches b
      WHERE b.product_id = p_product_id
        AND b.quantity > 0
    ),
    tr AS (
      SELECT
        COALESCE(SUM(mt.current_stock), 0)::bigint            AS tray_total_stock,
        COALESCE(SUM(mt.capacity), 0)::bigint                 AS tray_total_capacity,
        COUNT(DISTINCT mt.machine_id)::int                    AS machine_count
      FROM public.machine_trays mt
      WHERE mt.product_id = p_product_id
    ),
    s_today AS (
      SELECT
        COUNT(*)::bigint                                      AS units,
        COALESCE(SUM(s.item_price), 0)::numeric               AS revenue
      FROM public.sales s
      WHERE s.product_id = p_product_id
        AND s.created_at >= date_trunc('day', now())
    ),
    s_7d AS (
      SELECT
        COUNT(*)::bigint                                      AS units,
        COALESCE(SUM(s.item_price), 0)::numeric               AS revenue
      FROM public.sales s
      WHERE s.product_id = p_product_id
        AND s.created_at >= now() - interval '7 days'
    ),
    s_velocity AS (
      SELECT
        CASE WHEN v_velocity_days > 0
          THEN COUNT(*)::numeric / v_velocity_days
          ELSE 0
        END                                                   AS units_per_day
      FROM public.sales s
      WHERE s.product_id = p_product_id
        AND s.created_at >= now() - (v_velocity_days || ' days')::interval
    ),
    s_top AS (
      SELECT
        vm.id                                                 AS machine_id,
        vm.name                                               AS machine_name,
        COUNT(*)::bigint                                      AS units,
        COALESCE(SUM(s.item_price), 0)::numeric               AS revenue
      FROM public.sales s
      JOIN public."vendingMachine" vm ON vm.id = s.machine_id
      WHERE s.product_id = p_product_id
        AND s.created_at >= now() - (p_days || ' days')::interval
        AND s.machine_id IS NOT NULL
      GROUP BY vm.id, vm.name
      ORDER BY units DESC
      LIMIT 10
    )
  SELECT jsonb_build_object(
    'warehouse_total_qty',      (SELECT warehouse_total_qty FROM wh),
    'warehouse_count',          (SELECT warehouse_count FROM wh),
    'tray_total_stock',         (SELECT tray_total_stock FROM tr),
    'tray_total_capacity',      (SELECT tray_total_capacity FROM tr),
    'machine_count',            (SELECT machine_count FROM tr),
    'sales_today_units',        (SELECT units FROM s_today),
    'sales_today_revenue',      (SELECT revenue FROM s_today),
    'sales_7d_units',           (SELECT units FROM s_7d),
    'sales_7d_revenue',         (SELECT revenue FROM s_7d),
    'velocity_units_per_day',   (SELECT units_per_day FROM s_velocity),
    'velocity_window_days',     v_velocity_days,
    'top_machines',             COALESCE(
      (SELECT jsonb_agg(jsonb_build_object(
        'machine_id',   machine_id,
        'machine_name', machine_name,
        'units',        units,
        'revenue',      revenue
      )) FROM s_top),
      '[]'::jsonb
    )
  ) INTO v_result;

  RETURN v_result;
END
$$;

GRANT EXECUTE ON FUNCTION public.get_product_detail_kpis(uuid, int) TO authenticated;
```

- [ ] **Step 2: Apply the migration locally**

```bash
cd Docker/supabase && supabase migration up
```

Expected: "Applying migration 20260414120000_product_detail_kpis.sql..." then no errors.

- [ ] **Step 3: Smoke-test the RPC**

Use a real product id from your local dev DB (check via Studio at http://localhost:54323):

```bash
curl -s -X POST 'http://127.0.0.1:54321/rest/v1/rpc/get_product_detail_kpis' \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Authorization: Bearer $USER_JWT" \
  -H "Content-Type: application/json" \
  -d '{"p_product_id":"<UUID>","p_days":30}' | jq .
```

Expected: a JSON object with all keys above and `top_machines` as an array.

- [ ] **Step 4: Commit**

```bash
git add Docker/supabase/migrations/20260414120000_product_detail_kpis.sql
git commit -m "feat(db): add get_product_detail_kpis RPC for product detail page"
```

---

### Task 2: Extract `ProductFormModal.vue` (pure refactor)

The add/edit product modal is currently inline in `/products/index.vue` (1041 LOC). Pull it out so the detail page can reuse it. Behaviour must not change.

**Files:**
- Create: `management-frontend/app/components/ProductFormModal.vue`
- Modify: `management-frontend/app/pages/products/index.vue` — remove the inline `<AppModal>` block for the product form, replace with `<ProductFormModal>`.

- [ ] **Step 1: Read the source range to understand what to pull**

Read lines 1-250 and 580-820 of `management-frontend/app/pages/products/index.vue` to scope the modal + its reactive state (productForm, imagePreview, pendingBarcodes, editingProduct, submitProduct, onImageSelected, clearImage, image-search state).

- [ ] **Step 2: Create `ProductFormModal.vue` with the following contract**

```ts
// Props
defineProps<{
  open: boolean
  productId?: string | null   // null/undefined = create mode, uuid = edit mode
}>()

// Emits
defineEmits<{
  'update:open': [value: boolean]
  'saved': [productId: string]   // fires after successful create or update
}>()
```

The modal owns all local state that was previously on `/products/index.vue`: `productForm`, `imagePreview`, `pendingBarcodes`, `removeImage`, `searchingImages`, `suggestedImages`, `onImageSelected`, `clearImage`, `selectSuggestedImage`, barcode add/remove for pending + existing. It resolves `editingProduct` from `productId` by looking it up in the `useProducts()` store.

It wraps `<AppModal>` and keeps the same form markup. When the user submits, it calls the same `createProduct`/`updateProduct`/`uploadProductImage`/`addBarcode` functions from `useProducts()`/`useWarehouse()`, then emits `saved` + `update:open=false`.

Keep the i18n keys (`products.editProduct`, `products.addProduct`, `products.productName`, etc.) — no new keys for this task.

- [ ] **Step 3: Replace the inline modal in `/products/index.vue`**

- Remove lines 584–end-of-modal in the `<template>` and swap for:
  ```vue
  <ProductFormModal
    v-model:open="showProductModal"
    :product-id="editingProduct?.id ?? null"
    @saved="onProductSaved"
  />
  ```
- Delete the corresponding state and handlers that have moved into the modal component (productForm, imagePreview, pendingBarcodes, submitProduct, onImageSelected, clearImage, selectSuggestedImage, barcode-add/remove state).
- Keep: `showProductModal`, `editingProduct`, `openCreateModal()`, `openEditModal(product)`. Add `onProductSaved(id)` that just calls `fetchProducts()`.

- [ ] **Step 4: Manually verify /products still works**

```bash
cd management-frontend && npm run dev
```

Open http://localhost:3000/products and:
- Add a new product with image and category. Confirm it shows up in the list.
- Edit an existing product (change price, swap image, add a barcode). Confirm the change persists after reload.
- Delete a product. Confirm it's gone.

- [ ] **Step 5: Commit**

```bash
git add management-frontend/app/components/ProductFormModal.vue management-frontend/app/pages/products/index.vue
git commit -m "refactor(products): extract ProductFormModal for reuse"
```

---

### Task 3: Create `useProductDetail` composable

Data layer for the detail page. Fans out with `Promise.all`, returns reactive refs + `refresh()`. No realtime subscriptions.

**Files:**
- Create: `management-frontend/app/composables/useProductDetail.ts`

- [ ] **Step 1: Write the composable**

```ts
import { useSupabaseClient } from '#imports'
import type { Ref } from 'vue'
import { getProductImageUrl } from './useProducts'

export interface ProductDetail {
  id: string
  name: string
  sellprice: number | null
  description: string | null
  category: string | null
  category_name: string | null
  image_path: string | null
  image_url: string | null
  discontinued: boolean
}

export interface ProductBarcode {
  id: string
  barcode: string
  format: string
}

export interface ProductKpis {
  warehouse_total_qty: number
  warehouse_count: number
  tray_total_stock: number
  tray_total_capacity: number
  machine_count: number
  sales_today_units: number
  sales_today_revenue: number
  sales_7d_units: number
  sales_7d_revenue: number
  velocity_units_per_day: number
  velocity_window_days: number
  top_machines: Array<{ machine_id: string; machine_name: string; units: number; revenue: number }>
}

export interface WarehouseStockEntry {
  warehouse_id: string
  warehouse_name: string
  total_qty: number
  min_quantity: number | null
  batches: Array<{
    id: string
    batch_number: string | null
    expiration_date: string | null
    quantity: number
    created_at: string
  }>
}

export interface MachineTrayEntry {
  id: string
  machine_id: string
  machine_name: string
  item_number: number
  current_stock: number
  capacity: number
  fill_when_below: number | null
  last_sale_at: string | null
}

export interface RecentSaleEntry {
  id: number
  created_at: string
  item_price: number | null
  channel: string | null
  machine_id: string | null
  machine_name: string | null
}

export interface TransactionEntry {
  id: string
  created_at: string
  transaction_type: string
  quantity_change: number
  quantity_after: number | null
  warehouse_id: string
  warehouse_name: string
  user_id: string | null
  user_display: string   // built client-side: first_name+last_name || email || '—'
  notes: string | null
}

export interface SalesByDay { date: Date; total: number }

export function useProductDetail(productId: Ref<string>) {
  const supabase = useSupabaseClient()

  const product = ref<ProductDetail | null>(null)
  const barcodes = ref<ProductBarcode[]>([])
  const kpis = ref<ProductKpis | null>(null)
  const warehouseStock = ref<WarehouseStockEntry[]>([])
  const machineTrays = ref<MachineTrayEntry[]>([])
  const recentSales = ref<RecentSaleEntry[]>([])
  const transactions = ref<TransactionEntry[]>([])
  const chartRevenue = ref<SalesByDay[]>([])
  const chartUnits = ref<SalesByDay[]>([])

  const loading = ref(false)
  const notFound = ref(false)
  const error = ref<string | null>(null)

  async function refresh() {
    if (!productId.value) return
    loading.value = true
    notFound.value = false
    error.value = null

    try {
      const [
        productRes,
        barcodesRes,
        kpisRes,
        batchesRes,
        minStockRes,
        traysRes,
        salesRes,
        transactionsRes,
      ] = await Promise.all([
        supabase
          .from('products')
          .select('id, name, sellprice, description, category, image_path, discontinued, product_category(name)')
          .eq('id', productId.value)
          .maybeSingle(),
        supabase
          .from('product_barcodes')
          .select('id, barcode, format')
          .eq('product_id', productId.value)
          .order('created_at'),
        supabase.rpc('get_product_detail_kpis', {
          p_product_id: productId.value,
          p_days: 30,
        }),
        supabase
          .from('warehouse_stock_batches')
          .select('id, warehouse_id, batch_number, expiration_date, quantity, created_at, warehouses(name)')
          .eq('product_id', productId.value)
          .gt('quantity', 0)
          .order('expiration_date', { ascending: true, nullsFirst: false }),
        supabase
          .from('product_min_stock')
          .select('warehouse_id, min_quantity')
          .eq('product_id', productId.value),
        supabase
          .from('machine_trays')
          .select('id, machine_id, item_number, current_stock, capacity, fill_when_below, vendingMachine(name)')
          .eq('product_id', productId.value),
        supabase
          .from('sales')
          .select('id, created_at, item_price, channel, machine_id, vendingMachine(name)')
          .eq('product_id', productId.value)
          .order('created_at', { ascending: false })
          .limit(50),
        supabase
          .from('warehouse_transactions')
          .select('id, created_at, transaction_type, quantity_change, quantity_after, warehouse_id, user_id, notes, warehouses(name)')
          .eq('product_id', productId.value)
          .order('created_at', { ascending: false })
          .limit(50),
      ])

      // Product itself (triggers not-found early)
      if (productRes.error) throw productRes.error
      if (!productRes.data) {
        notFound.value = true
        return
      }
      const p: any = productRes.data
      product.value = {
        id: p.id,
        name: p.name,
        sellprice: p.sellprice,
        description: p.description,
        category: p.category,
        category_name: p.product_category?.name ?? null,
        image_path: p.image_path,
        image_url: p.image_path ? getProductImageUrl(p.image_path) : null,
        discontinued: p.discontinued ?? false,
      }

      if (barcodesRes.error) throw barcodesRes.error
      barcodes.value = (barcodesRes.data ?? []) as ProductBarcode[]

      if (kpisRes.error) throw kpisRes.error
      kpis.value = kpisRes.data as ProductKpis

      // Warehouse stock: group batches by warehouse, join min_quantity
      if (batchesRes.error) throw batchesRes.error
      if (minStockRes.error) throw minStockRes.error
      const minByWarehouse = new Map<string, number>()
      for (const row of (minStockRes.data ?? []) as Array<{ warehouse_id: string; min_quantity: number }>) {
        minByWarehouse.set(row.warehouse_id, row.min_quantity)
      }
      const byWarehouse = new Map<string, WarehouseStockEntry>()
      for (const row of (batchesRes.data ?? []) as any[]) {
        const wid = row.warehouse_id
        if (!byWarehouse.has(wid)) {
          byWarehouse.set(wid, {
            warehouse_id: wid,
            warehouse_name: row.warehouses?.name ?? '—',
            total_qty: 0,
            min_quantity: minByWarehouse.get(wid) ?? null,
            batches: [],
          })
        }
        const w = byWarehouse.get(wid)!
        w.total_qty += row.quantity
        w.batches.push({
          id: row.id,
          batch_number: row.batch_number,
          expiration_date: row.expiration_date,
          quantity: row.quantity,
          created_at: row.created_at,
        })
      }
      warehouseStock.value = [...byWarehouse.values()]

      if (traysRes.error) throw traysRes.error
      machineTrays.value = ((traysRes.data ?? []) as any[]).map((t) => ({
        id: t.id,
        machine_id: t.machine_id,
        machine_name: t.vendingMachine?.name ?? '—',
        item_number: t.item_number,
        current_stock: t.current_stock,
        capacity: t.capacity,
        fill_when_below: t.fill_when_below ?? null,
        last_sale_at: null,  // filled below
      }))

      if (salesRes.error) throw salesRes.error
      const sales = ((salesRes.data ?? []) as any[])
      recentSales.value = sales.map((s) => ({
        id: s.id,
        created_at: s.created_at,
        item_price: s.item_price,
        channel: s.channel,
        machine_id: s.machine_id,
        machine_name: s.vendingMachine?.name ?? null,
      }))

      // Fill last_sale_at per tray by scanning the recent-sales window
      const lastSaleByMachine = new Map<string, string>()
      for (const s of sales) {
        if (s.machine_id && !lastSaleByMachine.has(s.machine_id)) {
          lastSaleByMachine.set(s.machine_id, s.created_at)
        }
      }
      for (const t of machineTrays.value) {
        t.last_sale_at = lastSaleByMachine.get(t.machine_id) ?? null
      }

      // Transactions + separate user lookup (FK points at auth.users, can't embed public.users)
      if (transactionsRes.error) throw transactionsRes.error
      const txRows = (transactionsRes.data ?? []) as any[]
      const userIds = [...new Set(txRows.map((r) => r.user_id).filter(Boolean))]
      const users = new Map<string, string>()
      if (userIds.length > 0) {
        const { data: userRows, error: usersErr } = await supabase
          .from('users')
          .select('id, first_name, last_name, email')
          .in('id', userIds)
        if (usersErr) throw usersErr
        for (const u of (userRows ?? []) as any[]) {
          const name = [u.first_name, u.last_name].filter(Boolean).join(' ').trim()
          users.set(u.id, name || u.email || '—')
        }
      }
      transactions.value = txRows.map((r) => ({
        id: r.id,
        created_at: r.created_at,
        transaction_type: r.transaction_type,
        quantity_change: r.quantity_change,
        quantity_after: r.quantity_after,
        warehouse_id: r.warehouse_id,
        warehouse_name: r.warehouses?.name ?? '—',
        user_id: r.user_id,
        user_display: r.user_id ? (users.get(r.user_id) ?? '—') : '—',
        notes: r.notes,
      }))

      // Chart: bucket the last 30 days of sales into per-day revenue + units
      const now = new Date()
      const buckets = new Map<string, { revenue: number; units: number }>()
      for (let i = 29; i >= 0; i--) {
        const d = new Date(now)
        d.setHours(0, 0, 0, 0)
        d.setDate(d.getDate() - i)
        buckets.set(d.toISOString().slice(0, 10), { revenue: 0, units: 0 })
      }
      // Use a wider fetch than recentSales (which is LIMIT 50) — separate query
      const since = new Date()
      since.setDate(since.getDate() - 30)
      since.setHours(0, 0, 0, 0)
      const { data: chartRows, error: chartErr } = await supabase
        .from('sales')
        .select('created_at, item_price')
        .eq('product_id', productId.value)
        .gte('created_at', since.toISOString())
      if (chartErr) throw chartErr
      for (const row of (chartRows ?? []) as Array<{ created_at: string; item_price: number | null }>) {
        const key = row.created_at.slice(0, 10)
        const b = buckets.get(key)
        if (!b) continue
        b.units += 1
        b.revenue += row.item_price ?? 0
      }
      chartRevenue.value = [...buckets.entries()].map(([k, v]) => ({ date: new Date(k), total: v.revenue }))
      chartUnits.value = [...buckets.entries()].map(([k, v]) => ({ date: new Date(k), total: v.units }))
    } catch (e: any) {
      error.value = e?.message ?? 'failed to load product detail'
      throw e
    } finally {
      loading.value = false
    }
  }

  return {
    product,
    barcodes,
    kpis,
    warehouseStock,
    machineTrays,
    recentSales,
    transactions,
    chartRevenue,
    chartUnits,
    loading,
    notFound,
    error,
    refresh,
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add management-frontend/app/composables/useProductDetail.ts
git commit -m "feat(products): add useProductDetail composable"
```

---

### Task 4: Create `/products/[id].vue` page shell

Empty shell that loads the composable, shows not-found state, wires back button. No sections yet — just header + a "loading" placeholder body. Keeps this commit small and independently reviewable.

**Files:**
- Create: `management-frontend/app/pages/products/[id].vue`

- [ ] **Step 1: Write the page**

```vue
<script setup lang="ts">
definePageMeta({ middleware: 'auth' })

import { useProductDetail } from '~/composables/useProductDetail'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { IconArrowLeft, IconPencil } from '@tabler/icons-vue'

const { t } = useI18n()
const route = useRoute()
const router = useRouter()

const productId = computed(() => route.params.id as string)
const detail = useProductDetail(productId)

const editModalOpen = ref(false)

onMounted(() => detail.refresh())
watch(productId, () => detail.refresh())

function goBack() {
  if (window.history.length > 1) router.back()
  else router.push('/products')
}

function onEditSaved() {
  editModalOpen.value = false
  detail.refresh()
}
</script>

<template>
  <div class="container mx-auto max-w-6xl px-4 py-6 space-y-6">
    <!-- Header -->
    <div class="flex items-start gap-3">
      <Button variant="ghost" size="icon" @click="goBack">
        <IconArrowLeft class="size-5" />
      </Button>

      <template v-if="detail.loading.value && !detail.product.value">
        <div class="h-16 flex-1 animate-pulse rounded-md bg-muted" />
      </template>

      <template v-else-if="detail.notFound.value">
        <div class="flex-1 rounded-md border border-destructive/20 bg-destructive/5 p-4">
          <p class="font-medium">{{ t('products.detail.notFound.title') }}</p>
          <NuxtLink to="/products" class="mt-1 inline-block text-sm underline">
            {{ t('products.detail.notFound.back') }}
          </NuxtLink>
        </div>
      </template>

      <template v-else-if="detail.product.value">
        <img
          v-if="detail.product.value.image_url"
          :src="detail.product.value.image_url"
          :alt="detail.product.value.name"
          class="size-16 rounded-md object-cover border"
        />
        <div v-else class="size-16 rounded-md border bg-muted" />

        <div class="flex-1">
          <div class="flex items-center gap-2">
            <h1 class="text-2xl font-semibold">{{ detail.product.value.name }}</h1>
            <Badge v-if="detail.product.value.discontinued" variant="secondary">
              {{ t('products.detail.header.discontinued') }}
            </Badge>
          </div>
          <p v-if="detail.product.value.category_name" class="text-sm text-muted-foreground">
            {{ detail.product.value.category_name }}
          </p>
          <div v-if="detail.barcodes.value.length" class="mt-1 flex flex-wrap gap-1">
            <span
              v-for="b in detail.barcodes.value"
              :key="b.id"
              class="rounded-full border bg-muted/50 px-2 py-0.5 text-xs font-mono"
            >
              {{ b.barcode }}
            </span>
          </div>
        </div>

        <Button variant="outline" @click="editModalOpen = true">
          <IconPencil class="mr-2 size-4" />
          {{ t('products.detail.header.edit') }}
        </Button>
      </template>
    </div>

    <!-- Sections will be added in Chunk 2 -->
    <div v-if="detail.product.value" class="rounded-md border border-dashed p-8 text-center text-sm text-muted-foreground">
      Sections coming in the next chunk.
    </div>

    <ProductFormModal
      v-model:open="editModalOpen"
      :product-id="productId"
      @saved="onEditSaved"
    />
  </div>
</template>
```

- [ ] **Step 2: Add the three minimal i18n keys this shell needs**

Edit `management-frontend/i18n/locales/en.json` and `de.json`. Find the `products` block and add:

```json
"detail": {
  "notFound": {
    "title": "Product not found",
    "back": "Back to products"
  },
  "header": {
    "discontinued": "Discontinued",
    "edit": "Edit"
  }
}
```

German:

```json
"detail": {
  "notFound": {
    "title": "Produkt nicht gefunden",
    "back": "Zurück zu Produkten"
  },
  "header": {
    "discontinued": "Ausgelaufen",
    "edit": "Bearbeiten"
  }
}
```

(Full i18n set is added in Chunk 2 Task 12.)

- [ ] **Step 3: Manually verify the shell**

Still in `npm run dev`. Pick a real product id from your DB and visit `http://localhost:3000/products/<uuid>`. Confirm:
- Header renders with name, category, barcodes, image.
- Edit button opens the extracted `ProductFormModal`; saving refreshes the page.
- Back button returns to the previous page.
- Visiting `/products/00000000-0000-0000-0000-000000000000` shows the not-found state.

- [ ] **Step 4: Commit**

```bash
git add management-frontend/app/pages/products/\[id\].vue management-frontend/i18n/locales/en.json management-frontend/i18n/locales/de.json
git commit -m "feat(products): add detail page shell with header and not-found state"
```

---

## Chunk 2: Page sections (KPIs, chart, stock, trays, top, sales, history, i18n)

All tasks in this chunk edit `management-frontend/app/pages/products/[id].vue` (inserting sections into the body, replacing the placeholder) and add i18n keys. Each task produces a small visible section.

### Task 5: KPI row (4 cards)

**Files:**
- Modify: `management-frontend/app/pages/products/[id].vue`

- [ ] **Step 1: Import shadcn Card components and formatters**

Add to script-setup:
```ts
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { formatCurrency } from '~/lib/utils'
```

- [ ] **Step 2: Insert the KPI row before the placeholder**

```vue
<div v-if="detail.kpis.value" class="grid grid-cols-2 gap-3 md:grid-cols-4">
  <Card>
    <CardHeader class="pb-2"><CardTitle class="text-sm font-medium text-muted-foreground">{{ t('products.detail.kpi.warehouseStock') }}</CardTitle></CardHeader>
    <CardContent>
      <div class="text-2xl font-semibold">{{ detail.kpis.value.warehouse_total_qty }}</div>
      <p class="text-xs text-muted-foreground">{{ t('products.detail.kpi.warehouseCount', { n: detail.kpis.value.warehouse_count }) }}</p>
    </CardContent>
  </Card>
  <Card>
    <CardHeader class="pb-2"><CardTitle class="text-sm font-medium text-muted-foreground">{{ t('products.detail.kpi.machineStock') }}</CardTitle></CardHeader>
    <CardContent>
      <div class="text-2xl font-semibold">{{ detail.kpis.value.tray_total_stock }} / {{ detail.kpis.value.tray_total_capacity }}</div>
      <p class="text-xs text-muted-foreground">{{ t('products.detail.kpi.machineCount', { n: detail.kpis.value.machine_count }) }}</p>
    </CardContent>
  </Card>
  <Card>
    <CardHeader class="pb-2"><CardTitle class="text-sm font-medium text-muted-foreground">{{ t('products.detail.kpi.salesToday') }}</CardTitle></CardHeader>
    <CardContent>
      <div class="text-2xl font-semibold">{{ detail.kpis.value.sales_today_units }}</div>
      <p class="text-xs text-muted-foreground">{{ formatCurrency(detail.kpis.value.sales_today_revenue) }}</p>
    </CardContent>
  </Card>
  <Card>
    <CardHeader class="pb-2"><CardTitle class="text-sm font-medium text-muted-foreground">{{ t('products.detail.kpi.velocity') }}</CardTitle></CardHeader>
    <CardContent>
      <div class="text-2xl font-semibold">{{ detail.kpis.value.velocity_units_per_day.toFixed(1) }}</div>
      <p class="text-xs text-muted-foreground">{{ t('products.detail.kpi.velocitySubtitle', { n: detail.kpis.value.velocity_window_days }) }}</p>
    </CardContent>
  </Card>
</div>
```

Also add the new i18n keys (`kpi.warehouseStock`, `kpi.warehouseCount`, `kpi.machineStock`, `kpi.machineCount`, `kpi.salesToday`, `kpi.velocity`, `kpi.velocitySubtitle`). See Task 12 for the consolidated set; for now add just these.

- [ ] **Step 3: Visually verify; commit**

```bash
git commit -am "feat(products): add KPI row on detail page"
```

---

### Task 6: 30-day chart

Reuse `ChartAreaInteractive.vue` which expects `SalesByDay[]` (`{ date, total }`). We have two series (revenue, units) — render them as two side-by-side chart cards, each with its own data. Simpler than adding a mode toggle.

**Files:**
- Modify: `management-frontend/app/pages/products/[id].vue`

- [ ] **Step 1: Insert the chart row after the KPI row**

```vue
<div v-if="detail.product.value" class="grid gap-3 md:grid-cols-2">
  <ChartAreaInteractive
    :data="detail.chartRevenue.value"
    :title="t('products.detail.chart.revenueTitle')"
    :description="t('products.detail.chart.revenueDescription')"
  />
  <ChartAreaInteractive
    :data="detail.chartUnits.value"
    :title="t('products.detail.chart.unitsTitle')"
    :description="t('products.detail.chart.unitsDescription')"
  />
</div>
```

Nuxt auto-imports components in `app/components/`, no explicit import needed.

- [ ] **Step 2: Commit**

```bash
git commit -am "feat(products): add 30-day revenue and units charts"
```

---

### Task 7: Warehouse stock section

**Files:**
- Modify: `management-frontend/app/pages/products/[id].vue`

- [ ] **Step 1: Insert the warehouse section**

```vue
<section class="space-y-2" aria-labelledby="sec-warehouse">
  <h2 id="sec-warehouse" class="text-lg font-semibold">{{ t('products.detail.sections.warehouseStock') }}</h2>
  <p v-if="!detail.warehouseStock.value.length" class="text-sm text-muted-foreground">
    {{ t('products.detail.empty.noStock') }}
  </p>
  <div v-else class="space-y-2">
    <details
      v-for="w in detail.warehouseStock.value"
      :key="w.warehouse_id"
      class="rounded-md border"
    >
      <summary class="flex cursor-pointer items-center justify-between px-3 py-2 text-sm">
        <span class="font-medium">{{ w.warehouse_name }}</span>
        <span class="flex items-center gap-2">
          <span
            v-if="w.min_quantity !== null && w.total_qty < w.min_quantity"
            class="rounded-full bg-destructive/10 px-2 py-0.5 text-xs text-destructive"
          >
            {{ t('products.detail.warehouseStock.belowMin', { min: w.min_quantity }) }}
          </span>
          <span class="font-mono">{{ w.total_qty }}</span>
        </span>
      </summary>
      <table class="w-full border-t text-sm">
        <thead class="bg-muted/40 text-xs uppercase">
          <tr>
            <th class="px-3 py-1.5 text-left">{{ t('products.detail.warehouseStock.batchNumber') }}</th>
            <th class="px-3 py-1.5 text-left">{{ t('products.detail.warehouseStock.expiry') }}</th>
            <th class="px-3 py-1.5 text-left">{{ t('products.detail.warehouseStock.intake') }}</th>
            <th class="px-3 py-1.5 text-right">{{ t('products.detail.warehouseStock.qty') }}</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="b in w.batches" :key="b.id" class="border-t">
            <td class="px-3 py-1.5 font-mono">{{ b.batch_number ?? '—' }}</td>
            <td class="px-3 py-1.5">{{ b.expiration_date ?? '—' }}</td>
            <td class="px-3 py-1.5">{{ formatDate(b.created_at) }}</td>
            <td class="px-3 py-1.5 text-right font-mono">{{ b.quantity }}</td>
          </tr>
        </tbody>
      </table>
    </details>
  </div>
</section>
```

Add `import { formatDate } from '~/lib/utils'` if not already imported.

- [ ] **Step 2: Commit**

```bash
git commit -am "feat(products): add warehouse stock section with FIFO batches"
```

---

### Task 8: Machine trays section

**Files:**
- Modify: `management-frontend/app/pages/products/[id].vue`

- [ ] **Step 1: Insert the section**

```vue
<section class="space-y-2" aria-labelledby="sec-trays">
  <h2 id="sec-trays" class="text-lg font-semibold">{{ t('products.detail.sections.machineTrays') }}</h2>
  <p v-if="!detail.machineTrays.value.length" class="text-sm text-muted-foreground">
    {{ t('products.detail.empty.noTrays') }}
  </p>
  <div v-else class="overflow-x-auto rounded-md border">
    <table class="w-full text-sm">
      <thead class="bg-muted/40 text-xs uppercase">
        <tr>
          <th class="px-3 py-2 text-left">{{ t('products.detail.trays.machine') }}</th>
          <th class="px-3 py-2 text-left">{{ t('products.detail.trays.slot') }}</th>
          <th class="px-3 py-2 text-right">{{ t('products.detail.trays.stock') }}</th>
          <th class="px-3 py-2 text-right">{{ t('products.detail.trays.fillWhenBelow') }}</th>
          <th class="px-3 py-2 text-right">{{ t('products.detail.trays.lastSale') }}</th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="t2 in detail.machineTrays.value" :key="t2.id" class="border-t">
          <td class="px-3 py-2">
            <NuxtLink
              :to="`/machines/${t2.machine_id}?tab=stock`"
              class="text-primary hover:underline"
            >
              {{ t2.machine_name }}
            </NuxtLink>
          </td>
          <td class="px-3 py-2 font-mono">{{ t2.item_number }}</td>
          <td class="px-3 py-2 text-right font-mono">{{ t2.current_stock }} / {{ t2.capacity }}</td>
          <td class="px-3 py-2 text-right font-mono">{{ t2.fill_when_below ?? '—' }}</td>
          <td class="px-3 py-2 text-right text-muted-foreground">{{ t2.last_sale_at ? timeAgo(t2.last_sale_at) : '—' }}</td>
        </tr>
      </tbody>
    </table>
  </div>
</section>
```

Rename the loop variable to `t2` to avoid shadowing the `t` translation function.

Ensure `import { timeAgo, formatCurrency, formatDate } from '~/lib/utils'` is complete.

- [ ] **Step 2: Commit**

```bash
git commit -am "feat(products): add machine trays section"
```

---

### Task 9: Top machines section

**Files:**
- Modify: `management-frontend/app/pages/products/[id].vue`

- [ ] **Step 1: Insert the section**

Reads from `detail.kpis.value.top_machines` (already aggregated server-side over 30 days).

```vue
<section class="space-y-2" aria-labelledby="sec-top">
  <h2 id="sec-top" class="text-lg font-semibold">{{ t('products.detail.sections.topMachines') }}</h2>
  <p v-if="!detail.kpis.value || !detail.kpis.value.top_machines.length" class="text-sm text-muted-foreground">
    {{ t('products.detail.empty.noSales') }}
  </p>
  <div v-else class="overflow-x-auto rounded-md border">
    <table class="w-full text-sm">
      <thead class="bg-muted/40 text-xs uppercase">
        <tr>
          <th class="px-3 py-2 text-left">{{ t('products.detail.topMachines.machine') }}</th>
          <th class="px-3 py-2 text-right">{{ t('products.detail.topMachines.units') }}</th>
          <th class="px-3 py-2 text-right">{{ t('products.detail.topMachines.revenue') }}</th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="m in detail.kpis.value.top_machines" :key="m.machine_id" class="border-t">
          <td class="px-3 py-2">
            <NuxtLink :to="`/machines/${m.machine_id}?tab=sales`" class="text-primary hover:underline">
              {{ m.machine_name }}
            </NuxtLink>
          </td>
          <td class="px-3 py-2 text-right font-mono">{{ m.units }}</td>
          <td class="px-3 py-2 text-right font-mono">{{ formatCurrency(m.revenue) }}</td>
        </tr>
      </tbody>
    </table>
  </div>
</section>
```

- [ ] **Step 2: Commit**

```bash
git commit -am "feat(products): add top machines section"
```

---

### Task 10: Recent sales section

**Files:**
- Modify: `management-frontend/app/pages/products/[id].vue`

- [ ] **Step 1: Insert the section**

```vue
<section class="space-y-2" aria-labelledby="sec-sales">
  <h2 id="sec-sales" class="text-lg font-semibold">{{ t('products.detail.sections.recentSales') }}</h2>
  <p v-if="!detail.recentSales.value.length" class="text-sm text-muted-foreground">
    {{ t('products.detail.empty.noSales') }}
  </p>
  <div v-else class="overflow-x-auto rounded-md border">
    <table class="w-full text-sm">
      <thead class="bg-muted/40 text-xs uppercase">
        <tr>
          <th class="px-3 py-2 text-left">{{ t('products.detail.sales.time') }}</th>
          <th class="px-3 py-2 text-left">{{ t('products.detail.sales.machine') }}</th>
          <th class="px-3 py-2 text-left">{{ t('products.detail.sales.channel') }}</th>
          <th class="px-3 py-2 text-right">{{ t('products.detail.sales.price') }}</th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="s in detail.recentSales.value" :key="s.id" class="border-t">
          <td class="px-3 py-2 text-muted-foreground">{{ formatDateTime(s.created_at) }}</td>
          <td class="px-3 py-2">
            <NuxtLink
              v-if="s.machine_id"
              :to="`/machines/${s.machine_id}?tab=sales`"
              class="text-primary hover:underline"
            >
              {{ s.machine_name ?? '—' }}
            </NuxtLink>
            <span v-else>—</span>
          </td>
          <td class="px-3 py-2">{{ s.channel ?? '—' }}</td>
          <td class="px-3 py-2 text-right font-mono">{{ s.item_price !== null ? formatCurrency(s.item_price) : '—' }}</td>
        </tr>
      </tbody>
    </table>
  </div>
</section>
```

Add `formatDateTime` to the utils import.

- [ ] **Step 2: Commit**

```bash
git commit -am "feat(products): add recent sales section"
```

---

### Task 11: Warehouse history section

**Files:**
- Modify: `management-frontend/app/pages/products/[id].vue`

- [ ] **Step 1: Insert the section**

```vue
<section class="space-y-2" aria-labelledby="sec-tx">
  <h2 id="sec-tx" class="text-lg font-semibold">{{ t('products.detail.sections.history') }}</h2>
  <p v-if="!detail.transactions.value.length" class="text-sm text-muted-foreground">
    {{ t('products.detail.empty.noTransactions') }}
  </p>
  <div v-else class="overflow-x-auto rounded-md border">
    <table class="w-full text-sm">
      <thead class="bg-muted/40 text-xs uppercase">
        <tr>
          <th class="px-3 py-2 text-left">{{ t('products.detail.history.time') }}</th>
          <th class="px-3 py-2 text-left">{{ t('products.detail.history.warehouse') }}</th>
          <th class="px-3 py-2 text-left">{{ t('products.detail.history.type') }}</th>
          <th class="px-3 py-2 text-right">{{ t('products.detail.history.change') }}</th>
          <th class="px-3 py-2 text-right">{{ t('products.detail.history.after') }}</th>
          <th class="px-3 py-2 text-left">{{ t('products.detail.history.user') }}</th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="tx in detail.transactions.value" :key="tx.id" class="border-t">
          <td class="px-3 py-2 text-muted-foreground">{{ formatDateTime(tx.created_at) }}</td>
          <td class="px-3 py-2">{{ tx.warehouse_name }}</td>
          <td class="px-3 py-2">{{ tx.transaction_type }}</td>
          <td
            class="px-3 py-2 text-right font-mono"
            :class="tx.quantity_change >= 0 ? 'text-emerald-600' : 'text-destructive'"
          >
            {{ tx.quantity_change > 0 ? '+' : '' }}{{ tx.quantity_change }}
          </td>
          <td class="px-3 py-2 text-right font-mono">{{ tx.quantity_after ?? '—' }}</td>
          <td class="px-3 py-2">{{ tx.user_display }}</td>
        </tr>
      </tbody>
    </table>
  </div>
</section>
```

- [ ] **Step 2: Remove the placeholder div**

Delete the `<div v-if="detail.product.value" class="rounded-md border border-dashed …">Sections coming in the next chunk.</div>` from Task 4.

- [ ] **Step 3: Commit**

```bash
git commit -am "feat(products): add warehouse history section, drop placeholder"
```

---

### Task 12: Consolidate i18n keys for the detail page

**Files:**
- Modify: `management-frontend/i18n/locales/en.json`
- Modify: `management-frontend/i18n/locales/de.json`

- [ ] **Step 1: Replace the `products.detail.*` block with the full set**

English (under `products`):

```json
"detail": {
  "notFound": {
    "title": "Product not found",
    "back": "Back to products"
  },
  "header": {
    "discontinued": "Discontinued",
    "edit": "Edit"
  },
  "kpi": {
    "warehouseStock": "Warehouse stock",
    "warehouseCount": "in {n} warehouse(s)",
    "machineStock": "Machine stock",
    "machineCount": "in {n} machine(s)",
    "salesToday": "Sales today",
    "velocity": "Sales velocity",
    "velocitySubtitle": "units/day (last {n} days)"
  },
  "chart": {
    "revenueTitle": "Revenue (30 days)",
    "revenueDescription": "Daily revenue in EUR",
    "unitsTitle": "Units sold (30 days)",
    "unitsDescription": "Daily units sold"
  },
  "sections": {
    "warehouseStock": "Warehouse stock",
    "machineTrays": "Machine trays",
    "topMachines": "Top machines (30 days)",
    "recentSales": "Recent sales",
    "history": "Warehouse history"
  },
  "warehouseStock": {
    "batchNumber": "Batch",
    "expiry": "Expires",
    "intake": "Received",
    "qty": "Qty",
    "belowMin": "below min ({min})"
  },
  "trays": {
    "machine": "Machine",
    "slot": "Slot",
    "stock": "Stock / Capacity",
    "fillWhenBelow": "Refill when below",
    "lastSale": "Last sale"
  },
  "topMachines": {
    "machine": "Machine",
    "units": "Units",
    "revenue": "Revenue"
  },
  "sales": {
    "time": "Time",
    "machine": "Machine",
    "channel": "Channel",
    "price": "Price"
  },
  "history": {
    "time": "Time",
    "warehouse": "Warehouse",
    "type": "Type",
    "change": "Change",
    "after": "After",
    "user": "User"
  },
  "empty": {
    "noStock": "Not stocked in any warehouse.",
    "noTrays": "Not listed in any machine.",
    "noSales": "No sales yet.",
    "noTransactions": "No warehouse activity yet."
  }
}
```

German:

```json
"detail": {
  "notFound": {
    "title": "Produkt nicht gefunden",
    "back": "Zurück zu Produkten"
  },
  "header": {
    "discontinued": "Ausgelaufen",
    "edit": "Bearbeiten"
  },
  "kpi": {
    "warehouseStock": "Lagerbestand",
    "warehouseCount": "in {n} Lager",
    "machineStock": "Maschinenbestand",
    "machineCount": "in {n} Automat(en)",
    "salesToday": "Verkäufe heute",
    "velocity": "Verkaufsgeschwindigkeit",
    "velocitySubtitle": "Stück/Tag (letzte {n} Tage)"
  },
  "chart": {
    "revenueTitle": "Umsatz (30 Tage)",
    "revenueDescription": "Täglicher Umsatz in EUR",
    "unitsTitle": "Verkäufe (30 Tage)",
    "unitsDescription": "Verkaufte Stückzahl pro Tag"
  },
  "sections": {
    "warehouseStock": "Lagerbestand",
    "machineTrays": "Automaten-Slots",
    "topMachines": "Top-Automaten (30 Tage)",
    "recentSales": "Letzte Verkäufe",
    "history": "Lagerbewegungen"
  },
  "warehouseStock": {
    "batchNumber": "Charge",
    "expiry": "Ablauf",
    "intake": "Eingang",
    "qty": "Menge",
    "belowMin": "unter Mindest­bestand ({min})"
  },
  "trays": {
    "machine": "Automat",
    "slot": "Slot",
    "stock": "Bestand / Kapazität",
    "fillWhenBelow": "Auffüllen ab",
    "lastSale": "Letzter Verkauf"
  },
  "topMachines": {
    "machine": "Automat",
    "units": "Stück",
    "revenue": "Umsatz"
  },
  "sales": {
    "time": "Zeit",
    "machine": "Automat",
    "channel": "Kanal",
    "price": "Preis"
  },
  "history": {
    "time": "Zeit",
    "warehouse": "Lager",
    "type": "Typ",
    "change": "Änderung",
    "after": "Danach",
    "user": "Benutzer"
  },
  "empty": {
    "noStock": "In keinem Lager vorhanden.",
    "noTrays": "In keinem Automaten gelistet.",
    "noSales": "Noch keine Verkäufe.",
    "noTransactions": "Noch keine Lagerbewegungen."
  }
}
```

- [ ] **Step 2: Verify page renders in both locales**

Switch locale via the language switcher; confirm every string on the detail page is translated (no key-path leak like `products.detail.kpi.velocity`).

- [ ] **Step 3: Commit**

```bash
git add management-frontend/i18n/locales/en.json management-frontend/i18n/locales/de.json
git commit -m "i18n(products): add detail page translations (en, de)"
```

---

## Chunk 3: Click-through wiring

Each task adds click-through from one source surface. Rows depending on `sales.product_id` must guard with a conditional so null rows render non-clickable (no `cursor-pointer`, no navigation).

**Universal rules (restated explicitly in every task where applicable):**

1. **`@click.stop` on every interactive child** (buttons, links, icons with handlers) inside any row or card that becomes clickable. Not just delete buttons — every one. A row that mounts an interactive child later must re-check this; leave a comment in the template so future edits notice.
2. **Consistent conditional idiom.** Use `<component :is>` when clickability is per-row conditional (on `product_id`), as in Task 14. Use `<NuxtLink>` directly when clickability is unconditional (static surfaces). Do not mix `@click` + class-ternary with the component-conditional approach in the same codebase — pick the component-conditional form every time.
3. **`/refill` is excluded**, not just not-listed. Task 20 Step 3 adds a positive grep assertion to prove no `NuxtLink` to `/products/[id]` was introduced under `app/pages/refill/**`.
4. **Backtick escaping in this plan:** Vue template literals like `` `/products/${id}` `` appear inside inline code spans. Where unclear, read the block-code snippets as authoritative — the inline fragments are for orientation.

### Task 13: Dashboard — `DashboardTopProducts`

**Files:**
- Modify: `management-frontend/app/components/DashboardTopProducts.vue`

- [ ] **Step 1: Read the component to find where each product item is rendered**

Note the exact element (likely `<li>`, `<div>`, or `<tr>`), whether each row has a `product.id` in scope, and any existing click handlers or interactive children on the row.

- [ ] **Step 2: Wrap each product item's contents in a `<NuxtLink>`**

If the row is a `<div>` / `<li>`:

```vue
<NuxtLink
  :to="`/products/${product.id}`"
  class="block hover:bg-muted/50 transition-colors rounded-md"
>
  <!-- existing row content -->
</NuxtLink>
```

If the row is a `<tr>` (can't contain `<NuxtLink>`), wrap each `<td>`'s content in a `<NuxtLink>` instead. Do **not** use `@click` on the `<tr>` — we are not introducing that idiom.

- [ ] **Step 3: Add `@click.stop` to any interactive child already inside the wrapped content**

Grep the component for `<button`, `@click`, or other `<NuxtLink>`. For each one found inside the newly clickable area, append `@click.stop`. Add a comment `<!-- any interactive child needs @click.stop -->` just above the wrapped content.

- [ ] **Step 4: Verify in browser**

`npm run dev`, open dashboard, click a top product → lands on `/products/[id]`. Any existing button in the card still works without navigating.

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(dashboard): make top products card clickable to detail page"
```

---

### Task 14: Dashboard — `DashboardRecentSales` (canonical `<component :is>` pattern)

Sales without `product_id` stay non-clickable. This task establishes the conditional pattern that Tasks 15, 19, 20 mirror.

**Files:**
- Modify: `management-frontend/app/components/DashboardRecentSales.vue`
- Modify (if needed): whatever composable or page-level query feeds this component

- [ ] **Step 1: Ensure the feeding query selects `product_id`**

Grep from `DashboardRecentSales.vue` back to the query source. If the `.select(...)` for sales rows does not include `product_id`, add it. Commit this first so the DB-level change is visible independently.

- [ ] **Step 2: Import NuxtLink into the component's script setup**

```ts
import { NuxtLink } from '#components'
```

`NuxtLink` is auto-imported in templates but NOT in `<script setup>`. Don't try `<component :is="'NuxtLink'">` (string form) — it won't resolve.

- [ ] **Step 3: Conditionally wrap the row**

```vue
<component
  :is="sale.product_id ? NuxtLink : 'div'"
  :to="sale.product_id ? `/products/${sale.product_id}` : undefined"
  :class="['block', sale.product_id ? 'hover:bg-muted/50 cursor-pointer' : '']"
>
  <!-- existing row content -->
  <!-- any interactive child needs @click.stop -->
</component>
```

- [ ] **Step 4: Add `@click.stop` to any existing interactive child**

Grep the row content for `<button`, `@click`, `<NuxtLink>`. Append `@click.stop` to each one.

- [ ] **Step 5: Verify in browser**

Open dashboard. A sale row with a `product_id` should hover-highlight and click through. A row without (test by picking an older sale; if you don't have any, manually null one in dev DB for the test) should not react to hover or clicks.

- [ ] **Step 6: Commit**

```bash
git commit -am "feat(dashboard): make recent sales clickable when product_id is known"
```

---

### Task 15: `/machines/[id]` sales tab

Rows use `<tr>`. Existing action buttons (delete, possibly others) must keep working without triggering navigation.

**Files:**
- Modify: `management-frontend/app/pages/machines/[id].vue`

- [ ] **Step 1: Find the sales table inside the `sales` tab and inventory its interactive children**

Locate the `<tr v-for="sale in sales">` (or equivalent). Grep its inner template for every `<button`, `@click`, `<NuxtLink>`, or dropdown trigger. Write the list down — every one needs `@click.stop` in Step 4.

- [ ] **Step 2: Ensure the sales query selects `product_id`**

Find the composable or inline query that feeds the sales tab. Add `product_id` to the `.select(...)` if missing.

- [ ] **Step 3: Make the row conditionally clickable using the canonical pattern**

Since `<tr>` cannot host `<NuxtLink>` directly, use `@click` on the row **but only** when `sale.product_id` is set. Add a `cursor-pointer` class under the same condition:

```vue
<tr
  v-for="sale in sales"
  :key="sale.id"
  :class="{ 'cursor-pointer hover:bg-muted/50': sale.product_id }"
  @click="sale.product_id && $router.push(`/products/${sale.product_id}`)"
>
  <!-- cells — each interactive child needs @click.stop -->
</tr>
```

This is the one place the component-conditional idiom cannot apply (table semantics). The preamble's rule allows `@click` here as the exception; keep the conditional so null-`product_id` rows are completely inert.

- [ ] **Step 4: Append `@click.stop` to every interactive child identified in Step 1**

Not just delete — every button/link/dropdown trigger inside the row.

- [ ] **Step 5: Verify**

In browser: row with `product_id` hovers and navigates; delete button on that row still deletes without navigating; row without `product_id` (older sale) is fully inert.

- [ ] **Step 6: Commit**

```bash
git commit -am "feat(machines): click sales row to open product detail"
```

---

### Task 16: `/machines/[id]` trays tab

Row has edit/refill actions — **only** the product name/image cell is clickable. The row itself stays non-clickable.

**Files:**
- Modify: `management-frontend/app/pages/machines/[id].vue`

- [ ] **Step 1: Find the trays table rendering and confirm `tray.product_id` is already in the row scope**

`machine_trays.product_id` is the FK so it's almost certainly selected already. Verify.

- [ ] **Step 2: Verify no existing handler on the image itself**

Grep the tray-row template for `@click` on `<img>` or parent cell. If any lightbox/zoom handler exists on the image, skip wrapping the image and wrap only the name — otherwise the handler becomes unreachable.

- [ ] **Step 3: Wrap the product name cell when `tray.product_id` is set**

```vue
<td>
  <NuxtLink
    v-if="tray.product_id"
    :to="`/products/${tray.product_id}`"
    class="hover:underline inline-flex items-center gap-2"
  >
    <img v-if="tray.product_image_url" :src="tray.product_image_url" class="size-8 rounded object-cover" />
    <span>{{ tray.product_name }}</span>
  </NuxtLink>
  <template v-else>—</template>
</td>
```

The row's other cells (edit/refill actions) are untouched. No `@click.stop` needed because the row itself has no click handler.

- [ ] **Step 4: Verify**

Click a product in the trays tab → detail page. The edit and refill buttons in the same row still work normally (no propagation collision because the click is scoped to the name cell).

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(machines): product name in trays table links to detail page"
```

---

### Task 17: `/products` index page

Row click must still open the edit modal; only the product name/image gets a `<NuxtLink>`. The link must use `@click.stop` to prevent the row's edit handler from firing on navigation.

**Files:**
- Modify: `management-frontend/app/pages/products/index.vue`

- [ ] **Step 1: Verify the row-level click mechanism**

Locate the row that opens the edit modal. Check whether the click handler is on the `<tr>` via `@click` (simple bubbling — `@click.stop` works), on a cell via `@click.capture` (capture phase — `@click.stop` still works since it stops propagation during bubbling), or on a parent via event delegation with a specific target check. In the last case, `@click.stop` on the link is insufficient — you must instead route the edit via an explicit button/cell that excludes the name cell. Write down which mechanism is in use before editing.

- [ ] **Step 2: Wrap the product name cell contents in `<NuxtLink>`**

```vue
<NuxtLink
  :to="`/products/${p.id}`"
  class="hover:underline inline-flex items-center gap-2"
  @click.stop
>
  <img v-if="p.image_url" :src="p.image_url" class="size-8 rounded object-cover" />
  <span>{{ p.name }}</span>
</NuxtLink>
```

If Step 1 found a capture/delegation mechanism that `@click.stop` can't handle, take the alternative path: move the edit trigger to an explicit pencil-icon button and remove the row-level click.

- [ ] **Step 3: Verify both paths still work**

Click the product name → navigate to detail page (do not open edit modal). Click any other part of the row → open edit modal (do not navigate).

- [ ] **Step 4: Commit**

```bash
git commit -am "feat(products): product name links to detail page (row click still edits)"
```

---

### Task 18: `/warehouse` — stock + batches + transactions + min-stock alerts

Many action buttons per row; only name/image clickable. `/warehouse` is a multi-feature area — the implementer must enumerate every product surface before editing.

**Files:**
- Modify: files enumerated in Step 1

- [ ] **Step 1: Enumerate every product surface under `/warehouse`**

Run these greps from the repo root and paste the hit list into the commit message or a scratch note:

```bash
# Templates that render a product row
rg -l "product\.name|product_name|productName|\.product_id" management-frontend/app/pages/warehouse management-frontend/app/components | sort -u

# Any existing NuxtLink pointing at products (avoid duplicates)
rg "NuxtLink.*products" management-frontend/app/pages/warehouse management-frontend/app/components
```

For each hit, open the file and note (a) the element that renders the product name/image, (b) whether `product_id` is in scope, (c) any existing interactive children nearby. Produce a list: `[file, element, has_product_id, has_interactive_children]`. The implementer's checklist for Step 2 comes straight from this list.

- [ ] **Step 2: Wrap the product name in `<NuxtLink>` in each enumerated file**

```vue
<NuxtLink
  :to="`/products/${row.product_id}`"
  class="hover:underline inline-flex items-center gap-2"
>
  <!-- image if present -->
  <span>{{ row.product_name }}</span>
</NuxtLink>
```

If the row itself has a click handler (unlikely in /warehouse given the button density but possible), add `@click.stop` to the link.

- [ ] **Step 3: Re-run the first grep and confirm every original hit now has a `<NuxtLink>` to `/products/`**

```bash
# Should now list every wrapped surface
rg "NuxtLink.*products/" management-frontend/app/pages/warehouse management-frontend/app/components
```

Diff this list against Step 1's list — they must match.

- [ ] **Step 4: Commit, including the file list in the message**

```bash
git commit -am "feat(warehouse): product names link to detail page

Wrapped in: <paste Step 1's file list>"
```

---

### Task 19: `/tour-history`

Static rows — full item-row clickable when `product_id` is available. Uses the Task 14 canonical `<component :is>` idiom for the conditional case.

**Files:**
- Modify: `management-frontend/app/pages/tour-history/index.vue`

- [ ] **Step 1: Verify the tour-history query provides `product_id` on each line item**

If not, add it to the `.select(...)` in `useTourHistory` or wherever the data originates.

- [ ] **Step 2: Import NuxtLink in script setup**

```ts
import { NuxtLink } from '#components'
```

- [ ] **Step 3: Conditionally wrap each item row**

```vue
<component
  :is="item.product_id ? NuxtLink : 'div'"
  :to="item.product_id ? `/products/${item.product_id}` : undefined"
  :class="['block', item.product_id ? 'hover:bg-muted/50 cursor-pointer' : '']"
>
  <!-- existing item row content -->
  <!-- any interactive child needs @click.stop -->
</component>
```

- [ ] **Step 4: Grep the wrapped block for existing `<button` / `@click` / `<NuxtLink>` and add `@click.stop` to each**

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(tour-history): items link to product detail page"
```

---

### Task 20: `/reports`, `/cash-book`, `/deals`

Some of these list products by name. Apply the Task 14 / Task 16 patterns depending on whether the surface has row-level actions.

**Files:**
- Survey: `management-frontend/app/pages/reports/**`, `management-frontend/app/pages/cash-book/**`, `management-frontend/app/pages/deals/**`
- Modify only the files where a product actually appears.

- [ ] **Step 1: Enumerate every product surface and write down the list as an artifact**

Run:

```bash
rg -l "product\.name|product_name|productName|\.product_id" \
  management-frontend/app/pages/reports \
  management-frontend/app/pages/cash-book \
  management-frontend/app/pages/deals \
  | sort -u
```

For each hit file, note (a) the element rendering the product, (b) whether `product_id` is already in scope (grep the feeding composable / query), (c) whether `product_id` needs to be added to the `.select(...)`, (d) whether the row has existing interactive children. Paste this list into the commit message.

- [ ] **Step 2: If any surface is missing `product_id`, add it to the feeding query**

Commit the query change first, before the template change, so each commit is scoped.

- [ ] **Step 3: Wrap each product name/image using the right pattern**

- If the surface has **no** row-level click handler and no row-level interactive children: wrap the name/image cell in `<NuxtLink v-if="row.product_id">` (Task 16 pattern).
- If the surface has a full-row interactive purpose and no action buttons: wrap the whole row with `<component :is>` (Task 14 pattern).
- If the row already has action buttons: use Task 16 pattern and leave the row alone.

- [ ] **Step 4: Positive verification that `/refill` was left alone**

Run this grep — it must return **zero hits**:

```bash
rg "NuxtLink.*/products/|router.push.*products/" management-frontend/app/pages/refill
```

If there are hits, they were introduced in error; revert them. Paste the zero-result output into the commit message as proof.

- [ ] **Step 5: Commit, with the Step 1 file list and Step 4 grep result in the message**

```bash
git commit -am "feat(reports,cash-book,deals): product names link to detail page

Surfaces wrapped: <paste Step 1's list>
Confirmed /refill untouched: <paste Step 4's empty grep output>"
```

---

### Task 20.5: End-of-Chunk-3 verification

A single step that mechanically confirms the chunk's two hard invariants.

- [ ] **Step 1: Run both greps and paste the results into your notes**

```bash
# Invariant 1: /refill is not clickable
rg "NuxtLink.*products/|router.push.*products/" management-frontend/app/pages/refill
# Expected output: (empty — zero hits)

# Invariant 2: every <button> inside a clickable row/card has @click.stop
# (heuristic: any file changed in this chunk that contains NuxtLink to /products/
#  and also contains <button should be spot-checked)
git diff --name-only origin/main -- 'management-frontend/app/**/*.vue' | xargs -I{} sh -c 'echo "== {} =="; rg -A 2 "<button" {}'
```

For the second grep, manually scan the output for any `<button>` inside a row that now navigates. If found without `@click.stop`, add it and re-commit.

---

## Chunk 4: Tests

### Task 21: Unit test `useProductDetail`

**Files:**
- Create: `management-frontend/app/composables/__tests__/useProductDetail.test.ts`

Reference shape: `useMdbLog.test.ts` (195 LOC) or `useGeocoding.test.ts` (242 LOC) — both bigger than `useMachines.test.ts` and closer to the structural complexity needed here. Use one of them as the skeleton.

- [ ] **Step 1: Build a per-table mock dispatcher**

The composable hits eight different tables and one RPC. The mock needs to return a different builder per table. Skeleton:

```ts
import { describe, it, expect, vi, beforeEach } from 'vitest'

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

let salesCallCount = 0  // first sales call = recentSales (limit 50), second = chart

function makeBuilder(tableKey: keyof typeof fixtures) {
  // chainable; resolves on the terminal method (.maybeSingle/.in/.gte/.order/.limit)
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
  return { ref, useState: <T,>(_k: string, init?: () => T) => ref(init?.()), useSupabaseClient: () => mockSupabase }
})

vi.mock('../useProducts', () => ({ getProductImageUrl: (p: string) => `https://example.test/${p}` }))
```

- [ ] **Step 2: Write four test cases**

```ts
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

it('happy path: populates all refs from preset fixtures', async () => {
  fixtures.products.data = { id: 'p1', name: 'Coke', sellprice: 2.5, description: null, category: 'c1', image_path: 'p1.jpg', discontinued: false, product_category: { name: 'Drinks' } }
  fixtures.rpc_kpis.data = { warehouse_total_qty: 42, warehouse_count: 1, tray_total_stock: 5, tray_total_capacity: 10, machine_count: 2, sales_today_units: 3, sales_today_revenue: 7.5, sales_7d_units: 20, sales_7d_revenue: 50, velocity_units_per_day: 2.85, velocity_window_days: 7, top_machines: [{ machine_id: 'm1', machine_name: 'M1', units: 10, revenue: 25 }] }
  fixtures.warehouse_stock_batches.data = [{ id: 'b1', warehouse_id: 'w1', batch_number: 'B1', expiration_date: '2026-12-31', quantity: 42, created_at: '2026-04-01T00:00:00Z', warehouses: { name: 'WH-1' } }]
  fixtures.machine_trays.data = [{ id: 't1', machine_id: 'm1', item_number: 5, current_stock: 5, capacity: 10, fill_when_below: 3, vendingMachine: { name: 'M1' } }]
  fixtures.sales.data = [{ id: 100, created_at: new Date().toISOString(), item_price: 2.5, channel: 'cashless', machine_id: 'm1', vendingMachine: { name: 'M1' } }]

  const detail = useProductDetail(ref('p1'))
  await detail.refresh()

  expect(detail.notFound.value).toBe(false)
  expect(detail.product.value?.name).toBe('Coke')
  expect(detail.kpis.value?.warehouse_total_qty).toBe(42)
  expect(detail.warehouseStock.value).toHaveLength(1)
  expect(detail.warehouseStock.value[0].total_qty).toBe(42)
  expect(detail.machineTrays.value[0].last_sale_at).not.toBeNull()  // backfilled from sales
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
  fixtures.products.data = { id: 'p1', name: 'X', sellprice: null, description: null, category: null, image_path: null, discontinued: false, product_category: null }
  fixtures.rpc_kpis.data = { warehouse_total_qty: 0, warehouse_count: 0, tray_total_stock: 0, tray_total_capacity: 0, machine_count: 0, sales_today_units: 0, sales_today_revenue: 0, sales_7d_units: 0, sales_7d_revenue: 0, velocity_units_per_day: 0, velocity_window_days: 30, top_machines: [] }
  fixtures.warehouse_transactions.data = [
    { id: 't1', created_at: '2026-04-10T00:00:00Z', transaction_type: 'intake', quantity_change: 10, quantity_after: 10, warehouse_id: 'w1', user_id: 'u1', notes: null, warehouses: { name: 'WH-1' } },
    { id: 't2', created_at: '2026-04-09T00:00:00Z', transaction_type: 'refill', quantity_change: -5, quantity_after: 5, warehouse_id: 'w1', user_id: null, notes: null, warehouses: { name: 'WH-1' } },
  ]
  fixtures.users.data = [{ id: 'u1', first_name: 'Anna', last_name: 'Berg', email: 'anna@example.com' }]

  const detail = useProductDetail(ref('p1'))
  await detail.refresh()
  expect(detail.transactions.value[0].user_display).toBe('Anna Berg')
  expect(detail.transactions.value[1].user_display).toBe('—')
})

it('chart bucketing: a sale 3 days ago lands in the correct bucket index', async () => {
  fixtures.products.data = { id: 'p1', name: 'X', sellprice: null, description: null, category: null, image_path: null, discontinued: false, product_category: null }
  fixtures.rpc_kpis.data = { warehouse_total_qty: 0, warehouse_count: 0, tray_total_stock: 0, tray_total_capacity: 0, machine_count: 0, sales_today_units: 0, sales_today_revenue: 0, sales_7d_units: 0, sales_7d_revenue: 0, velocity_units_per_day: 0, velocity_window_days: 30, top_machines: [] }
  const threeDaysAgo = new Date()
  threeDaysAgo.setDate(threeDaysAgo.getDate() - 3)
  threeDaysAgo.setHours(12, 0, 0, 0)
  fixtures.sales_chart.data = [{ created_at: threeDaysAgo.toISOString(), item_price: 4.0 }]

  const detail = useProductDetail(ref('p1'))
  await detail.refresh()

  // Buckets are 30 days, oldest first. Index 26 is "3 days ago" (29 - 3 = 26).
  expect(detail.chartUnits.value).toHaveLength(30)
  expect(detail.chartUnits.value[26].total).toBe(1)
  expect(detail.chartRevenue.value[26].total).toBe(4.0)
  // All other buckets are zero
  for (let i = 0; i < 30; i++) {
    if (i === 26) continue
    expect(detail.chartUnits.value[i].total).toBe(0)
  }
})
```

Note on the second sales call: the composable issues `sales` LIMIT-50 first, then later `sales` for the chart. The dispatcher in Step 1 disambiguates by call order. If the composable refactors to a single sales query, simplify the dispatcher accordingly.

- [ ] **Step 3: Run the test**

```bash
cd management-frontend && npx vitest run app/composables/__tests__/useProductDetail.test.ts
```

Expected: 4 passed.

- [ ] **Step 4: Commit**

```bash
git add management-frontend/app/composables/__tests__/useProductDetail.test.ts
git commit -m "test(products): unit-test useProductDetail composable"
```

---

### Task 22: SQL integration test for `get_product_detail_kpis` RPC

**Important framing:** This is an **integration test** that exercises the real `SECURITY DEFINER` function against a live local Supabase. The earlier `mqtt-webhook/mdb-log.test.ts` reference is for **file layout convention only** — that test mocks the Supabase client; this one does not. There is no existing DB-integration test in the repo, so this task creates the harness.

**Why a plain-SQL test instead of HTTP+JWT:** The function uses `SECURITY DEFINER` and `public.my_company_id()` which reads from the JWT. Two paths exist:

- **(A) Plain-SQL via `psql`** — call the function with `SET LOCAL` to inject a fake `request.jwt.claims`. Faster, no HTTP, no JWT-minting, no env vars needed beyond the local DB connection. **Preferred — use this.**
- **(B) HTTP+JWT** — sign a JWT with `JWT_SECRET` and POST to PostgREST. More realistic but requires the test to mint JWTs and manage env. Skip unless (A) is somehow inadequate.

**Files:**
- Create: `Docker/supabase/tests/get_product_detail_kpis.test.sql`
- Create: `Docker/supabase/tests/run-sql-tests.sh` (one-shot harness that any future SQL test can reuse)

- [ ] **Step 1: Make sure local Supabase is running**

```bash
cd Docker/supabase && supabase status
```

If not running: `supabase start`. **Do not** `supabase db reset` (project rule — kills dev data). Migrations applied via `supabase migration up` from Task 1 must already be in place.

- [ ] **Step 2: Write the SQL test**

`Docker/supabase/tests/get_product_detail_kpis.test.sql`:

```sql
-- Integration test for get_product_detail_kpis.
-- Runs inside one transaction that is rolled back at the end → no dev data touched.
-- Uses pgTAP-style RAISE NOTICE assertions (no extension required).

BEGIN;

-- Pin a stable "now" so today-window assertions are deterministic
SET LOCAL TIMEZONE = 'UTC';

DO $$
DECLARE
  v_company_a uuid := gen_random_uuid();
  v_company_b uuid := gen_random_uuid();
  v_user_a    uuid := gen_random_uuid();
  v_user_b    uuid := gen_random_uuid();
  v_product   uuid := gen_random_uuid();
  v_machine   uuid := gen_random_uuid();
  v_warehouse uuid := gen_random_uuid();
  v_kpis      jsonb;
  v_top_units bigint;
BEGIN
  -- ─── Seed company A ───────────────────────────────────────────────────────
  INSERT INTO public.companies (id, name, velocity_days)
    VALUES (v_company_a, 'TestCo A', 7);
  INSERT INTO public.companies (id, name, velocity_days)
    VALUES (v_company_b, 'TestCo B', 7);

  -- Auth users + public.users + organization_members for both companies
  INSERT INTO auth.users (id, instance_id, email)
    VALUES (v_user_a, '00000000-0000-0000-0000-000000000000', 'a@test.local');
  INSERT INTO auth.users (id, instance_id, email)
    VALUES (v_user_b, '00000000-0000-0000-0000-000000000000', 'b@test.local');
  INSERT INTO public.users (id, company, email)
    VALUES (v_user_a, v_company_a, 'a@test.local');
  INSERT INTO public.users (id, company, email)
    VALUES (v_user_b, v_company_b, 'b@test.local');
  INSERT INTO public.organization_members (company_id, user_id, role)
    VALUES (v_company_a, v_user_a, 'admin');
  INSERT INTO public.organization_members (company_id, user_id, role)
    VALUES (v_company_b, v_user_b, 'admin');

  -- Product, machine, warehouse, tray, batch, sales (today + 5d ago)
  INSERT INTO public.products (id, name, company)
    VALUES (v_product, 'Test Coke', v_company_a);
  INSERT INTO public."vendingMachine" (id, name, company)
    VALUES (v_machine, 'Test Machine', v_company_a);
  INSERT INTO public.warehouses (id, name, company_id)
    VALUES (v_warehouse, 'Test WH', v_company_a);
  INSERT INTO public.machine_trays (machine_id, item_number, product_id, capacity, current_stock)
    VALUES (v_machine, 1, v_product, 10, 7);
  INSERT INTO public.warehouse_stock_batches
    (warehouse_id, product_id, quantity, company_id)
    VALUES (v_warehouse, v_product, 25, v_company_a);
  INSERT INTO public.sales (machine_id, item_number, item_price, channel, created_at)
    VALUES (v_machine, 1, 2.50, 'cashless', now());
  INSERT INTO public.sales (machine_id, item_number, item_price, channel, created_at)
    VALUES (v_machine, 1, 2.50, 'cashless', now() - interval '5 days');

  -- ─── Test 1: caller from company A sees correct KPIs ─────────────────────
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text,
    true);

  SELECT public.get_product_detail_kpis(v_product, 30) INTO v_kpis;

  ASSERT (v_kpis->>'warehouse_total_qty')::bigint = 25,
    format('expected warehouse_total_qty=25, got %s', v_kpis->>'warehouse_total_qty');
  ASSERT (v_kpis->>'tray_total_stock')::bigint = 7,
    format('expected tray_total_stock=7, got %s', v_kpis->>'tray_total_stock');
  ASSERT (v_kpis->>'tray_total_capacity')::bigint = 10,
    format('expected tray_total_capacity=10, got %s', v_kpis->>'tray_total_capacity');
  ASSERT (v_kpis->>'machine_count')::int = 1,
    format('expected machine_count=1, got %s', v_kpis->>'machine_count');
  ASSERT (v_kpis->>'warehouse_count')::int = 1,
    format('expected warehouse_count=1, got %s', v_kpis->>'warehouse_count');
  ASSERT (v_kpis->>'sales_today_units')::bigint = 1,
    format('expected sales_today_units=1, got %s', v_kpis->>'sales_today_units');
  ASSERT (v_kpis->>'sales_7d_units')::bigint = 2,
    format('expected sales_7d_units=2, got %s', v_kpis->>'sales_7d_units');

  -- top_machines is a jsonb array; first element has units=2, name='Test Machine'
  SELECT (v_kpis->'top_machines'->0->>'units')::bigint INTO v_top_units;
  ASSERT v_top_units = 2,
    format('expected top_machines[0].units=2, got %s', v_top_units);
  ASSERT v_kpis->'top_machines'->0->>'machine_name' = 'Test Machine',
    'expected top_machines[0].machine_name=Test Machine';

  RAISE NOTICE 'Test 1 passed: KPIs for own-company product';

  -- ─── Test 2: caller from company B is blocked ────────────────────────────
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_b::text, 'role', 'authenticated')::text,
    true);

  BEGIN
    PERFORM public.get_product_detail_kpis(v_product, 30);
    RAISE EXCEPTION 'Test 2 FAILED: expected exception was not raised';
  EXCEPTION
    WHEN OTHERS THEN
      ASSERT SQLERRM LIKE '%product not found or access denied%',
        format('Test 2 FAILED: wrong error message: %s', SQLERRM);
      RAISE NOTICE 'Test 2 passed: cross-company call rejected with: %', SQLERRM;
  END;

END $$;

ROLLBACK;
```

Notes:
- The whole seed runs inside a single transaction. The final `ROLLBACK` ensures dev data is untouched even if assertions pass.
- `set_config('request.jwt.claims', …, true)` sets the claim for the rest of the transaction so `public.my_company_id()` (which reads `auth.uid()` derived from the JWT) resolves to the seeded user.
- If `companies` or `vendingMachine` schema differs from what's used here (extra NOT NULL columns), update the inserts accordingly. Run the test once and let any errors guide adjustments.

- [ ] **Step 3: Write the runner script**

`Docker/supabase/tests/run-sql-tests.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Run every *.test.sql in this directory against the local Supabase DB.
# Requires `supabase start` to have been run first.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_URL="${TEST_DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"

fail=0
for f in "$DIR"/*.test.sql; do
  echo "── Running $(basename "$f") ──"
  if psql "$DB_URL" -v ON_ERROR_STOP=1 -f "$f"; then
    echo "  PASS"
  else
    echo "  FAIL"
    fail=1
  fi
done

exit $fail
```

`chmod +x Docker/supabase/tests/run-sql-tests.sh`.

- [ ] **Step 4: Run it**

```bash
./Docker/supabase/tests/run-sql-tests.sh
```

Expected: each `RAISE NOTICE 'Test N passed: …'` appears, then "PASS". Exit code 0.

If schema-mismatch errors appear (missing required columns on `companies`, `vendingMachine`, etc.), update the seeds to satisfy NOT NULL constraints, then re-run.

- [ ] **Step 5: Commit**

```bash
git add Docker/supabase/tests/get_product_detail_kpis.test.sql Docker/supabase/tests/run-sql-tests.sh
git commit -m "test(db): SQL integration test for get_product_detail_kpis

Plain-SQL integration test that runs inside a transaction with
ROLLBACK at the end so dev data is never touched. Uses
set_config('request.jwt.claims', …, true) to inject a fake JWT for
SECURITY DEFINER + my_company_id() resolution. Reusable runner
script picks up any future *.test.sql in the same directory."
```

---

## Final smoke

Not a commit — a manual confirmation before declaring done.

- [ ] **Both dashboard cards individually:** click a product in `DashboardTopProducts` → lands on `/products/[id]`. Click a sale in `DashboardRecentSales` (one with a known `product_id`) → lands on `/products/[id]`.
- [ ] Visit `/machines/[id]` sales tab → click a sales row → detail page. Click delete in another sales row → row deletes, no navigation.
- [ ] Visit `/machines/[id]` trays tab → click product name → detail page. Click edit/refill on the same row → no navigation, action runs.
- [ ] `/products` index → click a product name → detail page. Click anywhere else in the row → edit modal opens (does not navigate).
- [ ] `/warehouse` (every page in that area) → product names link to detail; action buttons still work.
- [ ] `/tour-history`, `/reports`, `/cash-book`, `/deals` → product references navigate as planned.
- [ ] **Refill exclusion (positive check):** visit `/refill` and walk the wizard. Product rows must not hover-highlight, must not change cursor, and must not navigate. Then run:

  ```bash
  rg "NuxtLink.*products/|router.push.*products/" management-frontend/app/pages/refill
  ```

  Expected output: empty (zero hits).
- [ ] **`product_id IS NULL` invisibility:** find a sale in dev DB with `product_id IS NULL` (or `UPDATE sales SET product_id=NULL WHERE id=…` on a throwaway row). Confirm:
  - Detail page for the product whose tray that sale used to map to does NOT show the null-`product_id` sale in Recent Sales.
  - Chart bucket for the day of that sale does NOT include it.
  - In `DashboardRecentSales` and the machine sales tab, that row renders as non-clickable (no cursor, no nav).
- [ ] **Empty product:** load a product with zero sales / zero stock / zero trays → every section shows its empty-state string in the active locale; page does not error.
- [ ] **Heavy product:** load a product with many sales/transactions → charts render, tables scroll horizontally on mobile (test at 375px viewport); page stays responsive.
- [ ] Deep-link a `/products/[id]` URL in a fresh browser tab; full page load works (not just SPA-internal nav).
- [ ] Switch language `en ↔ de`; every string on the detail page swaps. No raw key paths visible.

---

**Reference skills for the executor:**
- @superpowers:executing-plans — standard execution
- @superpowers:subagent-driven-development — preferred when subagents are available
- @superpowers:verification-before-completion — before claiming any step done
- @superpowers:test-driven-development — for Tasks 1, 3, 21, 22
