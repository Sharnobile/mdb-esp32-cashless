# iOS App Store Release — Design

**Date:** 2026-07-15
**Status:** Approved (design), pending spec review
**Author:** Lucien Kerl (with Claude)

## 1. Problem & Goal

`ios/VMflow` (SwiftUI, iOS 17+) is a finished, in-use operator app that has
never been shipped through Apple. It is built and installed ad-hoc from Xcode.

Goal: publish it on the **public App Store** and make releasing repeatable:

- Every artefact Apple requires exists (legal documents, privacy answers,
  metadata, screenshots, review access).
- A **manually triggered** GitHub Actions pipeline builds, signs and uploads the
  app plus its **en/de** metadata and **automatically generated** screenshots.

Non-goals: iPad support, automatic submission to review, marketing website,
Android/PWA release.

## 2. Current State

Established by inspection on 2026-07-15:

| Fact | Source |
|---|---|
| Release bundle ID `de.kerl-handel.app`, team `4JT3V7XVXM` | `ios/Configurations/Release.xcconfig` |
| `CODE_SIGN_STYLE = Automatic` | `ios/project.yml:34` |
| String Catalog: `en` + `de`, 442 keys | `ios/VMflow/Resources/Localizable.xcstrings` |
| `ITSAppUsesNonExemptEncryption = false` (export compliance answered) | `ios/VMflow/Resources/Info.plist` |
| Build number from `git rev-list --count HEAD` via preBuildScript | `ios/project.yml:36-43` |
| Backend selectable at runtime (multi-server) | `ios/VMflow/Services/ServerStore.swift` |
| Supabase reached via one singleton client | `ios/VMflow/Services/SupabaseService.swift` |
| No test target of any kind | `ios/VMflow.xcodeproj/project.pbxproj` |
| No fastlane, no iOS workflow | `ios/`, `.github/workflows/` |
| Public repo → macOS runners are free | `gh repo view` |
| Public frontend URL | `https://lagerapp.kerl.io` |

**XcodeGen divergence:** `ios/project.yml` exists but the committed
`project.pbxproj` is the source of truth (new Swift files are registered in it
by hand — see memory `project_ios_xcode_file_registration`). Regenerating from
`project.yml` would drop files. **This design does not run XcodeGen.** New
targets and files are registered in `project.pbxproj` directly, and `project.yml`
is updated best-effort to stay descriptive, never authoritative.

## 3. Store Blockers

These would each cause a rejection or a broken listing.

### 3.1 APNs entitlement (rejection)

`ios/VMflow/Resources/VMflow.entitlements` hardcodes
`aps-environment = development`. App Store builds require `production`.

**Fix:** split into `VMflow.entitlements` (Debug, `development`) and
`VMflow.Release.entitlements` (Release, `production`), selected per
configuration via `CODE_SIGN_ENTITLEMENTS` in the two xcconfigs. Backend side
already switches on `APNS_PRODUCTION` (`ios/README.md`); no backend change.

### 3.2 ATS + local-network strings (review risk)

`Info.plist` sets `NSAllowsArbitraryLoads = true`,
`NSAllowsLocalNetworking = true`, Bonjour `_http._tcp`, and
`NSLocalNetworkUsageDescription = "…connect to the development server."`

The blanket exception exists for a real reason: `ServerStore` lets an operator
point the app at a self-hosted Supabase over plain `http://` on their LAN.

**Fix:** drop `NSAllowsArbitraryLoads`, keep `NSAllowsLocalNetworking` and
Bonjour, and reword the usage string to describe the actual feature (connecting
to a self-hosted VMflow server on the local network) with no mention of
development.

