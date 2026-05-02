# Firmware Cellular P6 — Field Validation Catalogue

> **For agentic workers:** This phase is **NOT executable autonomously**. Every task requires physical hardware (LilyGo T-SIM7080G-S3 board + a current production WiFi-only board + USB cable + serial monitor + a SIM card with cellular service). The autonomous agent has shipped P1–P5 and verified by build, source inspection, and unit tests where possible. P6 is the user's hardware acceptance gate.

**Goal:** Empirically prove that the cellular milestone delivers what the spec promised — and that the WiFi-only fleet is genuinely unaffected. Every test in this catalogue maps to a specific spec invariant. Mark tests off as you complete them; paste a serial-log excerpt under each completed test as your validation record.

**Spec reference:** [docs/superpowers/specs/2026-04-27-firmware-cellular-network-design.md](../specs/2026-04-27-firmware-cellular-network-design.md) — see §7 (Testing & validation), and the manual acceptance catalogue in each prior plan (P1 Tasks 12–13, P2 Task 11, P3 Task 8, P4 Task 5).

**Position in milestone:** Phase 6 of 6. Tag `milestone/cellular-v1` after all critical tests pass.

---

## Pre-flight

Before flashing anything, confirm the workshop environment:

- [ ] **ESP-IDF v5.5.1 active** in the shell:
  ```bash
  . ~/esp/esp-idf/export.sh
  idf.py --version    # should report 5.5.1
  ```
