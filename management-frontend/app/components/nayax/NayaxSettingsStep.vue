<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { formatInTimeZone, fromZonedTime } from 'date-fns-tz'

defineProps<{ isAdmin: boolean }>()
const emit = defineEmits<{ run: []; back: [] }>()
const { t } = useI18n()
const recon = useNayaxReconciliation()

const fromInput = ref('')
const toInput = ref('')

onMounted(() => {
  if (recon.settings.value.fromUtc) fromInput.value = toLocalInput(recon.settings.value.fromUtc)
  if (recon.settings.value.toUtc) toInput.value = toLocalInput(recon.settings.value.toUtc)
})

// Both directions of the datetime-local conversion respect the file's
// chosen timezone (recon.settings.value.timezone), NOT the browser's
// timezone. Otherwise a user on an en-US browser reviewing a Berlin
// file would see the date inputs shifted by 6 hours and any manual
// adjustment would shift the query window by the browser offset.
function toLocalInput(iso: string): string {
  return formatInTimeZone(iso, recon.settings.value.timezone, "yyyy-MM-dd'T'HH:mm")
}

function fromLocalInput(local: string): string {
  return fromZonedTime(local, recon.settings.value.timezone).toISOString()
}

function submit() {
  recon.settings.value.fromUtc = fromLocalInput(fromInput.value)
  recon.settings.value.toUtc = fromLocalInput(toInput.value)
  emit('run')
}
</script>

<template>
  <div class="rounded-xl border bg-card p-6 shadow-sm">
    <h2 class="text-lg font-semibold mb-4">{{ t('nayax.reconcile.settings.title') }}</h2>

    <div class="grid gap-4 sm:grid-cols-2">
      <div class="space-y-1">
        <label class="text-sm font-medium">{{ t('nayax.reconcile.settings.from') }}</label>
        <input v-model="fromInput" type="datetime-local" class="flex h-9 w-full rounded-md border bg-background px-3 text-sm" />
      </div>
      <div class="space-y-1">
        <label class="text-sm font-medium">{{ t('nayax.reconcile.settings.to') }}</label>
        <input v-model="toInput" type="datetime-local" class="flex h-9 w-full rounded-md border bg-background px-3 text-sm" />
      </div>
      <div class="space-y-1">
        <label class="text-sm font-medium">{{ t('nayax.reconcile.settings.tz') }}</label>
        <select v-model="recon.settings.value.timezone" class="flex h-9 w-full rounded-md border bg-background px-3 text-sm">
          <option value="Europe/Berlin">Europe/Berlin</option>
          <option value="Europe/Vienna">Europe/Vienna</option>
          <option value="Europe/Zurich">Europe/Zurich</option>
          <option value="UTC">UTC</option>
        </select>
        <p class="text-[10px] text-muted-foreground">{{ t('nayax.reconcile.settings.tzHint') }}</p>
      </div>
    </div>

    <div class="mt-6 flex justify-end gap-2">
      <button class="inline-flex h-9 items-center rounded-md border px-4 text-sm hover:bg-muted" @click="emit('back')">
        {{ t('common.back') }}
      </button>
      <button class="inline-flex h-9 items-center rounded-md bg-primary px-6 text-sm font-medium text-primary-foreground shadow hover:bg-primary/90" @click="submit">
        {{ t('nayax.reconcile.settings.runCta') }}
      </button>
    </div>
  </div>
</template>
