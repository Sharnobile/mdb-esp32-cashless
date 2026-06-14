<script setup lang="ts">
import { ref } from 'vue'
import { Check, ChevronsUpDown, Plus } from 'lucide-vue-next'
import {
  Command, CommandEmpty, CommandGroup, CommandInput, CommandItem, CommandList,
} from '@/components/ui/command'
import { Popover, PopoverContent, PopoverTrigger } from '@/components/ui/popover'
import { cn } from '@/lib/utils'

const { t } = useI18n()

interface Supplier { id: string; name: string }

const props = withDefaults(
  defineProps<{ modelValue: string; suppliers: Supplier[]; placeholder?: string; disabled?: boolean }>(),
  { placeholder: '', disabled: false },
)
const emit = defineEmits<{ 'update:modelValue': [name: string] }>()

const open = ref(false)
const searchQuery = ref('')

function pick(name: string) {
  emit('update:modelValue', name)
  open.value = false
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
        :class="cn('flex h-9 w-full items-center justify-between rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm hover:bg-accent hover:text-accent-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring disabled:cursor-not-allowed disabled:opacity-50')"
      >
        <span class="truncate" :class="{ 'text-muted-foreground': !modelValue }">{{ modelValue || placeholder }}</span>
        <ChevronsUpDown class="ml-2 size-4 shrink-0 opacity-50" />
      </button>
    </PopoverTrigger>
    <PopoverContent class="w-[--reka-popover-trigger-width] p-0" align="start">
      <Command v-model:search-term="searchQuery">
        <CommandInput :placeholder="placeholder" />
        <CommandList>
          <CommandEmpty>
            <span class="text-muted-foreground text-sm">{{ t('common.noResults') }}</span>
          </CommandEmpty>
          <CommandGroup>
            <CommandItem v-for="s in suppliers" :key="s.id" :value="s.name" @select="pick(s.name)">
              <Check :class="cn('mr-2 size-4', modelValue === s.name ? 'opacity-100' : 'opacity-0')" />
              {{ s.name }}
            </CommandItem>
          </CommandGroup>
          <CommandGroup v-if="searchQuery.trim()">
            <CommandItem :value="searchQuery" @select="pick(searchQuery.trim())">
              <Plus class="mr-2 size-4" />
              {{ t('purchasePrices.useSupplier', { name: searchQuery.trim() }) }}
            </CommandItem>
          </CommandGroup>
        </CommandList>
      </Command>
    </PopoverContent>
  </Popover>
</template>
