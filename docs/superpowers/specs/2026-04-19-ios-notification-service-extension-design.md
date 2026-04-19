# iOS Notification Service Extension — Design

**Date:** 2026-04-19
**Status:** Draft
**Owner:** Lucien Kerl

## Summary

Add a `NotificationService` app extension target to the native iOS VMflow app so
that push notifications can display the product image of the item that was just
sold (and any other image the backend attaches in the future). The backend
already ships `productImageUrl` as the `image` field in sale push payloads and
already sets `mutable-content: 1` in the APNs payload. The iOS app currently
lacks the Notification Service Extension that is required to actually surface
rich media — so today iOS users only see the app icon next to the alert, while
web-push and Android-FCM users already see the product image.

The extension is intentionally generic: it reads the `image` URL from
`userInfo` regardless of notification type (`sale`, `low_stock`, future types)
and attaches the download as a `UNNotificationAttachment`. If anything fails
(missing URL, download error, timeout, unsupported format) the original
notification is delivered unchanged.

## Problem

Rich push notification media on iOS requires a `UNNotificationServiceExtension`
— a separate app extension target that intercepts incoming pushes with
`mutable-content: 1`, modifies the content (e.g. attaches downloaded files),
and hands it back to the system for display. The main app process cannot do
this; Apple runs the extension in its own short-lived process even when the
host app is terminated or backgrounded.

Current state:

- `Docker/supabase/functions/mqtt-webhook/index.ts:337-356` already looks up
  `products.image_path` for the sold item and includes it as the `image` field
  in the `sendPushToUsers(..., 'sale', { image: productImageUrl, ... })` call.
- `Docker/supabase/functions/_shared/web-push.ts:327` sets
  `aps['mutable-content'] = 1` on every APNs push.
- `ios/VMflow/` contains no extension target — `project.yml` defines only the
  `VMflow` application target.

Result: The `image` field arrives in the iOS push payload but nothing unpacks
it. Web and Android already render it (VAPID/FCM notification formats handle
images natively). Only iOS users get a text-only banner with the app icon.

## Goals

- iOS push notifications display the product image as a thumbnail (lock screen
  / banner) and as a large expanded preview (long-press / notification center).
- Works for all notification types that include an `image` URL — no type-
  specific code in the extension.
- Works in **both Debug and Release** builds side-by-side, matching the
  existing bundle-ID suffix convention (`.debug` vs production).
- Graceful degradation: any failure downloading or attaching the image leaves
  the notification otherwise unchanged and still delivered.
- No changes to the backend or the push payload format — fully backward
  compatible. Users on older app builds without the extension keep seeing the
  text-only notification.

## Non-Goals

- **No image caching.** The extension runs in a short-lived sandboxed process;
  persistent caching via App Groups is real work for marginal benefit (typical
  product image ≈ 10–100 kB over HTTPS, one download per notification).
- **No WebP conversion.** `UNNotificationAttachment` supports JPEG, PNG, GIF,
  HEIC. The `product-images` bucket allows WebP uploads; if a user uploads a
  WebP, the iOS thumbnail will silently not appear. Fixing that is a separate
  concern (backend imgproxy rewrite or bucket policy).
- **No changes to other notification types.** `low_stock` and `inbox` pushes
  today do not include an `image` field; the extension will just pass them
  through unchanged. Wiring images into those flows is a future backend change.
- **No changes to Web Push or Android.** They already work.
- **No rich notification actions / buttons.** Only the image attachment.

## Architecture

### New target: `NotificationService`

A second target in `ios/project.yml` of type
`app-extension.notification-service`, embedded into the `VMflow` host app.
Three new files under `ios/NotificationService/`:

```
ios/NotificationService/
  NotificationService.swift   # UNNotificationServiceExtension subclass
  Info.plist                  # NSExtension + ATS mirror
```

Plus modifications to:

- `ios/project.yml` — add target, wire embed, bind bundle ID to xcconfig.
- `ios/Configurations/Debug.xcconfig` — add `EXTENSION_BUNDLE_IDENTIFIER`.
- `ios/Configurations/Release.xcconfig` — add `EXTENSION_BUNDLE_IDENTIFIER`.

