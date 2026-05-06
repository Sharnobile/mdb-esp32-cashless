<script setup lang="ts">
import { IconCreditCard, IconCopy, IconEye, IconEyeOff, IconTrash } from '@tabler/icons-vue'

const { t } = useI18n()
const supabase = useSupabaseClient()
const { organization, role } = useOrganization()

// ── Stripe API keys (admin only) ────────────────────────────────────────────
const stripeSecretInput = ref('')
const stripePubInput = ref('')
const stripeWebhookInput = ref('')
const stripeSecretMasked = ref('')
const stripePubMasked = ref('')
const stripeWebhookMasked = ref('')
const stripeHasKeys = ref(false)
const stripeLoading = ref(false)
const stripeError = ref('')
const stripeSuccess = ref('')
const stripeSecretVisible = ref(false)

function maskKey(key: string) {
  if (!key || key.length < 14) return key
  return key.substring(0, 10) + '...' + key.substring(key.length - 4)
}

async function loadStripeKeys() {
  if (!organization.value?.id) return
  const { data } = await supabase
    .from('companies')
    .select('stripe_secret_key, stripe_publishable_key, stripe_webhook_secret')
    .eq('id', organization.value.id)
    .single()
  const d = data as any
  if (d?.stripe_secret_key) {
    stripeHasKeys.value = true
    stripeSecretMasked.value = maskKey(d.stripe_secret_key)
    stripePubMasked.value = maskKey(d.stripe_publishable_key || '')
    stripeWebhookMasked.value = maskKey(d.stripe_webhook_secret || '')
  } else {
    stripeHasKeys.value = false
    stripeSecretMasked.value = ''
    stripePubMasked.value = ''
    stripeWebhookMasked.value = ''
  }
}

async function saveStripeKeys() {
  stripeError.value = ''
  stripeSuccess.value = ''
  if (!stripeSecretInput.value.trim() || !stripePubInput.value.trim()) {
    stripeError.value = t('settings.stripeKeysRequired')
    return
  }
  stripeLoading.value = true
  try {
    const update: Record<string, string | null> = {
      stripe_secret_key: stripeSecretInput.value.trim(),
      stripe_publishable_key: stripePubInput.value.trim(),
    }
    if (stripeWebhookInput.value.trim()) {
      update.stripe_webhook_secret = stripeWebhookInput.value.trim()
    }
    const { error } = await supabase
      .from('companies')
      .update(update)
      .eq('id', organization.value!.id)
    if (error) throw error
    stripeSuccess.value = t('settings.stripeSaved')
    stripeSecretInput.value = ''
    stripePubInput.value = ''
    stripeWebhookInput.value = ''
    await loadStripeKeys()
  } catch (err: unknown) {
    stripeError.value = err instanceof Error ? err.message : 'Failed to save Stripe keys'
  } finally {
    stripeLoading.value = false
  }
}

async function removeStripeKeys() {
  stripeError.value = ''
  stripeSuccess.value = ''
  stripeLoading.value = true
  try {
    const { error } = await supabase
      .from('companies')
      .update({ stripe_secret_key: null, stripe_publishable_key: null, stripe_webhook_secret: null })
      .eq('id', organization.value!.id)
    if (error) throw error
    stripeSuccess.value = t('settings.stripeRemoved')
    stripeHasKeys.value = false
    stripeSecretMasked.value = ''
    stripePubMasked.value = ''
    stripeWebhookMasked.value = ''
  } catch (err: unknown) {
    stripeError.value = err instanceof Error ? err.message : 'Failed to remove Stripe keys'
  } finally {
    stripeLoading.value = false
  }
}

const stripeWebhookUrl = computed(() => {
  if (!organization.value?.id) return ''
  const base = useRuntimeConfig().public.supabase?.url || 'http://127.0.0.1:54321'
  return `${base}/functions/v1/stripe-webhook?company_id=${organization.value.id}`
})

// Own watcher: only load this card's data
watch(() => organization.value?.id, (id) => {
  if (import.meta.client && id && role.value === 'admin') loadStripeKeys()
}, { immediate: true })
</script>

