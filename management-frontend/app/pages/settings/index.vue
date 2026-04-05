<script setup lang="ts">
definePageMeta({ middleware: 'auth' })

import { IconMoon, IconSun, IconBell, IconBellOff, IconDeviceMobile, IconSend, IconTrash, IconSparkles, IconEye, IconEyeOff, IconReceipt2, IconPlus, IconPencil } from '@tabler/icons-vue'
import { Switch } from '~/components/ui/switch'
import { notificationTypes } from '~/composables/useNotifications'
import { timeAgo } from '~/lib/utils'

const { t } = useI18n()
const config = useRuntimeConfig()
const supabase = useSupabaseClient()
const user = useSupabaseUser()
const { organization, role } = useOrganization()
const { isDark, toggleTheme } = useTheme()
const {
  permission: notifPermission,
  isSubscribed,
  isSupported: pushSupported,
  needsHomescreen,
  isIOS,
  loading: notifLoading,
  error: notifError,
  subscribe: subscribePush,
  unsubscribe: unsubscribePush,
  devices,
  isTypeEnabled,
  togglePreference,
  removeDevice,
  init: initNotifications,
} = useNotifications()

// Initialize notifications on client mount
onMounted(() => { initNotifications() })

// ── Service Worker diagnostics ───────────────────────────────────────────────
const swStatus = ref('')
const swDiagLoading = ref(false)

async function checkSwStatus() {
  if (import.meta.server) return
  swDiagLoading.value = true
  const lines: string[] = []

  try {
    // 1. API support
    const hasSW = 'serviceWorker' in navigator
    const hasPM = 'PushManager' in window
    const hasNotif = 'Notification' in window
    lines.push(`APIs: SW=${hasSW} Push=${hasPM} Notif=${hasNotif}`)

    // 2. Protocol & context
    lines.push(`Protocol: ${location.protocol}`)
    lines.push(`Standalone: ${window.matchMedia('(display-mode: standalone)').matches || (navigator as any).standalone === true}`)
    lines.push(`Host: ${location.host}`)

    if (!hasSW) {
      lines.push('⛔ ServiceWorker API missing')
      swStatus.value = lines.join('\n')
      return
    }

    // 3. Current controller
    const ctrl = navigator.serviceWorker.controller
    lines.push(`Controller: ${ctrl ? `${ctrl.state} (${ctrl.scriptURL})` : 'none'}`)

    // 4. All registrations
    const regs = await navigator.serviceWorker.getRegistrations()
    lines.push(`Registrations: ${regs.length}`)
    for (const reg of regs) {
      const active = reg.active
      const waiting = reg.waiting
      const installing = reg.installing
      lines.push(`  scope: ${reg.scope}`)
      if (active) lines.push(`    active: ${active.state} ${active.scriptURL}`)
      if (waiting) lines.push(`    waiting: ${waiting.state}`)
      if (installing) lines.push(`    installing: ${installing.state}`)
      if (!active && !waiting && !installing) lines.push(`    (no worker)`)
    }

    // 5. If no registrations, try to manually register and see what happens
    if (regs.length === 0) {
      lines.push('⚠️ No SW registered. Attempting manual registration…')
      try {
        const reg = await navigator.serviceWorker.register('/sw.js', { scope: '/', updateViaCache: 'none' })
        const sw = reg.installing ?? reg.waiting ?? reg.active
        lines.push(`✅ Manual register OK: ${sw?.state ?? 'unknown'}`)
      } catch (regErr: any) {
        lines.push(`❌ Manual register failed: ${regErr.message}`)
      }
    }

    // 6. Notification permission
    if (hasNotif) {
      lines.push(`Notif permission: ${Notification.permission}`)
    }

    // 7. Check if SW script is reachable
    try {
      const resp = await fetch('/sw.js', { method: 'HEAD' })
      lines.push(`SW file /sw.js: ${resp.status} ${resp.ok ? '✅' : '❌'}`)
    } catch (fetchErr: any) {
      lines.push(`SW file /sw.js: fetch failed (${fetchErr.message})`)
    }
  } catch (e: any) {
    lines.push(`Diagnostic error: ${e.message}`)
  } finally {
    swStatus.value = lines.join('\n')
    swDiagLoading.value = false
  }
}

onMounted(() => { if (import.meta.client) checkSwStatus() })

