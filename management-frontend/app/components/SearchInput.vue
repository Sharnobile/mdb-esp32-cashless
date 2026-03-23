<script setup lang="ts">
import { IconSearch, IconX } from '@tabler/icons-vue'

const model = defineModel<string>({ default: '' })
defineProps<{ placeholder?: string }>()
</script>

<template>
  <div class="relative">
    <IconSearch class="absolute left-2.5 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
    <input
      v-model="model"
      type="text"
      :placeholder="placeholder"
      class="h-9 w-full rounded-md border border-input bg-background pl-8 pr-8 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
    />
    <button
      v-if="model"
      type="button"
      class="absolute right-2 top-1/2 -translate-y-1/2 text-muted-foreground hover:text-foreground"
      @click="model = ''"
    >
      <IconX class="size-3.5" />
    </button>
  </div>
</template>
