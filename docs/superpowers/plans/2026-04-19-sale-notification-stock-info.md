# Sale Notification Stock Info Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enhance the sale push notification with stock count + urgency indicator, dedup the low-stock notification for users who already see sale pushes, and make the "Send Test Notification" button exercise the new sale format with dummy values.

**Architecture:** Server-only change across three edge-function files. Add an optional `subtitle` field to `PushPayload` with per-platform dispatch (iOS uses `aps.alert.subtitle`; Android/Web merge into body with `\n`). Add a `suppressIfAlsoEnabled` filter option to `sendPushToUsers` so low-stock can be suppressed for users with `sale` enabled. Extract a pure `stockUrgency` helper for the emoji logic so it can be unit-tested.

**Tech Stack:** Deno 1.x edge runtime, TypeScript, Supabase Edge Functions, APNs HTTP/2, FCM HTTP v1, Web Push (VAPID).

**Spec:** `docs/superpowers/specs/2026-04-19-sale-notification-stock-info-design.md`

---

## File Map

**New files:**

- `Docker/supabase/functions/mqtt-webhook/stock-urgency.ts` — tiny module exporting the pure `stockUrgency(currentStock, fillWhenBelow)` function. Separate from `index.ts` for testability.
- `Docker/supabase/functions/mqtt-webhook/stock-urgency.test.ts` — Deno unit test for all four urgency buckets plus the `fillWhenBelow === 0` edge case.

**Modified files:**

- `Docker/supabase/functions/_shared/web-push.ts` — add `subtitle` to `PushPayload`; dispatch it natively in `sendApnsNotification`; merge it into body in `sendFcmNotification` and `sendPushNotification`; add `options.suppressIfAlsoEnabled` to `sendPushToUsers`.
- `Docker/supabase/functions/mqtt-webhook/index.ts` — fetch `fill_when_below` in the tray query; compose new sale notification body using `stockUrgency`; pass `suppressIfAlsoEnabled: 'sale'` on the low-stock dispatch; remove debug `console.log` left over from the iOS-image-debugging session.
- `Docker/supabase/functions/test-push/index.ts` — replace generic text body with a sale-shaped dummy payload; remove `DEBUG-V2` and other debug `console.log` left over from debugging.

**Intentionally NOT touched:**

- iOS `NotificationService.swift` — `aps.alert.subtitle` is rendered natively by iOS; the extension passes content through unchanged.
- Web PWA service worker — it renders `title` + `body`; the merged-body approach needs no client-side change.
- Android/FCM client code — FCM's `notification.body` is all that's shown for the Android surface; merged body covers it.
- `machine_trays` schema — no migration.

---

## Conventions

- Every commit ends with the Claude Code co-author trailer via HEREDOC body:
  ```
  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  ```
- User has explicitly approved working on `main`. Commit directly.
- Tests use Deno + `jsr:@std/assert` (see existing `mdb-log.test.ts`). Run from repo root as `deno test <path> --allow-env` (or without `--allow-env` when no env is needed).
- Small surgical edits only — do not reformat surrounding code.

---

## Chunk 1: Pure Helper + Foundation

### Task 1: `stockUrgency` with tests (TDD)

**Files:**
- Create: `Docker/supabase/functions/mqtt-webhook/stock-urgency.ts`
- Create: `Docker/supabase/functions/mqtt-webhook/stock-urgency.test.ts`

**Rationale:** A pure, unit-testable function with four well-defined buckets. TDD locks behavior before it gets used inline.

- [ ] **Step 1: Write the failing test**

Create `Docker/supabase/functions/mqtt-webhook/stock-urgency.test.ts` with:

```typescript
/**
 * Tests for the stockUrgency pure helper.
 * Run: deno test Docker/supabase/functions/mqtt-webhook/stock-urgency.test.ts
 */

import { assertEquals } from 'jsr:@std/assert'
import { stockUrgency } from './stock-urgency.ts'

Deno.test('stockUrgency: empty tray returns 🚨', () => {
  assertEquals(stockUrgency(0, 5), '🚨 ')
  assertEquals(stockUrgency(0, 0), '🚨 ')
})

Deno.test('stockUrgency: current below threshold returns ⚠️', () => {
  assertEquals(stockUrgency(3, 5), '⚠️ ')
  assertEquals(stockUrgency(5, 5), '⚠️ ') // at threshold counts as critical
  assertEquals(stockUrgency(1, 5), '⚠️ ')
})

Deno.test('stockUrgency: current within 1.5× threshold returns 🟡', () => {
  assertEquals(stockUrgency(6, 5), '🟡 ')   // 6 ≤ 7.5
  assertEquals(stockUrgency(7, 5), '🟡 ')   // 7 ≤ 7.5
  // 8 > 7.5 → normal (no emoji)
})

Deno.test('stockUrgency: current well above threshold returns empty', () => {
  assertEquals(stockUrgency(10, 5), '')
  assertEquals(stockUrgency(8, 5), '')
})

Deno.test('stockUrgency: zero threshold disables warning, keeps empty marker', () => {
  // fill_when_below = 0 means "no threshold configured"
  // Only the empty-tray marker applies.
  assertEquals(stockUrgency(5, 0), '')
  assertEquals(stockUrgency(1, 0), '')
  assertEquals(stockUrgency(0, 0), '🚨 ')
})
```

- [ ] **Step 2: Run the test and confirm it fails**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
deno test Docker/supabase/functions/mqtt-webhook/stock-urgency.test.ts 2>&1 | tail -10
```

Expected: FAIL — "Module not found" or "stockUrgency is not exported".

- [ ] **Step 3: Implement `stockUrgency`**

Create `Docker/supabase/functions/mqtt-webhook/stock-urgency.ts`:

```typescript
/**
 * Map a tray's current stock and refill threshold to a prefix emoji for
 * sale push notifications. Returns a string that already contains the
 * trailing space ("⚠️ ") so it can be concatenated directly; returns the
 * empty string when no urgency indicator should appear.
 *
 * Thresholds:
 *  - currentStock === 0              → 🚨 (empty, always shown)
 *  - fillWhenBelow === 0             → no further indicator (no threshold)
 *  - currentStock <= fillWhenBelow   → ⚠️ (critical, needs refill)
 *  - currentStock <= 1.5 * threshold → 🟡 (warning zone)
 *  - otherwise                       → '' (normal)
 */
export function stockUrgency(currentStock: number, fillWhenBelow: number): string {
  if (currentStock === 0) return '🚨 '
  if (fillWhenBelow === 0) return ''
  if (currentStock <= fillWhenBelow) return '⚠️ '
  if (currentStock <= fillWhenBelow * 1.5) return '🟡 '
  return ''
}
```

- [ ] **Step 4: Run the test and confirm it passes**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
deno test Docker/supabase/functions/mqtt-webhook/stock-urgency.test.ts 2>&1 | tail -10
```

Expected: `ok | 5 passed | 0 failed`.

- [ ] **Step 5: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git add Docker/supabase/functions/mqtt-webhook/stock-urgency.ts \
        Docker/supabase/functions/mqtt-webhook/stock-urgency.test.ts
git commit -m "$(cat <<'EOF'
mqtt-webhook: add stockUrgency helper with tests

Pure function that maps (currentStock, fillWhenBelow) to an emoji prefix
for sale push notifications. Four buckets: empty/critical/warning/normal,
plus handling of fill_when_below === 0 (no threshold configured).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Add `subtitle` field to `PushPayload` and dispatch per-platform

**Files:**
- Modify: `Docker/supabase/functions/_shared/web-push.ts`

**Rationale:** Three small, independent changes in one file. Each dispatcher gets handled locally so the merge policy lives next to the consumer that needs it.

- [ ] **Step 1: Add `subtitle?: string` to the `PushPayload` interface**

Locate the `PushPayload` interface (around line 31 of `_shared/web-push.ts`). Insert the new field immediately after `body`:

