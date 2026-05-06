<script setup lang="ts">
import { IconSparkles, IconEye, IconEyeOff, IconTrash } from '@tabler/icons-vue'

const { t } = useI18n()
const supabase = useSupabaseClient()
const { organization, role } = useOrganization()

// ── AI Insights API key (admin only) ─────────────────────────────────────
const aiKeyInput = ref('')
const aiKeyMasked = ref('')
const aiKeyHasKey = ref(false)
const aiKeyLoading = ref(false)
const aiKeyError = ref('')
const aiKeySuccess = ref('')
const aiKeyVisible = ref(false)

async function loadAiKey() {
  if (!organization.value?.id) return
  const { data } = await supabase
    .from('companies')
    .select('anthropic_api_key')
    .eq('id', organization.value.id)
    .single()
  const key = (data as any)?.anthropic_api_key
  if (key) {
    aiKeyHasKey.value = true
    aiKeyMasked.value = key.substring(0, 10) + '...' + key.substring(key.length - 4)
  } else {
    aiKeyHasKey.value = false
    aiKeyMasked.value = ''
  }
}

async function saveAiKey() {
  aiKeyError.value = ''
  aiKeySuccess.value = ''
  if (!aiKeyInput.value.trim()) {
    aiKeyError.value = t('settings.aiKeyRequired')
    return
  }
  aiKeyLoading.value = true
  try {
    const { error } = await supabase
      .from('companies')
      .update({ anthropic_api_key: aiKeyInput.value.trim() })
      .eq('id', organization.value!.id)
    if (error) throw error
    aiKeySuccess.value = t('settings.aiKeySaved')
    aiKeyInput.value = ''
    await loadAiKey()
  } catch (err: unknown) {
    aiKeyError.value = err instanceof Error ? err.message : 'Failed to save API key'
  } finally {
    aiKeyLoading.value = false
  }
}

async function removeAiKey() {
  aiKeyError.value = ''
  aiKeySuccess.value = ''
  aiKeyLoading.value = true
  try {
    const { error } = await supabase
      .from('companies')
      .update({ anthropic_api_key: null })
      .eq('id', organization.value!.id)
    if (error) throw error
    aiKeySuccess.value = t('settings.aiKeyRemoved')
    aiKeyHasKey.value = false
    aiKeyMasked.value = ''
    aiKeyInput.value = ''
  } catch (err: unknown) {
    aiKeyError.value = err instanceof Error ? err.message : 'Failed to remove API key'
  } finally {
    aiKeyLoading.value = false
  }
}

// Own watcher: only load this card's data
watch(() => organization.value?.id, (id) => {
  if (import.meta.client && id && role.value === 'admin') loadAiKey()
}, { immediate: true })
</script>

<template>
  <!-- AI Insights API Key (admin only) -->
  <div class="rounded-xl border bg-card p-6 shadow-sm">
    <div class="mb-5 flex items-center gap-2">
      <IconSparkles class="size-5 text-primary" />
      <div>
        <h2 class="text-lg font-semibold">{{ t('settings.aiInsights') }}</h2>
        <p class="text-sm text-muted-foreground">{{ t('settings.aiInsightsDescription') }}</p>
      </div>
    </div>

    <!-- Current key status -->
    <div v-if="aiKeyHasKey" class="mb-4 flex items-center justify-between rounded-lg border bg-muted/50 px-3 py-2">
      <div class="min-w-0">
        <p class="text-sm font-medium">{{ t('settings.aiKeyActive') }}</p>
        <p class="text-xs font-mono text-muted-foreground truncate">{{ aiKeyMasked }}</p>
      </div>
      <button
        :disabled="aiKeyLoading"
        class="ml-2 shrink-0 inline-flex h-7 items-center gap-1 rounded-md px-2 text-xs font-medium text-destructive transition-colors hover:bg-destructive/10 disabled:opacity-50"
        @click="removeAiKey"
      >
        <IconTrash class="size-3.5" />
        {{ t('common.remove') }}
      </button>
    </div>

    <!-- Input for new/update key -->
    <form class="space-y-3" @submit.prevent="saveAiKey">
      <div class="space-y-1">
        <label class="text-sm font-medium" for="ai-api-key">
          {{ aiKeyHasKey ? t('settings.replaceApiKey') : t('settings.enterApiKey') }}
        </label>
        <div class="relative">
          <input
            id="ai-api-key"
            v-model="aiKeyInput"
            :type="aiKeyVisible ? 'text' : 'password'"
            placeholder="sk-ant-..."
            class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 pr-9 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring font-mono"
          />
          <button
            type="button"
            class="absolute right-2 top-1/2 -translate-y-1/2 text-muted-foreground hover:text-foreground"
            @click="aiKeyVisible = !aiKeyVisible"
          >
            <IconEyeOff v-if="aiKeyVisible" class="size-4" />
            <IconEye v-else class="size-4" />
          </button>
        </div>
      </div>

      <p v-if="aiKeyError" class="text-sm text-destructive">{{ aiKeyError }}</p>
      <p v-if="aiKeySuccess" class="text-sm text-green-600">{{ aiKeySuccess }}</p>

      <button
        type="submit"
        :disabled="aiKeyLoading || !aiKeyInput.trim()"
        class="inline-flex h-9 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90 disabled:opacity-50"
      >
        <span v-if="aiKeyLoading">{{ t('common.saving') }}</span>
        <span v-else>{{ aiKeyHasKey ? t('settings.updateApiKey') : t('settings.saveApiKey') }}</span>
      </button>
    </form>
  </div>
</template>
