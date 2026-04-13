<script setup lang="ts">
import { IconRefresh, IconTag, IconBuildingStore, IconAlertCircle, IconSettings, IconExternalLink, IconCheck, IconX, IconDeviceMobile } from '@tabler/icons-vue'
import Badge from '@/components/ui/badge/Badge.vue'
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
} from '@/components/ui/sheet'
import type { Deal } from '@/composables/useDeals'
import { timeAgo } from '@/lib/utils'

definePageMeta({ middleware: 'auth' })

const { t } = useI18n()
const { role } = useOrganization()
const {
  deals,
  loading,
  error,
  fromCache,
  dealsEnabled,
  lastFetchedAt,
  loadSettings,
  fetchDeals,
  totalDeals,
  uniqueRetailers,
  avgDiscount,
} = useDeals()

const lastFetchLabel = computed(() => {
  if (!lastFetchedAt.value) return null
  return timeAgo(new Date(lastFetchedAt.value), t)
})

const searchQuery = ref('')
const groupBy = ref<'retailer' | 'product'>('retailer')

// Detail sheet state
const selectedDeal = ref<Deal | null>(null)
const sheetOpen = ref(false)

function openDetail(deal: Deal) {
  selectedDeal.value = deal
  sheetOpen.value = true
}

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

interface DealValidity {
  status: 'upcoming' | 'active' | 'expiring' | 'expired'
  label: string
  cls: string
  badgeCls: string
}

function dealValidity(validFrom: string | null, validUntil: string | null): DealValidity {
  const now = new Date()
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate())

  if (validFrom) {
    const from = new Date(validFrom)
    if (from > today) {
      const days = Math.ceil((from.getTime() - today.getTime()) / (24 * 60 * 60 * 1000))
      return {
        status: 'upcoming',
        label: days === 1
          ? t('deals.startsIn', { days: 1 })
          : t('deals.startsIn', { days }),
        cls: 'text-blue-600 dark:text-blue-400',
        badgeCls: 'bg-blue-100 text-blue-800 dark:bg-blue-900 dark:text-blue-200',
      }
    }
  }

  if (validUntil) {
    const until = new Date(validUntil)
    if (until < today) {
      return {
        status: 'expired',
        label: t('deals.expired'),
        cls: 'text-muted-foreground line-through',
        badgeCls: 'bg-muted text-muted-foreground',
      }
    }
    const daysLeft = Math.ceil((until.getTime() - today.getTime()) / (24 * 60 * 60 * 1000))
    if (daysLeft <= 2) {
      return {
        status: 'expiring',
        label: daysLeft === 0
          ? t('deals.lastDay')
          : t('deals.daysLeft', { days: daysLeft }),
        cls: 'text-orange-600 dark:text-orange-400 font-medium',
        badgeCls: 'bg-orange-100 text-orange-800 dark:bg-orange-900 dark:text-orange-200',
      }
    }
    return {
      status: 'active',
      label: t('deals.daysLeft', { days: daysLeft }),
      cls: 'text-green-600 dark:text-green-400',
      badgeCls: 'bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200',
    }
  }

  return {
    status: 'active',
    label: t('deals.activeNow'),
    cls: 'text-green-600 dark:text-green-400',
    badgeCls: 'bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200',
  }
}

/** Confidence label + color */
function confidenceLevel(c: number): { label: string; cls: string } {
  if (c >= 0.85) return { label: t('deals.matchHigh'), cls: 'text-green-600 dark:text-green-400' }
  if (c >= 0.65) return { label: t('deals.matchMedium'), cls: 'text-yellow-600 dark:text-yellow-400' }
  return { label: t('deals.matchLow'), cls: 'text-orange-600 dark:text-orange-400' }
}

/**
 * Highlight matched tokens in a text string.
 * Returns an array of { text, matched } segments for the template to render.
 */
