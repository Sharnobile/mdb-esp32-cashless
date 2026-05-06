<script setup lang="ts">
import { ref, watch } from 'vue'
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle, DialogDescription } from '~/components/ui/dialog'
import { Input } from '~/components/ui/input'
import { Label } from '~/components/ui/label'
import { Button } from '~/components/ui/button'

const props = defineProps<{
  open: boolean
  /** When set, dialog opens in "edit existing" mode and submits via update() */
  existing?: {
    providerId: string
    displayName: string
    url: string
    authToken: string
    extraConfigJson: string
  }
}>()

const emit = defineEmits<{
  (e: 'update:open', v: boolean): void
  (e: 'submit', payload: {
    providerId?: string
    displayName: string
    url: string
    authToken: string
    extraConfig: Record<string, unknown>
  }): void
}>()

const { t } = useI18n()

const displayName = ref('')
const url         = ref('')
const authToken   = ref('')
const extraConfig = ref('{}')
const error       = ref('')

// When the dialog opens with `existing`, hydrate the fields. Reset when closed.
watch(() => props.open, (isOpen) => {
  if (isOpen) {
    displayName.value = props.existing?.displayName ?? ''
    url.value         = props.existing?.url ?? ''
    authToken.value   = props.existing?.authToken ?? ''
    extraConfig.value = props.existing?.extraConfigJson ?? '{}'
    error.value = ''
  }
})

function onSubmit() {
  error.value = ''
  if (!displayName.value.trim()) { error.value = t('extensions.errors.nameRequired'); return }
  if (!url.value.startsWith('https://')) { error.value = t('extensions.errors.httpsRequired'); return }
  if (!authToken.value) { error.value = t('extensions.errors.tokenRequired'); return }
  let parsed: Record<string, unknown> = {}
  try {
    parsed = JSON.parse(extraConfig.value || '{}')
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) throw new Error('not an object')
  } catch {
    error.value = t('extensions.errors.configJsonInvalid')
    return
  }
  emit('submit', {
    providerId: props.existing?.providerId,
    displayName: displayName.value.trim(),
    url: url.value.trim(),
    authToken: authToken.value,
    extraConfig: parsed,
  })
  emit('update:open', false)
}
</script>

<template>
  <Dialog :open="open" @update:open="(v: boolean) => emit('update:open', v)">
    <DialogContent class="sm:max-w-md">
      <DialogHeader>
        <DialogTitle>{{ existing ? t('extensions.webhook.editTitle') : t('extensions.webhook.addTitle') }}</DialogTitle>
        <DialogDescription>{{ t('extensions.webhook.help') }}</DialogDescription>
      </DialogHeader>

      <div class="space-y-3 py-2">
        <div class="space-y-1.5">
          <Label for="webhook-name">{{ t('extensions.webhook.name') }}</Label>
          <Input id="webhook-name" v-model="displayName" autofocus />
        </div>

        <div class="space-y-1.5">
          <Label for="webhook-url">{{ t('extensions.webhook.url') }}</Label>
          <Input id="webhook-url" v-model="url" placeholder="https://..." />
        </div>

        <div class="space-y-1.5">
          <Label for="webhook-token">{{ t('extensions.webhook.authToken') }}</Label>
          <Input id="webhook-token" v-model="authToken" type="password" />
        </div>

        <div class="space-y-1.5">
          <Label for="webhook-config">{{ t('extensions.webhook.extraConfig') }}</Label>
          <textarea
            id="webhook-config"
            v-model="extraConfig"
            rows="3"
            class="w-full rounded-md border bg-background px-3 py-2 font-mono text-sm"
          />
        </div>

        <p v-if="error" class="text-sm text-destructive">{{ error }}</p>
      </div>

      <DialogFooter>
        <Button variant="outline" @click="emit('update:open', false)">{{ t('common.cancel') }}</Button>
        <Button @click="onSubmit">{{ t('common.save') }}</Button>
      </DialogFooter>
    </DialogContent>
  </Dialog>
</template>
