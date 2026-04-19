# Sale Notification Stock Info — Design

**Date:** 2026-04-19
**Status:** Draft
**Owner:** Lucien Kerl

## Summary

Enhance the sale push notification so users can see at a glance how full the
tray still is and how close it is to the refill threshold. The current body is
a single line (`Product — €price (channel) · Machine`) — useful but misses the
one number every operator actually cares about: *am I about to run out?*

The change introduces an optional `subtitle` field in the platform-agnostic
`PushPayload` type, dispatches it natively on iOS (via `aps.alert.subtitle`),
and folds it into the body with a newline on Android (FCM) and web push
(VAPID) where no subtitle field exists. Sale notifications adopt a three-line
layout with the product+price on the subtitle line and stock info on the body
line, prefixed with an urgency emoji that derives from the tray's
`fill_when_below` threshold.

To avoid double-alerting, a second piece: when `mqtt-webhook` dispatches the
separate low-stock notification, it suppresses delivery for users who also
have sale notifications enabled — those users already see the stock info in
the sale push. Users who explicitly turn sale notifications off but keep
low-stock on still get the low-stock alert.

Finally, the in-app "Send Test Notification" button is repurposed from a
generic text-only test push into a sale-style push with dummy values, so
operators can see the new format without triggering a real sale.

## Problem

Today a sale push looks like:

> **New Sale**
> Coca-Cola Zero 0,33l — €2.50 (cash) · Office Machine

Useful, but you can't tell whether that sale left the slot at 9/10 (no
urgency) or 1/10 (refill soon). Operators currently have to open the app, go
to the machine detail, find the tray — just to check one number they already
almost know.

Stock info already flows into `mqtt-webhook` via the `machine_trays` lookup
(see `Docker/supabase/functions/mqtt-webhook/index.ts:322-327`); we just
don't render it in the notification body.

Separately: when a sale drops the stock at or below `fill_when_below`, the
code dispatches a second `low_stock` push. After this change the sale push
already carries that information — sending both would be redundant noise for
users who subscribe to both types.

## Goals

- Sale push notifications show:
  - Machine name in the title
  - Product name + price as the middle line (iOS subtitle, other platforms
    folded into body)
  - Remaining stock as a ratio (`current/capacity`) with an urgency emoji
    derived from the tray threshold, plus a short `refill at N` hint when a
    threshold is configured
  - Product image as the rich-media attachment (already works via the iOS
    Notification Service Extension)
- Web and Android users see the same information without subtitle support,
  via a newline-joined body.
- Low-stock push is suppressed for users who also have `sale` enabled, so
  they don't get two notifications for the same event.
- Users who subscribe only to `low_stock` (sale disabled) continue to receive
  the separate low-stock alert exactly as today.
- The "Send Test Notification" button exercises the new sale format with
  dummy stock numbers, using a real product (for the image), so the full
  end-to-end rendering can be validated in-app.

## Non-Goals

- **Not changing the `low_stock` notification format.** It stays as today;
  only its delivery audience changes.
- **Not adding new urgency levels to the low-stock push itself** (this spec's
  urgency emoji is on the *sale* push only). Low-stock is by definition
  already in the critical range.
- **Not changing anything on the iOS Notification Service Extension.** It
  reads `userInfo["image"]` and passes through all `aps.alert` fields
  untouched — the new `aps.alert.subtitle` is rendered by iOS directly.
- **No new notification type.** Sale and low_stock preferences stay as-is.
- **No persistent stock history in the push payload.** Just the number at
  the moment of the sale.
- **No localization of the new body strings in this increment.** Matches the
  existing English-only body for both notification types.

## Architecture

### 1. `PushPayload` gains `subtitle`

In `Docker/supabase/functions/_shared/web-push.ts`:

```typescript
interface PushPayload {
  title: string
  body: string
  subtitle?: string   // new — shown as iOS `aps.alert.subtitle`; merged into body elsewhere
  icon?: string
  image?: string
  data?: Record<string, unknown>
  badge?: number
}
```

### 2. Platform-specific subtitle handling (same file)

**iOS APNs direct** (`sendApnsNotification`): when `payload.subtitle` is
set, include it in the alert object:

```typescript
const aps: Record<string, unknown> = {
  alert: payload.subtitle
    ? { title: payload.title, subtitle: payload.subtitle, body: payload.body }
    : { title: payload.title, body: payload.body },
  sound: 'default',
  'mutable-content': 1,
}
```

