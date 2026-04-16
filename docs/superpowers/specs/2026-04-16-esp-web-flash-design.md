# ESP Web Flash — Browser-Based Firmware Installer

**Date:** 2026-04-16
**Status:** Draft

## Overview

Add a public `/install` page to the Nuxt management frontend that lets users flash ESP32-S3 firmware directly from their browser using [ESP Web Tools](https://github.com/esphome/esp-web-tools). The page requires no login and includes step-by-step guides for before and after flashing. Admins control which firmware versions are publicly visible via an opt-out `is_public` flag on the existing `/firmware` page. The column name `is_public` is used instead of `public` to avoid conflicts with the Postgres reserved schema name.

**Network constraint:** The `/install` page fetches firmware binaries from Supabase Storage via the browser. Users must be able to reach the Supabase URL. For self-hosted LAN deployments, this means the user's device must be on the same network. For cloud-hosted deployments, the public Supabase URL is used. The manifest endpoint constructs Storage URLs dynamically from `useRuntimeConfig()` — no hardcoded URLs.

## Goals

- Users can flash a VMflow ESP32-S3 device without installing build tools or desktop software
- Admins control which firmware versions are publicly available
- Full flash support (bootloader + partition table + app) via GitHub Actions pipeline
- Post-flash setup guide with concrete device details (SoftAP name, screenshots)
- i18n support (en/de) consistent with the rest of the frontend

## Non-Goals

- Replacing the existing OTA deployment flow (that stays as-is for field updates)
- Supporting ESP32 variants other than ESP32-S3
- Auto-provisioning after flash (user still goes through SoftAP captive portal)

---

## 1. Database Changes

### 1.1 New Migration

New migration file: `YYYYMMDDHHMMSS_firmware_web_flash.sql`

Add three columns to `firmware_versions`:

```sql
ALTER TABLE firmware_versions ADD COLUMN IF NOT EXISTS is_public boolean NOT NULL DEFAULT true;
ALTER TABLE firmware_versions ADD COLUMN IF NOT EXISTS bootloader_path text;
ALTER TABLE firmware_versions ADD COLUMN IF NOT EXISTS partition_table_path text;

-- Allow anonymous (anon) role to read public firmware versions
GRANT SELECT ON public.firmware_versions TO anon;

-- Allow authenticated role to update the is_public toggle (and other new columns)
GRANT UPDATE ON public.firmware_versions TO authenticated;
```

### 1.2 RLS Policies

Add an anonymous read policy for public firmware versions, and an update policy for admins:

```sql
CREATE POLICY "Anyone can read public firmware versions"
  ON firmware_versions FOR SELECT TO anon
  USING (is_public = true);

CREATE POLICY "Admins can update own firmware versions"
  ON firmware_versions FOR UPDATE TO authenticated
  USING (company_id = my_company_id() AND i_am_admin())
  WITH CHECK (company_id = my_company_id() AND i_am_admin());
```

The existing authenticated SELECT/INSERT/DELETE policies remain unchanged.

### 1.3 Storage Access

The `firmware` storage bucket is already public (read access). No changes needed — the new bootloader and partition table binaries stored alongside the app binary are automatically accessible.

### 1.4 Storage File Structure

Per firmware version, up to three files in the `firmware` bucket:

```
firmware/
  {company_id}/{version_label}.bin                ← App binary (existing)
  {company_id}/{version_label}-bootloader.bin     ← Bootloader (new)
  {company_id}/{version_label}-partitions.bin     ← Partition table (new)
```

---

## 2. GitHub Actions Workflow

### 2.1 Extended Build Artifacts

Extend `.github/workflows/build-firmware.yml` to upload two additional release assets alongside the existing app binary:

| Asset | Source | Example Name |
|-------|--------|-------------|
| App binary | `build/{name}.bin` | `mdb-slave-esp32s3-v1.2.3.bin` (unchanged) |
| Bootloader | `build/bootloader/bootloader.bin` | `mdb-slave-esp32s3-v1.2.3-bootloader.bin` (new) |
| Partition table | `build/partition_table/partition-table.bin` | `mdb-slave-esp32s3-v1.2.3-partitions.bin` (new) |

The existing app binary naming is preserved — nothing breaks for current consumers.

### 2.2 Workflow Changes

In the release step, add the two new files to the `files` list:

```yaml
- name: Create Release
  uses: softprops/action-gh-release@v2
  with:
    files: |
      ${{ env.PROJECT_DIR }}/build/${{ env.ARTIFACT_NAME }}.bin
      ${{ env.PROJECT_DIR }}/build/${{ env.ARTIFACT_NAME }}-bootloader.bin
      ${{ env.PROJECT_DIR }}/build/${{ env.ARTIFACT_NAME }}-partitions.bin
    # ... rest unchanged
```

Before the release step, add rename steps for the new binaries. Source paths must use the full project directory prefix (same as the existing app binary rename):

```yaml
- name: Rename bootloader artifact
  run: cp ${{ steps.project.outputs.dir }}/build/bootloader/bootloader.bin ${{ steps.project.outputs.dir }}/build/${{ env.ARTIFACT_NAME }}-bootloader.bin

- name: Rename partition table artifact
  run: cp ${{ steps.project.outputs.dir }}/build/partition_table/partition-table.bin ${{ steps.project.outputs.dir }}/build/${{ env.ARTIFACT_NAME }}-partitions.bin
```

---

## 3. Import GitHub Release — Edge Function

### 3.1 Extended Import Logic

`Docker/supabase/functions/import-github-release/index.ts` currently downloads one `.bin` asset. Extend to:

1. After downloading the primary app binary (existing), look for matching bootloader and partitions assets in the same release:
   - Pattern: `{base_name}-bootloader.bin` and `{base_name}-partitions.bin` where `base_name` matches the primary asset without `.bin` extension
2. If found, download and upload each to storage at `{company_id}/{version_label}-bootloader.bin` and `{company_id}/{version_label}-partitions.bin`
3. Store the paths in the new `bootloader_path` and `partition_table_path` columns

### 3.2 Backward Compatibility

- If bootloader/partitions assets are not found in the release (older releases), the columns remain `null`
- No error is thrown — the import succeeds with just the app binary (as before)
- The edge function response includes a `has_full_flash` boolean indicating whether all three binaries were imported

---

## 4. Nuxt Server API Routes

### 4.1 Manifest Endpoint

**`server/api/firmware/manifest.get.ts`**

Public endpoint (no auth). Returns an ESP Web Tools manifest for a given firmware version.

**Request:** `GET /api/firmware/manifest?id={firmware_version_id}`

**Response:**
```json
{
  "name": "VMflow MDB Cashless",
  "version": "1.2.3",
  "builds": [
    {
      "chipFamily": "ESP32-S3",
      "parts": [
        { "path": "https://{supabase}/storage/v1/object/public/firmware/{company}/{ver}-bootloader.bin", "offset": 0 },
        { "path": "https://{supabase}/storage/v1/object/public/firmware/{company}/{ver}-partitions.bin", "offset": 32768 },
        { "path": "https://{supabase}/storage/v1/object/public/firmware/{company}/{ver}.bin", "offset": 131072 }
      ]
    }
  ]
}
```

**Behavior:**
- Creates a Supabase client using `@supabase/supabase-js` with the **anon key** from `useRuntimeConfig(event).public.supabase` (URL + anon key). Both are already available in the frontend container — no new env vars needed. The anon key is safe to use server-side here because RLS restricts access to `is_public = true` rows only.
- Queries `firmware_versions` where `id = ?` AND `is_public = true`
- Returns 404 if version not found or not public
- Constructs Storage URLs dynamically using the **public** Supabase URL from `useRuntimeConfig(event).public.supabase.url` (this is the URL the user's browser can reach)
- If `bootloader_path` or `partition_table_path` is null, includes only the app binary part at offset `0x20000` (131072)

**Server-side Supabase access pattern:** Both server routes use `createClient()` from `@supabase/supabase-js` directly (not the Nuxt module's `useSupabaseClient()` which is Vue-only). They use the **anon key** (not the service key) because these endpoints only need public read access, and the anon RLS policy covers exactly this use case:

```typescript
// server/utils/supabase.ts — shared helper for public-read endpoints
import { createClient } from '@supabase/supabase-js'
import type { H3Event } from 'h3'

export function useServerSupabaseAnon(event: H3Event) {
  const config = useRuntimeConfig(event)
  return createClient(config.public.supabase.url, config.public.supabase.key)
}
```

No new env vars or Docker changes needed — `NUXT_PUBLIC_SUPABASE_URL` and `NUXT_PUBLIC_SUPABASE_KEY` are already injected into the frontend container.

### 4.2 Public Versions Endpoint

**`server/api/firmware/public.get.ts`**

Public endpoint (no auth). Returns all publicly available firmware versions for the dropdown.

**Request:** `GET /api/firmware/public`

**Response:**
```json
[
  {
    "id": "uuid",
    "version_label": "v1.2.3",
    "notes": "Changelog text...",
    "created_at": "2026-04-16T...",
    "has_full_flash": true
  }
]
```

**Behavior:**
- Uses the same `useServerSupabaseAnon()` helper as the manifest endpoint
- Queries `firmware_versions` where `is_public = true`, ordered by `created_at` desc
- `has_full_flash` is computed: `bootloader_path IS NOT NULL AND partition_table_path IS NOT NULL`
- No company filter — returns all public versions across all companies (the public page is not company-scoped)
- **Privacy note:** All firmware versions default to `is_public = true`. Admins of any company must opt-out via the toggle before importing firmware if they do not want it listed publicly. The admin UI should show a brief reminder of this when importing.

---

## 5. Public `/install` Page

### 5.1 Route Configuration

Add `/install` to the public routes list in `app/middleware/auth.ts` so it does not require authentication.

The page uses `definePageMeta({ layout: false })` to avoid rendering the authenticated app shell (sidebar, bottom tab bar). It renders its own minimal layout (header with logo + language switcher, footer).

### 5.2 Page Structure

**`app/pages/install.vue`**

Top-to-bottom layout:

1. **Header** — VMflow logo + Language Switcher (en/de)

2. **Introduction** — Brief explanation of VMflow and what this page does

3. **Prerequisites Checklist**
   - Compatible browser (Chrome 89+ or Edge 89+) with Web Serial API
   - Internet access (the flashing engine is loaded from a CDN at runtime)
   - USB-C cable
   - ESP32-S3 development board

4. **Pre-Flash Guide**
   - Step 1: Connect ESP32-S3 via USB to your computer
   - Step 2: If device is not detected, hold BOOT button while connecting
   - Step 3: Select firmware version from dropdown (newest pre-selected)

5. **Flash Area**
   - `<esp-web-install-button>` web component with dynamic `manifest` attribute
   - Wrapped in `<ClientOnly>` for SSR safety
   - Browser compatibility notice if Web Serial API is not available (detected via `navigator.serial`)

6. **Release Notes**
   - Markdown-rendered changelog for the selected firmware version
   - Updates reactively when dropdown selection changes

7. **Post-Flash Setup Guide**
   - Step 1: Device restarts and creates WiFi hotspot named `VMflow-XXXX` (last 4 chars of MAC address), no password (open network)
   - Step 2: Connect to the hotspot with your phone/laptop — captive portal opens automatically
   - Step 3: Select your WiFi network and enter the password
   - Step 4: Enter provisioning code — with sub-section explaining how to generate one:
     - Screenshot placeholder of `/devices` page showing "Register New Device" button
     - Screenshot placeholder of the provisioning code dialog
   - Step 5: Confirm server URL (pre-filled, usually no change needed)
   - Step 6: Device connects and appears in the management dashboard
   - Screenshot placeholders from the captive portal UI (WiFi selection, code entry, success)

8. **Footer** — Links to GitHub repository, management dashboard, documentation

### 5.3 i18n

All text content uses the `useI18n()` composable with keys under `install.*` namespace. Both `en` and `de` translations provided.

### 5.4 Placeholder Images

Stored in `public/images/install/`:
- `captive-portal-wifi.png` — WiFi selection screen
- `captive-portal-code.png` — Provisioning code entry
- `captive-portal-success.png` — Success state
- `dashboard-register-device.png` — Device registration button in dashboard
- `dashboard-provisioning-code.png` — Provisioning code dialog

Initially placeholder images; replaced with real screenshots later.

---

## 6. Admin `/firmware` Page Changes

### 6.1 Public Toggle

Add a toggle switch in each firmware version table row:
- Bound to `firmware_versions.is_public` column
- Calls `updateFirmwareVersion(id, { is_public: value })` on toggle
- Default: on (opt-out model)

### 6.2 Full Flash Indicator

Add a small badge/icon per row indicating whether all three binaries are present:
- **"Full Flash"** badge (green) — bootloader + partitions + app all present
- **"App Only"** badge (gray) — only app binary available
- Tooltip explaining the difference: "Full Flash supports first-time installation via the web installer. App Only is suitable for OTA updates."

### 6.3 Composable Changes

Extend `useFirmware.ts`:
- Add `is_public`, `bootloader_path`, `partition_table_path` to the `FirmwareVersion` interface
- Add `updateFirmwareVersion(id: string, updates: Partial<FirmwareVersion>)` function for the public toggle
- Add `has_full_flash` computed helper
- **Update `deleteFirmwareVersion()`** to also remove `bootloader_path` and `partition_table_path` storage objects when non-null (prevents orphaned files in the firmware bucket)

### 6.4 Manual Upload Extension

The upload modal gets two optional file inputs:
- "Bootloader binary (.bin)" — optional
- "Partition table binary (.bin)" — optional

If provided, uploaded alongside the app binary to storage with the `-bootloader.bin` / `-partitions.bin` suffix. Paths stored in the new DB columns.

---

## 7. ESP Web Tools Integration

### 7.1 Package Installation

```bash
cd management-frontend
npm install esp-web-tools
```

### 7.2 Nuxt Configuration

In `nuxt.config.ts`, register `esp-*` as custom elements:

```typescript
vue: {
  compilerOptions: {
    isCustomElement: (tag) => tag.startsWith('esp-')
  }
}
```

### 7.3 Client-Side Loading

On the `/install` page, import esp-web-tools dynamically in `onMounted`:

```typescript
onMounted(async () => {
  await import('esp-web-tools')
})
```

The `<esp-web-install-button>` is rendered inside `<ClientOnly>`:

```vue
<ClientOnly>
  <esp-web-install-button
    :manifest="`/api/firmware/manifest?id=${selectedVersionId}`"
  >
    <span slot="activate">Flash Firmware</span>
    <span slot="unsupported">Your browser does not support Web Serial</span>
  </esp-web-install-button>
</ClientOnly>
```

### 7.4 Browser Compatibility Detection

Before the flash button, check for Web Serial API support:

```typescript
const hasWebSerial = ref(false)
onMounted(() => {
  hasWebSerial.value = 'serial' in navigator
})
```

If not supported, show a notice listing compatible browsers (Chrome 89+, Edge 89+) instead of the flash button.

**Note:** The `esp-web-tools` npm package is a thin wrapper — the actual flashing engine (improv-wifi, esptool-js) is loaded from a CDN at runtime by the web component. This means the user's browser needs internet access for flashing to work, even when the management app is self-hosted on a local LAN.

---

## 8. Flash Offsets

ESP32-S3 flash layout (4MB, DIO mode, 80MHz):

| Binary | Offset (hex) | Offset (decimal) |
|--------|-------------|-------------------|
| Bootloader | `0x0` | 0 |
| Partition table | `0x8000` | 32768 |
| App | `0x20000` | 131072 |

These offsets are derived from the ESP-IDF build output (`build/flash_args`) and are constant for the current partition scheme.

---

## 9. Data Flow Summary

```
GitHub Actions (tag push)
  ├─ Builds firmware (ESP-IDF v5.5.1)
  ├─ Creates GitHub Release with 3 assets:
  │   ├─ app.bin
  │   ├─ bootloader.bin
  │   └─ partitions.bin
  │
  ▼
Admin: /firmware page
  ├─ "Import from GitHub" → import-github-release edge function
  │   ├─ Downloads all 3 assets → Supabase Storage
  │   └─ Creates firmware_versions row (is_public=true by default)
  ├─ OR: Manual upload (app binary required, bootloader+partitions optional)
  ├─ Public toggle per version (opt-out)
  │
  ▼
Public: /install page
  ├─ GET /api/firmware/public → version dropdown
  ├─ User selects version
  ├─ <esp-web-install-button manifest="/api/firmware/manifest?id=X">
  │   └─ GET /api/firmware/manifest?id=X → ESP Web Tools manifest JSON
  │       └─ Points to Supabase Storage URLs for bootloader, partitions, app
  ├─ User clicks "Flash Firmware" → Web Serial → ESP32-S3 flashed
  │
  ▼
Post-Flash: User follows on-page setup guide
  ├─ Connect to VMflow-XXXX SoftAP (no password)
  ├─ Captive portal: enter WiFi + provisioning code
  └─ Device claims itself → appears in dashboard
```

---

## 10. Files Changed / Created

### New Files
| File | Purpose |
|------|---------|
| `management-frontend/app/pages/install.vue` | Public flash page |
| `management-frontend/server/api/firmware/manifest.get.ts` | ESP Web Tools manifest endpoint |
| `management-frontend/server/api/firmware/public.get.ts` | Public firmware versions endpoint |
| `management-frontend/server/utils/supabase.ts` | Server-side Supabase client helper |
| `Docker/supabase/migrations/YYYYMMDDHHMMSS_firmware_web_flash.sql` | DB migration |
| `public/images/install/*.png` | Placeholder screenshots (5 files) |
| `i18n/en/install.json` or inline i18n keys | English translations |
| `i18n/de/install.json` or inline i18n keys | German translations |

### Modified Files
| File | Change |
|------|--------|
| `.github/workflows/build-firmware.yml` | Upload bootloader + partitions assets |
| `Docker/supabase/functions/import-github-release/index.ts` | Download + store additional binaries |
| `management-frontend/app/composables/useFirmware.ts` | Extended types, updateFirmwareVersion(), has_full_flash |
| `management-frontend/app/pages/firmware/index.vue` | Public toggle, full flash badge, optional upload fields |
| `management-frontend/app/middleware/auth.ts` | Add `/install` to public routes |
| `management-frontend/nuxt.config.ts` | `vue.compilerOptions.isCustomElement` for `esp-*` |
| `management-frontend/package.json` | Add `esp-web-tools` dependency |
