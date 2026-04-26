# Firmware Cellular P2 — Network Manager

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce `network.c` / `network.h` as the single orchestrator for boot-time uplink selection (WiFi vs Cellular), extract the existing WiFi event handling out of `mdb-slave-esp32s3.c` into the new module, and replace P1's Kconfig-gated `CASHLESS_TEST_MODE_MODEM` wrap with a real runtime branch driven by the modem-probe result.

**Architecture:** New module `network.c` / `network.h` becomes the only place that touches `esp_wifi_*` event handlers, `WIFI_EVENT`/`IP_EVENT` registration, SoftAP lifecycle, the WiFi reconnect timer, and the cellular boot decision. `mdb-slave-esp32s3.c`'s `app_main` calls `network_init()` and registers a single callback (`network_register_callback`) that fires when an uplink comes up — at which point MQTT and the provisioning task start, regardless of whether the underlying netif is WiFi STA or PPP. The cellular branch (modem detected + APN in NVS) reuses `modem_probe`/`modem_init`/`modem_connect` from P1 unchanged.

**Tech Stack:** ESP-IDF v5.x, FreeRTOS, esp_wifi, esp_netif, esp_event, esp_modem (transitive via modem.h), nvs.

**Spec reference:** [docs/superpowers/specs/2026-04-27-firmware-cellular-network-design.md](../specs/2026-04-27-firmware-cellular-network-design.md) — see §1 (Module structure) and §2 (Boot flow).

**Position in milestone:** This is **Phase 2 of 6**. P1 (modem driver foundation) is complete (14 commits; tag pending hardware acceptance). P3 (captive portal wizard), P4 (modem watchdog), P5 (backend telemetry), P6 (field validation) follow in their own plan files.

**Backward-compat invariant (load-bearing):** On a board where `modem_probe()` returns false (production WiFi-only fleet), the post-P2 boot behaviour MUST be functionally identical to today. The acceptance test for this is Task 19 (deferred to user hardware testing). Any deviation breaks deployed devices.

---

## File Structure

P2 introduces two new files, materially changes one large file, and removes one file:

- **Create:** `mdb-slave-esp32s3/main/network.h` — public API: state enum, status struct, lifecycle (`network_init`, `network_get_state`, `network_get_status`, `network_register_callback`, `network_start_softap`, `network_stop_softap`), captive-portal-friendly entry points (`network_cellular_configure`, `network_wifi_configure`). Single responsibility: declare what `network.c` exposes.
- **Create:** `mdb-slave-esp32s3/main/network.c` — implementation. Owns the `WIFI_EVENT`/`IP_EVENT`/`NETIF_PPP_STATUS` event registrations, the WiFi reconnect timer, the SoftAP lifecycle, and the boot-time branch (`modem_probe()` true → cellular path; false → WiFi path). Single responsibility: orchestrate uplink lifecycle.
- **Modify:** `mdb-slave-esp32s3/main/modem.h` — promote `modem_nvs_load`/`modem_nvs_save` from internal forward-declarations to public API (P1 review surfaced this; P2 needs them in `network.c`).
- **Modify:** `mdb-slave-esp32s3/main/modem.c` — drop the internal forward-declaration block; the helpers are still defined here, just declared publicly now.
- **Modify (large):** `mdb-slave-esp32s3/main/mdb-slave-esp32s3.c` — remove `wifi_event_handler` (lines 2276–2440 today), `wifi_reconnect_timer_cb` (lines 84–87), the WiFi-related `app_main` initialisation block (lines 2569–2580 + the `esp_wifi_start()` at line 2782), the `wifi_retry_num` and `softap_active` and `wifi_reconnect_timer` static state (lines 80–82). Replace with a single `network_init()` call + a `network_register_callback()` that wires MQTT + provisioning to fire when the uplink comes up. Removes the test-mode `#if !CONFIG_CASHLESS_TEST_MODE_MODEM` wrap entirely (no longer needed; production main.c is now variant-agnostic).
- **Modify:** `mdb-slave-esp32s3/main/CMakeLists.txt` — add `network.c` to `srcs`; remove `modem_test.c` from `srcs` (file is going away).
- **Modify:** `mdb-slave-esp32s3/main/Kconfig.projbuild` — remove the `CASHLESS_TEST_MODE_MODEM` Kconfig option (its sole purpose was P1 validation; now obsolete). Keep the `SIM7080G` menu (`SIM7080G_APN`, `SIM7080G_CMNB`, the LTE-mode choice).
- **Delete:** `mdb-slave-esp32s3/main/modem_test.c` — superseded by the production boot path that runs the same probe/init/connect sequence.
- **Modify:** `CLAUDE.md` — update the Cellular driver paragraph to reflect P2 (it's now wired into the production boot path).

`network.h` and `network.c` should fit in ~140 lines and ~450 lines respectively. The post-P2 `mdb-slave-esp32s3.c` shrinks by ~180 lines (event handler + WiFi init removed). If `network.c` grows past ~600 lines, the boundaries should be revisited (most likely candidate: extracting the SoftAP / DNS lifecycle into a separate `softap.c`, but that decision waits for P3 when the captive-portal wizard is built).

---

## Chunk 1: Foundation — NVS promotion + network module skeleton (Tasks 1–3)

This chunk is purely additive. No production code paths change. The new `network.c` is wired into the build but never called yet — `network_init()` is a stub. Production behaviour is bit-identical to post-P1 state.

### Task 1: Promote modem NVS helpers to modem.h

**Files:**
- Modify: `mdb-slave-esp32s3/main/modem.h`
- Modify: `mdb-slave-esp32s3/main/modem.c`
- Modify: `mdb-slave-esp32s3/main/modem_test.c`

P1 deferred this. Network manager (this chunk's Task 4 will need it) and the captive portal (P3) both want these symbols, so they belong in the public header.

- [ ] **Step 1: Add macros + prototypes to `modem.h`**

Insert *before* the closing `#endif /* MODEM_H */` at the bottom of `modem.h`:

```c
/* ---- NVS helpers (cellular config) ---- */

/* Recommended buffer sizes for the load helper. */
#define MODEM_APN_MAX   64
#define MODEM_PIN_MAX   12

/*
 * Load cellular config from NVS namespace "vmflow", keys
 * "apn" / "sim_pin" / "lte_mode". Returns ESP_OK on success and fills
 * the outputs. Returns ESP_ERR_NVS_NOT_FOUND if either the namespace
 * does not exist yet OR the apn key is missing/empty (caller treats
 * both as "no cellular config saved"). Returns ESP_ERR_INVALID_ARG if
 * apn_out is NULL or apn_size is 0. pin_out and mode_out are optional.
 */
esp_err_t modem_nvs_load(char *apn_out, size_t apn_size,
                         char *pin_out, size_t pin_size,
                         modem_lte_mode_t *mode_out);

/*
 * Save cellular config to NVS. apn must be non-NULL and non-empty;
 * pin may be NULL or empty. Returns the underlying NVS error on
 * failure.
 */
esp_err_t modem_nvs_save(const char *apn, const char *pin, modem_lte_mode_t mode);
```

- [ ] **Step 2: Remove the internal forward-declaration block from `modem.c`**

Delete the block at the top of `modem.c` (currently around lines 50–55):

```c
/* === Internal API — promoted to modem.h in P3 ===================== */
esp_err_t modem_nvs_load(char *apn_out, size_t apn_size,
                         char *pin_out, size_t pin_size,
                         modem_lte_mode_t *mode_out);
esp_err_t modem_nvs_save(const char *apn, const char *pin, modem_lte_mode_t mode);
/* ================================================================== */
```

Also delete the `#define MODEM_APN_MAX 64` and `#define MODEM_PIN_MAX 12` lines and their preceding comment from `modem.c` — they're in `modem.h` now.

The implementations below (the actual `modem_nvs_load` and `modem_nvs_save` function bodies) stay unchanged.

- [ ] **Step 3: Remove the duplicate forward-declaration from `modem_test.c`**

In `modem_test.c`, delete:

```c
/* Forward-declared in modem.c (will move to modem.h in P3). */
esp_err_t modem_nvs_load(char *apn_out, size_t apn_size,
                         char *pin_out, size_t pin_size,
                         modem_lte_mode_t *mode_out);
```

`modem_test.c` already includes `modem.h` (where the prototype now lives) so nothing else needs to change. The file will be deleted entirely in Chunk 3 — we just clean up the duplicate now to keep the intermediate state consistent.

- [ ] **Step 4: Build with test flag OFF and ON**

```bash
. ~/esp/esp-idf/export.sh > /dev/null 2>&1 && cd /Users/lucienkerl/Development/mdb-esp32-cashless/mdb-slave-esp32s3 && idf.py build 2>&1 | tail -8
```

Expected: clean. Then toggle `CONFIG_CASHLESS_TEST_MODE_MODEM=y` in `sdkconfig` (one line edit), build again, restore to `# CONFIG_CASHLESS_TEST_MODE_MODEM is not set`. Both builds must succeed.

- [ ] **Step 5: Commit**

```bash
git add mdb-slave-esp32s3/main/modem.h \
        mdb-slave-esp32s3/main/modem.c \
        mdb-slave-esp32s3/main/modem_test.c
git commit -m "$(cat <<'EOF'
firmware(modem): promote modem_nvs_load/save to public modem.h API

Removes the "promoted to modem.h in P3" temporary forward-declaration
pattern from modem.c and modem_test.c, replaced with proper public
prototypes in modem.h. P1 code review flagged this as the next obvious
cleanup; P2 needs the helpers in network.c so doing it now removes the
duplicate-declaration smell before it propagates further.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Create network.h with the public API

**Files:**
- Create: `mdb-slave-esp32s3/main/network.h`

- [ ] **Step 1: Write the header in full**

```c
/*
 * VMflow.xyz
 *
 * network.h — Network manager public API
 *
 * Single source of truth for the device's uplink state. Owns WiFi
 * event handling, cellular probe/connect orchestration, SoftAP
 * lifecycle, and the boot-time branch between WiFi-only and cellular
 * variants. Consumers (mdb-slave-esp32s3.c, webui_server.c in P3)
 * never call esp_wifi_* or modem_* directly — everything goes through
 * this header.
 */

#ifndef NETWORK_H
#define NETWORK_H

#include <stdbool.h>
#include <stdint.h>
#include <esp_err.h>
#include "modem.h"

#ifdef __cplusplus
extern "C" {
#endif

/* High-level state machine. State transitions are driven by:
 *   - modem_probe outcome at boot (CELLULAR vs WIFI branch)
 *   - WIFI_EVENT / IP_EVENT (WiFi STA up/down)
 *   - NETIF_PPP_STATUS (PPP up/down)
 *   - explicit network_start_softap()/network_stop_softap() calls (P3) */
typedef enum {
    NETWORK_STATE_BOOTING        = 0,  /* network_init not yet called */
    NETWORK_STATE_OFFLINE        = 1,  /* initialised, no uplink */
    NETWORK_STATE_SOFTAP_ONLY    = 2,  /* setup mode, no uplink */
    NETWORK_STATE_WIFI_CONNECTING = 3,
    NETWORK_STATE_WIFI_UP        = 4,
    NETWORK_STATE_CELLULAR_REGISTERING = 5,
    NETWORK_STATE_CELLULAR_UP    = 6,
} network_state_t;

/* Snapshot of network state. Used by status MQTT payloads (P5) and
 * the captive portal /system/info endpoint (P3). All string fields
 * are NUL-terminated; empty string means "unknown". */
typedef struct {
    network_state_t state;
    bool            uplink_up;          /* shorthand for state == WIFI_UP || CELLULAR_UP */

    /* "wifi" | "cellular" | "none" — for human-readable display */
    char            uplink_kind[16];

    /* WiFi sub-state (always populated when WiFi STA is initialised; */
    /* zeroed on cellular-only boards where WiFi STA never came up) */
    bool            wifi_initialised;
    char            wifi_ssid[33];
    int8_t          wifi_rssi;
    char            wifi_ip[16];

    /* Cellular sub-state (populated when modem_probe returned true) */
    bool            modem_present;
    bool            cellular_registered;
    int8_t          cellular_rssi_dbm;
    char            cellular_operator[32];
    char            cellular_ip[16];
    modem_lte_mode_t cellular_mode;
} network_status_t;

/* Events delivered to the registered callback. Fired from the network
 * task context — keep handlers brief, post to a queue if non-trivial. */
typedef enum {
    NETWORK_EVENT_UPLINK_UP        = 0,  /* WiFi STA got IP, OR PPP got IP */
    NETWORK_EVENT_UPLINK_DOWN      = 1,  /* uplink lost */
    NETWORK_EVENT_SOFTAP_STARTED   = 2,
    NETWORK_EVENT_SOFTAP_STOPPED   = 3,
} network_event_t;

typedef void (*network_event_cb_t)(network_event_t event, void *user_data);

/* ---- Lifecycle ---- */

/*
 * Initialise the network manager. Probes for a SIM7080G modem and
 * branches:
 *   - Modem detected: cellular-only boot path. WiFi STA is NOT
 *     initialised. SoftAP comes up immediately so the user can enter
 *     APN/PIN/LTE-mode (and the provisioning code) via the captive
 *     portal in P3.
 *   - No modem: WiFi-only boot path. Behaves exactly like today's
 *     firmware — esp_wifi_init, esp_wifi_start, esp_wifi_connect.
 *     SoftAP comes up after WIFI_SOFTAP_AFTER failed connect attempts.
 *
 * Must be called exactly once, after nvs_flash_init,
 * esp_netif_init, and esp_event_loop_create_default.
 */
void network_init(void);

network_state_t network_get_state(void);

/* Refresh and return current network status. Cheap to call. */
void network_get_status(network_status_t *out);

/*
 * Register a single callback fired on uplink up/down + softap up/down.
 * Idempotent — a second call replaces the previous callback. Pass NULL
 * to unregister.
 */
void network_register_callback(network_event_cb_t cb, void *user_data);

/* SoftAP lifecycle — used by P3 wizard to keep the portal alive
 * until claim succeeds, and to bring it back up for recovery in P4. */
esp_err_t network_start_softap(void);
esp_err_t network_stop_softap(void);

/* ---- Captive-portal entry points (P3 wires these to HTTP handlers) ---- */

/*
 * Persist cellular config to NVS and trigger modem_init + modem_connect
 * in a background task. Returns immediately. Status is observable via
 * network_get_status() — caller (the captive portal poll loop) watches
 * for state transition to CELLULAR_UP.
 */
esp_err_t network_cellular_configure(const char *apn, const char *pin, modem_lte_mode_t mode);

/*
 * Persist WiFi credentials and trigger esp_wifi_connect. Returns
 * immediately. Status observable via network_get_status().
 */
esp_err_t network_wifi_configure(const char *ssid, const char *password);

#ifdef __cplusplus
}
#endif

#endif /* NETWORK_H */
```

- [ ] **Step 2: Verify the file is on disk**

```bash
test -f mdb-slave-esp32s3/main/network.h && wc -l mdb-slave-esp32s3/main/network.h
```

Expected: file exists, ~140 lines.

- [ ] **Step 3: Commit**

```bash
git add mdb-slave-esp32s3/main/network.h
git commit -m "$(cat <<'EOF'
firmware(network): public API header for network manager

Single-source-of-truth header for the cellular milestone's runtime
boot-flow decision. Defines network_state_t (BOOTING / OFFLINE /
SOFTAP_ONLY / WIFI_CONNECTING / WIFI_UP / CELLULAR_REGISTERING /
CELLULAR_UP), network_status_t (full snapshot for status payload +
captive portal), and the lifecycle/event/captive-portal entry-point
prototypes that the P2 implementation in network.c will satisfy.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Create network.c skeleton with stubs

**Files:**
- Create: `mdb-slave-esp32s3/main/network.c`
- Modify: `mdb-slave-esp32s3/main/CMakeLists.txt`

- [ ] **Step 1: Write the skeleton**

Create `mdb-slave-esp32s3/main/network.c` with:

```c
/*
 * VMflow.xyz
 *
 * network.c — Network manager implementation (skeleton; filled in
 *             across Chunk 2 + Chunk 3 of P2).
 */

#include "network.h"

#include <string.h>
#include <esp_log.h>
#include <esp_err.h>

#define TAG "network"

static network_state_t s_state = NETWORK_STATE_BOOTING;

/* All symbols below are stubs — real implementations land in C2/C3. */

void network_init(void) {
    ESP_LOGW(TAG, "network_init: stub — full implementation in P2 C2/C3");
}

network_state_t network_get_state(void) {
    return s_state;
}

void network_get_status(network_status_t *out) {
    if (!out) return;
    memset(out, 0, sizeof(*out));
    out->state = s_state;
    strcpy(out->uplink_kind, "none");
}

void network_register_callback(network_event_cb_t cb, void *user_data) {
    (void)cb; (void)user_data;
    ESP_LOGW(TAG, "network_register_callback: stub");
}

esp_err_t network_start_softap(void) {
    ESP_LOGW(TAG, "network_start_softap: stub returns ESP_OK");
    return ESP_OK;
}

esp_err_t network_stop_softap(void) {
    return ESP_OK;
}

esp_err_t network_cellular_configure(const char *apn, const char *pin, modem_lte_mode_t mode) {
    (void)apn; (void)pin; (void)mode;
    ESP_LOGW(TAG, "network_cellular_configure: stub returns ESP_ERR_NOT_SUPPORTED");
    return ESP_ERR_NOT_SUPPORTED;
}

esp_err_t network_wifi_configure(const char *ssid, const char *password) {
    (void)ssid; (void)password;
    ESP_LOGW(TAG, "network_wifi_configure: stub returns ESP_ERR_NOT_SUPPORTED");
    return ESP_ERR_NOT_SUPPORTED;
}
```

- [ ] **Step 2: Add `network.c` to CMakeLists srcs**

Edit `mdb-slave-esp32s3/main/CMakeLists.txt`. Add `network.c` to the `srcs` list (it currently lists `mdb-slave-esp32s3.c`, `webui_server.c`, `nimble.c`, `sale_queue.c`, `modem.c`, `modem_test.c`):

```cmake
set(srcs "mdb-slave-esp32s3.c"
        "webui_server.c"
        "nimble.c"
        "sale_queue.c"
        "modem.c"
        "modem_test.c"
        "network.c")
```

(`modem_test.c` will be removed in Chunk 3 — leave it for now.)

- [ ] **Step 3: Build with test flag OFF and ON**

Both must succeed. Network is dead code right now — linker should DCE it.

- [ ] **Step 4: Commit**

```bash
git add mdb-slave-esp32s3/main/network.c \
        mdb-slave-esp32s3/main/CMakeLists.txt
git commit -m "$(cat <<'EOF'
firmware(network): wire network.c skeleton into build

Stub implementations only — every public API logs "stub" and returns
the safe no-op value. The point of this commit is to lock the build
wiring before C2 starts moving real WiFi handler code from
mdb-slave-esp32s3.c into the new module.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Chunk 2: WiFi extraction (Tasks 4–7)

The big move. WiFi event handler, reconnect timer, and `app_main`'s WiFi initialisation block move out of `mdb-slave-esp32s3.c` and into `network.c`. The test-mode wrap stays during this chunk so we have a fallback if the refactor breaks something — Chunk 3 removes it.

After this chunk: production builds (test flag OFF) on a board with no modem still work end-to-end (WiFi connects, MQTT starts, sales publish). Cellular branch is still a stub.

### Task 4: Extract WiFi event handler into network.c

**Files:**
- Modify: `mdb-slave-esp32s3/main/network.c`

- [ ] **Step 1: Add the WiFi event handler + reconnect timer to network.c**

The current `wifi_event_handler` in `mdb-slave-esp32s3.c` (lines 2276–2440 — about 165 lines) must be moved verbatim into `network.c`, with these adjustments:

- Make it `static`
- Rename to `network_wifi_event_handler` (avoid name collision while extraction is in progress)
- Move the `wifi_retry_num`, `softap_active`, and `wifi_reconnect_timer` static state into `network.c`
- Move `wifi_reconnect_timer_cb` static helper into `network.c`
- Move the `WIFI_SOFTAP_AFTER` and `WIFI_RECONNECT_INTERVAL_SEC` macros into `network.c`
- The handler currently calls `start_softap()` and `start_dns_server()` — these are in `webui_server.c`, not in main.c, so they remain external symbols. `network.c` includes `webui_server.h` to access them.
- The handler calls `xTaskCreate(provision_claim_task, ...)` on `IP_EVENT_STA_GOT_IP` if a `prov_code` is in NVS — this is application logic that belongs in main.c. Replace this section with a callback fire (the registered network event callback receives `NETWORK_EVENT_UPLINK_UP` and main.c decides whether to spawn the claim task).
- The handler currently sets `mqtt_started = false` on disconnect and starts MQTT in `IP_EVENT_STA_GOT_IP` — these touch mqttClient symbols in main.c. Same treatment: fire the callback, let main.c handle MQTT lifecycle.

Concrete extraction strategy: read the source range first to be precise.

```bash
sed -n '2276,2440p' mdb-slave-esp32s3/main/mdb-slave-esp32s3.c
```

Then in `network.c`:

```c
#include <esp_wifi.h>
#include <esp_netif.h>
#include <esp_event.h>
#include <esp_timer.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <nvs.h>
#include "webui_server.h"

#define WIFI_SOFTAP_AFTER  5
#define WIFI_RECONNECT_INTERVAL_SEC 60

static int                  s_wifi_retry_num = 0;
static bool                 s_softap_active = false;
static esp_timer_handle_t   s_wifi_reconnect_timer = NULL;
static network_event_cb_t   s_event_cb = NULL;
static void                *s_event_user_data = NULL;

static void network_fire_event(network_event_t event) {
    if (s_event_cb) s_event_cb(event, s_event_user_data);
}

static void wifi_reconnect_timer_cb(void *arg) {
    ESP_LOGI(TAG, "WiFi reconnect timer: retrying esp_wifi_connect()");
    esp_wifi_connect();
}

static void network_wifi_event_handler(void *arg, esp_event_base_t event_base,
                                        int32_t event_id, void *event_data) {
    /* [PASTE the body of the existing wifi_event_handler here, with the
     *  three patches noted above:
     *    - any "mqtt_started = ..." or "esp_mqtt_client_*" refs become
     *      network_fire_event(NETWORK_EVENT_UPLINK_UP/DOWN) calls;
     *    - the "if (prov_code present) xTaskCreate(provision_claim_task,...)"
     *      block becomes network_fire_event(NETWORK_EVENT_UPLINK_UP) (main.c
     *      callback handles spawning provision_claim_task);
     *    - state transitions (s_state = NETWORK_STATE_*) added at the right
     *      points: WIFI_EVENT_STA_START → WIFI_CONNECTING; STA_DISCONNECTED →
     *      OFFLINE or SOFTAP_ONLY; IP_EVENT_STA_GOT_IP → WIFI_UP. ] */
}

void network_register_callback(network_event_cb_t cb, void *user_data) {
    s_event_cb = cb;
    s_event_user_data = user_data;
}
```

**Important:** during extraction, do NOT delete the original `wifi_event_handler` from `mdb-slave-esp32s3.c` yet — Task 5 does that. Keeping both versions in the build temporarily makes it impossible for the linker to be silently using the wrong one (it'll error on duplicate registration of WIFI_EVENT handlers if you try). The intermediate state is "code copied, not yet wired in `app_main`".

To make both versions coexist during extraction, the new handler in `network.c` is `static` (file-private) and is not yet registered with the event loop — the registration call moves over only in Task 6 along with the rest of `app_main`'s WiFi init.

- [ ] **Step 2: Build with test flag OFF**

```bash
. ~/esp/esp-idf/export.sh > /dev/null 2>&1 && cd /Users/lucienkerl/Development/mdb-esp32-cashless/mdb-slave-esp32s3 && idf.py build 2>&1 | tail -10
```

Expected: clean. There may be a "defined but not used" warning on `network_wifi_event_handler` — that's expected; it's wired up in Task 6.

- [ ] **Step 3: Commit**

```bash
git add mdb-slave-esp32s3/main/network.c
git commit -m "firmware(network): copy WiFi event handler + reconnect timer into network.c

Verbatim copy from mdb-slave-esp32s3.c, with the integration points
abstracted into network_fire_event() callbacks (so main.c retains
ownership of MQTT + provisioning task lifecycle). Not yet wired into
the event loop — that switch lands in Task 6 atomically with the
removal from main.c, so we can never have two handlers registered
simultaneously.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Implement network_init() WiFi-only path

**Files:**
- Modify: `mdb-slave-esp32s3/main/network.c`

- [ ] **Step 1: Replace the network_init stub with the WiFi-only branch**

For Chunk 2 we implement only the WiFi branch. The cellular branch is still a stub that does nothing (kicks in via Chunk 3).

```c
void network_init(void) {
    ESP_LOGI(TAG, "network_init: probing modem...");
    bool modem_present = modem_probe();
    ESP_LOGI(TAG, "modem_probe → %s", modem_present ? "true" : "false");

    if (modem_present) {
        /* Cellular branch lands in Chunk 3. For now, fall through to
         * WiFi to avoid leaving the device with no uplink during the
         * P2 transition. */
        ESP_LOGW(TAG, "cellular branch not yet implemented in P2 C2 — "
                      "falling through to WiFi for now");
    }

    /* WiFi-only branch — equivalent to today's app_main WiFi init. */
    s_state = NETWORK_STATE_WIFI_CONNECTING;

    esp_netif_create_default_wifi_sta();
    esp_netif_create_default_wifi_ap();

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    esp_wifi_init(&cfg);

    esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID,
                                         network_wifi_event_handler, NULL, NULL);
    esp_event_handler_instance_register(IP_EVENT, ESP_EVENT_ANY_ID,
                                         network_wifi_event_handler, NULL, NULL);

    esp_wifi_start();
    /* esp_wifi_connect() fires from inside the WIFI_EVENT_STA_START handler. */
}
```

- [ ] **Step 2: Build with test flag OFF and ON**

Both must succeed. The function is still not called from `app_main` — that wire-up is Task 6.

- [ ] **Step 3: Commit**

```bash
git add mdb-slave-esp32s3/main/network.c
git commit -m "firmware(network): implement network_init WiFi-only branch

Mirrors the existing app_main WiFi init: create STA+AP netifs,
esp_wifi_init, register the WiFi event handler (the one copied in from
main.c in Task 4), esp_wifi_start. modem_probe is called too, but the
cellular branch is intentionally a fall-through to WiFi until Chunk 3
wires up the real cellular boot path.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Wire app_main into network.c (the atomic switchover)

**Files:**
- Modify: `mdb-slave-esp32s3/main/mdb-slave-esp32s3.c`

This is the critical commit. Atomic switchover from inline WiFi handling to network.c.

- [ ] **Step 1: Identify the regions to remove from `mdb-slave-esp32s3.c`**

```bash
grep -n "^static int wifi_retry_num\|^static bool softap_active\|^static esp_timer_handle_t wifi_reconnect_timer\|^static void wifi_reconnect_timer_cb\|^#define WIFI_SOFTAP_AFTER\|^#define WIFI_RECONNECT_INTERVAL_SEC\|^static void wifi_event_handler" mdb-slave-esp32s3/main/mdb-slave-esp32s3.c
```

Expected matches (roughly):
- `#define WIFI_SOFTAP_AFTER` (line 77)
- `#define WIFI_RECONNECT_INTERVAL_SEC` (line 78)
- `static int wifi_retry_num` (line 80)
- `static bool softap_active` (line 81)
- `static esp_timer_handle_t wifi_reconnect_timer` (line 82)
- `static void wifi_reconnect_timer_cb` (line 84)
- `static void wifi_event_handler` (line 2276)

- [ ] **Step 2: Remove those regions and the WiFi init block in app_main**

In sequence:

1. Delete lines 77–87 (the macros, statics, and `wifi_reconnect_timer_cb`)
2. Delete the entire `wifi_event_handler` function (lines 2276–2440 today; verify exact bounds with `awk` — the function starts at the `static void wifi_event_handler(` line and ends at the matching closing `}` followed by a blank line)
3. In `app_main`, replace the WiFi init block (current lines 2569–2580 — `esp_netif_init`, `esp_event_loop_create_default`, `esp_netif_create_default_wifi_sta`, `_wifi_ap`, `esp_wifi_init`, both `esp_event_handler_instance_register` calls) with these two lines (keep `esp_netif_init` and `esp_event_loop_create_default` — those are general infrastructure that other things may depend on):

```c
    esp_netif_init();
    esp_event_loop_create_default();

    /* Network manager owns WiFi events, SoftAP lifecycle, modem probe,
     * and the boot-time cellular vs WiFi branch. */
    network_init();
    network_register_callback(network_event_cb, NULL);
```

4. Delete the `esp_wifi_start()` call further down (currently around line 2782) — `network_init()` does that now.

5. Add `#include "network.h"` at the top of the file (alongside the other includes).

6. Add the callback function `network_event_cb` somewhere appropriate (near the MQTT setup, e.g. just above `app_main`):

```c
static void network_event_cb(network_event_t event, void *user_data) {
    (void)user_data;
    switch (event) {
        case NETWORK_EVENT_UPLINK_UP:
            ESP_LOGI(TAG, "uplink up — starting MQTT + provisioning if needed");

            /* Spawn provision_claim_task if a prov_code is sitting in NVS
             * and we don't have a passkey yet (this is the first-boot
             * claim flow that today's wifi_event_handler also did). */
            {
                nvs_handle_t h;
                if (nvs_open("vmflow", NVS_READONLY, &h) == ESP_OK) {
                    char prov_code[16] = {0};
                    size_t s = sizeof(prov_code);
                    bool has_prov = (nvs_get_str(h, "prov_code", prov_code, &s) == ESP_OK
                                      && strlen(prov_code) > 0);
                    nvs_close(h);
                    if (has_prov && strlen(my_passkey) == 0) {
                        ESP_LOGI(TAG, "spawning provision_claim_task");
                        xTaskCreate(provision_claim_task, "prov_claim", 8192, NULL, 5, NULL);
                        return;  /* claim flow takes over; MQTT starts after claim+restart */
                    }
                }
            }

            /* Start MQTT (uses the existing setup logic; harmless to
             * call repeatedly because esp_mqtt_client_start handles
             * the already-started case internally). */
            if (!mqtt_started && mqttClient) {
                esp_mqtt_client_start(mqttClient);
            }
            break;

        case NETWORK_EVENT_UPLINK_DOWN:
            ESP_LOGW(TAG, "uplink down — MQTT will reconnect when uplink returns");
            /* Don't stop MQTT — its own reconnect logic handles the
             * transient outage. The MQTT watchdog covers the longer
             * outage case. */
            break;

        case NETWORK_EVENT_SOFTAP_STARTED:
        case NETWORK_EVENT_SOFTAP_STOPPED:
            /* No app-level action; portal is self-contained. */
            break;
    }
}
```

- [ ] **Step 3: Build with test flag OFF**

```bash
. ~/esp/esp-idf/export.sh > /dev/null 2>&1 && cd /Users/lucienkerl/Development/mdb-esp32-cashless/mdb-slave-esp32s3 && idf.py build 2>&1 | tail -20
```

Expected: clean. The single biggest behavioural risk in P2 lands here. If anything's wrong, the production build will likely fail to compile (missing symbols, duplicate registrations) rather than silently misbehave. Errors are usually obvious.

- [ ] **Step 4: Build with test flag ON**

Confirm the test path still compiles. The test main doesn't use network.c, so it shouldn't be affected.

- [ ] **Step 5: Commit**

```bash
git add mdb-slave-esp32s3/main/mdb-slave-esp32s3.c
git commit -m "$(cat <<'EOF'
firmware(network): switchover — main.c calls network_init, drops WiFi handler

Atomic switchover from inline WiFi handling in mdb-slave-esp32s3.c to
network.c orchestration. Removed:
- WIFI_SOFTAP_AFTER / WIFI_RECONNECT_INTERVAL_SEC macros (now in network.c)
- wifi_retry_num / softap_active / wifi_reconnect_timer statics
- wifi_reconnect_timer_cb callback
- wifi_event_handler (~165 lines) — replaced by network_wifi_event_handler in network.c
- Inline esp_netif_create_default_wifi_sta/ap, esp_wifi_init, both
  esp_event_handler_instance_register calls, esp_wifi_start

Added:
- #include "network.h"
- network_init() + network_register_callback(network_event_cb) calls
  in app_main
- network_event_cb() dispatcher that wires UPLINK_UP to either
  provision_claim_task (first-boot claim flow) OR esp_mqtt_client_start
  (steady state)

The behaviour for WiFi-only boards is preserved: same retry count
before SoftAP, same reconnect timer interval, same MQTT start on
GOT_IP, same provision_claim_task spawn on first-boot claim. Just
located in a different file.

Cellular branch in network.c is still a fall-through to WiFi at this
point — Chunk 3 turns it on.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Sanity-check WiFi-only path on a developer machine (no flash)

**Files:** none modified — verification step.

We can't flash hardware autonomously, but we can verify build artefact health and source-level invariants.

- [ ] **Step 1: Confirm only one WIFI_EVENT registration in the binary**

```bash
grep -rn "esp_event_handler_instance_register.*WIFI_EVENT\|esp_event_handler_instance_register.*IP_EVENT" mdb-slave-esp32s3/main/
```

Expected: exactly two matches, both in `network.c` (one for WIFI_EVENT, one for IP_EVENT). If you see any in `mdb-slave-esp32s3.c`, Task 6 step 2 was incomplete.

- [ ] **Step 2: Confirm the production binary still builds clean and is sized appropriately**

```bash
. ~/esp/esp-idf/export.sh > /dev/null 2>&1 && cd /Users/lucienkerl/Development/mdb-esp32-cashless/mdb-slave-esp32s3 && idf.py build 2>&1 | grep -E "Project build|warning|error" | tail -10
ls -la build/mdb-slave-esp32s3.bin
```

Expected: clean build, no errors. Binary size should be within ~10KB of the post-P1 size (~1430KB) — slight changes from refactoring but no big delta.

- [ ] **Step 3: Confirm `app_main` is materially smaller**

```bash
awk '/^void app_main/,/^}$/' mdb-slave-esp32s3/main/mdb-slave-esp32s3.c | wc -l
```

Expected: less than the post-P1 line count (~325). Should be down ~25 lines from removing the WiFi init block.

- [ ] **Step 4: Confirm `wifi_event_handler` is gone from main.c**

```bash
grep -n "static void wifi_event_handler\|wifi_event_handler(" mdb-slave-esp32s3/main/mdb-slave-esp32s3.c
```

Expected: empty output. (`network_wifi_event_handler` lives in network.c and is `static`, so it won't match this grep.)

- [ ] **Step 5: No commit** — this is a verification step.

---

## Chunk 3: Cellular branch + cleanup (Tasks 8–11)

The final chunk turns on the cellular boot path, removes the test-mode wrap, deletes `modem_test.c`, and cleans up the Kconfig. After this chunk, P2 is functionally complete — the production firmware is variant-aware at runtime.

### Task 8: Implement the cellular boot branch in network_init()

**Files:**
- Modify: `mdb-slave-esp32s3/main/network.c`

- [ ] **Step 1: Replace the "fall-through to WiFi" branch with the real cellular path**

In `network_init`, replace:

```c
    if (modem_present) {
        /* Cellular branch lands in Chunk 3. For now, fall through ... */
        ESP_LOGW(TAG, "cellular branch not yet implemented in P2 C2 — "
                      "falling through to WiFi for now");
    }
```

with:

```c
    if (modem_present) {
        ESP_LOGI(TAG, "cellular branch — WiFi STA will NOT be initialised");

        /* Bring up SoftAP only — the captive portal serves the
         * cellular config wizard (P3) so the user can enter APN/PIN.
         * P3 wires this; for now we still need SoftAP up so the user
         * has something to talk to. */
        esp_netif_create_default_wifi_ap();
        wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
        esp_wifi_init(&cfg);
        s_state = NETWORK_STATE_SOFTAP_ONLY;
        network_start_softap();

        /* If the user has previously saved an APN, kick off the
         * cellular bring-up in a background task. Otherwise wait
         * here for the captive portal (P3) to call
         * network_cellular_configure(). */
        char apn[MODEM_APN_MAX], pin[MODEM_PIN_MAX];
        modem_lte_mode_t mode;
        esp_err_t err = modem_nvs_load(apn, sizeof(apn), pin, sizeof(pin), &mode);
        if (err == ESP_OK) {
            ESP_LOGI(TAG, "APN found in NVS — starting cellular bring-up task");
            xTaskCreate(cellular_bring_up_task, "cell_up", 4096, NULL, 4, NULL);
        } else {
            ESP_LOGI(TAG, "no APN in NVS — waiting for captive portal config");
        }

        return;  /* DO NOT init WiFi STA on cellular boards */
    }
```

And add the `cellular_bring_up_task` static function above `network_init`:

```c
static void cellular_bring_up_task(void *arg) {
    (void)arg;
    char apn[MODEM_APN_MAX], pin[MODEM_PIN_MAX];
    modem_lte_mode_t mode;

    esp_err_t err = modem_nvs_load(apn, sizeof(apn), pin, sizeof(pin), &mode);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "cellular bring-up: no APN — task exiting");
        vTaskDelete(NULL);
        return;
    }

    s_state = NETWORK_STATE_CELLULAR_REGISTERING;

    err = modem_init(apn, pin, mode);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "modem_init failed: %s", esp_err_to_name(err));
        s_state = NETWORK_STATE_OFFLINE;
        vTaskDelete(NULL);
        return;
    }

    err = modem_connect();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "modem_connect failed: %s", esp_err_to_name(err));
        s_state = NETWORK_STATE_OFFLINE;
        vTaskDelete(NULL);
        return;
    }

    s_state = NETWORK_STATE_CELLULAR_UP;
    ESP_LOGI(TAG, "cellular up");
    network_fire_event(NETWORK_EVENT_UPLINK_UP);
    vTaskDelete(NULL);
}
```

Also: register a `NETIF_PPP_STATUS` event handler so we hear about PPP loss. Add this near the WiFi event handler registration:

```c
/* PPP status event handler — fires on NETIF_PPP_LOST_IP and friends.
 * For now we just log + transition state. P4 watchdog escalates. */
