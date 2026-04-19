<script setup lang="ts">
import { ref } from 'vue'
import { Plus, Pencil, Trash2 } from 'lucide-vue-next'
import { Button } from '@/components/ui/button'
import Badge from '@/components/ui/badge/Badge.vue'
import DealKeywordModal from './DealKeywordModal.vue'
import type { DealKeyword } from '@/composables/useDeals'

const { t } = useI18n()
const { keywords, fetchKeywords, createKeyword, updateKeyword, setKeywordProducts, deleteKeyword } = useDeals()

const open = ref(false)
const editing = ref<DealKeyword | null>(null)

onMounted(() => { fetchKeywords() })

function openNew() {
  editing.value = null
  open.value = true
}

function openEdit(k: DealKeyword) {
  editing.value = k
  open.value = true
}

async function onSave(payload: { id?: string; label: string | null; terms: string[]; product_ids: string[] }) {
  if (payload.id) {
    await updateKeyword(payload.id, { label: payload.label, terms: payload.terms })
    await setKeywordProducts(payload.id, payload.product_ids)
  } else {
    await createKeyword({ label: payload.label, terms: payload.terms, product_ids: payload.product_ids })
  }
}

async function onDelete(k: DealKeyword) {
  if (!confirm(t('deals.keywords.deleteConfirm', { label: k.label ?? k.terms[0] }))) return
  await deleteKeyword(k.id)
}

function displayName(k: DealKeyword): string {
  return k.label?.trim() || k.terms[0] || '—'
}

function termsPreview(k: DealKeyword): string {
  const first = k.terms.slice(0, 3).join(', ')
  const extra = k.terms.length - 3
  return extra > 0 ? `${first} +${extra}` : first
}
</script>

<template>
  <div class="space-y-4">
    <div class="flex items-center justify-between">
      <h2 class="text-lg font-semibold">{{ t('deals.keywords.title') }}</h2>
      <Button @click="openNew">
        <Plus class="mr-1 size-4" />
        {{ t('deals.keywords.newGroup') }}
      </Button>
    </div>

    <div v-if="!keywords.length" class="rounded-md border border-dashed p-8 text-center text-muted-foreground">
      <p class="mb-1 font-medium">{{ t('deals.keywords.emptyTitle') }}</p>
      <p class="text-sm">{{ t('deals.keywords.emptyHint') }}</p>
    </div>

    <ul v-else class="divide-y rounded-md border">
      <li
        v-for="k in keywords"
        :key="k.id"
        class="flex items-center justify-between gap-3 p-3"
      >
        <div class="min-w-0 flex-1">
          <div class="font-medium">{{ displayName(k) }}</div>
          <div class="truncate text-sm text-muted-foreground">{{ termsPreview(k) }}</div>
        </div>
        <Badge variant="secondary">
          {{ t('deals.keywords.productsCount', { n: k.product_ids.length }) }}
        </Badge>
        <Button variant="ghost" size="icon" @click="openEdit(k)">
          <Pencil class="size-4" />
        </Button>
        <Button variant="ghost" size="icon" @click="onDelete(k)">
          <Trash2 class="size-4 text-destructive" />
        </Button>
      </li>
    </ul>

    <DealKeywordModal v-model:open="open" :editing="editing" @save="onSave" />
  </div>
</template>
