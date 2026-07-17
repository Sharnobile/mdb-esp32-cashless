# App Store Connect — App Privacy answers

Values to enter under **App Store Connect → your app → App Privacy**. These must
agree with the app's `PrivacyInfo.xcprivacy` (phase 1) and the privacy policy at
`/legal/privacy`. Derived from the phase-1/2 code audit — re-check against the
code, don't just re-copy, when the app's data use changes.

## Does this app collect data? → **Yes**

Two data types are collected, both **linked to the user's identity**, both used
only for **App Functionality**, and **none used for tracking**.

### 1. Contact Info → Email Address
- **Collected:** Yes
- **Linked to identity:** Yes (it *is* the account identifier)
- **Used for tracking:** No
- **Purposes:** App Functionality (authentication)
- Why: sign-in is email + password via the self-hosted Supabase Auth backend.

### 2. Identifiers → Device ID
- **Collected:** Yes
- **Linked to identity:** Yes (stored against the user's push subscription)
- **Used for tracking:** No
- **Purposes:** App Functionality (push notifications)
- Why: the APNs device token is stored (`push_subscriptions`) to deliver
  low-stock/event alerts. Only collected if the user enables notifications.

## Everything else → **Not Collected**

Explicitly answer **No** to all other categories, in particular:
- **Usage Data / Analytics** — none. No analytics or tracking SDK is present.
- **Location** — the app stores machine coordinates as *business* data entered by
  the operator; it does **not** collect the device's location. Answer No.
- **Photos/Camera** — the camera is used **on-device** to scan barcodes; no image
  is captured or uploaded. This is not "data collection". Answer No.
- **Financial Info** — sales figures are the operator's business data about their
  own machines, not the user's personal financial info. Answer No.

## Tracking → **No**
The app does not track users across apps or websites owned by other companies.
`NSPrivacyTracking` is `false` in the manifest, `NSPrivacyTrackingDomains` empty.

## Cross-check
| Artefact | Must say |
|---|---|
| `PrivacyInfo.xcprivacy` | EmailAddress + DeviceID, linked, non-tracking, app-functionality; `NSPrivacyTracking=false` |
| `/legal/privacy` | account email, APNs token, no tracking, camera local-only |
| This questionnaire | the two types above, nothing else |

If you ever add analytics, a crash reporter, or an ad SDK, all three change together.
