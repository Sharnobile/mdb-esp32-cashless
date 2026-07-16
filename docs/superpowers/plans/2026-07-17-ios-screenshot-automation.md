# iOS Screenshot Automation Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `bundle exec fastlane screenshots` produces the App Store screenshot set — 5 screens × en/de on iPhone 16 Pro Max — deterministically, offline, from fixtures.

**Architecture:** One branch in `SupabaseService`: launch argument `-UITestFixtures` swaps the `SupabaseClient`'s `URLSession` for one whose `protocolClasses` is `[FixtureURLProtocol]` (seam verified: `SupabaseClientOptions.GlobalOptions.session`, supabase-swift 2.43.1 `Types.swift:100-112`). The protocol answers auth, PostgREST, edge functions and Storage from bundled JSON/PNG fixtures. A new UI-test target `VMflowScreenshots` drives five screens through fastlane snapshot. No ViewModel changes.

**Tech Stack:** XCUITest, fastlane snapshot, URLProtocol.

**Spec:** `docs/superpowers/specs/2026-07-15-ios-app-store-release-design.md` §8

**Phase 5 of 6.**

---

## Design decisions

1. **Target creation via the `xcodeproj` Ruby gem, not hand-edited hex IDs.**
   The house rule "register new Swift files by hand in 4 places" is calibrated
   for files; a whole new *target* is ~10 interlocking pbxproj sections, and
   hand-crafting those is where silent corruption lives. fastlane already
   bundles the `xcodeproj` gem — a one-off Ruby script
   (`ios/scripts/add_screenshots_target.rb`, committed for reproducibility)
   creates the UI-test target, wires `TEST_TARGET_ID`, adds sources and the
   fixtures folder as resources. The result is reviewed the same way any pbxproj
   change is: `git diff`, then builds. **XcodeGen stays forbidden** — this
   script *adds* to the existing pbxproj rather than regenerating it.
2. **Auto-login under the flag, not UI typing.** With `-UITestFixtures`, the
   app calls `auth.login(email: "demo@vmflow.app", password: "fixtures")` at
   startup; the stubbed `/auth/v1/token` answers with a long-lived session.
   Deterministic, and skips flaky text entry. `ServerStore` is bypassed with a
   dummy `https://fixtures.local` base URL (never contacted — the protocol
   intercepts everything).
3. **Fixture routing: exact table first, then safe fallbacks.**
   `FixtureURLProtocol` resolves, in order: (1) exact `"METHOD path?query-prefix"`
   entries from a routing table; (2) any `/rest/v1/<table>` GET → the fixture
   file `<table>.json` if bundled; (3) any other `/rest/v1/*` GET → `[]`
   (empty result, HTTP 200) so an unanticipated query renders an empty state
   instead of a spinner; (4) `/storage/v1/object/public/product-images/*` →
   one bundled placeholder PNG per product id, falling back to a generic one;
   (5) anything else → 404 **and** `os_log` the miss — misses are the debugging
   surface while building fixtures.
4. **Realtime is inert by construction.** WebSockets bypass URLProtocol, but the
   realtime handshake simply fails against `fixtures.local` and the app's
   subscriptions degrade to no-ops. Verify during implementation that failure is
   silent (no error UI); if any screen surfaces it, gate that subscription on
   the flag.
5. **Determinism.** Fixture dates are absolute and old enough that `timeAgo`
   renders stable strings; sales timestamps spread over a fixed 30-day window
   ending at a fixed anchor date. The snapshot run sets a fixed status bar via
   snapshot's `override_status_bar`.
6. **Fixture data is fictional** — "Automaten am Hauptbahnhof"-style names,
   plausible revenue, no real customer data.

## Review corrections (round 1)

1. **`URLProtocol.registerClass` in addition to the session injection.**
   `ProductImage.swift:58` loads images via `URLSession.shared` (deliberately,
   AsyncImage bug) and fails silently — without global registration every
   screenshot shows gray placeholder boxes while all checks pass. Registered
   classes are consulted by `URLSession.shared`; the storage routing then fires.
