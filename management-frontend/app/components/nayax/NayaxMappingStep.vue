<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import NayaxMachineCombobox from './NayaxMachineCombobox.vue'

const props = defineProps<{ isAdmin: boolean }>()
const emit = defineEmits<{ done: [] }>()
const { t } = useI18n()
const recon = useNayaxReconciliation()
const { machines, fetchMachines } = useMachines()

const unmappedIds = computed(() => recon.detectUnmappedIds())
// Indexed under noUncheckedIndexedAccess: explicit `string | null | undefined`
// keeps the lookup happy even when a row hasn't been touched yet.
const localPicks = ref<Record<string, string | null>>({})
const saving = ref(false)
const error = ref('')

onMounted(async () => {
  if (machines.value.length === 0) await fetchMachines()
})

interface UnmappedRow {
  nayaxId: string
  name: string
}

function rowsToShow(): UnmappedRow[] {
  // Show the unique unmapped IDs along with the most recent Nayax machineName
  // observed for each.
  const seen = new Map<string, string>()
  for (const n of recon.rawRows.value) {
    if (unmappedIds.value.includes(n.nayaxMachineId) && !seen.has(n.nayaxMachineId)) {
      seen.set(n.nayaxMachineId, n.machineName)
    }
  }
  return [...seen.entries()].map(([nayaxId, name]) => ({ nayaxId, name }))
}

function pickFor(nayaxId: string): string | null {
  return localPicks.value[nayaxId] ?? null
}

function setPick(nayaxId: string, value: string | null) {
  localPicks.value = { ...localPicks.value, [nayaxId]: value }
}

async function save() {
  if (!props.isAdmin) {
    error.value = 'nayax.reconcile.mapping.adminOnly'
    return
  }
  saving.value = true
  error.value = ''
  try {
    for (const [nayaxId, vmId] of Object.entries(localPicks.value)) {
      await recon.saveMapping(nayaxId, vmId)
    }
    emit('done')
  }
  catch (e: unknown) {
    error.value = e instanceof Error ? e.message : 'nayax.reconcile.mapping.saveFailed'
  }
  finally {
    saving.value = false
  }
}
</script>

<template>
  <div class="rounded-xl border bg-card p-6 shadow-sm">
    <h2 class="text-lg font-semibold mb-1">{{ t('nayax.reconcile.mapping.title') }}</h2>
    <p class="mb-4 text-sm text-muted-foreground">{{ t('nayax.reconcile.mapping.intro') }}</p>

    <div v-if="!isAdmin" class="rounded-lg border border-yellow-200 bg-yellow-50 p-3 text-sm text-yellow-900 mb-4">
      {{ t('nayax.reconcile.mapping.viewerNotice') }}
    </div>

    <table class="w-full text-sm">
      <thead>
        <tr class="border-b text-left">
          <th class="py-2 font-medium">{{ t('nayax.reconcile.mapping.colNayaxId') }}</th>
          <th class="py-2 font-medium">{{ t('nayax.reconcile.mapping.colNayaxName') }}</th>
          <th class="py-2 font-medium">{{ t('nayax.reconcile.mapping.colMapsTo') }}</th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="row in rowsToShow()" :key="row.nayaxId" class="border-b last:border-0">
          <td class="py-3 font-mono text-xs">{{ row.nayaxId }}</td>
          <td class="py-3">{{ row.name }}</td>
          <td class="py-3">
            <NayaxMachineCombobox
              :model-value="pickFor(row.nayaxId)"
              :machines="machines"
              :disabled="!isAdmin"
              @update:model-value="(v) => setPick(row.nayaxId, v)"
            />
          </td>
        </tr>
      </tbody>
    </table>

    <p v-if="error" class="mt-3 text-sm text-destructive">{{ t(error) || error }}</p>

    <div class="mt-4 flex justify-end gap-2">
      <button
        class="inline-flex h-9 items-center rounded-md border px-4 text-sm hover:bg-muted"
        @click="recon.reset()"
      >
        {{ t('common.cancel') }}
      </button>
      <button
        :disabled="saving"
        class="inline-flex h-9 items-center rounded-md bg-primary px-6 text-sm font-medium text-primary-foreground shadow hover:bg-primary/90 disabled:opacity-50"
        @click="save"
      >
        <span v-if="saving">{{ t('common.saving') }}</span>
        <span v-else>{{ t('nayax.reconcile.mapping.continueCta') }}</span>
      </button>
    </div>
  </div>
</template>