### Bundle IDs

Apple requires extension bundle IDs to be suffixes of the host app. Following
the existing Debug / Release split:

| Config | Host app ID | Extension ID |
|--------|-------------|--------------|
| Debug   | `de.kerl-handel.app.debug` | `de.kerl-handel.app.debug.NotificationService` |
| Release | `de.kerl-handel.app` | `de.kerl-handel.app.NotificationService` |

Defined as `EXTENSION_BUNDLE_IDENTIFIER` per xcconfig; the extension target in
`project.yml` sets `PRODUCT_BUNDLE_IDENTIFIER = $(EXTENSION_BUNDLE_IDENTIFIER)`.
This keeps both configs parallel to the existing main-app convention and lets
Debug + Release be installed on the same device.

### Data flow

```
APNs push (mutable-content:1, image URL in userInfo)
   │
   ▼
NotificationService.didReceive(request, contentHandler)
   │  1. copy request.content → bestAttemptContent (mutableCopy)
   │  2. read imageUrl = userInfo["image"] as String?
   │  3. if nil → contentHandler(bestAttemptContent); return
   │
   ▼
URLSession.shared.downloadTask(with: imageUrl)
   │
   ├─ success ─► move tempURL into NSTemporaryDirectory with file extension
   │             preserved from URL path (so iOS recognizes the UTI)
   │          ─► UNNotificationAttachment(identifier:"image", url:fileURL)
   │          ─► bestAttemptContent.attachments = [attachment]
   │          ─► contentHandler(bestAttemptContent)
   │
   └─ failure / unsupported / timeout
              ─► contentHandler(bestAttemptContent) unchanged
```

### Error handling (critical — live production devices)

Every failure path falls back to calling `contentHandler` with
`bestAttemptContent` so the text notification still arrives:

- **No `image` key in userInfo** → fall through (inbox / low_stock today).
- **`image` key present but not a String / invalid URL** → fall through, log
  once with `os_log`.
- **`URLSession` download error or non-2xx HTTP status** → fall through.
- **File move fails** → fall through.
- **`UNNotificationAttachment` init throws** (unsupported format / size) →
  fall through, drop the temp file.
- **`serviceExtensionTimeWillExpire` fires** (≈30 s budget) → return whatever
  `bestAttemptContent` holds at that moment via `contentHandler`. Cancel the
  in-flight download task.

The extension never crashes and never silently swallows the notification.

### Info.plist for the extension

Mirrors the main app's ATS exception so Debug builds can fetch product images
over HTTP from the local Supabase at `http://10.0.1.130:54321`. Release builds
hit HTTPS and don't need the exception, but keeping it in both configs keeps
the extension identical between configs — Xcode build settings handle the
environment split via xcconfig, the plist is shared.

Required keys:

- `NSExtension` → `NSExtensionPointIdentifier = com.apple.usernotifications.service`
- `NSExtension` → `NSExtensionPrincipalClass = $(PRODUCT_MODULE_NAME).NotificationService`
- `CFBundleDisplayName`, `CFBundleIdentifier = $(PRODUCT_BUNDLE_IDENTIFIER)`,
  `CFBundleVersion = $(CURRENT_PROJECT_VERSION)`, `CFBundleShortVersionString`
- `NSAppTransportSecurity` → `NSAllowsArbitraryLoads = true`,
  `NSAllowsLocalNetworking = true` (mirrors main app for Debug HTTP reach).

### Backend / APNs topic routing — unchanged

`push_subscriptions.apns_topic` is populated at registration time from
`Bundle.main.bundleIdentifier` (see `NotificationService.registerWithBackend`
in `ios/VMflow/Services/NotificationService.swift:151-156`). So:

- Debug build registers → topic `de.kerl-handel.app.debug` → local Supabase
  pushes land there.
- Release build registers → topic `de.kerl-handel.app` → prod Supabase
  pushes land there.

