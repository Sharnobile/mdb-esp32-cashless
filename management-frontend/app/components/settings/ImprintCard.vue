<script setup lang="ts">
import { IconBuildingStore } from '@tabler/icons-vue'
import { CURATED_TIMEZONES, detectBrowserTimezone } from '~/lib/timezones'

const { t } = useI18n()
const supabase = useSupabaseClient()
const { organization, role } = useOrganization()

// Company-wide IANA timezone. Operator-level setting consumed by the daily
// low-stock push AND the daily deal refresh, so it lives here on the operator
// card rather than on any single feature card.
const timezone = ref<string>(detectBrowserTimezone())

/** Curated zones + browser-detected zone if not already in the list. */
const timezoneOptions = computed(() => {
  const browserTz = detectBrowserTimezone()
  const known = new Set(CURATED_TIMEZONES.map(z => z.id))
  if (!known.has(browserTz)) {
    return [{ id: browserTz, label: `${browserTz} (detected)` }, ...CURATED_TIMEZONES]
  }
  return CURATED_TIMEZONES
})

// ── Company imprint / Betreiberinformationen (admin only) ─────────────────
// Shown read-only on the public /m/[machine_id] storefront for customers;
// legally required for German operators (§5 TMG Impressumspflicht).
interface ImprintForm {
  legal_name: string
  contact_email: string
  contact_phone: string
  website: string
  address_street: string
  address_house_number: string
  address_postal_code: string
  address_city: string
}

const imprintForm = reactive<ImprintForm>({
  legal_name: '',
  contact_email: '',
  contact_phone: '',
  website: '',
  address_street: '',
  address_house_number: '',
  address_postal_code: '',
  address_city: '',
})
const imprintLoading = ref(false)
const imprintError = ref('')
const imprintSuccess = ref('')

async function loadImprint() {
  if (!organization.value?.id) return
  const { data } = await supabase
    .from('companies')
    .select('legal_name, contact_email, contact_phone, website, address_street, address_house_number, address_postal_code, address_city, timezone')
    .eq('id', organization.value.id)
    .single()
  const d = data as (Partial<ImprintForm> & { timezone?: string }) | null
  if (!d) return
  imprintForm.legal_name           = d.legal_name           ?? ''
  imprintForm.contact_email        = d.contact_email        ?? ''
  imprintForm.contact_phone        = d.contact_phone        ?? ''
  imprintForm.website              = d.website              ?? ''
  imprintForm.address_street       = d.address_street       ?? ''
  imprintForm.address_house_number = d.address_house_number ?? ''
  imprintForm.address_postal_code  = d.address_postal_code  ?? ''
  imprintForm.address_city         = d.address_city         ?? ''
  if (d.timezone) timezone.value = d.timezone
}

async function saveImprint() {
  imprintError.value = ''
  imprintSuccess.value = ''
  if (!organization.value?.id) return

  // Normalize: empty strings → null so the public storefront can cleanly
  // check "is any imprint field set" without dealing with blank whitespace.
  const norm = (v: string) => {
    const t = v.trim()
    return t.length > 0 ? t : null
  }

  imprintLoading.value = true
  try {
    const { error } = await supabase
      .from('companies')
      .update({
        legal_name:           norm(imprintForm.legal_name),
        contact_email:        norm(imprintForm.contact_email),
        contact_phone:        norm(imprintForm.contact_phone),
        website:              norm(imprintForm.website),
        address_street:       norm(imprintForm.address_street),
        address_house_number: norm(imprintForm.address_house_number),
        address_postal_code:  norm(imprintForm.address_postal_code),
        address_city:         norm(imprintForm.address_city),
        timezone:             timezone.value,
      })
      .eq('id', organization.value.id)
    if (error) throw error
    imprintSuccess.value = t('settings.imprintSaved')
  } catch (err: unknown) {
    imprintError.value = err instanceof Error ? err.message : 'Failed to save imprint'
  } finally {
    imprintLoading.value = false
  }
}

