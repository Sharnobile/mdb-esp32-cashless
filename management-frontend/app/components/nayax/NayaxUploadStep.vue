<script setup lang="ts">
const props = defineProps<{ parsing: boolean; error: string }>()
const emit = defineEmits<{ file: [f: File] }>()
const { t } = useI18n()

function onChange(e: Event) {
  const input = e.target as HTMLInputElement
  const file = input.files?.[0]
  if (file) emit('file', file)
  // Reset so re-selecting the same file (e.g. after a parser error) refires.
  input.value = ''
}

function onDrop(e: DragEvent) {
  e.preventDefault()
  const file = e.dataTransfer?.files?.[0]
  if (file) emit('file', file)
}
</script>

<template>
  <div class="rounded-xl border bg-card p-6 shadow-sm">
    <p class="mb-4 text-sm text-muted-foreground">{{ t('nayax.reconcile.upload.description') }}</p>
    <label
      class="flex h-40 w-full cursor-pointer items-center justify-center rounded-lg border-2 border-dashed border-muted-foreground/25 text-muted-foreground transition-colors hover:border-primary/50 hover:bg-primary/5"
      @dragover.prevent
      @drop="onDrop"
    >
      <div class="text-center">
        <span v-if="props.parsing" class="text-sm">{{ t('nayax.reconcile.upload.parsing') }}</span>
        <template v-else>
          <span class="text-sm font-medium">{{ t('nayax.reconcile.upload.dropHere') }}</span>
          <span class="mt-1 block text-xs">{{ t('nayax.reconcile.upload.supportsXlsx') }}</span>
        </template>
      </div>
      <input type="file" accept=".xlsx,.xls" class="sr-only" @change="onChange" />
    </label>
    <p v-if="props.error" class="mt-3 text-sm text-destructive">{{ t(props.error) || props.error }}</p>
  </div>
</template>
