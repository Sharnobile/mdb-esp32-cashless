<script setup lang="ts">
import { ref, computed } from 'vue'
import { Check, ChevronsUpDown } from 'lucide-vue-next'
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

interface VM {
  id: string
  name: string | null
}

const props = defineProps<{
  modelValue: string | null
  machines: VM[]
  placeholder?: string
  disabled?: boolean
}>()

const emit = defineEmits<{ 'update:modelValue': [v: string | null] }>()

const open = ref(false)
const query = ref('')

const selected = computed(() => props.machines.find(m => m.id === props.modelValue))
const filtered = computed(() => {
  const q = query.value.trim().toLowerCase()
  if (!q) return props.machines
  return props.machines.filter(m => (m.name ?? '').toLowerCase().includes(q))
})

function pick(id: string | null) {
  emit('update:modelValue', id)
  open.value = false
  query.value = ''
}
</script>

<template>
  <Popover v-model:open="open">
    <PopoverTrigger as-child>
      <button
        type="button"
        :disabled="disabled"
        :class="cn(
          'inline-flex h-9 w-full items-center justify-between rounded-md border border-input bg-background px-3 text-sm shadow-sm transition-colors hover:bg-muted/30 disabled:opacity-50',
        )"
      >
        <span :class="selected ? '' : 'text-muted-foreground'">
          {{ selected?.name ?? placeholder ?? t('nayax.reconcile.mapping.pickMachine') }}
        </span>
        <ChevronsUpDown class="ml-2 h-4 w-4 opacity-50" />
      </button>
    </PopoverTrigger>
    <PopoverContent class="w-[--reka-popover-trigger-width] p-0">
      <Command v-model:search-term="query">
        <CommandInput :placeholder="t('nayax.reconcile.mapping.searchMachine')" />
        <CommandList>
          <CommandEmpty>{{ t('nayax.reconcile.mapping.noMatch') }}</CommandEmpty>
          <CommandGroup>
            <CommandItem
              v-for="m in filtered"
              :key="m.id"
              :value="m.id"
              @select="pick(m.id)"
            >
              <Check :class="cn('mr-2 h-4 w-4', modelValue === m.id ? 'opacity-100' : 'opacity-0')" />
              {{ m.name ?? '—' }}
            </CommandItem>
            <CommandItem value="__skip" @select="pick(null)">
              <span class="text-muted-foreground italic">{{ t('nayax.reconcile.mapping.skipForRun') }}</span>
            </CommandItem>
          </CommandGroup>
        </CommandList>
      </Command>
    </PopoverContent>
  </Popover>
</template>