The extension inherits the host app's APNs registration — extensions do not
register separately with APNs. `Docker/.env` `APNS_TOPIC` needs no change in
either environment.

### Signing

Automatic signing is already active (`CODE_SIGN_STYLE: Automatic`,
`DEVELOPMENT_TEAM: 4JT3V7XVXM`). Xcode will provision both new App IDs
(`de.kerl-handel.app.debug.NotificationService` and
`de.kerl-handel.app.NotificationService`) on first build.

Push Notifications capability is **not** required on the extension App ID —
extensions inherit the host's entitlements for notification delivery. The
host app's existing Push Notifications entitlement is sufficient.

## Testing

### Unit-testable surface — minimal

The extension logic is thin glue (download + attach) and dominated by
`UNNotificationServiceExtension` lifecycle calls that are awkward to mock.
A Swift-side unit test would primarily test the URL-parsing and file-extension
handling, which is not a high-value target. Skip unit tests; rely on manual
integration tests on device.

### Manual integration test plan

**Prerequisite: augment `test-push` to include an image.** The current
`Docker/supabase/functions/test-push/index.ts` does not attach an `image`
field, so it would not exercise the extension. Option A: temporarily add a
fixed sample image URL for the test payload. Option B (recommended): pick one
of the user's own products (first `product-images/*` from the auth'd user's
company) as the test image — covers the real URL pattern including storage
path + HTTPS.

Test matrix (run both in Debug against local Supabase and Release against
prod):

1. **Sale with image attached** — trigger a sale on a machine whose tray has
   a product with an image. Verify:
   - Banner shows thumbnail next to title/body.
   - Long-press expands to large preview.
   - Lock screen shows thumbnail.
   - Notification Center shows thumbnail.
2. **Sale without image** — product with `image_path = NULL`. Verify text-only
   banner arrives (no crash, no broken thumbnail placeholder).
3. **Inbox notification** — submit a product wish from the anonymous machine
   page. Verify text-only banner arrives unchanged (no `image` field in
   payload → extension falls through).
4. **Low stock notification** — trigger the `check-low-stock` cron. Verify
   text-only banner arrives unchanged.
5. **Broken image URL** — manually craft a push via `test-push` with an
   invalid image URL. Verify text banner arrives within normal timing (no
   30 s hang — the extension deadlines the download).
6. **Foreground delivery** — open the app, trigger a sale. The foreground
   presentation handler in `AppDelegate` should still show the banner with
   thumbnail.
7. **Side-by-side** — install Debug build, then Release build, trigger sales
   from both Supabases. Verify each app receives its own pushes with images.

### Regression checks

- Badge count (`openInboxCount` → `aps.badge`) continues to work — extension
  must not overwrite or clear `badge` on the modified content.
- Deep link (`userInfo["type"] == "inbox"` → `pendingDeepLink = .inbox`) still
  routes on tap — extension must preserve all `userInfo` fields untouched.

## Rollout

1. Land extension target + code on `main`.
2. Next Debug build on-device exercises it against local Supabase.
3. Next Release build / TestFlight exercises it against prod Supabase.

Both configs ship together — the extension is fail-safe so there is no reason
to stage them separately. Users on older Release builds without the extension
continue to receive text-only notifications as today; no coordination with
firmware or backend is required.

## Open Items

- `test-push` needs a minor augmentation to include an image in the test
  payload. In scope for this work; will be picked up in the implementation
  plan as a small adjacent change so the manual test plan above is runnable.

## References

- Backend sale push with image: `Docker/supabase/functions/mqtt-webhook/index.ts:337-356`
- Shared APNs payload construction: `Docker/supabase/functions/_shared/web-push.ts:321-340`
- Existing iOS notification service: `ios/VMflow/Services/NotificationService.swift`
- iOS project config: `ios/project.yml`, `ios/Configurations/{Debug,Release}.xcconfig`
- Apple docs: [Modifying content in newly delivered notifications](https://developer.apple.com/documentation/usernotifications/modifying-content-in-newly-delivered-notifications)
