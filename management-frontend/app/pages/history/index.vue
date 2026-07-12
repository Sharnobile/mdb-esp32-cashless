<script setup lang="ts">
definePageMeta({ middleware: 'auth' })

import { formatDate, formatTime, formatDateTime } from '@/lib/utils'
import { useActivityLog } from '@/composables/useActivityLog'
import { useActivityDescriptor } from '@/composables/useActivityDescriptor'
import { Badge } from '@/components/ui/badge'

const { t, locale } = useI18n()

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
  entityTypeVariant,
} = useActivityLog()

// Human labels + detail chips are centralised in the descriptor so /history and
// the dashboard feed render every action type identically.
const { actionLabel, metadataChips } = useActivityDescriptor()

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
  await fetchLogs()
  unsubscribe = subscribe()
})

onUnmounted(() => {
  unsubscribe?.()
})

function entityTypeLabel(type: string) {
  const found = ENTITY_TYPES.value.find(e => e.value === type)
  return found?.label ?? type
}

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

    <!-- Log list (mobile: cards, desktop: table) -->
    <template v-else>
      <!-- ── Mobile card list (grouped by date) ── -->
      <div class="flex flex-col gap-4 sm:hidden">
        <div v-for="group in groupedLogs" :key="group.date">
          <h3 class="sticky top-0 z-10 mb-2 text-xs font-semibold uppercase tracking-wider text-muted-foreground bg-background py-1">
            {{ group.label }}
          </h3>
          <div class="flex flex-col gap-2">
            <div
              v-for="entry in group.entries"
              :key="entry.id"
              class="rounded-lg border bg-card p-3 space-y-2"
            >
              <!-- Row 1: badge + action + time -->
              <div class="flex items-center gap-2">
                <Badge :variant="entityTypeVariant(entry.entity_type)" class="capitalize shrink-0">
                  {{ entry.entity_type }}
                </Badge>
                <span class="font-medium text-sm truncate">{{ actionLabel(entry.action) }}</span>
                <span class="ml-auto shrink-0 text-xs tabular-nums text-muted-foreground" :title="formatDateTime(entry.created_at, locale)">
                  {{ formatTime(entry.created_at, locale) }}
                </span>
              </div>
              <!-- Row 2: chips -->
              <div v-if="metadataChips(entry).length > 0" class="flex flex-wrap gap-1.5">
                <span
                  v-for="chip in metadataChips(entry)"
                  :key="chip.label"
                  class="inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-xs"
                  :class="{
                    'border-emerald-200 bg-emerald-50 dark:border-emerald-800 dark:bg-emerald-950': chip.variant === 'increase',
                    'border-red-200 bg-red-50 dark:border-red-800 dark:bg-red-950': chip.variant === 'decrease',
                  }"
                >
                  <span class="text-muted-foreground">{{ chip.label }}</span>
                  <span
                    class="font-medium"
                    :class="{
                      'text-emerald-700 dark:text-emerald-400': chip.variant === 'increase',
                      'text-red-700 dark:text-red-400': chip.variant === 'decrease',
                    }"
                  >{{ chip.value }}</span>
                </span>
              </div>
              <!-- Row 3: user -->
              <div v-if="entry.user_display" class="text-xs text-muted-foreground">
                {{ entry.user_display }}
              </div>
            </div>
          </div>
        </div>
      </div>

      <!-- ── Desktop table (grouped by date) ── -->
      <div class="hidden sm:block overflow-x-auto rounded-lg border">
        <table class="w-full text-sm">
          <thead>
            <tr class="border-b bg-muted/50">
              <th class="px-4 py-3 text-left font-medium text-muted-foreground">{{ t('history.timeCol') }}</th>
              <th class="px-4 py-3 text-left font-medium text-muted-foreground">{{ t('history.typeCol') }}</th>
              <th class="px-4 py-3 text-left font-medium text-muted-foreground">{{ t('history.actionCol') }}</th>
              <th class="px-4 py-3 text-left font-medium text-muted-foreground">{{ t('history.detailsCol') }}</th>
              <th class="px-4 py-3 text-left font-medium text-muted-foreground">{{ t('history.userCol') }}</th>
            </tr>
          </thead>
          <tbody>
            <template v-for="group in groupedLogs" :key="group.date">
              <!-- Date group header -->
              <tr class="bg-muted/30">
                <td colspan="5" class="px-4 py-2 text-xs font-semibold uppercase tracking-wider text-muted-foreground">
                  {{ group.label }}
                </td>
              </tr>
              <tr
                v-for="entry in group.entries"
                :key="entry.id"
                class="border-b transition-colors last:border-0 hover:bg-muted/30"
              >
                <td class="whitespace-nowrap px-4 py-3 tabular-nums text-muted-foreground">
                  {{ formatTime(entry.created_at, locale) }}
                </td>
                <td class="px-4 py-3">
                  <Badge :variant="entityTypeVariant(entry.entity_type)" class="capitalize">
                    {{ entry.entity_type }}
                  </Badge>
                </td>
                <td class="px-4 py-3 font-medium">
                  {{ actionLabel(entry.action) }}
                </td>
                <td class="px-4 py-3">
                  <div class="flex flex-wrap gap-1.5">
                    <span
                      v-for="chip in metadataChips(entry)"
                      :key="chip.label"
                      class="inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-xs"
                      :class="{
                        'border-emerald-200 bg-emerald-50 dark:border-emerald-800 dark:bg-emerald-950': chip.variant === 'increase',
                        'border-red-200 bg-red-50 dark:border-red-800 dark:bg-red-950': chip.variant === 'decrease',
                      }"
                    >
                      <span class="text-muted-foreground">{{ chip.label }}</span>
                      <span
                        class="font-medium"
                        :class="{
                          'text-emerald-700 dark:text-emerald-400': chip.variant === 'increase',
                          'text-red-700 dark:text-red-400': chip.variant === 'decrease',
                        }"
                      >{{ chip.value }}</span>
                    </span>
                    <span v-if="metadataChips(entry).length === 0" class="text-muted-foreground">—</span>
                  </div>
                </td>
                <td class="px-4 py-3">
                  <span
                    :class="entry.user_id ? 'text-foreground' : 'italic text-muted-foreground'"
                    class="text-sm"
                  >
                    {{ entry.user_display }}
                  </span>
                </td>
              </tr>
            </template>
          </tbody>
        </table>
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
