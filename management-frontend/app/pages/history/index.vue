<script setup lang="ts">
definePageMeta({ middleware: 'auth' })

import { formatDate, formatTime, formatDateTime } from '@/lib/utils'
import { useActivityLog } from '@/composables/useActivityLog'
import { useActivityDescriptor } from '@/composables/useActivityDescriptor'
import { useProducts } from '@/composables/useProducts'
import {
  ShoppingCart, Trash2, PlusCircle, RotateCcw, CircleDollarSign, Settings,
  Package, PackagePlus, Truck, Repeat, Wallet, Coins, Link as LinkIcon, Unlink,
  Activity, MapPin, Hash, Euro, CreditCard, Clock, Cpu, Warehouse, Boxes,
  LayoutGrid, Plus, Tag, StickyNote, RefreshCw, ArrowUpRight, ArrowDownRight, ArrowRight,
  ChevronDown,
} from 'lucide-vue-next'

const { t, locale } = useI18n()
const supabase = useSupabaseClient()

const {
  logs,
  loading,
  hasMore,
  entityTypeFilter,
  dateFrom,
  dateTo,
  searchQuery,
  fetchLogs,
  fetchMore,
  subscribe,
} = useActivityLog()

// ── Machine-name + product lookups ──────────────────────────────────────────
// Resolve machine_id → name (so chips show the name, never a raw UUID) and
// product_id/name → thumbnail image.
const machineNameMap = ref<Map<string, string>>(new Map())
// device/embedded id → machine name (sale_recorded/credit_sent carry the
// embedded id, not machine_id). NB: the linking column on vendingMachine is
// `embedded` (= embeddeds.id), NOT `embedded_id`.
const deviceMachineNameMap = ref<Map<string, string>>(new Map())
async function fetchMachineNames() {
  const { data } = await (supabase as any).from('vendingMachine').select('id, name, embedded')
  const byId = new Map<string, string>()
  const byDevice = new Map<string, string>()
  for (const r of (data ?? []) as { id: string; name: string | null; embedded: string | null }[]) {
    if (!r.name) continue
    byId.set(r.id, r.name)
    if (r.embedded) byDevice.set(r.embedded, r.name)
  }
  machineNameMap.value = byId
  deviceMachineNameMap.value = byDevice
}
const resolveMachineName = (id: string) => machineNameMap.value.get(id)
const resolveMachineNameByDevice = (deviceId: string) => deviceMachineNameMap.value.get(deviceId)

const { products, fetchProducts } = useProducts()
const productsById = computed(() => {
  const m = new Map<string, { image_url: string | null }>()
  for (const p of products.value) m.set(p.id, p)
  return m
})
const productsByName = computed(() => {
  const m = new Map<string, { image_url: string | null }>()
  for (const p of products.value) m.set(p.name.toLowerCase(), p)
  return m
})
function resolveProductImage(ref: { productId?: string; productName?: string } | null): string | null {
  if (!ref) return null
  let p = ref.productId ? productsById.value.get(ref.productId) : undefined
  if (!p && ref.productName) p = productsByName.value.get(ref.productName.toLowerCase())
  return p?.image_url ?? null
}

// Labels, icons + detail chips are centralised in the descriptor so /history
// and the dashboard feed render every action type identically.
const { actionLabel, actionIcon, metadataChips, productRef, productRefs, activityDetailsFor } = useActivityDescriptor({
  machineName: resolveMachineName,
  machineNameByDevice: resolveMachineNameByDevice,
})

// lucide component registry — the descriptor returns icon names as strings.
const ICONS: Record<string, unknown> = {
  ShoppingCart, Trash2, PlusCircle, RotateCcw, CircleDollarSign, Settings,
  Package, PackagePlus, Truck, Repeat, Wallet, Coins, Link: LinkIcon, Unlink,
  Activity, MapPin, Hash, Euro, CreditCard, Clock, Cpu, Warehouse, Boxes,
  LayoutGrid, Plus, Tag, StickyNote, RefreshCw, ArrowUpRight, ArrowDownRight, ArrowRight,
}
const iconComp = (name?: string) => (name && ICONS[name]) || Activity

