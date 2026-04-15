<script setup lang="ts">
definePageMeta({ middleware: 'auth' })

import { NuxtLink } from '#components'
import { IconChevronDown, IconCheck, IconPlayerSkipForward } from '@tabler/icons-vue'
import { timeAgo, formatDateTime } from '@/lib/utils'
import { useTourHistory } from '@/composables/useTourHistory'

const { t } = useI18n()
const { tours, loading, fetchTours } = useTourHistory()

const expandedTourIds = ref(new Set<string>())

function toggleExpanded(tourId: string) {
  const next = new Set(expandedTourIds.value)
  if (next.has(tourId)) {
    next.delete(tourId)
  } else {
    next.add(tourId)
  }
  expandedTourIds.value = next
}

function isExpanded(tourId: string): boolean {
  return expandedTourIds.value.has(tourId)
}

onMounted(() => fetchTours())
</script>

<template>
  <div class="flex flex-1 flex-col gap-4 p-3 sm:gap-6 sm:p-4 md:p-6">
    <!-- Header -->
    <div>
      <h1 class="text-xl font-bold tracking-tight sm:text-2xl">{{ t('tourHistory.title') }}</h1>
      <p class="text-sm text-muted-foreground">{{ t('tourHistory.subtitle') }}</p>
    </div>

    <!-- Loading -->
    <div v-if="loading && tours.length === 0" class="space-y-2">
      <div
        v-for="i in 5"
        :key="i"
        class="h-16 animate-pulse rounded-xl bg-muted"
      />
    </div>

    <!-- Empty state -->
    <div
      v-else-if="!loading && tours.length === 0"
      class="flex flex-col items-center justify-center gap-2 py-24 text-center text-muted-foreground"
    >
      <p class="font-medium">{{ t('tourHistory.noTours') }}</p>
    </div>

    <!-- Tour cards -->
    <div v-else class="flex flex-col gap-2">
      <div
        v-for="tour in tours"
        :key="tour.tour_id"
        class="rounded-xl border bg-card overflow-hidden"
      >
        <!-- Card header (always visible) -->
        <button
          class="flex w-full items-center gap-3 px-4 py-3 text-left transition-colors hover:bg-muted/50"
          @click="toggleExpanded(tour.tour_id)"
        >
          <!-- Expand chevron -->
          <IconChevronDown
            class="h-4 w-4 shrink-0 text-muted-foreground transition-transform"
            :class="isExpanded(tour.tour_id) ? 'rotate-180' : ''"
          />

          <!-- Tour info -->
          <div class="min-w-0 flex-1">
            <div class="flex items-center gap-2 flex-wrap">
              <span class="text-sm font-medium" :title="formatDateTime(tour.date)">
                {{ timeAgo(tour.date, t) }}
              </span>
              <span class="text-xs text-muted-foreground">&middot;</span>
              <span class="text-sm text-muted-foreground truncate">{{ tour.user_display }}</span>
            </div>
          </div>

          <!-- Stats -->
          <div class="flex items-center gap-3 shrink-0 text-xs">
            <span class="inline-flex items-center gap-1 rounded-full border px-2 py-0.5">
              <span class="font-medium">{{ tour.total_machines }}</span>
              <span class="text-muted-foreground hidden sm:inline">{{ tour.total_machines === 1 ? t('tourHistory.machine') : t('tourHistory.machines') }}</span>
            </span>
            <span class="inline-flex items-center gap-1 rounded-full bg-primary/10 px-2 py-0.5 font-medium text-primary">
              +{{ tour.total_items_added }}
            </span>
          </div>
        </button>

        <!-- Expanded details -->
        <div v-if="isExpanded(tour.tour_id)" class="border-t px-4 py-3 space-y-2">
          <div
            v-for="machine in tour.machines"
            :key="machine.machine_id"
            class="rounded-lg border px-3 py-2.5"
          >
            <div class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium truncate">{{ machine.machine_name }}</span>
              <span
                v-if="machine.skipped"
                class="inline-flex items-center gap-1 rounded-full bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-700 dark:bg-amber-950/40 dark:text-amber-400 shrink-0"
              >
                <IconPlayerSkipForward class="h-3 w-3" />
                {{ t('tourHistory.skipped') }}
              </span>
              <span
                v-else
                class="inline-flex items-center gap-1 rounded-full bg-green-100 px-2 py-0.5 text-xs font-medium text-green-700 dark:bg-green-950/40 dark:text-green-400 shrink-0"
              >
                <IconCheck class="h-3 w-3" />
                +{{ machine.total_added }}
              </span>
            </div>

            <!-- Product list -->
            <div v-if="machine.products.length > 0" class="mt-1.5 space-y-0.5">
              <component
                :is="product.product_id ? NuxtLink : 'div'"
                v-for="(product, idx) in machine.products"
                :key="idx"
                :to="product.product_id ? `/products/${product.product_id}` : undefined"
                :class="[
                  'block text-xs text-muted-foreground',
                  product.product_id ? 'hover:text-foreground hover:underline cursor-pointer' : '',
                ]"
              >
                {{ product.quantity }}&times; {{ product.product_name }}
              </component>
            </div>
          </div>

          <!-- Tour timestamp -->
          <p class="text-[11px] text-muted-foreground pt-1">
            {{ formatDateTime(tour.date) }}
          </p>
        </div>
      </div>
    </div>
  </div>
</template>
