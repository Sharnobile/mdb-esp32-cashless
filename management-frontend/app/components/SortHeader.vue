<script setup lang="ts">
import { IconArrowUp, IconArrowDown, IconArrowsSort } from '@tabler/icons-vue'

defineProps<{
  icon: 'up' | 'down' | 'none'
  align?: 'left' | 'right'
}>()
</script>

<template>
  <div class="flex items-center gap-1" :class="{ 'justify-end': align === 'right' }">
    <slot />
    <component
      :is="icon === 'up' ? IconArrowUp : icon === 'down' ? IconArrowDown : IconArrowsSort"
      class="size-3.5 text-muted-foreground"
    />
  </div>
</template>
