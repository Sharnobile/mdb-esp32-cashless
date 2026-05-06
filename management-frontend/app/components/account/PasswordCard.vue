<script setup lang="ts">
const { t } = useI18n()
const supabase = useSupabaseClient()

const newPassword = ref('')
const confirmPassword = ref('')
const passwordLoading = ref(false)
const passwordError = ref('')
const passwordSuccess = ref('')

async function changePassword() {
  passwordError.value = ''
  passwordSuccess.value = ''

  if (newPassword.value.length < 6) {
    passwordError.value = t('settings.passwordMinLength')
    return
  }
  if (newPassword.value !== confirmPassword.value) {
    passwordError.value = t('settings.passwordsMismatch')
    return
  }

  passwordLoading.value = true
  try {
    const { error } = await supabase.auth.updateUser({
      password: newPassword.value,
    })
    if (error) throw error
    passwordSuccess.value = t('settings.passwordUpdated')
    newPassword.value = ''
    confirmPassword.value = ''
  } catch (err: unknown) {
    passwordError.value = err instanceof Error ? err.message : t('common.failedTo', { action: 'update password' })
  } finally {
    passwordLoading.value = false
  }
}
</script>

<template>
  <!-- Change Password -->
  <div class="rounded-xl border bg-card p-6 shadow-sm">
    <h2 class="mb-1 text-lg font-semibold">{{ t('settings.changePassword') }}</h2>
    <p class="mb-5 text-sm text-muted-foreground">
      {{ t('settings.passwordDescription') }}
    </p>

    <form class="space-y-4" @submit.prevent="changePassword">
      <div class="space-y-1">
        <label class="text-sm font-medium" for="new-password">{{ t('settings.newPassword') }}</label>
        <input
          id="new-password"
          v-model="newPassword"
          type="password"
          required
          :placeholder="t('settings.newPassword')"
          class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
      </div>
      <div class="space-y-1">
        <label class="text-sm font-medium" for="confirm-password">{{ t('settings.confirmNewPassword') }}</label>
        <input
          id="confirm-password"
          v-model="confirmPassword"
          type="password"
          required
          :placeholder="t('settings.confirmNewPassword')"
          class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
      </div>

      <p v-if="passwordError" class="text-sm text-destructive">{{ passwordError }}</p>
      <p v-if="passwordSuccess" class="text-sm text-green-600">{{ passwordSuccess }}</p>

      <button
        type="submit"
        :disabled="passwordLoading"
        class="inline-flex h-9 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90 disabled:opacity-50"
      >
        <span v-if="passwordLoading">{{ t('settings.updating') }}</span>
        <span v-else>{{ t('settings.updatePassword') }}</span>
      </button>
    </form>
  </div>
</template>
