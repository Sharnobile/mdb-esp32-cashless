# iOS Release Pipeline Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A manually triggered GitHub Actions pipeline that builds, signs and uploads VMflow to TestFlight / App Store Connect via fastlane.

**Architecture:** fastlane under `ios/fastlane/` (pinned via `ios/Gemfile`) with four lanes; one workflow `.github/workflows/ios-release.yml` with `workflow_dispatch` + a lane choice. Signing is App Store Connect API key + Xcode cloud signing (`-allowProvisioningUpdates`) — no cert repo, no keychain juggling beyond `setup_ci`.

**Tech Stack:** fastlane (installed locally at `/opt/homebrew/bin/fastlane`), GitHub Actions `macos-15`, Xcode 16.

**Spec:** `docs/superpowers/specs/2026-07-15-ios-app-store-release-design.md` §7, §9

**Phase 4 of 6.** The `screenshots` lane body lands in phase 5 (it needs the UI-test target); this phase creates the lane as a clearly-labeled stub so the workflow's lane choice is stable from day one. Store metadata content lands in phase 6; the `metadata` lane is functional as soon as those files exist.

---

## Decisions locked in this phase

1. **Build-number race: document, don't re-engineer.** The two prebuild scripts
   each run `git rev-list --count HEAD` (spec §9). In CI nothing commits
   mid-build, so app and extension always agree; locally they can diverge (seen
   live: 1647 vs 1648). Decision: **uploads happen only from CI**; local archives
   are for debugging. Recorded in the Fastfile header comment. Touching the
   pbxproj script bodies for a local-only cosmetic risk is not worth it.
2. **fastlane via Bundler.** `ios/Gemfile` pins the version; CI runs
   `bundle exec fastlane`. Reproducible, and `ruby/setup-ruby` caches gems.
3. **API key via env, file written at runtime.** The `.p8` arrives base64 in
   `APP_STORE_CONNECT_KEY_P8`; the Fastfile decodes it to a temp file and hands
   it to both fastlane (`app_store_connect_api_key`) and xcodebuild
   (`-authenticationKeyPath …`) — cloud signing needs it on the xcodebuild side
   too, or `-allowProvisioningUpdates` has nothing to authenticate with.

## Tasks

### Task 1: Gemfile + fastlane skeleton

**Files:**
- Create: `ios/Gemfile`
- Create: `ios/fastlane/Appfile`
- Create: `ios/fastlane/Fastfile`
- Create: `ios/.gitignore` (fastlane build artifacts)

- [ ] `ios/Gemfile`:

```ruby
source "https://rubygems.org"

gem "fastlane", "~> 2.228"
```

Run `cd ios && bundle install` and commit the generated `Gemfile.lock` too —
CI must resolve the exact same versions.

- [ ] `ios/fastlane/Appfile`:

```ruby
app_identifier("de.kerl-handel.app")
team_id("4JT3V7XVXM")
```

- [ ] `ios/fastlane/Fastfile` — four lanes. Key requirements:

  - A private helper `asc_api_key` that fails loudly if any of the three env
    vars (`APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`,
    `APP_STORE_CONNECT_KEY_P8`) is missing, decodes the base64 `.p8` to
    a temp file, and returns the `app_store_connect_api_key` object.
  - `beta`: `setup_ci` (temp keychain on CI) → API key → `build_app` with
    `scheme: "VMflow"`, `export_method: "app-store"`, and `xcargs` carrying
    `-allowProvisioningUpdates -authenticationKeyPath <file>
    -authenticationKeyID <id> -authenticationKeyIssuerID <issuer>` →
    `upload_to_testflight(skip_waiting_for_build_processing: true)`.
  - `release`: same build → `upload_to_app_store` with
    `submit_for_review: false`, `automatic_release: false`,
    `precheck_include_in_app_purchases: false` (no IAP; precheck otherwise
    needs an extra API scope). Uploads binary + whatever metadata/screenshots
    exist.
  - `metadata`: `upload_to_app_store` with `skip_binary_upload: true`,
    `skip_screenshots: false`, `submit_for_review: false` — text/screens only.
  - `screenshots`: stub — `UI.user_error!` with a message naming phase 5, so a
    premature dispatch fails loudly instead of silently doing nothing.
  - Header comment: the build-number/CI decision from above.

