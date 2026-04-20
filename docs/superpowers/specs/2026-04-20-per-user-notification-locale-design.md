# Per-User Notification Locale — Design

**Date:** 2026-04-20
**Status:** Draft
**Owner:** Lucien Kerl

## Summary

Push notifications today are English-only, regardless of the recipient's
preferred language. This spec adds per-user localization: each user's
preferred language is stored in a new `public.users.locale` column, the
edge-function push dispatcher fetches that column alongside the
subscriptions and renders one payload per locale group, and the clients
(iOS native app + web PWA) write their current language back to the DB
when it changes.

Scope is intentionally small: two languages (`en` and `de`, matching the
web frontend's existing i18n), ~8 short notification strings, and
locale-aware currency formatting (`€2.50` / `2,50 €`). Product names,
machine names, and the `🛒`/`🟡`/`⚠️` emoji prefixes stay universal.

## Problem

- Every push notification body/title/subtitle is hardcoded English in
  `Docker/supabase/functions/mqtt-webhook/index.ts` and
  `Docker/supabase/functions/test-push/index.ts`.
- The web frontend uses `@nuxtjs/i18n` (en/de) — users can already
  operate the dashboard in their preferred language — but pushes arrive
  in English regardless.
- The iOS app has a partially localized `Localizable.xcstrings` (source
  en, partial de) so the UI already follows device language. Pushes do
  not.
- There is no server-side record of each user's preferred language.
  The Nuxt i18n default persistence is the `i18n_redirected` cookie,
  which is client-only.

## Goals

- Each user has a persistent server-side `locale` preference.
- Web frontend writes the preference when the user changes language
  via the `LanguageSwitcher`.
- iOS app writes the device's system language on login and app resume
  (auto-detect; no user-facing picker in v1).
- Edge functions that send pushes render title/subtitle/body in the
  recipient's locale, including locale-aware currency formatting.
- Users without a preference fall back to `'en'` — matches today's
  behaviour byte-for-byte.
- Works on both dev and prod Supabase without config changes.

## Non-Goals

- **No new languages beyond en/de in this increment.** A check
  constraint keeps it that way. Adding a language later is a one-line
  migration + two entries in the translation dict.
- **No per-user explicit override in the iOS app.** Device language
  is the single source of truth; iOS users change it in iOS Settings.
  A manual picker can be added later if someone requests it.
- **No translation of product or machine names.** Those are user input;
  keep as entered.
- **No translation of emoji prefixes** (`🛒`, `💵`, `🟡`, `⚠️`, `🚨`).
- **No localization of other edge-function responses** (create-org,
  accept-invitation, etc.) — this is a push-notification scope only.
- **No `notification_preferences.locale_override`.** YAGNI — a user
  who wants different language for pushes vs. app UI is a hypothetical
  we don't have yet.

## Architecture

### 1. DB migration

New idempotent migration file
`Docker/supabase/migrations/<timestamp>_user_locale.sql`:

```sql
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS locale text NOT NULL DEFAULT 'en'
  CHECK (locale IN ('en', 'de'));
```

No RLS change needed — `users_select` and `users_select_same_company`
already cover the read side, and the owner-only update policy covers
the write side (each user can only update their own row).

### 2. Backend i18n dict

New file `Docker/supabase/functions/_shared/notification-i18n.ts`
exports:

- `type Locale = 'en' | 'de'`
- `normalizeLocale(raw: string | null | undefined): Locale` — clamps
  any unknown value to `'en'`, accepts `'de'` as-is, lowercases input,
  accepts `de-DE` / `en-US` by taking the first segment.
- `t(locale: Locale): TranslationSet` — returns an object with ~8
  fields (`sale`, `left`, `refillAt(n)`, `noStockInfo`,
  `lowStockTitle`, `remaining`, `testMachine`, `sampleProduct`).
  `refillAt` is a function, not a string, because DE needs the number
  mid-sentence.
- `formatPrice(amount: number, locale: Locale): string` — uses
  `Intl.NumberFormat('de-DE', ...)` for `'de'` (→ `"2,50 €"`) and
  `'en-GB'` for `'en'` (→ `"€2.50"`). Always EUR.

Translation table (final copy, locked via unit tests):

| Key | en | de |
|-----|----|----|
| sale | `Sale` | `Verkauf` |
| left | `left` | `übrig` |
| refillAt(n) | `refill at {n}` | `nachfüllen bei {n}` |
| noStockInfo | `No stock info` | `Kein Bestand` |
| lowStockTitle | `Low Stock Alert` | `Bestandswarnung` |
| remaining | `remaining` | `übrig` |
| testMachine | `Test Machine` | `Testmaschine` |
| sampleProduct | `Sample Product` | `Beispielprodukt` |

### 3. `sendPushToUsers` refactor

The shared helper in `Docker/supabase/functions/_shared/web-push.ts`
changes its fourth argument from `payload: PushPayload` to
`buildPayload: (locale: Locale) => PushPayload`.

Pseudocode of the new recipient loop:

```ts
// After the existing member/disabled/suppressed filtering:
const recipients = filtered subscriptions

// Bulk-fetch locale for all recipient users (one query).
const userIds = [...new Set(recipients.map(s => s.user_id))]
const { data: userRows } = await adminClient
  .from('users')
  .select('id, locale')
  .in('id', userIds)
const localeByUser = new Map<string, Locale>(
  (userRows ?? []).map(r => [r.id, normalizeLocale(r.locale)])
)

// Group recipients by locale (default 'en' if user row missing).
const groups = new Map<Locale, PushSubscription[]>()
for (const sub of recipients) {
  const loc = localeByUser.get(sub.user_id) ?? 'en'
  ;(groups.get(loc) ?? groups.set(loc, []).get(loc)!).push(sub)
}

// Dispatch per locale.
for (const [loc, subs] of groups) {
  const payload = buildPayload(loc)
  // existing iOS / Android / web push loops, but restricted to `subs`
}
```

Return shape (`{ sent, expired }`) unchanged.

### 4. Caller updates

`mqtt-webhook/index.ts` for the **sale** dispatch:

```ts
await sendPushToUsers(adminClient, embedded.company, 'sale', (locale) => {
  const strings = t(locale)
  const priceStr = formatPrice(salePrice, locale)
  const itemLabel = productName ?? `Item #${itemNumber}`
  const machineLabel = machine?.name ? ` · ${machine.name}` : ''
  const saleTitle = `💵 ${strings.sale}${machineLabel}`
  const saleSubtitle = `${itemLabel} — ${priceStr}`
  const saleBody = /* tray check, stockUrgency, strings.left, strings.refillAt(tray.fill_when_below) */
    ? `${emoji}${tray.current_stock}/${tray.capacity} ${strings.left} — ${strings.refillAt(tray.fill_when_below)}`
    : strings.noStockInfo
  return { title: saleTitle, subtitle: saleSubtitle, body: saleBody, image: productImageUrl, data: {...} }
})
```

Same pattern for the **low_stock** branch (uses `strings.lowStockTitle`
and `strings.remaining`).

`test-push/index.ts` for the simulator:

```ts
await sendPushToUsers(adminClient, membership.company_id, '_test', (locale) => {
  const strings = t(locale)
  const productName = testProductName ?? strings.sampleProduct
  const priceStr = formatPrice(2.50, locale)
  const dummyBody = `🟡 6/10 ${strings.left} — ${strings.refillAt(5)}`
  return {
    title: `💵 ${strings.sale} · ${strings.testMachine}`,
    subtitle: `${productName} — ${priceStr}`,
    body: dummyBody,
    image: testImageUrl,
    data: { type: 'test' },
  }
})
```

### 5. iOS: auto-detect + sync

In `AuthService` (or a small new `LocaleSyncService`):

```swift
/// Read device primary language and sync to users.locale.
/// Call on: successful login, app resume, and language-change notification.
func syncLocaleToServer() async {
    let deviceCode = Locale.current.language.languageCode?.identifier ?? "en"
    let locale = (deviceCode == "de") ? "de" : "en"  // clamp unknown to en
    
    // Cache last-synced value to skip redundant writes.
    let cacheKey = "last-synced-locale"
    if UserDefaults.standard.string(forKey: cacheKey) == locale { return }
    
    do {
        let userId = try await client.auth.session.user.id
        try await client.from("users")
            .update(["locale": locale])
            .eq("id", value: userId)
            .execute()
        UserDefaults.standard.set(locale, forKey: cacheKey)
    } catch {
        // Best-effort; log but don't surface. Default 'en' is fine if sync fails.
    }
}
```

Hooks:
- `AuthService.setSession(_:)` (post-login) → `Task { await syncLocaleToServer() }`
- `VMflowApp.onAppear` scene phase `.active` → same call
- `NSLocale.currentLocaleDidChangeNotification` observer → same call

### 6. Web frontend: persist on switch

`app/components/LanguageSwitcher.vue` — `switchLocale(code)` currently
only calls `setLocale(code)`. Wrap into a helper that also writes to
`users.locale`:

```vue
async function switchLocale(code: string) {
  await setLocale(code)
  try {
    const supabase = useSupabaseClient()
    const user = useSupabaseUser()
    if (user.value) {
      await supabase.from('users').update({ locale: code }).eq('id', user.value.id)
    }
  } catch {
    // ignore — setLocale cookie is still set, push localization will just use default
  }
}
```

Optional small composable `useLocaleSync.ts` that:
- On mounted: compare `useI18n().locale.value` with `users.locale`; if
  user's stored locale differs and hasn't yet been synced, write it.
- This covers users who previously only set the cookie and haven't
  used the switcher since the feature shipped.

### 7. Backward compatibility

- Users created before the migration get `locale='en'` by default →
  identical pushes to today.
- Edge functions with the new code but missing `users` row still
  default to `'en'` via the `?? 'en'` in the group loop.
- Rollback: revert the edge-function commits only. The `locale` column
  stays in DB, harmless.
- iOS app on old version: doesn't write locale → stays at DB default
  `'en'` → sees English pushes (no regression).

## Data Flow

```
On language change (web) or app start (iOS):
  client → PATCH users.locale → Postgres

