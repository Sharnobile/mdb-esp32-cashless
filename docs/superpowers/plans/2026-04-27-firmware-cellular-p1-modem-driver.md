# Firmware Cellular P1 — Modem Driver Foundation

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land a self-contained `modem.c` / `modem.h` SIM7080G driver in `mdb-slave-esp32s3/main/` with `probe → init → connect → status → disconnect → power_cycle`, validated end-to-end on a LilyGo T-SIM7080G board (modem detected, PPP up, AT round-trip works) and proven side-effect-free on an existing WiFi-only production board (probe returns false, GPIO 14 quiescent state untouched).

**Architecture:** New module `modem.c` / `modem.h`, no integration with `mdb-slave-esp32s3.c` yet (that's P2 via the network manager). For P1 validation, a temporary `modem_test.c` ships behind a Kconfig flag `CASHLESS_TEST_MODE_MODEM` that swaps in a tiny `app_main` exercising the driver. Touch nothing in the production boot path so the change is a pure no-op for installed devices when the flag is off.

**Tech Stack:** ESP-IDF v5.x, `espressif/esp_modem` v2.x (already in `idf_component.yml`), FreeRTOS, NVS, SIM7080G via UART2 at 115200 baud.

**Spec reference:** [docs/superpowers/specs/2026-04-27-firmware-cellular-network-design.md](../specs/2026-04-27-firmware-cellular-network-design.md) — see §1 (Module structure), §4 (NVS keys), §5 (Power-cycle), and the P1 line item under "Phasing".

**Position in milestone:** This is **Phase 1 of 6**. P2 (network manager), P3 (captive portal wizard), P4 (recovery / watchdog), P5 (backend telemetry), P6 (field validation) will each get their own plan file when they begin — written *after* P1 ships, because P2's API surface depends on what `modem.h` actually settles on after empirical hardware validation here.

---

## File Structure

P1 introduces three new files and modifies four existing files:

- **Create:** `mdb-slave-esp32s3/main/modem.h` — public API (types, constants, function signatures). Single responsibility: declare what `modem.c` exposes.
- **Create:** `mdb-slave-esp32s3/main/modem.c` — driver implementation. Single responsibility: SIM7080G lifecycle (probe, init, connect, disconnect, status, power_cycle). No NVS reads beyond `apn`/`sim_pin`/`lte_mode`. No MQTT, no event loop coupling. No watchdog task yet (P4).
- **Create:** `mdb-slave-esp32s3/main/modem_test.c` — temporary P1-only validation entry point. Single responsibility: call `modem_*` in sequence and log results to serial. Removed during P2 once the network manager assumes the same job. Kept behind `#if CONFIG_CASHLESS_TEST_MODE_MODEM`.

- **Modify:** `mdb-slave-esp32s3/main/CMakeLists.txt` — add the three new files to `srcs`.
- **Modify:** `mdb-slave-esp32s3/main/Kconfig.projbuild` — add `SIM7080G` menu (APN default, LTE mode choice) and a `CASHLESS_TEST_MODE_MODEM` boolean. Mirrors the structure that lived briefly in commit `d3f8b05`.
- **Modify:** `mdb-slave-esp32s3/main/mdb-slave-esp32s3.c` — wrap the existing `app_main` definition in `#if !CONFIG_CASHLESS_TEST_MODE_MODEM` so the test entry point can take over cleanly. *No other change.*
- **Modify:** `mdb-slave-esp32s3/main/idf_component.yml` — already declares `espressif/esp_modem: ^2.0.0`. Confirm version is current; bump if out of date.

`modem.h` and `modem.c` are designed to fit inside ~120 + ~400 lines respectively. If either grows materially past that, the boundaries should be revisited (most likely candidate: extracting the AT-command helpers into a separate `modem_at.c` if they become non-trivial).

---

## Chunk 1: Foundation (Tasks 1–5)

Hardware verification, Kconfig, public header, driver skeleton, NVS helpers. This chunk produces a buildable but no-op driver — every public function is stubbed out with sensible defaults. The point is to lock down the API surface and the build wiring before risking any real hardware code.

### Task 1: Confirm hardware pinout on the user's LilyGo board

**Why first:** The current `PIN_SIM7080G_*` defines in `mdb-slave-esp32s3.c` (RX=18, TX=17, PWR=14) were inherited from Leonardo's custom-PCB attempt in `d3f8b05`. The standard LilyGo T-SIM7080G ESP32-S3 may use different pins — verifying this *before* writing any driver code prevents writing a driver that doesn't match the actual board.

**Files:**
- Read: `mdb-slave-esp32s3/main/mdb-slave-esp32s3.c:56-58` (current pin defines)

- [ ] **Step 1: Identify which exact LilyGo board variant is in hand**

The user said "LilyGo ESP32-S3 Board mit SIM7080G Modul". Most likely candidate: **LilyGo T-SIM7080G-S3** (the ESP32-S3 + SIM7080G combo). Other possibilities: T-SIM7080-S3-Cat-M (only LTE-M variant), or a custom carrier board.

Ask the user to confirm the exact model name printed on the silkscreen, or check the LilyGo product link they ordered from. Document the answer in this task before proceeding.

**Autonomous-executor fallback:** If no user is available within 5 minutes to answer, default to the LilyGo T-SIM7080G-S3 standard pinout (`MODEM_TX=GPIO_4`, `MODEM_RX=GPIO_5`, `MODEM_PWRKEY=GPIO_41`) and **explicitly note in this task that the assumption was made unverified**. The hardware acceptance Tasks 12 and 13 will catch any pinout mismatch — a wrong assumption shows up as `modem_probe → FALSE` on real LilyGo hardware, which is recoverable.

- [ ] **Step 2: Look up the official pinout for that variant**

The authoritative source is the LilyGo GitHub repo for the board:
- T-SIM7080G-S3: <https://github.com/Xinyuan-LilyGO/LilyGo-T-SIM7080G-S3>

Cross-reference the schematic PDF against these signals:
- `MODEM_TX` (ESP32-S3 → SIM7080G UART RX)
- `MODEM_RX` (SIM7080G TX → ESP32-S3)
- `MODEM_PWRKEY` (active-LOW power-on pulse)
- `MODEM_DTR` (sleep control, optional for P1)
- `MODEM_RST` (hard reset, optional for P1)
- Any inverting transistor on PWRKEY (Leonardo's custom PCB has one; LilyGo typically does *not*)

Record findings in this section of the plan as a small table.

- [ ] **Step 3: Decide whether to update pin defines or keep them**

Two outcomes:

**Outcome A — pins match (RX=18, TX=17, PWR=14, no transistor):** No code change. Move on to Task 2. Note the PWRKEY polarity (likely active-LOW directly, *not* inverted via transistor) — this affects the power-cycle code in Task 8.

**Outcome B — pins differ:** Update the three `#define PIN_SIM7080G_*` lines in `mdb-slave-esp32s3.c:56-58` to match the LilyGo schematic. Commit the change as a separate atomic commit before continuing:

```bash
git add mdb-slave-esp32s3/main/mdb-slave-esp32s3.c
git commit -m "firmware(modem): align SIM7080G pin defines with LilyGo T-SIM7080G-S3 schematic"
```

- [ ] **Step 4: Record the PWRKEY polarity decision in this plan**

Edit this task's section to add a one-line note: *"PWRKEY polarity: active-LOW direct"* OR *"PWRKEY polarity: active-LOW via inverting transistor (GPIO high → PWRKEY low)"*. This drives the implementation in Task 8.

> **Pinout assumption (autonomous executor, 2026-04-26):** kept existing defines (RX=18, TX=17, PWR=14) from Leonardo's d3f8b05; PWRKEY polarity assumed direct active-LOW (LilyGo standard). Awaits user verification during Task 12 hardware acceptance.

---

### Task 2: Add Kconfig options for SIM7080G

**Files:**
- Modify: `mdb-slave-esp32s3/main/Kconfig.projbuild`

- [ ] **Step 1: Add the `SIM7080G` menu and `CASHLESS_TEST_MODE_MODEM` flag**

Append the following to `mdb-slave-esp32s3/main/Kconfig.projbuild`, *after* the existing `endmenu # MDB Cashless Device` line. The menu structure mirrors the one that lived briefly in `d3f8b05`, plus the new test-mode flag:

```kconfig

menu "SIM7080G"

    choice
        prompt "LTE Network Mode"
        default SIM7080G_CMNB_BOTH

        config SIM7080G_CMNB_CATM
            bool "Cat-M only"

        config SIM7080G_CMNB_NBIOT
            bool "NB-IoT only"

        config SIM7080G_CMNB_BOTH
            bool "Both (LTE-M + NB-IoT)"

    endchoice

    config SIM7080G_CMNB
        int
        default 1 if SIM7080G_CMNB_CATM
        default 2 if SIM7080G_CMNB_NBIOT
        default 3 if SIM7080G_CMNB_BOTH

    config SIM7080G_APN
        string "Default APN (compile-time fallback)"
        default "internet"
        help
            Default APN baked into the binary. The captive portal in P3
            allows runtime override; this value is only used if no APN is
            saved in NVS.

    config CASHLESS_TEST_MODE_MODEM
        bool "Run modem test main instead of full firmware (P1 validation)"
        default n
        help
            When enabled, app_main() is replaced by modem_test_main()
            which exercises modem_probe / init / connect / status and
            logs results. Used for P1 hardware validation only — must
            be turned off for production builds.

endmenu # SIM7080G
```

- [ ] **Step 2: Build to confirm Kconfig syntax**

```bash
. $IDF_PATH/export.sh
cd mdb-slave-esp32s3
idf.py reconfigure
```

Expected: Reconfigure succeeds. The new Kconfig options appear when running `idf.py menuconfig` under a top-level "SIM7080G" menu.

If `IDF_PATH` is not set, source the user's preferred ESP-IDF activation script first.

- [ ] **Step 3: Commit**

```bash
git add mdb-slave-esp32s3/main/Kconfig.projbuild
git commit -m "firmware(modem): add SIM7080G Kconfig menu + P1 test-mode flag"
```

---

### Task 3: Create modem.h with full public API

**Files:**
- Create: `mdb-slave-esp32s3/main/modem.h`

- [ ] **Step 1: Write the header in full**

Create `mdb-slave-esp32s3/main/modem.h` with this exact content:

```c
/*
 * VMflow.xyz
 *
 * modem.h — SIM7080G driver public API
 *
 * Single source of truth for the cellular modem lifecycle. Consumers
 * (network.c in P2, webui_server.c in P3) interact with the modem only
 * through this header — no esp_modem_* symbols leak.
 */

#ifndef MODEM_H
#define MODEM_H

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <esp_err.h>

#ifdef __cplusplus
extern "C" {
#endif

/* LTE network mode encoding — matches AT+CMNB and SIM7080G_CMNB Kconfig. */
typedef enum {
    MODEM_LTE_MODE_CATM  = 1,
    MODEM_LTE_MODE_NBIOT = 2,
    MODEM_LTE_MODE_BOTH  = 3,
} modem_lte_mode_t;

/* Snapshot of modem state. All fields are best-effort; consumers must
 * tolerate empty strings and rssi_dbm == 0 (means "unknown"). */
typedef struct {
    bool                registered;       /* AT+CEREG stat 1 (home) or 5 (roaming) */
    int8_t              rssi_dbm;         /* derived from AT+CSQ; 0 = unknown */
    char                operator_name[32];/* e.g. "Vodafone DE"; empty if unknown */
    char                ip[16];           /* PPP-assigned IPv4 dotted; empty if no PPP */
    modem_lte_mode_t    active_mode;      /* what the modem actually negotiated */
} modem_status_t;

/* ---- Lifecycle ---- */

/*
 * Detect whether a SIM7080G is wired and responsive.
 *
 * Sequence (safe on boards without a modem):
 *   1. Configure UART2 at 115200, GPIOs RX/TX/PWR per Kconfig pin defaults.
 *   2. Read PWRKEY GPIO quiescent state — must match modem-attached pattern.
 *   3. Try esp_modem_sync() (modem may already be on after warm reset).
 *   4. If fail: switch to ESP_MODEM_MODE_COMMAND (PPP escape), retry sync.
 *   5. If still fail AND quiescent state is modem-attached: power_pulse, retry.
 *   6. Returns true only if AT sync succeeds; false otherwise.
 *
 * Total worst-case duration: ~10 s. Quick path (modem absent + GPIO check
 * fails): <500 ms.
 *
 * Idempotent — safe to call multiple times. Does NOT enable any cellular
 * function (CFUN stays at whatever the modem booted with).
 */
bool modem_probe(void);

/*
 * Configure the modem with credentials and prepare for network attach.
 * Must be called after a successful modem_probe(). Does not establish
 * PPP — call modem_connect() for that.
 *
 * `apn` is required (non-NULL, non-empty). `pin` may be NULL or empty
 * (no PIN). `mode` selects LTE-M / NB-IoT / both.
 */
esp_err_t modem_init(const char *apn, const char *pin, modem_lte_mode_t mode);

/*
 * Bring the modem online: enable RF (CFUN=1), wait for network
 * registration (AT+CEREG, up to 60 s), switch to PPP data mode. On
 * success, the PPP netif becomes the default route.
 */
esp_err_t modem_connect(void);

/*
 * Tear down the PPP link cleanly and return to AT command mode. Safe
 * to call even if PPP is not currently active.
 */
esp_err_t modem_disconnect(void);

/*
 * Hard power-cycle the modem: assert PWRKEY for 1.2 s, wait 5 s for
 * boot. Used by the recovery layer (P4) when AT sync stops responding.
 * Caller should re-init/re-connect afterwards.
 */
void modem_power_cycle(void);

/*
 * Refresh and return current modem status. Cheap to call (issues
 * AT+CSQ, AT+CEREG?, AT+COPS?). Times out fast (<3 s).
 */
void modem_status(modem_status_t *out);

#ifdef __cplusplus
}
#endif

#endif /* MODEM_H */
```

- [ ] **Step 2: Build to confirm header is syntactically clean**

The header alone won't trigger a compile until something includes it. We check the syntax indirectly via the next task. For now just confirm the file is on disk:

```bash
test -f mdb-slave-esp32s3/main/modem.h && echo "header exists"
```

Expected output: `header exists`.

- [ ] **Step 3: Commit**

```bash
git add mdb-slave-esp32s3/main/modem.h
git commit -m "firmware(modem): public API header for SIM7080G driver"
```

---

### Task 4: Create modem.c skeleton with stubs and wire into build

**Files:**
- Create: `mdb-slave-esp32s3/main/modem.c`
- Modify: `mdb-slave-esp32s3/main/CMakeLists.txt`

- [ ] **Step 1: Write a stubbed `modem.c` that compiles but does nothing**

Create `mdb-slave-esp32s3/main/modem.c` with the skeleton only — every function returns the safe "no-op" value. We fill them in across Tasks 6-10. The skeleton lets us verify the file is properly registered in the build system before risking real driver code.

```c
/*
 * VMflow.xyz
 *
 * modem.c — SIM7080G driver implementation
 */

#include "modem.h"

#include <string.h>
#include <esp_log.h>
#include <esp_err.h>

#define TAG "modem"

bool modem_probe(void) {
    ESP_LOGW(TAG, "modem_probe: stub returns false");
    return false;
}

esp_err_t modem_init(const char *apn, const char *pin, modem_lte_mode_t mode) {
    (void)apn; (void)pin; (void)mode;
    ESP_LOGW(TAG, "modem_init: stub returns ESP_ERR_NOT_SUPPORTED");
    return ESP_ERR_NOT_SUPPORTED;
}

esp_err_t modem_connect(void) {
    ESP_LOGW(TAG, "modem_connect: stub returns ESP_ERR_NOT_SUPPORTED");
    return ESP_ERR_NOT_SUPPORTED;
}

esp_err_t modem_disconnect(void) {
    ESP_LOGW(TAG, "modem_disconnect: stub returns ESP_OK (no-op)");
    return ESP_OK;
}

void modem_power_cycle(void) {
    ESP_LOGW(TAG, "modem_power_cycle: stub does nothing");
}

void modem_status(modem_status_t *out) {
    if (!out) return;
    memset(out, 0, sizeof(*out));
    out->active_mode = MODEM_LTE_MODE_BOTH;
}
```

- [ ] **Step 2: Add `modem.c` and `modem_test.c` to the CMakeLists srcs**

Edit `mdb-slave-esp32s3/main/CMakeLists.txt`. The current `srcs` block looks like:

```cmake
set(srcs "mdb-slave-esp32s3.c"
        "webui_server.c"
        "nimble.c"
        "sale_queue.c")
```

Replace with:

```cmake
set(srcs "mdb-slave-esp32s3.c"
        "webui_server.c"
        "nimble.c"
        "sale_queue.c"
        "modem.c"
        "modem_test.c")
```

Also extend the `REQUIRES` list — `esp_modem` and `esp_netif` need to be listed explicitly so the build picks up the managed component. The current `REQUIRES` line:

```cmake
REQUIRES esp_wifi esp_http_client esp_http_server esp-tls mbedtls
         mqtt driver nvs_flash lwip esp_adc json bt
         app_update esp_https_ota
```

Add `esp_modem esp_netif`:

```cmake
REQUIRES esp_wifi esp_http_client esp_http_server esp-tls mbedtls
         mqtt driver nvs_flash lwip esp_adc json bt
         app_update esp_https_ota esp_modem esp_netif
```

- [ ] **Step 3: Create a placeholder `modem_test.c` so the build doesn't fail**

Task 11 fills in the real test main. For now create an empty stub so the CMake `srcs` reference resolves:

```c
/*
 * VMflow.xyz
 *
 * modem_test.c — P1 validation entry point (placeholder; filled in Task 11)
 */

#include "sdkconfig.h"

#if CONFIG_CASHLESS_TEST_MODE_MODEM
/* Real test main lives here after Task 11. */
#endif
```

- [ ] **Step 4: Build to confirm everything links**

```bash
. $IDF_PATH/export.sh
cd mdb-slave-esp32s3
idf.py build 2>&1 | tail -40
```

Expected: build succeeds. If `esp_modem.h` or `esp_netif_ppp.h` aren't found yet, that's fine — the stub doesn't include them. If linker fails on `modem_*` symbols, double-check `srcs` includes `modem.c`.

- [ ] **Step 5: Commit**

```bash
git add mdb-slave-esp32s3/main/modem.c \
        mdb-slave-esp32s3/main/modem_test.c \
        mdb-slave-esp32s3/main/CMakeLists.txt
git commit -m "firmware(modem): wire modem.c + modem_test.c stubs into build"
```

---

### Task 5: Add NVS load/save helpers (private to modem.c)

**Files:**
- Modify: `mdb-slave-esp32s3/main/modem.c`

These helpers are *not* in `modem.h` because P1 doesn't need them in the public API yet — `modem_init()` takes `apn`/`pin`/`mode` as direct arguments. The helpers exist so `modem_test.c` can read/write them. In P3 the captive portal will call them too.

- [ ] **Step 1: Add NVS helpers as static functions in modem.c**

Insert *above* `bool modem_probe(void)` in `modem.c`:

```c
#include <nvs.h>

#define NVS_NAMESPACE   "vmflow"
#define NVS_KEY_APN     "apn"
#define NVS_KEY_PIN     "sim_pin"
#define NVS_KEY_MODE    "lte_mode"

#define MODEM_APN_MAX   64
#define MODEM_PIN_MAX   12

/* Load cellular config from NVS. Returns ESP_OK on success and fills the
 * outputs; returns ESP_ERR_NVS_NOT_FOUND if no APN is set (in which case
 * the caller must wait for the captive portal to populate NVS). */
esp_err_t modem_nvs_load(char *apn_out, size_t apn_size,
                         char *pin_out, size_t pin_size,
                         modem_lte_mode_t *mode_out) {
    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NAMESPACE, NVS_READONLY, &h);
    if (err != ESP_OK) return err;

    size_t s = apn_size;
    err = nvs_get_str(h, NVS_KEY_APN, apn_out, &s);
    if (err != ESP_OK || strlen(apn_out) == 0) {
        nvs_close(h);
        return ESP_ERR_NVS_NOT_FOUND;
    }

    if (pin_out && pin_size > 0) {
        s = pin_size;
        if (nvs_get_str(h, NVS_KEY_PIN, pin_out, &s) != ESP_OK) {
            pin_out[0] = '\0';
        }
    }

    if (mode_out) {
        uint8_t m = MODEM_LTE_MODE_BOTH;
        nvs_get_u8(h, NVS_KEY_MODE, &m);
        *mode_out = (modem_lte_mode_t)m;
    }

    nvs_close(h);
    return ESP_OK;
}

esp_err_t modem_nvs_save(const char *apn, const char *pin, modem_lte_mode_t mode) {
    if (!apn || strlen(apn) == 0) return ESP_ERR_INVALID_ARG;

    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NAMESPACE, NVS_READWRITE, &h);
    if (err != ESP_OK) return err;

    err = nvs_set_str(h, NVS_KEY_APN, apn);
    if (err == ESP_OK && pin) {
        err = nvs_set_str(h, NVS_KEY_PIN, pin);
    }
    if (err == ESP_OK) {
        err = nvs_set_u8(h, NVS_KEY_MODE, (uint8_t)mode);
    }
    if (err == ESP_OK) {
        err = nvs_commit(h);
    }
    nvs_close(h);
    return err;
}
```

These are deliberately **not** declared in `modem.h` for P1 — `modem_test.c` will use a forward-declaration. P3 will promote them to the public API once the captive portal needs them.

- [ ] **Step 2: Add the forward declarations to modem.c that consumers use**

At the top of `modem.c`, *before* the function definitions, add a block clearly marked as "internal — promoted to modem.h in P3":

```c
/* === Internal API — promoted to modem.h in P3 ===================== */
esp_err_t modem_nvs_load(char *apn_out, size_t apn_size,
                         char *pin_out, size_t pin_size,
                         modem_lte_mode_t *mode_out);
esp_err_t modem_nvs_save(const char *apn, const char *pin, modem_lte_mode_t mode);
/* ================================================================== */
```

- [ ] **Step 3: Build to confirm the helpers compile**

```bash
cd mdb-slave-esp32s3
idf.py build 2>&1 | tail -10
```

Expected: build succeeds. No new warnings.

- [ ] **Step 4: Commit**

```bash
git add mdb-slave-esp32s3/main/modem.c
git commit -m "firmware(modem): NVS load/save helpers for apn/sim_pin/lte_mode"
```

---

## Chunk 2: Detection + Lifecycle (Tasks 6–10)

Real driver code: detection (with the safety-critical GPIO probe), the power-cycle helper, and the four lifecycle functions (init, connect, disconnect, status). Each task produces a working, buildable increment. Hardware verification is deferred to Chunk 3 — these tasks only confirm that code compiles and links correctly.

### Task 6: Implement `modem_probe()` — careful, side-effect-free on WiFi-only boards

**Files:**
- Modify: `mdb-slave-esp32s3/main/modem.c`

This is the safety-critical task. The function must return `false` on a board with no modem **without** asserting any GPIO that could affect unrelated circuitry.

- [ ] **Step 0: Verify the correct esp_modem device enum for SIM7080G**

The SIM7080G belongs to the **SIM7070 family** (SIM7070G/SIM7080G/SIM7090G all share the AT command set). The esp_modem v2.x library exposes both `ESP_MODEM_DCE_SIM7000` and `ESP_MODEM_DCE_SIM7070` — these are different drivers with different defaults (band selection, low-power behaviour). Use `ESP_MODEM_DCE_SIM7070`.

Confirm by grep:

```bash
grep -n "SIM7070\|SIM7000" mdb-slave-esp32s3/managed_components/espressif__esp_modem/include/esp_modem_c_api_types.h
```

Expected: both enum names appear in the file. If `ESP_MODEM_DCE_SIM7070` is **not** present (e.g., older esp_modem version), bump the version requirement in `idf_component.yml` to ≥`^2.0.0` (current pin already satisfies this) and re-run `idf.py reconfigure`.

*(The lost reference commit `d3f8b05` used `ESP_MODEM_DCE_SIM7000` — that was technically incorrect for SIM7080G. We deliberately diverge here.)*

- [ ] **Step 1: Add esp_modem includes and module-static state**

At the top of `modem.c`, after the existing includes, add:

```c
#include <esp_modem_api.h>
#include <esp_netif_ppp.h>
#include <esp_netif.h>
#include <driver/gpio.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

/* Pin defaults must match Task 1's findings. Currently: */
#define MODEM_PIN_RX    GPIO_NUM_18
#define MODEM_PIN_TX    GPIO_NUM_17
#define MODEM_PIN_PWR   GPIO_NUM_14
#define MODEM_UART_PORT UART_NUM_2
#define MODEM_BAUD      115200

/* Set in Task 1: true if the LilyGo board uses an inverting transistor
 * on PWRKEY (GPIO high → PWRKEY low). false if PWRKEY is wired direct
 * (GPIO low → PWRKEY low). DEFAULT: direct (LilyGo standard). Override
 * if Task 1 found otherwise. */
#define MODEM_PWRKEY_INVERTED 0

static esp_modem_dce_t  *s_dce  = NULL;
static esp_netif_t      *s_netif = NULL;
static bool              s_probed_present = false;
```

- [ ] **Step 2: Add a static helper for the GPIO quiescent check**

Insert *above* `bool modem_probe(void)`:

```c
/*
 * Read PWRKEY quiescent state as a *necessary-but-not-sufficient*
 * sanity check before deciding to issue a power-pulse. On a board
 * with the SIM7080G wired to GPIO 14, the modem's internal pull-up
 * keeps the line HIGH while VBAT is powered. On a board with no
 * modem, GPIO 14 is floating (returns 0 if internal pull-down is
 * applied).
 *
 * IMPORTANT: this is a heuristic, not a hardware barrier. If the
 * production WiFi-only PCB happens to wire GPIO 14 to a stable HIGH
 * source (3V3 pull-up, output of another peripheral), this check
 * would falsely report "modem present" and modem_probe() would then
 * pulse the GPIO as an output. **The empirical confirmation in Task
 * 13 is the load-bearing safety mechanism, not this code.** If Task
 * 13 fails (production board reads 5/5 high), see that task's
 * recovery section for what to do.
 */
static bool modem_pwrkey_quiescent_looks_attached(void) {
    gpio_config_t io = {
        .pin_bit_mask = 1ULL << MODEM_PIN_PWR,
        .mode         = GPIO_MODE_INPUT,
        .pull_up_en   = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type    = GPIO_INTR_DISABLE,
    };
    gpio_config(&io);

    int high_samples = 0;
    for (int i = 0; i < 5; i++) {
        if (gpio_get_level(MODEM_PIN_PWR) == 1) high_samples++;
        vTaskDelay(pdMS_TO_TICKS(10));
    }
    ESP_LOGI(TAG, "PWRKEY quiescent: %d/5 high", high_samples);
    return high_samples == 5;
}
```

- [ ] **Step 3: Implement `modem_probe()` replacing the stub**

Delete the existing stub `bool modem_probe(void) { ... }` and replace with:

```c
bool modem_probe(void) {
    if (s_probed_present) {
        ESP_LOGI(TAG, "modem_probe: already probed (present)");
        return true;
    }

    /* Step 1: GPIO quiescent check. Cheap, no side effects. */
    bool likely_attached = modem_pwrkey_quiescent_looks_attached();

    /* Step 2: Build a temporary DTE/DCE just for the AT-sync probe.
     * If sync fails we tear it down without ever issuing a power pulse. */
    esp_modem_dte_config_t dte_config = ESP_MODEM_DTE_DEFAULT_CONFIG();
    dte_config.uart_config.port_num   = MODEM_UART_PORT;
    dte_config.uart_config.baud_rate  = MODEM_BAUD;
    dte_config.uart_config.tx_io_num  = MODEM_PIN_TX;
    dte_config.uart_config.rx_io_num  = MODEM_PIN_RX;
    dte_config.uart_config.rts_io_num = -1;
    dte_config.uart_config.cts_io_num = -1;

    /* APN doesn't matter for the probe; pass an empty placeholder. */
    esp_modem_dce_config_t dce_config = ESP_MODEM_DCE_DEFAULT_CONFIG("");

    esp_netif_config_t netif_cfg = ESP_NETIF_DEFAULT_PPP();
    s_netif = esp_netif_new(&netif_cfg);
    if (!s_netif) {
        ESP_LOGE(TAG, "esp_netif_new failed");
        return false;
    }

    s_dce = esp_modem_new_dev(ESP_MODEM_DCE_SIM7070, &dte_config, &dce_config, s_netif);
    if (!s_dce) {
        ESP_LOGE(TAG, "esp_modem_new_dev failed");
        esp_netif_destroy(s_netif);
        s_netif = NULL;
        return false;
    }

    /* Try sync: modem may already be powered (warm reset, prior session). */
    esp_err_t ret = esp_modem_sync(s_dce);
    ESP_LOGI(TAG, "esp_modem_sync (cold try): %s", esp_err_to_name(ret));

    if (ret != ESP_OK) {
        /* Could be stuck in PPP mode from a prior boot. Escape and retry. */
        esp_modem_set_mode(s_dce, ESP_MODEM_MODE_COMMAND);
        vTaskDelay(pdMS_TO_TICKS(1000));
        ret = esp_modem_sync(s_dce);
        ESP_LOGI(TAG, "esp_modem_sync (after PPP escape): %s", esp_err_to_name(ret));
    }

    if (ret != ESP_OK) {
        if (!likely_attached) {
            ESP_LOGI(TAG, "GPIO quiescent says no modem — skipping power pulse");
            esp_modem_destroy(s_dce);
            esp_netif_destroy(s_netif);
            s_dce = NULL;
            s_netif = NULL;
            /* Reset PWRKEY GPIO to default (input, no pull) so we leave
             * no trace on the production board. */
            gpio_reset_pin(MODEM_PIN_PWR);
            return false;
        }

        /* Last resort: pulse power and try one more time. Only reached
         * when the GPIO check thinks a modem is attached but the modem
         * isn't responding to AT — likely cold boot. */
        ESP_LOGI(TAG, "issuing PWRKEY pulse...");
        modem_power_cycle();
        ret = esp_modem_sync(s_dce);
        ESP_LOGI(TAG, "esp_modem_sync (after pulse): %s", esp_err_to_name(ret));

        if (ret != ESP_OK) {
            vTaskDelay(pdMS_TO_TICKS(2000));
            ret = esp_modem_sync(s_dce);
            ESP_LOGI(TAG, "esp_modem_sync (after pulse + 2 s): %s", esp_err_to_name(ret));
        }
    }

    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "no modem detected");
        esp_modem_destroy(s_dce);
        esp_netif_destroy(s_netif);
        s_dce = NULL;
        s_netif = NULL;
        gpio_reset_pin(MODEM_PIN_PWR);
        return false;
    }

    /* Configure PPP-related netif params now (one-time, at netif creation
     * time) so we don't re-set on every connect/disconnect cycle. */
    esp_netif_ppp_config_t ppp_cfg = { .ppp_phase_event_enabled = true };
    esp_netif_ppp_set_params(s_netif, &ppp_cfg);

    s_probed_present = true;
    ESP_LOGI(TAG, "modem detected and synced");
    return true;
}
```

- [ ] **Step 4: Build to confirm**

```bash
cd mdb-slave-esp32s3
idf.py build 2>&1 | tail -20
```

Expected: build succeeds. If `esp_modem_api.h` is not found, double-check Task 4 added `esp_modem` to `REQUIRES` and that `managed_components/espressif__esp_modem/` exists (it should — see git status notes from spec).

- [ ] **Step 5: Commit**

```bash
git add mdb-slave-esp32s3/main/modem.c
git commit -m "firmware(modem): implement modem_probe with GPIO safety check + AT-sync detection"
```

---

### Task 7: Implement `modem_power_cycle()`

**Files:**
- Modify: `mdb-slave-esp32s3/main/modem.c`

- [ ] **Step 1: Replace the stub with the real implementation**

Delete the stub `void modem_power_cycle(void) { ... }` and replace with:

```c
void modem_power_cycle(void) {
    /* Configure PWRKEY as output. Direction matters: on LilyGo (direct
     * wiring), GPIO low = PWRKEY low = "press". On Leonardo's custom
     * PCB (inverting transistor), GPIO high = PWRKEY low = "press".
     * MODEM_PWRKEY_INVERTED selects between them. */
    gpio_set_direction(MODEM_PIN_PWR, GPIO_MODE_OUTPUT);

    const int idle_level    = MODEM_PWRKEY_INVERTED ? 0 : 1;
    const int pressed_level = MODEM_PWRKEY_INVERTED ? 1 : 0;

    gpio_set_level(MODEM_PIN_PWR, idle_level);
    vTaskDelay(pdMS_TO_TICKS(100));
    gpio_set_level(MODEM_PIN_PWR, pressed_level);
    vTaskDelay(pdMS_TO_TICKS(1200));   /* SIM7080G PWRKEY ≥ 1.0 s */
    gpio_set_level(MODEM_PIN_PWR, idle_level);

    ESP_LOGI(TAG, "PWRKEY pulsed; waiting 5 s for boot...");
    vTaskDelay(pdMS_TO_TICKS(5000));
}
```

- [ ] **Step 2: Build**

```bash
cd mdb-slave-esp32s3
idf.py build 2>&1 | tail -10
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add mdb-slave-esp32s3/main/modem.c
git commit -m "firmware(modem): implement modem_power_cycle with polarity-aware PWRKEY pulse"
```

---

### Task 8: Implement `modem_init()`

**Files:**
- Modify: `mdb-slave-esp32s3/main/modem.c`

- [ ] **Step 1: Replace the stub**

Delete `esp_err_t modem_init(...)` stub and replace with:

```c
esp_err_t modem_init(const char *apn, const char *pin, modem_lte_mode_t mode) {
    if (!s_dce) {
        ESP_LOGE(TAG, "modem_init called before successful modem_probe");
        return ESP_ERR_INVALID_STATE;
    }
    if (!apn || strlen(apn) == 0) {
        ESP_LOGE(TAG, "modem_init: APN required");
        return ESP_ERR_INVALID_ARG;
    }

    esp_err_t err;

    /* SIM PIN, if provided. AT+CPIN expects only the PIN if it's needed;
     * if the SIM is PIN-less, sending AT+CPIN errors and we ignore that. */
    if (pin && strlen(pin) > 0) {
        err = esp_modem_set_pin(s_dce, pin);
        ESP_LOGI(TAG, "esp_modem_set_pin: %s", esp_err_to_name(err));
        /* Tolerate failure — SIM may not require PIN. */
    }

    /* Network mode: 38 = LTE only (we don't want GSM fallback). */
    err = esp_modem_at(s_dce, "AT+CNMP=38", NULL, 3000);
    ESP_LOGI(TAG, "AT+CNMP=38: %s", esp_err_to_name(err));

    /* CMNB selects within LTE: 1=Cat-M, 2=NB-IoT, 3=both. */
    char cmnb_cmd[24];
    snprintf(cmnb_cmd, sizeof(cmnb_cmd), "AT+CMNB=%d", (int)mode);
    err = esp_modem_at(s_dce, cmnb_cmd, NULL, 3000);
    ESP_LOGI(TAG, "%s: %s", cmnb_cmd, esp_err_to_name(err));

    /* Configure APN via the esp_modem helper (writes AT+CGDCONT). */
    err = esp_modem_set_apn(s_dce, apn);
    ESP_LOGI(TAG, "esp_modem_set_apn(%s): %s", apn, esp_err_to_name(err));
    if (err != ESP_OK) return err;

    /* Enable +CEREG URC so we can poll registration cleanly later. */
    esp_modem_at(s_dce, "AT+CEREG=1", NULL, 3000);

    return ESP_OK;
}
```

- [ ] **Step 2: Build**

```bash
cd mdb-slave-esp32s3
idf.py build 2>&1 | tail -10
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add mdb-slave-esp32s3/main/modem.c
git commit -m "firmware(modem): implement modem_init (PIN, CNMP, CMNB, APN, CEREG)"
```

---

### Task 9: Implement `modem_connect()` and `modem_disconnect()`

**Files:**
- Modify: `mdb-slave-esp32s3/main/modem.c`

- [ ] **Step 1: Add a registration-wait helper**

Insert *above* the connect implementation:

```c
/* Poll AT+CEREG? until stat == 1 (home) or 5 (roaming). Up to 60 s. */
static esp_err_t modem_wait_registered(void) {
    char resp[96];
    for (int i = 0; i < 30; i++) {
        memset(resp, 0, sizeof(resp));
        esp_err_t err = esp_modem_at(s_dce, "AT+CEREG?", resp, 3000);
        if (err == ESP_OK && (strstr(resp, ",1") || strstr(resp, ",5"))) {
            ESP_LOGI(TAG, "EPS registered: %s", resp);
            return ESP_OK;
        }
        ESP_LOGW(TAG, "not registered (attempt %d/30): %s", i + 1, resp);
        vTaskDelay(pdMS_TO_TICKS(2000));
    }
    return ESP_ERR_TIMEOUT;
}
```

- [ ] **Step 2: Replace the `modem_connect()` stub**

```c
esp_err_t modem_connect(void) {
    if (!s_dce) return ESP_ERR_INVALID_STATE;

    /* Make sure RF is on (some modems boot at CFUN=4 = airplane). */
    esp_err_t err = esp_modem_at(s_dce, "AT+CFUN=1", NULL, 5000);
    ESP_LOGI(TAG, "AT+CFUN=1: %s", esp_err_to_name(err));

    err = modem_wait_registered();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "registration timeout");
        return err;
    }

    /* PPP params already set in modem_probe — just enter DATA mode. */
    err = esp_modem_set_mode(s_dce, ESP_MODEM_MODE_DATA);
    ESP_LOGI(TAG, "set DATA mode: %s", esp_err_to_name(err));
    return err;
}
```

- [ ] **Step 3: Replace the `modem_disconnect()` stub**

```c
esp_err_t modem_disconnect(void) {
    if (!s_dce) return ESP_OK;
    esp_err_t err = esp_modem_set_mode(s_dce, ESP_MODEM_MODE_COMMAND);
    ESP_LOGI(TAG, "set COMMAND mode: %s", esp_err_to_name(err));
    return err;
}
```

- [ ] **Step 4: Build**

```bash
cd mdb-slave-esp32s3
idf.py build 2>&1 | tail -10
```

Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add mdb-slave-esp32s3/main/modem.c
git commit -m "firmware(modem): implement modem_connect (CFUN=1, CEREG poll, PPP) + modem_disconnect"
```

---

### Task 10: Implement `modem_status()`

**Files:**
- Modify: `mdb-slave-esp32s3/main/modem.c`

- [ ] **Step 1: Add an RSSI parser helper**

Insert above the `modem_status` definition:

```c
/* Convert AT+CSQ raw value (0-31, 99 = unknown) to dBm. Per 3GPP 27.007:
 *   raw = 0   → -113 dBm
 *   raw = 31  → -51 dBm
 *   raw = 99  → unknown (return 0)
 *   else      → -113 + 2 * raw */
static int8_t csq_to_dbm(int raw) {
    if (raw == 99 || raw < 0 || raw > 31) return 0;
    return -113 + (raw * 2);
}
```

- [ ] **Step 2: Replace the `modem_status()` stub**

```c
void modem_status(modem_status_t *out) {
    if (!out) return;
    memset(out, 0, sizeof(*out));
    out->active_mode = MODEM_LTE_MODE_BOTH;

    if (!s_dce) return;

    char resp[96];

    /* Signal quality. Response shape varies between firmwares — esp_modem
     * may strip the AT echo entirely and return just "+CSQ: 14,99\r\n",
     * or it may include a leading "\r\n+CSQ: ...". Use strstr to find
     * the prefix instead of a positional sscanf format. */
    if (esp_modem_at(s_dce, "AT+CSQ", resp, 2000) == ESP_OK) {
        const char *p = strstr(resp, "+CSQ:");
        if (p) {
            int rssi_raw = -1, ber = -1;
            if (sscanf(p, "+CSQ: %d,%d", &rssi_raw, &ber) >= 1) {
                out->rssi_dbm = csq_to_dbm(rssi_raw);
            }
        }
    }

    /* Registration */
    if (esp_modem_at(s_dce, "AT+CEREG?", resp, 2000) == ESP_OK) {
        out->registered = (strstr(resp, ",1") || strstr(resp, ",5")) != NULL;
    }

    /* Operator name */
    if (esp_modem_at(s_dce, "AT+COPS?", resp, 2000) == ESP_OK) {
        /* Response: +COPS: 0,0,"Vodafone DE",7  — extract the quoted string */
        char *first = strchr(resp, '"');
        if (first) {
            char *second = strchr(first + 1, '"');
            if (second) {
                size_t len = second - first - 1;
                if (len >= sizeof(out->operator_name)) len = sizeof(out->operator_name) - 1;
                memcpy(out->operator_name, first + 1, len);
                out->operator_name[len] = '\0';
            }
        }
    }

    /* IP address (only valid in PPP/data mode) */
    if (s_netif) {
        esp_netif_ip_info_t ip_info;
        if (esp_netif_get_ip_info(s_netif, &ip_info) == ESP_OK && ip_info.ip.addr != 0) {
            esp_ip4addr_ntoa(&ip_info.ip, out->ip, sizeof(out->ip));
        }
    }
}
```

- [ ] **Step 3: Build**

```bash
cd mdb-slave-esp32s3
idf.py build 2>&1 | tail -10
```

Expected: build succeeds. May warn about `sscanf` format — acceptable for P1.

- [ ] **Step 4: Commit**

```bash
git add mdb-slave-esp32s3/main/modem.c
git commit -m "firmware(modem): implement modem_status (CSQ, CEREG, COPS, IP)"
```

---

## Chunk 3: Validation + Wrap-up (Tasks 11–14)

Test harness behind a Kconfig flag, hardware acceptance on both board variants (the empirical proof that the spec's R1 and R2 risks are mitigated), and final cleanup so the binary is safe to ship to production with the test flag off.

### Task 11: Write the P1 test main

**Files:**
- Modify: `mdb-slave-esp32s3/main/modem_test.c`
- Modify: `mdb-slave-esp32s3/main/mdb-slave-esp32s3.c` (one-line wrap of `app_main`)

- [ ] **Step 1: Replace the placeholder `modem_test.c` with a real test main**

```c
/*
 * VMflow.xyz
 *
 * modem_test.c — P1 hardware validation entry point.
 *
 * Activated by Kconfig CASHLESS_TEST_MODE_MODEM. When enabled, this
 * app_main runs instead of the production one — exercises modem_probe,
 * init, connect, status repeatedly, logs to serial.
 *
 * Removed during P2.
 */

#include "sdkconfig.h"

#if CONFIG_CASHLESS_TEST_MODE_MODEM

#include <string.h>
#include <esp_log.h>
#include <esp_netif.h>
#include <esp_event.h>
#include <nvs_flash.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

#include "modem.h"

#define TAG "modem_test"

/* Forward-declared in modem.c (will move to modem.h in P3). */
esp_err_t modem_nvs_load(char *apn_out, size_t apn_size,
                         char *pin_out, size_t pin_size,
                         modem_lte_mode_t *mode_out);

void app_main(void) {
    ESP_LOGW(TAG, "================================================");
    ESP_LOGW(TAG, "  P1 modem driver test main (NOT PRODUCTION)   ");
    ESP_LOGW(TAG, "================================================");

    /* NVS init (modem_nvs_load needs it) */
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        nvs_flash_erase();
        nvs_flash_init();
    }

    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());

    ESP_LOGI(TAG, "calling modem_probe()...");
    bool present = modem_probe();
    ESP_LOGI(TAG, "modem_probe → %s", present ? "TRUE (modem detected)" : "FALSE (no modem)");

    if (!present) {
        ESP_LOGI(TAG, "no modem; sleeping forever (this is the WiFi-only-board outcome)");
        while (1) vTaskDelay(pdMS_TO_TICKS(60000));
    }

    /* Modem present. Try to bring it online. */
    char apn[64], pin[12];
    modem_lte_mode_t mode;
    err = modem_nvs_load(apn, sizeof(apn), pin, sizeof(pin), &mode);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "no APN in NVS — falling back to compile-time default '%s'",
                 CONFIG_SIM7080G_APN);
        strcpy(apn, CONFIG_SIM7080G_APN);
        pin[0] = '\0';
        mode = (modem_lte_mode_t)CONFIG_SIM7080G_CMNB;
    } else {
        ESP_LOGI(TAG, "loaded NVS: apn=%s, pin=%s, mode=%d", apn,
                 pin[0] ? "(set)" : "(none)", mode);
    }

    err = modem_init(apn, pin, mode);
    ESP_LOGI(TAG, "modem_init → %s", esp_err_to_name(err));
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "init failed; sleeping");
        while (1) vTaskDelay(pdMS_TO_TICKS(60000));
    }

    err = modem_connect();
    ESP_LOGI(TAG, "modem_connect → %s", esp_err_to_name(err));

    /* Status loop, every 10 s for inspection */
    while (1) {
        modem_status_t st;
        modem_status(&st);
        ESP_LOGI(TAG, "STATUS: registered=%d rssi=%d dBm op='%s' ip=%s mode=%d",
                 st.registered, st.rssi_dbm, st.operator_name, st.ip, st.active_mode);
        vTaskDelay(pdMS_TO_TICKS(10000));
    }
}