static void network_ppp_event_handler(void *arg, esp_event_base_t event_base,
                                       int32_t event_id, void *event_data) {
    if (event_base != IP_EVENT) return;
    if (event_id == IP_EVENT_PPP_GOT_IP) {
        ESP_LOGI(TAG, "PPP GOT_IP");
        /* state transition handled in cellular_bring_up_task — this
         * event is informational because esp_modem_set_mode(DATA)
         * already drives the PPP lifecycle synchronously. */
    } else if (event_id == IP_EVENT_PPP_LOST_IP) {
        ESP_LOGW(TAG, "PPP LOST_IP");
        if (s_state == NETWORK_STATE_CELLULAR_UP) {
            s_state = NETWORK_STATE_OFFLINE;
            network_fire_event(NETWORK_EVENT_UPLINK_DOWN);
        }
    }
}
```

Register the PPP handler unconditionally at network_init top (before the modem_probe call):

```c
    esp_event_handler_instance_register(IP_EVENT, IP_EVENT_PPP_GOT_IP,
                                         network_ppp_event_handler, NULL, NULL);
    esp_event_handler_instance_register(IP_EVENT, IP_EVENT_PPP_LOST_IP,
                                         network_ppp_event_handler, NULL, NULL);
```

Implement `network_cellular_configure`:

```c
esp_err_t network_cellular_configure(const char *apn, const char *pin, modem_lte_mode_t mode) {
    esp_err_t err = modem_nvs_save(apn, pin, mode);
    if (err != ESP_OK) return err;
    /* Spawn the bring-up task — same one network_init uses. */
    xTaskCreate(cellular_bring_up_task, "cell_up", 4096, NULL, 4, NULL);
    return ESP_OK;
}
```

- [ ] **Step 2: Implement `network_get_status` properly**

Replace the stub. Include WiFi state from `esp_wifi_get_config` + `esp_netif_get_ip_info` for the WiFi netif if STA is up; cellular state from `modem_status()`.

```c
void network_get_status(network_status_t *out) {
    if (!out) return;
    memset(out, 0, sizeof(*out));
    out->state = s_state;
    out->uplink_up = (s_state == NETWORK_STATE_WIFI_UP || s_state == NETWORK_STATE_CELLULAR_UP);

    if (s_state == NETWORK_STATE_WIFI_UP) strcpy(out->uplink_kind, "wifi");
    else if (s_state == NETWORK_STATE_CELLULAR_UP) strcpy(out->uplink_kind, "cellular");
    else strcpy(out->uplink_kind, "none");

    /* WiFi block — populated when WiFi STA is initialised */
    wifi_config_t wcfg = {0};
    if (esp_wifi_get_config(WIFI_IF_STA, &wcfg) == ESP_OK && wcfg.sta.ssid[0] != 0) {
        out->wifi_initialised = true;
        strncpy(out->wifi_ssid, (const char *)wcfg.sta.ssid, sizeof(out->wifi_ssid) - 1);

        wifi_ap_record_t ap = {0};
        if (esp_wifi_sta_get_ap_info(&ap) == ESP_OK) {
            out->wifi_rssi = ap.rssi;
        }

        esp_netif_t *sta = esp_netif_get_handle_from_ifkey("WIFI_STA_DEF");
        if (sta) {
            esp_netif_ip_info_t ip_info;
            if (esp_netif_get_ip_info(sta, &ip_info) == ESP_OK && ip_info.ip.addr != 0) {
                esp_ip4addr_ntoa(&ip_info.ip, out->wifi_ip, sizeof(out->wifi_ip));
            }
        }
    }

    /* Cellular block — populated only if modem was detected */
    if (s_state == NETWORK_STATE_CELLULAR_REGISTERING ||
        s_state == NETWORK_STATE_CELLULAR_UP ||
        s_state == NETWORK_STATE_SOFTAP_ONLY) {
        modem_status_t ms;
        modem_status(&ms);
        out->modem_present       = true;
        out->cellular_registered = ms.registered;
        out->cellular_rssi_dbm   = ms.rssi_dbm;
        strncpy(out->cellular_operator, ms.operator_name, sizeof(out->cellular_operator) - 1);
        strncpy(out->cellular_ip, ms.ip, sizeof(out->cellular_ip) - 1);
        out->cellular_mode       = ms.active_mode;
    }
}
```

- [ ] **Step 3: Build OFF and ON**

Both must succeed.

- [ ] **Step 4: Commit**

```bash
git add mdb-slave-esp32s3/main/network.c
git commit -m "$(cat <<'EOF'
firmware(network): cellular boot branch + status reporting