// Leading action-badge colour per semantic tint bucket.
const TINT_CLASSES: Record<string, string> = {
  sale: 'bg-emerald-100 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-400',
  danger: 'bg-red-100 text-red-700 dark:bg-red-950/50 dark:text-red-400',
  credit: 'bg-blue-100 text-blue-700 dark:bg-blue-950/50 dark:text-blue-400',
  stock: 'bg-amber-100 text-amber-700 dark:bg-amber-950/50 dark:text-amber-400',
  tour: 'bg-indigo-100 text-indigo-700 dark:bg-indigo-950/50 dark:text-indigo-400',
  cashbook: 'bg-teal-100 text-teal-700 dark:bg-teal-950/50 dark:text-teal-400',
  config: 'bg-slate-100 text-slate-700 dark:bg-slate-800/60 dark:text-slate-300',
  neutral: 'bg-muted text-muted-foreground',
}

const ENTITY_TYPES = computed(() => [
  { value: '', label: t('history.allEvents') },
  { value: 'sale', label: t('history.salesFilter') },
  { value: 'credit', label: t('history.creditSends') },
  { value: 'stock', label: t('history.stockChanges') },
  { value: 'firmware', label: t('history.firmwareFilter') },
  { value: 'device', label: t('history.devicesFilter') },
])

// Reload when filters change
watch([entityTypeFilter, dateFrom, dateTo], () => fetchLogs())

let unsubscribe: (() => void) | null = null

onMounted(async () => {
  await Promise.all([fetchLogs(), fetchMachineNames(), fetchProducts()])
  unsubscribe = subscribe()
})

onUnmounted(() => {
  unsubscribe?.()
})

// Group logs by date for section headers
const groupedLogs = computed(() => {
  const groups: { date: string; label: string; entries: typeof logs.value }[] = []
  let currentDate = ''
  for (const entry of logs.value) {
    const day = new Date(entry.created_at).toISOString().slice(0, 10)
    if (day !== currentDate) {
      currentDate = day
      const d = new Date(entry.created_at)
      const today = new Date()
      const yesterday = new Date()
      yesterday.setDate(yesterday.getDate() - 1)
      let label: string
      if (d.toDateString() === today.toDateString()) {
        label = t('history.today')
      } else if (d.toDateString() === yesterday.toDateString()) {
        label = t('history.yesterday')
      } else {
        label = formatDate(entry.created_at, locale.value)
      }
      groups.push({ date: day, label, entries: [] })
    }
    groups[groups.length - 1].entries.push(entry)
  }
  return groups
})

// ── Expandable rows (product-refill breakdown + technical details) ─────────
const expandedIds = ref<Set<string>>(new Set())
function isExpanded(id: string): boolean {
  return expandedIds.value.has(id)
}
function toggleExpanded(id: string) {
  const next = new Set(expandedIds.value)
  if (next.has(id)) next.delete(id)
  else next.add(id)
  expandedIds.value = next
}
function visibleProductRefs(entry: { id: string; action: string; metadata: Record<string, unknown> | null }) {
  const refs = productRefs(entry)
  return isExpanded(entry.id) ? refs : refs.slice(0, 3)
}
function hasExpandableContent(entry: { id: string; action: string; metadata: Record<string, unknown> | null }): boolean {
  return productRefs(entry).length > 3 || activityDetailsFor(entry).length > 0
}
</script>

