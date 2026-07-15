# iOS App Store Release — Design

**Date:** 2026-07-15
**Status:** Approved (design), spec review round 3
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

**17 FKs** reference `auth.users(id)` or `companies(id)` with no `ON DELETE`
clause. A missing clause means `NO ACTION`, which blocks the parent delete
**regardless of nullability** — nullability only decides whether `SET NULL` is a
legal *fix*. All 17 raise a raw `23503` today.

Blocking **auth-user deletion** (11):

| FK | Source | Fix |
|---|---|---|
| `sales.owner_id` | `20260101000000:56` | SET NULL |
| `embeddeds.owner_id` | `20260101000000:37` | SET NULL |
| `paxcounter.owner_id` | `20260228000000:48` | SET NULL |
| `organization_members.invited_by` | `20260228000000:14` | SET NULL |
| `invitations.invited_by` | `20260228000000:33` | SET NULL |
| `device_provisioning.created_by` | `20260228130000:11` | SET NULL |
| `firmware_versions.uploaded_by` | `20260301800000:14` | SET NULL |
| `ota_updates.triggered_by` | `20260301800000:46` | SET NULL |
| `api_keys.created_by` **NOT NULL** | `20260303100000:5` | drop NOT NULL + SET NULL |
| `cash_books.created_by` **NOT NULL** | `20260407000000:29` | drop NOT NULL + SET NULL |
| `cash_book_entries.created_by` **NOT NULL** | `20260407000000:73` | drop NOT NULL + SET NULL |

`sales.owner_id` and `embeddeds.owner_id` are the fatal pair: an operator's
account is stamped on their own sales rows, so `deleteUser` fails for
essentially every real user. This breaks the **ordinary** deletion path, not just
the last-admin one.

Blocking **company deletion** (6):

| FK | Source | Fix |
|---|---|---|
| `users.company` | `20260101000000:24` | **SET NULL** (see below) |
| `embeddeds.company` | `20260101000000:42` | CASCADE |
| `vendingMachine.company` | `20260101000000:76` | CASCADE |
| `product_category.company` | `20260101000000:93` | CASCADE |
| `products.company` | `20260101000000:112` | CASCADE |
| `cash_book_entries.company_id` | `20260407000000:62` | CASCADE |

Correcting an earlier claim in this spec: it is **not** true that "every other
table cascades." Tables added from `20260303000000` onward cascade; the five
original `initial_schema` tables and `cash_book_entries` never did.

`users.company` is the one exception to CASCADE in that list. `public.users` is
the *profile* table (`20260101000000_initial_schema.sql:21-27`), not company-owned
data. Cascading it would delete the profile row of **every other member** of the
deleted company — a viewer who merely belonged there would keep their
`auth.users` row but lose their profile, and `on_auth_user_created` only fires at
signup, so it is never recreated: a live account with no profile. Same reasoning
as the `*_by` columns below — the person survives, the link is dropped.

`SET NULL` rather than `CASCADE` for the `*_by` / `owner_id` columns: attribution
is lost, the record survives. Cascading would destroy a company's sales history,
accounting rows and working API keys because one colleague left — wrong.

**Dropping `NOT NULL`** on the three `created_by` columns weakens an invariant
that inserting code may assume. Audit before writing: any RLS policy, trigger, or
`SECURITY DEFINER` RPC reading `created_by` (the cash-book RPCs and
`add_purchase_price`-style functions are the risk). A policy of the form
`created_by = auth.uid()` fails closed on NULL — acceptable. A `NOT NULL`-assuming
trigger is not.

**New migration** `20260715000000_account_deletion_fk_fixes.sql` — new file,
never edit the originals (memory `feedback_migration_immutability`).

**Do not drop constraints by guessed name.** `DROP CONSTRAINT IF EXISTS
<table>_<column>_fkey` assumes Postgres's inline-declaration naming; if any
deployed DB differs, `IF EXISTS` misses **silently**, the old blocking FK
survives, the new one is added under another name, and the migration reports
success while production still `23503`s. Because `update.sh` fires each migration
once by filename, that failure is latent — the exact class of bug
`feedback_migration_immutability` exists for. Instead, a `DO` block looks the
constraint up in `pg_constraint` by `(conrelid, confrelid, conkey)` and drops
whatever name it finds, then re-adds with the intended clause. That is both
idempotent and name-independent. (Evidence the convention *usually* holds:
`20260301400000_device_delete_fks.sql` drops by that exact pattern and works —
but it drops without `IF EXISTS`, so it would have failed loudly. Our version
must not fail quietly.)

