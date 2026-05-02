# Firmware Cellular P4 — Modem Watchdog + Recovery

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a 3-layer recovery escalation for cellular failure modes (PPP reconnect → modem power-cycle → existing hard-reboot watchdog) and tune MQTT client parameters for cellular link characteristics. Net effect: a fielded cellular device that loses signal recovers within ~60 s without rebooting; a hung modem chip gets pulse-recovered before the firmware nukes itself.

**Architecture:** A new modem-watchdog FreeRTOS task in `modem.c` (low priority, 30 s tick) probes the modem with `AT+CSQ` heartbeats while in cellular state. On three consecutive failures it issues `modem_power_cycle()` and re-runs `modem_init` + `modem_connect`. Layer 1 (PPP-reconnect-on-LOST_IP) lands in `network.c`; Layer 3 (existing 10-min `mqtt_watchdog_cb` hard-reboot) is unchanged. MQTT keepalive/timeouts switch to cellular-friendly values when `network_get_state() == CELLULAR_UP` at the moment `esp_mqtt_client_init` is called.

**Tech Stack:** ESP-IDF, FreeRTOS, esp-modem, esp_mqtt_client.

**Spec reference:** [docs/superpowers/specs/2026-04-27-firmware-cellular-network-design.md](../specs/2026-04-27-firmware-cellular-network-design.md) — see §5 (Recovery & watchdog).

**Position in milestone:** Phase 4 of 6. P1+P2+P3 complete. P5 (backend telemetry) and P6 (field validation) follow.

**Backward-compat invariant:** WiFi-only boards must see no behaviour change. The watchdog task does not start on non-cellular boards (gated by `network_get_state()`). MQTT tuning conditional means WiFi keeps its current 60s/10s/5s values; only cellular overrides them.

---

## File Structure

- **Modify:** `mdb-slave-esp32s3/main/modem.c` (~440 → ~580 lines): add static modem watchdog task + `modem_at_keepalive_ping()` helper. Watchdog spawns from `network.c` after `modem_connect` succeeds, NOT autostarted from modem.c (to keep modem.c free of FreeRTOS-task-lifecycle policy).
- **Modify:** `mdb-slave-esp32s3/main/modem.h`: expose `modem_start_watchdog()` and `modem_stop_watchdog()`.
- **Modify:** `mdb-slave-esp32s3/main/network.c`: add Layer-1 PPP reconnect logic in `network_ppp_event_handler` (3 fast attempts via `modem_disconnect` + `modem_connect` before falling back to Layer 2). Trigger `modem_start_watchdog()` after first successful `cellular_bring_up_task` connect; trigger `modem_stop_watchdog()` only on shutdown (not on transient PPP loss — the watchdog needs to keep running).
- **Modify:** `mdb-slave-esp32s3/main/mdb-slave-esp32s3.c`: tune MQTT config based on `network_get_state()`. Three lines of conditional values applied to `esp_mqtt_client_config_t` before `esp_mqtt_client_init`.

modem.c size will end up around 580 lines — still under the ~600 sanity budget.

---

## Chunk 1: MQTT cellular tuning + Layer 1 PPP reconnect (Tasks 1–3)

### Task 1: Cellular-aware MQTT config in mdb-slave-esp32s3.c

**Files:** Modify `mdb-slave-esp32s3/main/mdb-slave-esp32s3.c`.

The existing config is at lines 2618–2655. Today: keepalive 60 s, network.timeout_ms 10 s, network.reconnect_timeout_ms 5 s. For cellular, override to 180 / 30 / 20.

