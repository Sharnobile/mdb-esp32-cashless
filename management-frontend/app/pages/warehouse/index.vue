<script setup lang="ts">
definePageMeta({ middleware: 'auth' })

import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import {
  IconPlus, IconBarcode, IconAdjustments, IconTrash,
  IconPackageImport, IconChevronDown, IconChevronRight,
  IconAlertTriangle, IconSearch, IconX,
} from '@tabler/icons-vue'
import { timeAgo } from '@/lib/utils'
import { getProductImageUrl } from '@/composables/useProducts'
import {
  expirationStatus, expirationBadgeClass, expirationLabel,
  type Warehouse, type StockBatch, type WarehouseProductSummary,
} from '@/composables/useWarehouse'

const { t } = useI18n()
const { organization, role } = useOrganization()
const { products, fetchProducts } = useProducts()
const {
  warehouses, batches, transactions, productSummaries, barcodes, minStocks,
  loading, transactionLoading, transactionHasMore,
  fetchWarehouses, createWarehouse, updateWarehouse, deleteWarehouse,
  fetchBarcodes, lookupBarcode, addBarcode, removeBarcode,
  fetchBatches, fetchProductSummaries, bookIncoming, adjustStock,
  fetchMinStocks, setMinStock,
  fetchTransactions, fetchMoreTransactions,
  subscribeToStockUpdates,
  transactionTypeLabel, transactionTypeBadgeClass,
} = useWarehouse()

const isAdmin = computed(() => role.value === 'admin')

const route = useRoute()
const activeTab = ref((route.query.tab as string) || 'overview')
const selectedWarehouseId = ref<string | null>(null)

const selectedWarehouse = computed(() =>
  warehouses.value.find(w => w.id === selectedWarehouseId.value) ?? null
)

usePullToRefresh(async () => {
  await Promise.all([fetchWarehouses(), fetchProducts()])
  if (selectedWarehouseId.value) await loadWarehouseData()
})

let unsubscribe: (() => void) | null = null

onMounted(async () => {
  await Promise.all([fetchWarehouses(), fetchProducts()])
  const first = warehouses.value[0]
  if (first) {
    selectedWarehouseId.value = first.id
    await loadWarehouseData()
  }
})

onUnmounted(() => {
  unsubscribe?.()
})

watch(selectedWarehouseId, async (id) => {
  unsubscribe?.()
  if (id) {
    await loadWarehouseData()
    unsubscribe = subscribeToStockUpdates(id)
  }
})

async function loadWarehouseData() {
  const id = selectedWarehouseId.value
  if (!id) return
  await Promise.all([
    fetchProductSummaries(id),
    fetchBatches(id),
    fetchMinStocks(id),
  ])
}

// ── KPIs ────────────────────────────────────────────────────────────────────

const totalProducts = computed(() => productSummaries.value.length)
const totalUnits = computed(() => productSummaries.value.reduce((s, p) => s + p.total_quantity, 0))
const expiringSoonCount = computed(() => productSummaries.value.filter(p => p.expiration_status !== 'ok').length)
const belowMinCount = computed(() => productSummaries.value.filter(p => p.is_below_min).length)

// ── Stock tab state ─────────────────────────────────────────────────────────

const stockSearch = ref('')
const stockFilter = ref<'all' | 'warning' | 'critical'>('all')
const expandedProducts = ref(new Set<string>())

function toggleExpand(productId: string) {
  if (expandedProducts.value.has(productId)) {
    expandedProducts.value.delete(productId)
  } else {
    expandedProducts.value.add(productId)
  }
}

const filteredSummaries = computed(() => {
  let items = productSummaries.value
  if (stockSearch.value) {
    const q = stockSearch.value.toLowerCase()
    items = items.filter(p => p.product_name.toLowerCase().includes(q))
  }
  if (stockFilter.value === 'warning') {
    items = items.filter(p => p.expiration_status === 'warning' || p.expiration_status === 'critical')
  } else if (stockFilter.value === 'critical') {
    items = items.filter(p => p.expiration_status === 'critical')
  }
  return items
})

function batchesForProduct(productId: string): StockBatch[] {
  return batches.value.filter(b => b.product_id === productId)
}

// ── Incoming tab state ──────────────────────────────────────────────────────

const incomingProductId = ref('')
const incomingQuantity = ref<number | null>(null)
const incomingExpiration = ref('')
const incomingBatch = ref('')
const incomingLoading = ref(false)
const incomingError = ref('')
const recentBookings = ref<{ product_name: string; product_image: string | null; quantity: number; expiration: string | null }[]>([])

function productImagePath(productId: string): string | null {
  return products.value.find(p => p.id === productId)?.image_path ?? null
}
const showScanner = ref(false)
const scannedBarcode = ref('')

// Product autocomplete for incoming
const incomingProductQuery = ref('')
const incomingProductOpen = ref(false)
const incomingHighlightedIndex = ref(-1)

const incomingFilteredProducts = computed(() => {
  const q = incomingProductQuery.value.toLowerCase().trim()
  if (!q) return products.value
  return products.value.filter(p => p.name.toLowerCase().includes(q))
})

watch(incomingProductQuery, () => {
  if (!incomingProductOpen.value) return
  const q = incomingProductQuery.value.toLowerCase().trim()
  if (q && incomingFilteredProducts.value.length > 0) {
    const startsIdx = incomingFilteredProducts.value.findIndex(p => p.name.toLowerCase().startsWith(q))
    incomingHighlightedIndex.value = startsIdx >= 0 ? startsIdx : 0
  } else {
    incomingHighlightedIndex.value = -1
  }
})

const incomingSelectedProductName = computed(() => {
  if (!incomingProductId.value) return ''
  return products.value.find(p => p.id === incomingProductId.value)?.name ?? ''
})

function openIncomingProductAutocomplete() {
  incomingProductOpen.value = true
  incomingProductQuery.value = ''
  incomingHighlightedIndex.value = -1
  nextTick(() => {
    const input = document.getElementById('incoming-product-input') as HTMLInputElement | null
    input?.focus()
  })
}

function selectIncomingProduct(productId: string, productName: string) {
  incomingProductId.value = productId
  incomingProductOpen.value = false
  incomingProductQuery.value = ''
}

function handleIncomingProductBlur() {
  setTimeout(() => { incomingProductOpen.value = false }, 200)
}

function handleIncomingProductKeydown(event: KeyboardEvent) {
  const items = incomingFilteredProducts.value
  if (event.key === 'Escape') {
    event.preventDefault()
    incomingProductOpen.value = false
    return
  }
  if (event.key === 'ArrowDown') {
    event.preventDefault()
    incomingHighlightedIndex.value = Math.min(incomingHighlightedIndex.value + 1, items.length - 1)
    return
  }
  if (event.key === 'ArrowUp') {
    event.preventDefault()
    incomingHighlightedIndex.value = Math.max(incomingHighlightedIndex.value - 1, 0)
    return
  }
  if (event.key === 'Enter') {
    event.preventDefault()
    const p = items[incomingHighlightedIndex.value]
    if (incomingHighlightedIndex.value >= 0 && p) {
      selectIncomingProduct(p.id, p.name)
    }
  }
}

