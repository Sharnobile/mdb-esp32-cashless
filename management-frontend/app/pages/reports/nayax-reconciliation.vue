<script setup lang="ts">
import { computed, onMounted } from 'vue'
import NayaxUploadStep from '~/components/nayax/NayaxUploadStep.vue'
import NayaxMappingStep from '~/components/nayax/NayaxMappingStep.vue'
import NayaxSettingsStep from '~/components/nayax/NayaxSettingsStep.vue'
import NayaxResultsView from '~/components/nayax/NayaxResultsView.vue'

definePageMeta({ middleware: 'auth' })

const { t } = useI18n()
const { role } = useOrganization()
const recon = useNayaxReconciliation()
const isAdmin = computed(() => role.value === 'admin')

// localStorage hydration on first mount. Persists user prefs across reloads
// without polluting the DB — these are display preferences, not org data.
onMounted(() => {
  const tz = localStorage.getItem('nayax-reconcile-tz')
  if (tz) recon.settings.value.timezone = tz
  const tol = localStorage.getItem('nayax-reconcile-tolerance')
  if (tol) recon.settings.value.toleranceSeconds = Math.max(5, Math.min(600, Number(tol)))
})

async function onFileSelected(file: File) {
  await recon.parseFile(file)
  if (recon.error.value) return
  await recon.loadMappingForCompany()
  const unmapped = recon.detectUnmappedIds()
  recon.step.value = unmapped.length > 0 ? 'mapping' : 'settings'
}

async function onMappingDone() {
  recon.step.value = 'settings'
}

async function onSettingsRun() {
  localStorage.setItem('nayax-reconcile-tz', recon.settings.value.timezone)
  localStorage.setItem('nayax-reconcile-tolerance', String(recon.settings.value.toleranceSeconds))
  await recon.loadDbSales()
  recon.runMatch()
  recon.step.value = 'results'
}

function onStartOver() {
  recon.reset()
}
</script>

<template>
  <div class="flex flex-1 flex-col gap-6 p-4 md:p-6">
    <div class="flex items-center justify-between">
      <div>
        <h1 class="text-2xl font-semibold">{{ t('nayax.reconcile.title') }}</h1>
        <p class="text-sm text-muted-foreground">{{ t('nayax.reconcile.subtitle') }}</p>
      </div>
      <NuxtLink
        to="/reports"
        class="text-sm text-muted-foreground hover:text-foreground"
      >
        ← {{ t('nayax.reconcile.backToReports') }}
      </NuxtLink>
    </div>

    <NayaxUploadStep
      v-if="recon.step.value === 'upload'"
      :parsing="recon.parsing.value"
      :error="recon.error.value"
      @file="onFileSelected"
    />

    <NayaxMappingStep
      v-else-if="recon.step.value === 'mapping'"
      :is-admin="isAdmin"
      @done="onMappingDone"
    />

    <NayaxSettingsStep
      v-else-if="recon.step.value === 'settings'"
      :is-admin="isAdmin"
      @run="onSettingsRun"
      @back="recon.step.value = 'mapping'"
    />

    <NayaxResultsView
      v-else-if="recon.step.value === 'results'"
      :is-admin="isAdmin"
      @restart="onStartOver"
      @rerun="recon.step.value = 'settings'"
      @go-to-mapping="recon.step.value = 'mapping'"
    />
  </div>
</template>
