# Per-User Notification Locale Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Localize push notifications to each recipient's preferred language (en/de), with the preference stored server-side in `public.users.locale`, written by the web frontend on language switch and by the iOS app via device-locale auto-detect, and consumed by the edge-function dispatcher that groups recipients by locale and renders per-locale payloads.

**Architecture:** Four independent chunks. Chunk A adds a DB column, a small i18n helper module with unit tests, and refactors `sendPushToUsers` to take a locale-aware payload builder. Chunk B adds device-locale sync to the iOS app. Chunk C makes the web `LanguageSwitcher` persist to DB. Chunk D is manual end-to-end verification. Each chunk ships independently; backward compat is preserved throughout (missing locale → `'en'` default → today's behavior).

**Tech Stack:** Deno 1.x edge runtime, TypeScript, Supabase (PostgreSQL + Auth + Edge Functions), Swift 5.9 / iOS 17 (`Locale.current` + Foundation), Nuxt 4 (`@nuxtjs/i18n` + `@nuxtjs/supabase`).

**Spec:** `docs/superpowers/specs/2026-04-20-per-user-notification-locale-design.md`

---

## File Map

**New files:**

- `Docker/supabase/migrations/<timestamp>_user_locale.sql` — idempotent migration adding `public.users.locale`.
- `Docker/supabase/functions/_shared/notification-i18n.ts` — `Locale` type, `normalizeLocale`, `t(locale)`, `formatPrice(amount, locale)`.
- `Docker/supabase/functions/_shared/notification-i18n.test.ts` — Deno unit tests for the helpers above.

**Modified files (backend):**

- `Docker/supabase/functions/_shared/web-push.ts` — `sendPushToUsers` signature: 4th arg becomes `buildPayload: (locale: Locale) => PushPayload`. Internal: fetch `users.locale`, group by locale, dispatch per group.
- `Docker/supabase/functions/mqtt-webhook/index.ts` — sale + low_stock call sites use the builder form.
- `Docker/supabase/functions/test-push/index.ts` — simulator uses the builder form.

**Modified files (iOS):**

- `ios/VMflow/Services/AuthService.swift` — add `syncLocaleToServer()` method.
- `ios/VMflow/VMflowApp.swift` — scene-phase `onChange` hook → call sync on `.active`. Also trigger on successful login (already in AuthService flow).

**Modified files (web):**

- `management-frontend/app/components/LanguageSwitcher.vue` — `switchLocale` persists to `users.locale` after `setLocale`.

**Intentionally NOT touched:**

- `notification_preferences` schema — YAGNI for now (no per-user per-type locale override).
- Frontend i18n JSON files — UI translations already exist for en/de. This spec only affects server-rendered push copy.
- iOS `Localizable.xcstrings` — not needed, notifications are server-rendered.
- `Docker/supabase/functions/_shared/inbox-notify.ts` — existing caller of `sendPushToUsers`. Kept on the legacy (English-only) `PushPayload` form thanks to the backward-compatible signature. Migrating it to a localized builder is future work.
- `Docker/supabase/functions/check-low-stock/index.ts` — warehouse-low-stock cron. Also on the legacy form. Future work: translate its body to match the consistency users see in mqtt-webhook's machine-low-stock path.

---

## Conventions

- Commits end with the Claude co-author trailer via HEREDOC body:
  `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`
- User has explicitly approved working on `main`.
- Migration filenames: `YYYYMMDDHHMMSS_<slug>.sql` — pick a timestamp strictly greater than the latest existing migration. Check with `ls Docker/supabase/migrations/ | tail -5`.
- **Migrations are immutable once committed to `main`.** This plan only creates a new migration; never edit existing ones.
- Tests use Deno + `jsr:@std/assert` (see `stock-urgency.test.ts` for the pattern). Run from repo root as `deno test <path>`.
- Small surgical edits; don't reformat surrounding code.

---

## Chunk A: Backend Foundation

### Task A1: Migration for `users.locale`

**Files:**
- Create: `Docker/supabase/migrations/<timestamp>_user_locale.sql`

**Rationale:** Idempotent schema change. Users without an explicit preference default to `'en'` — matches today's behavior exactly.

- [ ] **Step 1: Pick a timestamp strictly greater than the latest migration**

```bash
ls /Users/lucienkerl/Development/mdb-esp32-cashless/Docker/supabase/migrations/ | sort | tail -3
```

Pick the next timestamp (e.g., `20260420000000_user_locale.sql`).

- [ ] **Step 2: Write the migration**

Create `Docker/supabase/migrations/20260420000000_user_locale.sql` (adjust timestamp if needed):

```sql
-- Per-user notification locale. Default 'en' matches prior behavior byte-for-byte.
-- CHECK keeps the column closed to en/de until a future migration opens it wider.
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS locale text NOT NULL DEFAULT 'en';

ALTER TABLE public.users
  DROP CONSTRAINT IF EXISTS users_locale_check;

ALTER TABLE public.users
  ADD CONSTRAINT users_locale_check CHECK (locale IN ('en', 'de'));
```

Note: the two-statement CHECK constraint pattern (drop-if-exists + add) is idempotent on re-runs. `ADD COLUMN IF NOT EXISTS` handles the additive case; the constraint follows the CLAUDE.md migration-immutability convention.

- [ ] **Step 3: Apply the migration to local dev**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/Docker/supabase
supabase migration up 2>&1 | tail -20
```

Expected: no errors. The CLI applies the new migration and records it.

- [ ] **Step 4: Verify the column exists with the right defaults**

```bash
docker exec supabase_db_supabase-test psql -U postgres -d postgres -c "\d public.users" 2>&1 | grep -iE "locale"
docker exec supabase_db_supabase-test psql -U postgres -d postgres -c "SELECT id, locale FROM public.users LIMIT 5;"
```

Expected: `locale | text | not null | 'en'::text` in schema; existing users all show `'en'`.

- [ ] **Step 5: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git add Docker/supabase/migrations/20260420000000_user_locale.sql
git commit -m "$(cat <<'EOF'
db: add users.locale column for per-user notification language

Idempotent migration — defaults to 'en' so existing users see
identical pushes to today. CHECK constraint keeps the column
closed to en/de; a future migration can open it wider.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task A2: `notification-i18n` module with TDD

**Files:**
- Create: `Docker/supabase/functions/_shared/notification-i18n.ts`
- Create: `Docker/supabase/functions/_shared/notification-i18n.test.ts`

**Rationale:** Three small pure helpers. TDD locks the dictionary and locale normalization. `formatPrice` goes through `Intl.NumberFormat` — test its output format, not the exact whitespace (Intl implementations vary slightly).

- [ ] **Step 1: Write the failing tests**

Create `Docker/supabase/functions/_shared/notification-i18n.test.ts`:

```typescript
/**
 * Tests for notification-i18n helpers.
 * Run: deno test Docker/supabase/functions/_shared/notification-i18n.test.ts
 */

import { assertEquals, assert, assertStringIncludes } from 'jsr:@std/assert'
import { normalizeLocale, t, formatPrice } from './notification-i18n.ts'

// ── normalizeLocale ──────────────────────────────────────────────────────────

Deno.test('normalizeLocale: accepts "de" and "en" as-is', () => {
  assertEquals(normalizeLocale('de'), 'de')
  assertEquals(normalizeLocale('en'), 'en')
})

Deno.test('normalizeLocale: case-insensitive', () => {
  assertEquals(normalizeLocale('DE'), 'de')
  assertEquals(normalizeLocale('En'), 'en')
})

Deno.test('normalizeLocale: strips region tag', () => {
  assertEquals(normalizeLocale('de-DE'), 'de')
  assertEquals(normalizeLocale('en-US'), 'en')
  assertEquals(normalizeLocale('de_AT'), 'de')
})

Deno.test('normalizeLocale: unknown → en', () => {
  assertEquals(normalizeLocale('fr'), 'en')
  assertEquals(normalizeLocale('xx-YY'), 'en')
})

Deno.test('normalizeLocale: null / undefined / empty → en', () => {
  assertEquals(normalizeLocale(null), 'en')
  assertEquals(normalizeLocale(undefined), 'en')
  assertEquals(normalizeLocale(''), 'en')
})

// ── t() dictionary ───────────────────────────────────────────────────────────

Deno.test('t: all keys present for both locales', () => {
  const expectedKeys = [
    'sale', 'left', 'refillAt', 'noStockInfo',
    'lowStockTitle', 'remaining', 'testMachine', 'sampleProduct',
  ]
  for (const key of expectedKeys) {
    assert(key in t('en'), `'en' missing key "${key}"`)
    assert(key in t('de'), `'de' missing key "${key}"`)
  }
})

Deno.test('t: en strings', () => {
  const en = t('en')
  assertEquals(en.sale, 'Sale')
  assertEquals(en.left, 'left')
  assertEquals(en.refillAt(5), 'refill at 5')
  assertEquals(en.noStockInfo, 'No stock info')
  assertEquals(en.lowStockTitle, 'Low Stock Alert')
  assertEquals(en.remaining, 'remaining')
  assertEquals(en.testMachine, 'Test Machine')
  assertEquals(en.sampleProduct, 'Sample Product')
})

Deno.test('t: de strings', () => {
  const de = t('de')
  assertEquals(de.sale, 'Verkauf')
  assertEquals(de.left, 'übrig')
  assertEquals(de.refillAt(5), 'nachfüllen bei 5')
  assertEquals(de.noStockInfo, 'Kein Bestand')
  assertEquals(de.lowStockTitle, 'Bestandswarnung')
  assertEquals(de.remaining, 'übrig')
  assertEquals(de.testMachine, 'Testmaschine')
  assertEquals(de.sampleProduct, 'Beispielprodukt')
})

// ── formatPrice ──────────────────────────────────────────────────────────────

Deno.test('formatPrice: en uses dot decimal, € prefix', () => {
  const s = formatPrice(2.5, 'en')
  assertStringIncludes(s, '2.50')
  assertStringIncludes(s, '€')
})

Deno.test('formatPrice: de uses comma decimal, € suffix', () => {
  const s = formatPrice(2.5, 'de')
  assertStringIncludes(s, '2,50')
  assertStringIncludes(s, '€')
})

Deno.test('formatPrice: handles whole numbers', () => {
  assertStringIncludes(formatPrice(10, 'en'), '10.00')
  assertStringIncludes(formatPrice(10, 'de'), '10,00')
})
```

- [ ] **Step 2: Run the tests and confirm they fail**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
deno test Docker/supabase/functions/_shared/notification-i18n.test.ts 2>&1 | tail -15
```

Expected: FAIL — "Module not found ./notification-i18n.ts" or similar.

- [ ] **Step 3: Implement the module**

Create `Docker/supabase/functions/_shared/notification-i18n.ts`:

```typescript
/**
 * Per-locale notification strings + price formatting for push pushes.
 *
 * Single source of truth for the ~8 strings we send to user devices.
 * Emoji prefixes (🛒 💵 🟡 ⚠️ 🚨) stay universal and are concatenated
 * by the callers; this module only supplies translated words and
 * locale-aware currency formatting.
 */

export type Locale = 'en' | 'de'

/**
 * Clamp any input (user-supplied locale, Accept-Language header,
 * iOS `Locale.current` code) to our supported set. Unknown → 'en'.
 */
export function normalizeLocale(raw: string | null | undefined): Locale {
  if (!raw) return 'en'
  const prefix = raw.toLowerCase().split(/[-_]/)[0] ?? ''
  return prefix === 'de' ? 'de' : 'en'
}

export interface TranslationSet {
  sale: string
  left: string
  refillAt: (threshold: number) => string
  noStockInfo: string
  lowStockTitle: string
  remaining: string
  testMachine: string
  sampleProduct: string
}

const en: TranslationSet = {
  sale: 'Sale',
  left: 'left',
  refillAt: (n) => `refill at ${n}`,
  noStockInfo: 'No stock info',
  lowStockTitle: 'Low Stock Alert',
  remaining: 'remaining',
  testMachine: 'Test Machine',
  sampleProduct: 'Sample Product',
}

const de: TranslationSet = {
  sale: 'Verkauf',
  left: 'übrig',
  refillAt: (n) => `nachfüllen bei ${n}`,
  noStockInfo: 'Kein Bestand',
  lowStockTitle: 'Bestandswarnung',
  remaining: 'übrig',
  testMachine: 'Testmaschine',
  sampleProduct: 'Beispielprodukt',
}

export function t(locale: Locale): TranslationSet {
  return locale === 'de' ? de : en
}

/**
 * Locale-aware EUR currency formatting.
 *   en → '€2.50'   (en-GB style, symbol-first)
 *   de → '2,50 €'  (de-DE style, symbol-last with NBSP separator)
 *
 * Callers embed the returned string directly in the notification body.
 */
export function formatPrice(amount: number, locale: Locale): string {
  const bcp47 = locale === 'de' ? 'de-DE' : 'en-GB'
  return new Intl.NumberFormat(bcp47, {
    style: 'currency',
    currency: 'EUR',
  }).format(amount)
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
deno test Docker/supabase/functions/_shared/notification-i18n.test.ts 2>&1 | tail -15
```

Expected: `ok | N passed | 0 failed`. All 13+ test cases green.

- [ ] **Step 5: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git add Docker/supabase/functions/_shared/notification-i18n.ts \
        Docker/supabase/functions/_shared/notification-i18n.test.ts
git commit -m "$(cat <<'EOF'
_shared: add notification-i18n module with en/de translations

Three pure helpers: normalizeLocale clamps any input to 'en'|'de',
t(locale) returns the translation dict (~8 strings), formatPrice
produces locale-aware EUR strings via Intl.NumberFormat. Unit-tested
with 13 Deno test cases covering dictionary completeness, locale
fallbacks, and currency format both sides.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Chunk B: Dispatch Refactor

### Task B1: `sendPushToUsers` accepts builder function (backward-compatible)

**Files:**
- Modify: `Docker/supabase/functions/_shared/web-push.ts`

**Rationale:** The 4th argument widens to a union type `PushPayload | ((locale) => PushPayload)`. Legacy callers (`inbox-notify.ts`, `check-low-stock/index.ts`) continue passing a plain `PushPayload` and behave identically to today — internally the dispatcher normalizes to a builder that ignores its argument. New callers (mqtt-webhook, test-push in B2/B3) pass the builder form to get locale-aware rendering. No existing caller needs to change.

**Backward-compat requirement (user-flagged):** there are FIVE existing `sendPushToUsers` call sites across `_shared/inbox-notify.ts`, `check-low-stock/index.ts`, `mqtt-webhook/index.ts` (×2), `test-push/index.ts`. This task cannot break the two legacy callers not covered by this plan.

- [ ] **Step 1: Import the helpers at the top of `web-push.ts`**

Add near the top (below the existing `import { createClient ... }` line):

```typescript
import { normalizeLocale, type Locale } from './notification-i18n.ts'
```

- [ ] **Step 2: Update the `sendPushToUsers` signature (accepts both old + new form)**

Find the existing export (search for `export async function sendPushToUsers`). Widen the 4th argument to a union type and normalize internally to a builder:

```typescript
export async function sendPushToUsers(
  adminClient: SupabaseClient,
  companyId: string,
  notificationType: string,
  payloadOrBuilder: PushPayload | ((locale: Locale) => PushPayload),
  options?: {
    suppressIfAlsoEnabled?: string
  },
): Promise<{ sent: number; expired: number }> {
  // Normalize to a builder. Legacy callers that pass a plain PushPayload
  // get the same payload for every locale group — functionally identical
  // to the pre-locale behavior. New callers pass the builder directly.
  const buildPayload: (locale: Locale) => PushPayload =
    typeof payloadOrBuilder === 'function'
      ? payloadOrBuilder
      : () => payloadOrBuilder
```

Place the `buildPayload` normalization as the very first line inside the function body (before any other logic). All downstream code that used to reference `payload` directly must be renamed to call `buildPayload(locale)` inside the per-locale loop.

- [ ] **Step 3: Restructure the dispatch logic**

After the existing recipient-filtering block (which ends with
`const subscriptions = allSubs.filter(...) as PushSubscription[]`),
replace the existing per-platform dispatch with a per-locale group
loop. The existing structure is roughly:

```typescript
  if (subscriptions.length === 0) {
    return { sent: 0, expired: 0 }
  }

  // Split subscriptions by platform
  const webSubs = subscriptions.filter(...)
  const iosSubs = subscriptions.filter(...)
  const androidSubs = subscriptions.filter(...)

  let sent = 0
  let expired = 0
  const expiredIds: string[] = []

  // Send web push notifications (VAPID)
  if (vapid && webSubs.length > 0) { ... }

  // Send iOS push notifications (APNs direct)
  if (apnsConfig && iosSubs.length > 0) { ... }

  // Send Android push notifications (FCM)
  if (fcmServiceAccount && androidSubs.length > 0) { ... }

  // Clean up expired subscriptions
  ...
```

New structure — wrap the three dispatch blocks in a per-locale loop:

```typescript
  if (subscriptions.length === 0) {
    return { sent: 0, expired: 0 }
  }

  // Bulk-fetch locale for all remaining subscribers. Absence of row or
  // unknown value → 'en' (matches today's behavior byte-for-byte).
  const userIds = [...new Set(subscriptions.map((s) => s.user_id))]
  const { data: userRows } = await adminClient
    .from('users')
    .select('id, locale')
    .in('id', userIds)

  const localeByUser = new Map<string, Locale>(
    (userRows ?? []).map((r: { id: string; locale: string | null }) => [
      r.id,
      normalizeLocale(r.locale),
    ]),
  )

  // Group recipients by locale.
  const groupedByLocale = new Map<Locale, PushSubscription[]>()
  for (const sub of subscriptions) {
    const loc = localeByUser.get(sub.user_id) ?? 'en'
    const bucket = groupedByLocale.get(loc) ?? []
    bucket.push(sub)
    groupedByLocale.set(loc, bucket)
  }

  let sent = 0
  let expired = 0
  const expiredIds: string[] = []

  // Dispatch per locale group — each group sees a freshly-built payload
  // in its language.
  for (const [locale, groupSubs] of groupedByLocale) {
    const payload = buildPayload(locale)

    const webSubs = groupSubs.filter(
      (s) => s.platform === 'web' && s.endpoint && s.p256dh && s.auth,
    )
    const iosSubs = groupSubs.filter((s) => s.platform === 'ios' && s.fcm_token)
    const androidSubs = groupSubs.filter((s) => s.platform === 'android' && s.fcm_token)

    // Send web push notifications (VAPID)
    if (vapid && webSubs.length > 0) {
      // ← move the existing web push loop body here verbatim
    }

    // Send iOS push notifications (APNs direct)
    if (apnsConfig && iosSubs.length > 0) {
      // ← move the existing APNs loop body here verbatim
    }

    // Send Android push notifications (FCM)
    if (fcmServiceAccount && androidSubs.length > 0) {
      // ← move the existing FCM loop body here verbatim
    }
  }

  // Clean up expired subscriptions (unchanged; runs once after all groups)
  if (expiredIds.length > 0) { ... }

  return { sent, expired }
}
```

Three dispatch loops stay byte-for-byte identical inside; they're just moved into the per-locale loop. The original `let sent`, `let expired`, and `expiredIds` shared across groups — already correct because they're declared outside the loop.

- [ ] **Step 4: Verify TypeScript parses cleanly across ALL callers**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
deno check Docker/supabase/functions/_shared/web-push.ts 2>&1 | tail -10
deno check Docker/supabase/functions/_shared/inbox-notify.ts 2>&1 | tail -10
deno check Docker/supabase/functions/check-low-stock/index.ts 2>&1 | tail -10
deno check Docker/supabase/functions/mqtt-webhook/index.ts 2>&1 | tail -10
deno check Docker/supabase/functions/test-push/index.ts 2>&1 | tail -10
```

Expected: no errors in any of the 5 files. The widened union type makes the legacy callers (`inbox-notify.ts` and `check-low-stock/index.ts`) type-compatible without changes.

If `deno` is unavailable on PATH, skip — runtime-tested in Task E1. But at minimum confirm by reading the function signatures that the legacy callers still pass `PushPayload` as the 4th arg (which the union accepts).

- [ ] **Step 5: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git add Docker/supabase/functions/_shared/web-push.ts
git commit -m "$(cat <<'EOF'
web-push: per-locale rendering in sendPushToUsers (backward-compatible)

4th argument widens to (PushPayload | ((locale) => PushPayload)).
Legacy callers (inbox-notify, check-low-stock) keep passing plain
PushPayload and see identical behavior. New callers can opt into
the builder form to get locale-aware rendering. Internally: bulk-
fetch users.locale, group recipients by locale, dispatch each
group with its own rendered payload. Missing locale rows fall
back to 'en'.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task B2: mqtt-webhook sale + low_stock use the builder form

**Files:**
- Modify: `Docker/supabase/functions/mqtt-webhook/index.ts`

**Rationale:** Both call sites get the same treatment: wrap the payload construction in a `(locale) => {...}` lambda, pull strings from `t(locale)`, format the price via `formatPrice`. The dispatch code and filter-related arguments stay unchanged.

- [ ] **Step 1: Import the i18n helpers at the top of `index.ts`**

Add (after the existing imports):

```typescript
import { t, formatPrice, type Locale } from '../_shared/notification-i18n.ts';
```

- [ ] **Step 2: Rewrite the sale dispatch to use the builder form**

Find the current sale dispatch block (search for `'sale'` notification type). The existing code builds `saleTitle`, `saleSubtitle`, `saleBody` as locale-free locals. Replace the block with:

```typescript
        // 1. Sale notification — three-line layout on iOS (title / subtitle /
        //    body), merged on Android+web (subtitle\nbody). Localized per
        //    recipient via sendPushToUsers' locale grouping.
        const itemLabel = productName ?? `Item #${itemNumber}`;
        const machineLabel = machine?.name ? ` · ${machine.name}` : '';

        await sendPushToUsers(adminClient, embedded.company, 'sale', (locale: Locale) => {
          const strings = t(locale);
          const priceStr = formatPrice(salePrice, locale);

          let body: string;
          if (tray && typeof tray.current_stock === 'number' && typeof tray.capacity === 'number' && tray.capacity > 0) {
            const emoji = stockUrgency(tray.current_stock, tray.fill_when_below ?? 0);
            const refillHint = (tray.fill_when_below ?? 0) > 0
              ? ` — ${strings.refillAt(tray.fill_when_below)}`
              : '';
            body = `${emoji}${tray.current_stock}/${tray.capacity} ${strings.left}${refillHint}`;
          } else {
            body = strings.noStockInfo;
          }

          return {
            title: `💵 ${strings.sale}${machineLabel}`,
            subtitle: `${itemLabel} — ${priceStr}`,
            body,
            image: productImageUrl,
            data: { type: 'sale', embedded_id: embedded.id },
          };
        });
```

Note: `itemLabel` and `machineLabel` remain user-input strings (product and machine names), so they're computed once outside the lambda. Only locale-dependent strings (`sale`, `left`, `refillAt`, `noStockInfo`) and the price move inside.

- [ ] **Step 3: Rewrite the low_stock dispatch**

Find the `if (machine && lowTray)` block further down. Replace with:

```typescript
        // 2. Low stock notification — localized title + body. Still
        //    suppressed for users with sale enabled (sale push already
        //    carries stock info).
        if (machine && lowTray) {
          const itemLabelLow = productName ?? `Item #${itemNumber}`;
          const machineName = machine.name;

          await sendPushToUsers(adminClient, embedded.company, 'low_stock', (locale: Locale) => {
            const strings = t(locale);
            return {
              title: strings.lowStockTitle,
              body: `${itemLabelLow} in ${machineName}: ${lowTray.current_stock}/${lowTray.capacity} ${strings.remaining}`,
              image: productImageUrl,
              data: { type: 'low_stock', machine_id: machine.id },
            };
          }, {
            suppressIfAlsoEnabled: 'sale',
          });
        }
```

- [ ] **Step 4: Verify TypeScript parses cleanly**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
deno check Docker/supabase/functions/mqtt-webhook/index.ts 2>&1 | tail -10
```

Expected: no errors.

- [ ] **Step 5: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git add Docker/supabase/functions/mqtt-webhook/index.ts
git commit -m "$(cat <<'EOF'
mqtt-webhook: localize sale + low-stock pushes per recipient

Both call sites now pass a (locale) => PushPayload builder to
sendPushToUsers. The dispatcher groups recipients by their stored
users.locale and renders one payload per locale group. Product
names and machine names stay as user input (not translated).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task B3: test-push simulator uses the builder form

**Files:**
- Modify: `Docker/supabase/functions/test-push/index.ts`

**Rationale:** The test button should show the recipient's language too, so operators can preview what a German user sees by switching their device / web language and hitting the button.

- [ ] **Step 1: Add the i18n import**

At the top (after the existing imports):

```typescript
import { t, formatPrice, type Locale } from '../_shared/notification-i18n.ts'
```

- [ ] **Step 2: Replace the `sendPushToUsers` call**

Find the current call and replace the entire call (the block that ends with `data: { type: 'test' }`). Replace with:

```typescript
    const result = await sendPushToUsers(adminClient, membership.company_id, '_test', (locale: Locale) => {
      const strings = t(locale)
      const productName = testProductName ?? strings.sampleProduct
      const priceStr = formatPrice(2.50, locale)
      const dummyCurrentStock = 6
      const dummyCapacity = 10
      const dummyFillWhenBelow = 5
      const emoji = stockUrgency(dummyCurrentStock, dummyFillWhenBelow)
      const refillHint = dummyFillWhenBelow > 0
        ? ` — ${strings.refillAt(dummyFillWhenBelow)}`
        : ''
      const body = `${emoji}${dummyCurrentStock}/${dummyCapacity} ${strings.left}${refillHint}`

      return {
        title: `💵 ${strings.sale} · ${strings.testMachine}`,
        subtitle: `${productName} — ${priceStr}`,
        body,
        image: testImageUrl,
        data: { type: 'test' },
      }
    })
```

The outer-scope `let dummyProductName` / `let dummyPrice` etc. declarations from the previous version are replaced by locals inside the lambda. Drop them from the outer scope to keep the file clean.

- [ ] **Step 3: Verify TypeScript parses cleanly**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
deno check Docker/supabase/functions/test-push/index.ts 2>&1 | tail -10
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git add Docker/supabase/functions/test-push/index.ts
git commit -m "$(cat <<'EOF'
test-push: localize simulator payload per recipient

The test button now uses the same (locale) => PushPayload builder
pattern as mqtt-webhook so operators can preview the notification
in their own language.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Chunk C: iOS Auto-Sync

### Task C1: `syncLocaleToServer()` in `AuthService`

**Files:**
- Modify: `ios/VMflow/Services/AuthService.swift`

**Rationale:** Add one method to an existing service. Reads device language, clamps to `'en'`/`'de'`, writes to `users.locale` via Supabase client, caches last synced value in `UserDefaults` so repeated calls on unchanged locale are no-ops.

- [ ] **Step 1: Read the current `AuthService` to find a good insertion point**

```bash
sed -n '1,50p' /Users/lucienkerl/Development/mdb-esp32-cashless/ios/VMflow/Services/AuthService.swift
```

Note where existing methods live (e.g., `signIn`, `signOut`, etc.) so you can slot the new method alongside them.

- [ ] **Step 2: Add the `syncLocaleToServer()` method**

Add this method inside the `AuthService` class, placed after the existing auth methods:

```swift
    // MARK: - Locale sync

    /// Read the device's primary language code and persist it to
    /// `public.users.locale` (clamped to "en" / "de"). Idempotent: caches
    /// the last-synced value in UserDefaults and skips the write if
    /// unchanged. Best-effort — failures log but never surface to the user.
    ///
    /// Call on: successful login, scene phase `.active`, and on the
    /// `NSLocale.currentLocaleDidChangeNotification`.
    func syncLocaleToServer() async {
        let deviceCode = Locale.current.language.languageCode?.identifier ?? "en"
        let locale = (deviceCode.lowercased() == "de") ? "de" : "en"

        let cacheKey = "vmflow-last-synced-locale"
        if UserDefaults.standard.string(forKey: cacheKey) == locale {
            return
        }

        do {
            let userId = try await client.auth.session.user.id
            try await client.from("users")
                .update(["locale": locale])
                .eq("id", value: userId)
                .execute()
            UserDefaults.standard.set(locale, forKey: cacheKey)
            print("[Locale] Synced user locale to \(locale)")
        } catch {
            print("[Locale] Sync failed (best-effort): \(error)")
        }
    }
```

Note: `client` is the Supabase client already used elsewhere in `AuthService`. If the property is named differently (e.g., `supabaseClient`), adapt accordingly.

- [ ] **Step 3: Call `syncLocaleToServer()` after successful login**

Find the method that handles a successful login (e.g., `signIn(email:password:)` or `setSession(_:)`). After the line that sets the session / user, add:

```swift
        Task { await self.syncLocaleToServer() }
```

If there are multiple entry points (email login, OAuth, session restore), add the call at each one. The cache check ensures no extra DB writes.

- [ ] **Step 4: Build the iOS project to verify**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/ios
xcodebuild -project VMflow.xcodeproj -scheme VMflow \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -quiet build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`. Any Swift compile errors here need fixing before proceeding.

- [ ] **Step 5: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git add ios/VMflow/Services/AuthService.swift
git commit -m "$(cat <<'EOF'
ios: sync device locale to users.locale after login

Adds AuthService.syncLocaleToServer() that reads Locale.current's
primary language code, clamps to en/de, and UPSERTs to public.users.
Cached in UserDefaults so repeat calls on unchanged locale are
no-ops. Wired into the post-login flow.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task C2: Wire scene-phase + locale-change triggers

**Files:**
- Modify: `ios/VMflow/VMflowApp.swift`

**Rationale:** Two extra triggers for `syncLocaleToServer` so users who change their iPhone language without relaunching, or bring the app to foreground after a system-language change, also get synced.

- [ ] **Step 1: Read the current `VMflowApp.swift`**

```bash
cat /Users/lucienkerl/Development/mdb-esp32-cashless/ios/VMflow/VMflowApp.swift
```

Understand the current scene-phase handling (usually `@Environment(\.scenePhase) private var scenePhase` + `.onChange(of: scenePhase) { ... }`).

- [ ] **Step 2: Add the scene-phase + locale-change hooks**

If the app already has a `scenePhase` handler, extend it:

```swift
.onChange(of: scenePhase) { _, newPhase in
    if newPhase == .active {
        Task { await AuthService.shared.syncLocaleToServer() }
    }
}
```

If there's no such handler yet, add one inside the `WindowGroup { ContentView() ... }` body.

Also register a Locale-change observer. Somewhere near app init (e.g., in a `.task {}` modifier or `init()` of the main view):

```swift
.task {
    let center = NotificationCenter.default
    for await _ in center.notifications(named: NSLocale.currentLocaleDidChangeNotification) {
        await AuthService.shared.syncLocaleToServer()
    }
}
```

Note: `AuthService.shared` assumes the existing singleton pattern. If `AuthService` is accessed via `@EnvironmentObject`, adapt the call accordingly.

- [ ] **Step 3: Build to verify**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/ios
xcodebuild -project VMflow.xcodeproj -scheme VMflow \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -quiet build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git add ios/VMflow/VMflowApp.swift
git commit -m "$(cat <<'EOF'
ios: re-sync locale on scene foreground + system locale change

Two extra hooks to AuthService.syncLocaleToServer(): scene phase
.active and NSLocale.currentLocaleDidChangeNotification. UserDefaults
cache skips redundant writes when locale is unchanged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Chunk D: Web Frontend Persist

### Task D1: `LanguageSwitcher` persists to `users.locale`

**Files:**
- Modify: `management-frontend/app/components/LanguageSwitcher.vue`

**Rationale:** One-file change. Current `switchLocale(code)` only calls `setLocale(code)`. Add a DB write after the locale switch, best-effort (failure doesn't block the UI change).

- [ ] **Step 1: Read the current file**

```bash
cat /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend/app/components/LanguageSwitcher.vue
```

- [ ] **Step 2: Update `switchLocale` to persist**

Replace the `switchLocale` function with:

```typescript
async function switchLocale(code: string) {
  await setLocale(code)

  // Persist to users.locale so edge-function pushes can read the
  // preference. Best-effort — if the DB write fails, the i18n cookie
  // is still set and the UI follows; pushes just fall back to 'en'.
  try {
    const supabase = useSupabaseClient()
    const user = useSupabaseUser()
    if (user.value?.id) {
      await supabase.from('users').update({ locale: code }).eq('id', user.value.id)
    }
  } catch (err) {
    console.warn('[LanguageSwitcher] persist failed:', err)
  }
}
```

- [ ] **Step 3: Verify the frontend builds and type-checks**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend
npx nuxi typecheck 2>&1 | tail -20
```

Expected: no new errors related to `LanguageSwitcher.vue`. Pre-existing project-wide warnings are fine to ignore.

- [ ] **Step 4: Smoke-test in dev**

Run `npm run dev`, open the frontend, click the language switcher to toggle, check Supabase Studio that `public.users.locale` updated for the current user.

- [ ] **Step 5: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git add management-frontend/app/components/LanguageSwitcher.vue
git commit -m "$(cat <<'EOF'
frontend: persist selected locale to users.locale

LanguageSwitcher now writes the new code to the user's row in
public.users after setLocale. Best-effort; failures log but don't
block the UI change. Enables the edge-function push dispatcher to
render notifications in the user's language.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Chunk E: Manual Verification

### Task E1: Test push in German locale

**Files:** (none — verification only)

- [ ] **Step 1: Set iOS device or web frontend to `de`**

iOS: System Settings → General → Language & Region → iPhone language → Deutsch. Reopen the app.

Web: click the language switcher in the frontend, pick Deutsch.

- [ ] **Step 2: Verify `users.locale` row updated**

```bash
docker exec supabase_db_supabase-test psql -U postgres -d postgres \
  -c "SELECT id, email, locale FROM public.users WHERE email = '<your-email>';"
```

Expected: `locale = 'de'`.

- [ ] **Step 3: Tap "Send Test Notification" / trigger a real sale**

Expected notification (iOS / web):
- Title: `💵 Verkauf · Testmaschine` (or real machine name)
- Subtitle: `<product> — 2,50 €`
- Body: `🟡 6/10 übrig — nachfüllen bei 5`

- [ ] **Step 4: Check edge-function log**

```bash
docker logs --tail 30 supabase_edge_runtime_supabase-test 2>&1 | tail -15
```

Expected: no errors; `sent: >= 1` counts in the response.

- [ ] **Step 5: No commit needed**

---

### Task E2: Test push in English locale + cross-locale dispatch

**Files:** (none — verification only)

- [ ] **Step 1: Switch back to en**

iOS: change iPhone language to English, reopen the app so the sync fires.

Web: toggle the switcher back to English.

- [ ] **Step 2: Verify `users.locale` updated to `en`**

Same query as E1, expect `locale = 'en'`.

- [ ] **Step 3: Trigger a test push**

Expected:
- Title: `💵 Sale · Test Machine`
- Subtitle: `<product> — €2.50`
- Body: `🟡 6/10 left — refill at 5`

- [ ] **Step 4: (optional) Verify cross-locale dispatch**

If you have access to two users in the same company with different locales (`de` and `en`), trigger a real sale and verify each user receives their own language. In the edge-function logs you should see the push dispatcher run per-locale-group — for a mixed company, that's two APNs / two VAPID sends back-to-back.

- [ ] **Step 5: No commit needed**

---

## Final Commit Check

After all tasks pass:

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git log --oneline origin/main..HEAD 2>&1 | head -15
git status --short
```

Expect the new commits in order, working tree clean (apart from pre-existing `ios/.../Info.plist` auto-bump drift and the `kicad/.history/` untracked folder).

---

## Rollback Plan

- `git revert <SHA>` of the `mqtt-webhook` or `test-push` commits → falls back to English-only pushes (before this feature). The `sendPushToUsers` signature stays backward-compatible, so reverting these callers independently works without touching `web-push.ts`.
- `git revert <SHA>` of `web-push.ts` refactor → narrows `sendPushToUsers` back to `PushPayload` only. Must be reverted in lockstep with mqtt-webhook and test-push; otherwise they pass a function where a payload is expected. The legacy callers (inbox-notify, check-low-stock) are unaffected by this revert direction because they already use `PushPayload`.
- DB migration stays applied; harmless on its own.
- iOS app on old version: doesn't write `users.locale` → DB default `'en'` → sees English pushes, no regression.
- Web frontend on old version: language switcher doesn't persist; user sees cookie-only behavior, still gets `'en'` pushes from any caller.
- Partial landing: Chunk A alone is safe — existing callers see no behavior change. Chunk A + B (with union type) is also safe. iOS and web chunks are independent of each other and of the backend.

---

## References

- Spec: `docs/superpowers/specs/2026-04-20-per-user-notification-locale-design.md`
- Prior feature (sale stock info): `docs/superpowers/plans/2026-04-19-sale-notification-stock-info.md`
- Push dispatcher: `Docker/supabase/functions/_shared/web-push.ts`
- Frontend i18n: `management-frontend/i18n/locales/{en,de}.json` + `LanguageSwitcher.vue`
- iOS localization: `ios/VMflow/Resources/Localizable.xcstrings`
- iOS device locale API: `Locale.current.language.languageCode` (Foundation, iOS 16+)
- Migration immutability rule: project `CLAUDE.md` section on migrations.
