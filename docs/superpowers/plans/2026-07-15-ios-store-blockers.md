# iOS Store Blockers Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `ios/VMflow` uploadable to App Store Connect — today the archive fails validation before any human sees it.

**Architecture:** Five independent, mechanical fixes to build settings, plists and assets. No Swift logic changes, no backend, no new dependencies. Each task is verifiable by a command that reads back what the build system actually resolved, not what the file says.

**Tech Stack:** Xcode 16 / xcodebuild, `sips`, Python PIL (installed, 12.1.1), plutil.

**Spec:** `docs/superpowers/specs/2026-07-15-ios-app-store-release-design.md` §3

**Phase 1 of 6.** Later phases (account deletion, legal pages, fastlane/CI, screenshots, metadata) get their own plans. After this plan the app archives cleanly; it is not yet submittable.

---

## Ground rules for this plan

1. **Never run `xcodegen`.** `ios/project.yml` has diverged from the committed
   `project.pbxproj`, which is the source of truth. Regenerating drops files.
   Edit `project.pbxproj` by hand. (Spec §2; memory `project_ios_xcode_file_registration`.)
2. **`ios/VMflow/Resources/Info.plist` and `ios/NotificationService/Info.plist`
   are already dirty in the working tree** — the `CFBundleVersion` prebuild
   script rewrites them on every build. Those two lines are noise. When
   committing, add files explicitly by path; never `git add -A`.
3. **Another session may be committing to this branch.** Use
   `git add <path> && git commit -m … -- <path>`. Never amend/reset/rebase a
   commit you did not create this turn. (Memory `feedback_concurrent_branch_commits`.)
4. Line numbers below were read on 2026-07-15. **Re-grep before editing** — an
   earlier task in this plan shifts them.

Baseline build command used throughout:

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/ios
xcodebuild -project VMflow.xcodeproj -scheme VMflow \
  -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO
```

---

## Chunk 1: Assets and build settings

### Task 1: Flatten the app icon's alpha channel

Apple rejects transparent 1024×1024 icons at upload (ITMS-90717).

**This change is pixel-identical.** The alpha channel is fully opaque
(`getextrema()` on the A channel returns `(255, 255)`), so RGBA→RGB drops a
channel that carries no information. No background colour needs choosing and the
artwork cannot shift.

**Files:**
- Modify: `ios/VMflow/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png`

- [ ] **Step 1: Confirm the failing state and that the drop is lossless**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/ios/VMflow/Resources/Assets.xcassets/AppIcon.appiconset
sips -g hasAlpha AppIcon.png
python3 -c "
from PIL import Image
a = Image.open('AppIcon.png').getchannel('A')
print('alpha extrema:', a.getextrema())
"
```

Expected: `hasAlpha: yes`, and `alpha extrema: (255, 255)`.

**If the extrema are not `(255, 255)`, stop.** The icon has real transparency and
flattening would change it; that needs a design decision, not this plan.

- [ ] **Step 2: Record a checksum of the visible pixels**

```bash
python3 -c "
from PIL import Image
im = Image.open('AppIcon.png').convert('RGB')
print('rgb bytes sha:', __import__('hashlib').sha256(im.tobytes()).hexdigest())
"
```

Note the value — Step 4 asserts it is unchanged.

- [ ] **Step 3: Drop the alpha channel**

```bash
python3 -c "
from PIL import Image
im = Image.open('AppIcon.png')
assert im.mode == 'RGBA', im.mode
im.convert('RGB').save('AppIcon.png', 'PNG', optimize=True)
print('done')
"
```

- [ ] **Step 4: Verify — no alpha, identical pixels**

```bash
sips -g hasAlpha -g pixelWidth -g pixelHeight AppIcon.png
python3 -c "
from PIL import Image
im = Image.open('AppIcon.png')
print('mode:', im.mode)
print('rgb bytes sha:', __import__('hashlib').sha256(im.convert('RGB').tobytes()).hexdigest())
"
```

Expected: `hasAlpha: no`, `pixelWidth: 1024`, `pixelHeight: 1024`, `mode: RGB`,
and the **same sha as Step 2**. A differing sha means the pixels moved — revert
and investigate.