// Barcode assign flow (when barcode not found)
const showAssignBarcodeFlow = ref(false)
const assignBarcodeValue = ref('')
const assignBarcodeProductId = ref('')
const assignBarcodeLoading = ref(false)
const assignBarcodeError = ref('')

// Products that don't have any barcode yet
const productsWithoutBarcode = computed(() => {
  const barcodeProductIds = new Set(barcodes.value.map(b => b.product_id))
  return products.value.filter(p => !barcodeProductIds.has(p.id))
})

async function onBarcodeDetected(barcode: string) {
  showScanner.value = false
  scannedBarcode.value = barcode
  incomingError.value = ''
  showAssignBarcodeFlow.value = false
  const result = await lookupBarcode(barcode)
  if (result) {
    incomingProductId.value = result.product_id
    incomingProductOpen.value = false
  } else {
    // Show assign flow
    assignBarcodeValue.value = barcode
    assignBarcodeProductId.value = ''
    assignBarcodeError.value = ''
    showAssignBarcodeFlow.value = true
  }
}

async function assignBarcodeAndSelect() {
  if (!assignBarcodeProductId.value || !assignBarcodeValue.value) {
    assignBarcodeError.value = t('warehouse.selectProductForBarcode')
    return
  }
  assignBarcodeLoading.value = true
  assignBarcodeError.value = ''
  try {
    await addBarcode({ product_id: assignBarcodeProductId.value, barcode: assignBarcodeValue.value })
    // Select the product for incoming
    incomingProductId.value = assignBarcodeProductId.value
    showAssignBarcodeFlow.value = false
  } catch (err: any) {
    assignBarcodeError.value = err.message ?? t('warehouse.failedToAssignBarcode')
  } finally {
    assignBarcodeLoading.value = false
  }
}

async function submitIncoming() {
  if (!selectedWarehouseId.value || !incomingProductId.value || !incomingQuantity.value) {
    incomingError.value = t('warehouse.selectProductAndQuantity')
    return
  }
  incomingLoading.value = true
  incomingError.value = ''
  try {
    await bookIncoming({
      warehouse_id: selectedWarehouseId.value,
      product_id: incomingProductId.value,
      quantity: incomingQuantity.value,
      expiration_date: incomingExpiration.value || null,
      batch_number: incomingBatch.value.trim() || undefined,
    })
    const product = products.value.find(p => p.id === incomingProductId.value)
    recentBookings.value.unshift({
      product_name: product?.name ?? 'Unknown',
      product_image: product?.image_path ?? null,
      quantity: incomingQuantity.value,
      expiration: incomingExpiration.value || null,
    })
    // Reset form for next scan
    incomingProductId.value = ''
    incomingQuantity.value = null
    incomingExpiration.value = ''
    incomingBatch.value = ''
    scannedBarcode.value = ''
    showAssignBarcodeFlow.value = false
    // Refresh data
    await loadWarehouseData()
  } catch (err: any) {
    incomingError.value = err.message ?? t('warehouse.failedToBookIncoming')
  } finally {
    incomingLoading.value = false
  }
}

// ── Adjustment modal state ──────────────────────────────────────────────────

const showAdjustModal = ref(false)
const adjustBatch = ref<StockBatch | null>(null)
const adjustQuantity = ref<number | null>(null)
const adjustReason = ref<'adjustment_damage' | 'adjustment_expired' | 'adjustment_correction'>('adjustment_damage')
const adjustNotes = ref('')
const adjustLoading = ref(false)
const adjustError = ref('')

function openAdjust(batch: StockBatch) {
  adjustBatch.value = batch
  adjustQuantity.value = null
  adjustReason.value = 'adjustment_damage'
  adjustNotes.value = ''
  adjustError.value = ''
  showAdjustModal.value = true
}

async function submitAdjust() {
  if (!adjustBatch.value || !adjustQuantity.value) {
    adjustError.value = t('warehouse.enterQuantity')
    return
  }
  adjustLoading.value = true
  adjustError.value = ''
  try {
    await adjustStock({
      batch_id: adjustBatch.value.id,
      warehouse_id: adjustBatch.value.warehouse_id,
      product_id: adjustBatch.value.product_id,
      quantity_change: -Math.abs(adjustQuantity.value),
      reason: adjustReason.value,
      notes: adjustNotes.value.trim() || undefined,
    })
    showAdjustModal.value = false
    await loadWarehouseData()
  } catch (err: any) {
    adjustError.value = err.message ?? t('warehouse.failedToAdjustStock')
  } finally {
    adjustLoading.value = false
  }
}

// ── History tab state ───────────────────────────────────────────────────────

const historyFilterType = ref('')
const historyFilterProduct = ref('')
const historyLoaded = ref(false)

async function loadHistory() {
  if (!selectedWarehouseId.value) return
  historyLoaded.value = true
  await fetchTransactions(selectedWarehouseId.value, {
    type: historyFilterType.value || undefined,
    product_id: historyFilterProduct.value || undefined,
  })
}

async function loadMoreHistory() {
  if (!selectedWarehouseId.value) return
  await fetchMoreTransactions(selectedWarehouseId.value, {
    type: historyFilterType.value || undefined,
    product_id: historyFilterProduct.value || undefined,
  })
}

watch([historyFilterType, historyFilterProduct], () => {
  if (historyLoaded.value) loadHistory()
})

watch(activeTab, (tab) => {
  if (tab === 'history' && !historyLoaded.value) loadHistory()
})

// ── Warehouse settings modal state ──────────────────────────────────────────

const showWarehouseModal = ref(false)
const editingWarehouse = ref<Warehouse | null>(null)
const warehouseForm = ref({ name: '', address: '', notes: '' })
const warehouseLoading = ref(false)
const warehouseError = ref('')

function openAddWarehouse() {
  editingWarehouse.value = null
  warehouseForm.value = { name: '', address: '', notes: '' }
  warehouseError.value = ''
  showWarehouseModal.value = true
}

function openEditWarehouse(wh: Warehouse) {
  editingWarehouse.value = wh
  warehouseForm.value = { name: wh.name, address: wh.address ?? '', notes: wh.notes ?? '' }
  warehouseError.value = ''
  showWarehouseModal.value = true
}

async function submitWarehouse() {
  if (!warehouseForm.value.name.trim()) {
    warehouseError.value = t('warehouse.nameRequired')
    return
  }
  warehouseLoading.value = true
  warehouseError.value = ''
  try {
    if (editingWarehouse.value) {
      await updateWarehouse(editingWarehouse.value.id, {
        name: warehouseForm.value.name.trim(),
        address: warehouseForm.value.address.trim() || undefined,
        notes: warehouseForm.value.notes.trim() || undefined,
      })
    } else {
      const id = await createWarehouse({
        name: warehouseForm.value.name.trim(),
        address: warehouseForm.value.address.trim() || undefined,
        notes: warehouseForm.value.notes.trim() || undefined,
      })
      selectedWarehouseId.value = id
    }
    showWarehouseModal.value = false
  } catch (err: any) {
    warehouseError.value = err.message ?? t('warehouse.failedToSaveWarehouse')
  } finally {
    warehouseLoading.value = false
  }
}

const showDeleteWarehouseConfirm = ref(false)
const deletingWarehouse = ref<Warehouse | null>(null)

