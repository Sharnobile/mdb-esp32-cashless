# Split Account and Settings Pages — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the 1753-line `/settings` page into `/account` (per-user) and `/settings` (admin) by extracting each section into its own card component, and surface the app version in the sidebar footer.

**Architecture:** Pure frontend refactor. No backend, DB, or firmware changes. Each section becomes a self-contained `.vue` SFC with its own imports, refs, and Supabase calls — no shared state across cards. The two pages compose the cards. Admin gate sits at the page level on `/settings`; the section-internal `v-if="isAdmin"` guards become redundant and are dropped.

**Tech Stack:** Nuxt 4 (`app/` directory), TypeScript, `@nuxtjs/supabase`, `@nuxtjs/i18n`, shadcn-nuxt, TailwindCSS 4, `@vueuse/core`.

**Spec:** [docs/superpowers/specs/2026-05-06-split-account-and-settings-design.md](../specs/2026-05-06-split-account-and-settings-design.md)

**Verification model:** No Vue component tests exist for the current settings page; the codebase pattern is browser smoke tests. Each chunk ends with a smoke-test step. Run `npm run dev` from `management-frontend/` once at the start; HMR picks up edits.

---

## Pre-flight

- [ ] **Step 0.1: Start the dev server**

```bash
cd management-frontend
npm install   # if not already done
npm run dev
```

Leave it running in a side terminal. Open `http://localhost:3000` in a browser. Log in with credentials from `memory/user_dev_credentials.md`.

- [ ] **Step 0.2: Confirm baseline works**

Navigate to `/settings`. Confirm all sections render (Profile, Change Email, Change Password, Appearance, Imprint, AI Insights, Stripe, Deal Search, Tax, Push Notifications, App Version).

If anything is broken on `main` already, stop and ask before proceeding.

---

## Chunk 1: Navigation foundation

Adds i18n keys, the sidebar app-version line, and the second dropdown entry. All three changes are tiny and independent of the card extraction. Do these first so the navigation surface is in place when the new `/account` route appears.

### Task 1: Add i18n keys

**Files:**
- Modify: `management-frontend/i18n/locales/en.json` (line 57 area, line 883 area)
- Modify: `management-frontend/i18n/locales/de.json` (same)

- [ ] **Step 1.1: Add `nav.settings` to en.json**

In `management-frontend/i18n/locales/en.json`, find the `"nav":` block (line 46). Add `"settings"` after the existing `"account"` entry on line 57:

```json
    "account": "Account",
    "settings": "Settings",
    "logout": "Log out",
```

- [ ] **Step 1.2: Add `nav.settings` to de.json**

Same change in `management-frontend/i18n/locales/de.json`:

```json
    "account": "Konto",
    "settings": "Einstellungen",
    "logout": "Abmelden",
```

- [ ] **Step 1.3: Add `account` top-level section + `settings.noAccessHint` + `settings.extensionsLink` to en.json**

Find the `"settings":` block (line 883). Insert a new top-level `"account"` block immediately above it:

```json
  "account": {
    "title": "Account"
  },
  "settings": {
```

Inside the existing `"settings":` block, find the `"title"` entry near the top and add two new keys right after it:

```json
    "title": "Account Settings",
    "noAccessHint": "No settings available for your role.",
    "extensionsLink": "Manage extensions",
```

- [ ] **Step 1.4: Mirror the same three keys in de.json**

```json
  "account": {
    "title": "Konto"
  },
  "settings": {
```

```json
    "title": "Kontoeinstellungen",
    "noAccessHint": "Keine Einstellungen für deine Rolle verfügbar.",
    "extensionsLink": "Extensions verwalten",
```

(Use the existing German `"title"` value as-is — only add the two new keys after it.)

- [ ] **Step 1.5: Verify JSON is valid**

```bash
node -e "JSON.parse(require('fs').readFileSync('management-frontend/i18n/locales/en.json','utf8')); console.log('en.json OK')"
node -e "JSON.parse(require('fs').readFileSync('management-frontend/i18n/locales/de.json','utf8')); console.log('de.json OK')"
```

Expected: both print `OK`. If either errors, fix the trailing-comma / brace mismatch and re-run.

- [ ] **Step 1.6: Commit**

