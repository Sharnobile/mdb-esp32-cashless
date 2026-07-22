<script setup lang="ts">
import { ref, computed } from 'vue'
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

// IMPORTANT: this repo's <Command> is built on reka-ui ListboxRoot, which has NO
// `searchTerm` v-model (the search lives in the Command's internal filterState,
// fed by ListboxFilter inside CommandInput). So we capture the typed text from
// CommandInput's `update:model-value` event instead of a (non-existent) model.
function onSearch(value: string | number | null | undefined) {
  searchQuery.value = value == null ? '' : String(value)
}

// True once the typed text is an exact (case-insensitive) match of an existing
// supplier — no point offering to create a duplicate.
const exactMatch = computed(() => {
  const q = searchQuery.value.trim().toLowerCase()
  if (!q) return false
  return props.suppliers.some((s) => s.name.trim().toLowerCase() === q)
})
// There's an actual name to create (same condition the button used to be
// entirely hidden behind). Rendered as a plain button (NOT a CommandItem)
// because CommandItem filters by its mount-time textContent, which would hide
// a dynamic-label create row as the query grows.
const canCreate = computed(() => searchQuery.value.trim().length > 0 && !exactMatch.value)

function pick(name: string) {
  const v = name.trim()
  if (!v) return
  emit('update:modelValue', v)
  searchQuery.value = ''
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
      <Command>
        <CommandInput :placeholder="placeholder" @update:model-value="onSearch" />
        <CommandList>
          <CommandEmpty v-if="!canCreate">
            <span class="text-muted-foreground text-sm">{{ t('common.noResults') }}</span>
          </CommandEmpty>
          <CommandGroup>
            <CommandItem v-for="s in suppliers" :key="s.id" :value="s.name" @select="pick(s.name)">
              <Check :class="cn('mr-2 size-4', modelValue === s.name ? 'opacity-100' : 'opacity-0')" />
              {{ s.name }}
            </CommandItem>
          </CommandGroup>
          <!-- Create action: a plain button (NOT a CommandItem) so reka's
               textContent-based filter can't hide it as the query grows.
               Shown as soon as the popover opens (disabled, as a hint) rather
               than only after typing a non-matching name — otherwise nothing
               here suggests you can add a new supplier at all. -->
          <button
            v-if="!exactMatch"
            type="button"
            data-testid="create-supplier"
            :disabled="!canCreate"
            class="relative flex w-full items-center gap-2 rounded-sm px-2 py-1.5 text-left text-sm outline-none hover:bg-accent hover:text-accent-foreground disabled:cursor-default disabled:opacity-60 disabled:hover:bg-transparent"
            @click="canCreate && pick(searchQuery)"
          >
            <Plus class="size-4 shrink-0" />
            {{ canCreate ? t('purchasePrices.useSupplier', { name: searchQuery.trim() }) : t('purchasePrices.typeToCreateHint') }}
          </button>
        </CommandList>
      </Command>
    </PopoverContent>
  </Popover>
</template>