**Android FCM** (`sendFcmNotification`) and **Web VAPID**
(`sendPushNotification`): merge subtitle into body with `\n`, because neither
surface supports a subtitle line. Do the merge once at the top of each
platform-specific function so the rest of the logic stays untouched:

```typescript
const mergedBody = payload.subtitle
  ? `${payload.subtitle}\n${payload.body}`
  : payload.body
```

Then use `mergedBody` everywhere that function currently reads
`payload.body`. This keeps the merge local to each dispatcher; the
`PushPayload` object itself stays immutable.

### 3. Optional suppression filter in `sendPushToUsers`

Extend the function signature in `web-push.ts`:

```typescript
export async function sendPushToUsers(
  adminClient: SupabaseClient,
  companyId: string,
  notificationType: string,
  payload: PushPayload,
  options?: {
    /**
     * Skip users who have this OTHER notification type enabled. Useful to
     * avoid redundant alerts when the current push would duplicate info
     * already sent via a different channel.
     */
    suppressIfAlsoEnabled?: string
  },
): Promise<{ sent: number; expired: number }>
```

Implementation: after the existing `disabledPrefs` lookup, do a second
lookup for the suppression type's *disabled* rows, then compute
`suppressedUserIds = members \ disabledForOtherType` — i.e., everyone who
has the other type enabled (absent row counts as enabled, matching the
existing default). Exclude those from the subscription filter.

### 4. Sale notification rendering (mqtt-webhook)

`Docker/supabase/functions/mqtt-webhook/index.ts` already fetches
`tray.current_stock`, `tray.capacity`, `tray.min_stock` in the same block
that builds the notification. Extend the query to also pull
`fill_when_below`, compute the urgency emoji and the body string, and call
`sendPushToUsers` with the new subtitle field.

Urgency emoji helper (pure, can sit next to the dispatch code):

```typescript
function stockUrgency(currentStock: number, fillWhenBelow: number): string {
  if (currentStock === 0) return '🚨 '
  if (fillWhenBelow === 0) return ''                     // no threshold configured
  if (currentStock <= fillWhenBelow) return '⚠️ '
  if (currentStock <= fillWhenBelow * 1.5) return '🟡 '
  return ''
}
```

Body assembly:

```typescript
const emoji = stockUrgency(tray.current_stock, tray.fill_when_below)
const refillHint = tray.fill_when_below > 0 ? ` — refill at ${tray.fill_when_below}` : ''
const stockLine = `${emoji}${tray.current_stock}/${tray.capacity} left${refillHint}`
```

Dispatch:

```typescript
await sendPushToUsers(adminClient, embedded.company, 'sale', {
  title: machine?.name ? `🛒 New Sale · ${machine.name}` : '🛒 New Sale',
  subtitle: `${productName ?? `Item #${itemNumber}`} — €${salePrice.toFixed(2)}`,
  body: stockLine,
  image: productImageUrl,
  data: { type: 'sale', embedded_id: embedded.id },
})
```

The old single-line body (with channel in parens) is dropped. Channel info
(`cash` / `card` / `cashless`) is no longer shown in the push — if someone
wants it back it can always be added to the end of the stockLine, but the
user didn't ask for it and the operator probably doesn't care per-sale.

Edge case: when no tray row exists (unknown item number), we skip the stock
suffix and fall back to a minimal body (`No stock info`) so the notification
still fires. Same for when `tray.capacity` is zero or absent.

### 5. Low-stock notification with dedup

Right after the sale dispatch, the existing low-stock branch becomes:

```typescript
if (machine && lowTray) {
  await sendPushToUsers(adminClient, embedded.company, 'low_stock', {
    title: 'Low Stock Alert',
    body: `${productName ?? `Item #${itemNumber}`} in ${machine.name}: ${lowTray.current_stock}/${lowTray.capacity} remaining`,
    image: productImageUrl,
    data: { type: 'low_stock', machine_id: machine.id },
  }, {
    suppressIfAlsoEnabled: 'sale',
  })
}
```