Replaces the Chunk-2 fall-through with the real cellular path:

- On boards where modem_probe returns true, WiFi STA is NOT initialised
- SoftAP comes up immediately (so the captive portal can configure APN
  in P3)
- If an APN is already in NVS (post-claim reboot, or pre-configured
  device), spawn cellular_bring_up_task which runs modem_init +
  modem_connect and fires NETWORK_EVENT_UPLINK_UP on success
- network_cellular_configure (called from the P3 captive portal) takes
  the same path
- Register a PPP status event handler that maps NETIF_PPP_LOST_IP to
  NETWORK_EVENT_UPLINK_DOWN; the existing MQTT reconnect logic in
  main.c handles the transient outage. P4 watchdog adds power-cycle
  recovery
- network_get_status populated for both WiFi (esp_wifi_sta_get_ap_info)
  and cellular (modem_status) cases

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Remove modem_test.c and the test-mode Kconfig wrap

**Files:**
- Delete: `mdb-slave-esp32s3/main/modem_test.c`
- Modify: `mdb-slave-esp32s3/main/CMakeLists.txt`
- Modify: `mdb-slave-esp32s3/main/Kconfig.projbuild`
- Modify: `mdb-slave-esp32s3/main/mdb-slave-esp32s3.c`
- Modify: `mdb-slave-esp32s3/sdkconfig` (working tree only — do NOT commit)