// Toggle master push subscription
async function handlePushToggle(enabled: boolean) {
  if (enabled) {
    await subscribePush()
  } else {
    await unsubscribePush()
  }
}

// ── Test notification ─────────────────────────────────────────────────────────
const testLoading = ref(false)
const testResult = ref('')

async function sendTestNotification() {
  testResult.value = ''
  testLoading.value = true
  try {
    const { data, error } = await supabase.functions.invoke('test-push')
    if (error) throw error
    const sent = data?.sent ?? 0
    if (sent > 0) {
      testResult.value = `Test notification sent (${sent} device${sent > 1 ? 's' : ''}).`
    } else {
      testResult.value = t('settings.noSubscriptions')
    }
  } catch (err: unknown) {
    testResult.value = err instanceof Error ? err.message : 'Failed to send test notification'
  } finally {
    testLoading.value = false
  }
}

// ── Push device helpers ──────────────────────────────────────────────────────
function parseDeviceInfo(device: { endpoint: string; user_agent: string | null }) {
  // Detect push service from endpoint
  let service = 'Unknown'
  if (device.endpoint.includes('fcm.googleapis.com') || device.endpoint.includes('google')) service = 'Chrome'
  else if (device.endpoint.includes('mozilla.com')) service = 'Firefox'
  else if (device.endpoint.includes('apple.com')) service = 'Safari'
  else if (device.endpoint.includes('notify.windows.com')) service = 'Edge'

  // Parse user agent for OS
  const ua = device.user_agent ?? ''
  let os = ''
  if (/Android/i.test(ua)) os = 'Android'
  else if (/iPhone|iPad|iPod/i.test(ua)) os = 'iOS'
  else if (/Mac OS X|macOS/i.test(ua)) os = 'macOS'
  else if (/Windows/i.test(ua)) os = 'Windows'
  else if (/Linux/i.test(ua)) os = 'Linux'

  const label = os ? `${service} on ${os}` : service
  return { label, service, os }
}

// ── Profile info ─────────────────────────────────────────────────────────────
// @nuxtjs/supabase v2 returns JWT claims (sub) not User object (id)
const userId = computed(() => user.value?.id ?? (user.value as any)?.sub ?? null)
const email = computed(() => user.value?.email ?? '')
const createdAt = computed(() => {
  if (!user.value?.created_at) return '—'
  return new Date(user.value.created_at).toLocaleDateString()
})

// ── Name editing ─────────────────────────────────────────────────────────────
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

watch(() => organization.value?.id, (id) => {
  if (import.meta.client && id && role.value === 'admin') loadAiKey()
}, { immediate: true })

// ── Tax Settings (admin only) ───────────────────────────────────────────────
const {
  taxClasses,
  taxRates,
  companyCountry,
  loading: taxLoading,
  fetchAll: fetchTaxAll,
  createTaxClass,
  updateTaxClass,
  deleteTaxClass,
  createTaxRate,
  deleteTaxRate,
  updateCompanyCountry,
  seedFromSystem,
  formatTaxClassLabel,
  getCurrentRate,
  backfillSales,
} = useTaxSettings()
const { COUNTRY_OPTIONS } = await import('~/composables/useTaxSettings')

const taxError = ref('')
const taxSuccess = ref('')
const showTaxClassModal = ref(false)
const editingTaxClass = ref<{ id: string; name: string; description: string | null } | null>(null)
const taxClassForm = ref({ name: '', description: '' })
const taxClassLoading = ref(false)

const showTaxRateModal = ref(false)
const taxRateForm = ref({ taxClassId: '', rate: '', name: '', validFrom: '', validTo: '' })
const taxRateLoading = ref(false)

// Seed + backfill loading
const seedLoading = ref(false)
const backfillLoading = ref(false)
const backfillResult = ref('')

function openAddTaxClass() {
  editingTaxClass.value = null
  taxClassForm.value = { name: '', description: '' }
  showTaxClassModal.value = true
}

function openEditTaxClass(tc: { id: string; name: string; description: string | null }) {
  editingTaxClass.value = tc
  taxClassForm.value = { name: tc.name, description: tc.description ?? '' }
  showTaxClassModal.value = true
}