The body stays as-is (not this spec's scope), the subtitle is not used
because the existing body already reads naturally on a single line.

### 6. Test notification simulates a sale

`Docker/supabase/functions/test-push/index.ts` currently sends a generic
text body. Rewrite it to build a sale-shaped payload with hardcoded dummy
stock and a real product (for the image). The notification-preference type
stays `_test` so the button keeps working for users with `sale` disabled.
`data.type = 'test'` stays so the client can distinguish later if wanted.

Dummy values:
- Machine name: `Test Machine`
- Stock: 3 left, capacity 10, `fill_when_below` 5 → 🟡 (warning zone)
- Price: `€2.50`
- Product name: whatever the first product-with-image lookup returns; fall
  back to `Sample Product` if no image-bearing product exists

Resulting notification:
- Title: `🛒 New Sale · Test Machine`
- Subtitle: `<product name> — €2.50`
- Body: `🟡 3/10 left — refill at 5`
- Image: product image (if any)

### 7. Backward compatibility

- `PushPayload.subtitle` is optional; existing callers that don't set it
  produce the same pushes as today on every platform.
- `sendPushToUsers`'s new `options` argument is optional; existing callers
  behave unchanged.
- iOS app versions that don't have the Notification Service Extension still
  render the new sale push correctly — iOS natively renders
  `aps.alert.subtitle` on all iOS 10+ devices. They just don't get the
  product image attachment, same as before.
- Android and web push clients see the subtitle merged into the body via
  newline — no client-side change needed. If a specific client wants to
  render subtitle+body as separate lines later, we can add it to the payload
  data block.
- Older firmware is unaffected (server-side change only).

## Data Flow

```
ESP32 sale → MQTT → forwarder → mqtt-webhook edge function
  │
  ├── Insert sales row (unchanged)
  │
  ├── Look up machine + tray + product
  │     (tray now also fetches fill_when_below)
  │
  ├── Compute stockUrgency(current_stock, fill_when_below) → emoji
  │
  ├── sendPushToUsers('sale', { title, subtitle, body, image })
  │     ├── iOS APNs direct → aps.alert.{title, subtitle, body}
  │     ├── Android FCM → notification.body = `${subtitle}\n${body}`
  │     └── Web VAPID → same \n merge in the JSON body
  │
  └── if low stock:
        sendPushToUsers('low_stock', ..., { suppressIfAlsoEnabled: 'sale' })
          → recipients = (low_stock enabled) - (sale enabled)
```

## Testing

### Unit-style tests (Deno)

The two new pure helpers are trivial to test and worth locking down:

- `stockUrgency(currentStock, fillWhenBelow)` — test the four buckets
  (empty, critical, warning, normal) plus the `fillWhenBelow === 0` case.
- `sendPushToUsers`'s suppression filter can be unit-tested if we extract
  the recipient-selection logic into a pure helper; if not, it's covered by
  integration testing.

Test framework: existing Deno tests use `Deno.test()`. Put new tests next to
the code, e.g.:

- `Docker/supabase/functions/mqtt-webhook/stock-urgency.test.ts`
- `Docker/supabase/functions/_shared/web-push.test.ts` (new file — add
  recipient-filter test covering `suppressIfAlsoEnabled`)

### Manual integration tests

- Press "Send Test Notification" from the iOS app (Debug and Release builds)
  → verify three-line layout with product image + correct urgency emoji.
- Trigger a real sale on a machine where `fill_when_below` is set to e.g. 5
  and the tray is at 3 after the sale → verify sale push shows 🟡 prefix
  and no duplicate low-stock push arrives for that user.
- Turn off `sale` preference for a second test user, leave `low_stock` on
  → trigger a critical sale → verify that user gets the low-stock push.
- Verify web push on the PWA shows the subtitle inline (newline preserved
  by the service-worker `body` rendering).

## Rollout

Server-side only. Deploy the edge-function changes; any connected client
(iOS, Android, web) picks up the richer notifications on the next sale
without any app update. iOS 10+ renders `aps.alert.subtitle` natively.

If anything goes wrong (e.g., subtitle merge produces weird body on a
specific client), revert the two edge-function commits — no schema change
or irreversible state.

## Open Items

None — all design questions resolved during brainstorming.

## References

- Backend sale push dispatch: `Docker/supabase/functions/mqtt-webhook/index.ts:309-378`
- Shared push helper: `Docker/supabase/functions/_shared/web-push.ts`
- Test push: `Docker/supabase/functions/test-push/index.ts`
- Tray schema: `machine_trays` table with `capacity`, `current_stock`,
  `min_stock`, `fill_when_below` (per-company via FK through vendingMachine)
- Notification preferences: `notification_preferences` table, absence = enabled
- iOS extension (image attachment): `ios/NotificationService/NotificationService.swift`
- Apple docs: [Generating a remote notification](https://developer.apple.com/documentation/usernotifications/generating-a-remote-notification) — `aps.alert.subtitle` reference
