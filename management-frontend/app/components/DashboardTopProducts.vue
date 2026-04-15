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

type SortMode = 'revenue' | 'units'
const sortMode = ref<SortMode>('revenue')

const sorted = computed(() => {
  const copy = [...props.products]
  if (sortMode.value === 'units') {
    copy.sort((a, b) => b.units_sold - a.units_sold)
  } else {
    copy.sort((a, b) => b.total_revenue - a.total_revenue)
  }
  return copy.slice(0, 5)
})

const maxValue = computed(() => {
  if (sorted.value.length === 0) return 1
  return sortMode.value === 'units'
    ? sorted.value[0]!.units_sold
    : sorted.value[0]!.total_revenue
})

function barWidth(product: TopProduct) {
  const val = sortMode.value === 'units' ? product.units_sold : product.total_revenue
  return `${(val / maxValue.value) * 100}%`
}

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
    <CardHeader class="flex items-center justify-between gap-2 border-b py-5 sm:flex-row">
      <div class="grid flex-1 gap-1">
        <CardTitle>{{ t('dashboard.topProducts') }}</CardTitle>
        <CardDescription>{{ t('dashboard.topProductsDesc') }}</CardDescription>
      </div>
      <div class="flex shrink-0 rounded-md border text-xs">
        <button
          class="rounded-l-md px-2.5 py-1 font-medium transition-colors"
          :class="sortMode === 'revenue' ? 'bg-primary text-primary-foreground' : 'text-muted-foreground hover:text-foreground'"
          @click="sortMode = 'revenue'"
        >
          {{ t('dashboard.topByRevenue') }}
        </button>
        <button
          class="rounded-r-md border-l px-2.5 py-1 font-medium transition-colors"
          :class="sortMode === 'units' ? 'bg-primary text-primary-foreground' : 'text-muted-foreground hover:text-foreground'"
          @click="sortMode = 'units'"
        >
          {{ t('dashboard.topByUnits') }}
        </button>
      </div>
    </CardHeader>
    <CardContent class="px-4 pt-4 sm:px-6 sm:pt-6 pb-4">
      <div v-if="products.length === 0" class="flex h-[250px] items-center justify-center text-sm text-muted-foreground">
        {{ t('dashboard.noSalesData') }}
      </div>
      <div v-else class="space-y-4">
        <NuxtLink
          v-for="(product, index) in sorted"
          :key="product.product_id"
          :to="`/products/${product.product_id}`"
          class="block space-y-1.5 rounded-md p-1 -m-1 hover:bg-muted/50 transition-colors"
        >
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
                <span class="shrink-0 text-sm font-semibold tabular-nums">
                  {{ sortMode === 'revenue' ? formatCurrency(product.total_revenue) : product.units_sold }}
                </span>
              </div>
              <span class="text-xs text-muted-foreground">
                {{ sortMode === 'revenue' ? t('dashboard.nSales', product.units_sold) : formatCurrency(product.total_revenue) }}
              </span>
            </div>
          </div>
          <div class="ml-9 h-1.5 overflow-hidden rounded-full bg-muted">
            <div
              class="h-full rounded-full bg-primary transition-all"
              :style="{ width: barWidth(product) }"
            />
          </div>
        </NuxtLink>
      </div>
    </CardContent>
  </Card>
</template>