async function confirmDeleteWarehouse() {
  if (!deletingWarehouse.value) return
  warehouseLoading.value = true
  try {
    await deleteWarehouse(deletingWarehouse.value.id)
    if (selectedWarehouseId.value === deletingWarehouse.value.id) {
      selectedWarehouseId.value = warehouses.value[0]?.id ?? null
    }
    showDeleteWarehouseConfirm.value = false
  } catch (err: any) {
    warehouseError.value = err.message ?? t('warehouse.failedToDeleteWarehouse')
  } finally {
    warehouseLoading.value = false
  }
}

// ── Barcode modal state ─────────────────────────────────────────────────────

const showBarcodeModal = ref(false)
const barcodeForm = ref({ product_id: '', barcode: '' })
const barcodeLoading = ref(false)
const barcodeError = ref('')
const barcodeSettingsLoaded = ref(false)

async function loadBarcodeSettings() {
  if (!barcodeSettingsLoaded.value) {
    await fetchBarcodes()
    barcodeSettingsLoaded.value = true
  }
}

watch(activeTab, (tab) => {
  if (tab === 'settings') loadBarcodeSettings()
})

async function submitBarcode() {
  if (!barcodeForm.value.product_id || !barcodeForm.value.barcode.trim()) {
    barcodeError.value = t('warehouse.productAndBarcodeRequired')
    return
  }
  barcodeLoading.value = true
  barcodeError.value = ''
  try {
    await addBarcode({
      product_id: barcodeForm.value.product_id,
      barcode: barcodeForm.value.barcode.trim(),
    })
    showBarcodeModal.value = false
    barcodeForm.value = { product_id: '', barcode: '' }
  } catch (err: any) {
    barcodeError.value = err.message ?? t('warehouse.failedToAddBarcode')
  } finally {
    barcodeLoading.value = false
  }
}

// ── Min stock editing ───────────────────────────────────────────────────────

const minStockEdits = ref(new Map<string, number>())

function getMinStockValue(productId: string): number {
  if (minStockEdits.value.has(productId)) return minStockEdits.value.get(productId)!
  const entry = minStocks.value.find(m => m.product_id === productId)
  return entry?.min_quantity ?? 0
}

async function saveMinStock(productId: string) {
  if (!selectedWarehouseId.value) return
  const val = minStockEdits.value.get(productId) ?? 0
  await setMinStock({ product_id: productId, warehouse_id: selectedWarehouseId.value, min_quantity: val })
  minStockEdits.value.delete(productId)
  await fetchProductSummaries(selectedWarehouseId.value)
}

function formatDate(dateStr: string | null): string {
  if (!dateStr) return '—'
  return new Date(dateStr).toLocaleDateString('de-DE', { day: '2-digit', month: '2-digit', year: 'numeric' })
}
</script>

