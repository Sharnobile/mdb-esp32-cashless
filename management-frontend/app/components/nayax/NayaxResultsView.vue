<script setup lang="ts">
// Temporary placeholder. The real reconciliation results UI is delivered in
// Chunk 6 — see the Nayax Sales Reconciliation plan. This stub exists only so
// the wizard page compiles while Chunks 5 and 6 land separately.
defineProps<{ isAdmin: boolean }>()
defineEmits<{ restart: []; rerun: []; 'go-to-mapping': [] }>()
</script>

<template>
  <div class="rounded-xl border bg-card p-6 shadow-sm text-sm text-muted-foreground">
    Results coming in Chunk 6
  </div>
</template>
