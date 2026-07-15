# iOS App Store Release — Design

**Date:** 2026-07-15
**Status:** Approved (design), spec review round 2
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
Android/PWA release, member/role management in iOS.

## 2. Current State

Verified by inspection on 2026-07-15.

| Fact | Source |
|---|---|
| Release bundle ID `de.kerl-handel.app`, extension `…app.NotificationService` | `ios/Configurations/Release.xcconfig` |
| Team `4JT3V7XVXM`, `CODE_SIGN_STYLE = Automatic` | `ios/project.yml:36-38` |
| Build number from `git rev-list --count HEAD` | `ios/project.yml:39-45` |
| String Catalog: `en` + `de`, 442 keys | `ios/VMflow/Resources/Localizable.xcstrings` |
| `ITSAppUsesNonExemptEncryption = false` (export compliance answered) | `ios/VMflow/Resources/Info.plist` |
| Backend selectable at runtime (multi-server) | `ios/VMflow/Services/ServerStore.swift` |
| All 11 ViewModels reach Supabase via one singleton | `ios/VMflow/Services/SupabaseService.swift` |
| supabase-swift pinned at **2.43.1** (exposes `SupabaseClientOptions.global.session`) | `Package.resolved` |
| No test target, no fastlane, no iOS workflow | `ios/`, `.github/workflows/` |
| Public repo → macOS runners free; `workflow_dispatch` is collaborator-only | `gh repo view` |
| Public frontend URL | `https://lagerapp.kerl.io` |
| **No** member/role management UI in iOS (Settings shows org + role read-only) | `ios/VMflow/Views/` |

**XcodeGen divergence:** `ios/project.yml` exists but the committed
`project.pbxproj` is the source of truth — new Swift files are registered in it
by hand (memory `project_ios_xcode_file_registration`). Regenerating from
`project.yml` would drop files. **This design never runs XcodeGen.** New targets
and files are registered in `project.pbxproj` directly; `project.yml` is updated
best-effort as description only, never as authority.

Second target: `ios/NotificationService/` is an embedded app extension with its
own bundle ID and its own `Info.plist`. Every plist/build-setting change below
applies to **both** targets unless stated otherwise.

## 3. Store Blockers

Each of these fails the upload or the review. §3.1–3.2 fail before a human ever
sees the app.

### 3.1 App icon has an alpha channel (upload fails, ITMS-90717)

`ios/VMflow/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png` is
1024×1024 with `hasAlpha: yes` (verified via `sips`). Apple rejects transparent
large icons at upload.

**Fix:** flatten onto an opaque background, keeping the artwork identical.
`AppIcon-Debug.appiconset` is irrelevant (never uploaded).

### 3.2 Missing privacy manifest (upload fails, ITMS-91053)

No `PrivacyInfo.xcprivacy` exists. `UserDefaults` — a required-reason API
(`NSPrivacyAccessedAPICategoryUserDefaults`, CA92.1) — is used in
`ServerStore.swift`, `AuthService.swift`, `NotificationService.swift`,
`RefillWizardViewModel.swift`.

**Fix:** add `PrivacyInfo.xcprivacy` to the app target declaring the
`UserDefaults` reason, plus the collected-data types matching §6. Audit the
NotificationService target separately and give it its own manifest if it touches
a required-reason API. Register as a resource in `project.pbxproj`.
supabase-swift is not on Apple's SDK-signature list, so no third-party manifest
obligation.

### 3.3 APNs entitlement (rejection)

`ios/VMflow/Resources/VMflow.entitlements` hardcodes
`aps-environment = development`; the App Store requires `production`. It also
carries `com.apple.developer.associated-domains: webcredentials:supabase.kerl-handel.de`.

**Fix:** add `VMflow.Release.entitlements` with `aps-environment = production`
**and the associated-domains key preserved verbatim** — dropping it silently
kills password autofill in Release.

**Mechanism matters:** `CODE_SIGN_ENTITLEMENTS` is set at *target* level in
`project.pbxproj:926,943`, and target-level settings override xcconfig. Setting
it in the xcconfigs alone would be silently ignored and ship `development` to
the Store — the exact rejection this section exists to prevent. So set it
per-configuration in `project.pbxproj` directly (or remove the target-level
setting first so the xcconfig can win; pbxproj-direct is preferred, one less
indirection).

Associated Domains must be enabled on the App ID in the developer portal. With
automatic signing + `-allowProvisioningUpdates`, a capability missing from the
App ID fails **provisioning in CI**, not review — an opaque failure worth
pre-empting.

Backend already switches on `APNS_PRODUCTION` (`ios/README.md`); no backend change.

### 3.4 ATS + local-network strings (review risk)