function highlightTokens(text: string, tokens: string[] | null): { text: string; matched: boolean }[] {
  if (!tokens || tokens.length === 0) return [{ text, matched: false }]

  const lower = text.toLowerCase()
  const segments: { start: number; end: number }[] = []

  for (const token of tokens) {
    let pos = 0
    while (pos < lower.length) {
      const idx = lower.indexOf(token.toLowerCase(), pos)
      if (idx === -1) break
      segments.push({ start: idx, end: idx + token.length })
      pos = idx + token.length
    }
  }

  if (segments.length === 0) return [{ text, matched: false }]

  // Sort and merge overlapping segments
  segments.sort((a, b) => a.start - b.start)
  const merged: typeof segments = [segments[0]]
  for (let i = 1; i < segments.length; i++) {
    const last = merged[merged.length - 1]
    if (segments[i].start <= last.end) {
      last.end = Math.max(last.end, segments[i].end)
    } else {
      merged.push(segments[i])
    }
  }

  const result: { text: string; matched: boolean }[] = []
  let cursor = 0
  for (const seg of merged) {
    if (cursor < seg.start) {
      result.push({ text: text.slice(cursor, seg.start), matched: false })
    }
    result.push({ text: text.slice(seg.start, seg.end), matched: true })
    cursor = seg.end
  }
  if (cursor < text.length) {
    result.push({ text: text.slice(cursor), matched: false })
  }
  return result
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
          <p class="text-sm text-muted-foreground">{{ t('deals.lastFetched') }}</p>
          <p class="mt-1 text-sm font-medium">
            {{ lastFetchLabel ?? '—' }}
          </p>
          <p v-if="fromCache" class="mt-0.5 text-xs text-muted-foreground">{{ t('deals.cached') }}</p>
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
            <button
              v-for="deal in groupDeals"
              :key="deal.id"
              class="flex gap-3 rounded-xl border bg-card p-4 shadow-sm transition-colors hover:bg-muted/50 text-left cursor-pointer"
              @click="openDetail(deal)"
            >
              <!-- Deal image (medium thumbnail, fallback to large prospekt excerpt) -->
              <div class="shrink-0">
                <img
                  v-if="deal.image_url || deal.image_url_large"
                  :src="deal.image_url ?? deal.image_url_large!"
                  :alt="deal.deal_title"
                  class="size-16 rounded-lg object-cover bg-muted"
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
                  <span v-if="deal.requires_app" class="inline-flex items-center gap-0.5 rounded-full bg-purple-100 px-1.5 py-0.5 text-[10px] font-medium text-purple-800 dark:bg-purple-900 dark:text-purple-200">
                    <IconDeviceMobile class="size-2.5" />
                    App
                  </span>
                </div>

                <!-- Validity & confidence -->
                <div class="mt-1 flex items-center gap-2 text-[11px]">
                  <span
                    class="inline-flex rounded-full px-1.5 py-0.5 text-[10px] font-medium"
                    :class="dealValidity(deal.valid_from, deal.valid_until).badgeCls"
                  >
                    {{ dealValidity(deal.valid_from, deal.valid_until).label }}
                  </span>
                  <span :class="confidenceLevel(deal.confidence).cls">
                    {{ Math.round(deal.confidence * 100) }}% {{ t('deals.match') }}
                  </span>
                </div>
              </div>
            </button>
          </div>
        </div>
      </div>
    </template>

    <!-- ─── Detail Sheet ────────────────────────────────────────────── -->
    <Sheet v-model:open="sheetOpen">
      <SheetContent class="w-full sm:max-w-md overflow-y-auto px-5 sm:px-6">
        <SheetHeader>
          <SheetTitle>{{ t('deals.detailTitle') }}</SheetTitle>
          <SheetDescription>{{ selectedDeal?.retailer }}</SheetDescription>
        </SheetHeader>

        <div v-if="selectedDeal" class="mt-5 space-y-5">
          <!-- Hero: image + price overlay -->
          <div class="relative overflow-hidden rounded-xl border h-36 sm:h-44">
            <!-- Blurred background fill (same image, scaled up) -->
            <div
              v-if="selectedDeal.image_url_large"
              class="absolute inset-0 bg-cover bg-center blur-xl scale-125 opacity-40"
              :style="{ backgroundImage: `url(${selectedDeal.image_url_large})` }"
            />
            <div v-else class="absolute inset-0 bg-muted" />
            <!-- Actual image (fully visible, centered) -->
            <img
              v-if="selectedDeal.image_url_large"
              :src="selectedDeal.image_url_large"
              :alt="selectedDeal.deal_title"
              class="relative size-full object-contain"
              loading="lazy"
            />
            <div v-else class="flex h-32 items-center justify-center">
              <IconTag class="size-10 text-muted-foreground" />
            </div>
            <!-- Price overlay bottom-right -->
            <div v-if="selectedDeal.deal_price != null" class="absolute bottom-2 right-2 flex items-center gap-1.5 rounded-lg bg-black/70 px-2.5 py-1 backdrop-blur-sm">
              <span class="text-base font-bold text-green-400">
                {{ selectedDeal.deal_price.toFixed(2) }}&euro;
              </span>
              <span v-if="selectedDeal.regular_price != null" class="text-xs text-white/60 line-through">
                {{ selectedDeal.regular_price.toFixed(2) }}&euro;
              </span>
              <Badge v-if="selectedDeal.discount_pct" variant="destructive" class="text-[10px] px-1.5 py-0">
                {{ formatDiscount(selectedDeal.discount_pct) }}
              </Badge>
            </div>
          </div>

          <!-- Title + badges row -->
          <div class="space-y-2.5">
            <h3 class="text-sm font-semibold leading-snug sm:text-base">{{ selectedDeal.deal_title }}</h3>

            <div class="flex flex-wrap items-center gap-1.5">
              <!-- Validity badge -->
              <span
                v-if="selectedDeal.valid_from || selectedDeal.valid_until"
                class="inline-flex rounded-full px-2 py-0.5 text-[11px] font-medium"
                :class="dealValidity(selectedDeal.valid_from, selectedDeal.valid_until).badgeCls"
              >
                {{ dealValidity(selectedDeal.valid_from, selectedDeal.valid_until).label }}
              </span>
              <!-- Date range -->
              <span v-if="selectedDeal.valid_from || selectedDeal.valid_until" class="text-xs text-muted-foreground">
                {{ selectedDeal.valid_from }}{{ selectedDeal.valid_from && selectedDeal.valid_until ? ' — ' : '' }}{{ selectedDeal.valid_until }}
              </span>
              <!-- App badge -->
              <span v-if="selectedDeal.requires_app" class="inline-flex items-center gap-0.5 rounded-full bg-purple-100 px-2 py-0.5 text-[11px] font-medium text-purple-800 dark:bg-purple-900 dark:text-purple-200">
                <IconDeviceMobile class="size-3" />
                App
              </span>
            </div>
          </div>

          <!-- App required notice -->
          <div v-if="selectedDeal.requires_app" class="flex items-center gap-2 rounded-lg border border-purple-200 bg-purple-50 px-3 py-2 dark:border-purple-800 dark:bg-purple-950">
            <IconDeviceMobile class="size-4 shrink-0 text-purple-600 dark:text-purple-400" />
            <p class="text-xs text-purple-800 dark:text-purple-200">
              {{ t('deals.requiresApp', { retailer: selectedDeal.retailer }) }}
            </p>
          </div>

          <!-- Action buttons -->
          <div class="flex gap-2">
            <a
              v-if="selectedDeal.source_url"
              :href="selectedDeal.source_url"
              target="_blank"
              rel="noopener"
              class="inline-flex flex-1 items-center justify-center gap-1.5 rounded-lg border px-3 py-2 text-xs font-medium transition-colors hover:bg-muted sm:text-sm"
            >
              <IconExternalLink class="size-3.5" />
              {{ t('deals.viewProspekt') }}
            </a>
            <a
              v-if="selectedDeal.external_url"
              :href="selectedDeal.external_url"
              target="_blank"
              rel="noopener"
              class="inline-flex flex-1 items-center justify-center gap-1.5 rounded-lg border px-3 py-2 text-xs font-medium transition-colors hover:bg-muted sm:text-sm"
            >
              <IconExternalLink class="size-3.5" />
              {{ t('deals.viewAllOffers', { retailer: selectedDeal.retailer }) }}
            </a>
          </div>

          <!-- ─── Match Validation (compact) ────────────────────── -->
          <div class="rounded-xl border bg-card p-4 space-y-3">
            <div class="flex items-center justify-between">
              <h4 class="text-xs font-semibold">{{ t('deals.matchValidation') }}</h4>
              <span :class="confidenceLevel(selectedDeal.confidence).cls" class="text-xs font-medium">
                {{ Math.round(selectedDeal.confidence * 100) }}% {{ confidenceLevel(selectedDeal.confidence).label }}
              </span>
            </div>

            <!-- Confidence bar -->
            <div class="h-1.5 overflow-hidden rounded-full bg-muted">
              <div
                class="h-full rounded-full transition-all"
                :class="{
                  'bg-green-500': selectedDeal.confidence >= 0.85,
                  'bg-yellow-500': selectedDeal.confidence >= 0.65 && selectedDeal.confidence < 0.85,
                  'bg-orange-500': selectedDeal.confidence < 0.65,
                }"
                :style="{ width: `${Math.round(selectedDeal.confidence * 100)}%` }"
              />
            </div>

            <!-- Side by side: Offer vs Product -->
            <div class="grid grid-cols-2 gap-2">
              <div class="space-y-0.5">
                <p class="text-[10px] font-medium uppercase tracking-wide text-muted-foreground">{{ t('deals.offerText') }}</p>
                <p class="text-xs leading-snug">
                  <template v-for="(seg, idx) in highlightTokens(selectedDeal.deal_title, selectedDeal.matched_tokens)" :key="idx">
                    <mark v-if="seg.matched" class="rounded-sm bg-green-200 px-0.5 dark:bg-green-900">{{ seg.text }}</mark>
                    <span v-else>{{ seg.text }}</span>
                  </template>
                </p>
              </div>
              <div class="space-y-0.5">
                <p class="text-[10px] font-medium uppercase tracking-wide text-muted-foreground">{{ t('deals.yourProduct') }}</p>
                <p class="text-xs leading-snug">
                  <template v-for="(seg, idx) in highlightTokens(selectedDeal.products?.name ?? '', selectedDeal.matched_tokens)" :key="idx">
                    <mark v-if="seg.matched" class="rounded-sm bg-green-200 px-0.5 dark:bg-green-900">{{ seg.text }}</mark>
                    <span v-else>{{ seg.text }}</span>
                  </template>
                </p>
                <p v-if="selectedDeal.products?.sellprice != null" class="text-[10px] text-muted-foreground">
                  {{ t('deals.yourPrice') }}: {{ selectedDeal.products.sellprice.toFixed(2) }}&euro;
                </p>
              </div>
            </div>

            <!-- Matched tokens -->
            <div v-if="selectedDeal.matched_tokens?.length" class="flex flex-wrap gap-1">
              <span
                v-for="token in selectedDeal.matched_tokens"
                :key="token"
                class="inline-flex items-center gap-0.5 rounded-full bg-green-100 px-1.5 py-0.5 text-[10px] font-medium text-green-800 dark:bg-green-900 dark:text-green-200"
              >
                <IconCheck class="size-2.5" />
                {{ token }}
              </span>
            </div>
          </div>
        </div>
      </SheetContent>
    </Sheet>
  </div>
</template>