Beware the phantom `20260606000000` when running `supabase migration up` locally
(memory `project_cash_book_phantom_migration`).

### 4.3 The company cascade cannot be a cascade

`sales` and `paxcounter` have **no company column** (verified:
`20260101000000_initial_schema.sql:53-64`, `20260228000000_multitenancy.sql:45-52`).
They reach a company only through `embedded_id` / `machine_id` — and both of those
FKs are deliberately `ON DELETE SET NULL` (`20260301400000_device_delete_fks.sql`,
`20260301200000_device_swap.sql:15`) so that history survives a device swap.

So deleting the `companies` row would cascade away `embeddeds` and
`vendingMachine`, and leave every `sales` and `paxcounter` row alive with **both**
FKs NULL: unreachable by RLS, invisible in every UI, undeletable through the app,
still holding the operator's revenue history. That is the opposite of what §4.1
promises, and a live GDPR Art. 17 exposure. The device-swap `SET NULL` must stay,
so the rows must be deleted **explicitly and first**.

This ordering must be atomic, which an edge function issuing sequential
PostgREST calls cannot guarantee. Therefore the migration also adds:

```sql
public.delete_company_and_data(p_company_id uuid) RETURNS void
  SECURITY DEFINER
  SET search_path = public, extensions   -- memory: feedback_supabase_security_definer_search_path
```

One transaction, in order: delete `sales`, `paxcounter` **and
`stock_decrement_log`** whose `embedded_id` belongs to the company's devices **or**
whose `machine_id` belongs to its machines; then delete the `companies` row and
let the (now fixed) FKs cascade the rest. Legacy rows with both FKs already NULL
cannot be attributed to a company and are out of scope.

`stock_decrement_log` (`20260404000000_fix_stock_decrement_reliability.sql:17-26`)
is the worst of the three: its `embedded_id` and `machine_id` are **bare `uuid`
columns with no `references` clause at all**. So a company delete neither blocks
on it nor cascades it — every row survives, holding per-sale pricing data, forever
unreachable. It is the only table in this shape; every other indirect-only table
(`machine_trays`, `ota_updates`, `mdb_log`, `machine_product_offerings`,
`push_subscriptions`, …) cascades correctly via a real FK.

Note the verification consequence: §12's `pg_constraint` sweep **cannot** see
`stock_decrement_log`, because there is no constraint to find. A catalog query
alone would report success while the rows survive. §12 therefore also asserts row
counts.

Unlike the `get_platform_*` RPCs, this function is **not** self-guarding — it is
called only by the edge function with the service role, after that function has
verified the caller. It must not be granted to `authenticated`; `REVOKE` from
`public` explicitly.

⚠️ **Flagged for the user, not decided here:** cash-book entries are accounting
records that German retention law (GoBD/HGB §257) generally requires kept for
years, while GDPR Art. 17(3)(b) exempts exactly such data from erasure. Deleting
a company's cash book on account deletion may conflict with that duty. This is a
legal question for your tax advisor, not an engineering one — it does not block
the iOS work, but the answer may later change what §4.3 deletes.

### 4.4 Edge function

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
3. If `role = 'admin'` **and** no other admin exists for that company → cascading
   path: require `confirm_company_name` to match `companies.name` exactly (else
   `400`); **collect** the company's `products.image_path` values (they become
   unreadable once the cascade runs); call `delete_company_and_data(company_id)`;
   and only **after it returns successfully**, remove those objects from the
   `product-images` bucket (keyed `{product_id}.{ext}` with no company FK, so
   nothing else reaps them).

   The order matters and is not cosmetic: removing the objects first means a
   failing RPC leaves a live, in-use company that has silently lost every product
   image — damage with no deletion. Reading paths first and deleting objects last
   is the only order where each failure point degrades safely.