On sale event:
  ESP32 → MQTT → forwarder → mqtt-webhook edge function
    │
    ├── Insert sales row
    ├── Machine + tray + product lookup
    │
    ├── sendPushToUsers('sale', buildPayload)
    │     ├── Filter recipients (existing logic)
    │     ├── SELECT users.locale WHERE id IN (recipient user ids)
    │     ├── Group recipients by locale
    │     └── For each locale:
    │           payload = buildPayload(locale)  ← runs translation dict
    │           dispatch via APNs/FCM/VAPID to that group
    │
    └── Low-stock branch (similar, suppressIfAlsoEnabled: 'sale' preserved)
```

## Testing

### Unit tests (Deno)

New file `Docker/supabase/functions/_shared/notification-i18n.test.ts`:

- `normalizeLocale` — clamps arbitrary input to `'en'`/`'de'`:
  - `normalizeLocale('de')` → `'de'`
  - `normalizeLocale('DE')` → `'de'`
  - `normalizeLocale('de-DE')` → `'de'`
  - `normalizeLocale('fr')` → `'en'`
  - `normalizeLocale(null)` → `'en'`
  - `normalizeLocale(undefined)` → `'en'`
- `t('de').refillAt(5)` → `'nachfüllen bei 5'`
- `t('en').refillAt(5)` → `'refill at 5'`
- `formatPrice(2.5, 'de')` — contains `'2,50'` and `'€'`
- `formatPrice(2.5, 'en')` — contains `'2.50'` and `'€'`
- All 8 translation keys exist for both locales (dictionary completeness)

### Integration tests (manual)

1. User A with device locale `de`: trigger test push → subtitle shows
   `2,50 €`, body shows `6/10 übrig — nachfüllen bei 5`, title shows
   `💵 Verkauf · Testmaschine`.
2. User B with device locale `en` in same company: same test push
   event, different payload → `€2.50`, `6/10 left — refill at 5`,
   `💵 Sale · Test Machine`.
3. Two users with different locales receive independent APNs payloads
   for the same sale (check edge-function logs for two
   `sent: 1` dispatches instead of one `sent: 2`).
4. User with stale DB row (`locale` never written) → falls back to
   `'en'` cleanly.
5. Web frontend: toggle language → check `users.locale` updates in
   Supabase Studio.
6. iOS: change device language in iOS Settings → reopen app →
   `users.locale` updates to new value.
7. Low-stock push respects `suppressIfAlsoEnabled: 'sale'` AND is
   translated — user subscribed only to `low_stock` with `de` locale
   gets `"Bestandswarnung"` title.

## Rollout

Landing order:

1. **Migration + backend** (Chunk A): users without locale rows get
   `'en'` default. Pushes still English. No visible user-facing change
   until a locale is written.
2. **iOS auto-sync** (Chunk B): pushes to iOS users on German devices
   start arriving in German.
3. **Web switcher** (Chunk C): pushes to users who last set language
   via the web dashboard start following that choice.

Each chunk is independently revertable without breaking the others.

## References

- Spec's predecessor: `docs/superpowers/specs/2026-04-19-sale-notification-stock-info-design.md`
- Push dispatcher: `Docker/supabase/functions/_shared/web-push.ts`
- Sale path: `Docker/supabase/functions/mqtt-webhook/index.ts:309-395`
- Frontend i18n: `management-frontend/i18n/locales/{en,de}.json` + `app/components/LanguageSwitcher.vue`
- iOS localization: `ios/VMflow/Resources/Localizable.xcstrings`
- iOS device locale API: `Locale.current.language.languageCode` (Foundation, iOS 16+)