```bash
git add management-frontend/i18n/locales/en.json management-frontend/i18n/locales/de.json
git commit -m "i18n: add nav.settings + account.title + settings.noAccessHint/extensionsLink"
```

### Task 2: Add app version line to sidebar footer

**Files:**
- Modify: `management-frontend/app/components/AppSidebar.vue:166-168`

- [ ] **Step 2.1: Inject runtime config**

Edit `management-frontend/app/components/AppSidebar.vue`. After the existing `useI18n` / `useOrganization` calls in the `<script setup>` block (around line 35), add:

```ts
const config = useRuntimeConfig()
```

- [ ] **Step 2.2: Add the version line in `SidebarFooter`**

In the same file, replace the `<SidebarFooter>` block:

```vue
    <SidebarFooter>
      <NavUser />
    </SidebarFooter>
```

with:

```vue
    <SidebarFooter>
      <div class="px-2 pb-1 text-[11px] text-muted-foreground">v{{ config.public.appVersion }}</div>
      <NavUser />
    </SidebarFooter>
```

- [ ] **Step 2.3: Smoke test in browser**

The sidebar reloads via HMR. Confirm a small `vX.Y.Z` line appears just above the user avatar block in the sidebar footer, on every page.

- [ ] **Step 2.4: Commit**

```bash
git add management-frontend/app/components/AppSidebar.vue
git commit -m "feat(sidebar): show app version in footer above NavUser"
```

### Task 3: Add second dropdown entry to NavUser

**Files:**
- Modify: `management-frontend/app/components/NavUser.vue`

- [ ] **Step 3.1: Import the settings icon**

In `management-frontend/app/components/NavUser.vue`, the icon import block at line 2 currently reads:

```ts
import {
  IconDotsVertical,
  IconLogout,
  IconUserCircle,
} from "@tabler/icons-vue"
```

Add `IconSettings`:

```ts
import {
  IconDotsVertical,
  IconLogout,
  IconSettings,
  IconUserCircle,
} from "@tabler/icons-vue"
```

- [ ] **Step 3.2: Update the existing Account dropdown item to point at /account**

Find the block at line 117–122:

```vue
            <DropdownMenuItem as-child @click="isMobile && setOpenMobile(false)">
              <NuxtLink to="/settings">
                <IconUserCircle />
                {{ t('nav.account') }}
              </NuxtLink>
            </DropdownMenuItem>
```

Replace `to="/settings"` with `to="/account"`:

```vue
            <DropdownMenuItem as-child @click="isMobile && setOpenMobile(false)">
              <NuxtLink to="/account">
                <IconUserCircle />
                {{ t('nav.account') }}
              </NuxtLink>
            </DropdownMenuItem>
```

- [ ] **Step 3.3: Add the new Settings dropdown item directly below it**

Insert a new `DropdownMenuItem` immediately after the Account item, still inside the same `DropdownMenuGroup`:

```vue
            <DropdownMenuItem as-child @click="isMobile && setOpenMobile(false)">
              <NuxtLink to="/settings">
                <IconSettings />
                {{ t('nav.settings') }}
              </NuxtLink>
            </DropdownMenuItem>
```

- [ ] **Step 3.4: Smoke test the dropdown**

Open the user dropdown in the sidebar footer. Confirm two entries appear: "Account" → `/account` and "Settings" / "Einstellungen" → `/settings`. Clicking "Account" will 404 right now (the page does not exist yet) — that's expected; clicking "Settings" still loads the unchanged settings page.

- [ ] **Step 3.5: Commit**

```bash
git add management-frontend/app/components/NavUser.vue
git commit -m "feat(navuser): split dropdown into Account (/account) + Settings (/settings)"
```

### Chunk 1 verification

- [ ] **Step C1.1: End-of-chunk smoke**

Reload any page in the browser. Confirm:
1. Sidebar footer shows version line + user avatar
2. Avatar dropdown has 2 nav entries (Account, Settings) above the language switcher
3. `/settings` still works (unchanged content); `/account` returns 404 (next chunk fixes this)

---

## Chunk 2: Account page (5 cards + page)

Extracts the per-user sections from `pages/settings/index.vue` into card components and composes them on a new `/account` page. Each card extraction follows the same recipe: copy script + template, fix imports, leave the source page alone for now (delete sections only in Chunk 3 when we rewrite `/settings`).