4. Otherwise: no company-side work. The caller's `organization_members` row is
   removed by step 5's cascade (`organization_members.user_id → auth.users
   ON DELETE CASCADE`, `20260228000000_multitenancy.sql:12`) — no explicit delete
   needed.
5. `adminClient.auth.admin.deleteUser(userId)`.
6. App signs out, returns to login.

**Partial-failure boundary:** `deleteUser` goes through the GoTrue admin API and
**cannot** join a Postgres transaction with step 3. A failure between 3 and 5
leaves a company deleted and its user alive — an orphan admin with no company,
who by §4.1's rules can simply delete again (a user with no company row is always
deletable). So the sequence is retry-safe and fails toward the recoverable state.
Reversing 3 and 5 would strand the company undeletable.

**That property depends on §4.5's second delete affordance and is false without
it.** An org-less user is routed to `NoOrganizationView`, not `SettingsView` — so
without the fix in §4.5 the orphan admin cannot reach the button to retry, having
destroyed their company and kept an undeletable account. The retry path is not
theoretical safety; it must be reachable.

Storage cleanup is best-effort *once the RPC has succeeded*: an object-removal
failure is logged but does not abort, since a stale image after a completed
deletion is the lesser harm.

A user with no company row can always delete. Registration stays in the app.

Uses `SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY` — both already present in both
environments, so no `.env.example` / `setup.sh` / `update.sh` / Dockerfile
change. Needs `[functions.delete-account]` with `import_map` in `config.toml`
plus its own `deno.json` (both environments — memory
`project_supabase_cli_workdir_env_parse`).

### 4.5 UI — two entry points, not one

Destructive "Konto löschen / Delete account" row at the bottom of
`ios/VMflow/Views/Settings/SettingsView.swift`, below Sign Out. Confirmation
dialog names the consequence. For the cascading case: a second screen listing
what disappears (machines, sales, warehouse, devices) and a text field requiring
the company name. New `en`/`de` String Catalog entries, inserted surgically
(memory `reference_ios_xcstrings_editing`).

**`SettingsView` alone is not enough — this is a blocker, not a nicety.**
`RootView` (`ios/VMflow/VMflowApp.swift:38-56`) routes on three states, and
`organization == nil` lands on `NoOrganizationView`
(`VMflowApp.swift:75-98`), which offers only **Sign Out** and **Retry** and reads
*"Please create or join one using the web dashboard."* `AdaptiveRootView` — and
therefore `SettingsView` — is never rendered.

A user who registers in-app via `RegisterView` (the very fact that triggers
5.1.1(v), §3.6) is **org-less on first launch**. So the most natural reviewer
script — register a fresh account, then look for account deletion — dead-ends on
a screen with no delete affordance that points at a website. That is the same
rejection §4 exists to prevent, re-entering through a different door. It is also
the state an orphan admin lands in (§4.4).

So the same affordance must also live on `NoOrganizationView`. §4.4's contract
already handles this case correctly (no company row → always deletable); only the
UI cannot currently invoke it.

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
2. **Account deletion** — FK migration (17 FKs + `delete_company_and_data`),
   `created_by` NOT NULL audit, edge function, Settings UI, strings.
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
| FK migration | `supabase migration up` clean; then assert **zero** FKs to `auth.users`/`companies` remain with `confdeltype = 'a'` (NO ACTION) — a query, not a spot-check, so a missed FK cannot hide |
| Realistic user delete | a user who **owns sales + paxcounter rows, a registered device, an API key and a cash-book entry** (i.e. a real admin) deletes successfully. The weaker "API key + cash-book entry" case would pass while `sales.owner_id` still blocks everyone |
| Cascade completeness | after deleting a company: **zero** `sales` / `paxcounter` / `stock_decrement_log` rows remain that belonged to it; company's product-image objects gone from the bucket. Row counts, **not** the catalog query — `stock_decrement_log` has no FK for `confdeltype` to see |
| Profile survival | delete a company with a second (viewer) member → the viewer's `public.users` row still exists with `company IS NULL`, and they can still log in |
| Deletion reachable | register a **fresh** account in-app, do not join an org → the delete affordance is present on `NoOrganizationView` and completes |
| `delete-account` | SQL/RPC test (memory `project_sql_test_harness`): non-admin deletes; admin with a second admin deletes without touching the company; sole admin + wrong name → 400; sole admin + correct name → company gone |
| Device-swap regression | deleting a *single device* still leaves its sales rows intact with `machine_id` set — the `SET NULL` behaviour §4.3 preserves must not be broken by the FK migration |
| Legal pages | `curl` each URL logged-out → 200, not a login redirect |
| Screenshots | `fastlane screenshots --clean` twice → identical bytes; 10 PNGs (5 × 2 languages) plus fastlane's `screenshots.html` |
| Pipeline | `beta` lane → build visible in TestFlight |
| Build number | CI-computed number exceeds the last uploaded |

Frontend `npx vitest run` stays green. Firmware and MQTT are untouched: the new
edge function is additive and unknown to existing clients, and the FK migration
only relaxes constraints (no column dropped or renamed) — nothing a field device
or older frontend depends on changes.
