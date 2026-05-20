<script setup lang="ts">
import { computed, ref } from 'vue'
import type { NayaxRow } from '~/composables/useNayaxReconciliation'
import { IconAlertTriangle, IconChevronDown, IconChevronRight } from '@tabler/icons-vue'
import { formatCurrency } from '@/lib/utils'

const props = defineProps<{ rows: NayaxRow[]; isAdmin: boolean; open: boolean }>()
defineEmits<{ toggle: [] }>()
const { t, locale } = useI18n()
const recon = useNayaxReconciliation()

const selected = ref<Set<string>>(new Set())
const showConfirm = ref(false)
const lastResult = ref<{ imported: number; errors: string[] } | null>(null)

const allSelected = computed(() => props.rows.length > 0 && selected.value.size === props.rows.length)

function toggleOne(txId: string) {
  if (selected.value.has(txId)) selected.value.delete(txId)
  else selected.value.add(txId)
  selected.value = new Set(selected.value)
}

function toggleAll() {
  if (allSelected.value) selected.value = new Set()
  else selected.value = new Set(props.rows.map(r => r.txId))
}

async function runImport() {
  const rows = props.rows.filter(r => selected.value.has(r.txId))
  if (rows.length === 0) return
  showConfirm.value = false
  lastResult.value = await recon.bulkImportMissing(rows)
  selected.value = new Set()
}
</script>

<template>
  <div class="rounded-xl border border-red-200 bg-card shadow-sm">
    <button class="flex w-full items-center justify-between p-4 hover:bg-muted/30" @click="$emit('toggle')">
      <span class="flex items-center gap-2 text-sm font-medium">
        <IconAlertTriangle class="h-4 w-4 text-red-600" />
        {{ t('nayax.reconcile.results.missingTitle') }} ({{ rows.length }})
      </span>
      <component :is="open ? IconChevronDown : IconChevronRight" class="h-4 w-4 text-muted-foreground" />
    </button>
    <div v-if="open" class="border-t">
      <div v-if="selected.size > 0 && isAdmin" class="flex items-center justify-between bg-muted/40 px-4 py-2 text-sm">
        <span>{{ t('nayax.reconcile.results.selectedN', { n: selected.size }) }}</span>
        <button
          class="inline-flex h-8 items-center rounded-md bg-primary px-3 text-xs font-medium text-primary-foreground hover:bg-primary/90"
          @click="showConfirm = true"
        >
          {{ t('nayax.reconcile.results.importCta') }}
        </button>
      </div>
      <div
        v-if="lastResult"
        class="border-b px-4 py-2 text-sm"
        :class="lastResult.errors.length > 0
          ? 'bg-amber-50 text-amber-900 dark:bg-amber-950 dark:text-amber-200'
          : 'bg-green-50 text-green-800 dark:bg-green-950 dark:text-green-200'"
      >
        <p>
          {{ t('nayax.reconcile.results.importedN', { n: lastResult.imported }) }}
          <span v-if="lastResult.errors.length > 0">· {{ t('nayax.reconcile.results.importErrors', { n: lastResult.errors.length }) }}</span>
        </p>
        <details v-if="lastResult.errors.length > 0" class="mt-2">
          <summary class="cursor-pointer text-xs underline">{{ t('nayax.reconcile.results.showErrors') }}</summary>
          <ul class="mt-1 list-disc pl-5 text-xs space-y-0.5">
            <li v-for="(err, i) in lastResult.errors" :key="i" class="font-mono">{{ err }}</li>
          </ul>
        </details>
      </div>
      <div v-if="rows.length === 0" class="p-4 text-sm text-muted-foreground">
        {{ t('nayax.reconcile.results.allMatched') }}
      </div>
      <div v-else class="overflow-x-auto">
        <table class="w-full text-sm">
          <thead>
            <tr class="border-b bg-muted/40 text-left">
              <th class="w-10 px-4 py-2">
                <input type="checkbox" :checked="allSelected" :disabled="!isAdmin" @change="toggleAll" />
              </th>
              <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colTime') }}</th>
              <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colMachine') }}</th>
              <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colSlot') }}</th>
              <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colProduct') }}</th>
              <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colPrice') }}</th>
              <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colPayment') }}</th>
              <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colTxId') }}</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="r in rows" :key="r.txId" class="border-b last:border-0">
              <td class="px-4 py-2">
                <input
                  type="checkbox"
                  :checked="selected.has(r.txId)"
                  :disabled="!isAdmin"
                  @change="toggleOne(r.txId)"
                />
              </td>
              <td class="px-4 py-2">{{ r.localDt }}</td>
              <td class="px-4 py-2">{{ r.machineName }}</td>
              <td class="px-4 py-2 tabular-nums">{{ r.itemNumber }}</td>
              <td class="px-4 py-2">{{ r.productName }}</td>
              <td class="px-4 py-2 tabular-nums">{{ formatCurrency(r.priceGross, locale) }}</td>
              <td class="px-4 py-2">{{ r.paymentSource }}</td>
              <td class="px-4 py-2 font-mono text-xs">{{ r.txId }}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>

    <!-- Confirm dialog -->
    <AppModal
      v-model:open="showConfirm"
      :title="t('nayax.reconcile.results.importConfirmTitle')"
      size="sm"
    >
      <p class="text-sm text-muted-foreground mb-4">
        {{ t('nayax.reconcile.results.importConfirmBody', { n: selected.size }) }}
      </p>
      <div class="flex justify-end gap-2">
        <button
          class="inline-flex h-9 items-center rounded-md border px-4 text-sm hover:bg-muted"
          @click="showConfirm = false"
        >
          {{ t('common.cancel') }}
        </button>
        <button
          class="inline-flex h-9 items-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground"
          @click="runImport"
        >
          {{ t('common.confirm') }}
        </button>
      </div>
    </AppModal>
  </div>
</template>
