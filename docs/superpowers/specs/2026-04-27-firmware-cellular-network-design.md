# Firmware Cellular Network Support (SIM7080G) — Single Binary, Runtime Detection

**Date:** 2026-04-27
**Status:** Draft
**Owner:** Lucien Kerl
**Scope:** Milestone (≈3-4 weeks part-time). Multi-phase plan to follow.

## Summary

The `mdb-slave-esp32s3` firmware today only ships network connectivity over WiFi.
A new hardware variant adds a SIM7080G LTE-M / NB-IoT modem so vending machines
can be deployed in locations without customer WiFi (most field deployments). This
milestone extends the firmware to support cellular as a first-class transport
**without forking the codebase**: a single binary boots cleanly on both the
existing WiFi-only PCB and the new SIM7080G PCB / LilyGo prototype board, with
runtime detection of the modem.

WiFi-only behaviour stays bit-for-bit unchanged for installed devices (backward
compatibility is non-negotiable — production fleet runs the same firmware
artefact). The captive portal becomes a small wizard that adapts to the variant:
WiFi-only devices see today's single-page form; SIM-equipped devices first
configure cellular (APN / PIN / LTE mode) and only then advance to the
provisioning-code screen, with a live status banner visible at every step.

A short-lived earlier attempt at this work landed in commit
[`d3f8b05`](../../mdb-slave-esp32s3/main/mdb-slave-esp32s3.c) on 2026-04-23 and
was lost during subsequent refactors (the SIM code only survived as GPIO
defines + the `espressif/esp_modem` dependency). This spec deliberately
separates the modem and network concerns into their own modules so the same
loss cannot happen again.

## Problem

Two vending machine deployment scenarios are not served by the current
firmware:

1. **Locations without WiFi** — most public/semi-public placements (kiosks,
   gyms, transit hubs, outdoor sites). Today the only way to onboard one is to
   bring a temporary hotspot, which is not viable for unattended installs.
2. **Locations with hostile WiFi** — captive-portal corporate networks,
   guest-WiFi disconnect cycles, or networks that block MQTT egress. A
   cellular fallback removes the dependency on the host network entirely.

The hardware fix exists (LilyGo T-SIM7080G ESP32-S3 in hand for prototyping,
[custom PCB in progress](../../kicad/mdb-slave-esp32s3-sim7080g/) on the
`feat/sim7080G` branch). The firmware fix is what this milestone delivers.

A secondary problem: the previous SIM7080G integration attempt on `main`
(commit `d3f8b05`, ~297 LOC inline in the already-2806-LOC
`mdb-slave-esp32s3.c`) was effectively erased by routine refactors days
later. The remnants on `main` today are only the GPIO defines, the
`espressif/esp_modem` dependency, and the `managed_components/` directory.
Module-level isolation (this spec) makes the next attempt durable.

## Goals

- **Single firmware binary** boots correctly on (a) existing WiFi-only PCB,
  (b) new SIM7080G custom PCB, (c) LilyGo T-SIM7080G prototype.
- **Runtime modem detection** at boot — no compile-time `#ifdef` to switch
  between variants, no separate build target.
- **Cellular-only policy when modem is present** — devices with a modem use
  cellular for all uplink; WiFi STA is not initialised. Deterministic, no
  failover state machine to debug.
- **Captive portal wizard** — SoftAP comes up immediately on every boot that
  needs setup. SIM-equipped devices must complete cellular configuration
  before the claim screen unlocks. A status banner is visible on every step.
- **Backward compatibility** — installed WiFi-only devices that pull the new
  firmware behave bit-for-bit identically to today.
- **Modem-aware recovery** — power-cycle the modem before falling back to a
  hard reboot, to avoid wasting flash cycles on a hung modem chip.
- **Backend visibility** — RSSI / operator / network mode / IP appear in the
  `status` MQTT payload and a small badge in the management frontend.

## Non-Goals

- **No iOS-app / BLE provisioning in this milestone.** The modular design
  leaves the hooks in place (`cellular_configure()` is callable from any
  handler, not just HTTP), but the BLE provisioning UX is a separate
  milestone after firmware lands.
- **No SoftAP / BLE recovery channel post-claim.** If layered recovery
  exhausts itself on a fielded device, on-site reflash or hardware swap is
  required. SoftAP-on-failure is intentionally deferred (security-vs-debug
  trade-off; revisit once field data justifies it).
