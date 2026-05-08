<script setup lang="ts">
const props = defineProps<{
  open: boolean
  initialThreshold: number
  initialTrackPerMachine: boolean
}>()

const emit = defineEmits<{
  (e: 'update:open', value: boolean): void
  (e: 'submit', payload: { threshold: number; trackPerMachine: boolean }): void
}>()

const { t } = useI18n()

const threshold = ref(props.initialThreshold)
const trackPerMachine = ref(props.initialTrackPerMachine)
const loading = ref(false)

watch(() => props.open, (now) => {
  if (now) {
    threshold.value = props.initialThreshold
    trackPerMachine.value = props.initialTrackPerMachine
  }
})

async function onSubmit() {
  if (threshold.value < 1) return
  loading.value = true
  try {
    emit('submit', { threshold: threshold.value, trackPerMachine: trackPerMachine.value })
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <AppModal
    :open="open"
    :title="t('cashBook.barkasseSettings')"
    size="sm"
    @update:open="(v: boolean) => emit('update:open', v)"
  >
    <form class="space-y-4" @submit.prevent="onSubmit">
      <div>
        <label class="text-sm font-medium">{{ t('cashBook.bankDepositThreshold') }} (EUR)</label>
        <input
          v-model.number="threshold"
          type="number" step="1" min="1" required
          class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
        <p class="mt-1 text-xs text-muted-foreground">{{ t('cashBook.thresholdHint') }}</p>
        <p class="mt-1 text-xs text-muted-foreground">{{ t('cashBook.thresholdMinimumHint') }}</p>
      </div>

      <label class="flex items-start gap-2 cursor-pointer">
        <input
          v-model="trackPerMachine"
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
          :disabled="loading || threshold < 1"
          class="h-9 rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-50"
        >
          {{ loading ? t('common.loading') : t('common.save') }}
        </button>
      </div>
    </form>
  </AppModal>
</template>
