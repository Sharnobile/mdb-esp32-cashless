<script setup lang="ts">
definePageMeta({ middleware: 'auth' })

import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Separator } from '@/components/ui/separator'
import { IconArrowLeft, IconCheck, IconPlayerSkipForward, IconTruck } from '@tabler/icons-vue'
import { getProductImageUrl } from '@/composables/useProducts'
import { useRefillWizard } from '@/composables/useRefillWizard'

const { t } = useI18n()
const router = useRouter()
const { warehouses, fetchWarehouses } = useWarehouse()

const {
  currentStep, machines, currentMachineIndex, selectedWarehouseId,
  loading, tourStarting, confirmingRefill,
  currentTrays, currentTraysLoading,
  tourLog, tourSummary, currentMachine, totalMachinesInTour, currentMachineNumber,
  isPacked, togglePacked, allPacked, effectiveDeficit,
  isOutOfWarehouseStock, hasPartialStock, hasAnyPackedItems, effectiveStockHealth,
  initTour, loadWarehouseStock, startTour,
  adjustFillAmount, confirmMachineRefill, skipMachine, resetWizard,
} = useRefillWizard()

// Init
onMounted(async () => {
  await fetchWarehouses()
  if (warehouses.value.length > 0) {
    selectedWarehouseId.value = warehouses.value[0]!.id
  }
  await initTour()
  await loadWarehouseStock()
})

watch(selectedWarehouseId, () => loadWarehouseStock())

function goBack() {
  if (currentStep.value === 'packing') {
    router.push('/machines')
  }
}

const isLastMachine = computed(() =>
  currentMachineIndex.value >= machines.value.length - 1
)
</script>