2. **Fixture timestamps are now-relative, not absolute.** `DashboardViewModel`
   buckets sales client-side against `Date()` (lines 121-196); absolute past
   dates render €0.00 KPIs. `FixtureURLProtocol` synthesizes `created_at` at
   request time with fixed offsets (09:12 today, −1d, … −29d).
3. **Determinism criterion restated:** two consecutive same-session runs →
   byte-identical, with `UIView.setAnimationsEnabled(false)` under the flag and
   anchor-element waits. Cross-day regeneration diffs (calendar axis labels) and
   is simply re-committed.
4. **Release exclusion mechanism:** `EXCLUDED_SOURCE_FILE_NAMES = $(inherited)
   Fixtures*` in `Release.xcconfig` (resource membership has no per-config
   toggle), verified by asserting the exported Release bundle contains **no
   `Fixtures/` directory** — the strings-grep alone can't see resources.
5. **xcodeproj script additions:** override `GENERATE_INFOPLIST_FILE = YES` +
   `INFOPLIST_FILE = ""` on the new target (it inherits the app's), add
   `target.add_dependency(app_target)`, set TargetAttributes
   `TestTargetID = 896CD9A61911762E88A22E98`, and edit the scheme's TestAction
   in the same script via `Xcodeproj::XCScheme` (currently empty testables).
6. **`https://fixtures.invalid`, not `.local`** — `.local` triggers multi-second
   mDNS timeouts on the paths that do try to resolve (realtime websocket).
   RFC 2606 `.invalid` fails instantly.
7. **Locale-independent navigation:** tab labels are localized; the de-DE run
   cannot find buttons by English label. Use `accessibilityIdentifier`s on the
   tab items (or `boundBy:` indices). Refill's first step is **Review** (not
   packing) and needs no saved-tour state — the resume alert cannot fire.
8. **RPC fallback:** `POST /rest/v1/rpc/*` → `[]`/`0` fallback (RPCs are POSTs;
   the GET-only fallback would 404 them — e.g. `get_new_deals_count`, KPI RPCs).

Verified enablers (no action): all SDK sub-clients (Auth/PostgREST/Functions/
Storage) inherit `options.global.session` in 2.43.1; snapshot uses the scheme's
Test action = **Debug**; `-AppleLanguages en-US/de-DE` resolves to catalog
`en`/`de`; `en-US`/`de-DE` are exactly deliver's locale folder names and
`./fastlane/screenshots` is deliver's default path — phase 6 aligns; simulator
runs prompt no permission dialogs (notification code only checks status).

## Tasks

### Task 1: The seam + fixture engine (app target)

**Files:**
- Modify: `ios/VMflow/Services/SupabaseService.swift` (the one branch)
- Create: `ios/VMflow/Services/FixtureURLProtocol.swift`
- Modify: `ios/VMflow/VMflowApp.swift` (auto-login under flag)
- Modify: `ios/VMflow.xcodeproj/project.pbxproj` (register the new file — by
  hand, 4 places, per house rule)

- [ ] `SupabaseService.init`: if
  `ProcessInfo.processInfo.arguments.contains("-UITestFixtures")`, build the
  client with `SupabaseClientOptions(global: .init(session: fixtureSession))`
  where `fixtureSession` uses an ephemeral configuration with
  `protocolClasses = [FixtureURLProtocol.self]`, base URL
  `https://fixtures.local`, anon key `"fixtures"`. Production path untouched.
- [ ] `FixtureURLProtocol` per design decision 3. Fixtures load from the **app
  bundle** (`Bundle.main`) — they ship only in this debug path but live in a
  `Fixtures/` folder added to the app target's Resources **in Debug builds**;
  guard the whole file with `#if DEBUG` so no fixture engine reaches the App
  Store binary.
- [ ] Auto-login: in `VMflowApp` (or AuthService init), under the flag, kick
  `login(...)` once at startup.
- [ ] Build + run in simulator with the launch argument set manually in a quick
  `xcrun simctl launch` — expect the login screen to skip straight to the
  dashboard rendering fixture data (however incomplete at this point).

### Task 2: Fixtures

**Files:**
- Create: `ios/VMflow/Fixtures/*.json` + `product-placeholder.png` (+ per-product PNGs as needed)

