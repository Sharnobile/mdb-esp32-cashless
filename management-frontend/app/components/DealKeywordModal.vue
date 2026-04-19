<script setup lang="ts">
import { ref, watch } from 'vue'
import { X } from 'lucide-vue-next'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import Badge from '@/components/ui/badge/Badge.vue'
import MultiProductCombobox from './MultiProductCombobox.vue'
import type { DealKeyword } from '@/composables/useDeals'

const { t } = useI18n()

const props = defineProps<{
  open: boolean
  editing: DealKeyword | null
}>()

const emit = defineEmits<{
  'update:open': [value: boolean]
  save: [payload: { id?: string; label: string | null; terms: string[]; product_ids: string[] }]
}>()

// CORRECTED: getProductImageUrl is a module-level export, not part of the
// composable return — and products already carry a precomputed image_url,
// so we don't need it here.
const { products, fetchProducts } = useProducts()

const label = ref('')
const termDraft = ref('')
const terms = ref<string[]>([])
const productIds = ref<string[]>([])
const submitting = ref(false)

// Hydrate form when the modal opens (or when editing target changes)
watch(
  () => [props.open, props.editing] as const,
  async ([open, editing]) => {
    if (!open) return
    if (!products.value.length) await fetchProducts()
    if (editing) {
      label.value = editing.label ?? ''
      terms.value = [...editing.terms]
      productIds.value = [...editing.product_ids]
    } else {
      label.value = ''
      terms.value = []
      productIds.value = []
    }
    termDraft.value = ''
  },
  { immediate: true },
)

// CORRECTED: products already carry image_url — just pass it through.
const productsForCombobox = computed(() =>
  products.value.map((p: any) => ({
    id: p.id,
    name: p.name,
    image_url: p.image_url ?? null,
  })),
)

function addTerm() {
  const t = termDraft.value.trim()
  if (!t) return
  if (!terms.value.includes(t)) terms.value.push(t)
  termDraft.value = ''
}

function onTermKeydown(e: KeyboardEvent) {
  if (e.key === 'Enter' || e.key === ',') {
    e.preventDefault()
    addTerm()
  }
}

function removeTerm(t: string) {
  terms.value = terms.value.filter((x) => x !== t)
}

async function onSave() {
  if (terms.value.length === 0) return
  submitting.value = true
  try {
    emit('save', {
      id: props.editing?.id,
      label: label.value.trim() || null,
      terms: [...terms.value],
      product_ids: [...productIds.value],
    })
    emit('update:open', false)
  } finally {
    submitting.value = false
  }
}
</script>

<template>
  <Dialog :open="open" @update:open="(v) => emit('update:open', v)">
    <DialogContent class="sm:max-w-lg">
      <DialogHeader>
        <DialogTitle>
          {{ editing ? t('deals.keywords.editGroup') : t('deals.keywords.newGroup') }}
        </DialogTitle>
        <DialogDescription>{{ t('deals.keywords.modalHint') }}</DialogDescription>
      </DialogHeader>

      <div class="grid gap-4 py-2">
        <div class="grid gap-2">
          <Label for="kw-label">{{ t('deals.keywords.label') }}</Label>
          <Input id="kw-label" v-model="label" :placeholder="t('deals.keywords.labelPlaceholder')" />
        </div>

        <div class="grid gap-2">
          <Label for="kw-terms">{{ t('deals.keywords.terms') }}</Label>
          <Input
            id="kw-terms"
            v-model="termDraft"
            :placeholder="t('deals.keywords.termsHint')"
            @keydown="onTermKeydown"
            @blur="addTerm"
          />
          <div v-if="terms.length" class="flex flex-wrap gap-1">
            <Badge v-for="term in terms" :key="term" variant="secondary" class="gap-1">
              {{ term }}
              <span
                role="button"
                class="ml-1 rounded-sm opacity-70 hover:opacity-100"
                @click="removeTerm(term)"
              >
                <X class="size-3" />
              </span>
            </Badge>
          </div>
        </div>

        <div class="grid gap-2">
          <Label>{{ t('deals.keywords.products') }}</Label>
          <MultiProductCombobox
            v-model="productIds"
            :products="productsForCombobox"
            :placeholder="t('deals.keywords.productsPlaceholder')"
          />
        </div>
      </div>

      <DialogFooter>
        <Button variant="outline" @click="emit('update:open', false)">{{ t('common.cancel') }}</Button>
        <Button :disabled="terms.length === 0 || submitting" @click="onSave">
          {{ t('common.save') }}
        </Button>
      </DialogFooter>
    </DialogContent>
  </Dialog>
</template>