> **Pattern recap:** Source code lives in `management-frontend/app/pages/settings/index.vue`. Section template comments mark each block: `<!-- Profile Information -->` (l. 767), `<!-- Change Email -->` (l. 832), `<!-- Change Password -->` (l. 866), `<!-- Appearance -->` (l. 911), `<!-- Push Notifications -->` (l. 1567).
>
> Copy each section's template *and* its supporting `<script setup>` refs/functions into a new file. Each new card declares its own `useI18n`, `useSupabaseClient`, `useSupabaseUser`, etc. — no props, no emits.

### Task 4: Extract `ProfileCard.vue`

**Files:**
- Create: `management-frontend/app/components/account/ProfileCard.vue`

**Source:** `pages/settings/index.vue`
- Script: lines 169–218 (userId, email, createdAt, firstName/lastName, nameLoading/Error/Success, loadProfile, saveName, watch)
- Template: lines 767–831

- [ ] **Step 4.1: Create the file**

Create `management-frontend/app/components/account/ProfileCard.vue` with the script + template. The file structure:

```vue
<script setup lang="ts">
const { t } = useI18n()
const supabase = useSupabaseClient()
const user = useSupabaseUser()
const { organization } = useOrganization()

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
  <!-- Copy the entire <!-- Profile Information --> block (lines 767–831) verbatim -->
</template>
```

For the template, copy lines 767–831 exactly. Do not change any class names, labels, or `t()` keys.

- [ ] **Step 4.2: Smoke test**

