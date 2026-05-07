<script setup lang="ts">
const props = defineProps<{
  open: boolean
  cashBookName: string
  entryCount: number
  loading: boolean
}>()

const emit = defineEmits<{
  (e: 'update:open', value: boolean): void
  (e: 'confirm'): void
}>()

const { t } = useI18n()

const step = ref<1 | 2>(1)
const confirmName = ref('')

watch(() => props.open, (now) => {
  if (now) {
    step.value = 1
    confirmName.value = ''
  }
})
</script>

<template>
  <AppModal
    :open="open"
    :title="t('cashBook.deleteCashBook')"
    size="sm"
    @update:open="(v: boolean) => emit('update:open', v)"
  >
    <div class="space-y-4">
      <template v-if="step === 1">
        <div class="rounded-lg border border-red-200 bg-red-50 p-4 dark:border-red-800 dark:bg-red-900/20">
          <p class="text-sm font-medium text-red-700 dark:text-red-400">
            {{ t('cashBook.deleteWarning') }}
          </p>
          <ul class="mt-2 list-disc pl-5 text-sm text-red-600 dark:text-red-400 space-y-1">
            <li>{{ t('cashBook.deleteWarningEntries', { count: entryCount }) }}</li>
            <li>{{ t('cashBook.deleteWarningMachines') }}</li>
            <li>{{ t('cashBook.deleteWarningIrreversible') }}</li>
          </ul>
        </div>
        <div class="flex justify-end gap-2">
          <button class="h-9 rounded-md border border-input px-4 text-sm font-medium hover:bg-accent" @click="emit('update:open', false)">
            {{ t('common.cancel') }}
          </button>
          <button
            class="h-9 rounded-md bg-red-600 px-4 text-sm font-medium text-white hover:bg-red-700"
            @click="step = 2"
          >
            {{ t('cashBook.deleteConfirmStep1') }}
          </button>
        </div>
      </template>

      <template v-if="step === 2">
        <p class="text-sm">
          {{ t('cashBook.deleteTypeName', { name: cashBookName }) }}
        </p>
        <input
          v-model="confirmName"
          type="text"
          :placeholder="cashBookName"
          class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
        <div class="flex justify-end gap-2">
          <button class="h-9 rounded-md border border-input px-4 text-sm font-medium hover:bg-accent" @click="emit('update:open', false)">
            {{ t('common.cancel') }}
          </button>
          <button
            :disabled="loading || confirmName !== cashBookName"
            class="h-9 rounded-md bg-red-600 px-4 text-sm font-medium text-white hover:bg-red-700 disabled:opacity-50"
            @click="emit('confirm')"
          >
            {{ loading ? t('common.loading') : t('cashBook.deleteConfirmFinal') }}
          </button>
        </div>
      </template>
    </div>
  </AppModal>
</template>
