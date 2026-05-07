<script setup lang="ts">
import { IconBuildingBank } from '@tabler/icons-vue'
import { Card, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { formatCurrency, formatDate } from '@/lib/utils'
import type { CashBookEntry } from '@/composables/useCashBook'

const props = defineProps<{ lastBankDeposit: CashBookEntry | null }>()
const { t } = useI18n()

const daysAgo = computed(() => {
  if (!props.lastBankDeposit) return null
  const ms = Date.now() - new Date(props.lastBankDeposit.created_at).getTime()
  return Math.floor(ms / (24 * 60 * 60 * 1000))
})
</script>

<template>
  <Card>
    <CardHeader>
      <CardDescription class="flex items-center gap-1.5">
        <IconBuildingBank class="size-4" />
        {{ t('cashBook.lastBankDeposit') }}
      </CardDescription>
      <CardTitle class="text-2xl font-semibold tabular-nums">
        <template v-if="lastBankDeposit">
          {{ formatCurrency(Math.abs(lastBankDeposit.amount)) }}
        </template>
        <template v-else>
          <span class="text-base font-normal text-muted-foreground">{{ t('cashBook.noBankDepositYet') }}</span>
        </template>
      </CardTitle>
    </CardHeader>
    <div v-if="lastBankDeposit && daysAgo !== null" class="px-6 pb-4 text-xs text-muted-foreground">
      {{ daysAgo === 0 ? t('common.today') : t('cashBook.agoDays', { n: daysAgo }) }}
      · {{ formatDate(lastBankDeposit.created_at) }}
    </div>
  </Card>
</template>