The production boot path now does the same thing modem_test.c did, just for real. Time to retire the validation harness.

- [ ] **Step 1: Delete the file**

```bash
git rm mdb-slave-esp32s3/main/modem_test.c
```

- [ ] **Step 2: Remove from CMakeLists srcs**

Edit `mdb-slave-esp32s3/main/CMakeLists.txt`. Remove `"modem_test.c"` from the `srcs` list.

- [ ] **Step 3: Remove the CASHLESS_TEST_MODE_MODEM Kconfig option**

Edit `mdb-slave-esp32s3/main/Kconfig.projbuild`. Delete the `config CASHLESS_TEST_MODE_MODEM` block (lines added in P1 Task 2). Keep the rest of the SIM7080G menu (`SIM7080G_APN`, `SIM7080G_CMNB`, the LTE-mode choice).

- [ ] **Step 4: Remove the `#if !CONFIG_CASHLESS_TEST_MODE_MODEM` wrap from mdb-slave-esp32s3.c**

Delete the `#if !CONFIG_CASHLESS_TEST_MODE_MODEM` line right above `void app_main(void) {` and the matching `#endif /* !CONFIG_CASHLESS_TEST_MODE_MODEM */` at the very end of the file. The production app_main is no longer optional — it is THE app_main.

- [ ] **Step 5: Manually clean stale Kconfig refs from sdkconfig**