Browse to `/settings`. Profile section should still work (we haven't removed it yet). The new component file is unused for now; it just needs to compile. Check the dev server log — no Vue compile errors should appear.

- [ ] **Step 4.3: Commit**

```bash
git add management-frontend/app/components/account/ProfileCard.vue
git commit -m "feat(account): extract ProfileCard from settings page"
```

### Task 5: Extract `EmailCard.vue`

**Source:** `pages/settings/index.vue` script lines 731–759, template lines 832–865.

- [ ] **Step 5.1: Create `management-frontend/app/components/account/EmailCard.vue`**

```vue
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
  <!-- Copy <!-- Change Email --> block (lines 832–865) verbatim -->
</template>
```

- [ ] **Step 5.2: Smoke test (compile only)** — confirm dev server has no errors.

- [ ] **Step 5.3: Commit**

```bash
git add management-frontend/app/components/account/EmailCard.vue
git commit -m "feat(account): extract EmailCard from settings page"
```

### Task 6: Extract `PasswordCard.vue`

**Source:** `pages/settings/index.vue` script lines 695–729, template lines 866–910.

- [ ] **Step 6.1: Create `management-frontend/app/components/account/PasswordCard.vue`**

Same recipe as EmailCard — copy the password change script section + template block. Imports needed: `useI18n`, `useSupabaseClient`. State: `newPassword`, `confirmPassword`, `passwordLoading`, `passwordError`, `passwordSuccess`. Function: `changePassword()`.

- [ ] **Step 6.2: Smoke test (compile only).**

- [ ] **Step 6.3: Commit**

```bash
git add management-frontend/app/components/account/PasswordCard.vue
git commit -m "feat(account): extract PasswordCard from settings page"
```

### Task 7: Extract `AppearanceCard.vue`

**Source:** `pages/settings/index.vue` template lines 911–932. Logic comes from `useTheme()`.

- [ ] **Step 7.1: Create `management-frontend/app/components/account/AppearanceCard.vue`**

```vue
<script setup lang="ts">
import { IconMoon, IconSun } from '@tabler/icons-vue'
import { Switch } from '~/components/ui/switch'

const { t } = useI18n()
const { isDark, toggleTheme } = useTheme()
</script>

<template>
  <!-- Copy <!-- Appearance --> block (lines 911–932) verbatim -->
</template>
```

The icon imports (`IconMoon`, `IconSun`) and the `Switch` component import are only needed if those symbols appear inside the template block — verify by inspecting the template before saving.

- [ ] **Step 7.2: Smoke test (compile only).**

- [ ] **Step 7.3: Commit**

```bash
git add management-frontend/app/components/account/AppearanceCard.vue
git commit -m "feat(account): extract AppearanceCard from settings page"
```

### Task 8: Extract `PushNotificationsCard.vue`

This is the largest card. It owns: master toggle, per-type toggles, registered devices, test push, service-worker diagnostics. Take time to be thorough.

**Source:** `pages/settings/index.vue`
- Script: lines 4 (icons), 7 (notificationTypes), 8 (timeAgo), 16–34 (`useNotifications` destructure + `onMounted(initNotifications)`), 36–113 (SW diagnostics: `swStatus`, `swDiagLoading`, `checkSwStatus`, second `onMounted`), 115–122 (`handlePushToggle`), 124–145 (`testLoading`, `testResult`, `sendTestNotification`), 147–167 (`parseDeviceInfo`).
- Template: lines 1567–1730.

- [ ] **Step 8.1: Create `management-frontend/app/components/account/PushNotificationsCard.vue`**

Open with this script header (icons trimmed to only what the push template uses):

```vue
<script setup lang="ts">
import { IconBell, IconBellOff, IconDeviceMobile, IconSend, IconTrash } from '@tabler/icons-vue'
import { Switch } from '~/components/ui/switch'
import { notificationTypes } from '~/composables/useNotifications'
import { timeAgo } from '~/lib/utils'

const { t } = useI18n()
const supabase = useSupabaseClient()
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

onMounted(() => { initNotifications() })

// SW diagnostics, push toggle, test push, parseDeviceInfo — copy verbatim
// from pages/settings/index.vue lines 36–167.
</script>

<template>
  <!-- Copy <!-- Push Notifications --> block (lines 1567–1730) verbatim -->
</template>
```

**Important:** The two `onMounted` hooks (init notifications + check SW status) move into this card. They will only run when `/account` is mounted (the desired behaviour per spec).

- [ ] **Step 8.2: Smoke test in browser**

Browse to `/settings` (still has the original Push Notifications section). Subscribe to push, send a test push, unsubscribe. Confirm the original card still works while we have a parallel copy waiting.

- [ ] **Step 8.3: Commit**

```bash
git add management-frontend/app/components/account/PushNotificationsCard.vue
git commit -m "feat(account): extract PushNotificationsCard from settings page"
```

### Task 9: Create `/account` page

**Files:**
- Create: `management-frontend/app/pages/account/index.vue`

- [ ] **Step 9.1: Compose the page**

```vue
<script setup lang="ts">
definePageMeta({ middleware: 'auth' })

const { t } = useI18n()
</script>

<template>
  <div class="flex flex-1 flex-col gap-6 p-4 md:p-6">
    <h1 class="text-2xl font-semibold">{{ t('account.title') }}</h1>
    <div class="grid w-full max-w-3xl gap-6">
      <AccountProfileCard />
      <AccountEmailCard />
      <AccountPasswordCard />
      <AccountAppearanceCard />
      <AccountPushNotificationsCard />
    </div>
  </div>
</template>
```

The component names `<AccountProfileCard />` etc. resolve via Nuxt 4's auto-import (nested directories collapse to PascalCase prefixes).

- [ ] **Step 9.2: Smoke test in browser**

Navigate to `/account` via the avatar dropdown.

Verify:
1. Page heading shows "Account" / "Konto" depending on locale.
2. All 5 cards render in order: Profile, Email, Password, Appearance, Push Notifications.
3. Each card displays the same content as on `/settings`.
4. Save name → reload page → name persisted.
5. Toggle dark mode from the Appearance card → theme actually flips.

- [ ] **Step 9.3: Commit**

```bash
git add management-frontend/app/pages/account/index.vue
git commit -m "feat(account): add /account page composing the 5 personal cards"
```

### Chunk 2 verification

- [ ] **Step C2.1: End-of-chunk smoke**

Walk both `/account` and `/settings` in admin role. Both pages should look identical for the 5 personal sections (the duplication is temporary — Chunk 3 removes them from `/settings`).

---

## Chunk 3: Settings page rewrite (5 cards + page rewrite)

Extracts the 5 admin sections into card components, then rewrites `pages/settings/index.vue` so it composes only the admin cards inside an admin gate, and the personal sections are deleted in the same commit.

### Task 10: Extract `ImprintCard.vue`

**Source:** `pages/settings/index.vue` script lines 291–372 + the watch on lines 374–380, template lines 933–1033.

- [ ] **Step 10.1: Create `management-frontend/app/components/settings/ImprintCard.vue`**

```vue
<script setup lang="ts">
import { IconBuildingStore } from '@tabler/icons-vue'

const { t } = useI18n()
const supabase = useSupabaseClient()
const { organization, role } = useOrganization()

interface ImprintForm {
  legal_name: string
  contact_email: string
  contact_phone: string
  website: string
  address_street: string
  address_house_number: string
  address_postal_code: string
  address_city: string
}

const imprintForm = reactive<ImprintForm>({ /* ...same defaults... */ })
const imprintLoading = ref(false)
const imprintError = ref('')
const imprintSuccess = ref('')

async function loadImprint() { /* copy verbatim */ }
async function saveImprint() { /* copy verbatim */ }

watch(() => organization.value?.id, (id) => {
  if (import.meta.client && id && role.value === 'admin') loadImprint()
}, { immediate: true })
</script>

<template>
  <!-- Copy <!-- Company Imprint --> block (lines 933–1033) verbatim,
       BUT remove the outer v-if="role === 'admin'" wrapper since the page
       already gates on isAdmin. Keep all internal markup the same. -->
</template>
```

The watch in `pages/settings/index.vue:374-380` is shared with AI key + Stripe; here we narrow it to `loadImprint()` only. Each card owns its own load watcher.

- [ ] **Step 10.2: Smoke test (compile only).**

- [ ] **Step 10.3: Commit**

```bash
git add management-frontend/app/components/settings/ImprintCard.vue
git commit -m "feat(settings): extract ImprintCard from settings page"
```

### Task 11: Extract `AiKeyCard.vue`

**Source:** `pages/settings/index.vue` script lines 220–289, template lines 1034–1098.

- [ ] **Step 11.1: Create `management-frontend/app/components/settings/AiKeyCard.vue`**

Mirror the ImprintCard pattern: own `watch(() => organization.value?.id, ...)` calling `loadAiKey()` only. Strip the outer admin `v-if` from the template.

Imports needed: `IconSparkles`, `IconEye`, `IconEyeOff` (for show/hide key), `useI18n`, `useSupabaseClient`, `useOrganization`.

- [ ] **Step 11.2: Smoke test (compile only).**

- [ ] **Step 11.3: Commit**

```bash
git add management-frontend/app/components/settings/AiKeyCard.vue
git commit -m "feat(settings): extract AiKeyCard from settings page"
```

### Task 12: Extract `StripeCard.vue`

**Source:** `pages/settings/index.vue` script lines 382–480, template lines 1099–1203.

- [ ] **Step 12.1: Create `management-frontend/app/components/settings/StripeCard.vue`**

Imports: `IconCreditCard`, `IconCopy`, `IconEye`, `IconEyeOff`, `useI18n`, `useSupabaseClient`, `useOrganization`, `useRuntimeConfig` (for `stripeWebhookUrl` computed).

State: `stripeSecretInput`, `stripePubInput`, `stripeWebhookInput`, `stripeSecretMasked`, `stripePubMasked`, `stripeWebhookMasked`, `stripeHasKeys`, `stripeLoading`, `stripeError`, `stripeSuccess`, `stripeSecretVisible`. Helper `maskKey`. Functions `loadStripeKeys`, `saveStripeKeys`, `removeStripeKeys`. Computed `stripeWebhookUrl`. Own watch on `organization.value?.id`.

- [ ] **Step 12.2: Smoke test (compile only).**

- [ ] **Step 12.3: Commit**

```bash
git add management-frontend/app/components/settings/StripeCard.vue
git commit -m "feat(settings): extract StripeCard from settings page"
```

### Task 13: Extract `DealSearchCard.vue`

**Source:** `pages/settings/index.vue` script lines 482–533, template lines 1204–1326.

- [ ] **Step 13.1: Create `management-frontend/app/components/settings/DealSearchCard.vue`**

Imports: `IconTag`, `useI18n`, `useOrganization`, `useDeals`, `getDealsPreset`. Pull `companyCountry` from `useTaxSettings()` (the deal preset depends on the country).

State: `editingKeywords`, `genericTermsText`, `wildcardPhrasesText`, `appPatternsText`. Functions `startEditingKeywords`, `applyKeywordEdits`, `resetToDefaults`. Plus the `useDeals()` destructured refs/methods. Own watch on `organization.value?.id`.

> **Note on `companyCountry`:** comes from `useTaxSettings()`, which uses `useState('company-country', …)` — globally shared, so calling the composable again in `DealSearchCard` returns the same ref that `TaxCard` writes to. No extra Supabase lookup needed.

- [ ] **Step 13.2: Smoke test (compile only).**

- [ ] **Step 13.3: Commit**

```bash
git add management-frontend/app/components/settings/DealSearchCard.vue
git commit -m "feat(settings): extract DealSearchCard from settings page"
```

### Task 14: Extract `TaxCard.vue` (with both modals)

**Source:** `pages/settings/index.vue` script lines 535–693, template lines 1327–1566.

This is the biggest admin card. Modals stay inside this file (tightly coupled, not reused elsewhere).

- [ ] **Step 14.1: Create `management-frontend/app/components/settings/TaxCard.vue`**

Imports: `IconReceipt2`, `IconPlus`, `IconPencil`, `IconTrash`, `useI18n`, `useOrganization`, `useTaxSettings`. The dynamic import of `COUNTRY_OPTIONS` stays:

```ts
const { COUNTRY_OPTIONS } = await import('~/composables/useTaxSettings')
```

State + functions: copy verbatim from script lines 535–693. Own watch on `organization.value?.id` calling `fetchTaxAll(id)`.

Template: copy lines 1327–1566 (this includes the Tax Settings card AND both modals — TaxClassModal at l. 1454, TaxRateModal at l. 1500). Strip the outer admin `v-if`.

- [ ] **Step 14.2: Smoke test (compile only).**

- [ ] **Step 14.3: Commit**

```bash
git add management-frontend/app/components/settings/TaxCard.vue
git commit -m "feat(settings): extract TaxCard (with modals) from settings page"
```

### Task 15: Rewrite `pages/settings/index.vue`

**Files:**
- Modify (full rewrite): `management-frontend/app/pages/settings/index.vue`

This task replaces the 1753-line file with a small composition that:
1. Adds the page-level admin gate
2. Renders the 5 settings cards for admins, the no-access hint for everyone else
3. Drops the old `<!-- App Version -->` block
4. Drops all the personal sections (now lives at `/account`)

- [ ] **Step 15.1: Replace the file content**

Overwrite `management-frontend/app/pages/settings/index.vue` with:

```vue
<script setup lang="ts">
definePageMeta({ middleware: 'auth' })

const { t } = useI18n()
const { role } = useOrganization()
const isAdmin = computed(() => role.value === 'admin')
</script>

<template>
  <div class="flex flex-1 flex-col gap-6 p-4 md:p-6">
    <h1 class="text-2xl font-semibold">{{ t('settings.title') }}</h1>

    <div v-if="!isAdmin" class="max-w-3xl rounded-lg border bg-card p-6 text-sm text-muted-foreground">
      {{ t('settings.noAccessHint') }}
    </div>

    <div v-else class="grid w-full max-w-3xl gap-6">
      <SettingsImprintCard />
      <SettingsAiKeyCard />
      <SettingsStripeCard />
      <SettingsDealSearchCard />
      <SettingsTaxCard />
      <NuxtLink
        to="/settings/extensions"
        class="inline-flex h-9 w-fit items-center gap-2 rounded-md border bg-card px-4 text-sm font-medium shadow-sm transition-colors hover:bg-accent"
      >
        {{ t('settings.extensionsLink') }}
      </NuxtLink>
    </div>
  </div>
</template>
```

The 1753-line file is now ~25 lines. The 5 admin cards are auto-imported; the extensions link is just a `NuxtLink`.

- [ ] **Step 15.2: Smoke test in admin role**

Visit `/settings`. Verify:
1. Imprint, AI Insights, Stripe, Deal Search, Tax sections all render and behave the same as before (load existing values, save round-trip, etc.).
2. The "Manage extensions" link routes to `/settings/extensions`.
3. No Profile / Email / Password / Appearance / Push / App Version sections visible (they moved to `/account`).
4. Browser console: no errors.

- [ ] **Step 15.3: Smoke test in viewer role**

Log out, log in as a viewer (or change a test user's role to `viewer` in Supabase Studio). Visit `/settings`. Verify:
1. Heading "Account Settings" / "Kontoeinstellungen" still shows.
2. Below it: only the no-access hint card with the message "No settings available for your role." / "Keine Einstellungen für deine Rolle verfügbar."
3. No section content. No errors.

Restore the role to admin afterwards if you changed it.

- [ ] **Step 15.4: Commit**

```bash
git add management-frontend/app/pages/settings/index.vue
git commit -m "refactor(settings): page composes admin cards behind isAdmin gate

Drops the personal sections (moved to /account in earlier commits) and the
inline App Version block (now in sidebar footer). Each admin section is now
its own card component."
```

### Chunk 3 verification

- [ ] **Step C3.1: Full app smoke**

Walk through these flows in order:

| Step | Path | Action | Expected |
|------|------|--------|----------|
| 1 | `/account` | Edit name → save | Toast / success message; reload shows new name |
| 2 | `/account` | Toggle dark mode | Theme flips immediately |
| 3 | `/account` | Subscribe to push, send test, unsubscribe | All three succeed |
| 4 | `/settings` (admin) | Edit imprint legal name → save → reload | Persists |
| 5 | `/settings` (admin) | Open AI Insights card | Existing key shows masked, can replace |
| 6 | `/settings` (admin) | Open Stripe card | Existing keys show masked, webhook URL renders |
| 7 | `/settings` (admin) | Open Deal Search card | Toggle works, keywords editable |
| 8 | `/settings` (admin) | Open Tax card | Country selector works, classes list renders, can add a class then delete it |
| 9 | `/settings/extensions` | From the link on `/settings` | Existing extensions landing page loads |
| 10 | Sidebar footer | Look at version | `vX.Y.Z` line above user avatar |
| 11 | Avatar dropdown | Click | Two entries: Account, Settings (plus language + logout) |

If any step fails, fix before proceeding.

---

## Chunk 4: Cleanup & polish

### Task 16: Audit residual references

- [ ] **Step 16.1: Grep for stale references**

```bash
grep -rn "to=\"/settings\"" management-frontend/app/ | grep -v node_modules
```

Expected: only 2 hits — the new `<NuxtLink to="/settings">` in `NavUser.vue` and the existing admin CTA in `app/pages/deals/index.vue:384`. No stale references should remain.

- [ ] **Step 16.2: Confirm settings/index.vue is small now**

```bash
wc -l management-frontend/app/pages/settings/index.vue
```

Expected: under 40 lines.

- [ ] **Step 16.3: Confirm dev server has no warnings**

Look at the dev-server terminal output. There should be no `[Vue warn]`, no missing-translation messages for the new keys, no failed imports.

If anything is off, debug and fix before commit.

### Task 17: Final smoke + handoff

- [ ] **Step 17.1: Run typecheck (if available)**

```bash
cd management-frontend
npx nuxi typecheck 2>&1 | tail -50
```

Expected: no errors related to the new files. Pre-existing repo-wide type warnings can stay.

If `nuxi typecheck` is not configured, skip this step — the Nuxt dev server already validates Vue + TS at runtime.

- [ ] **Step 17.2: Run tests**

```bash
cd management-frontend
npm test 2>&1 | tail -30
```

Expected: all existing tests pass. We did not add new tests; we did not break existing ones.

- [ ] **Step 17.3: Final commit (if any cleanup happened)**

If steps 16–17 surfaced anything to fix, commit it as `chore(settings): final cleanup` and push.

If everything was already clean, no commit is needed for this task.

- [ ] **Step 17.4: Verify the worktree is ready for review**

```bash
git log --oneline main..HEAD
git status
```

Expected: a clean tree and ~16 new commits on this branch (1 i18n + 1 sidebar + 1 navuser + 5 account cards + 1 account page + 5 settings cards + 1 settings rewrite + optional cleanup, on top of the spec/plan doc commits already on the branch).

---

## Done

The user dropdown now exposes both `/account` (per-user) and `/settings` (org/admin). The 1753-line monolith is broken into 10 self-contained cards under `app/components/account/` and `app/components/settings/`. The app version surfaces in the sidebar footer on every page.

Closing checklist:

- [ ] Spec lives at [docs/superpowers/specs/2026-05-06-split-account-and-settings-design.md](../specs/2026-05-06-split-account-and-settings-design.md).
- [ ] All commits made with sensible messages.
- [ ] No orphaned references to `/settings` that should now be `/account`.
- [ ] All 6 smoke-test scenarios passing in admin role; viewer role shows the no-access hint.
