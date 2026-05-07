<script setup lang="ts">
const props = defineProps<{
  open: boolean
  initialThreshold: number
}>()

const emit = defineEmits<{
  (e: 'update:open', value: boolean): void
  (e: 'submit', threshold: number): void
}>()

const { t } = useI18n()

const threshold = ref(props.initialThreshold)
const loading = ref(false)

watch(() => props.open, (now) => {
  if (now) threshold.value = props.initialThreshold
})

async function onSubmit() {
  if (threshold.value < 1) return
  loading.value = true
  try {
    emit('submit', threshold.value)
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
