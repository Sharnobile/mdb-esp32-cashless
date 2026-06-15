<script setup lang="ts">
import { ref, computed } from 'vue'
import { Check, ChevronsUpDown, Plus } from 'lucide-vue-next'
import {
  Command,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
} from '@/components/ui/command'
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from '@/components/ui/popover'
import { cn } from '@/lib/utils'

const { t } = useI18n()

interface Product {
  id: string
  name: string
  image_path?: string | null
  image_url?: string | null
}

const props = withDefaults(
  defineProps<{
    modelValue: string | null
    products: Product[]
    placeholder?: string
    allowCreate?: boolean
    disabled?: boolean
  }>(),
  {
    placeholder: '',
    allowCreate: false,
    disabled: false,
  },
)

const emit = defineEmits<{
  'update:modelValue': [id: string | null]
  'create': [query: string]
  'select': [id: string | null]
}>()

const open = ref(false)
const searchQuery = ref('')

// IMPORTANT: this repo's <Command> is built on reka-ui ListboxRoot, which has NO
// `searchTerm` v-model (the search lives in the Command's internal filterState,
// fed by ListboxFilter inside CommandInput). So we capture the typed text from
// CommandInput's `update:model-value` event instead of a (non-existent) model.
function onSearch(value: string | number | null | undefined) {
  searchQuery.value = value == null ? '' : String(value)
}

const selectedProduct = computed(() =>
  props.products.find((p) => p.id === props.modelValue),
)

// Offer "create" when enabled and the typed text isn't an exact (case-insensitive)
// match of an existing product. Rendered as a plain button (NOT a CommandItem)
// because CommandItem filters by its mount-time textContent, which would hide a
// dynamic-label create row as the query grows.
const showCreate = computed(() => {
  if (!props.allowCreate) return false
  const q = searchQuery.value.trim()
  if (!q) return false
  return !props.products.some((p) => p.name.trim().toLowerCase() === q.toLowerCase())
})

function selectProduct(id: string | null) {
  emit('update:modelValue', id)
  emit('select', id)
  open.value = false
}

function requestCreate() {
  const q = searchQuery.value.trim()
  if (!q) return
  emit('create', q)
  searchQuery.value = ''
  open.value = false
}
</script>

<template>
  <Popover v-model:open="open">
    <PopoverTrigger as-child>
      <button
        role="combobox"
        :aria-expanded="open"
        :disabled="disabled"
        :class="cn(
          'flex h-9 w-full items-center justify-between rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm hover:bg-accent hover:text-accent-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring disabled:cursor-not-allowed disabled:opacity-50',
        )"
      >
        <span class="flex items-center gap-2 truncate" :class="{ 'text-muted-foreground': !selectedProduct }">
          <img
            v-if="selectedProduct?.image_url"
            :src="selectedProduct.image_url"
            :alt="selectedProduct.name"
            class="h-5 w-5 shrink-0 rounded object-cover"
          />
          {{ selectedProduct?.name || placeholder }}
        </span>
        <ChevronsUpDown class="ml-2 size-4 shrink-0 opacity-50" />
      </button>
    </PopoverTrigger>
    <PopoverContent class="w-[--reka-popover-trigger-width] p-0" align="start">
      <Command>
        <CommandInput :placeholder="placeholder" @update:model-value="onSearch" />
        <CommandList>
          <CommandEmpty v-if="!showCreate">
            <span class="text-muted-foreground text-sm">{{ t('common.noResults') }}</span>
          </CommandEmpty>
          <CommandGroup>
            <CommandItem
              value="__none__"
              @select="selectProduct(null)"
            >
              <Check :class="cn('mr-2 size-4', modelValue ? 'opacity-0' : 'opacity-100')" />
              <span class="text-muted-foreground">{{ t('machineDetail.none') }}</span>
            </CommandItem>
            <CommandItem
              v-for="product in products"
              :key="product.id"
              :value="product.name"
              @select="selectProduct(product.id)"
            >
              <Check :class="cn('mr-2 size-4', modelValue === product.id ? 'opacity-100' : 'opacity-0')" />
              <img
                v-if="product.image_url"
                :src="product.image_url"
                :alt="product.name"
                class="mr-2 h-6 w-6 shrink-0 rounded object-cover"
              />
              <div v-else class="mr-2 h-6 w-6 shrink-0 rounded bg-muted" />
              {{ product.name }}
            </CommandItem>
          </CommandGroup>
          <!-- Create action: a plain button (NOT a CommandItem) so reka's
               textContent-based filter can't hide it as the query grows. -->
          <button
            v-if="showCreate"
            type="button"
            data-testid="create-product"
            class="relative flex w-full cursor-pointer items-center gap-2 rounded-sm px-2 py-1.5 text-left text-sm outline-none hover:bg-accent hover:text-accent-foreground"
            @click="requestCreate"
          >
            <Plus class="size-4 shrink-0" />
            {{ t('warehouse.createNewProduct', { name: searchQuery.trim() }) }}
          </button>
        </CommandList>
      </Command>
    </PopoverContent>
  </Popover>
</template>
