<script setup lang="ts">
import { ref, watch } from 'vue'
import { useI18n } from '#imports'
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
} from '~/components/ui/dialog'
import { IconTrash } from '@tabler/icons-vue'
import LocationPicker, { type LocationModel } from '~/components/LocationPicker.vue'
import { useMachines, type MachineSettingsPatch } from '~/composables/useMachines'
import { COUNTRY_OPTIONS } from '~/composables/useTaxSettings'

const props = defineProps<{
  open: boolean
  machineId: string
  initial: Partial<LocationModel>
}>()

const emit = defineEmits<{
  (e: 'update:open', value: boolean): void
  (e: 'saved'): void
}>()

const { t } = useI18n()
const { updateMachineSettings } = useMachines()

const form = ref<LocationModel>(cloneInitial())
const saving = ref(false)
const errorMsg = ref<string | null>(null)

function cloneInitial(): LocationModel {
  return {
    location_lat: props.initial.location_lat ?? null,
    location_lon: props.initial.location_lon ?? null,
    address_street: props.initial.address_street ?? null,
    address_house_number: props.initial.address_house_number ?? null,
    address_postal_code: props.initial.address_postal_code ?? null,
    address_city: props.initial.address_city ?? null,
    formatted_address: props.initial.formatted_address ?? null,
    country_code: props.initial.country_code ?? null,
  }
}

// Reset the form every time the modal opens fresh
watch(
  () => props.open,
  (isOpen) => {
    if (isOpen) {
      form.value = cloneInitial()
      errorMsg.value = null
    }
  },
)

async function save() {
  saving.value = true
  errorMsg.value = null
  try {
    await updateMachineSettings(props.machineId, form.value as MachineSettingsPatch)
    emit('saved')
    emit('update:open', false)
  } catch (err) {
    errorMsg.value = (err as Error).message ?? 'Unknown error'
  } finally {
    saving.value = false
  }
}

function clearLocation() {
  form.value.location_lat = null
  form.value.location_lon = null
  form.value.address_street = null
  form.value.address_house_number = null
  form.value.address_postal_code = null
  form.value.address_city = null
  form.value.formatted_address = null
  form.value.country_code = null
}

function cancel() {
  emit('update:open', false)
}
</script>

<template>
  <Dialog :open="open" @update:open="(v) => emit('update:open', v)">
    <DialogContent class="max-h-[90vh] overflow-y-auto sm:max-w-2xl">
      <DialogHeader>
        <DialogTitle>{{ t('machineSettings.title') }}</DialogTitle>
      </DialogHeader>

      <div class="flex flex-col gap-4 py-2">
        <ClientOnly>
          <LocationPicker v-model="form" />
          <template #fallback>
            <div class="flex h-[200px] w-full items-center justify-center rounded-md border border-dashed text-sm text-muted-foreground">
              {{ t('machineSettings.mapLoading') }}
            </div>
          </template>
        </ClientOnly>

        <!-- Country code override -->
        <div>
          <label class="text-xs font-medium text-muted-foreground">{{ t('machineSettings.country') }}</label>
          <select
            v-model="form.country_code"
            class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          >
            <option :value="null">—</option>
            <option v-for="c in COUNTRY_OPTIONS" :key="c.code" :value="c.code">
              {{ c.code }} — {{ c.label }}
            </option>
          </select>
          <p class="mt-1 text-[10px] text-muted-foreground">{{ t('machineSettings.countryAutoHint') }}</p>
        </div>

        <p v-if="errorMsg" class="text-xs text-destructive">{{ errorMsg }}</p>
      </div>

      <DialogFooter class="flex items-center justify-between gap-2 sm:justify-between">
        <button
          v-if="form.location_lat != null"
          type="button"
          class="inline-flex items-center gap-1 text-xs text-destructive hover:underline"
          :disabled="saving"
          @click="clearLocation"
        >
          <IconTrash class="size-3.5" />
          {{ t('machineSettings.clearLocation') }}
        </button>
        <div v-else />
        <div class="flex gap-2">
          <button
            type="button"
            class="h-9 rounded-md border border-input bg-background px-4 text-sm font-medium shadow-sm hover:bg-accent"
            :disabled="saving"
            @click="cancel"
          >
            {{ t('machineSettings.cancel') }}
          </button>
          <button
            type="button"
            class="h-9 rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow hover:bg-primary/90 disabled:opacity-50"
            :disabled="saving"
            @click="save"
          >
            {{ t('machineSettings.save') }}
          </button>
        </div>
      </DialogFooter>
    </DialogContent>
  </Dialog>
</template>
