# Split Account and Settings Pages

**Date:** 2026-05-06
**Status:** Draft

## Problem

The current `/settings` page (`management-frontend/app/pages/settings/index.vue`, 1753 lines) mixes two scopes of configuration in a single screen:

- **Per-user / personal scope** — name, e-mail, password, dark mode, push notifications.
- **Organisation / admin scope** — imprint, AI Insights API key, Stripe keys, deal search, tax classes, extensions, app version.

The `NavUser` dropdown labels its only entry "Account" (`nav.account`) but routes to `/settings`, where admin-only sections dominate the page. The semantic mismatch makes the page harder to scan, and any new viewer-visible setting compounds the problem.

We want to split the page along the scope boundary so each destination has a single coherent purpose.

## Goals

- Two distinct destinations with clear scope boundaries
  - `/account` — per-user settings (visible to all roles)
  - `/settings` — organisation/admin settings (entry visible to all; content admin-only)
- Existing `/settings` URL preserved (no broken bookmarks; `/settings/extensions/*` untouched)
- Sidebar footer surfaces the app version on every page
- Each section becomes its own self-contained component, replacing the 1753-line monolith
- Zero backend changes (no DB migration, edge functions, MQTT, or firmware impact)

## Non-Goals

- No i18n key namespace renaming. Existing `settings.*` keys stay; only one new `nav.settings` key is added. The keys describe UI strings, not pages — renaming would be a large risky diff with no UX benefit.
- No new admin-vs-viewer permission model. We reuse `useOrganization().role`.
- No deep-linking to specific cards (`/settings#tax`). Out of scope for this change.
- No mobile bottom-tab-bar entry for either page. Both stay reachable via the user dropdown only.
- No tests for the existing settings page existed; we do not back-fill them.

## Routes

| Route | Visible to | Content |
|-------|-----------|---------|
| `/account` | All authenticated users with an organisation | Profile, e-mail, password, appearance, push notifications |
| `/settings` | All authenticated users with an organisation | If admin: imprint, AI key, Stripe, deal search, tax, extensions link, app version. If viewer: short hint "Keine Einstellungen für deine Rolle verfügbar". |
| `/settings/extensions/*` | Unchanged (admin-gated as today) | Existing extension landing + provider pages |

The auth middleware (`app/middleware/auth.ts`) uses a public-route allowlist, so `/account` is automatically protected without changes.

## Navigation

### `NavUser.vue` (avatar dropdown)

Currently has one entry "Account" → `/settings`. After the change:

```
┌────────────────────────────────┐
│ Avatar / Name / E-Mail         │
├────────────────────────────────┤
│ 👤 Account     →  /account     │  (new label key: nav.account, existing)
│ ⚙ Einstellungen → /settings    │  (new label key: nav.settings)
├────────────────────────────────┤
│ 🌐 Language Switcher           │  (unchanged)
├────────────────────────────────┤
│ ⏏ Logout                       │  (unchanged)
└────────────────────────────────┘
```

Both entries are visible to every role. Viewers clicking "Einstellungen" land on the page-level hint instead of section content — accepted UX trade-off in lieu of role-conditional dropdown items.

### `AppSidebar.vue` (sidebar footer)

`SidebarFooter` currently contains only `<NavUser />`. We add a small text line above `NavUser` displaying the app version:

```
SidebarFooter
├── <span class="px-2 text-xs text-muted-foreground">v{{ config.public.appVersion }}</span>
└── <NavUser />
```

`config.public.appVersion` is the same value the existing `/settings` page reads — no Nuxt config change.

## Architecture

### File layout

```
app/
├── pages/
│   ├── account/
│   │   └── index.vue          # NEW — composes 5 account cards
│   └── settings/
│       └── index.vue          # REWRITTEN — admin gate + 6 settings cards
└── components/
    ├── account/
    │   ├── ProfileCard.vue
    │   ├── EmailCard.vue
    │   ├── PasswordCard.vue
    │   ├── AppearanceCard.vue
    │   └── PushNotificationsCard.vue
    ├── settings/
    │   ├── ImprintCard.vue
    │   ├── AiKeyCard.vue
    │   ├── StripeCard.vue
    │   ├── DealSearchCard.vue
    │   ├── TaxCard.vue
    │   └── AppVersionCard.vue
    ├── AppSidebar.vue          # MODIFIED — add version line in footer
    └── NavUser.vue             # MODIFIED — split dropdown entries
```

### Component contracts

Each card is a self-contained Vue SFC. Inputs: none (no props). Side effects: each card owns its own Supabase calls, refs, and local error/success state. No shared state between cards — extraction is mechanical, not architectural.

| Component | Owns | Notes |
|-----------|------|-------|
| `ProfileCard` | first/last name form, save to `users` table | Reads `useSupabaseUser`, writes via supabase client |
| `EmailCard` | E-mail change form | `supabase.auth.updateUser({ email })` |
| `PasswordCard` | Password change form | `supabase.auth.updateUser({ password })` |
| `AppearanceCard` | Dark mode toggle | Wraps `useTheme()` |
| `PushNotificationsCard` | Master toggle, per-type toggles, registered devices, SW diagnostics, test push | Most complex card. Wraps `useNotifications()`. Tax-card-style: stays one file even though it has internal sub-sections. |
| `ImprintCard` | Legal name, e-mail, phone, website, address | Saves to `companies.imprint_*` columns |
| `AiKeyCard` | Anthropic API key entry/replace/remove | Updates `companies.anthropic_api_key` |
| `StripeCard` | Stripe secret + publishable + webhook secret + read-only webhook URL | Three keys to companies table; webhook URL is computed |
| `DealSearchCard` | Enable toggle, ZIP, keywords (generic terms + wildcard phrases) | Saves to `companies.deal_*` columns |
| `TaxCard` | Country selector, classes list with rates, seed defaults, modals (TaxClassModal, TaxRateModal) | Modals stay inside this file — tightly coupled, not reused. |

