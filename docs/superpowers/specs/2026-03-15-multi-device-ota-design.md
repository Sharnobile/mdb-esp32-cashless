# Multi-Device OTA Deployment + Live Device Status

## Problem

The firmware page currently supports deploying OTA updates to only one device at a time. Operators managing multiple vending machines must repeat the deploy flow for each device individually. Additionally, the devices page lacks live status updates — the online/offline badge only reflects the state at page load.

## Solution

### 1. Multi-Device Deploy Modal

Replace the single-device dropdown in the OTA deploy modal with a checkbox list supporting batch selection.

**Selection UI (`pages/firmware/index.vue`):**

- "Select all" checkbox in header with counter ("3/12 selected")
- Filter row: text search + status filter dropdown (All / Online only)
- Scrollable device list with checkboxes showing per device: machine name, MAC address, online/offline badge, current firmware version
- Offline devices are selectable but visually marked (muted style + badge). On deploy, a warning banner appears: "X devices are offline — update will be delivered when they come online"
- Deploy button shows dynamic count: "Update X devices"

**Progress view (same modal, after submit):**

- Modal transitions from selection to progress view on submit
- Progress bar at top: "X/Y sent"
- Per-device row with status icon:
  - Pending (dot)
  - Sending (spinner)
  - Sent (checkmark, green)
  - Failed (X, red) with error message
- "Retry failed" button appears when any device fails — retries only devices with `status === 'failed'`, never re-sends to already-successful devices
- "Close" button always available
- Calls to `trigger-ota` run sequentially (one device at a time) to avoid MQTT broker overload

### 2. Batch OTA Helper (`composables/useFirmware.ts`)

```ts
type OtaDeviceStatus = 'pending' | 'sending' | 'sent' | 'failed'
type OtaProgressCallback = (deviceId: string, status: OtaDeviceStatus, error?: string) => void

function triggerOtaBatch(
  deviceIds: string[],
  firmwareId: string,
  onProgress: OtaProgressCallback
): Promise<{ sent: string[], failed: { id: string, error: string }[] }>
```

Behavior:

1. Iterates through device IDs sequentially
2. Calls `onProgress(deviceId, 'sending')` before each call
3. Calls existing `triggerOta()` for each device (params: `{ device_id, firmware_id }`)
4. Calls `onProgress(deviceId, 'sent')` or `onProgress(deviceId, 'failed', errorMessage)` after each call
5. Returns summary object
6. State is owned by the composable (not the component) so the batch loop continues safely even if the modal is closed/unmounted

No new edge function needed — reuses existing `trigger-ota` endpoint per device.

### 3. Live Device Status (`pages/devices/index.vue`)

Add Supabase Realtime subscription on the `embeddeds` table to update online/offline badges without page refresh. Pattern follows `useMachines` composable which already subscribes to `embeddeds` for the machines page.

### 4. Files Changed

| File | Change |
|------|--------|
| `management-frontend/app/pages/firmware/index.vue` | Replace single-select modal with checkbox list + progress view |
| `management-frontend/app/composables/useFirmware.ts` | Add `triggerOtaBatch()` helper |
| `management-frontend/app/pages/devices/index.vue` | Add realtime subscription for device status |
| `management-frontend/i18n/locales/en.json` | New translation keys for multi-deploy UI |
| `management-frontend/i18n/locales/de.json` | German translations |

### 5. What Does NOT Change

- No database migrations
- No new edge functions
- No changes to `trigger-ota` backend
- No MQTT protocol changes
- Fully backward-compatible: single-device deploy still works (select one checkbox)

### 6. Data Flow

```
User selects devices + clicks "Update X devices"
  → Modal switches to progress view
  → For each device (sequentially):
      → POST /functions/v1/trigger-ota { device_id, firmware_id }
      → Edge function publishes to MQTT /{company}/{device}/ota
      → ota_updates row created with status='triggered'
      → onProgress callback updates UI for that device
  → All done: show summary (X sent, Y failed)
  → User can retry failed or close
```

### 7. Edge Cases

- **All devices offline**: Warning shown but deploy proceeds (MQTT QoS 1 ensures delivery when device reconnects)
- **Network error mid-batch**: Failed devices marked red, "Retry failed" button available, already-sent devices unaffected
- **Modal closed during deploy**: Batch state lives in the composable (not component refs), so the loop continues safely. Re-opening the modal could show current progress if needed in the future.
- **Device source**: The modal shows devices from `useMachines()` (only devices linked to a vending machine), consistent with current behavior. Unassigned devices in `embeddeds` are managed on the Devices page, not deployed to from Firmware.
- **No devices available**: "No devices with embedded hardware assigned" message (same as current behavior)
- **Single device selected**: Works identically to current flow, just via checkbox instead of dropdown