**Open risk, must be verified during implementation, not assumed:**
`NSAllowsLocalNetworking` is documented for unqualified hostnames and `.local`;
whether it covers a numeric private IP such as `http://10.0.1.181:8000` needs an
empirical check against a real LAN instance. If it does not, the fallback is to
keep `NSAllowsArbitraryLoads = true` and justify it in the review notes ("app
connects to user-operated self-hosted servers"), which is an accepted
justification but invites reviewer questions. Decide on evidence.

### 3.3 Account deletion (certain rejection)

`ios/VMflow/Views/Auth/RegisterView.swift` creates accounts in-app; nothing
deletes them. Guideline 5.1.1(v) requires in-app deletion whenever in-app
creation exists.

**Fix:** see §4.

### 3.4 Device family (broken listing)

`TARGETED_DEVICE_FAMILY` is unset → the app is universal → Apple additionally
demands 13" iPad screenshots.

**Fix:** set `TARGETED_DEVICE_FAMILY = 1` (iPhone only). Decided: the app is
designed for one-handed field use.

## 4. Account Deletion

**UI:** a destructive "Konto löschen / Delete account" row at the bottom of
`ios/VMflow/Views/Settings/SettingsView.swift`, behind a confirmation dialog
that names the consequence. New `en`/`de` entries in the String Catalog
(insert surgically per memory `reference_ios_xcstrings_editing`).

**Backend:** new edge function `Docker/supabase/functions/delete-account/`.

Contract:

```
POST /functions/v1/delete-account
Authorization: Bearer <user JWT>
→ 200 {"deleted": true}
→ 409 {"error": "last_admin"}     // caller is the last admin of their company
→ 401 {"error": "unauthorized"}
```

Logic, in order:

1. Resolve the caller via `adminClient.auth.getUser(token)` — the established
   pattern (`verify_jwt = false` + in-function verification, see `CLAUDE.md`).
2. Read the caller's `organization_members` row for `company_id` and `role`.
3. If `role = 'admin'` and no *other* admin exists for that `company_id` →
   `409 last_admin`. **Blocking is deliberate:** company data (machines, sales,
   warehouse, field devices) must not be destroyed by one tap, and devices in
   the field would publish into a void. The app shows: assign another admin or
   delete the company first.
4. Otherwise delete the `organization_members` row, then
   `adminClient.auth.admin.deleteUser(userId)`.
5. On success the app signs out and returns to the login screen.

A member with no company row can always delete. Registration stays in the app.

**Wiring (both environments, per memory `project_supabase_cli_workdir_env_parse`):**
`config.toml` needs a `[functions.delete-account]` entry with `import_map`, and
the function needs its own `deno.json`. It uses only `SUPABASE_URL` and
`SERVICE_ROLE_KEY`, which already exist in both environments — no new env var,
so `.env.example` / `setup.sh` / `update.sh` are untouched.

## 5. Legal Pages

New Nuxt pages under `management-frontend/app/pages/legal/`: `privacy.vue`,
`support.vue`, `terms.vue`, `imprint.vue`. Public URLs:

- `https://lagerapp.kerl.io/legal/privacy` → App Store privacy URL (required)
- `https://lagerapp.kerl.io/legal/support` → App Store support URL (required)
- `https://lagerapp.kerl.io/legal/terms`, `/legal/imprint` → linked from both

**Must-not-forget:** add `/legal` to `publicRoutes` in
`management-frontend/app/middleware/auth.ts:2-11`. Without it, Apple's reviewer
gets redirected to the login page and the mandatory URL counts as dead.

Text lives in the existing `i18n/locales/{en,de}.json` under a `legal.*` key
tree. i18n `strategy: 'no_prefix'` means there is no `/de/legal/privacy` URL —
one URL renders per the visitor's locale. That satisfies Apple (a single privacy
URL per locale is allowed to repeat), and both localized App Store entries point
at the same URL.

Content is scoped to what the app actually does: account e-mail, the operator's
own business data, APNs push tokens, camera used locally for barcodes with no
image upload, no tracking, no third-party analytics, self-hosted backend under
the operator's control.

## 6. App Privacy Answers

`docs/ios/app-store-privacy-answers.md` — the values to enter in App Store
Connect's privacy questionnaire, derived from the same audit as §5, with the
justification per item so the next release can re-check rather than re-guess.
Expected shape: *Contact Info → e-mail, linked to identity, app functionality*;
*Identifiers → device token (push), app functionality*; *Tracking → no*.
The audit is part of the work, not a foregone conclusion; the file records what
it finds.

## 7. Fastlane

New `ios/fastlane/`: `Appfile`, `Fastfile`, `Snapfile`, `Deliverfile`, and
`metadata/{en-US,de-DE}/` (name, subtitle, description, keywords, release notes,
support/marketing URL), plus `screenshots/{en-US,de-DE}/`.

| Lane | Does |
|---|---|
| `beta` | archive + sign + upload to TestFlight |
| `screenshots` | run the UI-test target, capture en+de |
| `metadata` | upload text + screenshots only (`skip_binary_upload`) |
| `release` | binary + metadata, **`submit_for_review: false`** |

`release` deliberately stops before submission — the first releases get a human
in front of the button.

Signing: App Store Connect API key (`.p8`) via fastlane `app_store_connect_api_key`,
with `xcodebuild -allowProvisioningUpdates` so Xcode fetches certificate and
profile itself. This keeps `CODE_SIGN_STYLE = Automatic` and adds no cert repo.

## 8. Screenshot Automation

New UI-test target `VMflowScreenshots`, registered by hand in `project.pbxproj`
(§2).

