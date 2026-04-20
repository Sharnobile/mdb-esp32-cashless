<script setup lang="ts">
import { ref, computed } from 'vue'
import { Check, ChevronsUpDown, X } from 'lucide-vue-next'
import {
  Command,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandList,
} from '@/components/ui/command'
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from '@/components/ui/popover'
import Badge from '@/components/ui/badge/Badge.vue'
import MultiProductCommandItem from './MultiProductCommandItem.vue'
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
    modelValue: string[]
    products: Product[]
    placeholder?: string
    disabled?: boolean
  }>(),
  { placeholder: '', disabled: false },
)

const emit = defineEmits<{
  'update:modelValue': [ids: string[]]
}>()

const open = ref(false)

const selectedSet = computed(() => new Set(props.modelValue))
const selectedProducts = computed(() =>
  props.products.filter((p) => selectedSet.value.has(p.id)),
)

function toggle(id: string) {
  const next = new Set(selectedSet.value)
  if (next.has(id)) next.delete(id)
  else next.add(id)
  emit('update:modelValue', Array.from(next))
}

function removeAt(id: string, event: Event) {
  event.stopPropagation()
  emit('update:modelValue', props.modelValue.filter((v) => v !== id))
}
</script>

<template>
  <Popover v-model:open="open">
    <PopoverTrigger as-child>
      <button
        type="button"
        role="combobox"
        :aria-expanded="open"
        :disabled="disabled"
        :class="cn(
          'flex min-h-9 w-full items-center justify-between gap-2 rounded-md border border-input bg-background px-3 py-1.5 text-sm shadow-sm hover:bg-accent/50 focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring disabled:cursor-not-allowed disabled:opacity-50',
        )"
      >
        <div class="flex flex-1 flex-wrap gap-1">
          <template v-if="selectedProducts.length === 0">
            <span class="text-muted-foreground">{{ placeholder }}</span>
          </template>
          <template v-else>
            <Badge
              v-for="product in selectedProducts"
              :key="product.id"
              variant="secondary"
              class="gap-1"
            >
              {{ product.name }}
              <span
                role="button"
                tabindex="-1"
                class="ml-1 rounded-sm opacity-70 hover:opacity-100"
                @click="(e) => removeAt(product.id, e)"
              >
                <X class="size-3" />
              </span>
            </Badge>
          </template>
        </div>
        <ChevronsUpDown class="size-4 shrink-0 opacity-50" />
      </button>
    </PopoverTrigger>
    <PopoverContent class="w-[--reka-popover-trigger-width] p-0" align="start">
      <Command>
        <CommandInput :placeholder="placeholder" />
        <CommandList>
          <CommandEmpty>
            <span class="text-muted-foreground text-sm">{{ t('common.noResults') }}</span>
          </CommandEmpty>
          <CommandGroup>
            <MultiProductCommandItem
              v-for="product in products"
              :key="product.id"
              :value="product.name"
              @select="toggle(product.id)"
            >
              <Check
                :class="cn('mr-2 size-4', selectedSet.has(product.id) ? 'opacity-100' : 'opacity-0')"
              />
              <img
                v-if="product.image_url"
                :src="product.image_url"
                :alt="product.name"
                class="mr-2 h-6 w-6 shrink-0 rounded object-cover"
              />
              <div v-else class="mr-2 h-6 w-6 shrink-0 rounded bg-muted" />
              {{ product.name }}
            </MultiProductCommandItem>
          </CommandGroup>
        </CommandList>
      </Command>
    </PopoverContent>
  </Popover>
</template>
