<script setup lang="ts">
definePageMeta({ middleware: 'auth' })

import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { IconTruck, IconPlayerPlay } from '@tabler/icons-vue'
import { formatCurrency } from '@/lib/utils'
import { getProductImageUrl } from '@/composables/useProducts'
import { hasSavedTour, clearSavedTourState } from '@/composables/useRefillWizard'

const { t } = useI18n()
const { organization } = useOrganization()
const {
  machines, loading, fetchMachines, subscribeToStatusUpdates, createMachine,
} = useMachines()
const { onResume } = useAppResume()
const savedTourAvailable = ref(false)

onMounted(() => { savedTourAvailable.value = hasSavedTour() })

function startNewTour() {
  clearSavedTourState()
  savedTourAvailable.value = false
  navigateTo('/refill')
}

// Re-fetch all machine data when app resumes from background (iOS PWA etc.)
onResume(() => fetchMachines())
usePullToRefresh(() => fetchMachines())

onMounted(async () => {
  await fetchMachines()
  const unsubscribe = subscribeToStatusUpdates()
  onUnmounted(unsubscribe)
})

// ── Add Machine modal ────────────────────────────────────────────────────────
const { open: showMachineModal, form: machineForm, loading: creatingMachine, error: machineError, openModal: openMachineModal, closeModal, submit } = useModalForm({ name: '' })

async function submitCreateMachine() {
  if (!machineForm.value.name.trim()) {
    machineError.value = t('machines.nameRequired')
    return
  }
  await submit(() => createMachine(machineForm.value.name.trim(), organization.value!.id))
}
</script>