<template>
  <div class="flex flex-1 flex-col gap-6 p-4 md:p-6">
    <!-- Header -->
    <div class="flex flex-wrap items-center justify-between gap-4">
      <div>
        <h1 class="text-2xl font-bold tracking-tight">{{ t('history.title') }}</h1>
        <p class="text-sm text-muted-foreground">{{ t('history.subtitle') }}</p>
      </div>
      <NuxtLink
        to="/tour-history"
        class="inline-flex h-9 items-center gap-1.5 rounded-md border border-input px-3 text-sm font-medium hover:bg-muted transition-colors"
      >
        {{ t('tourHistory.viewTourHistory') }}
      </NuxtLink>
    </div>

    <!-- Filters -->
    <div class="flex flex-wrap gap-3">
      <input
        v-model="searchQuery"
        type="text"
        :placeholder="t('history.searchPlaceholder')"
        class="h-9 w-full sm:w-56 rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm focus:outline-none focus:ring-1 focus:ring-ring"
      />
      <select
        v-model="entityTypeFilter"
        class="h-9 rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm focus:outline-none focus:ring-1 focus:ring-ring"
      >
        <option v-for="opt in ENTITY_TYPES" :key="opt.value" :value="opt.value">
          {{ opt.label }}
        </option>
      </select>

      <input
        v-model="dateFrom"
        type="date"
        placeholder="From"
        class="h-9 rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm focus:outline-none focus:ring-1 focus:ring-ring"
      />
      <input
        v-model="dateTo"
        type="date"
        placeholder="To"
        class="h-9 rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm focus:outline-none focus:ring-1 focus:ring-ring"
      />

      <button
        v-if="entityTypeFilter || dateFrom || dateTo || searchQuery"
        class="h-9 rounded-md border border-input px-3 py-1 text-sm text-muted-foreground hover:bg-muted"
        @click="entityTypeFilter = ''; dateFrom = ''; dateTo = ''; searchQuery = ''"
      >
        {{ t('history.clearFilters') }}
      </button>
    </div>

    <!-- Loading skeleton -->
    <div v-if="loading && logs.length === 0" class="space-y-2">
      <div
        v-for="i in 8"
        :key="i"
        class="h-14 animate-pulse rounded-lg bg-muted"
      />
    </div>

    <!-- Empty state -->
    <div
      v-else-if="!loading && logs.length === 0"
      class="flex flex-col items-center justify-center gap-2 py-24 text-center text-muted-foreground"
    >
      <span class="text-4xl">📋</span>
      <p class="font-medium">{{ t('history.noActivity') }}</p>
      <p class="text-sm">{{ t('history.eventsWillAppear') }}</p>
    </div>

    <!-- ── Unified activity list (grouped by date) ── -->
    <template v-else>
      <div class="flex flex-col gap-5">
        <div v-for="group in groupedLogs" :key="group.date">
          <h3 class="sticky top-0 z-10 mb-2 bg-background py-1 text-xs font-semibold uppercase tracking-wider text-muted-foreground">
            {{ group.label }}
          </h3>
          <div class="divide-y overflow-hidden rounded-xl border bg-card">
            <div
              v-for="entry in group.entries"
              :key="entry.id"
              class="flex gap-3 p-3 transition-colors hover:bg-muted/30 sm:px-4"
            >
              <!-- Leading action icon -->
              <div
                class="flex h-9 w-9 shrink-0 items-center justify-center rounded-full"
                :class="TINT_CLASSES[actionIcon(entry.action).tint]"
              >
                <component :is="iconComp(actionIcon(entry.action).icon)" class="h-[18px] w-[18px]" />
              </div>

              <!-- Body: title + meta line -->
              <div class="min-w-0 flex-1">
                <div class="flex items-center gap-1.5">
                  <span class="text-sm font-medium">{{ actionLabel(entry.action) }}</span>
                  <button
                    v-if="hasExpandableContent(entry)"
                    type="button"
                    class="inline-flex h-5 w-5 shrink-0 items-center justify-center rounded text-muted-foreground hover:bg-muted"
                    :aria-label="isExpanded(entry.id) ? t('activity.showLess') : t('activity.showMore')"
                    @click="toggleExpanded(entry.id)"
                  >
                    <ChevronDown class="h-3.5 w-3.5 transition-transform" :class="{ 'rotate-180': isExpanded(entry.id) }" />
                  </button>
                </div>
                <div class="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-[13px] text-muted-foreground">
                  <!-- Product thumbnail + name (single-product entries) -->
                  <span
                    v-if="productRef(entry)"
                    class="inline-flex items-center gap-1.5 rounded-md bg-muted/60 py-0.5 pl-0.5 pr-2"
                  >
                    <img
                      v-if="resolveProductImage(productRef(entry))"
                      :src="resolveProductImage(productRef(entry))!"
                      class="h-5 w-5 rounded object-cover"
                      alt=""
                    />
                    <span v-else class="flex h-5 w-5 items-center justify-center rounded bg-muted">
                      <Package class="h-3 w-3" />
                    </span>
                    <span class="text-foreground">{{ productRef(entry)?.productName || '—' }}</span>
                  </span>

                  <!-- Meta chips (icon + value) -->
                  <span
                    v-for="chip in metadataChips(entry)"
                    :key="chip.label + chip.value"
                    class="inline-flex items-center gap-1.5"
                    :class="{
                      'text-emerald-600 dark:text-emerald-400': chip.variant === 'increase',
                      'text-red-600 dark:text-red-400': chip.variant === 'decrease',
                    }"
                  >
                    <component :is="iconComp(chip.icon)" v-if="chip.icon" class="h-[15px] w-[15px] opacity-70" />
                    <span>{{ chip.value }}</span>
                  </span>
                </div>

                <!-- Multi-item refill breakdown (stock_refill_all / stock_refill_tour) -->
                <div v-if="productRefs(entry).length" class="mt-2 flex flex-wrap items-center gap-1.5">
                  <span
                    v-for="(p, i) in visibleProductRefs(entry)"
                    :key="(p.productId || p.productName || i) + ''"
                    class="inline-flex items-center gap-1.5 rounded-md bg-muted/60 py-0.5 pl-0.5 pr-2 text-[13px]"
                  >
                    <img
                      v-if="resolveProductImage(p)"
                      :src="resolveProductImage(p)!"
                      class="h-5 w-5 rounded object-cover"
                      alt=""
                    />
                    <span v-else class="flex h-5 w-5 items-center justify-center rounded bg-muted">
                      <Package class="h-3 w-3" />
                    </span>
                    <span class="text-foreground">{{ p.productName || '—' }}</span>
                    <span
                      v-if="p.oldStock != null && p.newStock != null"
                      class="tabular-nums"
                      :class="p.newStock > p.oldStock ? 'text-emerald-600 dark:text-emerald-400' : 'text-muted-foreground'"
                    >
                      {{ p.oldStock }} → {{ p.newStock }}
                    </span>
                    <span v-else-if="p.quantity != null" class="tabular-nums text-muted-foreground">×{{ p.quantity }}</span>
                  </span>
                  <button
                    v-if="!isExpanded(entry.id) && productRefs(entry).length > 3"
                    type="button"
                    class="text-[13px] text-muted-foreground underline-offset-2 hover:underline"
                    @click="toggleExpanded(entry.id)"
                  >
                    {{ t('activity.moreItems', { count: productRefs(entry).length - 3 }) }}
                  </button>
                </div>

                <!-- Technical details (expand panel) -->
                <div
                  v-if="isExpanded(entry.id) && activityDetailsFor(entry).length"
                  class="mt-2 rounded-md border border-dashed p-2 text-[13px]"
                >
                  <div class="mb-1 font-medium text-muted-foreground">{{ t('activity.technicalDetails') }}</div>
                  <div
                    v-for="d in activityDetailsFor(entry)"
                    :key="d.label"
                    class="flex items-center gap-2"
                    :class="{ 'text-amber-600 dark:text-amber-400': d.variant === 'warning' }"
                  >
                    <span class="text-muted-foreground">{{ d.label }}:</span>
                    <span>{{ d.value }}</span>
                  </div>
                </div>
              </div>

              <!-- Right: time + user -->
              <div class="shrink-0 text-right">
                <div
                  class="text-xs tabular-nums text-muted-foreground"
                  :title="formatDateTime(entry.created_at, locale)"
                >
                  {{ formatTime(entry.created_at, locale) }}
                </div>
                <div
                  v-if="entry.user_display"
                  class="mt-0.5 max-w-[7rem] truncate text-xs text-muted-foreground"
                  :class="{ italic: !entry.user_id }"
                >
                  {{ entry.user_display }}
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </template>

    <!-- Load more -->
    <div v-if="hasMore && logs.length > 0" class="flex justify-center">
      <button
        :disabled="loading"
        class="rounded-md border border-input px-4 py-2 text-sm hover:bg-muted disabled:opacity-50"
        @click="fetchMore"
      >
        {{ loading ? t('common.loading') : t('history.loadMore') }}
      </button>
    </div>
  </div>
</template>
