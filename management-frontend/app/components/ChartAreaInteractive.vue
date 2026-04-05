<script setup lang="ts">
import { VisAxis, VisStackedBar, VisXYContainer } from "@unovis/vue"
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from '@/components/ui/card'

const { t, locale } = useI18n()

interface SalesByDay {
  date: Date
  total: number
}

const props = withDefaults(defineProps<{
  data: SalesByDay[]
  title?: string
  description?: string
}>(), {
  title: undefined,
  description: undefined,
})

type Data = SalesByDay
</script>

<template>
  <Card class="pt-0">
    <CardHeader class="flex items-center gap-2 space-y-0 border-b py-5 sm:flex-row">
      <div class="grid flex-1 gap-1">
        <CardTitle>{{ title ?? t('dashboard.dailySales') }}</CardTitle>
        <CardDescription>
          {{ description ?? t('dashboard.revenuePerDay') }}
        </CardDescription>
      </div>
    </CardHeader>
    <CardContent class="px-2 pt-4 sm:px-6 sm:pt-6 pb-4">
      <div v-if="data.length === 0" class="flex h-[250px] items-center justify-center text-sm text-muted-foreground">
        {{ t('dashboard.noSalesData') }}
      </div>
      <VisXYContainer v-else :data="data" class="h-[250px] w-full">
        <VisStackedBar
          :x="(d: Data) => d.date"
          :y="[(d: Data) => d.total]"
          color="var(--primary)"
          :bar-padding="0.2"
          :rounded-corners="4"
        />
        <VisAxis
          type="x"
          :x="(d: Data) => d.date"
          :tick-line="false"
          :domain-line="false"
          :grid-line="false"
          :num-ticks="6"
          :tick-format="(d: number) => new Date(d).toLocaleDateString(locale, { month: 'short', day: 'numeric' })"
        />
        <VisAxis
          type="y"
          :num-ticks="3"
          :tick-line="false"
          :domain-line="false"
        />
      </VisXYContainer>
    </CardContent>
  </Card>
</template>