> **Auto-import naming:** Nuxt 4 flattens nested component directories into a PascalCase prefix, so `app/components/account/ProfileCard.vue` becomes `<AccountProfileCard />` and `app/components/settings/ImprintCard.vue` becomes `<SettingsImprintCard />`. The names in the page templates already follow this convention.

> **Push notification lifecycle:** The current `pages/settings/index.vue` calls `initNotifications()` in `onMounted()`. That lifecycle hook moves *with* the section into `PushNotificationsCard.vue` — it now fires on `/account` mount instead of `/settings` mount. Intended behaviour, no change in logic.

The app version is shown in the sidebar footer on *every* page (see Navigation section), so a dedicated `AppVersionCard` on `/settings` would duplicate the same read for no benefit. The current "App Version" block in `pages/settings/index.vue` is removed without replacement.

### Page composition

`pages/account/index.vue` (rough structure):

```vue
<template>
  <div class="container max-w-3xl space-y-6 p-4">
    <h1 class="text-2xl font-semibold">{{ t('account.title') }}</h1>
    <AccountProfileCard />
    <AccountEmailCard />
    <AccountPasswordCard />
    <AccountAppearanceCard />
    <AccountPushNotificationsCard />
  </div>
</template>
```

`pages/settings/index.vue` (rough structure):

```vue
<script setup lang="ts">
const { t } = useI18n()
const { role } = useOrganization()
const isAdmin = computed(() => role.value === 'admin')
</script>

<template>
  <div class="container max-w-3xl space-y-6 p-4">
    <h1 class="text-2xl font-semibold">{{ t('settings.title') }}</h1>

    <div v-if="!isAdmin" class="rounded-lg border p-6 text-sm text-muted-foreground">
      {{ t('settings.noAccessHint') }}
    </div>

    <template v-else>
      <SettingsImprintCard />
      <SettingsAiKeyCard />
      <SettingsStripeCard />
      <SettingsDealSearchCard />
      <SettingsTaxCard />
      <NuxtLink to="/settings/extensions" class="...">{{ t('settings.extensionsLink') }}</NuxtLink>
    </template>
  </div>
</template>
```

Section-level `v-if="isAdmin"` guards inside the cards become unnecessary because the page-level wrapper already gates rendering. They are removed during extraction; defense-in-depth is provided at the data layer (the API key, Stripe, imprint, etc. tables / RPCs already enforce admin via RLS).

## i18n

Existing `settings.*` keys are untouched. New keys added:

| Key | en | de |
|-----|----|----|
| `nav.settings` | Settings | Einstellungen |
| `account.title` | Account | Account |
| `settings.noAccessHint` | No settings available for your role. | Keine Einstellungen für deine Rolle verfügbar. |
| `settings.extensionsLink` | Manage extensions | Extensions verwalten |

The existing `nav.account` key is reused for the dropdown label.

## External Links to `/settings`

A grep audit (`grep -rn "/settings" management-frontend/app`) found two non-internal references:

1. `app/components/NavUser.vue:118` — already being modified.
2. `app/pages/deals/index.vue:384` — admin-only "Deal-Suche aktivieren" CTA. Deal search lives in the new `/settings`, so the link is still semantically correct and needs no change.

## Migration / Backward Compatibility

- `/settings` URL is preserved. Bookmarks still resolve. Admins see the same content (organised differently); viewers see the access hint instead of the personal sections.
- `/settings/extensions/*` is not touched.
- No DB schema changes, no edge functions, no MQTT, no firmware. Pure frontend.

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Extraction loses an import or reactive ref → build break | Extract one card at a time, run `nuxi typecheck` and the dev server after each. |
| `PushNotificationsCard` is the largest extraction (permission states, SW diagnostics, test push) → highest risk of subtle regression | Extract last; smoke-test in a browser (subscribe → send test → unsubscribe) before merging. |
| Viewer lands on `/settings` and sees the hint without context | Hint copy is explicit ("Keine Einstellungen für deine Rolle verfügbar") and admins continue to see the full UI. Acceptable. |
| Hidden coupling between sections (shared refs, shared toast helpers) | Audit script-block of `pages/settings/index.vue` before extracting; each card declares its own toast/loading state. |

## Build Order

1. Add new i18n keys (`nav.settings`, `account.title`, `settings.noAccessHint`, `settings.extensionsLink`) in en + de.
2. Create the 5 account card components by extracting from `settings/index.vue`. Build new `pages/account/index.vue` composing them. Verify in browser.
3. Create the 5 settings card components by extracting the remaining org-scoped sections. Rewrite `pages/settings/index.vue` as the admin-gated composition. The rewrite naturally drops the old `<!-- App Version -->` block and the now-redundant per-section `v-if="isAdmin"` guards. Verify both admin and viewer views.
4. Update `NavUser.vue` to add the second dropdown entry.
5. Update `AppSidebar.vue` to add the app version line in `SidebarFooter`.
6. Smoke test: log in as admin and viewer, walk both routes, send a test push notification, save the imprint and re-open.

## Out of Scope (Future)

- Renaming `settings.*` i18n keys for personal sections to `account.*`. Cosmetic only; can be a later cleanup.
- A dedicated `/account` entry in the bottom tab bar (mobile). Currently no tab bar entry for either; can be added later if usage data shows it is missed.
- Admin-only role-conditional dropdown rendering (hide "Einstellungen" for viewers). Decided against in clarification phase — viewers see a clear hint instead.
