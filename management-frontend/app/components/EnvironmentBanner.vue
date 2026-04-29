<script setup lang="ts">
import { computed } from 'vue'
import { IconAlertTriangle } from '@tabler/icons-vue'
import { useEnvironment, type ColorKey } from '@/composables/useEnvironment'

const env = useEnvironment()

// Static map — Tailwind 4 JIT picks up these literal class names.
// Colors are intentionally identical in light and dark mode: a warning
// indicator must remain prominent regardless of theme.
const COLOR_CLASSES: Record<ColorKey, string> = {
  red:    'bg-red-600 text-white',
  amber:  'bg-amber-500 text-amber-950',
  orange: 'bg-orange-500 text-white',
  purple: 'bg-purple-600 text-white',
  blue:   'bg-blue-600 text-white',
}

const colorClass = computed(() => COLOR_CLASSES[env.envColor])
</script>

<template>
  <div
    v-if="env.showBanner"
    data-testid="env-banner"
    role="status"
    aria-live="polite"
    :class="[
      'sticky top-0 z-50 w-full pt-[env(safe-area-inset-top)]',
      colorClass,
    ]"
  >
    <div class="flex h-7 items-center justify-center gap-2 text-xs font-semibold uppercase tracking-wider">
      <IconAlertTriangle class="size-4 shrink-0" aria-hidden="true" />
      <span>{{ env.envName }}</span>
    </div>
  </div>
</template>