- [ ] **Step 5: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git add ios/VMflow/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
git commit -m "fix(ios): drop alpha channel from app icon (ITMS-90717)

The channel was fully opaque (alpha extrema 255,255), so RGBA->RGB is
pixel-identical. App Store Connect rejects any large icon carrying an alpha
channel regardless of its contents." \
  -- ios/VMflow/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
```

---

### Task 2: Restrict to iPhone

`TARGETED_DEVICE_FAMILY = "1,2"` makes the app universal, which obliges 13" iPad
screenshots. Decided: iPhone-only (spec §3.5).

**Files:**
- Modify: `ios/VMflow.xcodeproj/project.pbxproj` (4 occurrences)

- [ ] **Step 1: Confirm the current state**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/ios
grep -n 'TARGETED_DEVICE_FAMILY' VMflow.xcodeproj/project.pbxproj
```

Expected: 4 hits, all `= "1,2";` — at ~790 (NotificationService Release), ~936
(VMflow Debug), ~953 (VMflow Release), ~972 (NotificationService Debug).
All four are intended: both targets, both configurations.

- [ ] **Step 2: Change all four**

```bash
sed -i '' 's/TARGETED_DEVICE_FAMILY = "1,2";/TARGETED_DEVICE_FAMILY = "1";/g' \
  VMflow.xcodeproj/project.pbxproj
```

- [ ] **Step 3: Verify the build system resolves it, not just the file**

```bash
xcodebuild -project VMflow.xcodeproj -target VMflow -configuration Release \
  -showBuildSettings 2>/dev/null | grep TARGETED_DEVICE_FAMILY
xcodebuild -project VMflow.xcodeproj -target NotificationService -configuration Release \
  -showBuildSettings 2>/dev/null | grep TARGETED_DEVICE_FAMILY
```

Expected: `TARGETED_DEVICE_FAMILY = 1` for **both** targets. Reading the file back
is not enough — this asserts nothing else overrides it.

- [ ] **Step 4: Build**

Run the baseline build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git add ios/VMflow.xcodeproj/project.pbxproj
git commit -m "chore(ios): target iPhone only (TARGETED_DEVICE_FAMILY=1)

Universal builds oblige 13-inch iPad screenshots in App Store Connect. The app
is designed for one-handed field use." \
  -- ios/VMflow.xcodeproj/project.pbxproj
```

---

### Task 3: Production APNs entitlement for Release

Release builds must carry `aps-environment: production`. The existing file
hardcodes `development` for both configurations.

**The mechanism is the trap.** `CODE_SIGN_ENTITLEMENTS` is set at *target* level
in `project.pbxproj`, and target-level settings **override xcconfig**. Setting it
in `Configurations/Release.xcconfig` would be silently ignored and ship
`development` to the Store — the exact rejection this task prevents. Set it in
`project.pbxproj`.

**Files:**
- Create: `ios/VMflow/Resources/VMflow.Release.entitlements`
- Modify: `ios/VMflow.xcodeproj/project.pbxproj` (the VMflow **Release** config block only)

- [ ] **Step 1: Read the current entitlements**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/ios
cat VMflow/Resources/VMflow.entitlements
```

Expected: `aps-environment = development` **and**
`com.apple.developer.associated-domains = [webcredentials:supabase.kerl-handel.de]`.

Both keys must survive. Dropping associated-domains silently kills password
autofill in Release.

- [ ] **Step 2: Create the Release entitlements**

Create `ios/VMflow/Resources/VMflow.Release.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>aps-environment</key>
	<string>production</string>
	<key>com.apple.developer.associated-domains</key>
	<array>
		<string>webcredentials:supabase.kerl-handel.de</string>
	</array>
</dict>
</plist>
```

- [ ] **Step 3: Validate it parses**

```bash
plutil -lint VMflow/Resources/VMflow.Release.entitlements
```

Expected: `OK`.

- [ ] **Step 4: Point the VMflow Release config at it**

