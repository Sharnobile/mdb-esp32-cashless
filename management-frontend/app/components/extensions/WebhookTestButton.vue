<script setup lang="ts">
import { ref } from 'vue'
import { Button } from '~/components/ui/button'
import { IconCheck, IconAlertTriangle, IconLoader2 } from '@tabler/icons-vue'

const props = defineProps<{
  extensionPoint: 'deal-source'
  url: string
  authToken: string
}>()

const { t } = useI18n()
const supabase = useSupabaseClient()

type Status = 'idle' | 'loading' | 'success' | 'error'
const status  = ref<Status>('idle')
const message = ref('')

async function run() {
  status.value = 'loading'
  message.value = ''
  try {
    const { data, error } = await supabase.functions.invoke('provider-test', {
      body: {
        extensionPoint: props.extensionPoint,
        url: props.url,
        authToken: props.authToken,
      },
    })
    if (error) throw error
    if (data.ok) {
      status.value = 'success'
      message.value = t('extensions.testResultOk', { count: data.sampleSize ?? 0 })
    } else {
      status.value = 'error'
      message.value = data.error ?? t('extensions.testResultUnknownError')
    }
  } catch (err) {
    status.value = 'error'
    message.value = err instanceof Error ? err.message : String(err)
  }
}
</script>

<template>
  <div class="flex items-center gap-2">
    <Button size="sm" variant="outline" :disabled="status === 'loading'" @click="run">
      <IconLoader2 v-if="status === 'loading'" class="size-4 animate-spin" />
      <IconCheck   v-else-if="status === 'success'" class="size-4 text-green-600" />
      <IconAlertTriangle v-else-if="status === 'error'" class="size-4 text-destructive" />
      {{ t('extensions.testCall') }}
    </Button>
    <span
      v-if="message"
      class="text-xs"
      :class="status === 'success' ? 'text-green-700 dark:text-green-400' : 'text-destructive'"
    >{{ message }}</span>
  </div>
</template>