async function submitTaxClass() {
  if (!taxClassForm.value.name.trim()) return
  taxClassLoading.value = true
  taxError.value = ''
  try {
    if (editingTaxClass.value) {
      await updateTaxClass(editingTaxClass.value.id, taxClassForm.value.name.trim(), taxClassForm.value.description.trim())
    } else {
      await createTaxClass(taxClassForm.value.name.trim(), taxClassForm.value.description.trim())
    }
    showTaxClassModal.value = false
  } catch (err: unknown) {
    taxError.value = err instanceof Error ? err.message : 'Failed'
  } finally {
    taxClassLoading.value = false
  }
}

async function handleDeleteTaxClass(id: string) {
  if (!confirm(t('settings.deleteTaxClassConfirm'))) return
  try {
    await deleteTaxClass(id)
  } catch (err: unknown) {
    taxError.value = err instanceof Error ? err.message : 'Failed'
  }
}

function openAddTaxRate(taxClassId: string) {
  taxRateForm.value = { taxClassId, rate: '', name: '', validFrom: new Date().toISOString().split('T')[0], validTo: '' }
  showTaxRateModal.value = true
}

async function submitTaxRate() {
  if (!taxRateForm.value.rate || !taxRateForm.value.name.trim()) return
  taxRateLoading.value = true
  taxError.value = ''
  try {
    const rateValue = parseFloat(taxRateForm.value.rate) / 100
    await createTaxRate(
      taxRateForm.value.taxClassId,
      companyCountry.value,
      rateValue,
      taxRateForm.value.name.trim(),
      taxRateForm.value.validFrom,
      taxRateForm.value.validTo || undefined,
    )
    showTaxRateModal.value = false
  } catch (err: unknown) {
    taxError.value = err instanceof Error ? err.message : 'Failed'
  } finally {
    taxRateLoading.value = false
  }
}

async function handleDeleteTaxRate(id: string) {
  try {
    await deleteTaxRate(id)
  } catch (err: unknown) {
    taxError.value = err instanceof Error ? err.message : 'Failed'
  }
}

async function handleCountryChange(code: string) {
  try {
    await updateCompanyCountry(code)
  } catch (err: unknown) {
    taxError.value = err instanceof Error ? err.message : 'Failed'
  }
}

async function handleSeedDefaults() {
  seedLoading.value = true
  taxSuccess.value = ''
  taxError.value = ''
  try {
    await seedFromSystem(companyCountry.value)
    taxSuccess.value = t('settings.seedSuccess')
  } catch (err: unknown) {
    taxError.value = err instanceof Error ? err.message : 'Failed'
  } finally {
    seedLoading.value = false
  }
}

async function handleBackfill() {
  backfillLoading.value = true
  backfillResult.value = ''
  taxError.value = ''
  try {
    const count = await backfillSales()
    backfillResult.value = count > 0
      ? t('settings.backfillSuccess', { count })
      : t('settings.backfillNoChanges')
  } catch (err: unknown) {
    taxError.value = err instanceof Error ? err.message : 'Failed'
  } finally {
    backfillLoading.value = false
  }
}

function ratesForClass(classId: string) {
  return taxRates.value.filter(r => r.tax_class_id === classId && r.country_code === companyCountry.value)
}

const countryLabel = computed(() => {
  return COUNTRY_OPTIONS.find(c => c.code === companyCountry.value)?.label ?? companyCountry.value
})

watch(() => organization.value?.id, (id) => {
  if (import.meta.client && id && role.value === 'admin') fetchTaxAll(id)
}, { immediate: true })

// ── Password change ──────────────────────────────────────────────────────────
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

