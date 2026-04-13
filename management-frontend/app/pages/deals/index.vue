<script setup lang="ts">
import { IconRefresh, IconTag, IconBuildingStore, IconPercentage, IconAlertCircle, IconSettings } from '@tabler/icons-vue'
import Badge from '@/components/ui/badge/Badge.vue'

definePageMeta({ middleware: 'auth' })

const { t } = useI18n()
const { role } = useOrganization()
const {
  deals,
  loading,
  error,
  fromCache,
  dealsEnabled,
  dealsZipCode,
  loadSettings,
  fetchDeals,
  dealsByRetailer,
  totalDeals,
  uniqueRetailers,
  avgDiscount,
} = useDeals()

const searchQuery = ref('')
const groupBy = ref<'retailer' | 'product'>('retailer')

const filteredDeals = computed(() => {
  if (!searchQuery.value.trim()) return deals.value
  const q = searchQuery.value.toLowerCase()
  return deals.value.filter(
    (d) =>
      d.deal_title.toLowerCase().includes(q) ||
      d.retailer.toLowerCase().includes(q) ||
      d.products?.name?.toLowerCase().includes(q),
  )
})

const groupedFiltered = computed(() => {
  const grouped = new Map<string, typeof filteredDeals.value>()
  for (const deal of filteredDeals.value) {
    const key = groupBy.value === 'retailer' ? deal.retailer : (deal.products?.name ?? deal.product_id)
    const existing = grouped.get(key) ?? []
    existing.push(deal)
    grouped.set(key, existing)
  }
  return grouped
})

onMounted(async () => {
  await loadSettings()
  if (dealsEnabled.value) {
    await fetchDeals()
  }
})

function formatDiscount(pct: number | null): string {
  if (pct == null) return ''
  return `-${Math.abs(pct)}%`
}

function isExpiringSoon(validUntil: string | null): boolean {
  if (!validUntil) return false
  const diff = new Date(validUntil).getTime() - Date.now()
  return diff > 0 && diff < 2 * 24 * 60 * 60 * 1000 // < 2 days
}
</script>

