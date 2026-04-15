<script setup lang="ts">
import { NuxtLink } from '#components'
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
} from '@/components/ui/card'
import { formatCurrency, formatDateTime } from '@/lib/utils'

const { t, locale } = useI18n()

export interface RecentSale {
  id: string
  created_at: string
  item_price: number
  item_number: number
  channel: string
  machine_name: string | null
  product_id: string | null
  product_name: string | null
  product_image_url: string | null
}

defineProps<{
  sales: RecentSale[]
}>()
</script>

<template>
  <Card>
    <CardHeader class="flex flex-row items-center justify-between pb-2">
      <CardTitle class="text-base font-medium">{{ t('dashboard.recentSales') }}</CardTitle>
    </CardHeader>
    <CardContent class="px-0 pb-0">
      <div v-if="sales.length === 0" class="flex items-center justify-center py-8 text-sm text-muted-foreground">
        {{ t('dashboard.noRecentSales') }}
      </div>
      <div v-else class="divide-y divide-border">
        <component
          :is="sale.product_id ? NuxtLink : 'div'"
          v-for="sale in sales"
          :key="sale.id"
          :to="sale.product_id ? `/products/${sale.product_id}` : undefined"
          :class="[
            'flex items-center gap-2 sm:gap-3 px-3 sm:px-6 py-3',
            sale.product_id ? 'hover:bg-muted/50 cursor-pointer transition-colors' : '',
          ]"
        >
          <!-- Product image or price badge -->
          <img
            v-if="sale.product_image_url"
            :src="sale.product_image_url"
            :alt="sale.product_name ?? ''"
            class="h-9 w-9 shrink-0 rounded-full object-cover"
          />
          <div v-else class="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-primary/10 text-xs font-semibold text-primary">
            {{ formatCurrency(sale.item_price, locale) }}
          </div>

          <!-- Product + Machine -->
          <div class="min-w-0 flex-1">
            <p class="truncate text-sm font-medium">
              {{ sale.product_name ?? `${t('machineDetail.item')} #${sale.item_number}` }}
            </p>
            <p v-if="sale.machine_name" class="truncate text-xs text-muted-foreground">
              {{ sale.machine_name }}
            </p>
          </div>

          <!-- Price + Date -->
          <div class="shrink-0 text-right">
            <span class="text-sm font-medium tabular-nums">
              {{ formatCurrency(sale.item_price, locale) }}
            </span>
            <p class="text-xs text-muted-foreground tabular-nums">
              {{ formatDateTime(sale.created_at, locale.value) }}
            </p>
          </div>
        </component>
      </div>
    </CardContent>
  </Card>
</template>