<template>
  <div class="flex flex-1 flex-col gap-4 p-4 md:p-6">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <h1 class="text-2xl font-semibold">{{ t('machines.title') }}</h1>
          <div class="flex flex-wrap items-center gap-2">
            <NuxtLink
              v-if="savedTourAvailable"
              to="/refill"
              class="inline-flex h-9 items-center justify-center gap-2 rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90"
            >
              <IconPlayerPlay class="h-4 w-4" />
              {{ t('refill.resumeTour') }}
            </NuxtLink>
            <button
              v-if="machines.some(m => (m.stock_health ?? 'ok') !== 'ok')"
              class="inline-flex h-9 items-center justify-center gap-2 rounded-md border border-primary bg-primary/10 px-4 text-sm font-medium text-primary shadow-sm transition-colors hover:bg-primary/20"
              @click="startNewTour"
            >
              <IconTruck class="h-4 w-4" />
              {{ t('machines.startRefillTour') }}
            </button>
            <button
              class="inline-flex h-9 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90"
              @click="openMachineModal"
            >
              {{ t('machines.addMachine') }}
            </button>
          </div>
        </div>

        <div v-if="loading" class="text-muted-foreground">{{ t('machines.loadingMachines') }}</div>

        <div v-else-if="machines.length === 0" class="text-muted-foreground">
          {{ t('machines.noMachinesYet') }}
        </div>

        <div v-else class="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3">
          <NuxtLink
            v-for="machine in machines"
            :key="machine.id"
            :to="`/machines/${machine.id}`"
            class="block rounded-xl transition-shadow hover:shadow-md"
          >
            <Card class="h-full">
              <CardHeader class="flex flex-row items-center justify-between space-y-0 pb-2">
                <CardTitle class="text-base font-semibold truncate">
                  {{ machine.name ?? t('machines.unnamedMachine') }}
                </CardTitle>
                <!-- Stock health dot -->
                <span
                  class="ml-2 inline-block h-3 w-3 shrink-0 rounded-full"
                  :class="{
                    'bg-red-500': (machine.stock_health ?? 'ok') === 'critical',
                    'bg-amber-500': (machine.stock_health ?? 'ok') === 'low',
                    'bg-green-500': (machine.stock_health ?? 'ok') === 'ok',
                  }"
                />
              </CardHeader>

              <CardContent class="space-y-3">
                <!-- Sales analytics -->
                <div class="grid grid-cols-2 gap-x-4 gap-y-1 text-xs">
                  <div class="flex justify-between">
                    <span class="text-muted-foreground">{{ t('common.today') }}</span>
                    <span class="font-medium tabular-nums">{{ formatCurrency(machine.today_revenue ?? 0) }} <span class="text-muted-foreground font-normal">({{ machine.today_sales_count ?? 0 }})</span></span>
                  </div>
                  <div class="flex justify-between">
                    <span class="text-muted-foreground">{{ t('common.thisMonth') }}</span>
                    <span class="font-medium tabular-nums">{{ formatCurrency(machine.this_month_revenue ?? 0) }} <span class="text-muted-foreground font-normal">({{ machine.this_month_sales_count ?? 0 }})</span></span>
                  </div>
                  <div class="flex justify-between">
                    <span class="text-muted-foreground">{{ t('common.yesterday') }}</span>
                    <span class="font-medium tabular-nums">{{ formatCurrency(machine.yesterday_revenue ?? 0) }} <span class="text-muted-foreground font-normal">({{ machine.yesterday_sales_count ?? 0 }})</span></span>
                  </div>
                  <div class="flex justify-between">
                    <span class="text-muted-foreground">{{ t('common.lastMonth') }}</span>
                    <span class="font-medium tabular-nums">{{ formatCurrency(machine.last_month_revenue ?? 0) }} <span class="text-muted-foreground font-normal">({{ machine.last_month_sales_count ?? 0 }})</span></span>
                  </div>
                </div>

                <!-- Healthy machine with no stock issues at all -->
                <template v-if="(machine.stock_health ?? 'ok') === 'ok' && (machine.no_stock_trays ?? 0) === 0">
                  <p class="text-sm text-muted-foreground">
                    <template v-if="(machine.total_trays ?? 0) > 0">
                      {{ t('machines.allStocked', { count: machine.total_trays }) }}
                    </template>
                    <template v-else>
                      {{ t('machines.noTraysConfigured') }}
                    </template>
                  </p>
                </template>

                <!-- Machine has stock issues (refillable and/or no-stock) -->
                <template v-else>
                  <!-- "All stocked" context when only no-stock issues remain -->
                  <p v-if="(machine.stock_health ?? 'ok') === 'ok'" class="text-sm text-muted-foreground">
                    {{ t('machines.allStocked', { count: machine.total_trays }) }}
                  </p>

                  <!-- Badges row -->
                  <div class="flex flex-wrap items-center gap-1.5">
                    <span
                      v-if="(machine.low_trays ?? 0) > 0"
                      class="inline-flex items-center gap-1 rounded-md bg-red-500/10 px-2 py-0.5 text-xs font-semibold text-red-500"
                    >
                      {{ t('machines.refillNeeded', { count: machine.low_trays }) }}
                    </span>
                    <span
                      v-if="(machine.no_stock_trays ?? 0) > 0"
                      class="inline-flex items-center rounded-md bg-muted px-2 py-0.5 text-xs text-muted-foreground"
                    >
                      {{ t('machines.noWarehouseStock', { count: machine.no_stock_trays }) }}
                    </span>
                  </div>

                  <!-- Product list -->
                  <div v-if="(machine.tray_summary?.length ?? 0) > 0 || (machine.no_stock_summary?.length ?? 0) > 0" class="space-y-0.5 text-xs">
                    <!-- Refillable products -->
                    <div
                      v-for="item in machine.tray_summary"
                      :key="'refill-' + item.product_id"
                      class="flex items-center justify-between gap-2"
                    >
                      <div class="flex items-center gap-1.5 min-w-0">
                        <img v-if="item.image_path" :src="getProductImageUrl(item.image_path)" class="size-5 shrink-0 rounded object-cover" alt="" />
                        <span class="truncate" :class="item.deficit >= (machine.tray_summary?.[0]?.deficit ?? 0) ? 'text-red-500' : 'text-amber-500'">
                          {{ item.product_name }} <span class="text-muted-foreground">(-{{ item.deficit }})</span>
                        </span>
                      </div>
                      <span class="shrink-0 text-green-500 text-[10px]">{{ t('machines.inStock') }}</span>
                    </div>
                    <!-- No-stock products (dimmed, sorted to bottom) -->
                    <div
                      v-for="item in machine.no_stock_summary"
                      :key="'nostock-' + item.product_id"
                      class="flex items-center justify-between gap-2 opacity-50"
                    >
                      <div class="flex items-center gap-1.5 min-w-0">
                        <img v-if="item.image_path" :src="getProductImageUrl(item.image_path)" class="size-5 shrink-0 rounded object-cover" alt="" />
                        <span class="truncate">
                          {{ item.product_name }} <span class="text-muted-foreground">(-{{ item.deficit }})</span>
                        </span>
                      </div>
                      <span class="shrink-0 text-muted-foreground text-[10px]">{{ t('machines.noStock') }}</span>
                    </div>
                  </div>

                  <!-- Stock bar (only when there are refillable issues) -->
                  <div v-if="(machine.stock_health ?? 'ok') !== 'ok'" class="flex items-center gap-2">
                    <div class="h-2 flex-1 overflow-hidden rounded-full bg-muted">
                      <div
                        class="h-full rounded-full transition-all"
                        :class="{
                          'bg-red-500': (machine.stock_percent ?? 0) < 20,
                          'bg-amber-500': (machine.stock_percent ?? 0) >= 20 && (machine.stock_percent ?? 0) < 50,
                          'bg-green-500': (machine.stock_percent ?? 0) >= 50,
                        }"
                        :style="{ width: `${machine.stock_percent ?? 0}%` }"
                      />
                    </div>
                    <span class="text-xs font-medium text-muted-foreground w-8 text-right">{{ machine.stock_percent ?? 0 }}%</span>
                  </div>
                </template>
              </CardContent>
            </Card>
          </NuxtLink>
        </div>
  </div>

  <!-- Add Machine Modal -->
  <AppModal
    v-model:open="showMachineModal"
    :title="t('machines.addMachine')"
    :description="t('machines.addMachineDescription')"
  >
    <div class="mb-4">
      <label for="machine-name" class="mb-1.5 block text-sm font-medium">{{ t('machines.machineName') }}</label>
      <input
        id="machine-name"
        v-model="machineForm.name"
        type="text"
        :placeholder="t('machines.machineNamePlaceholder')"
        class="flex h-9 w-full rounded-md border bg-transparent px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        @keydown.enter="submitCreateMachine"
      />
    </div>
    <FormError :message="machineError" />
    <template #footer>
      <button
        class="inline-flex h-9 flex-1 items-center justify-center rounded-md border px-4 text-sm font-medium hover:bg-muted"
        @click="closeModal"
      >
        {{ t('common.cancel') }}
      </button>
      <button
        :disabled="creatingMachine"
        class="inline-flex h-9 flex-1 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow hover:bg-primary/90 disabled:opacity-50"
        @click="submitCreateMachine"
      >
        <span v-if="creatingMachine">{{ t('common.creating') }}</span>
        <span v-else>{{ t('common.create') }}</span>
      </button>
    </template>
  </AppModal>

</template>
