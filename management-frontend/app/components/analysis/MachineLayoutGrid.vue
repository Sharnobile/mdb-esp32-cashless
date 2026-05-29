<script setup lang="ts">
import type { GridSlot, SlotTier } from '@/composables/useMachineAnalysis'

const props = defineProps<{
  slots: GridSlot[]
  rowCount: number
  selectedTrayId?: string | null
}>()

const emit = defineEmits<{ (e: 'select', slot: GridSlot): void }>()

const COLUMNS = 10

// Tailwind classes per performance tier (works in light + dark).
const tierClass: Record<SlotTier, string> = {
  strong: 'border-green-500/70 bg-green-500/10',
  ok: 'border-yellow-400/70 bg-yellow-400/10',
  weak: 'border-orange-400/80 bg-orange-400/15',
  dead: 'border-red-500/80 bg-red-500/15',
  testing: 'border-blue-400/70 bg-blue-400/10',
  empty: 'border-dashed border-muted-foreground/30 bg-transparent',
}

function cellStyle(slot: GridSlot) {
  return {
    gridColumn: `${slot.column + 1} / span ${slot.width}`,
    gridRow: `${slot.row + 1}`,
  }
}

// Short metric shown on each occupied cell.
function badge(slot: GridSlot): string {
  if (!slot.product_id) return ''
  if (slot.tier === 'testing') return '⏳'
  return `${Math.round(slot.sell_through_pct)}%`
}
</script>

<template>
  <div
    class="grid gap-1.5"
    :style="{ gridTemplateColumns: `repeat(${COLUMNS}, minmax(0, 1fr))`, gridAutoRows: '9rem' }"
  >
    <button
      v-for="slot in props.slots"
      :key="slot.trayId"
      type="button"
      :style="cellStyle(slot)"
      class="group relative flex flex-col items-center justify-center overflow-hidden rounded-md border-2 p-1 transition-colors hover:brightness-105 focus:outline-none focus-visible:ring-2 focus-visible:ring-primary"
      :class="[
        tierClass[slot.tier],
        props.selectedTrayId === slot.trayId ? 'ring-2 ring-primary' : '',
      ]"
      @click="emit('select', slot)"
    >
      <!-- Product image / placeholder -->
      <img
        v-if="slot.image_url"
        :src="slot.image_url"
        :alt="slot.product_name ?? ''"
        class="h-20 w-20 rounded object-cover"
      />
      <div
        v-else
        class="flex h-20 w-20 items-center justify-center rounded bg-muted/50 text-sm text-muted-foreground"
      >
        {{ slot.product_id ? '?' : '—' }}
      </div>

      <!-- Slot number pill (bottom-left) -->
      <span
        class="absolute bottom-0.5 left-0.5 rounded bg-black/60 px-1 text-[9px] font-semibold tabular-nums text-white"
      >
        {{ slot.item_number }}
      </span>

      <!-- Performance badge (top-right) -->
      <span
        v-if="badge(slot)"
        class="absolute right-0.5 top-0.5 rounded px-1 text-[9px] font-semibold tabular-nums"
        :class="slot.tier === 'dead' || slot.tier === 'weak'
          ? 'bg-red-600 text-white'
          : 'bg-black/50 text-white'"
      >
        {{ badge(slot) }}
      </span>
    </button>
  </div>
</template>
