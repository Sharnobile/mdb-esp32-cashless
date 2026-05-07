<script setup lang="ts">
import { IconBuildingStore } from '@tabler/icons-vue'
import { Card, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { formatCurrency } from '@/lib/utils'
import type { TheoreticalCash } from '@/composables/useCashBook'

defineProps<{ theoreticalCash: TheoreticalCash | null }>()
const { t } = useI18n()
</script>

<template>
  <Card>
    <CardHeader>
      <CardDescription class="flex items-center gap-1.5">
        <IconBuildingStore class="size-4" />
        {{ t('cashBook.inMachines') }}
      </CardDescription>
      <CardTitle class="text-2xl font-semibold tabular-nums">
        {{ theoreticalCash ? formatCurrency(theoreticalCash.cash_sales_since) : '—' }}
      </CardTitle>
    </CardHeader>
    <div v-if="theoreticalCash?.machines?.length" class="px-6 pb-4 space-y-0.5 text-xs text-muted-foreground">
      <div v-for="m in theoreticalCash.machines" :key="m.machine_id" class="flex justify-between gap-2">
        <span class="truncate">{{ m.machine_name || 'Automat' }}</span>
        <span class="tabular-nums">+{{ formatCurrency(m.cash_sales) }}</span>
      </div>
    </div>
  </Card>
</template>