Both `ios/VMflow/Resources/Info.plist` and `ios/NotificationService/Info.plist`
set `NSAllowsArbitraryLoads = true`. The app plist adds `NSAllowsLocalNetworking`,
Bonjour `_http._tcp`, and
`NSLocalNetworkUsageDescription = "…connect to the development server."`

The blanket exception has a real cause: `ServerStore` lets an operator point the
app at a self-hosted Supabase over plain `http://` on their LAN.

**Fix:** drop `NSAllowsArbitraryLoads` from both plists, keep
`NSAllowsLocalNetworking` + Bonjour on the app, and reword the usage string to
describe the actual feature (connecting to a self-hosted VMflow server on the
local network) with no mention of development.

**Open risk — verify empirically, do not assume:** `NSAllowsLocalNetworking` is
documented for unqualified hostnames and `.local`; whether it covers a numeric
private IP like `http://10.0.1.181:8000` must be checked against a real LAN
instance using a **Debug build pointed at a LAN server via the server picker**
(Release defaults to `https://supabase.kerl-handel.de` and cannot exercise the
path). If it does not cover it, the fallback is keeping
`NSAllowsArbitraryLoads = true` and justifying it in the review notes ("connects
to user-operated self-hosted servers") — an accepted justification that invites
questions. Decide on evidence.

### 3.5 Device family (broken listing)

`TARGETED_DEVICE_FAMILY = "1,2"` is set explicitly at **`project.pbxproj:790,
936, 953, 972`** (four build-config blocks, both targets); `project.yml` does not
set it at all. Universal → Apple additionally demands 13" iPad screenshots.

**Fix:** change all four to `"1"`. Decided: iPhone-only, the app is built for
one-handed field use.

### 3.6 Account deletion (certain rejection)

`ios/VMflow/Views/Auth/RegisterView.swift` creates accounts in-app; nothing
deletes them. Guideline 5.1.1(v) requires in-app deletion where in-app creation
exists. See §4.

## 4. Account Deletion

### 4.1 Why the company cascades

The first design blocked the last admin. That is unshippable here: iOS has **no
member management**, so a blocked admin has no in-app way to appoint a successor
— and a solo operator (the typical customer, plausibly the reviewer's own demo
account) has nobody to appoint at all. The account would be permanently
undeletable, which Apple reads as "deletion not offered."

**Decision:** the last admin may delete, and the company goes with them, behind a
type-the-company-name confirmation.

### 4.2 Blocking foreign keys (must be fixed first)

Four FKs lack `ON DELETE` behaviour and would make deletion fail with a raw
`23503`:

| FK | Problem |
|---|---|
| `api_keys.created_by → auth.users(id)` NOT NULL | any user who made an API key is undeletable |
| `cash_books.created_by → auth.users(id)` NOT NULL | same |
| `cash_book_entries.created_by → auth.users(id)` NOT NULL | same |
| `cash_book_entries.company_id → companies(id)` | company delete dies here; every other table cascades |

The first three break the **ordinary** deletion path, not just the last-admin
one — an admin is exactly the user who has created API keys and cash-book
entries.

**New migration** `20260715000000_account_deletion_fk_fixes.sql` (migrations are
immutable — new file, never edit `20260407000000_cash_book.sql`; memory
`feedback_migration_immutability`):

- `api_keys.created_by`, `cash_books.created_by`, `cash_book_entries.created_by`
  → drop `NOT NULL`, re-create FK with `ON DELETE SET NULL`. Attribution is lost;
  the record survives. Cascading instead would delete a company's accounting rows
  and working API keys because a colleague left — wrong.
- `cash_book_entries.company_id` → re-create FK with `ON DELETE CASCADE`,
  matching every other company-scoped table.

Idempotent (`DROP CONSTRAINT IF EXISTS` + `ADD CONSTRAINT`), applied by
`update.sh` on existing installs. Beware the phantom `20260606000000` when
running `supabase migration up` locally (memory
`project_cash_book_phantom_migration`).

⚠️ **Flagged for the user, not decided here:** cash-book entries are accounting
records that German retention law (GoBD/HGB §257) generally requires kept for
years, while GDPR Art. 17(3)(b) exempts exactly such data from erasure. Deleting
a company's cash book on account deletion may conflict with that duty. This is a
legal question for your tax advisor, not an engineering one — it does not block
the iOS work, but the answer may later change what §4.3 deletes.

### 4.3 Edge function

New `Docker/supabase/functions/delete-account/`.

```
POST /functions/v1/delete-account
Authorization: Bearer <user JWT>
Body: {"confirm_company_name": "<string>"}   // required only when cascading
→ 200 {"deleted": true, "company_deleted": bool}
→ 400 {"error": "company_name_mismatch"}
→ 401 {"error": "unauthorized"}
```

Order:

1. Resolve caller via `adminClient.auth.getUser(token)` — the established pattern
   (`verify_jwt = false` + in-function verification, `CLAUDE.md`).
2. Read the caller's `organization_members` row → `company_id`, `role`.
3. If `role = 'admin'` **and** no other admin exists for that company →
   cascading path: require `confirm_company_name` to match `companies.name`
   exactly (else `400`), then delete the `companies` row (FKs cascade the rest).
4. Otherwise delete only the `organization_members` row.
5. `adminClient.auth.admin.deleteUser(userId)`.
6. App signs out, returns to login.

A user with no company row can always delete. Registration stays in the app.

Uses `SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY` — both already present in both
environments, so no `.env.example` / `setup.sh` / `update.sh` / Dockerfile
change. Needs `[functions.delete-account]` with `import_map` in `config.toml`
plus its own `deno.json` (both environments — memory
`project_supabase_cli_workdir_env_parse`).

### 4.4 UI

Destructive "Konto löschen / Delete account" row at the bottom of
`ios/VMflow/Views/Settings/SettingsView.swift`, below Sign Out. Confirmation
dialog names the consequence. For the cascading case: a second screen listing
what disappears (machines, sales, warehouse, devices) and a text field requiring
the company name. New `en`/`de` String Catalog entries, inserted surgically
(memory `reference_ios_xcstrings_editing`).

Field devices are not notified — an ESP32 whose company vanished simply publishes
into a void. Acceptable and out of scope; no firmware or MQTT change (a deleted
company's device rows are gone, so `mqtt-webhook` writes fail as they already do
for unknown devices).

## 5. Legal Pages

New Nuxt pages under `management-frontend/app/pages/legal/`: `privacy.vue`,
`support.vue`, `terms.vue`, `imprint.vue`.

- `https://lagerapp.kerl.io/legal/privacy` → App Store privacy URL (required)
- `https://lagerapp.kerl.io/legal/support` → App Store support URL (required)
- `/legal/terms`, `/legal/imprint` → linked from both

**Must-not-forget:** add `/legal` to `publicRoutes` in
`management-frontend/app/middleware/auth.ts:2-11`. Without it the reviewer's
browser is redirected to login and the mandatory URL counts as dead.

Text lives in `i18n/locales/{en,de}.json` under a `legal.*` tree. i18n
`strategy: 'no_prefix'` means there is no `/de/legal/privacy`; one URL renders in
the visitor's locale, and both localized store entries point at the same URL —
which Apple permits.

Content is scoped to what the app actually does: account e-mail, the operator's
own business data, APNs push tokens, camera used locally for barcodes with no
image upload, no tracking, no third-party analytics, backend self-hosted under
the operator's control. Deletion rights per §4.

## 6. App Privacy Answers

`docs/ios/app-store-privacy-answers.md` — the values to enter in App Store
Connect's questionnaire (a different artefact from §3.2's manifest; both must
agree), with per-item justification so the next release re-checks instead of
re-guessing. The audit is part of the work; the file records what it finds.

