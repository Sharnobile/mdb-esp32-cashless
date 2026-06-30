<script setup lang="ts">
definePageMeta({ middleware: ['auth', 'platform-admin'] })

import { computed, onMounted } from 'vue'
import { useI18n } from 'vue-i18n'
import { usePlatformAdmin, companyActivityLevel } from '~/composables/usePlatformAdmin'
import { useTableSort } from '~/composables/useTableSort'
import { formatCurrency, timeAgo } from '~/lib/utils'

const { t } = useI18n()
const { overview, loading, error, fetchOverview } = usePlatformAdmin()

// useTableSort only tracks sort STATE ({ sortKey, sortDir, toggleSort, sortIcon });
// it does NOT sort data. The generic is the union of sortable column keys.
// Sorting is done in a local computed (same pattern as pages/devices/index.vue).
type SortKey = 'name' | 'user_count' | 'machine_count' | 'sales_window_count' | 'sales_window_revenue' | 'last_sale_at'
const { sortKey, sortDir, toggleSort } = useTableSort<SortKey>('sales_window_revenue', 'desc')

const sortedCompanies = computed(() => {
  const rows = overview.value?.companies ?? []
  const dir = sortDir.value === 'asc' ? 1 : -1
  return [...rows].sort((a, b) => {
    const k = sortKey.value
    if (k === 'name') return dir * (a.name ?? '').localeCompare(b.name ?? '')
    if (k === 'last_sale_at') return dir * (a.last_sale_at ?? '').localeCompare(b.last_sale_at ?? '')
    return dir * (((a[k] as number) ?? 0) - ((b[k] as number) ?? 0))
  })
})

const days = 30
onMounted(() => { fetchOverview(days).catch(() => {}) })

const activityClass: Record<string, string> = {
  active: 'bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400',
  idle: 'bg-amber-100 text-amber-700 dark:bg-amber-900/30 dark:text-amber-400',
  dead: 'bg-muted text-muted-foreground',
}
</script>

<template>
  <div class="p-4 space-y-6">
    <div>
      <h1 class="text-2xl font-semibold">{{ t('platformAdmin.title') }}</h1>
      <p class="text-muted-foreground">{{ t('platformAdmin.subtitle') }}</p>
    </div>

    <p v-if="error" class="text-destructive">{{ error }}</p>
    <p v-if="loading" class="text-muted-foreground">…</p>

    <div v-if="overview" class="grid grid-cols-2 md:grid-cols-5 gap-3">
      <div v-for="card in [
        { label: t('platformAdmin.totals.companies'), value: overview.totals.company_count },
        { label: t('platformAdmin.totals.users'), value: overview.totals.user_count },
        { label: t('platformAdmin.totals.machines'), value: overview.totals.machine_count },
        { label: t('platformAdmin.totals.devices'), value: overview.totals.device_count },
        { label: t('platformAdmin.totals.devicesOnline'), value: overview.totals.devices_online },
      ]" :key="card.label" class="rounded-lg border p-4">
        <div class="text-sm text-muted-foreground">{{ card.label }}</div>
        <div class="text-2xl font-semibold tabular-nums">{{ card.value }}</div>
      </div>
    </div>

    <div v-if="overview" class="rounded-lg border overflow-x-auto">
      <table class="w-full text-sm">
        <thead class="bg-muted/50">
          <tr class="text-left">
            <th class="p-2 cursor-pointer" @click="toggleSort('name')">{{ t('platformAdmin.table.company') }}</th>
            <th class="p-2 cursor-pointer" @click="toggleSort('user_count')">{{ t('platformAdmin.table.users') }}</th>
            <th class="p-2 cursor-pointer" @click="toggleSort('machine_count')">{{ t('platformAdmin.table.machines') }}</th>
            <th class="p-2">{{ t('platformAdmin.table.devicesOnline') }}</th>
            <th class="p-2 cursor-pointer" @click="toggleSort('sales_window_count')">{{ t('platformAdmin.table.salesWindow', { days }) }}</th>
            <th class="p-2 cursor-pointer" @click="toggleSort('sales_window_revenue')">{{ t('platformAdmin.table.revenueWindow', { days }) }}</th>
            <th class="p-2 cursor-pointer" @click="toggleSort('last_sale_at')">{{ t('platformAdmin.table.lastActivity') }}</th>
            <th class="p-2">{{ t('platformAdmin.table.activity') }}</th>
          </tr>
        </thead>
        <tbody>
          <tr
            v-for="c in sortedCompanies"
            :key="c.company_id"
            class="border-t hover:bg-muted/40 cursor-pointer"
            @click="navigateTo(`/admin/platform/${c.company_id}`)"
          >
            <td class="p-2 font-medium">{{ c.name }}</td>
            <td class="p-2 tabular-nums">{{ c.user_count }}</td>
            <td class="p-2 tabular-nums">{{ c.machine_count }}</td>
            <td class="p-2 tabular-nums">{{ c.devices_online }} / {{ c.device_count }}</td>
            <td class="p-2 tabular-nums">{{ c.sales_window_count }}</td>
            <td class="p-2 tabular-nums">{{ formatCurrency(c.sales_window_revenue) }}</td>
            <td class="p-2">{{ c.last_sale_at ? timeAgo(c.last_sale_at, t) : t('platformAdmin.neverActive') }}</td>
            <td class="p-2">
              <span class="rounded px-2 py-0.5 text-xs" :class="activityClass[companyActivityLevel(c.last_sale_at)]">
                {{ t(`platformAdmin.activity.${companyActivityLevel(c.last_sale_at)}`) }}
              </span>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</template>