- [ ] Start from the misses log: run each of the five screens, capture the 404'd
  paths from `os_log`, add fixtures until the screen is visually complete.
  Screens and their principal data: Dashboard (sales 30d, machines+embeddeds,
  activity feed), machine list (vendingMachine⋈embeddeds + stats), machine
  detail (sales history, machine_trays, products), refill wizard step 1
  (warehouses, trays, products, stock batches), warehouse (stock batches,
  transactions).
- [ ] Auth fixtures: `/auth/v1/token` (grant_type=password) and `/auth/v1/user`;
  `get-my-organization` edge function response.
- [ ] Product images: 3–5 distinct placeholder PNGs (generated solid-color +
  emoji-style via PIL is fine) so lists look real, not clip-art.
- [ ] German plausibility: fixture strings that render user-visibly (machine
  names, product names) should read naturally in BOTH store locales — use
  brand-like names (e.g. "Snackomat West", "Cola Zero 0,5 l") that need no
  translation.

### Task 3: UI-test target + snapshot

**Files:**
- Create: `ios/scripts/add_screenshots_target.rb` (xcodeproj-gem script)
- Create: `ios/VMflowScreenshots/VMflowScreenshotsTests.swift`
- Create: `ios/VMflowScreenshots/SnapshotHelper.swift` (fastlane's, vendored by `fastlane snapshot init` or copied from the gem)
- Modify: `ios/VMflow.xcodeproj/project.pbxproj` (via the script)
- Modify: `ios/VMflow.xcodeproj/xcshareddata/xcschemes/VMflow.xcscheme` (add the test target to the Test action)
- Create: `ios/fastlane/Snapfile`

- [ ] The Ruby script: `Xcodeproj::Project.open`, `new_target(:ui_test_bundle,
  "VMflowScreenshots", :ios, "17.0")`, set `TEST_TARGET_NAME = VMflow`,
  `PRODUCT_BUNDLE_IDENTIFIER = de.kerl-handel.app.screenshots`,
  `DEVELOPMENT_TEAM`, add both Swift files, save. Run once, inspect
  `git diff ios/VMflow.xcodeproj/project.pbxproj`, build.
- [ ] The test: `setupSnapshot(app)`, launch with `-UITestFixtures`, then per
  screen: navigate (tab bar / list taps), wait for a **fixture-data anchor
  element** (not a sleep), `snapshot("01Dashboard")` … `snapshot("05Warehouse")`.
- [ ] `ios/fastlane/Snapfile`: `devices(["iPhone 16 Pro Max"])`,
  `languages(["en-US", "de-DE"])`, `scheme("VMflow")`, `output_directory
  ("./fastlane/screenshots")`, `override_status_bar(true)`, `clear_previous_screenshots(true)`.
- [ ] Replace the `screenshots` lane stub with `capture_screenshots` (+ keep the
  lane runnable locally without ASC secrets — snapshot needs none).

### Task 4: Verify

- [ ] `bundle exec fastlane screenshots` → 10 PNGs
  (5 × en-US, 5 × de-DE) under `ios/fastlane/screenshots/`.
- [ ] Run twice → byte-identical PNGs (determinism; status bar overridden,
  fixture dates fixed). If pixels drift, find the nondeterminism — do not accept
  "close enough".
- [ ] Every screenshot shows fixture data (no empty states, no spinners, no
  error banners) — eyeball each of the 10.
- [ ] `git status`: screenshots are build artifacts → add
  `fastlane/screenshots/` to `ios/.gitignore`? **No — deliberately commit them**:
  they are the store assets phase 6 uploads, and reviewing them in a PR is the
  point. Decision: commit.
- [ ] Regular build still green; App Store export still clean (`#if DEBUG`
  keeps the fixture engine out of Release — verify by grepping the exported
  binary's strings for `fixtures.local`: must be absent).

## Done when

- 10 deterministic, visually complete PNGs from one `fastlane screenshots` run
- No fixture code in a Release binary (strings check)
- Normal app behaviour untouched (build + login against the real local stack still works)
- Everything committed, including the target-creation script
