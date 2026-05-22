<script setup lang="ts">
import { computed, ref } from 'vue'
import { IconDownload } from '@tabler/icons-vue'
import NayaxMatchedTable from './NayaxMatchedTable.vue'
import NayaxDifferencesTable from './NayaxDifferencesTable.vue'
import NayaxUnmappedSection from './NayaxUnmappedSection.vue'
import { formatDateTime } from '@/lib/utils'

defineProps<{ isAdmin: boolean }>()
const emit = defineEmits<{ restart: []; rerun: []; 'go-to-mapping': [] }>()
const { t, locale } = useI18n()
const recon = useNayaxReconciliation()

const result = computed(() => recon.result.value)
const matchedOpen = ref(false)
const diffOpen = ref(true)
const otherOpen = ref(true)

// Reverse-index vmId → machineName, derived from any Nayax row that
// referenced that VM. Used by NayaxDifferencesTable to show a human
// name on ghost rows (which only carry machine_id). Falls back to '—'
// inside the component when a ghost is on a machine that the current
// Nayax file didn't touch.
const machineNameByVmId = computed(() => {
  const map = new Map<string, string>()
  for (const n of recon.rawRows.value) {
    const vmId = recon.mapping.value[n.nayaxMachineId]
    if (vmId && !map.has(vmId)) {
      map.set(vmId, n.machineName)
    }
  }
  return map
})

function downloadCsv() {
  const csv = recon.exportDiffCsv()
  const blob = new Blob([csv], { type: 'text/csv;charset=utf-8;' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = `nayax-reconciliation-${new Date().toISOString().slice(0, 10)}.csv`
  a.click()
  URL.revokeObjectURL(url)
}

function fmtRange(): string {
  const s = result.value?.fileDateRange
  if (!s) return ''
  return `${formatDateTime(s.fromUtc, locale.value)} – ${formatDateTime(s.toUtc, locale.value)}`
}
</script>

<template>
  <div v-if="result" class="flex flex-col gap-4">
    <!-- Header bar -->
    <div class="rounded-xl border bg-card p-4 shadow-sm">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div>
          <p class="text-sm">
            <span class="font-medium text-green-700 dark:text-green-400">{{ result.matched.length }} {{ t('nayax.reconcile.results.matchedShort') }}</span> ·
            <span class="font-medium text-red-700 dark:text-red-400">{{ result.missingInDb.length }} {{ t('nayax.reconcile.results.missingShort') }}</span> ·
            <span class="font-medium text-yellow-700 dark:text-yellow-400">{{ result.ghostInDb.length }} {{ t('nayax.reconcile.results.ghostShort') }}</span>
          </p>
          <p class="text-xs text-muted-foreground mt-1">
            {{ fmtRange() }} · {{ result.settings.timezone }} · ±{{ result.settings.toleranceSeconds }}s
          </p>
        </div>
        <div class="flex gap-2">
          <button
            class="inline-flex h-9 items-center gap-2 rounded-md border px-3 text-sm hover:bg-muted"
            @click="downloadCsv"
          >
            <IconDownload class="h-4 w-4" /> {{ t('nayax.reconcile.results.exportCsv') }}
          </button>
          <button
            class="inline-flex h-9 items-center rounded-md border px-3 text-sm hover:bg-muted"
            @click="emit('rerun')"
          >
            {{ t('nayax.reconcile.results.rerun') }}
          </button>
          <button
            class="inline-flex h-9 items-center rounded-md border px-3 text-sm hover:bg-muted"
            @click="emit('restart')"
          >
            {{ t('nayax.reconcile.results.startOver') }}
          </button>
        </div>
      </div>
    </div>

    <!-- Merged differences (focus bucket) -->
    <NayaxDifferencesTable
      :missing="result.missingInDb"
      :ghosts="result.ghostInDb"
      :machine-name-by-vm-id="machineNameByVmId"
      :is-admin="isAdmin"
      :open="diffOpen"
      @toggle="diffOpen = !diffOpen"
    />

    <!-- Matched (collapsed by default) -->
    <NayaxMatchedTable
      :rows="result.matched"
      :open="matchedOpen"
      @toggle="matchedOpen = !matchedOpen"
    />

    <!-- Unmapped + unparseable -->
    <NayaxUnmappedSection
      v-if="result.unmapped.length + result.unparseable.length > 0"
      :unmapped="result.unmapped"
      :unparseable="result.unparseable"
      :open="otherOpen"
      @toggle="otherOpen = !otherOpen"
      @go-to-mapping="emit('go-to-mapping')"
    />
  </div>
</template>