Find the VMflow **Release** build-config block — the one whose `name = Release;`
and which contains `INFOPLIST_FILE = VMflow/Resources/Info.plist;` (id
`721C31EF76FFEFD13903BF0D`, ~line 943). Do **not** touch the Debug block
(`47D683708BFD2B7EC2F3258E`) or either NotificationService block (their
`CODE_SIGN_ENTITLEMENTS` is `""`, correct — the extension has no entitlements).

```bash
grep -n -A3 '721C31EF76FFEFD13903BF0D /\* Release \*/' VMflow.xcodeproj/project.pbxproj
```

In that block only, change:

```
				CODE_SIGN_ENTITLEMENTS = VMflow/Resources/VMflow.entitlements;
```

to:

```
				CODE_SIGN_ENTITLEMENTS = VMflow/Resources/VMflow.Release.entitlements;
```

- [ ] **Step 5: Register the file in the Resources group**

The entitlements files live in the `Resources` group (`path = Resources;`, ~line
521). Add a `PBXFileReference` and a child entry next to the existing
`45AE89831021CC12416B0F89 /* VMflow.entitlements */`.

Entitlements are **not** a build-phase input — they are referenced by path via
the build setting. So add **only** the file reference and the group child. Do
**not** add a `PBXBuildFile` and do **not** touch the Resources build phase;
copying an entitlements plist into the bundle would be wrong.

In the `PBXFileReference` section, alongside the existing entitlements reference:

```
		A1B2C3D4E5F60718293A4B5C /* VMflow.Release.entitlements */ = {isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = VMflow.Release.entitlements; sourceTree = "<group>"; };
```

In the `Resources` group's `children` list, after the existing entitlements line:

```
				A1B2C3D4E5F60718293A4B5C /* VMflow.Release.entitlements */,
```

The id `A1B2C3D4E5F60718293A4B5C` is an example — use any 24-char uppercase hex
that does not already appear in the file. Verify uniqueness:

```bash
grep -c 'A1B2C3D4E5F60718293A4B5C' VMflow.xcodeproj/project.pbxproj
```

Expected: `0` before you insert it, `2` after.

- [ ] **Step 6: Verify both configurations resolve correctly**

```bash
xcodebuild -project VMflow.xcodeproj -target VMflow -configuration Release \
  -showBuildSettings 2>/dev/null | grep CODE_SIGN_ENTITLEMENTS
xcodebuild -project VMflow.xcodeproj -target VMflow -configuration Debug \
  -showBuildSettings 2>/dev/null | grep CODE_SIGN_ENTITLEMENTS
```

Expected: Release → `VMflow/Resources/VMflow.Release.entitlements`;
Debug → `VMflow/Resources/VMflow.entitlements`. If Release still shows the Debug
file, the edit landed in the wrong block.

- [ ] **Step 7: Build**

Run the baseline build command. Expected: `** BUILD SUCCEEDED **`.

The `aps-environment: production` value can only be fully proven in a signed
archive (§12) — that check belongs to the CI phase, once signing exists. This
task proves the right *file* is selected per configuration, which is the part
that silently breaks.

- [ ] **Step 8: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git add ios/VMflow/Resources/VMflow.Release.entitlements ios/VMflow.xcodeproj/project.pbxproj
git commit -m "fix(ios): production APNs entitlement for Release builds

Release shipped aps-environment=development, which the App Store rejects. Set
per-configuration in project.pbxproj, not xcconfig: CODE_SIGN_ENTITLEMENTS is a
target-level setting and would override any xcconfig value silently.
associated-domains is preserved verbatim." \
  -- ios/VMflow/Resources/VMflow.Release.entitlements ios/VMflow.xcodeproj/project.pbxproj
```

---

## Chunk 2: Plists and privacy manifest

### Task 4: Remove the blanket ATS exception

`NSAllowsArbitraryLoads = true` in both targets is a review flag. The real need —
self-hosted servers over plain `http://` on a LAN — is served by
`NSAllowsLocalNetworking`, **if** it covers numeric private IPs. That is unproven
and this task proves it before committing to it.

**Files:**
- Modify: `ios/VMflow/Resources/Info.plist`
- Modify: `ios/NotificationService/Info.plist`

