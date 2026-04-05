<script setup lang="ts">
definePageMeta({ middleware: 'auth' })

import { IconDownload, IconTable } from '@tabler/icons-vue'
import { formatCurrency } from '@/lib/utils'

const { t } = useI18n()
const { organization, role } = useOrganization()
const { taxReadiness, fetchAll: fetchTaxAll, loading: taxLoading } = useTaxSettings()
const { fetchProducts } = useProducts()
const {
  sales,
  filteredSales,
  loading,
  dateFrom,
  dateTo,
  summary,
  vatBreakdown,
  channelFilters,
  availableChannels,
  toggleChannel,
  fetchReportData,
  exportSimpleCsv,
  exportDatev,
} = useReports()

// Ensure tax + products data is loaded for readiness check
const taxDataLoaded = ref(false)
onMounted(async () => {
  if (organization.value?.id) {
    await Promise.all([fetchTaxAll(organization.value.id), fetchProducts()])
  }
  taxDataLoaded.value = true
})

const isAdmin = computed(() => role.value === 'admin')
const canExport = computed(() => (taxReadiness.value.isReady || !taxDataLoaded.value) && filteredSales.value.length > 0)
const hasData = computed(() => sales.value.length > 0)

// Date presets
function setThisMonth() {
  const now = new Date()
  dateFrom.value = new Date(now.getFullYear(), now.getMonth(), 1).toISOString().split('T')[0]
  dateTo.value = now.toISOString().split('T')[0]
}

function setLastMonth() {
  const now = new Date()
  dateFrom.value = new Date(now.getFullYear(), now.getMonth() - 1, 1).toISOString().split('T')[0]
  dateTo.value = new Date(now.getFullYear(), now.getMonth(), 0).toISOString().split('T')[0]
}

function setThisQuarter() {
  const now = new Date()
  const qStart = Math.floor(now.getMonth() / 3) * 3
  dateFrom.value = new Date(now.getFullYear(), qStart, 1).toISOString().split('T')[0]
  dateTo.value = now.toISOString().split('T')[0]
}

function setThisYear() {
  const now = new Date()
  dateFrom.value = new Date(now.getFullYear(), 0, 1).toISOString().split('T')[0]
  dateTo.value = now.toISOString().split('T')[0]
}

function formatChannel(channel: string | null): string {
  if (!channel) return '—'
  if (channel === 'cashless' || channel === 'mqtt') return t('reports.cashless')
  if (channel === 'cash') return t('reports.cash')
  if (channel === 'card') return t('reports.card')
  return channel
}

function formatDate(iso: string): string {
  const d = new Date(iso)
  return `${String(d.getDate()).padStart(2, '0')}.${String(d.getMonth() + 1).padStart(2, '0')}.${d.getFullYear()}`
}