- **No Carrier-preset dropdown** in the captive portal. APN stays a freeform
  text field with a Kconfig default. Maintaining a curated carrier list is
  pure churn for a globally-deployed product.
- **No data-usage telemetry** (TX/RX byte counters, monthly caps). YAGNI for
  v1; revisit if customer feedback shows it matters.
- **No SMS / out-of-band command channel.** All commands continue to go via
  MQTT.
- **No iOS-app changes** — the iOS app already reads `mdb_diagnostics` as
  jsonb, missing cell_* fields are non-breaking. iOS visibility lands in a
  follow-up milestone alongside BLE provisioning.
- **No DB schema migration.** All new firmware fields land in the existing
  `embeddeds.mdb_diagnostics` jsonb column — additive by definition.

## Design

### 1. Module structure

Three new/refactored components in `mdb-slave-esp32s3/main/`:

**`modem.c` / `modem.h`** — All SIM7080G + esp_modem code:

```c
bool        modem_probe(void);                                 // power-pulse + AT-sync, 3-5s
esp_err_t   modem_init(const char *apn, const char *pin, uint8_t lte_mode);
esp_err_t   modem_connect(void);                               // CFUN=1, register, start PPP
esp_err_t   modem_disconnect(void);                            // PPP→AT
void        modem_status(modem_status_t *out);                 // registered, RSSI, op, IP, mode
void        modem_power_cycle(void);                           // PWRKEY pulse, clean reset
```

Internal FreeRTOS watchdog task (low priority, 30 s tick) runs the
power-cycle before hard-reboot escalation (see §5).

**`network.c` / `network.h`** — Boot orchestrator and single source of truth
for "what's the uplink?":

```c
void                network_init(void);                  // probes modem, branches
network_state_t     network_get_state(void);             // BOOTING / WIFI_UP / CELLULAR_UP / OFFLINE / SOFTAP_ONLY
void                network_get_status(network_status_t *out);  // for portal + status payload
void                network_start_softap(void);          // wraps webui_server lifecycle
```

`network.c` registers for `WIFI_EVENT`, `IP_EVENT`, and `NETIF_PPP_STATUS`
internally — the rest of the firmware only sees `network_*` callbacks. After
this refactor, `mdb-slave-esp32s3.c` no longer touches `esp_wifi_*` directly.

**`webui_server.c`** *(refactored)* — wizard state machine instead of a
single global form. Status banner is rendered from `network_get_status()`.

**`mdb-slave-esp32s3.c`** *(reduced)* — loses the existing
`wifi_event_handler` and `ip_event_handler` (~150 LOC), keeps MDB protocol,
MQTT app logic, BLE, sale queue. Net file size shrinks.

`provision_claim_task` and the MQTT client setup stay in `main.c` — they only
consume the abstract `network_*` API; they do not need to know whether the
underlying netif is WiFi or PPP.

### 2. Boot flow

```
app_main()
  ├─ NVS init, GPIO setup, LED, ADC, MDB-UART (unchanged)
  ├─ esp_netif_init(), esp_event_loop_create_default()
  └─ network_init()
       ├─ modem_probe()      // 3-5 s, power-pulse + AT-sync
       │
       ├─ MODEM DETECTED ──────────────────────────────────────────┐
       │   • State = SOFTAP_ONLY (wizard runs)                     │
       │   • esp_netif_create_default_wifi_ap()  // SoftAP only    │
       │   • esp_wifi_start() in AP mode                           │
       │   • start_softap() + start_dns_server() + start_rest_srv  │
       │   • WiFi STA is NOT initialised (cellular policy)         │
       │   •                                                       │
       │   • IF nvs.apn present:                                   │
       │       └─ modem_init(apn, pin, mode) + modem_connect()     │
       │           └─ on PPP_GOT_IP → State = CELLULAR_UP          │
       │               └─ if nvs.passkey present → start MQTT      │
       │               └─ else → wizard shows claim form           │
       │   • ELSE: wizard waits for POST /api/v1/cellular/configure│
       │
       └─ MODEM ABSENT ────────────────────────────────────────────┐
           • Bisheriges Verhalten 1:1                              │
           • esp_netif_create_default_wifi_sta() + ap()            │
           • esp_wifi_connect() — falls fehlt: SoftAP nach 5 retries│
           • on IP_EVENT_STA_GOT_IP → State = WIFI_UP → MQTT start │
```

The two paths converge once an IP exists. `esp_mqtt_client`,
`esp_http_client`, `esp_https_ota` see "IP up" and work unchanged regardless
of whether they are running on a WiFi STA netif or a PPP netif.