<template>
  <div class="flex flex-1 flex-col gap-3 p-3 pb-0 sm:gap-4 sm:p-4 md:p-6">
    <!-- Header -->
    <div class="flex items-center gap-3">
      <button
        v-if="currentStep === 'packing'"
        class="inline-flex h-10 w-10 items-center justify-center rounded-md border hover:bg-muted"
        @click="goBack"
      >
        <IconArrowLeft class="h-4 w-4" />
      </button>
      <h1 class="text-xl font-semibold sm:text-2xl">{{ t('refill.title') }}</h1>
    </div>

    <!-- Step indicator — compact on mobile -->
    <div class="flex items-center gap-1.5 sm:gap-2 text-sm">
      <span
        class="inline-flex h-7 w-7 items-center justify-center rounded-full text-xs font-medium"
        :class="currentStep === 'packing' ? 'bg-primary text-primary-foreground' : currentStep === 'refill' || currentStep === 'summary' ? 'bg-green-600 text-white' : 'bg-muted text-muted-foreground'"
      >
        <IconCheck v-if="currentStep !== 'packing'" class="h-3.5 w-3.5" />
        <template v-else>1</template>
      </span>
      <span class="hidden sm:inline" :class="currentStep === 'packing' ? 'font-medium' : 'text-muted-foreground'">{{ t('refill.packingStep') }}</span>
      <span class="text-muted-foreground mx-0.5">&rarr;</span>
      <span
        class="inline-flex h-7 w-7 items-center justify-center rounded-full text-xs font-medium"
        :class="currentStep === 'refill' ? 'bg-primary text-primary-foreground' : currentStep === 'summary' ? 'bg-green-600 text-white' : 'bg-muted text-muted-foreground'"
      >
        <IconCheck v-if="currentStep === 'summary'" class="h-3.5 w-3.5" />
        <template v-else>2</template>
      </span>
      <span class="hidden sm:inline" :class="currentStep === 'refill' ? 'font-medium' : 'text-muted-foreground'">{{ t('refill.refillStep') }}</span>
      <span class="text-muted-foreground mx-0.5">&rarr;</span>
      <span
        class="inline-flex h-7 w-7 items-center justify-center rounded-full text-xs font-medium"
        :class="currentStep === 'summary' ? 'bg-primary text-primary-foreground' : 'bg-muted text-muted-foreground'"
      >3</span>
      <span class="hidden sm:inline" :class="currentStep === 'summary' ? 'font-medium' : 'text-muted-foreground'">{{ t('refill.summaryStep') }}</span>
    </div>

    <!-- Loading -->
    <div v-if="loading" class="text-muted-foreground">{{ t('common.loading') }}</div>

    <!-- ══════════════════════════════════════════════════════════════════════ -->
    <!-- STEP 1: PACKING -->
    <!-- ══════════════════════════════════════════════════════════════════════ -->
    <template v-else-if="currentStep === 'packing'">
      <!-- No machines need refill -->
      <div v-if="machines.length === 0" class="text-muted-foreground py-8 text-center">
        {{ t('refill.noMachinesNeedRefill') }}
      </div>

      <template v-else>
        <!-- Warehouse selector -->
        <div v-if="warehouses.length > 0" class="flex items-center gap-2 rounded-lg border bg-muted/30 px-3 py-2.5">
          <label class="shrink-0 text-sm text-muted-foreground">{{ t('refill.selectWarehouse') }}</label>
          <select
            v-model="selectedWarehouseId"
            class="h-9 min-w-0 flex-1 rounded-md border border-input bg-background px-2 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          >
            <option v-for="wh in warehouses" :key="wh.id" :value="wh.id">{{ wh.name }}</option>
          </select>
        </div>

        <!-- Per-machine packing cards — single column on mobile -->
        <div class="flex flex-col gap-3 pb-20 sm:pb-24 md:grid md:grid-cols-2 xl:grid-cols-3 md:gap-4">
          <Card
            v-for="machine in machines"
            :key="machine.id"
            class="h-full"
            :class="effectiveStockHealth(machine) === 'ok' ? 'opacity-40' : ''"
          >
            <CardHeader class="flex flex-row items-center justify-between space-y-0 pb-2 px-4 sm:px-6">
              <CardTitle class="text-base font-semibold truncate">
                {{ machine.name }}
              </CardTitle>
              <span
                class="ml-2 inline-block h-3 w-3 shrink-0 rounded-full"
                :class="{
                  'bg-red-500': effectiveStockHealth(machine) === 'critical',
                  'bg-amber-500': effectiveStockHealth(machine) === 'low',
                  'bg-green-500': effectiveStockHealth(machine) === 'ok',
                }"
              />
            </CardHeader>

            <CardContent v-if="effectiveStockHealth(machine) !== 'ok'" class="space-y-3 px-4 sm:px-6">
              <!-- Stock bar -->
              <div class="flex items-center gap-2">
                <div class="h-2 flex-1 overflow-hidden rounded-full bg-muted">
                  <div
                    class="h-full rounded-full transition-all"
                    :class="{
                      'bg-red-500': machine.stock_percent < 20,
                      'bg-amber-500': machine.stock_percent >= 20 && machine.stock_percent < 50,
                      'bg-green-500': machine.stock_percent >= 50,
                    }"
                    :style="{ width: `${machine.stock_percent}%` }"
                  />
                </div>
                <span class="text-xs font-medium text-muted-foreground w-8 text-right">{{ machine.stock_percent }}%</span>
              </div>

              <!-- Packing checklist -->
              <div v-if="machine.tray_summary.length > 0" class="space-y-2">
                <div class="flex items-center justify-between">
                  <p class="text-xs font-medium text-muted-foreground uppercase tracking-wide">{{ t('refill.packForMachine') }}</p>
                  <span
                    v-if="allPacked(machine.id, machine.tray_summary)"
                    class="text-xs font-medium text-green-600"
                  >
                    {{ t('refill.allPacked') }}
                  </span>
                </div>
                <ul class="space-y-0.5">
                  <li
                    v-for="item in machine.tray_summary"
                    :key="item.product_id ?? item.product_name"
                    class="flex items-center gap-2.5 rounded-lg px-2 py-2.5 -mx-2 transition-colors"
                    :class="isOutOfWarehouseStock(item)
                      ? 'opacity-50 cursor-not-allowed'
                      : 'cursor-pointer select-none hover:bg-muted/50 active:bg-muted'"
                    @click="togglePacked(machine.id, item)"
                  >
                    <!-- Checkbox — larger touch target -->
                    <span
                      class="flex h-6 w-6 shrink-0 items-center justify-center rounded border-2 transition-colors"
                      :class="isOutOfWarehouseStock(item, machine.id)
                        ? 'border-muted-foreground/20 bg-muted'
                        : isPacked(machine.id, item)
                          ? 'bg-primary border-primary text-primary-foreground'
                          : 'border-muted-foreground/30'"
                    >
                      <svg v-if="isPacked(machine.id, item) && !isOutOfWarehouseStock(item, machine.id)" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" class="h-3.5 w-3.5"><polyline points="20 6 9 17 4 12" /></svg>
                    </span>
                    <!-- Product image -->
                    <img
                      v-if="item.image_path"
                      :src="getProductImageUrl(item.image_path)"
                      :alt="item.product_name"
                      class="h-10 w-10 shrink-0 rounded object-cover transition-opacity"
                      :class="isPacked(machine.id, item) || isOutOfWarehouseStock(item, machine.id) ? 'opacity-40' : ''"
                    />
                    <span
                      v-else
                      class="flex h-10 w-10 shrink-0 items-center justify-center rounded bg-muted text-xs text-muted-foreground transition-opacity"
                      :class="isPacked(machine.id, item) || isOutOfWarehouseStock(item, machine.id) ? 'opacity-40' : ''"
                    >
                      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" class="h-4 w-4"><rect width="18" height="18" x="3" y="3" rx="2" /><circle cx="9" cy="9" r="2" /><path d="m21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21" /></svg>
                    </span>
                    <!-- Product name + quantity -->
                    <span class="text-sm flex-1 transition-all" :class="isPacked(machine.id, item) ? 'line-through text-muted-foreground/50' : ''">
                      <template v-if="isOutOfWarehouseStock(item, machine.id)">
                        <span class="text-muted-foreground">{{ item.deficit }}&times; {{ item.product_name }}</span>
                        <span class="ml-1 text-xs text-red-500 dark:text-red-400">{{ t('machines.notInStock') }}</span>
                      </template>
                      <template v-else-if="hasPartialStock(item, machine.id)">
                        {{ effectiveDeficit(item, machine.id) }}&times; {{ item.product_name }}
                        <span class="ml-1 text-xs text-amber-500 dark:text-amber-400">{{ t('machines.needed', { count: item.deficit }) }}</span>
                      </template>
                      <template v-else>
                        {{ effectiveDeficit(item, machine.id) }}&times; {{ item.product_name }}
                      </template>
                    </span>
                  </li>
                </ul>
              </div>
            </CardContent>
          </Card>
        </div>

        <!-- Start Tour button — fixed bottom bar on mobile -->
        <div class="fixed bottom-14 md:bottom-0 inset-x-0 z-20 border-t bg-background/95 backdrop-blur supports-[backdrop-filter]:bg-background/80 p-3 sm:p-4 md:pb-[max(1rem,env(safe-area-inset-bottom))]">
          <button
            :disabled="!hasAnyPackedItems() || tourStarting"
            class="inline-flex h-12 w-full items-center justify-center gap-2 rounded-xl bg-primary px-6 text-base font-medium text-primary-foreground shadow-lg transition-colors hover:bg-primary/90 disabled:opacity-50"
            @click="startTour"
          >
            <IconTruck v-if="!tourStarting" class="h-5 w-5" />
            <span v-if="tourStarting">{{ t('refill.startingTour') }}</span>
            <span v-else>{{ t('refill.startTour') }}</span>
          </button>
          <p v-if="!hasAnyPackedItems()" class="mt-1.5 text-center text-xs text-muted-foreground">
            {{ t('refill.noItemsPacked') }}
          </p>
          <p v-else class="mt-1.5 text-center text-xs text-muted-foreground">
            {{ t('refill.warehouseDeductionHint') }}
          </p>
        </div>
      </template>
    </template>

    <!-- ══════════════════════════════════════════════════════════════════════ -->
    <!-- STEP 2: REFILL PER MACHINE -->
    <!-- ══════════════════════════════════════════════════════════════════════ -->
    <template v-else-if="currentStep === 'refill' && currentMachine">
      <!-- Progress -->
      <div class="flex items-center justify-between rounded-lg border bg-muted/30 px-3 py-2.5 sm:px-4 sm:py-3">
        <span class="text-sm font-medium">
          {{ t('refill.machineOf', { current: currentMachineNumber, total: machines.length }) }}
        </span>
        <div class="flex items-center gap-2">
          <div class="h-2 w-16 sm:w-24 overflow-hidden rounded-full bg-muted">
            <div
              class="h-full rounded-full bg-primary transition-all"
              :style="{ width: `${Math.round((currentMachineNumber / machines.length) * 100)}%` }"
            />
          </div>
          <span class="text-xs text-muted-foreground tabular-nums">{{ Math.round((currentMachineNumber / machines.length) * 100) }}%</span>
        </div>
      </div>

      <!-- Machine name -->
      <h2 class="text-lg font-semibold px-1">{{ currentMachine.name }}</h2>

      <div v-if="currentTraysLoading" class="text-muted-foreground px-1">{{ t('common.loading') }}</div>

      <div v-else-if="currentTrays.length === 0" class="text-muted-foreground text-sm px-1">
        {{ t('refill.noMachinesNeedRefill') }}
      </div>

      <!-- Tray cards — mobile-friendly card layout instead of table -->
      <div v-else class="flex flex-col gap-2 pb-28 sm:pb-32">
        <div
          v-for="tray in currentTrays"
          :key="tray.id"
          class="rounded-xl border bg-card p-3 sm:p-4"
        >
          <div class="flex items-center justify-between gap-3">
            <!-- Left: image + product -->
            <div class="flex items-center gap-3 min-w-0 flex-1">
              <img
                v-if="tray.image_path"
                :src="getProductImageUrl(tray.image_path)"
                :alt="tray.product_name ?? ''"
                class="h-10 w-10 shrink-0 rounded-lg object-cover"
              />
              <span
                v-else
                class="inline-flex h-10 w-10 shrink-0 items-center justify-center rounded-lg bg-muted font-mono text-xs font-medium"
              >
                {{ tray.item_number }}
              </span>
              <div class="min-w-0 flex-1">
                <p class="text-sm font-medium truncate">{{ tray.product_name ?? `Slot ${tray.item_number}` }}</p>
                <p class="text-xs text-muted-foreground tabular-nums">
                  <span
                    class="inline-flex items-center rounded px-1 py-0.5 text-[11px] font-medium"
                    :class="tray.current_stock === 0
                      ? 'bg-red-100 text-red-700 dark:bg-red-950/40 dark:text-red-400'
                      : 'bg-amber-100 text-amber-700 dark:bg-amber-950/40 dark:text-amber-400'"
                  >{{ tray.current_stock }}</span>
                  <span class="mx-1">/</span>
                  <span>{{ tray.capacity }}</span>
                </p>
              </div>
            </div>

            <!-- Right: fill amount controls — large touch targets -->
            <div class="flex items-center gap-1.5 shrink-0">
              <button
                class="inline-flex h-11 w-11 items-center justify-center rounded-xl border-2 text-lg font-semibold active:bg-muted disabled:opacity-30 transition-colors"
                :disabled="tray.fill_amount <= 0"
                @click="adjustFillAmount(tray.id, -1)"
              >&minus;</button>
              <span class="inline-flex h-11 min-w-14 items-center justify-center rounded-xl bg-primary/10 px-2 text-base font-bold tabular-nums text-primary">
                +{{ tray.fill_amount }}
              </span>
              <button
                class="inline-flex h-11 w-11 items-center justify-center rounded-xl border-2 text-lg font-semibold active:bg-muted disabled:opacity-30 transition-colors"
                :disabled="tray.fill_amount >= (tray.capacity - tray.current_stock)"
                @click="adjustFillAmount(tray.id, 1)"
              >+</button>
            </div>
          </div>
        </div>
      </div>

      <!-- Action buttons — fixed bottom bar -->
      <div class="fixed bottom-14 md:bottom-0 inset-x-0 z-20 border-t bg-background/95 backdrop-blur supports-[backdrop-filter]:bg-background/80 p-3 sm:p-4 md:pb-[max(1rem,env(safe-area-inset-bottom))]">
        <div class="flex flex-col gap-2 max-w-3xl mx-auto">
          <button
            :disabled="confirmingRefill"
            class="inline-flex h-12 w-full items-center justify-center gap-2 rounded-xl bg-primary px-6 text-base font-medium text-primary-foreground shadow-lg transition-colors hover:bg-primary/90 disabled:opacity-50"
            @click="confirmMachineRefill"
          >
            <IconCheck v-if="!confirmingRefill" class="h-5 w-5" />
            <span v-if="confirmingRefill">{{ t('refill.confirming') }}</span>
            <span v-else-if="isLastMachine">{{ t('refill.confirmAndFinish') }}</span>
            <span v-else>{{ t('refill.confirmAndNext') }}</span>
          </button>
          <button
            :disabled="confirmingRefill"
            class="inline-flex h-10 w-full items-center justify-center gap-2 rounded-xl border px-4 text-sm font-medium text-muted-foreground transition-colors hover:bg-muted disabled:opacity-50"
            @click="skipMachine"
          >
            <IconPlayerSkipForward class="h-4 w-4" />
            {{ t('refill.skipMachine') }}
          </button>
        </div>
      </div>
    </template>

    <!-- ══════════════════════════════════════════════════════════════════════ -->
    <!-- STEP 3: SUMMARY -->
    <!-- ══════════════════════════════════════════════════════════════════════ -->
    <template v-else-if="currentStep === 'summary'">
      <!-- Totals -->
      <div class="grid grid-cols-2 gap-2 sm:gap-4 sm:grid-cols-4">
        <div class="rounded-xl border p-3 text-center">
          <p class="text-2xl font-bold tabular-nums">{{ tourSummary.machinesRefilled }}</p>
          <p class="text-[11px] sm:text-xs text-muted-foreground">{{ t('refill.machinesRefilled', tourSummary.machinesRefilled) }}</p>
        </div>
        <div v-if="tourSummary.machinesSkipped > 0" class="rounded-xl border p-3 text-center">
          <p class="text-2xl font-bold tabular-nums text-amber-500">{{ tourSummary.machinesSkipped }}</p>
          <p class="text-[11px] sm:text-xs text-muted-foreground">{{ t('refill.machinesSkipped', { count: tourSummary.machinesSkipped }) }}</p>
        </div>
        <div class="rounded-xl border p-3 text-center">
          <p class="text-2xl font-bold tabular-nums">{{ tourSummary.totalTraysRefilled }}</p>
          <p class="text-[11px] sm:text-xs text-muted-foreground">{{ t('refill.traysRefilled', tourSummary.totalTraysRefilled) }}</p>
        </div>
        <div class="rounded-xl border p-3 text-center">
          <p class="text-2xl font-bold tabular-nums">{{ tourSummary.totalItemsAdded }}</p>
          <p class="text-[11px] sm:text-xs text-muted-foreground">{{ t('refill.itemsAdded', tourSummary.totalItemsAdded) }}</p>
        </div>
      </div>

      <Separator />

      <!-- Per-machine log -->
      <div class="flex flex-col gap-2 pb-20 sm:pb-24">
        <div
          v-for="entry in tourLog"
          :key="entry.machine_id"
          class="flex items-center justify-between rounded-xl border px-4 py-3"
        >
          <div class="min-w-0 flex-1">
            <p class="text-sm font-medium truncate">{{ entry.machine_name }}</p>
            <p v-if="!entry.skipped" class="text-xs text-muted-foreground">
              {{ entry.trays_refilled }} {{ entry.trays_refilled === 1 ? 'tray' : 'trays' }} &middot;
              +{{ entry.total_added }} {{ entry.total_added === 1 ? 'item' : 'items' }}
            </p>
          </div>
          <span
            v-if="entry.skipped"
            class="ml-2 shrink-0 inline-flex items-center rounded-full bg-amber-100 px-2.5 py-0.5 text-xs font-medium text-amber-700 dark:bg-amber-950/40 dark:text-amber-400"
          >
            {{ t('refill.skipped') }}
          </span>
          <IconCheck v-else class="ml-2 h-5 w-5 shrink-0 text-green-600" />
        </div>
      </div>

      <!-- Back button — fixed bottom bar -->
      <div class="fixed bottom-14 md:bottom-0 inset-x-0 z-20 border-t bg-background/95 backdrop-blur supports-[backdrop-filter]:bg-background/80 p-3 sm:p-4 md:pb-[max(1rem,env(safe-area-inset-bottom))]">
        <button
          class="inline-flex h-12 w-full max-w-3xl mx-auto items-center justify-center gap-2 rounded-xl bg-primary px-6 text-base font-medium text-primary-foreground shadow-lg transition-colors hover:bg-primary/90"
          @click="router.push('/machines')"
        >
          {{ t('refill.backToMachines') }}
        </button>
      </div>
    </template>
  </div>
</template>