- [ ] **Step 1: Establish the baseline — a LAN server must work today**

You need a reachable `http://` Supabase on the LAN (Docker or CLI). Build and run
the **Debug** scheme on a simulator, use the in-app server picker
(`ServerSelectionSheet`) to add `http://<LAN-IP>:8000`, and log in.

Expected: login succeeds. If it fails *before* any change, fix the environment
first — otherwise Step 4 cannot distinguish a broken test from a broken setting.

- [ ] **Step 2: Remove the exception from both plists**

In `ios/VMflow/Resources/Info.plist`, inside `NSAppTransportSecurity`, delete:

```xml
		<key>NSAllowsArbitraryLoads</key>
		<true/>
```

Keep `NSAllowsLocalNetworking` and the `NSBonjourServices` array.

In `ios/NotificationService/Info.plist`, remove the whole
`NSAppTransportSecurity` dict — the extension downloads push attachments over
HTTPS only and needs no exception.

Also reword the usage string in the app plist, which currently advertises the app
as unfinished:

```xml
	<key>NSLocalNetworkUsageDescription</key>
	<string>VMflow needs local network access to connect to your self-hosted VMflow server.</string>
```

- [ ] **Step 3: Validate both plists**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/ios
plutil -lint VMflow/Resources/Info.plist NotificationService/Info.plist
plutil -p VMflow/Resources/Info.plist | grep -A6 NSAppTransportSecurity
```

Expected: both `OK`; the ATS dict shows `NSAllowsLocalNetworking => 1` and **no**
`NSAllowsArbitraryLoads`.

- [ ] **Step 4: Re-run the LAN test — this is the decision point**

Repeat Step 1 with the rebuilt Debug app (delete the app from the simulator first
so the new plist is picked up).

- **Login still works** → `NSAllowsLocalNetworking` covers numeric private IPs.
  Proceed to Step 5.
- **Login now fails** (ATS error in the console) → it does not. **Restore
  `NSAllowsArbitraryLoads = true` in the app plist only** (the extension's removal
  still stands), and record in
  `docs/ios/app-store-review-notes.md` that the exception exists because the app
  connects to user-operated self-hosted servers. Then proceed to Step 5 with that
  state. Do not guess — the console error is the evidence.

- [ ] **Step 5: Build**

Run the baseline build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

Note both plists also carry an unrelated dirty `CFBundleVersion` line from the
prebuild script; it rides along harmlessly. Add by path only.

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git add ios/VMflow/Resources/Info.plist ios/NotificationService/Info.plist
git commit -m "fix(ios): drop blanket ATS exception, reword local-network string

NSAllowsArbitraryLoads on both targets is a review flag. Local self-hosted
servers are served by NSAllowsLocalNetworking (verified against a real LAN
instance). The usage string described the app as connecting to a 'development
server', which reads as unfinished to a reviewer." \
  -- ios/VMflow/Resources/Info.plist ios/NotificationService/Info.plist
```

---

### Task 5: Add the privacy manifest

Since May 2024, a bundle using a required-reason API without declaring it gets
ITMS-91053 at upload. `UserDefaults` (category `NSPrivacyAccessedAPICategoryUserDefaults`,
reason code `CA92.1` — "access info from same app, per documentation") is used in
four app-target files.

**Files:**
- Create: `ios/VMflow/Resources/PrivacyInfo.xcprivacy`
- Modify: `ios/VMflow.xcodeproj/project.pbxproj`