// ── Email change ─────────────────────────────────────────────────────────────
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
  <div class="flex flex-1 flex-col gap-6 p-4 md:p-6">
        <h1 class="text-2xl font-semibold">{{ t('settings.title') }}</h1>

        <div class="grid gap-6 md:max-w-2xl">
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

          <!-- Appearance -->
          <div class="rounded-xl border bg-card p-6 shadow-sm">
            <h2 class="mb-1 text-lg font-semibold">{{ t('settings.appearance') }}</h2>
            <p class="mb-5 text-sm text-muted-foreground">{{ t('settings.appearanceDescription') }}</p>

            <div class="flex items-center justify-between">
              <div class="space-y-0.5">
                <label class="text-sm font-medium">{{ t('settings.darkMode') }}</label>
                <p class="text-sm text-muted-foreground">
                  {{ isDark ? t('settings.darkThemeActive') : t('settings.lightThemeActive') }}
                </p>
              </div>
              <button
                class="inline-flex h-9 w-9 items-center justify-center rounded-md border border-input bg-background shadow-sm transition-colors hover:bg-muted"
                @click="toggleTheme()"
              >
                <IconMoon v-if="isDark" class="size-4" />
                <IconSun v-else class="size-4" />
              </button>
            </div>
          </div>

          <!-- AI Insights API Key (admin only) -->
          <div v-if="role === 'admin'" class="rounded-xl border bg-card p-6 shadow-sm">
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

          <!-- Tax Settings (admin only) -->
          <div v-if="role === 'admin'" class="rounded-xl border bg-card p-6 shadow-sm">
            <div class="mb-5 flex items-center gap-2">
              <IconReceipt2 class="size-5 text-primary" />
              <div>
                <h2 class="text-lg font-semibold">{{ t('settings.taxSettings') }}</h2>
                <p class="text-sm text-muted-foreground">{{ t('settings.taxSettingsDescription') }}</p>
              </div>
            </div>

            <!-- Company country -->
            <div class="mb-6 space-y-2">
              <label class="text-sm font-medium">{{ t('settings.companyCountry') }}</label>
              <select
                :value="companyCountry"
                class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
                @change="handleCountryChange(($event.target as HTMLSelectElement).value)"
              >
                <option v-for="c in COUNTRY_OPTIONS" :key="c.code" :value="c.code">
                  {{ c.code }} — {{ c.label }}
                </option>
              </select>
              <p class="text-xs text-muted-foreground">{{ t('settings.companyCountryHint') }}</p>
            </div>

            <!-- Seed defaults button -->
            <div class="mb-6">
              <button
                :disabled="seedLoading"
                class="inline-flex h-9 items-center justify-center rounded-md border px-4 text-sm font-medium shadow-sm transition-colors hover:bg-muted disabled:opacity-50"
                @click="handleSeedDefaults"
              >
                <span v-if="seedLoading">{{ t('common.loading') }}</span>
                <span v-else>{{ t('settings.seedFromDefaults', { country: countryLabel }) }}</span>
              </button>
              <button
                :disabled="backfillLoading"
                class="inline-flex h-9 items-center justify-center rounded-md border px-4 text-sm font-medium shadow-sm transition-colors hover:bg-muted disabled:opacity-50"
                @click="handleBackfill"
              >
                <span v-if="backfillLoading">{{ t('common.loading') }}</span>
                <span v-else>{{ t('settings.backfillSales') }}</span>
              </button>
            </div>
            <p class="mb-2 text-xs text-muted-foreground">{{ t('settings.backfillDescription') }}</p>

            <p v-if="taxError" class="mb-4 text-sm text-destructive">{{ taxError }}</p>
            <p v-if="taxSuccess" class="mb-4 text-sm text-green-600">{{ taxSuccess }}</p>
            <p v-if="backfillResult" class="mb-4 text-sm text-green-600">{{ backfillResult }}</p>

            <!-- Tax classes list -->
            <div class="space-y-4">
              <div class="flex items-center justify-between">
                <h3 class="text-sm font-medium">{{ t('settings.taxClasses') }}</h3>
                <button
                  class="inline-flex h-7 items-center gap-1 rounded-md border border-input bg-background px-2 text-xs font-medium shadow-sm transition-colors hover:bg-muted"
                  @click="openAddTaxClass"
                >
                  <IconPlus class="size-3.5" />
                  {{ t('settings.addTaxClass') }}
                </button>
              </div>

              <div v-if="taxClasses.length === 0" class="text-sm text-muted-foreground">
                {{ t('settings.noTaxClasses') }}
              </div>

              <div v-for="tc in taxClasses" :key="tc.id" class="rounded-lg border p-4">
                <div class="flex items-center justify-between mb-3">
                  <div>
                    <span class="font-medium text-sm">{{ tc.name }}</span>
                    <span v-if="getCurrentRate(tc.id) !== null" class="ml-2 text-xs text-muted-foreground">
                      ({{ (getCurrentRate(tc.id)! * 100).toFixed(getCurrentRate(tc.id)! * 100 % 1 === 0 ? 0 : 1) }}%)
                    </span>
                    <p v-if="tc.description" class="text-xs text-muted-foreground mt-0.5">{{ tc.description }}</p>
                  </div>
                  <div class="flex items-center gap-1">
                    <button
                      class="inline-flex h-7 w-7 items-center justify-center rounded-md text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
                      @click="openEditTaxClass(tc)"
                    >
                      <IconPencil class="size-3.5" />
                    </button>
                    <button
                      class="inline-flex h-7 w-7 items-center justify-center rounded-md text-muted-foreground transition-colors hover:bg-destructive/10 hover:text-destructive"
                      @click="handleDeleteTaxClass(tc.id)"
                    >
                      <IconTrash class="size-3.5" />
                    </button>
                  </div>
                </div>

                <!-- Rates for this class in current country -->
                <div class="space-y-1">
                  <div
                    v-for="rate in ratesForClass(tc.id)"
                    :key="rate.id"
                    class="flex items-center justify-between text-sm rounded-md bg-muted/50 px-3 py-1.5"
                  >
                    <span>{{ rate.name }} — {{ rate.country_code }}</span>
                    <div class="flex items-center gap-2">
                      <span class="text-xs text-muted-foreground">
                        {{ rate.valid_from }}
                        <template v-if="rate.valid_to"> — {{ rate.valid_to }}</template>
                      </span>
                      <button
                        class="text-xs text-destructive hover:underline"
                        @click="handleDeleteTaxRate(rate.id)"
                      >
                        {{ t('common.remove') }}
                      </button>
                    </div>
                  </div>
                  <div v-if="ratesForClass(tc.id).length === 0" class="text-xs text-muted-foreground italic px-3 py-1.5">
                    {{ t('settings.noTaxRates') }}
                  </div>
                  <button
                    class="mt-1 text-xs text-primary hover:underline"
                    @click="openAddTaxRate(tc.id)"
                  >
                    + {{ t('settings.taxRate') }}
                  </button>
                </div>
              </div>
            </div>
          </div>

          <!-- Tax class modal -->
          <AppModal
            v-model:open="showTaxClassModal"
            :title="editingTaxClass ? t('settings.editTaxClass') : t('settings.addTaxClass')"
            size="sm"
          >
            <form class="space-y-4" @submit.prevent="submitTaxClass">
              <div class="space-y-1">
                <label class="text-sm font-medium">{{ t('settings.className') }}</label>
                <input
                  v-model="taxClassForm.name"
                  type="text"
                  required
                  :placeholder="t('settings.className')"
                  class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
                />
              </div>
              <div class="space-y-1">
                <label class="text-sm font-medium">{{ t('common.description') }}</label>
                <input
                  v-model="taxClassForm.description"
                  type="text"
                  :placeholder="t('common.description')"
                  class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
                />
              </div>
              <div class="flex gap-2">
                <button
                  type="button"
                  class="inline-flex h-9 flex-1 items-center justify-center rounded-md border px-4 text-sm font-medium shadow-sm transition-colors hover:bg-muted"
                  @click="showTaxClassModal = false"
                >
                  {{ t('common.cancel') }}
                </button>
                <button
                  type="submit"
                  :disabled="taxClassLoading"
                  class="inline-flex h-9 flex-1 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90 disabled:opacity-50"
                >
                  <span v-if="taxClassLoading">{{ t('common.saving') }}</span>
                  <span v-else>{{ t('common.save') }}</span>
                </button>
              </div>
            </form>
          </AppModal>

          <!-- Tax rate modal -->
          <AppModal
            v-model:open="showTaxRateModal"
            :title="t('settings.taxRate')"
            size="sm"
          >
            <form class="space-y-4" @submit.prevent="submitTaxRate">
              <div class="space-y-1">
                <label class="text-sm font-medium">{{ t('settings.taxRate') }} (%)</label>
                <input
                  v-model="taxRateForm.rate"
                  type="number"
                  step="0.01"
                  required
                  placeholder="19"
                  class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
                />
              </div>
              <div class="space-y-1">
                <label class="text-sm font-medium">{{ t('common.name') }}</label>
                <input
                  v-model="taxRateForm.name"
                  type="text"
                  required
                  placeholder="MwSt. 19%"
                  class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
                />
              </div>
              <div class="grid grid-cols-2 gap-3">
                <div class="space-y-1">
                  <label class="text-sm font-medium">{{ t('settings.validFrom') }}</label>
                  <input
                    v-model="taxRateForm.validFrom"
                    type="date"
                    required
                    class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
                  />
                </div>
                <div class="space-y-1">
                  <label class="text-sm font-medium">{{ t('settings.validTo') }} <span class="text-xs text-muted-foreground">({{ t('products.optional') }})</span></label>
                  <input
                    v-model="taxRateForm.validTo"
                    type="date"
                    class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
                  />
                </div>
              </div>
              <div class="flex gap-2">
                <button
                  type="button"
                  class="inline-flex h-9 flex-1 items-center justify-center rounded-md border px-4 text-sm font-medium shadow-sm transition-colors hover:bg-muted"
                  @click="showTaxRateModal = false"
                >
                  {{ t('common.cancel') }}
                </button>
                <button
                  type="submit"
                  :disabled="taxRateLoading"
                  class="inline-flex h-9 flex-1 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90 disabled:opacity-50"
                >
                  <span v-if="taxRateLoading">{{ t('common.saving') }}</span>
                  <span v-else>{{ t('common.save') }}</span>
                </button>
              </div>
            </form>
          </AppModal>

          <!-- Push Notifications -->
          <ClientOnly>
            <div class="rounded-xl border bg-card p-6 shadow-sm">
              <div class="mb-5 flex items-center gap-2">
                <IconBell v-if="isSubscribed" class="size-5 text-primary" />
                <IconBellOff v-else class="size-5 text-muted-foreground" />
                <div>
                  <h2 class="text-lg font-semibold">{{ t('settings.pushNotifications') }}</h2>
                  <p class="text-sm text-muted-foreground">
                    {{ t('settings.pushDescription') }}
                  </p>
                </div>
              </div>

              <!-- iOS homescreen guidance -->
              <div
                v-if="needsHomescreen"
                class="mb-5 flex items-start gap-3 rounded-lg border border-amber-200 bg-amber-50 p-4 dark:border-amber-900 dark:bg-amber-950"
              >
                <IconDeviceMobile class="mt-0.5 size-5 shrink-0 text-amber-600 dark:text-amber-400" />
                <div class="text-sm">
                  <p class="mb-1 font-medium text-amber-800 dark:text-amber-200">
                    {{ t('settings.addToHomeScreen') }}
                  </p>
                  <p class="text-amber-700 dark:text-amber-300">
                    {{ t('settings.iosGuidance') }}
                  </p>
                </div>
              </div>

              <!-- Not supported warning -->
              <div
                v-if="!pushSupported && !needsHomescreen"
                class="mb-5 rounded-lg border border-muted bg-muted/50 p-4 text-sm text-muted-foreground"
              >
                {{ t('settings.browserNotSupported') }}
              </div>

              <!-- Permission denied warning -->
              <div
                v-if="notifPermission === 'denied'"
                class="mb-5 rounded-lg border border-destructive/20 bg-destructive/5 p-4 text-sm text-destructive"
              >
                <template v-if="isIOS">
                  {{ t('settings.notificationsBlocked') }}
                </template>
                <template v-else>
                  {{ t('settings.permissionDenied') }}
                </template>
              </div>

              <!-- Error message -->
              <div
                v-if="notifError"
                class="mb-5 rounded-lg border border-destructive/20 bg-destructive/5 p-4 text-sm text-destructive"
              >
                {{ notifError }}
              </div>

              <!-- Master toggle -->
              <div class="flex items-center justify-between">
                <div class="space-y-0.5">
                  <label class="text-sm font-medium">
                    {{ t('settings.enableOnDevice') }}
                  </label>
                  <p class="text-sm text-muted-foreground">
                    <template v-if="notifLoading">{{ t('settings.activating') }}</template>
                    <template v-else>{{ isSubscribed ? t('settings.notificationsActive') : t('settings.notificationsOff') }}</template>
                  </p>
                </div>
                <Switch
                  :checked="isSubscribed"
                  :disabled="notifLoading || !pushSupported || notifPermission === 'denied' || needsHomescreen"
                  @update:checked="handlePushToggle"
                />
              </div>

              <!-- Per-type toggles (only visible when subscribed) -->
              <div v-if="isSubscribed" class="mt-6 space-y-4 border-t pt-5">
                <h3 class="text-sm font-medium text-muted-foreground">{{ t('settings.notificationTypes') }}</h3>

                <div
                  v-for="nt in notificationTypes"
                  :key="nt.key"
                  class="flex items-center justify-between"
                >
                  <div class="space-y-0.5">
                    <label class="text-sm font-medium">{{ nt.label }}</label>
                    <p class="text-sm text-muted-foreground">{{ nt.description }}</p>
                  </div>
                  <Switch
                    :checked="isTypeEnabled(nt.key)"
                    @update:checked="(val: boolean) => togglePreference(nt.key, val)"
                  />
                </div>

                <!-- Test notification -->
                <div class="flex items-center justify-between pt-2">
                  <div class="space-y-0.5">
                    <label class="text-sm font-medium">{{ t('settings.testNotificationLabel') }}</label>
                    <p class="text-sm text-muted-foreground">
                      {{ testResult || t('settings.testNotificationDescription') }}
                    </p>
                  </div>
                  <button
                    :disabled="testLoading"
                    class="inline-flex h-9 items-center gap-1.5 rounded-md border border-input bg-background px-3 text-sm font-medium shadow-sm transition-colors hover:bg-muted disabled:opacity-50"
                    @click="sendTestNotification"
                  >
                    <IconSend class="size-3.5" />
                    <span v-if="testLoading">{{ t('settings.sending') }}</span>
                    <span v-else>{{ t('settings.sendTest') }}</span>
                  </button>
                </div>

                <!-- Registered devices -->
                <div v-if="devices.length > 0" class="mt-2 pt-4 border-t">
                  <h3 class="text-sm font-medium text-muted-foreground mb-3">{{ t('settings.registeredDevices') }}</h3>
                  <div class="space-y-2">
                    <div
                      v-for="device in devices"
                      :key="device.id"
                      class="flex items-center justify-between rounded-lg border px-3 py-2"
                    >
                      <div class="min-w-0">
                        <p class="text-sm font-medium truncate">{{ parseDeviceInfo(device).label }}</p>
                        <p class="text-xs text-muted-foreground">
                          {{ t('settings.registered', { time: timeAgo(device.created_at, t) }) }}
                        </p>
                      </div>
                      <button
                        class="ml-2 shrink-0 inline-flex h-7 w-7 items-center justify-center rounded-md text-muted-foreground transition-colors hover:bg-destructive/10 hover:text-destructive"
                        :title="t('settings.removeDevice')"
                        @click="removeDevice(device.id)"
                      >
                        <IconTrash class="size-3.5" />
                      </button>
                    </div>
                  </div>
                </div>
              </div>

              <!-- Service Worker Diagnostics -->
              <div class="mt-6 border-t pt-5">
                <div class="flex items-center justify-between mb-3">
                  <h3 class="text-sm font-medium text-muted-foreground">{{ t('settings.swDiagnostics') }}</h3>
                  <button
                    :disabled="swDiagLoading"
                    class="inline-flex h-7 items-center gap-1 rounded-md border border-input bg-background px-2 text-xs font-medium shadow-sm transition-colors hover:bg-muted disabled:opacity-50"
                    @click="checkSwStatus"
                  >
                    <span v-if="swDiagLoading">{{ t('settings.checking') }}</span>
                    <span v-else>{{ t('settings.recheck') }}</span>
                  </button>
                </div>
                <pre
                  v-if="swStatus"
                  class="whitespace-pre-wrap rounded-lg border bg-muted/50 p-3 text-xs font-mono text-muted-foreground leading-relaxed"
                >{{ swStatus }}</pre>
                <p v-else class="text-xs text-muted-foreground">{{ t('settings.loadingDiagnostics') }}</p>
              </div>
            </div>
          </ClientOnly>

          <!-- App Version -->
          <div class="rounded-xl border bg-card p-6 shadow-sm">
            <h2 class="mb-1 text-lg font-semibold">{{ t('settings.about') }}</h2>
            <p class="mb-5 text-sm text-muted-foreground">{{ t('settings.aboutDescription') }}</p>

            <div class="space-y-3 text-sm">
              <div class="flex items-center justify-between">
                <span class="text-muted-foreground">{{ t('settings.version') }}</span>
                <span class="font-mono font-medium">v{{ config.public.appVersion }}</span>
              </div>
              <div class="flex items-center justify-between">
                <span class="text-muted-foreground">{{ t('settings.build') }}</span>
                <span class="font-mono text-muted-foreground">{{ config.public.gitHash === 'dev' ? t('settings.development') : config.public.gitHash.substring(0, 7) }}</span>
              </div>
              <div v-if="config.public.buildDate" class="flex items-center justify-between">
                <span class="text-muted-foreground">{{ t('settings.built') }}</span>
                <span class="text-muted-foreground">{{ new Date(config.public.buildDate).toLocaleDateString() }}</span>
              </div>
            </div>
          </div>
        </div>
      </div>
</template>
