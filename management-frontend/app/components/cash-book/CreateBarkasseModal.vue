<script setup lang="ts">
const props = defineProps<{
  open: boolean
}>()

const emit = defineEmits<{
  (e: 'update:open', value: boolean): void
  (e: 'submit', payload: { name: string; initialBalance: number; threshold: number; trackPerMachine: boolean }): void
}>()

const { t } = useI18n()

const form = ref({ name: '', initial_balance: 0, threshold: 500, track_per_machine: false })
const loading = ref(false)

watch(() => props.open, (now) => {
  if (now) form.value = { name: '', initial_balance: 0, threshold: 500, track_per_machine: false }
})

async function onSubmit() {
  if (!form.value.name.trim() || form.value.threshold < 1) return
  loading.value = true
  try {
    emit('submit', {
      name: form.value.name.trim(),
      initialBalance: form.value.initial_balance,
      threshold: form.value.threshold,
      trackPerMachine: form.value.track_per_machine,
    })
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <AppModal
    :open="open"
    :title="t('cashBook.createCashBook')"
    size="sm"
    @update:open="(v: boolean) => emit('update:open', v)"
  >
    <form class="space-y-4" @submit.prevent="onSubmit">
      <div>
        <label class="text-sm font-medium">{{ t('cashBook.name') }}</label>
        <input
          v-model="form.name"
          type="text" required
          :placeholder="t('cashBook.name')"
          class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
      </div>
      <div>
        <label class="text-sm font-medium">{{ t('cashBook.initialBalance') }} (EUR)</label>
        <input
          v-model.number="form.initial_balance"
          type="number" step="0.01" min="0"
          class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
      </div>
      <div>
        <label class="text-sm font-medium">{{ t('cashBook.bankDepositThreshold') }} (EUR)</label>
        <input
          v-model.number="form.threshold"
          type="number" step="1" min="1"
          class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
        <p class="mt-1 text-xs text-muted-foreground">{{ t('cashBook.thresholdHint') }}</p>
      </div>

      <label class="flex items-start gap-2 cursor-pointer">
        <input
          v-model="form.track_per_machine"
          type="checkbox"
          class="mt-0.5 size-4 rounded border-input"
        />
        <span class="flex-1">
          <span class="text-sm font-medium">{{ t('cashBook.trackPerMachine') }}</span>
          <span class="block text-xs text-muted-foreground mt-0.5">{{ t('cashBook.trackPerMachineHint') }}</span>
        </span>
      </label>

      <div class="flex justify-end gap-2">
        <button
          type="button"
          class="h-9 rounded-md border border-input px-4 text-sm font-medium hover:bg-accent"
          @click="emit('update:open', false)"
        >
          {{ t('common.cancel') }}
        </button>
        <button
          type="submit"
          :disabled="loading"
          class="h-9 rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-50"
        >
          {{ loading ? t('common.loading') : t('cashBook.createCashBook') }}
        </button>
      </div>
    </form>
  </AppModal>
</template>