SoftAP runs continuously on SIM devices until the claim succeeds. After
successful claim → `esp_restart()` (existing behaviour) → on next boot,
`passkey` is set, `prov_code` is cleared, SoftAP no longer comes up.

**Crucial backward-compat point:** when `modem_probe()` returns false, the
network init path is structurally identical to today's `app_main()`. WiFi-only
boards see no behaviour change.

**Modem stays powered off on first boot until the user has saved an APN** —
this matches the chosen UX ("Modem starten ergibt erst Sinn, wenn der Nutzer
den APN hinterlegt hat") and keeps current draw down on freshly-unboxed SIM
devices that haven't been configured yet.

### 3. Captive portal wizard

**Status banner** (always visible, top of every step):

- Variant icon (SIM or WiFi)
- Current state in plain German: e.g. *"SIM nicht konfiguriert"*,
  *"Verbinde mit Mobilfunk…"*, *"Vodafone DE · -78 dBm · LTE-M"*,
  *"Online via WiFi"*
- Claim status (*"Nicht angemeldet"* / *"Angemeldet als <subdomain>"*)
- Frontend polls `GET /api/v1/system/info` every 2 s and re-renders.

**Wizard steps for SIM variant:**

1. **Mobilfunk konfigurieren**
   - APN (text, default from Kconfig)
   - SIM-PIN (text, optional)
   - LTE mode (Auto · Cat-M only · NB-IoT only)
   - Submit → `POST /api/v1/cellular/configure` →
     banner shows live: *"Schalte Modem ein…"* → *"Suche Netz…"* →
     *"Registriere bei T-Mobile DE…"*
   - On success: step 2 unlocks.
   - On failure after 60 s: back to step 1 with error text.

2. **Gerät registrieren** (only reachable when `CELLULAR_UP`)
   - Provisioning code (8 chars)
   - Server URL (text, default `https://api.vmflow.xyz`)
   - Submit → `POST /api/v1/claim` →
     banner shows: *"Sende Anfrage…"* → *"Geräte-ID erhalten"* →
     *"Reboot in 3 s"*

**Wizard for WiFi-only variant:** unchanged from today — single page with
SSID picker + password + provisioning code + server URL in one submit.
Only addition: the new status banner at the top.

**API endpoints:**

| Method | Path | Purpose |
|---|---|---|
| `GET`  | `/api/v1/system/info`        | extended (see §4) |
| `GET`  | `/api/v1/wifi/scan`          | unchanged |
| `POST` | `/api/v1/cellular/configure` | new — `{apn, pin, lte_mode}` |
| `POST` | `/api/v1/wifi/configure`     | new — `{ssid, password}` |
| `POST` | `/api/v1/claim`              | new — `{prov_code, srv_url}`. Internally invokes the existing `claim-device` Edge Function under the hood; **no backend changes required.** |
| `GET`  | `/generate_204`, `/hotspot-detect.html` | unchanged captive helpers |

The old `POST /api/v1/settings/set` is **removed** — the captive portal HTML
is served by the firmware itself, there is no cross-device caching, so no
compatibility shim is required.

The previous `mqtt_host` / `mqtt_port` / `mqtt_user` / `mqtt_pass` /
`srv_url` power-user override fields are removed from the captive portal —
they are populated from the `claim-device` Edge Function response anyway, the
manual fields were noise.

**HTML:** `webui/index.html` becomes a single-file vanilla-JS SPA (still
`EMBED_FILES`-bundled). One polling loop, three render functions keyed on
`wizard_state`, one shared banner render.

**i18n for wizard:** the German strings used as illustration above
(*"Suche Netz…"*, *"Registriere bei T-Mobile DE…"*, etc.) are part of the
embedded HTML/JS. Since the captive portal serves a single language at a
time and runs entirely on-device (not via Nuxt i18n), wizard strings live
inline in the HTML with a small `LANG` constant at the top — German first,
matching the existing portal copy. English fallback strings live next to
them. This is a P3 deliverable; not part of the Nuxt `app/i18n/locales/`
files (which only cover the management frontend, see §6).

### 4. NVS keys & status payload

**New NVS keys** (namespace `vmflow`):

| Key | Type | Default | Meaning |
|---|---|---|---|
| `apn` | `str` | empty | APN for modem. Empty → modem stays powered off, wizard requires entry. |
| `sim_pin` | `str` | empty | Optional SIM PIN (4-8 digits). |
| `lte_mode` | `u8` | `3` | `1`=Cat-M, `2`=NB-IoT, `3`=Both (matches old Kconfig encoding). |

**Existing keys** unchanged: `company_id`, `device_id`, `passkey`,
`prov_code`, `srv_url`, `mqtt_host`, `mqtt_port`, `mqtt_user`, `mqtt_pass`,
`mdb_addr`, `restart_reason`, `last_uptime`.

The choice to use *empty `apn`* as the "modem is disabled" sentinel (instead
of a dedicated `cellular_enabled` boolean) is a deliberate DRY move: one
source of truth, one fewer NVS round-trip. It only fails if a deployment
actively wants a configured-but-disabled modem, which is not a real use case.

**`status` MQTT payload** (plaintext JSON, additive change):

```json
{
  "version": "...",          // existing
  "uptime": 12345,           // existing
  "wifi_rssi": -55,          // existing — null when uplink is cellular
  "free_heap": ...,          // existing
  "uplink": "cellular",      // NEW — "wifi" | "cellular"
  "cell_operator": "Vodafone DE",
  "cell_mode": "LTE-M",      // "LTE-M" | "NB-IoT" | "GSM"
  "cell_rssi_dbm": -78,
  "cell_ip": "10.64.12.5"
}
```

`mqtt-webhook` Edge Function writes the payload as-is into
`embeddeds.mdb_diagnostics` (jsonb). No schema migration. Old WiFi firmware
that does not set the new fields stays valid; frontend treats `cell_*` as
optional.

**Captive-portal `/system/info` response shape:**

```json
{
  "variant": "cellular",
  "wizard_state": "cellular_registering",
  "uplink": {
    "kind": "cellular",
    "wifi": null,
    "cellular": {
      "operator": "Vodafone DE",
      "mode": "LTE-M",
      "rssi_dbm": -78,
      "ip": "10.64.12.5",
      "registered": true
    }
  },
  "claim": { "claimed": false, "prov_code_set": false }
}
```

IMEI / ICCID stay queryable via AT (`AT+CIMI`, `AT+CCID`) but are not
persisted — no real benefit to caching them.

### 5. Recovery & watchdog

Three escalating layers, fast → nuclear:

```
Layer 1 — PPP reconnect           (seconds)
  Trigger: NETIF_PPP_LOST_IP
  Action:  modem_disconnect() → modem_connect() (re-attach PPP, no chip reset)
  Limit:   3 fast attempts

Layer 2 — Modem power-cycle       (~30-60 s)
  Trigger: 3 PPP-reconnect failures, OR
           AT-keepalive ping (issued by the watchdog every 30 s) returns
           no response for 60 s. The keepalive sends a bare `AT` command
           in command mode; in PPP mode it triggers the +++ escape first.
  Action:  PWRKEY pulse (low 1.2 s) → DTR toggle → 5 s boot wait
            → modem_init() → modem_connect()
  Limit:   2 power-cycles in a row

Layer 3 — Hard reboot             (existing)
  Trigger: Layer 2 exhausted, OR existing MQTT watchdog (10 min no MQTT)
  Action:  tracked_restart("modem_watchdog") → esp_restart()
  Frequency limit: max 1 per 10 min (avoids boot loop on dead hardware)
```

The watchdog task lives inside `modem.c` (low-priority FreeRTOS task, 30 s
tick). It also refreshes RSSI / operator for the next status payload.

The existing offline-safe sale queue continues to buffer sales across all
three recovery layers — `mqtt_started == true` triggers a queue flush
unchanged.

**MQTT tuning when uplink is cellular** (carried forward from the lost
`d3f8b05` work):

- Keepalive: `60 s` → **`180 s`** (cellular link is stable, save ~⅔ of
  keepalive bytes for IoT-SIM data quotas)
- Network timeout: `10 s` → **`30 s`** (LTE-M latency)
- Reconnect timeout: `10 s` → **`20 s`**

These values only apply when `network_get_state() == CELLULAR_UP`. WiFi
keeps the tighter defaults.

The 180 s keepalive means a cellular outage can stay undetected for up to
3 minutes (vs 1 minute on WiFi). Trade is acceptable for IoT data savings;
revisit if field data shows it matters.

### 6. Backend & frontend impact

**Backend:** zero code changes. `mqtt-webhook` already round-trips the status
payload jsonb-as-is into `embeddeds.mdb_diagnostics`. New fields just appear.

**Database:** zero migrations. `mdb_diagnostics` is jsonb; additive by
definition.

**Web frontend (`management-frontend`):**

One new component:

- `app/components/CellularHealthBadge.vue`
  - Props: `diagnostics: object` (the `mdb_diagnostics` jsonb)
  - Renders nothing if `diagnostics.uplink !== 'cellular'`.
  - Otherwise: 4-step signal bars (from dBm), operator name, mode pill
    (`LTE-M` / `NB-IoT`).
  - Tooltip on hover: exact dBm + IP.
- Mounted in `app/pages/devices.vue` (per row) and
  `app/pages/machines/[id].vue` (next to existing status indicator).

i18n: two new keys `cellularHealth.signal`, `cellularHealth.mode` in
`i18n/locales/en/*.json` and `de/*.json`.

**iOS app:** out of scope. Already reads `mdb_diagnostics` defensively;
missing `cell_*` fields are not a crash.

**Hardware variant pin defaults:** today's defines (`PIN_SIM7080G_RX=18`,
`TX=17`, `PWR=14`) match the LilyGo T-SIM7080G. **P1 hardcodes the LilyGo
pins as `#define`s** (matching today's state). The `Kconfig.projbuild`
override pattern is a deliberate follow-up: it ships *only when* the
custom PCB is finalised and known to use different pins. Doing it now
would be speculative — the spec records the path forward without
implementing it.

### 7. Testing & validation

**Automated (CI-runnable):**

- `CellularHealthBadge.vue` — Vitest:
  - renders nothing without `cell_*` fields
  - renders bars + operator + mode with fields
  - boundary dBm values (`-50` / `-80` / `-100` → `4` / `2` / `0` bars)
  - i18n snapshot.
- `webui_server` wizard state machine — if extracted as a pure
  `next_state(current, event) → new_state` C function, host-build unit
  tests via the ESP-IDF `linux` target.

**Manual acceptance test catalogue** (part of milestone-done criteria):

1. **Modem probe correctness** — LilyGo: `probe == true`. Original WiFi-only
   board: `probe == false`, no boot delay > 5 s.
2. **WiFi-only regression (critical)** — flash new firmware on an installed
   production WiFi-only device → boot timing, captive-portal behaviour, MQTT
   reconnect, sale flow indistinguishable from previous version. *This
   protects the backward-compat promise.*
3. **Cellular first-boot end-to-end** — fresh LilyGo + fresh SIM → captive
   portal → enter APN/PIN/mode → banner shows live registration → enter
   provisioning code → claim → reboot → first real sale arrives in Supabase.
4. **Cellular Layer-1 recovery** — provisioned device, pull antenna for
   30 s, reconnect → PPP reconnect succeeds, queued sales flush.
5. **Cellular Layer-2 recovery** — provisioned device, hang the modem
   (`AT+CFUN=0` then no response) → power-cycle pulse fires, modem returns,
   no hard reboot.
6. **OTA over cellular** — provisioned cellular device → trigger OTA from
   frontend → download over PPP, flash, reboot, `ota_success` published.
7. **Backend visibility** — cellular device shows the new badge with correct
   operator + bars in `/devices` and `/machines/[id]`.

**Existing infrastructure that helps:** `mdb-master-esp32s3` simulates a VMC
and can drive sales over MDB while cellular is the uplink. Sale-queue
offline-safe path is already validated.

**Explicitly not tested in this milestone:** carrier hand-off mid-flight
(LTE-M ↔ NB-IoT roaming), extreme dead-spot scenarios, multi-country/
multi-carrier validation — those become field-validation work after rollout.

## Phasing (rough — feeds writing-plans)

Approximate ordering for the milestone. Each phase ends with a runnable
checkpoint.

1. **P1 — Modem driver foundation** (~3-4 days)
   `modem.c`/`modem.h`, NVS keys, `idf_component.yml` + `managed_components`
   sanity, basic `probe → init → connect → status` validated on LilyGo with
   simple test main. DoD: `probe` returns `true` on LilyGo, `false` on
   original board; **GPIO 14 quiescent state on WiFi-only PCB empirically
   confirmed** — the probe leaves it untouched when no modem is present.

2. **P2 — Network manager abstraction** (~3-4 days)
   Extract WiFi event handlers from `mdb-slave-esp32s3.c` into `network.c`.
   Implement boot-flow decision. DoD: WiFi-only board behaviour identical
   to today; SIM board comes up on cellular when an APN is preconfigured in
   NVS via test fixture.

3. **P3 — Captive portal wizard** (~3-4 days)
   Refactor `webui_server.c` into wizard state machine. Wizard transitions
   live in a pure C function `wizard_next_state(current, event) → new_state`
   so they are host-testable via the ESP-IDF `linux` target. Rebuild
   `webui/index.html` as polling SPA with banner + step rendering, including
   the inline German + English wizard strings (see §3 i18n note). New API
   endpoints. DoD: installer can complete first-boot setup on both variants
   via the captive portal; `wizard_next_state` host-test suite green.

4. **P4 — Modem watchdog + recovery** (~2-3 days)
   Layer-1/2/3 logic, PPP-loss detection, MQTT tuning for cellular. DoD:
   simulated antenna disconnect recovers within 60 s; simulated modem hang
   triggers power-cycle, not reboot.

5. **P5 — Backend telemetry surface** (~2 days)
   Extend `status` payload, add `CellularHealthBadge.vue`, mount in two
   pages, i18n. DoD: cellular device shows live signal in management
   frontend.

6. **P6 — Field validation + docs** (~2 days)
   Run the manual acceptance catalogue end-to-end on a real LilyGo + real
   SIM. Update `CLAUDE.md` and `mdb-slave-esp32s3/README.md`. Document the
   custom-PCB pin override pattern. DoD: clean install + claim completes
   via cellular only, with no WiFi network in range.

Total: ~3-4 weeks part-time.

## Future considerations (out of scope here, but the design accommodates)

- **iOS app + BLE provisioning** — `cellular_configure()` and `claim_*` are
  internal C functions, callable from a future BLE handler with no further
  refactor.
- **SoftAP/BLE recovery channel** post-claim — Layer-3 hard-reboot is the
  ceiling today. Adding a fourth recovery layer that exposes BLE for
  on-site diagnosis is additive.
- **Carrier-preset dropdown** in the captive portal — still possible if the
  fleet ends up converging on a small set of IoT SIM providers.
- **Cellular health history** as a new `cellular-log` MQTT topic — would
  enable trend analysis (signal degradation over weeks, modem reliability
  per device). Mirrors today's `mdb-log` pattern.
- **Data-usage telemetry** — TX/RX byte counters in status payload, dashboard
  cards for monthly quota tracking.
- **Hardware variant Kconfig** for custom-PCB pin overrides — trivial when
  the PCB ships.

## Risks & backward compatibility

- **R1 — Refactor regression on WiFi-only path.** The biggest risk is that
  extracting the WiFi event handlers from `mdb-slave-esp32s3.c` into
  `network.c` introduces a subtle behaviour change for installed devices.
  *Mitigation:* test 2 (WiFi-only regression) is mandatory in P6 before
  rollout. Stage rollout to a small canary set first.
- **R2 — Modem probe side-effects on WiFi-only board.** The SIM7080G
  GPIOs (17/18/14) on the existing WiFi-only PCB may be unconnected,
  pulled, or wired to something unrelated. The probe sequence must not
  perturb anything visible to the rest of the board. *Mitigation:* before
  any pulse, the probe configures GPIO 14 as input-with-pull and reads
  the quiescent state; only if the read matches the expected
  modem-attached pattern (and an AT-sync attempt also fails initially)
  does it issue the PWRKEY pulse. P1 DoD includes empirical confirmation
  on a current production board that the probe leaves GPIO 14 untouched
  when no modem is present.
- **R3 — Lost-work recurrence.** The `d3f8b05` SIM code disappeared during
  routine refactors because it was inline in the megafile.
  *Mitigation:* the module split is the structural defence — modem code in
  its own file, network code in its own file, code review will spot
  accidental deletion of either.
- **R4 — IoT-SIM data quota blow-up from OTA.** A `~1.5 MB` firmware image
  is `~3 %` of a 50 MB/month quota; not a problem in normal cadence but
  could compound if multiple OTAs ship per month. *Mitigation:* document
  expected data per OTA in `CLAUDE.md`; consider WiFi-only OTA gate as a
  future enhancement.
- **R5 — Modem chip variant differences.** `esp_modem` v2 abstracts SIM7080
  generically, but the LilyGo board uses a slightly different PWRKEY pulse
  width than the custom PCB might. *Mitigation:* Kconfig-tunable pulse
  width, default tuned for LilyGo first.

The spec deliberately makes **no** changes that block a future
WiFi+cellular dual-uplink mode — the network manager state machine is
extensible. We just don't ship that mode in v1 because Q1 picked a
deterministic policy.
