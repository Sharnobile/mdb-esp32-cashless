<script setup lang="ts">
import { computed, ref } from 'vue'
import type { NayaxRow, DbSale } from '~/composables/useNayaxReconciliation'
import { formatCurrency, formatDateTime } from '@/lib/utils'
import { IconAlertTriangle, IconChevronDown, IconChevronRight, IconInfoCircle, IconTrash } from '@tabler/icons-vue'
import AppModal from '~/components/AppModal.vue'

const props = defineProps<{
  missing: NayaxRow[]
  ghosts: DbSale[]
  machineNameByVmId: Map<string, string>
  isAdmin: boolean
  open: boolean
}>()
defineEmits<{ toggle: [] }>()

const { t, locale } = useI18n()
const recon = useNayaxReconciliation()

// Bulk-import selection (only Missing rows are selectable).
const selected = ref<Set<string>>(new Set())
const showConfirm = ref(false)
const lastResult = ref<{ imported: number; errors: string[] } | null>(null)
const pendingDelete = ref<DbSale | null>(null)

const showDeleteConfirm = computed({
  get: () => pendingDelete.value !== null,
  set: (v: boolean) => { if (!v) pendingDelete.value = null },
})

// Chronologically merged rows. Both NayaxRow.utcDt and DbSale.created_at are
// ISO 8601 with a 'Z' suffix, so lexicographic localeCompare is chronological.
// Stable tiebreaker: at identical timestamps, the missing-in-DB row comes
// before the ghost row (the Nayax-recorded event first).
type Row =
  | { kind: 'missing'; ts: string; payload: NayaxRow }
  | { kind: 'ghost'; ts: string; payload: DbSale }

const mergedRows = computed<Row[]>(() => {
  const rows: Row[] = [
    ...props.missing.map(m => ({ kind: 'missing' as const, ts: m.utcDt, payload: m })),
    ...props.ghosts.map(g => ({ kind: 'ghost' as const, ts: g.created_at, payload: g })),
  ]
  rows.sort((a, b) =>
    a.ts.localeCompare(b.ts) || (a.kind === 'missing' ? -1 : 1),
  )
  return rows
})

const total = computed(() => props.missing.length + props.ghosts.length)
const allMissingSelected = computed(() =>
  props.missing.length > 0 && selected.value.size === props.missing.length,
)

function toggleOne(txId: string) {
  if (selected.value.has(txId)) selected.value.delete(txId)
  else selected.value.add(txId)
  // Force reactivity — Vue does not observe Set.add/delete in-place.
  selected.value = new Set(selected.value)
}

function toggleAllMissing() {
  if (allMissingSelected.value) selected.value = new Set()
  else selected.value = new Set(props.missing.map(r => r.txId))
}

async function runImport() {
  const rowsToImport = props.missing.filter(r => selected.value.has(r.txId))
  if (rowsToImport.length === 0) return
  showConfirm.value = false
  lastResult.value = await recon.bulkImportMissing(rowsToImport)
  selected.value = new Set()
}

async function confirmDelete() {
  if (!pendingDelete.value) return
  const id = pendingDelete.value.id
  pendingDelete.value = null
  await recon.deleteGhost(id)
}

function ghostMachineName(g: DbSale): string {
  return props.machineNameByVmId.get(g.machine_id) ?? '—'
}
function shortId(id: string): string {
  return id.slice(0, 8)
}
</script>