<template>
  <div class="flex flex-col gap-4 p-4 md:p-6">
    <!-- Header -->
    <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
      <h1 class="text-2xl font-bold">{{ t('warehouse.title') }}</h1>
      <div class="flex items-center gap-2">
        <!-- Warehouse selector -->
        <select
          v-if="warehouses.length > 0"
          v-model="selectedWarehouseId"
          class="h-9 rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        >
          <option v-for="wh in warehouses" :key="wh.id" :value="wh.id">{{ wh.name }}</option>
        </select>
        <button
          v-if="isAdmin"
          class="inline-flex h-9 items-center gap-1.5 rounded-md bg-primary px-3 text-sm font-medium text-primary-foreground hover:bg-primary/90"
          @click="openAddWarehouse"
        >
          <IconPlus class="size-4" />
          <span class="hidden sm:inline">{{ t('warehouse.addWarehouse') }}</span>
        </button>
      </div>
    </div>

    <!-- Empty state -->
    <div v-if="warehouses.length === 0 && !loading" class="flex flex-col items-center gap-4 py-16 text-center">
      <div class="rounded-full bg-muted p-4">
        <IconPackageImport class="size-8 text-muted-foreground" />
      </div>
      <div>
        <h2 class="text-lg font-semibold">{{ t('warehouse.noWarehousesYet') }}</h2>
        <p class="text-sm text-muted-foreground">{{ t('warehouse.createFirstWarehouse') }}</p>
      </div>
      <button
        v-if="isAdmin"
        class="inline-flex h-9 items-center gap-1.5 rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground hover:bg-primary/90"
        @click="openAddWarehouse"
      >
        <IconPlus class="size-4" />
        {{ t('warehouse.createWarehouse') }}
      </button>
    </div>

    <!-- Tabs -->
    <Tabs v-if="warehouses.length > 0" v-model="activeTab">
      <TabsList>
        <TabsTrigger value="overview">{{ t('warehouse.overview') }}</TabsTrigger>
        <TabsTrigger value="stock">{{ t('warehouse.stockTab') }}</TabsTrigger>
        <TabsTrigger value="incoming">{{ t('warehouse.incoming') }}</TabsTrigger>
        <TabsTrigger value="history">{{ t('warehouse.historyTab') }}</TabsTrigger>
        <TabsTrigger v-if="isAdmin" value="settings">{{ t('warehouse.settings') }}</TabsTrigger>
      </TabsList>

      <!-- ═══════════════════════════════════════════════════════════════════ -->
      <!-- OVERVIEW TAB                                                       -->
      <!-- ═══════════════════════════════════════════════════════════════════ -->
      <TabsContent value="overview">
        <div class="flex flex-col gap-4">
          <!-- KPI cards -->
          <div class="grid grid-cols-2 gap-3 lg:grid-cols-4">
            <Card>
              <CardHeader class="pb-2">
                <CardTitle class="text-sm font-medium text-muted-foreground">{{ t('warehouse.productsKpi') }}</CardTitle>
              </CardHeader>
              <CardContent>
                <div class="text-2xl font-bold">{{ totalProducts }}</div>
              </CardContent>
            </Card>
            <Card>
              <CardHeader class="pb-2">
                <CardTitle class="text-sm font-medium text-muted-foreground">{{ t('warehouse.totalUnits') }}</CardTitle>
              </CardHeader>
              <CardContent>
                <div class="text-2xl font-bold">{{ totalUnits }}</div>
              </CardContent>
            </Card>
            <Card>
              <CardHeader class="pb-2">
                <CardTitle class="text-sm font-medium text-muted-foreground">{{ t('warehouse.expiringSoon') }}</CardTitle>
              </CardHeader>
              <CardContent>
                <div class="text-2xl font-bold" :class="expiringSoonCount > 0 ? 'text-amber-600 dark:text-amber-400' : ''">{{ expiringSoonCount }}</div>
              </CardContent>
            </Card>
            <Card>
              <CardHeader class="pb-2">
                <CardTitle class="text-sm font-medium text-muted-foreground">{{ t('warehouse.belowMinStock') }}</CardTitle>
              </CardHeader>
              <CardContent>
                <div class="text-2xl font-bold" :class="belowMinCount > 0 ? 'text-red-600 dark:text-red-400' : ''">{{ belowMinCount }}</div>
              </CardContent>
            </Card>
          </div>

          <!-- MHD warnings -->
          <div v-if="productSummaries.some(p => p.expiration_status !== 'ok')" class="rounded-lg border border-amber-200 bg-amber-50 p-4 dark:border-amber-700 dark:bg-amber-950/20">
            <div class="flex items-center gap-2 font-medium text-amber-800 dark:text-amber-300">
              <IconAlertTriangle class="size-5" />
              {{ t('warehouse.expirationWarnings') }}
            </div>
            <div class="mt-3 space-y-2">
              <div
                v-for="p in productSummaries.filter(p => p.expiration_status !== 'ok')"
                :key="p.product_id"
                class="flex items-center justify-between rounded-md bg-white/60 px-3 py-2 dark:bg-white/5"
              >
                <div class="flex items-center gap-2">
                  <span :class="[expirationBadgeClass(p.expiration_status), 'inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium']">
                    {{ expirationLabel(p.expiration_status) }}
                  </span>
                  <img v-if="p.product_image_path" :src="getProductImageUrl(p.product_image_path)" class="size-5 rounded object-cover" alt="" />
                  <span class="text-sm font-medium">{{ p.product_name }}</span>
                  <span class="text-xs text-muted-foreground">{{ t('warehouse.unitsCount', { count: p.total_quantity }) }}</span>
                </div>
                <span class="text-sm text-muted-foreground">{{ t('warehouse.mhd', { date: formatDate(p.earliest_expiration) }) }}</span>
              </div>
            </div>
          </div>

          <!-- Product summary table -->
          <div class="rounded-md border">
            <table class="w-full text-sm">
              <thead>
                <tr class="border-b bg-muted/50 text-left">
                  <th class="px-4 py-3 font-medium">{{ t('warehouse.productCol') }}</th>
                  <th class="px-4 py-3 font-medium text-right">{{ t('warehouse.quantityCol') }}</th>
                  <th class="hidden px-4 py-3 font-medium text-right md:table-cell">{{ t('warehouse.minStockCol') }}</th>
                  <th class="hidden px-4 py-3 font-medium md:table-cell">{{ t('warehouse.earliestMhd') }}</th>
                  <th class="px-4 py-3 font-medium">{{ t('warehouse.statusCol') }}</th>
                </tr>
              </thead>
              <tbody>
                <tr v-if="loading && productSummaries.length === 0">
                  <td colspan="5" class="px-4 py-8 text-center text-muted-foreground">{{ t('common.loading') }}</td>
                </tr>
                <tr v-else-if="productSummaries.length === 0">
                  <td colspan="5" class="px-4 py-8 text-center text-muted-foreground">{{ t('warehouse.noStockInWarehouse') }}</td>
                </tr>
                <tr
                  v-for="p in productSummaries"
                  :key="p.product_id"
                  class="border-b last:border-0 hover:bg-muted/30 transition-colors"
                >
                  <td class="px-4 py-3">
                    <div class="flex items-center gap-2">
                      <img
                        v-if="p.product_image_path"
                        :src="getProductImageUrl(p.product_image_path)"
                        class="size-8 rounded object-cover"
                        alt=""
                      />
                      <div v-else class="flex size-8 items-center justify-center rounded bg-muted text-xs font-medium text-muted-foreground">
                        {{ p.product_name.charAt(0) }}
                      </div>
                      <span class="font-medium">{{ p.product_name }}</span>
                    </div>
                  </td>
                  <td class="px-4 py-3 text-right tabular-nums">{{ p.total_quantity }}</td>
                  <td class="hidden px-4 py-3 text-right tabular-nums md:table-cell">{{ p.min_stock || '—' }}</td>
                  <td class="hidden px-4 py-3 md:table-cell">{{ formatDate(p.earliest_expiration) }}</td>
                  <td class="px-4 py-3">
                    <div class="flex gap-1.5">
                      <span
                        v-if="p.expiration_status !== 'ok'"
                        :class="[expirationBadgeClass(p.expiration_status), 'inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium']"
                      >
                        {{ expirationLabel(p.expiration_status) }}
                      </span>
                      <span
                        v-if="p.is_below_min"
                        class="inline-flex items-center rounded-full bg-red-100 px-2 py-0.5 text-xs font-medium text-red-700 dark:bg-red-950/40 dark:text-red-400"
                      >
                        {{ t('warehouse.lowStock') }}
                      </span>
                      <span
                        v-if="p.expiration_status === 'ok' && !p.is_below_min"
                        class="inline-flex items-center rounded-full bg-green-100 px-2 py-0.5 text-xs font-medium text-green-700 dark:bg-green-950/40 dark:text-green-400"
                      >
                        {{ t('warehouse.ok') }}
                      </span>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </TabsContent>

      <!-- ═══════════════════════════════════════════════════════════════════ -->
      <!-- STOCK TAB                                                          -->
      <!-- ═══════════════════════════════════════════════════════════════════ -->
      <TabsContent value="stock">
        <div class="flex flex-col gap-4">
          <!-- Filters -->
          <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
            <div class="flex items-center gap-2">
              <div class="relative">
                <IconSearch class="absolute left-2.5 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
                <input
                  v-model="stockSearch"
                  type="text"
                  :placeholder="t('warehouse.searchProducts')"
                  class="h-9 rounded-md border border-input bg-background pl-8 pr-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
                />
              </div>
              <select
                v-model="stockFilter"
                class="h-9 rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
              >
                <option value="all">{{ t('warehouse.all') }}</option>
                <option value="warning">{{ t('warehouse.expiringSoonFilter') }}</option>
                <option value="critical">{{ t('warehouse.criticalFilter') }}</option>
              </select>
            </div>
            <button
              v-if="isAdmin"
              class="inline-flex h-9 items-center gap-1.5 rounded-md bg-primary px-3 text-sm font-medium text-primary-foreground hover:bg-primary/90"
              @click="activeTab = 'incoming'"
            >
              <IconPlus class="size-4" />
              {{ t('warehouse.addStock') }}
            </button>
          </div>

          <!-- Expandable stock table -->
          <div class="rounded-md border">
            <table class="w-full text-sm">
              <thead>
                <tr class="border-b bg-muted/50 text-left">
                  <th class="w-8 px-2 py-3"></th>
                  <th class="px-4 py-3 font-medium">{{ t('warehouse.productCol') }}</th>
                  <th class="px-4 py-3 font-medium text-right">{{ t('warehouse.totalQty') }}</th>
                  <th class="hidden px-4 py-3 font-medium md:table-cell">{{ t('warehouse.earliestMhd') }}</th>
                  <th class="px-4 py-3 font-medium">{{ t('warehouse.statusCol') }}</th>
                </tr>
              </thead>
              <tbody>
                <tr v-if="filteredSummaries.length === 0">
                  <td colspan="5" class="px-4 py-8 text-center text-muted-foreground">
                    {{ stockSearch || stockFilter !== 'all' ? t('warehouse.noMatchingProducts') : t('warehouse.noStock') }}
                  </td>
                </tr>
                <template v-for="p in filteredSummaries" :key="p.product_id">
                  <!-- Product row -->
                  <tr
                    class="border-b cursor-pointer hover:bg-muted/30 transition-colors"
                    @click="toggleExpand(p.product_id)"
                  >
                    <td class="px-2 py-3 text-center">
                      <component
                        :is="expandedProducts.has(p.product_id) ? IconChevronDown : IconChevronRight"
                        class="size-4 text-muted-foreground"
                      />
                    </td>
                    <td class="px-4 py-3">
                      <div class="flex items-center gap-2">
                        <img
                          v-if="p.product_image_path"
                          :src="getProductImageUrl(p.product_image_path)"
                          class="size-8 rounded object-cover"
                          alt=""
                        />
                        <div v-else class="flex size-8 items-center justify-center rounded bg-muted text-xs font-medium text-muted-foreground">
                          {{ p.product_name.charAt(0) }}
                        </div>
                        <div>
                          <span class="font-medium">{{ p.product_name }}</span>
                          <span class="ml-2 text-xs text-muted-foreground">{{ t('warehouse.batchCount', { count: p.batch_count }, p.batch_count) }}</span>
                        </div>
                      </div>
                    </td>
                    <td class="px-4 py-3 text-right tabular-nums font-medium">{{ p.total_quantity }}</td>
                    <td class="hidden px-4 py-3 md:table-cell">{{ formatDate(p.earliest_expiration) }}</td>
                    <td class="px-4 py-3">
                      <span
                        :class="[expirationBadgeClass(p.expiration_status), 'inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium']"
                      >
                        {{ expirationLabel(p.expiration_status) }}
                      </span>
                    </td>
                  </tr>
                  <!-- Expanded batch rows -->
                  <tr
                    v-if="expandedProducts.has(p.product_id)"
                    v-for="batch in batchesForProduct(p.product_id)"
                    :key="batch.id"
                    class="border-b bg-muted/20"
                  >
                    <td></td>
                    <td class="px-4 py-2 pl-12">
                      <span class="text-muted-foreground">{{ batch.batch_number || t('warehouse.noBatchNumber') }}</span>
                    </td>
                    <td class="px-4 py-2 text-right tabular-nums">{{ batch.quantity }}</td>
                    <td class="hidden px-4 py-2 md:table-cell">
                      <span
                        :class="[expirationBadgeClass(expirationStatus(batch.expiration_date)), 'inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium']"
                      >
                        {{ formatDate(batch.expiration_date) }}
                      </span>
                    </td>
                    <td class="px-4 py-2">
                      <button
                        v-if="isAdmin"
                        class="inline-flex h-7 items-center gap-1 rounded-md border px-2 text-xs hover:bg-muted"
                        @click.stop="openAdjust(batch)"
                      >
                        <IconAdjustments class="size-3.5" />
                        {{ t('warehouse.adjust') }}
                      </button>
                    </td>
                  </tr>
                </template>
              </tbody>
            </table>
          </div>
        </div>
      </TabsContent>

      <!-- ═══════════════════════════════════════════════════════════════════ -->
      <!-- INCOMING TAB                                                       -->
      <!-- ═══════════════════════════════════════════════════════════════════ -->
      <TabsContent value="incoming">
        <div class="mx-auto flex max-w-lg flex-col gap-4">
          <h2 class="text-lg font-semibold">{{ t('warehouse.incomingGoods') }}</h2>

          <!-- Barcode scanner area -->
          <div class="flex flex-col gap-2">
            <BarcodeScanner
              v-if="showScanner"
              @detected="onBarcodeDetected"
              @close="showScanner = false"
            />
            <div class="flex gap-2">
              <button
                class="inline-flex h-9 flex-1 items-center justify-center gap-1.5 rounded-md border border-input bg-background text-sm font-medium hover:bg-muted"
                @click="showScanner = !showScanner"
              >
                <IconBarcode class="size-4" />
                {{ showScanner ? t('warehouse.closeScanner') : t('warehouse.scanBarcode') }}
              </button>
            </div>
            <p v-if="scannedBarcode" class="text-xs text-muted-foreground">
              {{ t('warehouse.scanned', { barcode: scannedBarcode }) }}
            </p>
          </div>

          <!-- Barcode assign flow (when barcode not found) -->
          <div v-if="showAssignBarcodeFlow" class="rounded-md border border-amber-300 bg-amber-50 p-3 dark:border-amber-700 dark:bg-amber-950/20">
            <div class="mb-2 flex items-start justify-between gap-2">
              <p class="text-sm font-medium">{{ t('warehouse.unknownBarcode', { barcode: assignBarcodeValue }) }}</p>
              <button class="shrink-0 text-muted-foreground hover:text-foreground" @click="showAssignBarcodeFlow = false">
                <IconX class="size-4" />
              </button>
            </div>
            <select
              v-model="assignBarcodeProductId"
              class="mb-2 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
            >
              <option value="">{{ t('warehouse.assignToProduct') }}</option>
              <option v-for="p in productsWithoutBarcode" :key="p.id" :value="p.id">{{ p.name }}</option>
            </select>
            <button
              class="h-9 w-full rounded-md border border-input bg-background text-sm font-medium hover:bg-muted disabled:opacity-50"
              :disabled="assignBarcodeLoading || !assignBarcodeProductId"
              @click="assignBarcodeAndSelect"
            >
              {{ assignBarcodeLoading ? t('warehouse.assigningBarcode') : t('warehouse.assignBarcodeAndSelect') }}
            </button>
            <p v-if="assignBarcodeError" class="mt-1 text-xs text-red-600 dark:text-red-400">{{ assignBarcodeError }}</p>
          </div>

          <!-- Product selection (autocomplete) -->
          <div>
            <label class="mb-1 block text-sm font-medium">{{ t('warehouse.product') }} *</label>
            <div class="relative">
              <div v-if="incomingProductOpen">
                <input
                  id="incoming-product-input"
                  v-model="incomingProductQuery"
                  type="text"
                  :placeholder="t('warehouse.searchProducts')"
                  role="combobox"
                  aria-expanded="true"
                  aria-autocomplete="list"
                  autocomplete="off"
                  class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
                  @blur="handleIncomingProductBlur"
                  @keydown="handleIncomingProductKeydown"
                />
                <div class="absolute left-0 top-full z-50 mt-1 max-h-48 w-full overflow-auto rounded-md border bg-popover shadow-md" role="listbox">
                  <button
                    v-for="(p, idx) in incomingFilteredProducts"
                    :key="p.id"
                    type="button"
                    tabindex="-1"
                    class="flex w-full items-center gap-2 px-3 py-1.5 text-left text-sm hover:bg-accent"
                    :class="{ 'bg-accent': incomingHighlightedIndex === idx }"
                    role="option"
                    @mousedown.prevent="selectIncomingProduct(p.id, p.name)"
                  >
                    <img v-if="p.image_path" :src="getProductImageUrl(p.image_path)" class="size-5 rounded object-cover" alt="" />
                    <div v-else class="flex size-5 items-center justify-center rounded bg-muted text-[10px] font-medium text-muted-foreground">{{ p.name.charAt(0) }}</div>
                    {{ p.name }}
                  </button>
                  <div v-if="incomingFilteredProducts.length === 0 && incomingProductQuery.trim()" class="px-3 py-2 text-xs text-muted-foreground">
                    {{ t('warehouse.noProductsFound') }}
                  </div>
                </div>
              </div>
              <button
                v-else
                type="button"
                class="flex h-9 w-full items-center gap-2 rounded-md border border-input bg-background px-3 text-sm transition-colors hover:bg-muted"
                @click="openIncomingProductAutocomplete"
              >
                <template v-if="incomingProductId">
                  <img v-if="productImagePath(incomingProductId)" :src="getProductImageUrl(productImagePath(incomingProductId)!)" class="size-5 rounded object-cover" alt="" />
                  <div v-else class="flex size-5 items-center justify-center rounded bg-muted text-[10px] font-medium text-muted-foreground">{{ incomingSelectedProductName.charAt(0) }}</div>
                  <span class="text-foreground">{{ incomingSelectedProductName }}</span>
                </template>
                <span v-else class="text-muted-foreground">{{ t('warehouse.selectProduct') }}</span>
              </button>
            </div>
          </div>

          <!-- Quantity -->
          <div>
            <label class="mb-1 block text-sm font-medium">{{ t('warehouse.quantity') }} *</label>
            <input
              v-model.number="incomingQuantity"
              type="number"
              min="1"
              :placeholder="t('warehouse.quantityPlaceholder')"
              class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
            />
          </div>

          <!-- Expiration date (optional) -->
          <div>
            <label class="mb-1 block text-sm font-medium">{{ t('warehouse.expirationDate') }}</label>
            <input
              v-model="incomingExpiration"
              type="date"
              class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
            />
            <p class="mt-1 text-xs text-muted-foreground">{{ t('warehouse.expirationHint') }}</p>
          </div>

          <!-- Batch number -->
          <div>
            <label class="mb-1 block text-sm font-medium">{{ t('warehouse.batchLotNumber') }}</label>
            <input
              v-model="incomingBatch"
              type="text"
              :placeholder="t('warehouse.optional')"
              class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
            />
          </div>

          <!-- Error -->
          <p v-if="incomingError" class="text-sm text-red-600 dark:text-red-400">{{ incomingError }}</p>

          <!-- Submit -->
          <button
            class="inline-flex h-10 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-50"
            :disabled="incomingLoading || !incomingProductId || !incomingQuantity"
            @click="submitIncoming"
          >
            {{ incomingLoading ? t('warehouse.booking') : t('warehouse.bookIncoming') }}
          </button>

          <!-- Recent bookings -->
          <div v-if="recentBookings.length > 0" class="space-y-2">
            <h3 class="text-sm font-medium text-muted-foreground">{{ t('warehouse.justBooked') }}</h3>
            <div
              v-for="(item, i) in recentBookings"
              :key="i"
              class="flex items-center justify-between rounded-md border bg-green-50 px-3 py-2 text-sm dark:bg-green-950/20"
            >
              <div class="flex items-center gap-2">
                <img v-if="item.product_image" :src="getProductImageUrl(item.product_image)" class="size-5 rounded object-cover" alt="" />
                <div v-else class="flex size-5 items-center justify-center rounded bg-muted text-[10px] font-medium text-muted-foreground">{{ item.product_name.charAt(0) }}</div>
                <span>{{ item.quantity }}x {{ item.product_name }}</span>
              </div>
              <span v-if="item.expiration" class="text-muted-foreground">{{ t('warehouse.mhd', { date: formatDate(item.expiration) }) }}</span>
            </div>
          </div>
        </div>
      </TabsContent>

      <!-- ═══════════════════════════════════════════════════════════════════ -->
      <!-- HISTORY TAB                                                        -->
      <!-- ═══════════════════════════════════════════════════════════════════ -->
      <TabsContent value="history">
        <div class="flex flex-col gap-4">
          <!-- Filters -->
          <div class="flex flex-col gap-2 sm:flex-row sm:items-center">
            <select
              v-model="historyFilterType"
              class="h-9 rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
            >
              <option value="">{{ t('warehouse.allTypes') }}</option>
              <option value="incoming">{{ t('warehouse.incomingFilter') }}</option>
              <option value="outgoing_refill">{{ t('warehouse.refillFilter') }}</option>
              <option value="adjustment_damage">{{ t('warehouse.damagedFilter') }}</option>
              <option value="adjustment_expired">{{ t('warehouse.expiredFilter') }}</option>
              <option value="adjustment_correction">{{ t('warehouse.correctionFilter') }}</option>
            </select>
            <select
              v-model="historyFilterProduct"
              class="h-9 rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
            >
              <option value="">{{ t('warehouse.allProducts') }}</option>
              <option v-for="p in products" :key="p.id" :value="p.id">{{ p.name }}</option>
            </select>
          </div>

          <!-- Transaction table -->
          <div class="rounded-md border">
            <table class="w-full text-sm">
              <thead>
                <tr class="border-b bg-muted/50 text-left">
                  <th class="px-4 py-3 font-medium">{{ t('warehouse.timeCol') }}</th>
                  <th class="px-4 py-3 font-medium">{{ t('warehouse.typeCol') }}</th>
                  <th class="px-4 py-3 font-medium">{{ t('warehouse.productCol') }}</th>
                  <th class="hidden px-4 py-3 font-medium md:table-cell">{{ t('warehouse.batchCol') }}</th>
                  <th class="px-4 py-3 font-medium text-right">{{ t('warehouse.qtyCol') }}</th>
                  <th class="hidden px-4 py-3 font-medium md:table-cell">{{ t('warehouse.userCol') }}</th>
                </tr>
              </thead>
              <tbody>
                <tr v-if="transactionLoading && transactions.length === 0">
                  <td colspan="6" class="px-4 py-8 text-center text-muted-foreground">{{ t('common.loading') }}</td>
                </tr>
                <tr v-else-if="transactions.length === 0">
                  <td colspan="6" class="px-4 py-8 text-center text-muted-foreground">{{ t('warehouse.noTransactions') }}</td>
                </tr>
                <tr
                  v-for="t in transactions"
                  :key="t.id"
                  class="border-b last:border-0 hover:bg-muted/30 transition-colors"
                >
                  <td class="px-4 py-3 text-muted-foreground">{{ timeAgo(t.created_at) }}</td>
                  <td class="px-4 py-3">
                    <span :class="[transactionTypeBadgeClass(t.transaction_type), 'inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium']">
                      {{ transactionTypeLabel(t.transaction_type) }}
                    </span>
                  </td>
                  <td class="px-4 py-3">
                    <div class="flex items-center gap-2">
                      <img v-if="productImagePath(t.product_id)" :src="getProductImageUrl(productImagePath(t.product_id)!)" class="size-6 rounded object-cover" alt="" />
                      <div v-else class="flex size-6 items-center justify-center rounded bg-muted text-[10px] font-medium text-muted-foreground">{{ (t.product_name ?? '?').charAt(0) }}</div>
                      <span class="font-medium">{{ t.product_name ?? '—' }}</span>
                    </div>
                  </td>
                  <td class="hidden px-4 py-3 md:table-cell text-muted-foreground">{{ t.batch_number ?? '—' }}</td>
                  <td class="px-4 py-3 text-right tabular-nums" :class="t.quantity_change > 0 ? 'text-green-600 dark:text-green-400' : 'text-red-600 dark:text-red-400'">
                    {{ t.quantity_change > 0 ? '+' : '' }}{{ t.quantity_change }}
                  </td>
                  <td class="hidden px-4 py-3 md:table-cell text-muted-foreground">{{ (t.metadata as any)?._user_email ?? '—' }}</td>
                </tr>
              </tbody>
            </table>
          </div>
          <button
            v-if="transactionHasMore"
            class="inline-flex h-9 items-center justify-center rounded-md border px-4 text-sm font-medium hover:bg-muted disabled:opacity-50"
            :disabled="transactionLoading"
            @click="loadMoreHistory"
          >
            {{ transactionLoading ? t('common.loading') : t('warehouse.loadMore') }}
          </button>
        </div>
      </TabsContent>

      <!-- ═══════════════════════════════════════════════════════════════════ -->
      <!-- SETTINGS TAB (admin only)                                          -->
      <!-- ═══════════════════════════════════════════════════════════════════ -->
      <TabsContent v-if="isAdmin" value="settings">
        <div class="flex flex-col gap-6">
          <!-- Warehouses management -->
          <div>
            <div class="mb-3 flex items-center justify-between">
              <h2 class="text-lg font-semibold">{{ t('warehouse.warehouses') }}</h2>
              <button
                class="inline-flex h-8 items-center gap-1 rounded-md bg-primary px-3 text-xs font-medium text-primary-foreground hover:bg-primary/90"
                @click="openAddWarehouse"
              >
                <IconPlus class="size-3.5" />
                {{ t('common.add') }}
              </button>
            </div>
            <div class="rounded-md border">
              <table class="w-full text-sm">
                <thead>
                  <tr class="border-b bg-muted/50 text-left">
                    <th class="px-4 py-3 font-medium">{{ t('common.name') }}</th>
                    <th class="hidden px-4 py-3 font-medium md:table-cell">{{ t('warehouse.warehouseAddress') }}</th>
                    <th class="px-4 py-3 font-medium text-right">{{ t('common.actions') }}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    v-for="wh in warehouses"
                    :key="wh.id"
                    class="border-b last:border-0 hover:bg-muted/30 transition-colors"
                  >
                    <td class="px-4 py-3 font-medium">{{ wh.name }}</td>
                    <td class="hidden px-4 py-3 md:table-cell text-muted-foreground">{{ wh.address ?? '—' }}</td>
                    <td class="px-4 py-3 text-right">
                      <div class="flex items-center justify-end gap-1">
                        <button class="h-7 rounded-md border px-2 text-xs hover:bg-muted" @click="openEditWarehouse(wh)">{{ t('common.edit') }}</button>
                        <button
                          class="h-7 rounded-md border border-red-200 px-2 text-xs text-red-600 hover:bg-red-50 dark:border-red-800 dark:text-red-400 dark:hover:bg-red-950/20"
                          @click="deletingWarehouse = wh; showDeleteWarehouseConfirm = true"
                        >
                          <IconTrash class="size-3.5" />
                        </button>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <!-- Barcode management -->
          <div>
            <div class="mb-3 flex items-center justify-between">
              <h2 class="text-lg font-semibold">{{ t('warehouse.barcodesSection') }}</h2>
              <button
                class="inline-flex h-8 items-center gap-1 rounded-md bg-primary px-3 text-xs font-medium text-primary-foreground hover:bg-primary/90"
                @click="barcodeForm = { product_id: '', barcode: '' }; barcodeError = ''; showBarcodeModal = true"
              >
                <IconPlus class="size-3.5" />
                {{ t('common.add') }}
              </button>
            </div>
            <div class="rounded-md border">
              <table class="w-full text-sm">
                <thead>
                  <tr class="border-b bg-muted/50 text-left">
                    <th class="px-4 py-3 font-medium">{{ t('warehouse.barcodeCol') }}</th>
                    <th class="px-4 py-3 font-medium">{{ t('warehouse.productCol') }}</th>
                    <th class="hidden px-4 py-3 font-medium md:table-cell">{{ t('warehouse.formatCol') }}</th>
                    <th class="px-4 py-3 font-medium text-right">{{ t('common.actions') }}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr v-if="barcodes.length === 0">
                    <td colspan="4" class="px-4 py-6 text-center text-muted-foreground">{{ t('warehouse.noBarcodesYet') }}</td>
                  </tr>
                  <tr
                    v-for="b in barcodes"
                    :key="b.id"
                    class="border-b last:border-0 hover:bg-muted/30 transition-colors"
                  >
                    <td class="px-4 py-3 font-mono text-xs">{{ b.barcode }}</td>
                    <td class="px-4 py-3">
                      <div class="flex items-center gap-2">
                        <img v-if="productImagePath(b.product_id)" :src="getProductImageUrl(productImagePath(b.product_id)!)" class="size-6 rounded object-cover" alt="" />
                        <div v-else class="flex size-6 items-center justify-center rounded bg-muted text-[10px] font-medium text-muted-foreground">{{ (b.product_name ?? '?').charAt(0) }}</div>
                        <span>{{ b.product_name ?? '—' }}</span>
                      </div>
                    </td>
                    <td class="hidden px-4 py-3 md:table-cell text-muted-foreground">{{ b.format }}</td>
                    <td class="px-4 py-3 text-right">
                      <button
                        class="h-7 rounded-md border border-red-200 px-2 text-xs text-red-600 hover:bg-red-50 dark:border-red-800 dark:text-red-400 dark:hover:bg-red-950/20"
                        @click="removeBarcode(b.id)"
                      >
                        <IconTrash class="size-3.5" />
                      </button>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <!-- Min stock thresholds -->
          <div>
            <h2 class="mb-3 text-lg font-semibold">{{ t('warehouse.minStockThresholds') }}</h2>
            <p class="mb-3 text-sm text-muted-foreground">{{ t('warehouse.minStockDescription', { name: selectedWarehouse?.name ?? '' }) }}</p>
            <div class="rounded-md border">
              <table class="w-full text-sm">
                <thead>
                  <tr class="border-b bg-muted/50 text-left">
                    <th class="px-4 py-3 font-medium">{{ t('warehouse.productCol') }}</th>
                    <th class="px-4 py-3 font-medium">{{ t('warehouse.currentStockCol') }}</th>
                    <th class="px-4 py-3 font-medium">{{ t('warehouse.minStockCol') }}</th>
                    <th class="px-4 py-3 font-medium text-right">{{ t('common.actions') }}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr v-if="products.length === 0">
                    <td colspan="4" class="px-4 py-6 text-center text-muted-foreground">{{ t('warehouse.noProducts') }}</td>
                  </tr>
                  <tr
                    v-for="p in products"
                    :key="p.id"
                    class="border-b last:border-0 hover:bg-muted/30 transition-colors"
                  >
                    <td class="px-4 py-3">
                      <div class="flex items-center gap-2">
                        <img v-if="p.image_path" :src="getProductImageUrl(p.image_path)" class="size-6 rounded object-cover" alt="" />
                        <div v-else class="flex size-6 items-center justify-center rounded bg-muted text-[10px] font-medium text-muted-foreground">{{ p.name.charAt(0) }}</div>
                        <span class="font-medium">{{ p.name }}</span>
                      </div>
                    </td>
                    <td class="px-4 py-3 tabular-nums">
                      {{ productSummaries.find(s => s.product_id === p.id)?.total_quantity ?? 0 }}
                    </td>
                    <td class="px-4 py-3">
                      <input
                        type="number"
                        min="0"
                        :value="getMinStockValue(p.id)"
                        class="h-8 w-20 rounded-md border border-input bg-background px-2 text-sm tabular-nums focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
                        @input="minStockEdits.set(p.id, Number(($event.target as HTMLInputElement).value))"
                      />
                    </td>
                    <td class="px-4 py-3 text-right">
                      <button
                        v-if="minStockEdits.has(p.id)"
                        class="h-7 rounded-md bg-primary px-2 text-xs font-medium text-primary-foreground hover:bg-primary/90"
                        @click="saveMinStock(p.id)"
                      >
                        {{ t('common.save') }}
                      </button>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </div>
      </TabsContent>
    </Tabs>

    <!-- ═══════════════════════════════════════════════════════════════════── -->
    <!-- MODALS                                                               -->
    <!-- ═══════════════════════════════════════════════════════════════════── -->

    <!-- Warehouse add/edit modal -->
    <div
      v-if="showWarehouseModal"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/40"
      @click.self="showWarehouseModal = false"
    >
      <div class="w-full max-w-md rounded-xl border bg-card p-6 shadow-lg">
        <h2 class="mb-4 text-lg font-semibold">{{ editingWarehouse ? t('warehouse.editWarehouseModal') : t('warehouse.addWarehouseModal') }}</h2>
        <form class="flex flex-col gap-3" @submit.prevent="submitWarehouse">
          <div>
            <label class="mb-1 block text-sm font-medium">{{ t('common.name') }} *</label>
            <input v-model="warehouseForm.name" type="text" class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring" />
          </div>
          <div>
            <label class="mb-1 block text-sm font-medium">{{ t('warehouse.warehouseAddress') }}</label>
            <input v-model="warehouseForm.address" type="text" class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring" />
          </div>
          <div>
            <label class="mb-1 block text-sm font-medium">{{ t('common.notes') }}</label>
            <textarea v-model="warehouseForm.notes" rows="2" class="w-full rounded-md border border-input bg-background px-3 py-2 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"></textarea>
          </div>
          <p v-if="warehouseError" class="text-sm text-red-600">{{ warehouseError }}</p>
          <div class="flex justify-end gap-2">
            <button type="button" class="h-9 rounded-md border px-4 text-sm hover:bg-muted" @click="showWarehouseModal = false">{{ t('common.cancel') }}</button>
            <button type="submit" class="h-9 rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-50" :disabled="warehouseLoading">
              {{ warehouseLoading ? t('common.saving') : t('common.save') }}
            </button>
          </div>
        </form>
      </div>
    </div>

    <!-- Delete warehouse confirm modal -->
    <div
      v-if="showDeleteWarehouseConfirm"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/40"
      @click.self="showDeleteWarehouseConfirm = false"
    >
      <div class="w-full max-w-sm rounded-xl border bg-card p-6 shadow-lg">
        <h2 class="mb-2 text-lg font-semibold">{{ t('warehouse.deleteWarehouseTitle') }}</h2>
        <p class="mb-4 text-sm text-muted-foreground">
          {{ t('warehouse.deleteWarehouseConfirm', { name: deletingWarehouse?.name ?? '' }) }}
        </p>
        <div class="flex justify-end gap-2">
          <button class="h-9 rounded-md border px-4 text-sm hover:bg-muted" @click="showDeleteWarehouseConfirm = false">{{ t('common.cancel') }}</button>
          <button
            class="h-9 rounded-md bg-red-600 px-4 text-sm font-medium text-white hover:bg-red-700 disabled:opacity-50"
            :disabled="warehouseLoading"
            @click="confirmDeleteWarehouse"
          >
            {{ t('common.delete') }}
          </button>
        </div>
      </div>
    </div>

    <!-- Adjustment modal -->
    <div
      v-if="showAdjustModal"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/40"
      @click.self="showAdjustModal = false"
    >
      <div class="w-full max-w-md rounded-xl border bg-card p-6 shadow-lg">
        <h2 class="mb-4 text-lg font-semibold">{{ t('warehouse.adjustStockTitle') }}</h2>
        <p class="mb-3 text-sm text-muted-foreground">
          {{ t('warehouse.adjustBatchInfo', { product: adjustBatch?.product_name ?? '', batch: adjustBatch?.batch_number || t('warehouse.noBatchId'), quantity: adjustBatch?.quantity ?? 0 }) }}
        </p>
        <form class="flex flex-col gap-3" @submit.prevent="submitAdjust">
          <div>
            <label class="mb-1 block text-sm font-medium">{{ t('warehouse.reason') }} *</label>
            <select v-model="adjustReason" class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring">
              <option value="adjustment_damage">{{ t('warehouse.damaged') }}</option>
              <option value="adjustment_expired">{{ t('warehouse.expiredDisposed') }}</option>
              <option value="adjustment_correction">{{ t('warehouse.inventoryCorrection') }}</option>
            </select>
          </div>
          <div>
            <label class="mb-1 block text-sm font-medium">{{ t('warehouse.quantityToRemove') }} *</label>
            <input v-model.number="adjustQuantity" type="number" min="1" :max="adjustBatch?.quantity" class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring" />
          </div>
          <div>
            <label class="mb-1 block text-sm font-medium">{{ t('common.notes') }}</label>
            <textarea v-model="adjustNotes" rows="2" class="w-full rounded-md border border-input bg-background px-3 py-2 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring" :placeholder="t('warehouse.optionalDetails')"></textarea>
          </div>
          <p v-if="adjustError" class="text-sm text-red-600">{{ adjustError }}</p>
          <div class="flex justify-end gap-2">
            <button type="button" class="h-9 rounded-md border px-4 text-sm hover:bg-muted" @click="showAdjustModal = false">{{ t('common.cancel') }}</button>
            <button type="submit" class="h-9 rounded-md bg-red-600 px-4 text-sm font-medium text-white hover:bg-red-700 disabled:opacity-50" :disabled="adjustLoading">
              {{ adjustLoading ? t('warehouse.adjusting') : t('warehouse.removeStock') }}
            </button>
          </div>
        </form>
      </div>
    </div>

    <!-- Barcode add modal -->
    <div
      v-if="showBarcodeModal"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/40"
      @click.self="showBarcodeModal = false"
    >
      <div class="w-full max-w-md rounded-xl border bg-card p-6 shadow-lg">
        <h2 class="mb-4 text-lg font-semibold">{{ t('warehouse.addBarcodeTitle') }}</h2>
        <form class="flex flex-col gap-3" @submit.prevent="submitBarcode">
          <div>
            <label class="mb-1 block text-sm font-medium">{{ t('warehouse.product') }} *</label>
            <select v-model="barcodeForm.product_id" class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring">
              <option value="">{{ t('warehouse.selectProduct') }}</option>
              <option v-for="p in products" :key="p.id" :value="p.id">{{ p.name }}</option>
            </select>
          </div>
          <div>
            <label class="mb-1 block text-sm font-medium">{{ t('warehouse.barcodeEan') }} *</label>
            <input v-model="barcodeForm.barcode" type="text" :placeholder="t('warehouse.barcodeEanPlaceholder')" class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm font-mono focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring" />
          </div>
          <p v-if="barcodeError" class="text-sm text-red-600">{{ barcodeError }}</p>
          <div class="flex justify-end gap-2">
            <button type="button" class="h-9 rounded-md border px-4 text-sm hover:bg-muted" @click="showBarcodeModal = false">{{ t('common.cancel') }}</button>
            <button type="submit" class="h-9 rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-50" :disabled="barcodeLoading">
              {{ barcodeLoading ? t('common.saving') : t('common.save') }}
            </button>
          </div>
        </form>
      </div>
    </div>
  </div>
</template>