- [ ] `ios/.gitignore`:

```
*.ipa
*.dSYM.zip
fastlane/report.xml
fastlane/README.md
build/
```

- [ ] Verify locally: `cd ios && bundle exec fastlane lanes` lists all four
  lanes without syntax errors. (`fastlane lanes` parses the Fastfile — a real
  syntax check, not a guess.)

### Task 2: GitHub Actions workflow

**Files:**
- Create: `.github/workflows/ios-release.yml`

- [ ] Shape (matching the repo's existing workflow style — `build-firmware.yml`):

```yaml
name: iOS Release

on:
  workflow_dispatch:
    inputs:
      lane:
        description: "fastlane lane"
        required: true
        type: choice
        options: [beta, metadata, release, screenshots]
        default: beta

jobs:
  fastlane:
    runs-on: macos-15
    defaults:
      run:
        working-directory: ios
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0   # build number = git rev-list --count HEAD; a shallow
                           # clone yields 1 and ASC rejects it

      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: "3.3"
          bundler-cache: true
          working-directory: ios

      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_16.4.app

      - name: Run fastlane lane
        env:
          APP_STORE_CONNECT_KEY_ID: ${{ secrets.APP_STORE_CONNECT_KEY_ID }}
          APP_STORE_CONNECT_ISSUER_ID: ${{ secrets.APP_STORE_CONNECT_ISSUER_ID }}
          APP_STORE_CONNECT_KEY_P8: ${{ secrets.APP_STORE_CONNECT_KEY_P8 }}
        run: bundle exec fastlane ${{ github.event.inputs.lane }}

      - name: Upload build log on failure
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: fastlane-logs
          path: |
            ios/fastlane/report.xml
            ~/Library/Logs/gym
          if-no-files-found: ignore
```

- [ ] **Verify the Xcode path against the current runner image before
  committing** — `macos-15`'s installed Xcode versions change; check
  https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md
  and pin an existing version. A wrong path fails in seconds with a clear error,
  but checking first is cheaper.
- [ ] Lint: `actionlint` if installed, else `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ios-release.yml'))"`.

### Task 3: Local verification of the signing path (as far as possible without secrets)

The pipeline cannot fully run until the user creates the ASC API key and the
GitHub secrets. What CAN be proven now, on this Mac (Xcode is signed into the
team — `DEVELOPMENT_TEAM` builds work):

- [ ] `cd ios && xcodebuild -project VMflow.xcodeproj -scheme VMflow \
  -destination 'generic/platform=iOS' archive \
  -archivePath /tmp/vmflow-test.xcarchive -allowProvisioningUpdates`
  — a real Release archive with automatic signing.
  - **Success** → inspect the archive:
    `codesign -d --entitlements - /tmp/vmflow-test.xcarchive/Products/Applications/VMflow.app`
    must show `aps-environment: production` **and** the associated-domains value
    (this closes phase 1's deferred archive-level check, spec §12).
  - **Provisioning failure naming Associated Domains / capabilities** → exactly
    the App-ID gap the spec predicts (§3.3). STOP and tell the user which
    capability to enable in the developer portal; do not work around it.
- [ ] Clean up `/tmp/vmflow-test.xcarchive` afterwards.

### Task 4: Commit + docs

- [ ] Commit paths only: `ios/Gemfile`, `ios/Gemfile.lock`, `ios/fastlane/`,
  `ios/.gitignore`, `.github/workflows/ios-release.yml`.
- [ ] Report to the user exactly which three secrets to create in
  GitHub → Settings → Secrets and variables → Actions, and how to base64 the
  `.p8` (`base64 -i AuthKey_XXXX.p8 | pbcopy`).

## Done when

- `bundle exec fastlane lanes` lists beta / metadata / release / screenshots
- Workflow YAML parses; Xcode path verified against the runner image
- Local archive succeeds with automatic signing AND its embedded entitlements
  show `aps-environment: production` + associated-domains — or the exact missing
  App-ID capability is reported to the user
- Everything committed; the user has the secrets checklist

## Not in this phase

TestFlight upload proof (needs the user's secrets — first real dispatch does it),
screenshots lane body (phase 5), metadata content (phase 6).