<template>
  <div class="rounded-xl border bg-card shadow-sm">
    <button class="flex w-full items-center justify-between p-4 hover:bg-muted/30" @click="$emit('toggle')">
      <span class="flex items-center gap-2 text-sm font-medium">
        <IconAlertTriangle class="h-4 w-4 text-muted-foreground" />
        {{ t('nayax.reconcile.results.differencesTitle') }} ({{ total }})
      </span>
      <component :is="open ? IconChevronDown : IconChevronRight" class="h-4 w-4 text-muted-foreground" />
    </button>

    <div v-if="open" class="border-t">
      <!-- Bulk action bar (only for admins with selected missing rows) -->
      <div v-if="selected.size > 0 && isAdmin" class="flex items-center justify-between bg-muted/40 px-4 py-2 text-sm">
        <span>{{ t('nayax.reconcile.results.selectedN', { n: selected.size }) }}</span>
        <button
          class="inline-flex h-8 items-center rounded-md bg-primary px-3 text-xs font-medium text-primary-foreground hover:bg-primary/90"
          @click="showConfirm = true"
        >
          {{ t('nayax.reconcile.results.importCta') }}
        </button>
      </div>

      <!-- Import result banner -->
      <div
        v-if="lastResult"
        class="border-b px-4 py-2 text-sm"
        :class="lastResult.errors.length > 0
          ? 'bg-amber-50 text-amber-900 dark:bg-amber-950 dark:text-amber-200'
          : 'bg-green-50 text-green-800 dark:bg-green-950 dark:text-green-200'"
      >
        <p>
          {{ t('nayax.reconcile.results.importedN', { n: lastResult.imported }) }}
          <span v-if="lastResult.errors.length > 0"> · {{ t('nayax.reconcile.results.importErrors', { n: lastResult.errors.length }) }}</span>
        </p>
        <details v-if="lastResult.errors.length > 0" class="mt-2">
          <summary class="cursor-pointer text-xs underline">{{ t('nayax.reconcile.results.showErrors') }}</summary>
          <ul class="mt-1 list-disc pl-5 text-xs space-y-0.5">
            <li v-for="(err, i) in lastResult.errors" :key="i" class="font-mono">{{ err }}</li>
          </ul>
        </details>
      </div>

      <!-- Empty state -->
      <div v-if="total === 0" class="p-4 text-sm text-muted-foreground">
        {{ t('nayax.reconcile.results.noDifferences') }}
      </div>

      <!-- Merged table -->
      <div v-else class="overflow-x-auto">
        <table class="w-full text-sm">
          <thead>
            <tr class="border-b bg-muted/40 text-left">
              <th class="w-10 px-4 py-2">
                <input
                  v-if="missing.length > 0"
                  type="checkbox"
                  :checked="allMissingSelected"
                  :disabled="!isAdmin"
                  :aria-label="t('nayax.reconcile.results.selectedN', { n: missing.length })"
                  @change="toggleAllMissing"
                />
              </th>
              <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colTime') }}</th>
              <th class="px-4 py-2 font-medium"></th>
              <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colMachine') }}</th>
              <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colSlot') }}</th>
              <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colProduct') }}</th>
              <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colPrice') }}</th>
              <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colPayment') }}</th>
              <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colTxId') }}</th>
              <th class="w-20 px-4 py-2"></th>
            </tr>
          </thead>
          <tbody>
            <template v-for="row in mergedRows" :key="row.kind + ':' + (row.kind === 'missing' ? row.payload.txId : row.payload.id)">
              <!-- Missing row -->
              <tr v-if="row.kind === 'missing'" class="border-b last:border-0">
                <td class="px-4 py-2">
                  <input
                    type="checkbox"
                    :checked="selected.has(row.payload.txId)"
                    :disabled="!isAdmin"
                    @change="toggleOne(row.payload.txId)"
                  />
                </td>
                <td class="px-4 py-2">{{ formatDateTime(row.payload.utcDt, locale) }}</td>
                <td class="px-4 py-2">
                  <span class="inline-flex items-center rounded-full bg-red-100 px-2 py-0.5 text-xs font-medium text-red-800 dark:bg-red-950 dark:text-red-200">
                    {{ t('nayax.reconcile.results.bucketMissing') }}
                  </span>
                </td>
                <td class="px-4 py-2">{{ row.payload.machineName }}</td>
                <td class="px-4 py-2 tabular-nums">{{ row.payload.itemNumber }}</td>
                <td class="px-4 py-2">{{ row.payload.productName }}</td>
                <td class="px-4 py-2 tabular-nums">{{ formatCurrency(row.payload.priceGross, locale) }}</td>
                <td class="px-4 py-2">{{ row.payload.paymentSource }}</td>
                <td class="px-4 py-2 font-mono text-xs">{{ row.payload.txId }}</td>
                <td class="px-4 py-2"></td>
              </tr>
              <!-- Ghost row -->
              <tr v-else class="border-b last:border-0">
                <td class="px-4 py-2"><span class="text-muted-foreground">—</span></td>
                <td class="px-4 py-2">{{ formatDateTime(row.payload.created_at, locale) }}</td>
                <td class="px-4 py-2">
                  <span class="inline-flex items-center rounded-full bg-yellow-100 px-2 py-0.5 text-xs font-medium text-yellow-800 dark:bg-yellow-950 dark:text-yellow-200">
                    <IconInfoCircle class="mr-1 h-3 w-3" />
                    {{ t('nayax.reconcile.results.bucketGhost') }}
                  </span>
                </td>
                <td class="px-4 py-2">{{ ghostMachineName(row.payload) }}</td>
                <td class="px-4 py-2 tabular-nums">{{ row.payload.item_number ?? '—' }}</td>
                <td class="px-4 py-2">{{ row.payload.product_name ?? '—' }}</td>
                <td class="px-4 py-2 tabular-nums">{{ formatCurrency(row.payload.item_price ?? null, locale) }}</td>
                <td class="px-4 py-2">{{ row.payload.channel ?? '—' }}</td>
                <td class="px-4 py-2 font-mono text-xs">{{ shortId(row.payload.id) }}</td>
                <td class="px-4 py-2 text-right">
                  <button
                    v-if="isAdmin"
                    class="inline-flex h-8 items-center gap-1 rounded-md border border-red-200 px-2 text-xs text-red-700 hover:bg-red-50 dark:border-red-900 dark:text-red-300 dark:hover:bg-red-950"
                    @click="pendingDelete = row.payload"
                  >
                    <IconTrash class="h-3 w-3" />
                    {{ t('common.delete') }}
                  </button>
                </td>
              </tr>
            </template>
          </tbody>
        </table>
      </div>
    </div>

    <!-- Bulk-import confirmation -->
    <AppModal v-model:open="showConfirm" :title="t('nayax.reconcile.results.importConfirmTitle')" size="sm">
      <p class="text-sm text-muted-foreground mb-4">
        {{ t('nayax.reconcile.results.importConfirmBody', { n: selected.size }) }}
      </p>
      <div class="flex justify-end gap-2">
        <button class="inline-flex h-9 items-center rounded-md border px-4 text-sm hover:bg-muted" @click="showConfirm = false">
          {{ t('common.cancel') }}
        </button>
        <button class="inline-flex h-9 items-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground" @click="runImport">
          {{ t('common.confirm') }}
        </button>
      </div>
    </AppModal>

    <!-- Per-row delete confirmation -->
    <AppModal v-model:open="showDeleteConfirm" :title="t('nayax.reconcile.results.deleteConfirmTitle')" size="sm">
      <p class="text-sm text-muted-foreground mb-4">
        {{ t('nayax.reconcile.results.deleteConfirmBody') }}
      </p>
      <div class="flex justify-end gap-2">
        <button class="inline-flex h-9 items-center rounded-md border px-4 text-sm hover:bg-muted" @click="pendingDelete = null">
          {{ t('common.cancel') }}
        </button>
        <button class="inline-flex h-9 items-center rounded-md bg-red-600 px-4 text-sm font-medium text-white hover:bg-red-700" @click="confirmDelete">
          {{ t('common.delete') }}
        </button>
      </div>
    </AppModal>
  </div>
</template>
