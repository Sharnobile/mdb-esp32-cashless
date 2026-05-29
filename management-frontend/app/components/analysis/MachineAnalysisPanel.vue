<script setup lang="ts">
import { Sheet, SheetContent, SheetHeader, SheetTitle, SheetDescription } from '@/components/ui/sheet'
import { Badge } from '@/components/ui/badge'
import { IconSparkles, IconLoader2, IconArrowRight, IconFlask } from '@tabler/icons-vue'
import { formatCurrency } from '@/lib/utils'
import MachineLayoutGrid from './MachineLayoutGrid.vue'
import { useMachineAnalysis, type SlotAnalysis, type SlotTier, type Suggestion } from '@/composables/useMachineAnalysis'
import { useInsights, priorityVariant, recommendationTypeLabel } from '@/composables/useInsights'

const props = defineProps<{ machineId: string; isAdmin: boolean }>()

const { t, locale } = useI18n()

const { slots, rowCount, loading, error, days, tierCounts, weakSlots, lostRevenuePotential, analyze, applySwap } = useMachineAnalysis()

const PERIODS = [7, 30, 90]

const TIER_ORDER: SlotTier[] = ['dead', 'weak', 'testing', 'ok', 'strong', 'empty']
const tierDot: Record<SlotTier, string> = {
  dead: 'bg-red-500',
  weak: 'bg-orange-400',
  testing: 'bg-blue-400',
  ok: 'bg-yellow-400',
  strong: 'bg-green-500',
  empty: 'bg-muted-foreground/30',
}

onMounted(() => analyze(props.machineId))

function changePeriod(d: number) {
  analyze(props.machineId, d)
}

// ── Slot detail sheet ────────────────────────────────────────────────────────
const sheetOpen = ref(false)
const selectedTrayId = ref<string | null>(null)
const selectedSlot = computed(() => slots.value.find(s => s.trayId === selectedTrayId.value) ?? null)
const applyingProductId = ref<string | null>(null)

function openSlot(slot: SlotAnalysis) {
  selectedTrayId.value = slot.trayId
  sheetOpen.value = true
}

async function handleApply(suggestion: Suggestion) {
  if (!selectedSlot.value) return
  applyingProductId.value = suggestion.product_id
  try {
    await applySwap(selectedSlot.value.trayId, suggestion.product_id)
    sheetOpen.value = false
  } catch { /* error surfaced via composable */ } finally {
    applyingProductId.value = null
  }
}

// ── AI recommendations ─────────────────────────────────────────────────────
const { data: insights, loading: aiLoading, error: aiError, fetchInsights } = useInsights()
const aiRequested = ref(false)

function loadAi() {
  aiRequested.value = true
  fetchInsights(props.machineId, days.value)
}

const aiSwaps = computed(() =>
  (insights.value?.recommendations ?? []).filter(r => r.type === 'product_swap' || r.type === 'remove_slot'),
)
</script>

