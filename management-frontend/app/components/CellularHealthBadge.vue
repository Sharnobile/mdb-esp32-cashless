<script setup lang="ts">
import { computed } from 'vue';

const props = defineProps<{
  diagnostics?: Record<string, any> | null;
}>();

const cellular = computed(() => {
  const c = props.diagnostics?.cellular;
  if (!c || c.uplink !== 'cellular') return null;
  return c;
});

/* dBm → 0..4 bars: ≥-65=4, ≥-80=3, ≥-95=2, ≥-105=1, else 0 */
const bars = computed(() => {
  const dbm = cellular.value?.rssi;
  if (typeof dbm !== 'number') return 0;
  if (dbm >= -65) return 4;
  if (dbm >= -80) return 3;
  if (dbm >= -95) return 2;
  if (dbm >= -105) return 1;
  return 0;
});

const tooltip = computed(() => {
  const c = cellular.value;
  if (!c) return '';
  const parts: string[] = [];
  if (typeof c.rssi === 'number') parts.push(`${c.rssi} dBm`);
  if (c.ip) parts.push(`IP ${c.ip}`);
  return parts.join(' · ');
});
</script>

<template>
  <div v-if="cellular" class="inline-flex items-center gap-2 text-xs" :title="tooltip">
    <!-- signal bars -->
    <span class="inline-flex items-end gap-px h-3.5">
      <span
        v-for="i in 4"
        :key="i"
        class="w-1 rounded-sm transition-colors"
        :class="i <= bars ? 'bg-lime-400' : 'bg-slate-700'"
        :style="{ height: `${i * 25}%` }"
      />
    </span>
    <!-- operator -->
    <span class="text-slate-300">{{ cellular.op || '—' }}</span>
    <!-- mode pill -->
    <span class="px-1.5 py-px rounded text-[10px] font-medium bg-slate-700 text-slate-200">
      {{ cellular.mode || '—' }}
    </span>
  </div>
</template>