- [ ] **Branch is `claude/firmware-cellular-milestone`** (or merged to main if you've integrated):
  ```bash
  cd /Users/lucienkerl/Development/mdb-esp32-cashless
  git status
  git log --oneline -5
  ```
- [ ] **Build clean from scratch** (so any flash is from a known state):
  ```bash
  cd mdb-slave-esp32s3
  idf.py fullclean && idf.py build
  ```
  Expected: build succeeds, binary `~1.45 MiB`, ~14 % partition free.

- [ ] **Two boards in hand**:
  1. A current **production WiFi-only** PCB (any one out of the field — to use as the regression canary)
  2. The **LilyGo T-SIM7080G-S3** with a SIM card inserted and antenna attached
- [ ] **Serial port permissions OK** on both boards (`ls -la /dev/cu.usbmodem*` on macOS or `/dev/ttyUSB*` on Linux)

---

## Critical Test 1 — WiFi-only Production Regression (LOAD-BEARING)

**Spec invariant**: R1 — "no production regression on WiFi-only path". This is the single most important test in P6. If this fails, do NOT roll out the new firmware.

- [ ] **Step 1**: Flash production WiFi-only board:
  ```bash
  cd mdb-slave-esp32s3
  idf.py -p /dev/cu.usbmodem<TAB> flash monitor
  ```
- [ ] **Step 2**: Watch for the GPIO-14 quiescent check + probe-false:
  ```
  I (xxx) modem: PWRKEY quiescent: 0/5 high     ← critical: NOT 5/5
  I (xxx) modem: esp_modem_sync (cold try): ESP_ERR_TIMEOUT
  I (xxx) modem: esp_modem_sync (after PPP escape): ESP_ERR_TIMEOUT
  I (xxx) modem: GPIO quiescent says no modem — skipping power pulse  ← critical
  W (xxx) modem: no modem detected
  I (xxx) network: modem_probe → false
  ```
  If `PWRKEY quiescent: 5/5 high` on the production board: **STOP**. The probe will pulse GPIO 14 and could affect unrelated circuitry. See P1 Task 13 Step 2 for the recovery path (re-confirm pin defines, switch to pull-DOWN probe, escalate with PCB schematic).

- [ ] **Step 3**: Confirm WiFi behaves identically to today:
  - WIFI_EVENT_STA_START → connects to saved SSID
  - GOT_IP fires within 30 s
  - MQTT broker reachable, sales publish on next vend
  - SoftAP fallback after 5 failed retries (test by entering wrong WiFi password, wait, observe SoftAP up after 5× retry → 60 s reconnect timer engages)
- [ ] **Step 4**: Trigger a real vend on the MDB bus (or use mdb-master simulator). Confirm sale arrives in Supabase `sales` table.
- [ ] **Step 5**: Paste a representative serial log excerpt below (status payload + GOT_IP + MQTT connect):
  ```
  <paste here>
  ```

**If anything in Steps 2–5 differs from pre-P5 behaviour, treat as a P0 regression**: revert to commit `5a07b1d` (post-P1) or `122c718` (pre-cellular work) and bisect.

---

## Critical Test 2 — Cellular First-Boot End-to-End (LilyGo)

**Spec invariant**: §2 boot flow + §3 captive portal wizard.

- [ ] **Step 1**: Erase NVS on the LilyGo to simulate a true factory state:
  ```bash
  cd mdb-slave-esp32s3
  idf.py -p /dev/cu.usbmodem<TAB> erase-flash
  idf.py -p /dev/cu.usbmodem<TAB> flash monitor
  ```
- [ ] **Step 2**: Confirm probe + cellular branch:
  ```
  I (xxx) modem: PWRKEY quiescent: 5/5 high
  I (xxx) modem: esp_modem_sync (cold try): ESP_OK   ← (or: pulse → sync OK)
  I (xxx) modem: modem detected and synced
  I (xxx) network: modem_probe → true
  I (xxx) network: cellular branch — WiFi STA will NOT be initialised
  I (xxx) network: SoftAP up
  I (xxx) network: no APN in NVS — waiting for captive portal config
  ```
  *No WiFi STA init log line should appear.*

- [ ] **Step 3**: Connect a laptop/phone to the SoftAP (SSID = `vmflow_<MAC suffix>`, password = the project default). Open `http://192.168.4.1` (or follow the captive-portal redirect).
- [ ] **Step 4**: Confirm the SPA loads and shows the cellular config view:
  - Banner: `📡 SIM nicht konfiguriert` + claim badge `Nicht registriert`
  - Form: APN / SIM-PIN / LTE-Mode dropdown
  - Default APN should be `internet` (or whatever Kconfig was set to)
- [ ] **Step 5**: Enter your real SIM's APN (and PIN if applicable), submit. Confirm the banner advances:
  - `📡 Registriere bei Mobilfunknetz…` (within 1 s)
  - Watch serial log: `cellular bring-up: APN=…`, `AT+CFUN=1`, `AT+CEREG?` polling, eventually `EPS registered`
  - `📡 Vodafone DE · -78 dBm 📊 · LTE-M` (within 30–60 s)
  - `Bereit zur Anmeldung` claim badge appears
  - Claim form unlocks (prov_code + srv_url)
- [ ] **Step 6**: Generate a provisioning code in the management frontend (`/devices` → "Add device"). Enter it + the server URL into the SPA. Submit.
  - Banner: `Anfrage gesendet — warte auf Bestätigung…`
  - Watch serial log: `provision_claim_task` POSTs to `{srv_url}/functions/v1/claim-device`, receives the response, saves company_id/device_id/passkey/mqtt_host to NVS, calls `esp_restart()`.
- [ ] **Step 7**: Device reboots. On second boot:
  - `network_init: probing modem... → true`
  - `cellular branch — WiFi STA will NOT be initialised`
  - `APN found in NVS — starting cellular bring-up task`
  - `cellular up`
  - `MQTT: starting client (company='…' device='…')`
  - `MQTT_EVENT_CONNECTED`
- [ ] **Step 8**: Paste serial log excerpt for Steps 5–7:
  ```
  <paste here>
  ```

---

## Critical Test 3 — Cellular Recovery (Layer 1 PPP reconnect)

**Spec invariant**: §5 — Layer 1 recovery via 3 PPP reconnect attempts.

- [ ] **Step 1**: With the LilyGo provisioned and online, **physically disconnect the antenna**. Wait 30 s.
- [ ] **Step 2**: Watch the serial log:
  ```
  W (xxx) network: PPP LOST_IP
  W (xxx) network: PPP reconnect attempt 1/3
  W (xxx) network: PPP reconnect attempt 2/3
  W (xxx) network: PPP reconnect attempt 3/3
  E (xxx) network: PPP Layer-1 reconnect exhausted — handing off to watchdog
  ```
- [ ] **Step 3**: **Reattach the antenna**. Within ~30 s (one watchdog tick) the AT keepalive should succeed and the modem should re-register:
  ```
  I (xxx) modem: watchdog: AT recovered after N fails
  I (xxx) modem: EPS registered (stat=1): +CEREG: 1,1,...
  I (xxx) network: cellular up
  ```
- [ ] **Step 4**: Confirm sales queued during the outage flush successfully (sale_queue logs + new entries in Supabase `sales`).
- [ ] **Step 5**: Paste excerpt:
  ```
  <paste here>
  ```

---

## Critical Test 4 — Cellular Recovery (Layer 2 PWRKEY pulse)

**Spec invariant**: §5 — Layer 2 power-cycle when AT keepalive fails.

- [ ] **Step 1**: With LilyGo provisioned, force the modem into airplane via serial (only works in dev, not via OTA):
  - Open a serial monitor that allows AT command injection (e.g. `idf.py -p /dev/cu... monitor`, then `Ctrl+T Ctrl+X` and Enter raw bytes — or use a separate UART2 hookup with another USB-UART)
  - Send `AT+CFUN=0` then physically yank the modem antenna and disconnect any reconnect path

  *Easier alternative*: simulate by pulling the SIM card while online. Either way, the goal is "modem stops responding to AT".

- [ ] **Step 2**: Watch the watchdog escalate:
  ```
  W (xxx) modem: watchdog: AT ping failed (1/3): ESP_ERR_TIMEOUT
  W (xxx) modem: watchdog: AT ping failed (2/3): ESP_ERR_TIMEOUT
  W (xxx) modem: watchdog: AT ping failed (3/3): ESP_ERR_TIMEOUT
  W (xxx) modem: watchdog: Layer 2 — modem_power_cycle + re-init (#1)
  I (xxx) modem: PWRKEY pulsed; waiting 5 s for boot...
  I (xxx) modem: AT+CNMP=38: ESP_OK
  ...
  I (xxx) modem: watchdog: recovered via Layer 2
  ```
- [ ] **Step 3**: Confirm power-cycle happens within ~2 minutes total (3 fails × 30 s tick + boot wait).
- [ ] **Step 4**: Confirm Layer 2 limit (2 cycles max):
  - If you keep the modem hung, expect:
    ```
    E (xxx) modem: watchdog: power-cycle limit reached — leaving Layer 3 to handle
    ```
    Then 5–10 minutes later, the existing `mqtt_watchdog_cb` should hard-reboot the device.
- [ ] **Step 5**: Paste excerpt:
  ```
  <paste here>
  ```

---

## Critical Test 5 — OTA over Cellular

**Spec invariant**: §7 test 6.

- [ ] **Step 1**: Build a slightly-different binary (bump the version in `idf_component.yml` or change a log line) so OTA has something to install.
- [ ] **Step 2**: Upload to firmware storage and trigger OTA via management frontend → `/firmware`.
- [ ] **Step 3**: Watch the LilyGo serial log:
  ```
  I (xxx) ota: starting download from https://...
  I (xxx) ota: progress 50%, 100%
  I (xxx) ota: ota_success
  I (xxx) ota: rebooting
  ```
- [ ] **Step 4**: Confirm the device comes back online with the new version (status MQTT shows new `v:`).
- [ ] **Step 5**: Cellular data usage estimate: ~1.5 MiB. Document on which carrier/plan.

  Paste excerpt:
  ```
  <paste here>
  ```

---

## Critical Test 6 — Backend Visibility

**Spec invariant**: P5 telemetry surface.

- [ ] **Step 1**: With the LilyGo online via cellular, open the management frontend `/devices` page.
- [ ] **Step 2**: Find the LilyGo device row. Confirm the cellular health badge appears:
  - 4-step signal bars
  - Operator name (e.g. "Vodafone DE")
  - Mode pill (e.g. "LTE-M")
  - Hover tooltip shows exact dBm + IP
- [ ] **Step 3**: Open `/machines/[id]` for any machine bound to the cellular device. Confirm the badge appears in the header.
- [ ] **Step 4**: Confirm a WiFi-only device row in the same `/devices` table does NOT show any cellular badge.
- [ ] **Step 5**: Inspect `embeddeds.mdb_diagnostics` jsonb directly in Supabase Studio for the cellular device:
  ```json
  {
    "state": "ENABLED",
    "addr": 16,
    ...,
    "cellular": {
      "uplink": "cellular",
      "op": "Vodafone DE",
      "rssi": -78,
      "mode": "LTE-M",
      "ip": "10.64.12.5"
    }
  }
  ```
  Confirm the `cellular` block is present and the existing diagnostic keys are preserved.
- [ ] **Step 6**: Take a screenshot of `/devices` showing both cellular + WiFi badges side-by-side. Attach to the milestone tracker.

---

## Optional Test 7 — Carrier Roaming (LTE-M ↔ NB-IoT)

**Out of P6 scope per spec** but useful for confidence on dual-mode SIMs.

- [ ] If your SIM supports both LTE-M and NB-IoT, configure `lte_mode = Auto` and observe whether the modem prefers one. Document.
- [ ] Switch to `lte_mode = Cat-M only` and confirm registration still works.
- [ ] Switch to `lte_mode = NB-IoT only` and confirm registration. Note that on some carriers NB-IoT registration takes 60+ s; if `modem_wait_registered` times out, increase from 60 s to 120 s and report.

---

## Sign-off

When Critical Tests 1–6 are all green:

- [ ] Tag the milestone:
  ```bash
  cd /Users/lucienkerl/Development/mdb-esp32-cashless
  git tag -a milestone/cellular-v1 -m "Cellular network milestone v1: P1–P5 shipped, P6 hardware acceptance signed off"
  ```
- [ ] (Optional) Push the branch:
  ```bash
  git push origin claude/firmware-cellular-milestone
  ```
- [ ] (Optional) Open a PR for review and integration to `main`.
- [ ] Decide rollout cadence: small canary first (1–3 cellular devices in a controlled location), monitor for 1–2 weeks, then broader rollout.

---

## What's NOT covered by P6

- **Multi-country / multi-carrier validation** — that's a post-rollout field-data exercise.
- **Long-soak reliability** (week-plus continuous run) — gather field data during canary.
- **Modem firmware updates** — SIM7080G has its own firmware; stays at the version it shipped with unless explicitly updated via AT commands. Out of scope.
- **iOS app cellular display + BLE provisioning** — separate milestone after P6 ships (per spec Future Considerations).
- **Power consumption measurements** — cellular adds ~150 mA continuous on PPP. If battery-powered devices ever ship, would need DTR sleep + measurements; not relevant for mains-powered vending machines.