**The seam.** All 11 ViewModels reach Supabase through
`SupabaseService.shared.client`. Rather than injecting protocols into each,
`SupabaseService` gets exactly one branch: when the launch arguments contain
`-UITestFixtures`, it builds its `SupabaseClient` with a `URLSession` whose
`configuration.protocolClasses` starts with `FixtureURLProtocol`, and it skips
`ServerStore` (using a dummy URL/key). Production behaviour is untouched.

**Verify before building on it:** that supabase-swift v2 exposes a custom
`URLSession` through `SupabaseClientOptions.global.session`. If that seam does
not exist in the pinned version, the fallback is registering
`FixtureURLProtocol` on `URLSessionConfiguration.default` from the test-launched
process, which is broader but needs no SDK support. Confirm which applies before
writing fixtures.

**`FixtureURLProtocol`** matches request path/method against JSON files bundled
in the test target and returns canned responses. It must cover the auth
token endpoint, PostgREST reads, edge-function calls the screens make
(`get-my-organization`, the KPI RPCs) and Storage image bytes. Realtime
(`RealtimeService`) uses WebSockets, which `URLProtocol` cannot intercept —
under the fixture flag Realtime subscriptions are skipped. Static screenshots do
not need live updates.

**Fixtures** are hand-authored, plausible demo data (fictional machines, products
and revenue), not a dump of real customer data.

**Screens captured** (× `en`, `de`): Dashboard, machine list, machine detail,
refill wizard, warehouse. Device: iPhone 16 Pro Max (6.9") — the only size Apple
still requires, and it upscales to nothing else since iPad is out.

Determinism: fixed fixture data, no network, no clock-dependent copy in frame
(relative timestamps like `timeAgo` are fed absolute fixture dates far enough
in the past to render stably).

## 9. GitHub Actions

`.github/workflows/ios-release.yml`:

- `on: workflow_dispatch` with a `lane` choice input (`beta` | `screenshots` |
  `metadata` | `release`). No push or tag trigger — decided: nothing reaches
  Apple without a deliberate click.
- `runs-on: macos-15`, Xcode selected explicitly (project declares 16.0).
- `actions/checkout` with **`fetch-depth: 0`** — the build number is
  `git rev-list --count HEAD`; a shallow clone yields `1` and App Store Connect
  rejects a build number lower than the last upload.
- Secrets: `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`,
  `APP_STORE_CONNECT_KEY_P8` (base64). Secrets are unavailable to fork PRs;
  `workflow_dispatch` is collaborator-only, so a public repo is not a leak path.

The `screenshots` lane needs no secrets (fixtures, no network).

## 10. Review Access

Fixtures serve screenshots; they do **not** serve review. The reviewer runs the
real app against a real server.

- A demo company on `https://supabase.kerl-handel.de` with seeded machines,
  products and sales, plus a demo user (viewer or admin — decided during setup).
- Credentials go in App Store Connect review notes, never in the repo.
- The notes must explain the server picker: which server is preselected and that
  no action is needed. A reviewer who lands on a server-selection screen with no
  context files a "cannot log in" rejection.
- `docs/ios/app-store-review-notes.md` holds the reusable text (no password).

## 11. Build Order

1. **Blockers** — entitlements split, ATS/strings, `TARGETED_DEVICE_FAMILY`.
2. **Account deletion** — edge function + Settings UI + strings.
3. **Legal pages** — 4 pages, i18n text, `publicRoutes`.
4. **Fastlane + Actions** — `beta` lane green → TestFlight reachable.
5. **Screenshots** — test target, seam, fixtures, `screenshots` lane.
6. **Metadata + docs** — en/de metadata, privacy answers, review notes.

After step 4 TestFlight builds are possible; 5–6 complete the store listing.

## 12. Verification

| Item | How |
|---|---|
| Entitlements | inspect the Release archive's embedded entitlements for `aps-environment: production` |
| ATS | run against a real `http://` LAN server; if broken, §3.2 fallback |
| `delete-account` | SQL/RPC-style test per `project_sql_test_harness`: normal member deletes; last admin gets 409; second admin present → deletes |
| Legal pages | `curl` each URL logged-out → 200, not a login redirect |
| Screenshots | `fastlane screenshots` twice → identical output; 10 files (5 × 2 languages) |
| Pipeline | `beta` lane → build visible in TestFlight |
| Build number | assert the CI-computed number exceeds the last uploaded |

Frontend: `npx vitest run` stays green. Firmware and MQTT are untouched — no
backward-compatibility surface is affected (the one new edge function is additive
and unknown to existing clients).
