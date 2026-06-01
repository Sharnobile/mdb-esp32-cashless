<script setup lang="ts">
import type { MatchPair } from '~/composables/useNayaxReconciliation'
import { IconChevronDown, IconChevronRight, IconCircleCheck } from '@tabler/icons-vue'
import { formatCurrency, formatDateTime } from '@/lib/utils'

defineProps<{ rows: MatchPair[]; open: boolean }>()
defineEmits<{ toggle: [] }>()
const { t, locale } = useI18n()
</script>

<template>
  <div class="rounded-xl border bg-card shadow-sm">
    <button class="flex w-full items-center justify-between p-4 hover:bg-muted/30" @click="$emit('toggle')">
      <span class="flex items-center gap-2 text-sm font-medium">
        <IconCircleCheck class="h-4 w-4 text-green-600" />
        {{ t('nayax.reconcile.results.matchedTitle') }} ({{ rows.length }})
      </span>
      <component :is="open ? IconChevronDown : IconChevronRight" class="h-4 w-4 text-muted-foreground" />
    </button>
    <div v-if="open && rows.length > 0" class="overflow-x-auto border-t">
      <table class="w-full text-sm">
        <thead>
          <tr class="border-b bg-muted/40 text-left">
            <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colTime') }}</th>
            <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colMachine') }}</th>
            <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colSlot') }}</th>
            <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colProduct') }}</th>
            <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colPrice') }}</th>
            <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colDelta') }}</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="m in rows" :key="m.nayax.txId" class="border-b last:border-0">
            <td class="px-4 py-2">{{ formatDateTime(m.nayax.utcDt, locale) }}</td>
            <td class="px-4 py-2">{{ m.nayax.machineName }}</td>
            <td class="px-4 py-2 tabular-nums">{{ m.nayax.itemNumber }}</td>
            <td class="px-4 py-2">
              {{ m.db.product_name ?? m.nayax.productName }}
              <span
                v-if="m.priceDiffers"
                class="ml-2 inline-flex items-center rounded-full bg-amber-100 px-2 py-0.5 text-[10px] font-medium text-amber-800 dark:bg-amber-950 dark:text-amber-200"
              >
                {{ t('nayax.reconcile.results.priceDiffers') }}
              </span>
            </td>
            <td class="px-4 py-2 tabular-nums">{{ formatCurrency(m.nayax.priceGross, locale) }}</td>
            <td
              class="px-4 py-2 tabular-nums"
              :class="Math.abs(m.deltaSeconds) >= 5 ? 'text-yellow-700 dark:text-yellow-400' : 'text-muted-foreground'"
            >
              {{ m.deltaSeconds > 0 ? '+' : '' }}{{ m.deltaSeconds.toFixed(1) }}s
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</template>