```typescript
interface PushPayload {
  title: string
  body: string
  /**
   * Optional second line of the notification. On iOS, rendered as
   * `aps.alert.subtitle` (three-line layout). On Android/FCM and web
   * push (VAPID), merged into the body with a `\n` separator because
   * those surfaces don't expose a subtitle field.
   */
  subtitle?: string
  icon?: string
  image?: string
  data?: Record<string, unknown>
  badge?: number
}
```

- [ ] **Step 2: Use subtitle in the APNs direct dispatcher**

Find the block in `sendApnsNotification` that builds `aps` (around line 320). Replace the current alert literal with a subtitle-aware build:

```typescript
  const alertDict: Record<string, unknown> = {
    title: payload.title,
    body: payload.body,
  }
  if (payload.subtitle) {
    alertDict.subtitle = payload.subtitle
  }

  // Build aps separately so we can add the optional badge field cleanly.
  const aps: Record<string, unknown> = {
    alert: alertDict,
    sound: 'default',
    'mutable-content': 1,
  }
```

Everything else in `sendApnsNotification` stays as-is.

- [ ] **Step 3: Merge subtitle into body in the Android FCM dispatcher**

Find `sendFcmNotification` (around line 446). At the top of the function body, introduce a `mergedBody` local and use it everywhere `payload.body` was read:

```typescript
async function sendFcmNotification(
  fcmToken: string,
  platform: 'android' | 'ios',
  payload: PushPayload,
  sa: FcmServiceAccount,
): Promise<{ ok: boolean; expired: boolean }> {
  const accessToken = await getFcmAccessToken(sa)

  // FCM has no subtitle field — fold it into body so the content is preserved.
  const mergedBody = payload.subtitle
    ? `${payload.subtitle}\n${payload.body}`
    : payload.body

  const message: Record<string, unknown> = {
    token: fcmToken,
    notification: {
      title: payload.title,
      body: mergedBody,
      ...(payload.image ? { image: payload.image } : {}),
    },
    ...
  }
```

Important: the rest of the function body (`if (platform === 'android') { ... } else { ... }`) stays unchanged — it already reads from `message.notification.body` indirectly via `message`.

- [ ] **Step 4: Merge subtitle into body in the Web Push dispatcher**

Find `sendPushNotification` (around line 517). Before the `JSON.stringify(payload)` call, build a shallow copy with the merged body and serialize that instead:

```typescript
async function sendPushNotification(
  subscription: { endpoint: string; p256dh: string; auth: string },
  payload: PushPayload,
  vapid: VapidConfig,
): Promise<Response> {
  // Web push has no subtitle field in the payload the service worker sees —
  // fold it into body so the content is preserved.
  const wirePayload: PushPayload = payload.subtitle
    ? { ...payload, body: `${payload.subtitle}\n${payload.body}` }
    : payload

  const payloadBytes = new TextEncoder().encode(JSON.stringify(wirePayload))
  ...
}
```

Note: we include `subtitle` in the JSON on the wire so future client-side code *could* read it separately, but we also merge it into body so today's service worker still shows it.