<template>
  <!-- Stripe Payment Keys (admin only) -->
  <div class="rounded-xl border bg-card p-6 shadow-sm">
    <div class="mb-5 flex items-center gap-2">
      <IconCreditCard class="size-5 text-primary" />
      <div>
        <h2 class="text-lg font-semibold">{{ t('settings.stripeSection') }}</h2>
        <p class="text-sm text-muted-foreground">{{ t('settings.stripeDescription') }}</p>
      </div>
    </div>

    <!-- Current keys status -->
    <div v-if="stripeHasKeys" class="mb-4 space-y-2">
      <div class="flex items-center justify-between rounded-lg border bg-muted/50 px-3 py-2">
        <div class="min-w-0 flex-1">
          <p class="text-sm font-medium">{{ t('settings.stripeActive') }}</p>
          <p class="text-xs font-mono text-muted-foreground truncate">Secret: {{ stripeSecretMasked }}</p>
          <p class="text-xs font-mono text-muted-foreground truncate">Publishable: {{ stripePubMasked }}</p>
          <p v-if="stripeWebhookMasked" class="text-xs font-mono text-muted-foreground truncate">Webhook: {{ stripeWebhookMasked }}</p>
        </div>
        <button
          :disabled="stripeLoading"
          class="ml-2 shrink-0 inline-flex h-7 items-center gap-1 rounded-md px-2 text-xs font-medium text-destructive transition-colors hover:bg-destructive/10 disabled:opacity-50"
          @click="removeStripeKeys"
        >
          <IconTrash class="size-3.5" />
          {{ t('common.remove') }}
        </button>
      </div>

      <!-- Webhook URL (read-only) -->
      <div class="rounded-lg border bg-muted/50 px-3 py-2">
        <p class="mb-1 text-xs font-medium text-muted-foreground">{{ t('settings.stripeWebhookUrl') }}</p>
        <div class="flex items-center gap-2">
          <code class="flex-1 truncate text-xs font-mono">{{ stripeWebhookUrl }}</code>
          <button
            type="button"
            class="shrink-0 text-muted-foreground hover:text-foreground"
            @click="navigator.clipboard.writeText(stripeWebhookUrl)"
          >
            <IconCopy class="size-3.5" />
          </button>
        </div>
        <p class="mt-1 text-[11px] text-muted-foreground">{{ t('settings.stripeWebhookHelp') }}</p>
      </div>
    </div>

    <!-- Input for keys -->
    <form class="space-y-3" @submit.prevent="saveStripeKeys">
      <div class="space-y-1">
        <label class="text-sm font-medium" for="stripe-secret">
          {{ stripeHasKeys ? t('settings.stripeReplace') : t('settings.stripeSecretLabel') }}
        </label>
        <div class="relative">
          <input
            id="stripe-secret"
            v-model="stripeSecretInput"
            :type="stripeSecretVisible ? 'text' : 'password'"
            placeholder="sk_live_..."
            class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 pr-9 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring font-mono"
          />
          <button
            type="button"
            class="absolute right-2 top-1/2 -translate-y-1/2 text-muted-foreground hover:text-foreground"
            @click="stripeSecretVisible = !stripeSecretVisible"
          >
            <IconEyeOff v-if="stripeSecretVisible" class="size-4" />
            <IconEye v-else class="size-4" />
          </button>
        </div>
      </div>
      <div class="space-y-1">
        <label class="text-sm font-medium" for="stripe-pub">{{ t('settings.stripePubLabel') }}</label>
        <input
          id="stripe-pub"
          v-model="stripePubInput"
          type="text"
          placeholder="pk_live_..."
          class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring font-mono"
        />
      </div>
      <div class="space-y-1">
        <label class="text-sm font-medium" for="stripe-webhook">{{ t('settings.stripeWebhookLabel') }}</label>
        <input
          id="stripe-webhook"
          v-model="stripeWebhookInput"
          type="password"
          placeholder="whsec_..."
          class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring font-mono"
        />
      </div>

      <p v-if="stripeError" class="text-sm text-destructive">{{ stripeError }}</p>
      <p v-if="stripeSuccess" class="text-sm text-green-600">{{ stripeSuccess }}</p>

      <button
        type="submit"
        :disabled="stripeLoading || !stripeSecretInput.trim() || !stripePubInput.trim()"
        class="inline-flex h-9 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90 disabled:opacity-50"
      >
        <span v-if="stripeLoading">{{ t('common.saving') }}</span>
        <span v-else>{{ stripeHasKeys ? t('settings.stripeUpdate') : t('settings.stripeSave') }}</span>
      </button>
    </form>
  </div>
</template>