```bash
grep -n CASHLESS_TEST_MODE_MODEM mdb-slave-esp32s3/sdkconfig
```

If any line matches, edit `sdkconfig` to remove the line. Then run `idf.py reconfigure` to regenerate the file cleanly. (The sdkconfig change is NOT committed — it's a per-checkout build artefact.)

- [ ] **Step 6: Build (only one build configuration now — the test mode no longer exists)**

```bash
. ~/esp/esp-idf/export.sh > /dev/null 2>&1 && cd /Users/lucienkerl/Development/mdb-esp32-cashless/mdb-slave-esp32s3 && idf.py build 2>&1 | tail -10
```

Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add mdb-slave-esp32s3/main/CMakeLists.txt \
        mdb-slave-esp32s3/main/Kconfig.projbuild \
        mdb-slave-esp32s3/main/mdb-slave-esp32s3.c
git commit -m "$(cat <<'EOF'
firmware(network): retire modem_test.c + CASHLESS_TEST_MODE_MODEM

The P1 validation harness lived behind a Kconfig flag because P1 didn't
yet integrate modem.c into the production boot path. P2 fixes that: the
real app_main now runs modem_probe via network_init, exercises modem_init
+ modem_connect via cellular_bring_up_task, and reports state via
modem_status. The test main is redundant.

Removed:
- mdb-slave-esp32s3/main/modem_test.c (deleted)
- modem_test.c from CMakeLists srcs
- CASHLESS_TEST_MODE_MODEM Kconfig option
- #if !CONFIG_CASHLESS_TEST_MODE_MODEM wrap around app_main

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: Update CLAUDE.md to reflect P2 wiring

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Replace the P1 Cellular driver paragraph**

Find the paragraph added in P1 Task 14 (`**Cellular driver (modem.c / modem.h)**:`). Replace it with:

```markdown
**Network manager (`network.c` / `network.h`)**: Single orchestrator for
the device's uplink. At boot, `network_init()` calls `modem_probe()` and
branches:
- **Modem detected** → cellular-only boot. WiFi STA is NOT initialised.
  SoftAP comes up immediately. If an APN is in NVS (post-claim or
  pre-configured), `cellular_bring_up_task` runs `modem_init` +
  `modem_connect`. P3 captive portal calls `network_cellular_configure`
  with new credentials.
- **No modem** → WiFi-only boot. Behaviour identical to the pre-P2
  firmware: `esp_wifi_init` + STA/AP netifs + `esp_wifi_start`. SoftAP
  comes up after `WIFI_SOFTAP_AFTER` failed connect attempts.

`mdb-slave-esp32s3.c` registers a single callback via
`network_register_callback` that fires on `NETWORK_EVENT_UPLINK_UP` —
the callback either spawns `provision_claim_task` (first-boot claim
flow) or starts the MQTT client. The pre-P2 inline `wifi_event_handler`
(~165 lines) was extracted into `network.c`.

**Cellular driver (`modem.c` / `modem.h`)**: SIM7080G driver introduced
in P1. Public API: `modem_probe`, `modem_init`, `modem_connect`,
`modem_disconnect`, `modem_status`, `modem_power_cycle`, plus NVS
helpers `modem_nvs_load`/`modem_nvs_save` (promoted to the public API
in P2). All callers now go through `network.c` — no part of `app_main`
touches `esp_modem_*` directly.
```

- [ ] **Step 2: Build (sanity)**

```bash
. ~/esp/esp-idf/export.sh > /dev/null 2>&1 && cd /Users/lucienkerl/Development/mdb-esp32-cashless/mdb-slave-esp32s3 && idf.py build 2>&1 | tail -5
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "firmware(network): document network manager in CLAUDE.md (P2)"
```

---

### Task 11: P2 Hardware acceptance — DEFERRED to user testing

This is the gate that proves the spec's R1 (no production regression) is met.

**The autonomous executor cannot run this task.** It requires physical access to:
- A current production WiFi-only board (to verify behaviour-identical regression)
- A LilyGo T-SIM7080G-S3 board with a SIM card and antenna (to verify cellular path comes up)
- Serial monitor + flash tooling (`idf.py -p /dev/cu.usbmodem... flash monitor`)

Document the deferral in this task before declaring P2 complete:

- [ ] **Acceptance test 1 — WiFi-only regression (CRITICAL)**

Flash post-P2 firmware on a current production WiFi-only board.

Expected behaviour (must be identical to today):
- WiFi connects to saved credentials within 30 s
- MQTT broker reachable, sales publish
- If WiFi fails 5×, SoftAP comes up
- Provisioning flow works on first boot (prov_code in NVS → claim → reboot → MQTT)

If anything is observably different from today's firmware: revert to `5a07b1d` (post-P1) and investigate.

- [ ] **Acceptance test 2 — Cellular boot on LilyGo (assuming pin defines match)**

Flash post-P2 firmware on the LilyGo T-SIM7080G-S3 board. Pre-populate NVS with an APN by either:
- Running `esp-idf-monitor` and using the NVS partition tool to set `vmflow.apn` = `<your APN>`, OR
- Waiting for P3 captive portal to land

Expected behaviour:
- `network_init: probing modem... → true`
- `cellular branch — WiFi STA will NOT be initialised`
- SoftAP comes up
- `cellular_bring_up_task` starts, registration completes within 60 s
- `cellular up`, `NETWORK_EVENT_UPLINK_UP` fires
- MQTT starts, sales publish via PPP

If `modem_probe` returns false on LilyGo: see P1 Task 1 — the pin defines need to be updated to match the LilyGo board's actual pinout.

- [ ] **Acceptance test 3 — No-APN cellular boot (sanity)**

Flash post-P2 firmware on the LilyGo board with no APN in NVS.

Expected: device boots into `NETWORK_STATE_SOFTAP_ONLY`, modem_init is NOT called, no cellular registration attempt is made until P3's captive portal calls `network_cellular_configure`. Device sits in SoftAP indefinitely waiting for config.

---

## P2 Definition of Done — checklist for the finishing reviewer

**Spec-derived (load-bearing):**

- [ ] On a board where `modem_probe()` returns false, post-P2 boot behaviour is functionally identical to pre-P2 (Acceptance test 1 — deferred to user). *(Spec R1 — non-negotiable.)*
- [ ] On the LilyGo, `network_init` calls `modem_probe` (true), skips WiFi STA init, brings up SoftAP, and (if APN in NVS) starts cellular registration within 60 s (Acceptance test 2 — deferred to user). *(Spec §2 boot flow.)*
- [ ] `mdb-slave-esp32s3.c` no longer registers any `WIFI_EVENT` or `IP_EVENT` handler directly — the only registrations are inside `network.c`. (Verifiable by grep without hardware.)
- [ ] `wifi_event_handler` and the WiFi reconnect timer + retry counter are gone from `mdb-slave-esp32s3.c`.
- [ ] `modem_test.c` deleted; `CASHLESS_TEST_MODE_MODEM` Kconfig deleted; `#if !CONFIG_CASHLESS_TEST_MODE_MODEM` wrap removed from `mdb-slave-esp32s3.c`.
- [ ] `idf.py build` succeeds with no warnings beyond pre-existing ones.

**Plan-internal:**

- [ ] `network.c` is ≤ ~600 lines. If larger, the SoftAP/DNS lifecycle is a candidate for extraction in P3.
- [ ] `network.h` API surface looks clean: enums, struct, lifecycle, single callback, captive-portal entry points. No esp_wifi_/esp_modem_ types leak.
- [ ] `mdb-slave-esp32s3.c` shrinks net by ~150–200 lines.

When the verifiable items are green and the user has run Acceptance tests 1+2: P2 is done. Tag `milestone/cellular-p2`.