- [ ] **Step 1: Re-audit the required-reason surface**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/ios
grep -rln "UserDefaults" VMflow NotificationService
grep -rlnE "creationDate|modificationDate|\.stat\(|systemUptime|activeProcessorCount|diskSpace" VMflow NotificationService
```

Expected: four app-target files use `UserDefaults`
(`VMflow/Services/ServerStore.swift`, `VMflow/Services/AuthService.swift`,
`VMflow/Services/NotificationService.swift`,
`VMflow/ViewModels/RefillWizardViewModel.swift`) and the second grep returns
nothing. If the second grep hits, the manifest needs more categories — check the
hit against Apple's required-reason list before adding anything.

**Do not confuse the two `NotificationService.swift` files.** The `UserDefaults`
user is `VMflow/Services/NotificationService.swift` (app target). The *extension*
file `NotificationService/NotificationService.swift` uses only
`FileManager.default.moveItem` / `removeItem`, which are **not** required-reason
APIs (`NSPrivacyAccessedAPICategoryFileTimestamp` covers `creationDate` /
`modificationDate` / the `stat` family — not move/remove). Expect the extension to
need **no** manifest. Confirm via the greps; do not add a spurious one.

- [ ] **Step 2: Create the manifest**

Create `ios/VMflow/Resources/PrivacyInfo.xcprivacy`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>NSPrivacyTracking</key>
	<false/>
	<key>NSPrivacyTrackingDomains</key>
	<array/>
	<key>NSPrivacyCollectedDataTypes</key>
	<array>
		<dict>
			<key>NSPrivacyCollectedDataType</key>
			<string>NSPrivacyCollectedDataTypeEmailAddress</string>
			<key>NSPrivacyCollectedDataTypeLinked</key>
			<true/>
			<key>NSPrivacyCollectedDataTypeTracking</key>
			<false/>
			<key>NSPrivacyCollectedDataTypePurposes</key>
			<array>
				<string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
			</array>
		</dict>
		<dict>
			<key>NSPrivacyCollectedDataType</key>
			<string>NSPrivacyCollectedDataTypeDeviceID</string>
			<key>NSPrivacyCollectedDataTypeLinked</key>
			<true/>
			<key>NSPrivacyCollectedDataTypeTracking</key>
			<false/>
			<key>NSPrivacyCollectedDataTypePurposes</key>
			<array>
				<string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
			</array>
		</dict>
	</array>
	<key>NSPrivacyAccessedAPITypes</key>
	<array>
		<dict>
			<key>NSPrivacyAccessedAPIType</key>
			<string>NSPrivacyAccessedAPICategoryUserDefaults</string>
			<key>NSPrivacyAccessedAPITypeReasons</key>
			<array>
				<string>CA92.1</string>
			</array>
		</dict>
	</array>
</dict>
</plist>
```

The two collected-data types are: the account e-mail (auth) and the APNs device
token (push). Both are app-functionality, neither is tracking. **This must agree
with the App Store Connect questionnaire** — §6 of the spec (a later phase)
produces that document from the same audit; if the audit there finds more, both
artefacts change together.

- [ ] **Step 3: Validate it parses**

```bash
plutil -lint VMflow/Resources/PrivacyInfo.xcprivacy
```

Expected: `OK`.

- [ ] **Step 4: Register it as a bundled resource**

Unlike the entitlements in Task 3, this file **must** be copied into the bundle —
so it needs all three: a file reference, a group child, and a Resources
build-phase entry.

`PBXFileReference` section:

```
		B2C3D4E5F60718293A4B5C6D /* PrivacyInfo.xcprivacy */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = PrivacyInfo.xcprivacy; sourceTree = "<group>"; };
```

`PBXBuildFile` section:

```
		C3D4E5F60718293A4B5C6D7E /* PrivacyInfo.xcprivacy in Resources */ = {isa = PBXBuildFile; fileRef = B2C3D4E5F60718293A4B5C6D /* PrivacyInfo.xcprivacy */; };
```

`Resources` group children (`path = Resources;`, ~line 521):

```
				B2C3D4E5F60718293A4B5C6D /* PrivacyInfo.xcprivacy */,
```

Resources build phase `674EE546BCC9074FF2AC9C96` `files` list (~line 613, next to
`Assets.xcassets` and `Localizable.xcstrings`):

```
				C3D4E5F60718293A4B5C6D7E /* PrivacyInfo.xcprivacy in Resources */,
```

Both ids are examples — use unique 24-char uppercase hex. There is only **one**
`PBXResourcesBuildPhase` in this project (the app target); the extension has none,
which is consistent with Step 1's finding that it needs no manifest.

- [ ] **Step 5: Build**

Run the baseline build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Verify it actually landed in the bundle**

