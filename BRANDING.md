# Branding

Single source of truth for the VMflow / mdb-esp32-cashless visual identity.

## The mark

Dark background, four vertical bars (two high / two low, the right pair tinted),
and an arrow line underneath.

| Element | Value | Meaning |
|---|---|---|
| Background | `#0F172A` (slate-900) | Engineering / hardware brand |
| Primary | `#FFFFFF` | Left half of the MDB bus signal |
| Accent | `#A3E635` (lime-400) | Right half + data-flow arrow — "live transmission" |
| Shape | Rounded square, `rx=10` on a 48-unit grid | Matches iOS/Android app-icon conventions |

The four bars represent the alternating wide/narrow pattern of an MDB bus
signal. The arrow below encodes directional data flow toward the cashless
peripheral.

## Source of truth

Four hand-maintained SVGs in `brand/`:

| File | Variant | Rounding | Used for |
|---|---|---|---|
| [`brand/logo-mark.svg`](brand/logo-mark.svg) | Prod | Rounded (`rx=10`) | Favicons, PWA `purpose=any`, Android legacy launchers |
| [`brand/logo-mark-bleed.svg`](brand/logo-mark-bleed.svg) | Prod | Full-bleed square | iOS AppIcon, PWA maskable, Android adaptive foreground |
| [`brand/logo-mark-dev.svg`](brand/logo-mark-dev.svg) | Dev | Rounded | Android debug-flavor legacy launchers |
| [`brand/logo-mark-dev-bleed.svg`](brand/logo-mark-dev-bleed.svg) | Dev | Full-bleed square | iOS AppIcon-Debug |

The dev variant adds an **orange diagonal band** in the top-left corner so the development build is visually distinct on the home screen / app switcher. No text — just colour and position — which keeps the generator output byte-deterministic (no font dependency) and also stays legible all the way down to the smallest launcher sizes.

**Do not hand-edit any of the generated PNGs.** Edit one of the SVGs above, then regenerate.

## Regenerating assets

```bash
cd brand
npm install       # first time only
npm run generate
```

The generator (`brand/generate.mjs`) uses [`@resvg/resvg-js`](https://www.npmjs.com/package/@resvg/resvg-js)
and writes to the following locations. Commit the result alongside the SVG
change in a single PR.

| Target | Files | Source | Notes |
|---|---|---|---|
| iOS AppIcon (Release) | `ios/VMflow/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png` (1024²) | bleed (prod) | iOS applies its own rounded mask |
| iOS AppIcon (Debug) | `ios/VMflow/Resources/Assets.xcassets/AppIcon-Debug.appiconset/AppIcon-Debug.png` (1024²) | **bleed (dev)** — with DEV ribbon | Selected by the Debug build configuration |
| Android legacy launcher — main | `Android/app/src/main/res/mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher.png` (48–192²) | rounded (prod) | Used on API < 26 for Release builds |
| Android legacy launcher — debug | `Android/app/src/debug/res/mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher.png` (48–192²) | **rounded (dev)** — with DEV ribbon | Auto-overrides main via Android source-set merging when building the `debug` variant |
| PWA icons | `management-frontend/public/icons/icon-{192,512}.png` | rounded (prod) | `purpose=any` |
| PWA maskable | `management-frontend/public/icons/icon-maskable-{192,512}.png` | bleed (prod) | `purpose=maskable`, Android masks it |
| Apple touch icon | `management-frontend/public/apple-touch-icon.png` (180²) | bleed (prod) | iOS masks it |
| Favicon PNG | `management-frontend/public/favicon-{16,32,48}.png` | rounded (prod) | Legacy browsers |
| Favicon SVG | `management-frontend/public/favicon.svg` | rounded (prod, copied verbatim) | Modern browsers |

Hand-maintained icon XMLs (update these manually if the mark design changes):

- `Android/app/src/main/res/drawable/ic_launcher_background.xml` — solid `#0F172A` background layer
- `Android/app/src/main/res/drawable/ic_launcher_foreground.xml` — bars + arrow as Android vector drawable, positioned in the 72dp safe zone
- `Android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml` + `ic_launcher_round.xml` — wires the two drawables into an `<adaptive-icon>` for API 26+
- `Android/app/src/debug/res/drawable/ic_launcher_foreground.xml` — **debug-flavor override** that duplicates the prod foreground and adds an orange diagonal band over the top-left corner

## Dev / Debug variant

**iOS.** The project already has two asset catalogs — `AppIcon.appiconset` and `AppIcon-Debug.appiconset`. The Xcode project's Debug build configuration (`Configurations/Debug.xcconfig` or the build scheme's `ASSETCATALOG_COMPILER_APPICON_NAME`) is expected to point at `AppIcon-Debug` — no firmware/code change is needed on our side, just running the generator repopulates the right PNG with the DEV-ribbon design.

