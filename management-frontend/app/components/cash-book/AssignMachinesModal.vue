<script setup lang="ts">
import type { CashBook, VendingMachineBasic } from '@/composables/useCashBook'

const props = defineProps<{
  open: boolean
  loading: boolean
  allMachines: VendingMachineBasic[]
  selectedCashBookId: string
  cashBooks: CashBook[]
}>()

const emit = defineEmits<{
  (e: 'update:open', value: boolean): void
  (e: 'toggle', payload: { machineId: string; currentCashBookId: string | null }): void
}>()

const { t } = useI18n()

function getCashBookName(cashBookId: string | null): string | null {
  if (!cashBookId) return null
  return props.cashBooks.find(c => c.id === cashBookId)?.name ?? null
}
</script>

<template>
  <AppModal
    :open="open"
    :title="t('cashBook.machineAssignment')"
    size="sm"
    @update:open="(v: boolean) => emit('update:open', v)"
  >
    <div v-if="loading" class="py-8 text-center text-muted-foreground">
      {{ t('common.loading') }}
    </div>
    <div v-else class="space-y-2 max-h-80 overflow-y-auto">
      <div
        v-for="machine in allMachines"
        :key="machine.id"
        class="flex items-center gap-3 rounded-md px-3 py-2 hover:bg-muted/50"
      >
        <input
          type="checkbox"
          :checked="machine.cash_book_id === selectedCashBookId"
          :disabled="machine.cash_book_id != null && machine.cash_book_id !== selectedCashBookId"
          class="size-4 rounded border-input"
          @change="emit('toggle', { machineId: machine.id, currentCashBookId: machine.cash_book_id })"
        />
        <div class="flex-1 min-w-0">
          <div class="text-sm font-medium truncate">{{ machine.name || machine.id.slice(0, 8) }}</div>
          <div
            v-if="machine.cash_book_id && machine.cash_book_id !== selectedCashBookId"
            class="text-xs text-muted-foreground"
          >
            {{ t('cashBook.assignedTo', { name: getCashBookName(machine.cash_book_id) }) }}
          </div>
        </div>
      </div>
      <div v-if="allMachines.length === 0" class="py-4 text-center text-sm text-muted-foreground">
        {{ t('cashBook.noMachinesAssigned') }}
      </div>
    </div>
  </AppModal>
</template>
