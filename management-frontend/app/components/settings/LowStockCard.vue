<script setup lang="ts">
import { IconBellRinging, IconLoader2 } from '@tabler/icons-vue'
import { CURATED_TIMEZONES, detectBrowserTimezone } from '~/lib/timezones'

const { t } = useI18n()
const supabase = useSupabaseClient()
const { organization, role } = useOrganization()

const timezone = ref<string>(detectBrowserTimezone())
const hour = ref<number | null>(null)
const loading = ref(false)
const error = ref('')
const success = ref('')

/** Merged dropdown list: curated zones + browser-detected zone if not in list. */
const timezoneOptions = computed(() => {
  const browserTz = detectBrowserTimezone()
  const known = new Set(CURATED_TIMEZONES.map(z => z.id))
  if (!known.has(browserTz)) {
    return [{ id: browserTz, label: `${browserTz} (detected)` }, ...CURATED_TIMEZONES]
  }
  return CURATED_TIMEZONES
})

const hourOptions = computed(() => {
  return Array.from({ length: 24 }, (_, i) => ({
    value: i,
    label: `${i.toString().padStart(2, '0')}:00`,
  }))
})

async function load() {
  if (!organization.value?.id) return
  loading.value = true
  error.value = ''
  try {
    const { data, error: fetchErr } = await supabase
      .from('companies')
      .select('timezone, low_stock_notification_hour')
      .eq('id', organization.value.id)
      .single()
    if (fetchErr) throw fetchErr
    const row = data as any
    if (row?.timezone) timezone.value = row.timezone
    hour.value = typeof row?.low_stock_notification_hour === 'number'
      ? row.low_stock_notification_hour
      : null
  } catch (err: unknown) {
    error.value = err instanceof Error ? err.message : t('settings.lowStockLoadError')
  } finally {
    loading.value = false
  }
}

async function save() {
  if (!organization.value?.id) return
  loading.value = true
  error.value = ''
  success.value = ''
  try {
    const { error: updateErr } = await supabase
      .from('companies')
      .update({
        timezone: timezone.value,
        low_stock_notification_hour: hour.value,
      })
      .eq('id', organization.value.id)
    if (updateErr) throw updateErr
    success.value = t('settings.lowStockSaved')
  } catch (err: unknown) {
    error.value = err instanceof Error ? err.message : t('settings.lowStockSaveError')
  } finally {
    loading.value = false
  }
}

watch(() => organization.value?.id, (id) => {
  if (import.meta.client && id && role.value === 'admin') load()
}, { immediate: true })
</script>

<template>
  <div class="rounded-xl border bg-card p-6 shadow-sm">
    <div class="mb-5 flex items-center gap-2">
      <IconBellRinging class="size-5 text-primary" />
      <div>
        <h2 class="text-lg font-semibold">{{ t('settings.lowStockTitle') }}</h2>
        <p class="text-sm text-muted-foreground">{{ t('settings.lowStockDescription') }}</p>
      </div>
    </div>

    <form class="space-y-4" @submit.prevent="save">
      <div class="space-y-1">
        <label for="ls-timezone" class="text-sm font-medium">{{ t('settings.lowStockTimezone') }}</label>
        <select
          id="ls-timezone"
          v-model="timezone"
          class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        >
          <option v-for="tz in timezoneOptions" :key="tz.id" :value="tz.id">{{ tz.label }}</option>
        </select>
      </div>

      <div class="space-y-1">
        <label for="ls-hour" class="text-sm font-medium">{{ t('settings.lowStockSendTime') }}</label>
        <select
          id="ls-hour"
          v-model="hour"
          class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        >
          <option :value="null">{{ t('settings.lowStockDisabledOption') }}</option>
          <option v-for="opt in hourOptions" :key="opt.value" :value="opt.value">{{ opt.label }}</option>
        </select>
      </div>

      <p v-if="error" class="text-sm text-destructive">{{ error }}</p>
      <p v-if="success" class="text-sm text-green-600">{{ success }}</p>

      <button
        type="submit"
        :disabled="loading"
        class="inline-flex h-9 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90 disabled:opacity-50"
      >
        <IconLoader2 v-if="loading" class="mr-2 size-4 animate-spin" />
        <span v-if="loading">{{ t('settings.lowStockSaving') }}</span>
        <span v-else>{{ t('settings.lowStockSave') }}</span>
      </button>
    </form>
  </div>
</template>