**Android.** `Android/app/src/debug/res/` is the standard location for debug-build resource overrides; Gradle merges it on top of `src/main/res/` automatically when assembling the `debug` variant. No `build.gradle` changes needed. If a future Android rewrite uses product flavors instead (e.g. `dev` / `prod`), the same PNGs + vector drawable can be moved into the matching flavor directory.

**Visual rule.** Any home-screen or launcher context that comes from a debug build shows the **orange diagonal band in the top-left**. The underlying mark is identical to prod — same bars, same lime accent — so the brand remains consistent; the debug variant is recognisable at a glance without being a different logo.

## Where the mark appears

| Surface | Location | How it gets there |
|---|---|---|
| ESP32 captive portal | `mdb-slave-esp32s3/webui/index.html` | Inline `<svg>` in the card header + base64 SVG favicon. Embedded into the firmware binary via `EMBED_FILES` in the main component's CMakeLists |
| Management frontend (browser tab) | `<link rel="icon">` in `management-frontend/nuxt.config.ts` | Served from `management-frontend/public/` |
| Management frontend (PWA installed) | `management-frontend/public/manifest.webmanifest` → `icons[]` | Served from `management-frontend/public/icons/` |
| iOS app | `ios/VMflow/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png` | Xcode asset catalog, auto-scaled at build |
| Android app | `@mipmap/ic_launcher` referenced from `Android/app/src/main/AndroidManifest.xml` | Legacy PNGs + adaptive-icon XML for API 26+ |

Everything else (Tabler icons in the Nuxt UI, SF Symbols in the iOS app, status-bar theme colours) is unrelated to the brand mark.

## CI

[`.github/workflows/brand-assets.yml`](.github/workflows/brand-assets.yml)
runs on every PR that touches `brand/**`:

1. Installs the generator deps (`npm ci` inside `brand/`).
2. Runs `node generate.mjs`.
3. Fails if the working tree differs from what was committed — meaning the SVG
   changed but the generated PNGs weren't regenerated.

The error message tells the contributor exactly what to run.

> **Platform note:** `@resvg/resvg-js` ships prebuilt native binaries per
> platform. Output is deterministic when the resvg version is pinned (which it
> is via `brand/package-lock.json`). In the rare case a CI run flags a
> byte-level diff that the developer's local machine doesn't produce, the fix
> is to run the generator on the CI platform (ubuntu-latest) or run it in
> Docker with the Node 22 image. In practice this hasn't been an issue.

## Changing the mark

1. Edit `brand/logo-mark.svg` **and** `brand/logo-mark-bleed.svg` (they should stay visually identical — only the outer `<rect>` differs in whether `rx=10` is present).
2. Edit `brand/logo-mark-dev.svg` **and** `brand/logo-mark-dev-bleed.svg` to mirror the same change — the dev variants embed a copy of the mark paths plus the DEV ribbon; diverging them will cause prod and dev to drift.
3. Run `cd brand && npm run generate`.
4. Update the Android adaptive-icon vector drawables by hand so they match:
   - `Android/app/src/main/res/drawable/ic_launcher_foreground.xml` (prod)
   - `Android/app/src/debug/res/drawable/ic_launcher_foreground.xml` (dev; share the same bar paths as prod, plus the orange band at the bottom)
   - `Android/app/src/main/res/drawable/ic_launcher_background.xml` only if the background colour changes
5. Update the inline SVG inside `mdb-slave-esp32s3/webui/index.html` (both the `<svg>` element and the base64 `<link rel="icon">` — re-encode the new SVG with `base64 -e < brand/logo-mark.svg`).
6. Open `brand/preview.html` via the `brand-preview` launch config (`python3 -m http.server 3003` in `brand/`) to visually compare prod vs dev before committing.
7. Commit all changes together. CI verifies consistency.

If this list grows, consider extending `brand/generate.mjs` to also emit the Android vector drawables and the captive-portal HTML snippet, so all propagation is automated.
