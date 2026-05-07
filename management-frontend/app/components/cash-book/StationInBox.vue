<script setup lang="ts">
import { IconCash } from '@tabler/icons-vue'
import { Card, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { formatCurrency, formatDate } from '@/lib/utils'

defineProps<{ currentBalance: number; lastEntryAt: string | null }>()
const { t } = useI18n()
</script>

<template>
  <Card>
    <CardHeader>
      <CardDescription class="flex items-center gap-1.5">
        <IconCash class="size-4" />
        {{ t('cashBook.inBox') }}
      </CardDescription>
      <CardTitle class="text-2xl font-semibold tabular-nums">
        {{ formatCurrency(currentBalance) }}
      </CardTitle>
    </CardHeader>
    <div v-if="lastEntryAt" class="px-6 pb-4 text-xs text-muted-foreground">
      {{ t('cashBook.sinceDate', { date: formatDate(lastEntryAt) }) }}
    </div>
  </Card>
</template>