A pbxproj edit that parses but misregisters the file fails **silently** — the
build succeeds and the manifest simply isn't there, which is exactly the state
that gets rejected at upload.

```bash
APP=$(xcodebuild -project VMflow.xcodeproj -scheme VMflow \
  -destination 'generic/platform=iOS Simulator' \
  -showBuildSettings CODE_SIGNING_ALLOWED=NO 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{d=$2} / FULL_PRODUCT_NAME/{n=$2} END{print d"/"n}')
echo "$APP"
ls -l "$APP/PrivacyInfo.xcprivacy"
plutil -p "$APP/PrivacyInfo.xcprivacy" | head -5
```

Expected: the file exists inside the built `.app` and prints as a valid plist.
If `ls` reports no such file, the Resources build-phase entry is wrong.

- [ ] **Step 7: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git add ios/VMflow/Resources/PrivacyInfo.xcprivacy ios/VMflow.xcodeproj/project.pbxproj
git commit -m "feat(ios): add privacy manifest (ITMS-91053)

The app uses UserDefaults (a required-reason API) in four files with no
PrivacyInfo.xcprivacy, which fails upload validation. Declares CA92.1 plus the
collected data types (account email, APNs token) — both app-functionality,
neither tracking. The NotificationService extension uses only moveItem/removeItem,
which are not required-reason APIs, so it needs no manifest." \
  -- ios/VMflow/Resources/PrivacyInfo.xcprivacy ios/VMflow.xcodeproj/project.pbxproj
```

---

### Task 6: Whole-phase verification

- [ ] **Step 1: Assert every §3 blocker is closed**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/ios

echo "--- icon (expect: hasAlpha: no)"
sips -g hasAlpha VMflow/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png

echo "--- device family (expect: 1 for both)"
for t in VMflow NotificationService; do
  xcodebuild -project VMflow.xcodeproj -target $t -configuration Release \
    -showBuildSettings 2>/dev/null | grep TARGETED_DEVICE_FAMILY
done

echo "--- entitlements (expect: Release=VMflow.Release.entitlements, Debug=VMflow.entitlements)"
for c in Release Debug; do
  xcodebuild -project VMflow.xcodeproj -target VMflow -configuration $c \
    -showBuildSettings 2>/dev/null | grep CODE_SIGN_ENTITLEMENTS
done

echo "--- ATS (expect: no NSAllowsArbitraryLoads, unless Task 4 Step 4 proved otherwise)"
plutil -p VMflow/Resources/Info.plist | grep -c NSAllowsArbitraryLoads || true
plutil -p NotificationService/Info.plist | grep -c NSAppTransportSecurity || true

echo "--- privacy manifest (expect: OK)"
plutil -lint VMflow/Resources/PrivacyInfo.xcprivacy
```

- [ ] **Step 2: Clean build from scratch**

```bash
xcodebuild -project VMflow.xcodeproj -scheme VMflow \
  -destination 'generic/platform=iOS Simulator' \
  clean build CODE_SIGNING_ALLOWED=NO
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Smoke-test on a simulator**

Run the Debug app, log in, open Settings. Nothing in this phase touches Swift, so
a regression here means a plist or resource change broke something — investigate
rather than proceed.

- [ ] **Step 4: Record the ATS outcome**

If Task 4 Step 4 forced `NSAllowsArbitraryLoads` to stay, note it now in the plan
file and in the spec's §3.4 "Open risk" paragraph, so the review-notes phase picks
it up. If it was removed cleanly, note that too — it closes the spec's only
open technical risk in §3.

---

## Done when

- `sips -g hasAlpha` on the icon → `no`
- Both targets resolve `TARGETED_DEVICE_FAMILY = 1` in Release
- VMflow Release resolves `VMflow.Release.entitlements`, Debug resolves `VMflow.entitlements`
- `PrivacyInfo.xcprivacy` is present **inside the built .app**
- ATS decision made **on evidence** from a real LAN server, and recorded
- Clean build succeeds; app still logs in

**Not done in this phase** (later plans): signed-archive verification of
`aps-environment: production`, App ID capabilities in the developer portal,
account deletion, legal pages, fastlane, screenshots, metadata.
