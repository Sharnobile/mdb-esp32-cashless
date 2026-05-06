<script setup lang="ts">
const { t } = useI18n()
const supabase = useSupabaseClient()
const user = useSupabaseUser()
const { organization, role } = useOrganization()

// @nuxtjs/supabase v2 returns JWT claims (sub) not User object (id)
const userId = computed(() => user.value?.id ?? (user.value as any)?.sub ?? null)
const email = computed(() => user.value?.email ?? '')
const createdAt = computed(() => {
  if (!user.value?.created_at) return '—'
  return new Date(user.value.created_at).toLocaleDateString()
})

const firstName = ref('')
const lastName = ref('')
const nameLoading = ref(false)
const nameError = ref('')
const nameSuccess = ref('')

async function loadProfile() {
  if (!userId.value) return
  const { data } = await supabase
    .from('users')
    .select('first_name, last_name')
    .eq('id', userId.value)
    .single()
  if (data) {
    firstName.value = (data as any).first_name ?? ''
    lastName.value = (data as any).last_name ?? ''
  }
}

async function saveName() {
  nameError.value = ''
  nameSuccess.value = ''
  if (!userId.value) return

  nameLoading.value = true
  try {
    const { error } = await supabase
      .from('users')
      .update({ first_name: firstName.value || null, last_name: lastName.value || null })
      .eq('id', userId.value)
    if (error) throw error
    nameSuccess.value = t('settings.nameUpdated')
  } catch (err: unknown) {
    nameError.value = err instanceof Error ? err.message : t('common.failedTo', { action: 'update name' })
  } finally {
    nameLoading.value = false
  }
}

watch(userId, (uid) => { if (import.meta.client && uid) loadProfile() }, { immediate: true })
</script>

<template>
  <!-- Profile Information -->
  <div class="rounded-xl border bg-card p-6 shadow-sm">
    <h2 class="mb-1 text-lg font-semibold">{{ t('settings.profile') }}</h2>
    <p class="mb-5 text-sm text-muted-foreground">{{ t('settings.profileDescription') }}</p>

    <form class="space-y-4" @submit.prevent="saveName">
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <div class="space-y-1">
          <label class="text-sm font-medium" for="settings-first-name">{{ t('settings.firstName') }}</label>
          <input
            id="settings-first-name"
            v-model="firstName"
            type="text"
            :placeholder="t('settings.firstName')"
            class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          />
        </div>
        <div class="space-y-1">
          <label class="text-sm font-medium" for="settings-last-name">{{ t('settings.lastName') }}</label>
          <input
            id="settings-last-name"
            v-model="lastName"
            type="text"
            :placeholder="t('settings.lastName')"
            class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          />
        </div>
      </div>

      <div class="space-y-1">
        <label class="text-sm font-medium">{{ t('common.email') }}</label>
        <p class="text-sm text-muted-foreground">{{ email }}</p>
      </div>
      <div class="space-y-1">
        <label class="text-sm font-medium">{{ t('settings.organisation') }}</label>
        <p class="text-sm text-muted-foreground">
          {{ organization?.name ?? '—' }}
          <span
            v-if="role"
            class="ml-2 rounded-full px-2 py-0.5 text-xs font-medium"
            :class="role === 'admin' ? 'bg-primary/10 text-primary' : 'bg-muted text-muted-foreground'"
          >
            {{ role }}
          </span>
        </p>
      </div>
      <div class="space-y-1">
        <label class="text-sm font-medium">{{ t('settings.accountCreated') }}</label>
        <p class="text-sm text-muted-foreground">{{ createdAt }}</p>
      </div>

      <p v-if="nameError" class="text-sm text-destructive">{{ nameError }}</p>
      <p v-if="nameSuccess" class="text-sm text-green-600">{{ nameSuccess }}</p>

      <button
        type="submit"
        :disabled="nameLoading"
        class="inline-flex h-9 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90 disabled:opacity-50"
      >
        <span v-if="nameLoading">{{ t('common.saving') }}</span>
        <span v-else>{{ t('settings.saveName') }}</span>
      </button>
    </form>
  </div>
</template>