## 7. Fastlane

New `ios/fastlane/`: `Appfile`, `Fastfile`, `Snapfile`, `Deliverfile`,
`metadata/{en-US,de-DE}/`, `screenshots/{en-US,de-DE}/`.

| Lane | Does |
|---|---|
| `beta` | archive + sign + upload to TestFlight |
| `screenshots` | run the UI-test target, capture en+de |
| `metadata` | upload text + screenshots only (`skip_binary_upload`) |
| `release` | binary + metadata, **`submit_for_review: false`** |

`release` deliberately stops before submission — a human presses the button.

Signing: App Store Connect API key (`.p8`) via `app_store_connect_api_key`, with
`xcodebuild -allowProvisioningUpdates`. Keeps `CODE_SIGN_STYLE = Automatic`, adds
no cert repo.

**First-submission fields** — App Store Connect blocks a first release without
them, so they are part of this work, not a surprise at the submit button:
`privacy_url` (§5 — the reason those pages exist), `app_review_information`
(demo credentials, §10), `primary_category`, `copyright`, content-rights
declaration. Most are settable in `Deliverfile`; the **age-rating questionnaire
is per-version and set by hand** in ASC.

Per-locale metadata: name, subtitle, description, keywords, release notes,
support/marketing URL.

## 8. Screenshot Automation

New UI-test target `VMflowScreenshots`, registered by hand in `project.pbxproj`
(§2).

**The seam.** All 11 ViewModels reach Supabase through
`SupabaseService.shared.client`. Rather than injecting protocols into each,
`SupabaseService` gets exactly one branch: when launch arguments contain
`-UITestFixtures`, it builds its client with a `URLSession` whose
`configuration.protocolClasses` starts with `FixtureURLProtocol`, and skips
`ServerStore` (dummy URL/key). Production behaviour untouched.

