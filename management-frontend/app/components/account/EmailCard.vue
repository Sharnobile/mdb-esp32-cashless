<script setup lang="ts">
const { t } = useI18n()
const supabase = useSupabaseClient()

const newEmail = ref('')
const emailLoading = ref(false)
const emailError = ref('')
const emailSuccess = ref('')

async function changeEmail() {
  emailError.value = ''
  emailSuccess.value = ''

  if (!newEmail.value || !newEmail.value.includes('@')) {
    emailError.value = t('settings.invalidEmail')
    return
  }

  emailLoading.value = true
  try {
    const { error } = await supabase.auth.updateUser({
      email: newEmail.value,
    })
    if (error) throw error
    emailSuccess.value = t('settings.emailUpdated')
    newEmail.value = ''
  } catch (err: unknown) {
    emailError.value = err instanceof Error ? err.message : t('common.failedTo', { action: 'update email' })
  } finally {
    emailLoading.value = false
  }
}
</script>

<template>
  <!-- Change Email -->
  <div class="rounded-xl border bg-card p-6 shadow-sm">
    <h2 class="mb-1 text-lg font-semibold">{{ t('settings.changeEmail') }}</h2>
    <p class="mb-5 text-sm text-muted-foreground">
      {{ t('settings.emailDescription') }}
    </p>

    <form class="space-y-4" @submit.prevent="changeEmail">
      <div class="space-y-1">
        <label class="text-sm font-medium" for="new-email">{{ t('settings.newEmailAddress') }}</label>
        <input
          id="new-email"
          v-model="newEmail"
          type="email"
          required
          placeholder="new@example.com"
          class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
      </div>

      <p v-if="emailError" class="text-sm text-destructive">{{ emailError }}</p>
      <p v-if="emailSuccess" class="text-sm text-green-600">{{ emailSuccess }}</p>

      <button
        type="submit"
        :disabled="emailLoading"
        class="inline-flex h-9 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90 disabled:opacity-50"
      >
        <span v-if="emailLoading">{{ t('settings.updating') }}</span>
        <span v-else>{{ t('settings.updateEmail') }}</span>
      </button>
    </form>
  </div>
</template>
