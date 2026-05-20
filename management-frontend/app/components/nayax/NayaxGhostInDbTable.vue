<script setup lang="ts">
import { computed, ref } from 'vue'
import type { DbSale } from '~/composables/useNayaxReconciliation'
import { IconChevronDown, IconChevronRight, IconInfoCircle, IconTrash } from '@tabler/icons-vue'
import { formatCurrency, formatDateTime } from '@/lib/utils'

defineProps<{ rows: DbSale[]; isAdmin: boolean; open: boolean }>()
defineEmits<{ toggle: [] }>()
const { t, locale } = useI18n()
const recon = useNayaxReconciliation()

const pendingDelete = ref<DbSale | null>(null)
const showDeleteConfirm = computed({
  get: () => pendingDelete.value !== null,
  set: (v: boolean) => { if (!v) pendingDelete.value = null },
})

async function confirmDelete() {
  if (!pendingDelete.value) return
  const id = pendingDelete.value.id
  pendingDelete.value = null
  await recon.deleteGhost(id)
}
</script>

<template>
  <div class="rounded-xl border border-yellow-200 bg-card shadow-sm">
    <button class="flex w-full items-center justify-between p-4 hover:bg-muted/30" @click="$emit('toggle')">
      <span class="flex items-center gap-2 text-sm font-medium">
        <IconInfoCircle class="h-4 w-4 text-yellow-600" />
        {{ t('nayax.reconcile.results.ghostTitle') }} ({{ rows.length }})
      </span>
      <component :is="open ? IconChevronDown : IconChevronRight" class="h-4 w-4 text-muted-foreground" />
    </button>
    <div v-if="open" class="border-t">
      <div v-if="rows.length === 0" class="p-4 text-sm text-muted-foreground">
        {{ t('nayax.reconcile.results.noGhosts') }}
      </div>
      <div v-else class="overflow-x-auto">
        <table class="w-full text-sm">
          <thead>
            <tr class="border-b bg-muted/40 text-left">
              <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colTime') }}</th>
              <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colSlot') }}</th>
              <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colProduct') }}</th>
              <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colPrice') }}</th>
              <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colChannel') }}</th>
              <th class="w-16 px-4 py-2"></th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="r in rows" :key="r.id" class="border-b last:border-0">
              <td class="px-4 py-2">{{ formatDateTime(r.created_at, locale) }}</td>
              <td class="px-4 py-2 tabular-nums">{{ r.item_number }}</td>
              <td class="px-4 py-2">{{ r.product_name ?? '—' }}</td>
              <td class="px-4 py-2 tabular-nums">{{ formatCurrency(r.item_price ?? null, locale) }}</td>
              <td class="px-4 py-2">{{ r.channel ?? '—' }}</td>
              <td class="px-4 py-2 text-right">
                <button
                  v-if="isAdmin"
                  class="inline-flex h-8 items-center gap-1 rounded-md border border-red-200 px-2 text-xs text-red-700 hover:bg-red-50"
                  @click="pendingDelete = r"
                >
                  <IconTrash class="h-3 w-3" />
                  {{ t('common.delete') }}
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>

    <AppModal
      v-model:open="showDeleteConfirm"
      :title="t('nayax.reconcile.results.deleteConfirmTitle')"
      size="sm"
    >
      <p class="text-sm text-muted-foreground mb-4">
        {{ t('nayax.reconcile.results.deleteConfirmBody') }}
      </p>
      <div class="flex justify-end gap-2">
        <button
          class="inline-flex h-9 items-center rounded-md border px-4 text-sm hover:bg-muted"
          @click="pendingDelete = null"
        >
          {{ t('common.cancel') }}
        </button>
        <button
          class="inline-flex h-9 items-center rounded-md bg-red-600 px-4 text-sm font-medium text-white hover:bg-red-700"
          @click="confirmDelete"
        >
          {{ t('common.delete') }}
        </button>
      </div>
    </AppModal>
  </div>
</template>
