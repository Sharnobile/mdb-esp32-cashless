<script setup lang="ts">
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from '@/components/ui/card'
import { formatCurrency } from '@/lib/utils'

const { t } = useI18n()

export interface TopProduct {
  product_id: string
  name: string
  units_sold: number
  total_revenue: number
}

const props = defineProps<{
  products: TopProduct[]
}>()

const maxRevenue = computed(() =>
  props.products.length > 0 ? props.products[0]!.total_revenue : 1
)

const rankColors = [
  'bg-green-500 text-white',
  'bg-green-500/80 text-white',
  'bg-green-500/60 text-white',
  'bg-green-500/40 text-white',
  'bg-green-500/30 text-white',
]
</script>

<template>
  <Card class="pt-0">
    <CardHeader class="border-b py-5">
      <div class="grid flex-1 gap-1">
        <CardTitle>{{ t('dashboard.topProducts') }}</CardTitle>
        <CardDescription>{{ t('dashboard.topProductsDesc') }}</CardDescription>
      </div>
    </CardHeader>
    <CardContent class="px-4 pt-4 sm:px-6 sm:pt-6 pb-4">
      <div v-if="products.length === 0" class="flex h-[250px] items-center justify-center text-sm text-muted-foreground">
        {{ t('dashboard.noSalesData') }}
      </div>
      <div v-else class="space-y-4">
        <div v-for="(product, index) in products" :key="product.product_id" class="space-y-1.5">
          <div class="flex items-center gap-3">
            <span
              class="flex size-6 shrink-0 items-center justify-center rounded-full text-xs font-bold"
              :class="rankColors[index] ?? 'bg-muted text-muted-foreground'"
            >
              {{ index + 1 }}
            </span>
            <div class="min-w-0 flex-1">
              <div class="flex items-baseline justify-between gap-2">
                <span class="truncate text-sm font-medium">{{ product.name }}</span>
                <span class="shrink-0 text-sm font-semibold tabular-nums">{{ formatCurrency(product.total_revenue) }}</span>
              </div>
              <span class="text-xs text-muted-foreground">{{ t('dashboard.nSales', product.units_sold) }}</span>
            </div>
          </div>
          <div class="ml-9 h-1.5 overflow-hidden rounded-full bg-muted">
            <div
              class="h-full rounded-full bg-primary transition-all"
              :style="{ width: `${(product.total_revenue / maxRevenue) * 100}%` }"
            />
          </div>
        </div>
      </div>
    </CardContent>
  </Card>
</template>
