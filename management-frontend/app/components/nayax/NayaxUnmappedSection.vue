<script setup lang="ts">
import type { NayaxRow } from '~/composables/useNayaxReconciliation'
import { IconChevronDown, IconChevronRight, IconCircleDashed } from '@tabler/icons-vue'

defineProps<{ unmapped: NayaxRow[]; unparseable: NayaxRow[]; open: boolean }>()
defineEmits<{ toggle: []; 'go-to-mapping': [] }>()
const { t } = useI18n()
</script>

<template>
  <div class="rounded-xl border bg-card shadow-sm">
    <button class="flex w-full items-center justify-between p-4 hover:bg-muted/30" @click="$emit('toggle')">
      <span class="flex items-center gap-2 text-sm font-medium">
        <IconCircleDashed class="h-4 w-4 text-muted-foreground" />
        {{ t('nayax.reconcile.results.otherTitle') }} ({{ unmapped.length + unparseable.length }})
      </span>
      <component :is="open ? IconChevronDown : IconChevronRight" class="h-4 w-4 text-muted-foreground" />
    </button>
    <div v-if="open" class="border-t p-4 space-y-3 text-sm">
      <div v-if="unmapped.length > 0">
        <p class="font-medium mb-1">{{ t('nayax.reconcile.results.unmappedHead', { n: unmapped.length }) }}</p>
        <p class="text-muted-foreground mb-2">{{ t('nayax.reconcile.results.unmappedHint') }}</p>
        <button
          class="inline-flex h-8 items-center rounded-md border px-3 text-xs hover:bg-muted"
          @click="$emit('go-to-mapping')"
        >
          {{ t('nayax.reconcile.results.openMapping') }}
        </button>
      </div>
      <div v-if="unparseable.length > 0">
        <p class="font-medium mb-1">{{ t('nayax.reconcile.results.unparseableHead', { n: unparseable.length }) }}</p>
        <ul class="list-disc pl-5 text-muted-foreground text-xs space-y-1">
          <li v-for="r in unparseable.slice(0, 10)" :key="r.txId">
            {{ r.localDt }} · {{ r.machineName }} · {{ r.productName }} ({{ r.selectionInfoRaw || t('nayax.reconcile.results.emptyField') }})
          </li>
        </ul>
        <p v-if="unparseable.length > 10" class="text-[10px] text-muted-foreground italic mt-1">
          {{ t('nayax.reconcile.results.unparseableMore', { n: unparseable.length - 10 }) }}
        </p>
      </div>
    </div>
  </div>
</template>
