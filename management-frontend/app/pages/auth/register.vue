<script setup lang="ts">
definePageMeta({ layout: false })

const { t } = useI18n()
const supabase = useSupabaseClient()
const route = useRoute()

const firstName = ref('')
const lastName = ref('')
const email = ref('')
const password = ref('')
const loading = ref(false)
const errorMsg = ref('')
const statusMsg = ref('')

const inviteToken = computed(() => (route.query.token as string) || '')
const loginLink = computed(() =>
  inviteToken.value ? `/auth/login?token=${inviteToken.value}` : '/auth/login'
)

async function register() {
  loading.value = true
  errorMsg.value = ''
  statusMsg.value = ''

  const { data: signUpData, error } = await supabase.auth.signUp({
    email: email.value,
    password: password.value,
  })

  if (error) {
    loading.value = false
    errorMsg.value = error.message
    return
  }

  // Save name to public.users (row created by auth trigger)
  if (signUpData.user?.id && (firstName.value || lastName.value)) {
    await supabase
      .from('users')
      .update({ first_name: firstName.value || null, last_name: lastName.value || null })
      .eq('id', signUpData.user.id)
  }

  // If there's an invitation token, accept it automatically
  if (inviteToken.value) {
    statusMsg.value = t('auth.joiningOrg')
    try {
      const { data, error: inviteError } = await supabase.functions.invoke('accept-invitation', {
        body: { token: inviteToken.value },
      })
      if (inviteError) throw inviteError
      if (data?.error) throw new Error(data.error)
    } catch (err: unknown) {
      loading.value = false
      errorMsg.value = err instanceof Error ? err.message : t('auth.failedToJoin')
      return
    }
  }

  loading.value = false
  await navigateTo(inviteToken.value ? '/' : '/onboarding/create-organization')
}
</script>

<template>
  <div class="flex min-h-screen items-center justify-center bg-background">
    <div class="w-full max-w-sm">
      <div class="rounded-xl border bg-card p-8 shadow-sm">
        <div class="mb-6 text-center">
          <h1 class="text-2xl font-semibold">{{ t('auth.createAccount') }}</h1>
          <p class="mt-1 text-sm text-muted-foreground">{{ t('auth.signUpDescription') }}</p>
        </div>

        <!-- Invitation banner -->
        <div v-if="inviteToken" class="mb-5 rounded-lg border border-primary/30 bg-primary/5 px-4 py-3 text-center text-sm text-primary">
          {{ t('auth.inviteRegisterBanner') }}
        </div>

        <form class="space-y-4" @submit.prevent="register">
          <div class="grid grid-cols-2 gap-3">
            <div class="space-y-1">
              <label class="text-sm font-medium" for="first-name">{{ t('auth.firstName') }}</label>
              <input
                id="first-name"
                v-model="firstName"
                type="text"
                autocomplete="given-name"
                placeholder="John"
                class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
              />
            </div>
            <div class="space-y-1">
              <label class="text-sm font-medium" for="last-name">{{ t('auth.lastName') }}</label>
              <input
                id="last-name"
                v-model="lastName"
                type="text"
                autocomplete="family-name"
                placeholder="Doe"
                class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
              />
            </div>
          </div>

          <div class="space-y-1">
            <label class="text-sm font-medium" for="email">{{ t('common.email') }}</label>
            <input
              id="email"
              v-model="email"
              type="email"
              required
              autocomplete="email"
              placeholder="you@example.com"
              class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
            />
          </div>

          <div class="space-y-1">
            <label class="text-sm font-medium" for="password">{{ t('common.password') }}</label>
            <input
              id="password"
              v-model="password"
              type="password"
              required
              autocomplete="new-password"
              placeholder="••••••••"
              class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
            />
          </div>

          <p v-if="errorMsg" class="text-sm text-destructive">{{ errorMsg }}</p>
          <p v-if="statusMsg" class="text-sm text-muted-foreground">{{ statusMsg }}</p>

          <button
            type="submit"
            :disabled="loading"
            class="inline-flex h-9 w-full items-center justify-center rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90 disabled:pointer-events-none disabled:opacity-50"
          >
            <span v-if="loading && statusMsg">{{ statusMsg }}</span>
            <span v-else-if="loading">{{ t('auth.creatingAccount') }}</span>
            <span v-else>{{ t('auth.createAccount') }}</span>
          </button>
        </form>

        <p class="mt-4 text-center text-sm text-muted-foreground">
          {{ t('auth.alreadyHaveAccount') }}
          <NuxtLink :to="loginLink" class="text-primary underline-offset-4 hover:underline">{{ t('auth.signInAction') }}</NuxtLink>
        </p>
      </div>
    </div>
  </div>
</template>