<template>
  <div class="space-y-6">
    <!-- Header -->
    <div class="flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
      <div>
        <h2 class="text-base font-medium">{{ t('analysis.title') }}</h2>
        <p class="text-sm text-muted-foreground">{{ t('analysis.subtitle') }}</p>
      </div>
      <div class="flex items-center gap-1 rounded-md border p-0.5">
        <button
          v-for="d in PERIODS"
          :key="d"
          class="rounded px-2.5 py-1 text-xs font-medium transition-colors"
          :class="days === d ? 'bg-primary text-primary-foreground' : 'text-muted-foreground hover:bg-muted'"
          @click="changePeriod(d)"
        >
          {{ t('analysis.days', { count: d }) }}
        </button>
      </div>
    </div>

    <!-- Loading / error / empty -->
    <div v-if="loading && slots.length === 0" class="flex items-center justify-center py-12 text-muted-foreground">
      <IconLoader2 class="size-5 animate-spin" />
    </div>
    <div v-else-if="error" class="rounded-md border border-destructive/40 bg-destructive/5 p-4 text-sm text-destructive">
      {{ error }}
    </div>
    <div v-else-if="slots.length === 0" class="rounded-xl border border-dashed p-8 text-center text-sm text-muted-foreground">
      {{ t('analysis.noTrays') }}
    </div>

    <template v-else>
      <!-- KPI strip -->
      <div class="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <div class="rounded-xl border bg-card p-3">
          <p class="text-xs text-muted-foreground">{{ t('analysis.tier.dead') }}</p>
          <p class="text-xl font-semibold tabular-nums">{{ tierCounts.dead }}</p>
        </div>
        <div class="rounded-xl border bg-card p-3">
          <p class="text-xs text-muted-foreground">{{ t('analysis.tier.weak') }}</p>
          <p class="text-xl font-semibold tabular-nums">{{ tierCounts.weak }}</p>
        </div>
        <div class="rounded-xl border bg-card p-3">
          <p class="text-xs text-muted-foreground">{{ t('analysis.tier.testing') }}</p>
          <p class="text-xl font-semibold tabular-nums">{{ tierCounts.testing }}</p>
        </div>
        <div class="rounded-xl border bg-card p-3">
          <p class="text-xs text-muted-foreground">{{ t('analysis.opportunity') }}</p>
          <p class="text-xl font-semibold tabular-nums">{{ formatCurrency(lostRevenuePotential, locale) }}</p>
        </div>
      </div>

      <!-- Layout grid -->
      <div class="rounded-xl border bg-card p-3 sm:p-4">
        <MachineLayoutGrid
          :slots="slots"
          :row-count="rowCount"
          :selected-tray-id="selectedTrayId"
          @select="openSlot"
        />
        <!-- Legend -->
        <div class="mt-4 flex flex-wrap gap-x-4 gap-y-1.5">
          <div v-for="tier in TIER_ORDER" :key="tier" class="flex items-center gap-1.5 text-xs text-muted-foreground">
            <span class="size-2.5 rounded-full" :class="tierDot[tier]" />
            {{ t(`analysis.tier.${tier}`) }} ({{ tierCounts[tier] }})
          </div>
        </div>
      </div>

      <!-- Weak slots list -->
      <div>
        <h3 class="mb-2 text-sm font-medium">{{ t('analysis.weakSlots') }}</h3>
        <p v-if="weakSlots.length === 0" class="text-sm text-muted-foreground">{{ t('analysis.noWeakSlots') }}</p>
        <div v-else class="rounded-xl border bg-card divide-y">
          <button
            v-for="slot in weakSlots"
            :key="slot.trayId"
            class="flex w-full items-center gap-3 px-4 py-3 text-left transition-colors hover:bg-muted/50"
            @click="openSlot(slot)"
          >
            <img
              v-if="slot.image_url"
              :src="slot.image_url"
              :alt="slot.product_name ?? ''"
              class="h-9 w-9 shrink-0 rounded object-cover"
            />
            <div v-else class="flex h-9 w-9 shrink-0 items-center justify-center rounded bg-muted text-xs text-muted-foreground">
              {{ slot.item_number }}
            </div>
            <div class="min-w-0 flex-1">
              <p class="truncate text-sm font-medium">
                {{ slot.product_name ?? t('analysis.emptySlot') }}
              </p>
              <p class="text-xs text-muted-foreground">
                {{ t('analysis.slot') }} {{ slot.item_number }} ·
                {{ t('analysis.unitsShort', { n: slot.units_sold }) }} ·
                {{ Math.round(slot.sell_through_pct) }}%
                <template v-if="slot.days_in_slot != null"> · {{ t('analysis.inSlotFor', { days: slot.days_in_slot }) }}</template>
              </p>
            </div>
            <Badge :variant="slot.tier === 'dead' ? 'destructive' : 'secondary'">
              {{ t(`analysis.tier.${slot.tier}`) }}
            </Badge>
            <IconArrowRight class="size-4 shrink-0 text-muted-foreground" />
          </button>
        </div>
      </div>

      <!-- AI recommendations -->
      <div class="rounded-xl border bg-card p-4">
        <div class="flex items-center justify-between gap-2">
          <h3 class="flex items-center gap-1.5 text-sm font-medium">
            <IconSparkles class="size-4 text-primary" />
            {{ t('analysis.aiRecommendations') }}
          </h3>
          <button
            v-if="!aiRequested"
            class="inline-flex h-8 items-center gap-1.5 rounded-md border px-3 text-xs font-medium transition-colors hover:bg-muted"
            @click="loadAi"
          >
            {{ t('analysis.loadAi') }}
          </button>
        </div>
        <div v-if="aiLoading" class="mt-3 flex items-center gap-2 text-sm text-muted-foreground">
          <IconLoader2 class="size-4 animate-spin" /> {{ t('analysis.aiLoading') }}
        </div>
        <p v-else-if="aiError" class="mt-3 text-sm text-destructive">{{ aiError }}</p>
        <template v-else-if="aiRequested && insights">
          <p v-if="insights.summary" class="mt-3 text-sm text-muted-foreground">{{ insights.summary }}</p>
          <p v-if="aiSwaps.length === 0" class="mt-3 text-sm text-muted-foreground">{{ t('analysis.noAiSwaps') }}</p>
          <div v-else class="mt-3 space-y-2">
            <div v-for="(rec, i) in aiSwaps" :key="i" class="rounded-lg border p-3">
              <div class="flex items-center gap-2">
                <Badge :variant="priorityVariant(rec.priority)">{{ t(recommendationTypeLabel(rec.type)) }}</Badge>
                <span v-if="rec.item_number != null" class="text-xs text-muted-foreground">{{ t('analysis.slot') }} {{ rec.item_number }}</span>
              </div>
              <p class="mt-1.5 text-sm font-medium">{{ rec.title }}</p>
              <p class="text-sm text-muted-foreground">{{ rec.detail }}</p>
            </div>
          </div>
        </template>
      </div>
    </template>

    <!-- Slot detail sheet -->
    <Sheet v-model:open="sheetOpen">
      <SheetContent class="w-full overflow-y-auto sm:max-w-md">
        <SheetHeader>
          <SheetTitle>
            {{ selectedSlot?.product_name ?? t('analysis.emptySlot') }}
          </SheetTitle>
          <SheetDescription>
            {{ t('analysis.slot') }} {{ selectedSlot?.item_number }}
          </SheetDescription>
        </SheetHeader>

        <div v-if="selectedSlot" class="mt-4 space-y-5 px-1">
          <!-- KPIs -->
          <div class="grid grid-cols-2 gap-3">
            <div class="rounded-lg border p-3">
              <p class="text-xs text-muted-foreground">{{ t('analysis.unitsSold') }}</p>
              <p class="text-lg font-semibold tabular-nums">{{ selectedSlot.units_sold }}</p>
            </div>
            <div class="rounded-lg border p-3">
              <p class="text-xs text-muted-foreground">{{ t('analysis.revenue') }}</p>
              <p class="text-lg font-semibold tabular-nums">{{ formatCurrency(selectedSlot.revenue_eur, locale) }}</p>
            </div>
            <div class="rounded-lg border p-3">
              <p class="text-xs text-muted-foreground">{{ t('analysis.sellThrough') }}</p>
              <p class="text-lg font-semibold tabular-nums">{{ Math.round(selectedSlot.sell_through_pct) }}%</p>
            </div>
            <div class="rounded-lg border p-3">
              <p class="text-xs text-muted-foreground">{{ t('analysis.avgDaily') }}</p>
              <p class="text-lg font-semibold tabular-nums">{{ selectedSlot.avg_daily_units }}</p>
            </div>
          </div>

          <p v-if="selectedSlot.days_in_slot != null" class="text-xs text-muted-foreground">
            {{ t('analysis.inSlotFor', { days: selectedSlot.days_in_slot }) }}
          </p>
          <div v-if="selectedSlot.tier === 'testing'" class="rounded-lg border border-blue-400/40 bg-blue-400/10 p-3 text-sm">
            {{ t('analysis.testingHint') }}
          </div>

          <!-- Replacement suggestions -->
          <div v-if="selectedSlot.suggestions.length > 0">
            <h4 class="mb-2 text-sm font-medium">{{ t('analysis.suggestions') }}</h4>
            <div class="space-y-2">
              <div
                v-for="sug in selectedSlot.suggestions"
                :key="sug.product_id"
                class="flex items-center gap-3 rounded-lg border p-2.5"
              >
                <img
                  v-if="sug.image_url"
                  :src="sug.image_url"
                  :alt="sug.name"
                  class="h-9 w-9 shrink-0 rounded object-cover"
                />
                <div v-else class="flex h-9 w-9 shrink-0 items-center justify-center rounded bg-muted text-muted-foreground">
                  <IconFlask v-if="sug.kind === 'newcomer'" class="size-4" />
                  <IconSparkles v-else class="size-4" />
                </div>
                <div class="min-w-0 flex-1">
                  <p class="truncate text-sm font-medium">{{ sug.name }}</p>
                  <p class="text-xs text-muted-foreground">
                    <span v-if="sug.kind === 'bestseller'">{{ t('analysis.perDay', { n: sug.velocity.toFixed(1) }) }}</span>
                    <span v-else class="text-blue-600 dark:text-blue-400">{{ t('analysis.neverSold') }}</span>
                  </p>
                </div>
                <button
                  v-if="props.isAdmin"
                  class="inline-flex h-8 items-center gap-1 rounded-md bg-primary px-3 text-xs font-medium text-primary-foreground transition-colors hover:bg-primary/90 disabled:opacity-50"
                  :disabled="applyingProductId !== null"
                  @click="handleApply(sug)"
                >
                  <IconLoader2 v-if="applyingProductId === sug.product_id" class="size-3.5 animate-spin" />
                  {{ applyingProductId === sug.product_id ? t('analysis.applying') : t('analysis.apply') }}
                </button>
              </div>
            </div>
            <p v-if="props.isAdmin" class="mt-2 text-xs text-muted-foreground">{{ t('analysis.swapHint') }}</p>
          </div>
        </div>
      </SheetContent>
    </Sheet>
  </div>
</template>