<template>
  <div class="flex flex-1 flex-col gap-6 p-4 md:p-6">
    <div class="flex items-center justify-between">
      <h1 class="text-2xl font-semibold">{{ t('deals.title') }}</h1>
      <div class="flex items-center gap-2">
        <button
          v-if="dealsEnabled"
          :disabled="loading"
          class="inline-flex h-9 items-center gap-2 rounded-md border px-3 text-sm font-medium shadow-sm transition-colors hover:bg-muted disabled:opacity-50"
          @click="fetchDeals(true)"
        >
          <IconRefresh class="size-4" :class="{ 'animate-spin': loading }" />
          {{ t('deals.refresh') }}
        </button>
      </div>
    </div>

    <!-- Feature not enabled -->
    <div v-if="!dealsEnabled" class="flex flex-col items-center justify-center gap-4 rounded-xl border bg-card p-12 text-center">
      <IconTag class="size-12 text-muted-foreground" />
      <div>
        <h2 class="text-lg font-semibold">{{ t('deals.notEnabled') }}</h2>
        <p class="mt-1 text-sm text-muted-foreground">{{ t('deals.notEnabledDescription') }}</p>
      </div>
      <NuxtLink
        v-if="role === 'admin'"
        to="/settings"
        class="inline-flex h-9 items-center gap-2 rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90"
      >
        <IconSettings class="size-4" />
        {{ t('deals.goToSettings') }}
      </NuxtLink>
    </div>

    <!-- Enabled: show deals -->
    <template v-else>
      <!-- Error -->
      <div v-if="error" class="flex items-center gap-2 rounded-lg border border-destructive/50 bg-destructive/10 px-4 py-3 text-sm text-destructive">
        <IconAlertCircle class="size-4 shrink-0" />
        {{ error }}
      </div>

      <!-- KPI Cards -->
      <div class="grid grid-cols-2 gap-4 md:grid-cols-4">
        <div class="rounded-xl border bg-card p-4 shadow-sm">
          <p class="text-sm text-muted-foreground">{{ t('deals.totalDeals') }}</p>
          <p class="mt-1 text-2xl font-bold">{{ totalDeals }}</p>
        </div>
        <div class="rounded-xl border bg-card p-4 shadow-sm">
          <p class="text-sm text-muted-foreground">{{ t('deals.retailers') }}</p>
          <p class="mt-1 text-2xl font-bold">{{ uniqueRetailers }}</p>
        </div>
        <div class="rounded-xl border bg-card p-4 shadow-sm">
          <p class="text-sm text-muted-foreground">{{ t('deals.avgDiscount') }}</p>
          <p class="mt-1 text-2xl font-bold">{{ avgDiscount ? `-${avgDiscount}%` : '—' }}</p>
        </div>
        <div class="rounded-xl border bg-card p-4 shadow-sm">
          <p class="text-sm text-muted-foreground">{{ t('deals.dataStatus') }}</p>
          <p class="mt-1 text-sm font-medium">
            <Badge v-if="fromCache" variant="secondary">{{ t('deals.cached') }}</Badge>
            <Badge v-else variant="default">{{ t('deals.fresh') }}</Badge>
          </p>
        </div>
      </div>

      <!-- Search & Grouping Controls -->
      <div class="flex flex-col gap-3 sm:flex-row sm:items-center">
        <input
          v-model="searchQuery"
          type="text"
          :placeholder="t('deals.searchPlaceholder')"
          class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring sm:max-w-xs"
        />
        <div class="flex gap-1 rounded-md border p-0.5">
          <button
            class="rounded-sm px-3 py-1 text-sm font-medium transition-colors"
            :class="groupBy === 'retailer' ? 'bg-primary text-primary-foreground shadow-sm' : 'hover:bg-muted'"
            @click="groupBy = 'retailer'"
          >
            {{ t('deals.byRetailer') }}
          </button>
          <button
            class="rounded-sm px-3 py-1 text-sm font-medium transition-colors"
            :class="groupBy === 'product' ? 'bg-primary text-primary-foreground shadow-sm' : 'hover:bg-muted'"
            @click="groupBy = 'product'"
          >
            {{ t('deals.byProduct') }}
          </button>
        </div>
      </div>

      <!-- Loading skeleton -->
      <div v-if="loading && deals.length === 0" class="space-y-4">
        <div v-for="i in 3" :key="i" class="h-24 animate-pulse rounded-xl border bg-muted" />
      </div>

      <!-- Empty state -->
      <div v-else-if="!loading && deals.length === 0" class="flex flex-col items-center justify-center gap-3 rounded-xl border bg-card p-12 text-center">
        <IconTag class="size-10 text-muted-foreground" />
        <p class="text-sm text-muted-foreground">{{ t('deals.noDeals') }}</p>
      </div>

      <!-- Deal groups -->
      <div v-else class="space-y-6">
        <div v-for="[group, groupDeals] in groupedFiltered" :key="group" class="space-y-3">
          <div class="flex items-center gap-2">
            <IconBuildingStore v-if="groupBy === 'retailer'" class="size-5 text-muted-foreground" />
            <h2 class="text-lg font-semibold">{{ group }}</h2>
            <Badge variant="secondary">{{ groupDeals.length }}</Badge>
          </div>

          <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
            <div
              v-for="deal in groupDeals"
              :key="deal.id"
              class="flex gap-3 rounded-xl border bg-card p-4 shadow-sm transition-colors hover:bg-muted/50"
            >
              <!-- Deal image -->
              <div class="shrink-0">
                <img
                  v-if="deal.image_url"
                  :src="deal.image_url"
                  :alt="deal.deal_title"
                  class="size-16 rounded-lg object-cover"
                  loading="lazy"
                />
                <div v-else class="flex size-16 items-center justify-center rounded-lg bg-muted">
                  <IconTag class="size-6 text-muted-foreground" />
                </div>
              </div>

              <!-- Deal info -->
              <div class="min-w-0 flex-1">
                <div class="flex items-start justify-between gap-2">
                  <p class="text-sm font-medium leading-tight line-clamp-2">{{ deal.deal_title }}</p>
                  <Badge v-if="deal.discount_pct" variant="destructive" class="shrink-0">
                    {{ formatDiscount(deal.discount_pct) }}
                  </Badge>
                </div>

                <!-- Matched product -->
                <p class="mt-1 text-xs text-muted-foreground">
                  {{ groupBy === 'retailer' ? deal.products?.name : deal.retailer }}
                </p>

                <!-- Price row -->
                <div class="mt-2 flex items-center gap-2">
                  <span v-if="deal.deal_price != null" class="text-sm font-bold text-green-600 dark:text-green-400">
                    {{ deal.deal_price.toFixed(2) }}&euro;
                  </span>
                  <span v-if="deal.regular_price != null" class="text-xs text-muted-foreground line-through">
                    {{ deal.regular_price.toFixed(2) }}&euro;
                  </span>
                </div>

                <!-- Validity & confidence -->
                <div class="mt-1 flex items-center gap-2 text-[11px] text-muted-foreground">
                  <span v-if="deal.valid_until">
                    <span :class="{ 'text-orange-500 font-medium': isExpiringSoon(deal.valid_until) }">
                      {{ t('deals.validUntil') }} {{ deal.valid_until }}
                    </span>
                  </span>
                  <span class="opacity-50">{{ Math.round(deal.confidence * 100) }}% {{ t('deals.match') }}</span>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </template>
  </div>
</template>