The seam is confirmed available: supabase-swift is pinned at **2.43.1**, which
exposes `SupabaseClientOptions.global.session`. (If that turns out wrong at
implementation time, the fallback is registering `FixtureURLProtocol` on
`URLSessionConfiguration.default` from the test-launched process — broader, needs
no SDK support.)

**`FixtureURLProtocol`** matches request path/method against JSON bundled in the
test target: the auth token endpoint, PostgREST reads, the edge functions the
screens call (`get-my-organization`, KPI RPCs), and Storage image bytes.
Realtime (`RealtimeService`) uses WebSockets, which `URLProtocol` cannot
intercept — under the fixture flag Realtime subscriptions are skipped. Static
screenshots need no live updates.

**Fixtures** are hand-authored, plausible demo data (fictional machines, products,
revenue) — not a dump of real customer data.

**Captured** (× `en`, `de`): Dashboard, machine list, machine detail, refill
wizard, warehouse. Device: iPhone 16 Pro Max (6.9") — the only size Apple still
requires, and iPad is out.

Determinism: fixed fixtures, no network, and absolute fixture dates far enough in
the past that relative copy (`timeAgo`) renders stably.

## 9. GitHub Actions

`.github/workflows/ios-release.yml`:

- `on: workflow_dispatch` with a `lane` choice input (`beta` | `screenshots` |
  `metadata` | `release`). No push or tag trigger — nothing reaches Apple without
  a deliberate click.
- `runs-on: macos-15`, Xcode selected explicitly (project declares 16.0).
- `actions/checkout` with **`fetch-depth: 0`** — the build number is
  `git rev-list --count HEAD`; a shallow clone yields `1` and ASC rejects a build
  number below the last upload.
- Secrets: `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`,
  `APP_STORE_CONNECT_KEY_P8` (base64). Secrets are unavailable to fork PRs and
  `workflow_dispatch` is collaborator-only, so the public repo is not a leak path.

The `screenshots` lane needs no secrets (fixtures, no network).

## 10. Review Access

Fixtures serve screenshots; they do **not** serve review. The reviewer runs the
real app against a real server.

- A demo company on `https://supabase.kerl-handel.de` with seeded machines,
  products and sales, and a demo user.
- **The reviewer will likely test account deletion** — that is the point of
  5.1.1(v). So the demo company must be *disposable and re-seedable*: a seed
  script the operator can re-run, not a hand-built fixture. Assume it will be
  destroyed and plan for re-creation before each submission.
- Credentials go in ASC review notes, never in the repo.
- The notes must explain the server picker: which server is preselected, that no
  action is needed. A reviewer landing on a server-selection screen with no
  context files a "cannot log in" rejection.
- `docs/ios/app-store-review-notes.md` holds the reusable text (no password).

## 11. Build Order

1. **Upload blockers** — icon alpha, privacy manifest, entitlements split
   (pbxproj-level), ATS/strings both targets, `TARGETED_DEVICE_FAMILY = 1`.
2. **Account deletion** — FK migration, edge function, Settings UI, strings.
3. **Legal pages** — 4 pages, i18n text, `publicRoutes`.
4. **Fastlane + Actions** — `beta` lane green → TestFlight reachable.
5. **Screenshots** — test target, seam, fixtures, `screenshots` lane.
6. **Metadata + docs** — en/de metadata, ASC first-submission fields, privacy
   answers, review notes, demo seed.

After step 4 TestFlight builds are possible; 5–6 complete the listing.

## 12. Verification

| Item | How |
|---|---|
| Icon | `sips -g hasAlpha AppIcon.png` → `no` |
| Privacy manifest | present in the built `.app` bundle; upload passes |
| Entitlements | inspect the **Release archive's embedded** entitlements: `aps-environment: production` **and** associated-domains present |
| Device family | Release archive `Info.plist` `UIDeviceFamily = [1]`, both targets |
| ATS | Debug build + server picker → real `http://` LAN server; if broken, §3.4 fallback |
| FK migration | `supabase migration up` clean; then: user with an API key + cash-book entry deletes successfully |
| `delete-account` | SQL/RPC test (memory `project_sql_test_harness`): non-admin deletes; admin with a second admin deletes without touching the company; sole admin + wrong name → 400; sole admin + correct name → company gone |
| Legal pages | `curl` each URL logged-out → 200, not a login redirect |
| Screenshots | `fastlane screenshots --clean` twice → identical bytes; 10 PNGs (5 × 2 languages) plus fastlane's `screenshots.html` |
| Pipeline | `beta` lane → build visible in TestFlight |
| Build number | CI-computed number exceeds the last uploaded |

Frontend `npx vitest run` stays green. Firmware and MQTT are untouched: the new
edge function is additive and unknown to existing clients, and the FK migration
only relaxes constraints (no column dropped or renamed) — nothing a field device
or older frontend depends on changes.