function formatTime(iso: string): string {
  const d = new Date(iso)
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`
}

function formatPercent(rate: number | null): string {
  if (rate == null) return '—'
  const pct = rate * 100
  return `${pct % 1 === 0 ? pct.toFixed(0) : pct.toFixed(1)}%`
}
</script>

<template>
  <div class="flex flex-1 flex-col gap-6 p-4 md:p-6">
    <h1 class="text-2xl font-semibold">{{ t('reports.title') }}</h1>

    <!-- Tax readiness blocker (only after data loaded) -->
    <div
      v-if="taxDataLoaded && !taxReadiness.isReady"
      class="rounded-lg border border-amber-200 bg-amber-50 p-4 text-sm text-amber-800 dark:border-amber-900 dark:bg-amber-950 dark:text-amber-200"
    >
      <p class="font-medium mb-1">{{ t('reports.taxNotReady') }}</p>
      <p>
        {{ t('reports.taxNotReadyDescription', { count: taxReadiness.categoriesWithoutTax }) }}
        <NuxtLink to="/products" class="underline font-medium hover:text-amber-900 dark:hover:text-amber-100">
          {{ t('reports.taxNotReadyLink') }}
        </NuxtLink>
      </p>
    </div>

    <!-- Date range controls -->
    <div class="rounded-xl border bg-card p-4 shadow-sm">
      <div class="flex flex-col gap-4 sm:flex-row sm:items-end">
        <div class="space-y-1">
          <label class="text-sm font-medium">{{ t('reports.dateFrom') }}</label>
          <input
            v-model="dateFrom"
            type="date"
            class="flex h-9 rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          />
        </div>
        <div class="space-y-1">
          <label class="text-sm font-medium">{{ t('reports.dateTo') }}</label>
          <input
            v-model="dateTo"
            type="date"
            class="flex h-9 rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          />
        </div>
        <button
          :disabled="loading"
          class="inline-flex h-9 items-center justify-center gap-2 rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90 disabled:opacity-50"
          @click="fetchReportData"
        >
          <IconTable class="size-4" />
          <span v-if="loading">{{ t('common.loading') }}</span>
          <span v-else>{{ t('reports.loadData') }}</span>
        </button>
      </div>

      <!-- Presets -->
      <div class="mt-3 flex flex-wrap gap-2">
        <button class="rounded-md border px-3 py-1 text-xs font-medium transition-colors hover:bg-muted" @click="setThisMonth">{{ t('reports.thisMonth') }}</button>
        <button class="rounded-md border px-3 py-1 text-xs font-medium transition-colors hover:bg-muted" @click="setLastMonth">{{ t('reports.lastMonth') }}</button>
        <button class="rounded-md border px-3 py-1 text-xs font-medium transition-colors hover:bg-muted" @click="setThisQuarter">{{ t('reports.thisQuarter') }}</button>
        <button class="rounded-md border px-3 py-1 text-xs font-medium transition-colors hover:bg-muted" @click="setThisYear">{{ t('reports.thisYear') }}</button>
      </div>
    </div>

    <!-- Payment method filters -->
    <div v-if="hasData" class="flex flex-wrap items-center gap-3">
      <span class="text-sm font-medium text-muted-foreground">{{ t('reports.payment') }}:</span>
      <button
        v-for="ch in availableChannels"
        :key="ch"
        class="inline-flex h-8 items-center gap-1.5 rounded-full border px-3 text-xs font-medium transition-colors"
        :class="channelFilters[ch] !== false
          ? 'bg-primary text-primary-foreground border-primary'
          : 'bg-background text-muted-foreground border-input hover:bg-muted'"
        @click="toggleChannel(ch)"
      >
        {{ formatChannel(ch) }}
      </button>
    </div>

    <!-- Export buttons -->
    <div v-if="hasData" class="flex flex-wrap gap-3">
      <button
        :disabled="!canExport"
        class="inline-flex h-9 items-center gap-2 rounded-md border px-4 text-sm font-medium shadow-sm transition-colors hover:bg-muted disabled:opacity-50"
        :title="!taxReadiness.isReady ? t('reports.taxNotReady') : ''"
        @click="exportSimpleCsv"
      >
        <IconDownload class="size-4" />
        {{ t('reports.exportCsv') }}
      </button>
      <button
        :disabled="!canExport"
        class="inline-flex h-9 items-center gap-2 rounded-md border px-4 text-sm font-medium shadow-sm transition-colors hover:bg-muted disabled:opacity-50"
        :title="!taxReadiness.isReady ? t('reports.taxNotReady') : ''"
        @click="exportDatev"
      >
        <IconDownload class="size-4" />
        {{ t('reports.exportDatev') }}
      </button>
    </div>

    <!-- Summary KPIs -->
    <div v-if="hasData" class="grid grid-cols-2 gap-3 sm:grid-cols-5">
      <div class="rounded-lg border bg-card p-3 shadow-sm">
        <p class="text-xs text-muted-foreground">{{ t('reports.totalGross') }}</p>
        <p class="text-lg font-semibold">{{ formatCurrency(summary.totalGross) }}</p>
      </div>
      <div class="rounded-lg border bg-card p-3 shadow-sm">
        <p class="text-xs text-muted-foreground">{{ t('reports.salesCount') }}</p>
        <p class="text-lg font-semibold">{{ summary.count }}</p>
      </div>
      <div class="rounded-lg border bg-card p-3 shadow-sm">
        <p class="text-xs text-muted-foreground">{{ t('reports.avgPerSale') }}</p>
        <p class="text-lg font-semibold">{{ formatCurrency(summary.avgPerSale) }}</p>
      </div>
      <div class="rounded-lg border bg-card p-3 shadow-sm">
        <p class="text-xs text-muted-foreground">{{ t('reports.totalTax') }}</p>
        <p class="text-lg font-semibold">{{ formatCurrency(summary.totalTax) }}</p>
      </div>
      <div class="rounded-lg border bg-card p-3 shadow-sm">
        <p class="text-xs text-muted-foreground">{{ t('reports.totalNet') }}</p>
        <p class="text-lg font-semibold">{{ formatCurrency(summary.totalNet) }}</p>
      </div>
    </div>

    <!-- VAT Breakdown -->
    <div v-if="hasData && vatBreakdown.length > 0" class="rounded-xl border bg-card p-4 shadow-sm">
      <h2 class="text-base font-semibold mb-1">{{ t('reports.vatBreakdown') }}</h2>
      <p class="text-sm text-muted-foreground mb-4">{{ t('reports.vatBreakdownDescription') }}</p>

      <div class="overflow-x-auto rounded-md border">
        <table class="w-full text-sm">
          <thead>
            <tr class="border-b bg-muted/50 text-left">
              <th class="px-4 py-2.5 font-medium">{{ t('reports.taxRate') }}</th>
              <th class="px-4 py-2.5 font-medium text-right">{{ t('reports.gross') }}</th>
              <th class="px-4 py-2.5 font-medium text-right">{{ t('reports.net') }}</th>
              <th class="px-4 py-2.5 font-medium text-right">{{ t('reports.taxAmount') }}</th>
              <th class="px-4 py-2.5 font-medium text-right">{{ t('reports.salesCount') }}</th>
            </tr>
          </thead>
          <tbody>
            <tr
              v-for="(row, i) in vatBreakdown"
              :key="i"
              class="border-b last:border-0"
            >
              <td class="px-4 py-2.5 font-medium">{{ formatPercent(row.rate) }}</td>
              <td class="px-4 py-2.5 text-right font-medium">{{ formatCurrency(row.gross) }}</td>
              <td class="px-4 py-2.5 text-right">{{ formatCurrency(row.net) }}</td>
              <td class="px-4 py-2.5 text-right">{{ formatCurrency(row.tax) }}</td>
              <td class="px-4 py-2.5 text-right">{{ row.count }}</td>
            </tr>
          </tbody>
          <tfoot>
            <tr class="border-t bg-muted/30 font-medium">
              <td class="px-4 py-2.5">{{ t('reports.total') }}</td>
              <td class="px-4 py-2.5 text-right">{{ formatCurrency(summary.totalGross) }}</td>
              <td class="px-4 py-2.5 text-right">{{ formatCurrency(summary.totalNet) }}</td>
              <td class="px-4 py-2.5 text-right">{{ formatCurrency(summary.totalTax) }}</td>
              <td class="px-4 py-2.5 text-right">{{ summary.count }}</td>
            </tr>
          </tfoot>
        </table>
      </div>
    </div>

    <!-- Data table -->
    <div v-if="loading" class="text-muted-foreground">{{ t('common.loading') }}</div>
    <div v-else-if="hasData" class="overflow-x-auto rounded-md border">
      <table class="w-full text-sm">
        <thead>
          <tr class="border-b bg-muted/50 text-left">
            <th class="whitespace-nowrap px-3 py-2.5 font-medium">{{ t('reports.date') }}</th>
            <th class="whitespace-nowrap px-3 py-2.5 font-medium">{{ t('reports.time') }}</th>
            <th class="whitespace-nowrap px-3 py-2.5 font-medium">{{ t('reports.machine') }}</th>
            <th class="whitespace-nowrap px-3 py-2.5 font-medium">{{ t('reports.tray') }}</th>
            <th class="whitespace-nowrap px-3 py-2.5 font-medium">{{ t('reports.product') }}</th>
            <th class="whitespace-nowrap px-3 py-2.5 font-medium">{{ t('reports.category') }}</th>
            <th class="whitespace-nowrap px-3 py-2.5 font-medium text-right">{{ t('reports.gross') }}</th>
            <th class="whitespace-nowrap px-3 py-2.5 font-medium text-right">{{ t('reports.taxRate') }}</th>
            <th class="whitespace-nowrap px-3 py-2.5 font-medium text-right">{{ t('reports.taxAmount') }}</th>
            <th class="whitespace-nowrap px-3 py-2.5 font-medium text-right">{{ t('reports.net') }}</th>
            <th class="whitespace-nowrap px-3 py-2.5 font-medium">{{ t('reports.payment') }}</th>
          </tr>
        </thead>
        <tbody>
          <tr
            v-for="sale in filteredSales"
            :key="sale.id"
            class="border-b last:border-0 hover:bg-muted/30 transition-colors"
          >
            <td class="whitespace-nowrap px-3 py-2">{{ formatDate(sale.created_at) }}</td>
            <td class="whitespace-nowrap px-3 py-2">{{ formatTime(sale.created_at) }}</td>
            <td class="px-3 py-2 max-w-[150px] truncate">{{ sale.machine_name }}</td>
            <td class="px-3 py-2 text-center">{{ sale.item_number }}</td>
            <td class="px-3 py-2 max-w-[150px] truncate">{{ sale.product_name ?? '—' }}</td>
            <td class="px-3 py-2 max-w-[120px] truncate">{{ sale.category_name ?? '—' }}</td>
            <td class="whitespace-nowrap px-3 py-2 text-right font-medium">{{ formatCurrency(sale.item_price) }}</td>
            <td class="whitespace-nowrap px-3 py-2 text-right">{{ formatPercent(sale.tax_rate_snapshot) }}</td>
            <td class="whitespace-nowrap px-3 py-2 text-right">{{ sale.tax_amount != null ? formatCurrency(sale.tax_amount) : '—' }}</td>
            <td class="whitespace-nowrap px-3 py-2 text-right">{{ sale.price_net != null ? formatCurrency(sale.price_net) : '—' }}</td>
            <td class="whitespace-nowrap px-3 py-2">{{ formatChannel(sale.channel) }}</td>
          </tr>
        </tbody>
      </table>
    </div>

    <!-- Empty state -->
    <div v-else-if="!loading" class="text-center text-sm text-muted-foreground py-8">
      {{ t('reports.noData') }}
    </div>
  </div>
</template>