#endif /* CONFIG_CASHLESS_TEST_MODE_MODEM */
```

- [ ] **Step 2: Wrap the production `app_main` so the test one can take over**

`app_main` is **the last function in `mdb-slave-esp32s3/main/mdb-slave-esp32s3.c`** — its closing brace is the **last `}` in the entire file**. There is nothing after it.

Find the line `void app_main(void) {` (currently around line 2481). Just **above** that line, add:

```c
#if !CONFIG_CASHLESS_TEST_MODE_MODEM
```

Then go to the very end of the file and add **after the final closing brace** (currently around line 2806):

```c
#endif /* !CONFIG_CASHLESS_TEST_MODE_MODEM */
```

Verify by:

```bash
grep -n "^void app_main\|^#if !CONFIG_CASHLESS_TEST_MODE_MODEM\|^#endif /\* !CONFIG_CASHLESS_TEST_MODE_MODEM" \
    mdb-slave-esp32s3/main/mdb-slave-esp32s3.c
tail -3 mdb-slave-esp32s3/main/mdb-slave-esp32s3.c
```

Expected: the `#if` appears before the `void app_main` line, and the `#endif` is the final non-empty line of the file.

- [ ] **Step 3: Build with the test flag OFF (regression check — production must still build)**

```bash
cd mdb-slave-esp32s3
idf.py build 2>&1 | tail -10
```

Expected: build succeeds. Binary size should be within ~5 KB of the previous build (the new modem.c adds code but it's referenced from nowhere in this configuration).

- [ ] **Step 4: Build with the test flag ON**

```bash
cd mdb-slave-esp32s3
idf.py menuconfig    # navigate to "SIM7080G" → enable "Run modem test main..."
# (Alternative: edit sdkconfig directly: set CONFIG_CASHLESS_TEST_MODE_MODEM=y)
idf.py build 2>&1 | tail -20
```

Expected: build succeeds. Linker should resolve `app_main` to the test version (the production one is `#if`'d out).

If the linker complains about duplicate `app_main` → check the wrap markers in `mdb-slave-esp32s3.c` are placed correctly.

- [ ] **Step 5: Commit (both flag-on and flag-off must build)**

```bash
git add mdb-slave-esp32s3/main/modem_test.c \
        mdb-slave-esp32s3/main/mdb-slave-esp32s3.c
git commit -m "firmware(modem): P1 test main + production app_main wrap behind Kconfig flag"
```

---

### Task 12: Hardware acceptance — LilyGo board (modem present)

**Files:** none modified — this task is empirical.

This task is the first half of P1's Definition of Done from the spec.

- [ ] **Step 1: Flash the LilyGo board with the test build**

With `CONFIG_CASHLESS_TEST_MODE_MODEM=y`:

```bash
cd mdb-slave-esp32s3
idf.py -p <PORT> flash monitor
```

Replace `<PORT>` with the LilyGo's serial port (e.g. `/dev/cu.usbmodem...` on macOS).

- [ ] **Step 2: Observe serial output and confirm probe success**

Expected log lines (in order, within ~15 s of boot):

```
W (xxx) modem_test: ================================================
W (xxx) modem_test:   P1 modem driver test main (NOT PRODUCTION)
W (xxx) modem_test: ================================================
I (xxx) modem_test: calling modem_probe()...
I (xxx) modem: PWRKEY quiescent: 5/5 high
I (xxx) modem: esp_modem_sync (cold try): ESP_OK             ← OR fails first time, that's OK
[…possibly: PWRKEY pulse → wait → sync OK]
I (xxx) modem: modem detected and synced
I (xxx) modem_test: modem_probe → TRUE (modem detected)
```

If `modem_probe → FALSE`: investigate (check pin defines vs Task 1 findings, check power supply, check antenna connection, check that the board actually has a SIM7080G — some LilyGo SKUs ship without).

- [ ] **Step 3: Confirm SIM card is recognised**

Expected next phase (assuming a SIM is inserted):

```
I (xxx) modem: esp_modem_set_pin: ...     (only if PIN provided)
I (xxx) modem: AT+CNMP=38: ESP_OK
I (xxx) modem: AT+CMNB=3: ESP_OK
I (xxx) modem: esp_modem_set_apn(internet): ESP_OK
I (xxx) modem_test: modem_init → ESP_OK
I (xxx) modem: AT+CFUN=1: ESP_OK
I (xxx) modem: not registered (attempt 1/30): +CEREG: 1,2
…
I (xxx) modem: EPS registered: +CEREG: 1,1
I (xxx) modem: set DATA mode: ESP_OK
I (xxx) modem_test: modem_connect → ESP_OK
```

Registration may take 5-30 s depending on carrier. If registration times out:
- Try a different APN (use `idf.py menuconfig` to change `SIM7080G_APN` and reflash, OR write to NVS via `nvs_flash` tool)
- Try a different LTE mode (Cat-M only vs both)
- Check antenna is connected
- Confirm SIM has cellular service

- [ ] **Step 4: Confirm status loop emits sensible values**

After `modem_connect → ESP_OK`, the test loop should print every 10 s:

```
I (xxx) modem_test: STATUS: registered=1 rssi=-77 dBm op='Vodafone.de' ip=10.123.45.67 mode=3
```

`rssi` between -50 and -113 dBm is plausible. `op` should be a non-empty string (most carriers reply within 2-3 s). `ip` should be a public-ish IPv4. If `rssi=0` or `op=''`, double-check the AT command timing in `modem_status()`.

- [ ] **Step 5: Record results in this task**

Take a serial-log snapshot and paste a representative excerpt back into this task as proof-of-pass. This becomes the validation record for P1.

No commit — this task produces no code changes.

---

### Task 13: Hardware acceptance — production WiFi-only board (modem absent, GPIO 14 quiescent)

**Files:** none modified — this task is empirical and is the **critical** backward-compat protection from the spec's R2.

- [ ] **Step 1: Flash a current production WiFi-only board with the SAME test build**

Same steps as Task 12 step 1, but on a production board (not LilyGo). Use a board you can recover (in case anything goes wrong with GPIO 14).

- [ ] **Step 2: Observe serial output and confirm probe returns false WITHOUT pulsing**

Expected log lines:

```
W (xxx) modem_test:   P1 modem driver test main (NOT PRODUCTION)
I (xxx) modem_test: calling modem_probe()...
I (xxx) modem: PWRKEY quiescent: 0/5 high     ← critical: NOT 5/5
I (xxx) modem: esp_modem_sync (cold try): ESP_ERR_TIMEOUT
I (xxx) modem: esp_modem_sync (after PPP escape): ESP_ERR_TIMEOUT
I (xxx) modem: GPIO quiescent says no modem — skipping power pulse   ← critical
W (xxx) modem: no modem detected
I (xxx) modem_test: modem_probe → FALSE (no modem)
I (xxx) modem_test: no modem; sleeping forever (this is the WiFi-only-board outcome)
```

Two critical things to verify:

1. **`PWRKEY quiescent: 0/5 high`** (or at least less than 5) — proves the GPIO is *not* being pulled high by anything that would trick the heuristic.
2. **`GPIO quiescent says no modem — skipping power pulse`** appears — proves the safety check fired and we did NOT issue a power pulse on the production board.

If `PWRKEY quiescent: 5/5 high` on the production board: **stop and investigate.** Concrete recovery steps (in order):

1. **Re-confirm pin defines from Task 1 are correct for the *production* PCB**, not just for LilyGo. The two boards may use different GPIOs for the modem PWRKEY. If the production PCB's GPIO 14 is wired to something else entirely (e.g. an unrelated control line), update `MODEM_PIN_PWR` to a pin that's actually unused on production.
2. **Look at the production PCB schematic** to identify what (if anything) is connected to GPIO 14. Source: `kicad/mdb-slave-esp32s3/` (the original WiFi-only board's KiCad project).
3. **Try a pull-DOWN probe instead of pull-up**: change `gpio_config` in `modem_pwrkey_quiescent_looks_attached()` to use `GPIO_PULLDOWN_ENABLE` and invert the expected reading (look for `5/5 low` as "no modem"). If the line reads HIGH with pull-down enabled, something is actively driving it.
4. **Escalate to the user with the production PCB schematic** before doing any more probe work. Do **not** attempt to "see what happens" by enabling the power-pulse on the production board. The PCB might route GPIO 14 to a critical control line; an unexpected pulse could brick the device.
5. **Worst-case fallback**: gate the entire `modem_probe()` behind a Kconfig option `CONFIG_MODEM_PROBE_ENABLED` (defaulted off). The cellular-variant build sets it on; production WiFi-only builds leave it off. This loses runtime detection but is a safe interim while pin assignments are reconciled across PCB variants.

Document which path was taken in this task before proceeding.

- [ ] **Step 3: Probe with a multimeter or scope to confirm GPIO 14 was untouched**

If hardware is available: monitor GPIO 14 on the production board with a scope across the boot. There must be **no falling edge** during the probe sequence — the pin should stay at its quiescent state the whole time. This is the strongest possible proof of zero side-effects.

If no scope is available, the serial log evidence in Step 2 is sufficient.

- [ ] **Step 4: Record results**

Same as Task 12 step 5 — paste a representative serial excerpt into this task.

No commit — empirical task.

---

### Task 14: P1 wrap-up — disable test mode by default and document

**Files:**
- Modify: `CLAUDE.md` (small section noting `modem.{c,h}` exists and what it does)
- *(Do NOT commit `sdkconfig`.)* `sdkconfig` is a per-checkout build artefact; ESP-IDF convention is to commit only `sdkconfig.defaults` for tracked defaults. We don't ship a `sdkconfig.defaults` for this flag because the default is `n` (enforced by Kconfig) and overriding it locally is a developer choice.

- [ ] **Step 1: Confirm `CONFIG_CASHLESS_TEST_MODE_MODEM` defaults to OFF in the working sdkconfig**

The Kconfig in Task 2 already has `default n`. Verify the local `sdkconfig` does **not** carry `CONFIG_CASHLESS_TEST_MODE_MODEM=y` after the test runs:

```bash
grep -n CASHLESS_TEST_MODE_MODEM mdb-slave-esp32s3/sdkconfig
```

If the line shows `=y`, run `idf.py menuconfig` to disable it, save, and reconfigure. If the line is `# CONFIG_CASHLESS_TEST_MODE_MODEM is not set`, you're good. **This change to `sdkconfig` is not committed** — leaving the test flag toggled on a developer's checkout is fine; what matters is that the Kconfig default is `n`.

- [ ] **Step 2: Add a short paragraph to CLAUDE.md**

Add this paragraph at the end of the `### mdb-slave-esp32s3 Architecture` section (search for that heading):

```markdown
**Cellular driver (`modem.c` / `modem.h`)**: Self-contained SIM7080G driver
introduced in P1 of the cellular milestone. Public API: `modem_probe`,
`modem_init`, `modem_connect`, `modem_disconnect`, `modem_status`,
`modem_power_cycle`. Not yet wired into `app_main` — that integration is
P2 (network manager). To run the P1 validation harness, set
`CONFIG_CASHLESS_TEST_MODE_MODEM=y` in `idf.py menuconfig` under the new
"SIM7080G" menu.
```

- [ ] **Step 3: Final regression build with test flag off**

```bash
cd mdb-slave-esp32s3
idf.py build 2>&1 | tail -10
```

Expected: build succeeds. **The binary should be safe to flash on production WiFi-only devices**, *given* that Task 13 has already empirically confirmed `modem.c` is never called and GPIO 14 is untouched in this configuration. Source-inspection alone is **not** sufficient evidence — Task 13 is the load-bearing safety check.

- [ ] **Step 4: Commit (CLAUDE.md only)**

```bash
git add CLAUDE.md
git commit -m "firmware(modem): document P1 driver in CLAUDE.md"
```

- [ ] **Step 5: Tag the P1 completion in git — only after Tasks 12 and 13 have evidence pasted into the plan**

Before creating the tag, verify the plan file has serial-log excerpts in Task 12 Step 5 and Task 13 Step 4. If either is empty, do not tag — it means hardware acceptance was skipped.

```bash
git tag -a milestone/cellular-p1 -m "Cellular milestone P1 complete: modem.c driver foundation"
```

(Tag is local until pushed. Don't push without the user's explicit approval.)

---

## P1 Definition of Done — checklist for the finishing reviewer

**Spec-derived (load-bearing):**

- [ ] `modem_probe()` returns **true** on the user's LilyGo T-SIM7080G with a SIM inserted. *(Spec P1 DoD line 1.)*
- [ ] `modem_probe()` returns **false** on a current production WiFi-only board, with serial log proving the GPIO safety check fired and no PWRKEY pulse was issued. *(Spec P1 DoD line 2 — empirical GPIO 14 quiescent confirmation.)*
- [ ] `modem_init` + `modem_connect` succeed end-to-end on LilyGo: registration completes within 60 s, PPP gets an IP, the status loop prints sensible RSSI / operator / IP values. *(Spec §1 lifecycle proof.)*
- [ ] No changes to existing production code paths — only the `#if !CONFIG_CASHLESS_TEST_MODE_MODEM` wrap around `app_main` in `mdb-slave-esp32s3.c`. *(Spec R1 — refactor regression mitigation.)*
- [ ] Production build (test mode off) compiles cleanly and is safe to flash on a production board, **proven by Task 13's empirical run** (not by source inspection).

**Plan-internal (not in spec, but useful sanity bounds):**

- [ ] `modem.h` and `modem.c` exist; `modem.c` is ≤ ~600 lines. *(If significantly larger, file split should be revisited — see File Structure section.)*

When all six checks are green: P1 is done. The next plan file (P2 — Network Manager) can be written.

---

## Skills referenced

This plan assumes the executor uses:

- @superpowers:test-driven-development — for any pure-C helper that's host-testable (the NVS helpers in Task 5 could be host-tested via the ESP-IDF `linux` target if the executor wants to push for stricter TDD; the rest of P1 is hardware-driven and TDD doesn't apply cleanly).
- @superpowers:verification-before-completion — Tasks 12 and 13 are the verification gates. Do not mark P1 complete without their serial-log evidence.
- @superpowers:subagent-driven-development — recommended for execution; each task in this plan is bounded enough for a fresh subagent.