- [ ] **Step 5: Verify TypeScript parses cleanly**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
deno check Docker/supabase/functions/_shared/web-push.ts 2>&1 | tail -10
```

Expected: no errors.

- [ ] **Step 6: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git add Docker/supabase/functions/_shared/web-push.ts
git commit -m "$(cat <<'EOF'
web-push: add subtitle field with per-platform dispatch

iOS APNs renders it as aps.alert.subtitle for a native three-line layout.
Android FCM and web VAPID fold it into body with \n because they don't
expose a subtitle field in their notification schemas. The PushPayload
field is optional — existing callers are unaffected.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Add `suppressIfAlsoEnabled` option to `sendPushToUsers`

**Files:**
- Modify: `Docker/supabase/functions/_shared/web-push.ts`

**Rationale:** The low-stock dedup rule belongs in the shared helper, not in mqtt-webhook, so any future caller can reuse it.

- [ ] **Step 1: Extend the function signature**

Find `sendPushToUsers` (around line 552). Change the signature:

```typescript
export async function sendPushToUsers(
  adminClient: SupabaseClient,
  companyId: string,
  notificationType: string,
  payload: PushPayload,
  options?: {
    /**
     * Skip users who also have this OTHER notification type enabled. Useful
     * to avoid redundant alerts when the current push duplicates info
     * already delivered via a different channel (e.g. low_stock when sale
     * already shows the stock count).
     */
    suppressIfAlsoEnabled?: string
  },
): Promise<{ sent: number; expired: number }> {
```

- [ ] **Step 2: Compute the suppression set**

After the existing `disabledUserIds` computation (around line 625 in current code — search for `const disabledUserIds = new Set`), add the suppression lookup before the `subscriptions = allSubs.filter(...)` line:

```typescript
  // Users who have an "alternate" type enabled should not receive this push.
  // Semantics: "enabled" = member AND no explicit row with enabled=false for
  // that type (absence = enabled, matching the disabledPrefs semantics above).
  const suppressedUserIds = new Set<string>()
  if (options?.suppressIfAlsoEnabled) {
    const { data: altDisabledPrefs } = await adminClient
      .from('notification_preferences')
      .select('user_id')
      .eq('notification_type', options.suppressIfAlsoEnabled)
      .eq('enabled', false)

    const altDisabledUserIds = new Set(
      (altDisabledPrefs ?? []).map((p: { user_id: string }) => p.user_id),
    )

    for (const memberId of memberIds) {
      if (!altDisabledUserIds.has(memberId)) {
        // This member has the other type enabled → suppress current push.
        suppressedUserIds.add(memberId)
      }
    }
  }
```

- [ ] **Step 3: Apply the filter**

Find the existing `subscriptions = allSubs.filter(...)` block and add the new predicate:

```typescript
  const subscriptions = allSubs.filter(
    (s: { user_id: string }) =>
      memberIds.has(s.user_id) &&
      !disabledUserIds.has(s.user_id) &&
      !suppressedUserIds.has(s.user_id),
  ) as PushSubscription[]
```

- [ ] **Step 4: Verify TypeScript parses cleanly**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
deno check Docker/supabase/functions/_shared/web-push.ts 2>&1 | tail -10
```

Expected: no errors.

- [ ] **Step 5: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git add Docker/supabase/functions/_shared/web-push.ts
git commit -m "$(cat <<'EOF'
web-push: add suppressIfAlsoEnabled filter to sendPushToUsers

Optional option to skip users who have a different notification type
enabled. Lets callers avoid redundant pushes when one already covers
the info (e.g. sale push carries stock info, so low_stock can be
suppressed for subscribers of both).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Chunk 2: Wire into mqtt-webhook and test-push

### Task 4: Update mqtt-webhook sale notification

**Files:**
- Modify: `Docker/supabase/functions/mqtt-webhook/index.ts`

**Rationale:** Two changes in the same function: fetch the extra column (`fill_when_below`), and rebuild the sale payload with title/subtitle/body using `stockUrgency`. Also removes debug logs left over from iOS debugging.

- [ ] **Step 1: Add `fill_when_below` to the tray select**

Find the tray lookup (around line 322 of `mqtt-webhook/index.ts`). Update the `.select()` column list:

```typescript
        if (machine) {
          const { data: tray } = await adminClient
            .from('machine_trays')
            .select('product_id, current_stock, min_stock, capacity, fill_when_below')
            .eq('machine_id', machine.id)
            .eq('item_number', itemNumber)
            .maybeSingle();
```

- [ ] **Step 2: Import `stockUrgency` at the top of `index.ts`**

Locate the existing imports at the top of `Docker/supabase/functions/mqtt-webhook/index.ts` and add:

```typescript
import { stockUrgency } from './stock-urgency.ts';
```

(If the file uses alphabetical ordering or grouped imports, follow that convention; otherwise append after the last relative import.)

- [ ] **Step 3: Replace the sale-notification body construction**

Find the block that currently builds `saleBody` and calls `sendPushToUsers` for the `sale` type (around lines 355-365). Replace it entirely with:

```typescript
        // 1. Sale notification — three-line layout on iOS (title / subtitle /
        //    body), merged on Android+web (subtitle\nbody).
        const itemLabel = productName ?? `Item #${itemNumber}`;
        const machineLabel = machine?.name ? ` · ${machine.name}` : '';
        const saleTitle = `🛒 New Sale${machineLabel}`;
        const saleSubtitle = `${itemLabel} — €${salePrice.toFixed(2)}`;

        let saleBody: string;
        if (tray && typeof tray.current_stock === 'number' && typeof tray.capacity === 'number' && tray.capacity > 0) {
          const emoji = stockUrgency(tray.current_stock, tray.fill_when_below ?? 0);
          const refillHint = (tray.fill_when_below ?? 0) > 0
            ? ` — refill at ${tray.fill_when_below}`
            : '';
          saleBody = `${emoji}${tray.current_stock}/${tray.capacity} left${refillHint}`;
        } else {
          saleBody = 'No stock info';
        }

        await sendPushToUsers(adminClient, embedded.company, 'sale', {
          title: saleTitle,
          subtitle: saleSubtitle,
          body: saleBody,
          image: productImageUrl,
          data: { type: 'sale', embedded_id: embedded.id },
        });
```

The channel (`cash` / `card` / `cashless`) that used to appear in the body is intentionally dropped — operators don't read it per sale. It remains available via `data` consumers if needed later.

- [ ] **Step 4: Remove debug `console.log` from the sale dispatch block**

Scan `mqtt-webhook/index.ts` for any `console.log` lines added during the recent iOS debugging session (search for `DEBUG`). Delete any that exist. If unsure, run:

```bash
grep -n "DEBUG\|console\.log.*test-push\|console\.log.*web-push" \
  /Users/lucienkerl/Development/mdb-esp32-cashless/Docker/supabase/functions/mqtt-webhook/index.ts
```

Delete any matching lines (typical victims: `console.log('[test-push][DEBUG] ...')`, `console.log('[web-push][DEBUG] ...')`). Leave existing `console.error` / `console.warn` in place — those are production logs, not debug.

Note: `mqtt-webhook/index.ts` probably has no debug logs (the debug logs were added to `test-push` and `_shared/web-push.ts`). Run the grep to confirm.

- [ ] **Step 5: Verify TypeScript parses cleanly**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
deno check Docker/supabase/functions/mqtt-webhook/index.ts 2>&1 | tail -10
```

Expected: no errors.

- [ ] **Step 6: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git add Docker/supabase/functions/mqtt-webhook/index.ts
git commit -m "$(cat <<'EOF'
mqtt-webhook: sale notifications carry stock count + urgency emoji

Three-line layout on iOS (🛒 New Sale · Machine / Product — €price /
emoji count/capacity left — refill at N). Other platforms see the
subtitle folded into body. Falls back to "No stock info" when the
tray row is missing or malformed. Channel (cash/card/cashless) no
longer appears in the notification body — operators don't read it.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Suppress low-stock for sale-subscribers

**Files:**
- Modify: `Docker/supabase/functions/mqtt-webhook/index.ts`

**Rationale:** A one-line options argument on the existing low-stock dispatch. Separate commit so the intent is crisp.

- [ ] **Step 1: Add the `suppressIfAlsoEnabled` option to the low-stock call**

Find the low-stock dispatch block (around line 368, right after the sale dispatch). Update the call:

```typescript
        // 2. Low stock notification — only for users who explicitly want
        //    low-stock alerts AND don't already receive sale notifications
        //    (sale pushes already carry stock info, so double-alerting is
        //    noisy). Users who turned sale off but kept low_stock on still
        //    get this.
        if (machine && lowTray) {
          await sendPushToUsers(adminClient, embedded.company, 'low_stock', {
            title: 'Low Stock Alert',
            body: `${productName ?? `Item #${itemNumber}`} in ${machine.name}: ${lowTray.current_stock}/${lowTray.capacity} remaining`,
            image: productImageUrl,
            data: { type: 'low_stock', machine_id: machine.id },
          }, {
            suppressIfAlsoEnabled: 'sale',
          });
        }
```

- [ ] **Step 2: Verify TypeScript parses cleanly**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
deno check Docker/supabase/functions/mqtt-webhook/index.ts 2>&1 | tail -10
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git add Docker/supabase/functions/mqtt-webhook/index.ts
git commit -m "$(cat <<'EOF'
mqtt-webhook: suppress low-stock push for users with sale enabled

Sale notifications now carry the stock count and urgency emoji, so users
subscribed to both types would otherwise see two pushes for the same
event. The low-stock push still fires for users who explicitly disabled
sale but kept low_stock on.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Rewrite `test-push` to simulate a sale

**Files:**
- Modify: `Docker/supabase/functions/test-push/index.ts`

**Rationale:** The test button becomes a realistic sale simulator so operators can validate the new layout + image rendering end-to-end. Also drops the debug logs left over from the earlier troubleshooting.

- [ ] **Step 1: Read the current file to find the product-lookup block**

The current implementation already does the product lookup to pull an image. Keep that. Capture the product name too (new — previously we only captured `image_path`).

- [ ] **Step 2: Update the product lookup to also select `name`**

Find the lookup query in `test-push/index.ts` and change `.select('image_path')` to `.select('image_path, name')`:

```typescript
      const { data: product } = await adminClient
        .from('products')
        .select('image_path, name')
        .eq('company', membership.company_id)
        .not('image_path', 'is', null)
        .limit(1)
        .maybeSingle()

      if (product?.image_path) {
        const supabaseUrl =
          Deno.env.get('SUPABASE_PUBLIC_URL') ??
          Deno.env.get('PUBLIC_SUPABASE_URL') ??
          Deno.env.get('SUPABASE_URL')
        testImageUrl = `${supabaseUrl}/storage/v1/object/public/product-images/${product.image_path}`
      }
      testProductName = product?.name ?? undefined
```

Also declare `let testProductName: string | undefined` alongside `let testImageUrl: string | undefined`.

- [ ] **Step 3: Replace the `sendPushToUsers` call with sale-style payload**

Find the current `sendPushToUsers(..., '_test', {...})` call and replace the entire payload object with:

```typescript
    // Simulate a sale-shaped notification so the user can verify the new
    // layout (title / subtitle / body) end-to-end, including rich-media
    // image on iOS. Uses real product name + image for realism; dummy
    // stock numbers to hit the 🟡 warning bucket.
    const dummyProductName = testProductName ?? 'Sample Product'
    const dummyPrice = 2.50
    const dummyCurrentStock = 3
    const dummyCapacity = 10
    const dummyFillWhenBelow = 5
    const emoji = stockUrgency(dummyCurrentStock, dummyFillWhenBelow)
    const refillHint = dummyFillWhenBelow > 0
      ? ` — refill at ${dummyFillWhenBelow}`
      : ''
    const dummyBody = `${emoji}${dummyCurrentStock}/${dummyCapacity} left${refillHint}`

    const result = await sendPushToUsers(adminClient, membership.company_id, '_test', {
      title: '🛒 New Sale · Test Machine',
      subtitle: `${dummyProductName} — €${dummyPrice.toFixed(2)}`,
      body: dummyBody,
      image: testImageUrl,
      data: { type: 'test' },
    })
```

Also add the import at the top:

```typescript
import { stockUrgency } from '../mqtt-webhook/stock-urgency.ts'
```

- [ ] **Step 4: Remove all debug `console.log` from `test-push/index.ts`**

```bash
grep -n "DEBUG\|console\.log" \
  /Users/lucienkerl/Development/mdb-esp32-cashless/Docker/supabase/functions/test-push/index.ts
```

Delete every line that contains `[test-push][DEBUG]` or `[test-push][DEBUG-V2]`. Also delete any other temporary `console.log` statements added during debugging. The only `console.*` that may remain is the existing `console.warn('[test-push] product image lookup failed:', err)` inside the try/catch (that's legitimate error logging, keep it).

- [ ] **Step 5: Also clean `_shared/web-push.ts`**

```bash
grep -n "console\.log.*web-push.*DEBUG\|\\[web-push\\]\\[DEBUG\\]" \
  /Users/lucienkerl/Development/mdb-esp32-cashless/Docker/supabase/functions/_shared/web-push.ts
```

Delete every matching line. Keep existing `console.warn('[APNs] Push failed: ...')` and similar legitimate production logs — they are NOT debug artifacts.

- [ ] **Step 6: Verify TypeScript parses cleanly across both files**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
deno check Docker/supabase/functions/test-push/index.ts 2>&1 | tail -5
deno check Docker/supabase/functions/_shared/web-push.ts 2>&1 | tail -5
```

Expected: no errors in either.

- [ ] **Step 7: Smoke-test the imports**

The cross-function import (`test-push → ../mqtt-webhook/stock-urgency.ts`) is unusual. Supabase CLI supports it — edge functions share the filesystem. In production (Docker), each function is deployed via file mounts that typically include the whole `functions/` tree. Verify locally by tapping the Settings button in the iOS app; if the function errors out with a module-resolution failure, we need a `deno.json` import-map entry. If it works, we're good.

- [ ] **Step 8: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git add Docker/supabase/functions/test-push/index.ts \
        Docker/supabase/functions/_shared/web-push.ts
git commit -m "$(cat <<'EOF'
test-push: simulate sale notification with dummy stock values

The Send Test Notification button now fires a sale-shaped push: real
product name + image, fake machine name ("Test Machine"), fake stock
in the warning zone (3/10, refill at 5 → 🟡 emoji). Operators can
verify the new three-line layout end-to-end without triggering a real
sale. Also removes debug console.log statements left over from the
earlier iOS image-debugging session.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Chunk 3: Manual Verification

### Task 7: Restart edge runtime and exercise the test button

**Files:** (none modified — verification only)

**Rationale:** Edge runtime caches compiled modules. A restart ensures the new code is live before the user taps.

- [ ] **Step 1: Reload the edge runtime**

Ideally: `supabase stop && supabase start` — picks up any new env vars AND re-mounts functions. If the user already has an active dev session and does not want the full restart, `docker restart supabase_edge_runtime_supabase-<project>` reloads functions (env vars stay from last start, which is fine for this task since no env var changed).

- [ ] **Step 2: User taps "Send Test Notification" in the iOS app**

Expected on iOS (Debug build):
- Title: `🛒 New Sale · Test Machine`
- Subtitle: `<your first image-bearing product> — €2.50`
- Body: `🟡 3/10 left — refill at 5`
- Thumbnail: the product's image, next to the text in the banner
- Long-press: expanded preview shows the same layout + larger image

- [ ] **Step 3: Check the edge runtime log for non-debug, non-error output**

```bash
docker logs --tail 20 supabase_edge_runtime_supabase-<project> 2>&1 | tail -20
```

Expected: no `DEBUG` lines (since we removed them). Expected: no `[APNs] Push failed` warnings. A clean path looks like:
```
serving the request with supabase/functions/test-push
```
— plus maybe nothing else.

- [ ] **Step 4: No commit needed**

Verification only.

---

### Task 8: Trigger a real sale and verify the full path

**Files:** (none modified — verification only)

**Rationale:** End-to-end: actual sale → `mqtt-webhook` → new format → iOS rich push.

Prerequisite: at least one machine with a tray configured (product assigned, capacity > 0, `fill_when_below` > 0 for a meaningful urgency test).

- [ ] **Step 1: Before triggering, note the tray state**

Use Supabase Studio or the Trays tab in the frontend to note the current `current_stock`, `capacity`, `fill_when_below` for the tray you're about to sell from. Predict which emoji you'll see:
- `current_stock - 1 == 0` → 🚨
- `current_stock - 1 <= fill_when_below` → ⚠️
- `current_stock - 1 <= 1.5 * fill_when_below` → 🟡
- otherwise → no emoji

- [ ] **Step 2: Trigger a sale**

Either: press the button on the `mdb-master-esp32s3` dev rig to fire a real MDB sale, or use the frontend's "Add manual sale" flow on a machine page. The notification should arrive within ~2 seconds.

- [ ] **Step 3: Verify notification content**

Check:
- Title line: `🛒 New Sale · <machine name>`
- Subtitle line: `<product name> — €<price>`
- Body line: matches your predicted emoji + `<new stock>/<capacity> left — refill at <fill_when_below>` (or without the refill part if `fill_when_below == 0`)
- Thumbnail: product image visible in the banner; expanded preview shows large image

- [ ] **Step 4: Verify low-stock dedup**

If the sale crossed into the low-stock threshold and your user account has `sale` enabled, verify you received EXACTLY ONE push (not two). Check `sent` counts in the edge runtime log via:

```bash
docker logs --tail 30 supabase_edge_runtime_supabase-<project> 2>&1 | grep -E "sent|sale|low_stock"
```

If the tray has a second user in the company with `sale` disabled + `low_stock` enabled, that user should have received the low-stock push separately. (Not required to test with two users — just sanity-check via `sent` counts.)

- [ ] **Step 5: No commit needed**

Verification only.

---

### Task 9: Verify web push (if PWA is in use)

**Files:** (none modified — verification only)

**Rationale:** The web push path uses the merged-body approach. Confirm the newline actually renders correctly in the browser notification.

- [ ] **Step 1: Open the PWA in a browser with notifications enabled**

Navigate to the management frontend, ensure push is registered (Settings → Notifications → enabled).

- [ ] **Step 2: Trigger a sale (same as Task 8)**

- [ ] **Step 3: Verify the web notification**

Expected: a single notification banner with the title unchanged and the body showing two lines — the subtitle text on top, the stock-info line below, separated by a visible line break. Chrome and Safari both render `\n` in push bodies as a line break by default.

- [ ] **Step 4: No commit needed**

Verification only. If `\n` does NOT render as a line break in your browser, the fix is a service-worker change (replace `\n` with a different delimiter). That is deferred as a follow-up if needed.

---

## Final Commit Check

After all tasks pass:

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git log --oneline main~7..HEAD    # should show the new commits in order
git status                        # expect clean working tree
```

If the working tree has any stray modifications (e.g., pbxproj churn, local-only `.env` drift), decide whether to commit or leave untracked as appropriate.

---

## Rollback Plan

Each commit in Chunks 1 and 2 is independently revertable:

- `git revert <sha>` on the sale-format commit (Task 4) reverts to today's single-line body.
- `git revert <sha>` on the dedup commit (Task 5) restores double-dispatch (users on both types will see both pushes again).
- `git revert <sha>` on the test-push commit (Task 6) restores the generic test body.

The subtitle field and the `suppressIfAlsoEnabled` option are additive on their own — no caller is forced to use them, so Tasks 2 and 3 can stay landed even if Tasks 4–6 are reverted.

---

## References

- Spec: `docs/superpowers/specs/2026-04-19-sale-notification-stock-info-design.md`
- Shared push helper: `Docker/supabase/functions/_shared/web-push.ts`
- Sale path: `Docker/supabase/functions/mqtt-webhook/index.ts:309-378`
- Test button: `Docker/supabase/functions/test-push/index.ts`
- Tray schema: `machine_trays` (cols: `capacity`, `current_stock`, `min_stock`, `fill_when_below`)
- Notification preferences: `notification_preferences` (absence = enabled, `enabled=false` = disabled)
- APNs alert fields: [Apple — Generating a remote notification](https://developer.apple.com/documentation/usernotifications/generating-a-remote-notification)