// Own watcher: only load this card's data
watch(() => organization.value?.id, (id) => {
  if (import.meta.client && id && role.value === 'admin') loadImprint()
}, { immediate: true })
</script>

<template>
  <!-- Company Imprint / Betreiberinformationen (admin only) -->
  <!-- Shown read-only on the public storefront for end-customers. -->
  <div class="rounded-xl border bg-card p-6 shadow-sm">
    <div class="mb-5 flex items-center gap-2">
      <IconBuildingStore class="size-5 text-primary" />
      <div>
        <h2 class="text-lg font-semibold">{{ t('settings.imprintSection') }}</h2>
        <p class="text-sm text-muted-foreground">{{ t('settings.imprintDescription') }}</p>
      </div>
    </div>

    <form class="grid grid-cols-1 gap-4 sm:grid-cols-2" @submit.prevent="saveImprint">
      <div class="space-y-1 sm:col-span-2">
        <label class="text-sm font-medium" for="imprint-legal-name">{{ t('settings.imprintLegalName') }}</label>
        <input
          id="imprint-legal-name"
          v-model="imprintForm.legal_name"
          type="text"
          :placeholder="t('settings.imprintLegalNamePlaceholder')"
          class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
      </div>

      <div class="space-y-1">
        <label class="text-sm font-medium" for="imprint-email">{{ t('settings.imprintEmail') }}</label>
        <input
          id="imprint-email"
          v-model="imprintForm.contact_email"
          type="email"
          placeholder="support@acme.com"
          class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
      </div>

      <div class="space-y-1">
        <label class="text-sm font-medium" for="imprint-phone">{{ t('settings.imprintPhone') }}</label>
        <input
          id="imprint-phone"
          v-model="imprintForm.contact_phone"
          type="tel"
          placeholder="+49 ..."
          class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
      </div>

      <div class="space-y-1 sm:col-span-2">
        <label class="text-sm font-medium" for="imprint-website">{{ t('settings.imprintWebsite') }}</label>
        <input
          id="imprint-website"
          v-model="imprintForm.website"
          type="url"
          placeholder="https://example.com"
          class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
      </div>

      <div class="space-y-1 sm:col-span-2">
        <label class="text-sm font-medium">{{ t('settings.imprintAddress') }}</label>
        <div class="grid grid-cols-4 gap-2">
          <input
            v-model="imprintForm.address_street"
            type="text"
            :placeholder="t('settings.imprintStreet')"
            class="col-span-3 flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          />
          <input
            v-model="imprintForm.address_house_number"
            type="text"
            :placeholder="t('settings.imprintHouseNumber')"
            class="col-span-1 flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          />
          <input
            v-model="imprintForm.address_postal_code"
            type="text"
            :placeholder="t('settings.imprintPostalCode')"
            class="col-span-1 flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          />
          <input
            v-model="imprintForm.address_city"
            type="text"
            :placeholder="t('settings.imprintCity')"
            class="col-span-3 flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          />
        </div>
      </div>

      <div class="space-y-1 sm:col-span-2">
        <label class="text-sm font-medium" for="imprint-timezone">{{ t('settings.timezoneLabel') }}</label>
        <select
          id="imprint-timezone"
          v-model="timezone"
          class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        >
          <option v-for="tz in timezoneOptions" :key="tz.id" :value="tz.id">{{ tz.label }}</option>
        </select>
        <p class="text-xs text-muted-foreground">{{ t('settings.timezoneHint') }}</p>
      </div>

      <div class="sm:col-span-2">
        <p v-if="imprintError" class="mb-2 text-sm text-destructive">{{ imprintError }}</p>
        <p v-if="imprintSuccess" class="mb-2 text-sm text-green-600">{{ imprintSuccess }}</p>
        <button
          type="submit"
          :disabled="imprintLoading"
          class="inline-flex h-9 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90 disabled:opacity-50"
        >
          <span v-if="imprintLoading">{{ t('common.saving') }}</span>
          <span v-else>{{ t('common.save') }}</span>
        </button>
      </div>
    </form>
  </div>
</template>