- [ ] **Step 1:** Add `#include "network.h"` at the top of the file (it's already included via P2 — verify).
- [ ] **Step 2:** Replace the literal values in `mqttCfg` initialiser with constant expressions chosen at runtime. Since `esp_mqtt_client_config_t` is a designated initialiser, the cleanest pattern is:

```c
    /* Cellular link is more latent than WiFi — bump keepalive (saves
     * data quota) and timeouts (LTE-M latency). The watchdog still
     * fires after MQTT_WATCHDOG_TIMEOUT_SEC if the broker is unreachable,
     * so the longer keepalive only delays detection by ~2 minutes. */
    bool on_cellular = (network_get_state() == NETWORK_STATE_CELLULAR_UP ||
                         network_get_state() == NETWORK_STATE_CELLULAR_REGISTERING);
    int  mqtt_keepalive       = on_cellular ? 180   : 60;
    int  mqtt_network_timeout = on_cellular ? 30000 : 10000;
    int  mqtt_reconnect       = on_cellular ? 20000 : 5000;
    ESP_LOGI(TAG, "MQTT tuning: keepalive=%ds netto=%dms recto=%dms (cellular=%d)",
             mqtt_keepalive, mqtt_network_timeout, mqtt_reconnect, on_cellular);

    const esp_mqtt_client_config_t mqttCfg = {
        // ... unchanged fields ...
        .session.keepalive            = mqtt_keepalive,
        .network.timeout_ms           = mqtt_network_timeout,
        .network.reconnect_timeout_ms = mqtt_reconnect,
    };
```

- [ ] **Step 3:** Build. Commit `firmware(mqtt): cellular-aware keepalive + timeouts (180s/30s/20s vs 60s/10s/5s)`.

### Task 2: Add `modem_at_keepalive_ping()` and watchdog API to modem.h

**Files:** Modify `mdb-slave-esp32s3/main/modem.h` and `modem.c`.

- [ ] **Step 1:** In `modem.h`, before the closing `#endif`, add:

```c
/* ---- Watchdog ---- */

/*
 * Periodic AT keepalive sent to the modem from a low-priority FreeRTOS
 * task (started via modem_start_watchdog). Returns ESP_OK if the modem
 * responded to the bare "AT" within ~3s. Failure modes:
 *   - In PPP DATA mode the modem won't respond to AT — caller must
 *     issue an escape (+++) first; the watchdog handles this internally.
 *   - Three consecutive failures trigger modem_power_cycle + re-init.
 */
esp_err_t modem_at_keepalive_ping(void);

/*
 * Start the watchdog task. Must be called only after a successful
 * modem_connect. Idempotent — second call is a no-op. The task runs
 * forever (no stop API in P4; modem_stop_watchdog is a placeholder
 * for future use).
 */
void modem_start_watchdog(void);
void modem_stop_watchdog(void);   /* P4: no-op; reserved */
```

- [ ] **Step 2:** In `modem.c`, add the watchdog task and helper. Insert after `modem_status` (before any lifecycle code that might use it):

```c
/* === Watchdog =========================================================
 *
 * Polls the modem with a bare "AT" every WATCHDOG_TICK_SEC. On three
 * consecutive failures escalates to power-cycle + re-init + re-connect.
 * Layer-3 hard-reboot is the existing mqtt_watchdog_cb in main.c —
 * we never call esp_restart() from here.
 *
 * Forward-compatibility note (P5): the watchdog tick also refreshes
 * RSSI / operator into a static struct, so /system/info and the
 * MQTT status payload can read them without re-issuing AT every poll.
 * ===================================================================== */

#define WATCHDOG_TICK_SEC          30
#define WATCHDOG_FAIL_TO_POWER_CYCLE 3
#define WATCHDOG_POWER_CYCLE_LIMIT 2

static TaskHandle_t  s_watchdog_task = NULL;
static int           s_consec_fails  = 0;
static int           s_power_cycles  = 0;

esp_err_t modem_at_keepalive_ping(void) {
    if (!s_dce) return ESP_ERR_INVALID_STATE;

    /* If we're in DATA (PPP) mode, AT commands won't get through.
     * We must escape with +++ first. esp_modem_set_mode handles the
     * timing internally. */
    char resp[32];
    esp_err_t err = esp_modem_at(s_dce, "AT", resp, 3000);
    if (err == ESP_OK) return ESP_OK;

    /* Try a PPP escape and one retry. If even that fails, the modem
     * is unresponsive. */
    esp_modem_set_mode(s_dce, ESP_MODEM_MODE_COMMAND);
    vTaskDelay(pdMS_TO_TICKS(1000));
    err = esp_modem_at(s_dce, "AT", resp, 3000);
    return err;
}

static void modem_watchdog_task(void *arg) {
    (void)arg;
    ESP_LOGI(TAG, "watchdog: starting (tick=%ds, fail-to-pulse=%d)",
             WATCHDOG_TICK_SEC, WATCHDOG_FAIL_TO_POWER_CYCLE);

    while (1) {
        vTaskDelay(pdMS_TO_TICKS(WATCHDOG_TICK_SEC * 1000));

        esp_err_t err = modem_at_keepalive_ping();
        if (err == ESP_OK) {
            if (s_consec_fails) {
                ESP_LOGI(TAG, "watchdog: AT recovered after %d fails", s_consec_fails);
            }
            s_consec_fails = 0;
            s_power_cycles = 0;
            continue;
        }

        s_consec_fails++;
        ESP_LOGW(TAG, "watchdog: AT ping failed (%d/%d): %s",
                 s_consec_fails, WATCHDOG_FAIL_TO_POWER_CYCLE,
                 esp_err_to_name(err));

        if (s_consec_fails < WATCHDOG_FAIL_TO_POWER_CYCLE) continue;

        /* Layer 2: pulse PWRKEY and re-init. Bounded by
         * WATCHDOG_POWER_CYCLE_LIMIT so a dead chip doesn't burn flash
         * cycles forever — Layer 3 (mqtt_watchdog_cb) reboots the
         * device after another 5-10 minutes. */
        if (s_power_cycles >= WATCHDOG_POWER_CYCLE_LIMIT) {
            ESP_LOGE(TAG, "watchdog: power-cycle limit reached — leaving Layer 3 to handle");
            s_consec_fails = 0;   /* let it re-arm; Layer 3 will reboot eventually */
            continue;
        }

        ESP_LOGW(TAG, "watchdog: Layer 2 — modem_power_cycle + re-init (#%d)",
                 s_power_cycles + 1);
        modem_power_cycle();
        s_power_cycles++;

        /* Re-init with the saved NVS config (same path cellular_bring_up_task
         * uses). If config is missing, log and let Layer 3 reboot — there's
         * nothing useful we can do. */
        char apn[MODEM_APN_MAX], pin[MODEM_PIN_MAX];
        modem_lte_mode_t mode;
        if (modem_nvs_load(apn, sizeof(apn), pin, sizeof(pin), &mode) != ESP_OK) {
            ESP_LOGE(TAG, "watchdog: no NVS config to re-init with");
            continue;
        }
        if (modem_init(apn, pin, mode) != ESP_OK) {
            ESP_LOGE(TAG, "watchdog: modem_init after pulse failed");
            continue;
        }
        if (modem_connect() != ESP_OK) {
            ESP_LOGE(TAG, "watchdog: modem_connect after pulse failed");
            continue;
        }
        ESP_LOGI(TAG, "watchdog: recovered via Layer 2");
        s_consec_fails = 0;
        /* leave s_power_cycles as-is so the limit binds across rapid retries */
    }
}

void modem_start_watchdog(void) {
    if (s_watchdog_task) return;
    xTaskCreate(modem_watchdog_task, "modem_wdt", 4096, NULL, 2, &s_watchdog_task);
}

void modem_stop_watchdog(void) {
    /* P4: not used. Real implementation would vTaskDelete + null the
     * handle, but no caller needs that yet. Reserved for future use. */
}
```

- [ ] **Step 3:** Build. Commit `firmware(modem): watchdog task with PWRKEY-pulse Layer-2 recovery`.

### Task 3: Layer-1 PPP reconnect in network.c + start watchdog after cellular_bring_up

**Files:** Modify `mdb-slave-esp32s3/main/network.c`.

- [ ] **Step 1:** In `cellular_bring_up_task`, after `modem_connect` succeeds and state goes to `CELLULAR_UP`, call `modem_start_watchdog()`:

```c
    s_state = NETWORK_STATE_CELLULAR_UP;
    ESP_LOGI(TAG, "cellular up");
    modem_start_watchdog();
    network_fire_event(NETWORK_EVENT_UPLINK_UP);
```

- [ ] **Step 2:** Replace the existing `network_ppp_event_handler` body. Currently on `IP_EVENT_PPP_LOST_IP` it just sets `OFFLINE` + fires `UPLINK_DOWN`. Add Layer-1 logic — 3 fast reconnect attempts before falling through to OFFLINE:

```c
#define PPP_RECONNECT_ATTEMPTS  3
static int s_ppp_reconnect_attempts = 0;

static void ppp_reconnect_task(void *arg) {
    (void)arg;
    while (s_ppp_reconnect_attempts < PPP_RECONNECT_ATTEMPTS) {
        s_ppp_reconnect_attempts++;
        ESP_LOGW(TAG, "PPP reconnect attempt %d/%d",
                 s_ppp_reconnect_attempts, PPP_RECONNECT_ATTEMPTS);

        modem_disconnect();
        vTaskDelay(pdMS_TO_TICKS(2000));

        if (modem_connect() == ESP_OK) {
            ESP_LOGI(TAG, "PPP reconnect succeeded on attempt %d", s_ppp_reconnect_attempts);
            s_state = NETWORK_STATE_CELLULAR_UP;
            s_ppp_reconnect_attempts = 0;
            network_fire_event(NETWORK_EVENT_UPLINK_UP);
            vTaskDelete(NULL);
            return;
        }
    }
    /* All Layer-1 attempts exhausted — modem watchdog (Layer 2) will
     * pick up from here on its next tick. */
    ESP_LOGE(TAG, "PPP Layer-1 reconnect exhausted — handing off to watchdog");
    s_ppp_reconnect_attempts = 0;
    s_state = NETWORK_STATE_OFFLINE;
    network_fire_event(NETWORK_EVENT_UPLINK_DOWN);
    vTaskDelete(NULL);
}

static void network_ppp_event_handler(void *arg, esp_event_base_t event_base,
                                       int32_t event_id, void *event_data) {
    if (event_base != IP_EVENT) return;
    if (event_id == IP_EVENT_PPP_GOT_IP) {
        ESP_LOGI(TAG, "PPP GOT_IP");
        /* state transition handled in cellular_bring_up_task or
         * ppp_reconnect_task — this event is informational. */
    } else if (event_id == IP_EVENT_PPP_LOST_IP) {
        ESP_LOGW(TAG, "PPP LOST_IP");
        if (s_state == NETWORK_STATE_CELLULAR_UP) {
            /* Layer 1: spawn a reconnect task. We do this in a task
             * because modem_disconnect/modem_connect can take seconds,
             * and the event handler must not block. */
            xTaskCreate(ppp_reconnect_task, "ppp_reconn", 4096, NULL, 4, NULL);
        }
    }
}
```

- [ ] **Step 3:** Build. Commit `firmware(network): Layer-1 PPP reconnect (3 attempts) on PPP_LOST_IP`.

---

## Chunk 2: Verification + docs (Tasks 4–5)

### Task 4: Build sanity + module-size check

**Files:** none modified.

- [ ] **Step 1:** Build with both Kconfig configurations (no-flag and any leftover sdkconfig variations). Both should be clean.
- [ ] **Step 2:** Confirm `modem.c` is ≤ ~600 lines. If significantly above, extract the watchdog into `modem_watchdog.c` (file split) — but only if needed.
- [ ] **Step 3:** Grep for any inadvertent Layer-1/2 logic that escaped into `mdb-slave-esp32s3.c`:
```bash
grep -n "modem_power_cycle\|modem_at_keepalive\|modem_watchdog_task" mdb-slave-esp32s3/main/mdb-slave-esp32s3.c
```
Expected: empty (all watchdog calls live in modem.c + network.c).
- [ ] **Step 4:** No commit — verification only.

### Task 5: Update CLAUDE.md and document deferred hardware acceptance

**Files:** Modify `CLAUDE.md`.

- [ ] **Step 1:** Append a paragraph to the cellular section:

> **Cellular recovery (P4)**: 3-layer escalation. Layer 1 — `network.c::ppp_reconnect_task` retries `modem_disconnect`+`modem_connect` 3 times on `IP_EVENT_PPP_LOST_IP`, ~6 s total. Layer 2 — `modem.c::modem_watchdog_task` (30 s tick) escalates to `modem_power_cycle` (PWRKEY pulse) after 3 consecutive `AT` failures; bounded to 2 power-cycles before deferring to Layer 3. Layer 3 — existing `mqtt_watchdog_cb` hard-reboots after 10 min without MQTT (unchanged from pre-P4). MQTT keepalive bumps to 180 s + network/reconnect timeouts to 30 s/20 s when uplink is cellular at `esp_mqtt_client_init` time.

- [ ] **Step 2:** Hardware acceptance (DEFERRED to user testing):
  1. Antenna disconnect on LilyGo while online → expect Layer-1 messages within ~5 s, recovery (or Layer-2 trigger) within 60 s.
  2. Force-hang modem with `AT+CFUN=0` then disconnect serial cable → Layer-2 PWRKEY pulse + re-init within ~2 minutes.
  3. WiFi-only board boot regression: the watchdog task must NOT start (gated by network state). Verify via `pidof modem_wdt` not appearing in `esp_pthread_get_*_info()` or via log absence.

- [ ] **Step 3:** Build. Commit `firmware(network): document P4 watchdog + recovery in CLAUDE.md`.

---

## P4 DoD

- [ ] `modem_watchdog_task` exists and is gated by `modem_start_watchdog()` (not autostarted)
- [ ] `network_ppp_event_handler` spawns Layer-1 reconnect task on PPP_LOST_IP
- [ ] MQTT keepalive/timeouts conditionally apply cellular values
- [ ] WiFi-only boot path doesn't start the watchdog (no calls to `modem_start_watchdog()` in WiFi branches)
- [ ] modem.c stays ≤ ~600 lines
- [ ] Build clean
- [ ] Hardware acceptance pasted into Task 5 by user after empirical run.
