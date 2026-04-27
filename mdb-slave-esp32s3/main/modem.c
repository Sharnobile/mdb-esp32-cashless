/*
 * VMflow.xyz
 *
 * modem.c — SIM7080G driver implementation
 */

#include "modem.h"

#include <string.h>
#include <esp_log.h>
#include <esp_err.h>
#include <nvs.h>

#include <esp_modem_api.h>
#include <esp_netif_ppp.h>
#include <esp_netif.h>
#include <driver/gpio.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

#define TAG "modem"

#define NVS_NAMESPACE   "vmflow"
#define NVS_KEY_APN     "apn"
#define NVS_KEY_PIN     "sim_pin"
#define NVS_KEY_MODE    "lte_mode"

/* LilyGo T-SIM7080G-S3 standard pinout, confirmed by user 2026-04-27.
 * The earlier 18/17/14 defines were inherited from Leonardo's custom-PCB
 * attempt (commit d3f8b05) and crashed during uart_driver_install on
 * actual hardware because they don't match anything on a real LilyGo.
 *
 * LilyGo T-SIM7080G-S3 (verified by user):
 *   PWRKEY:  GPIO 41   active-LOW direct (no transistor inversion)
 *   MODEM_TX (ESP→SIM): GPIO 5
 *   MODEM_RX (SIM→ESP): GPIO 4
 *   RI:      GPIO 3   (not used in P1)
 *   DTR:     GPIO 42  (not used in P1)
 *
 * NOTE: GPIO 4 and 5 alias PIN_MDB_RX/PIN_MDB_TX in mdb-slave-esp32s3.c.
 * On the LilyGo the MDB hardware is absent so the alias is harmless —
 * MDB code sets these as inputs at boot (idle high-Z), which doesn't
 * conflict with the modem's later UART matrix re-routing. On a future
 * board variant with BOTH MDB and the modem, these defines must move
 * into Kconfig and the two functions must use different pins. */
#define MODEM_PIN_RX    GPIO_NUM_4    /* SIM7080G TX → ESP RX */
#define MODEM_PIN_TX    GPIO_NUM_5    /* ESP TX → SIM7080G RX */
#define MODEM_PIN_PWR   GPIO_NUM_41   /* PWRKEY active-LOW direct */
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

/* Load cellular config from NVS. Returns ESP_OK on success and fills the
 * outputs; returns ESP_ERR_NVS_NOT_FOUND if either the vmflow namespace
 * does not exist yet OR the apn key is missing/empty (caller treats both
 * as "no cellular config saved"). Returns ESP_ERR_INVALID_ARG if apn_out
 * is NULL or apn_size is 0. */
esp_err_t modem_nvs_load(char *apn_out, size_t apn_size,
                         char *pin_out, size_t pin_size,
                         modem_lte_mode_t *mode_out) {
    if (!apn_out || apn_size == 0) return ESP_ERR_INVALID_ARG;

    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NAMESPACE, NVS_READONLY, &h);
    if (err == ESP_ERR_NVS_NOT_FOUND) return ESP_ERR_NVS_NOT_FOUND;
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
        /* Reject garbage from a corrupted or hand-edited NVS. */
        if (m < MODEM_LTE_MODE_CATM || m > MODEM_LTE_MODE_BOTH) {
            m = MODEM_LTE_MODE_BOTH;
        }
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

bool modem_probe(void) {
    if (s_probed_present) {
        ESP_LOGI(TAG, "modem_probe: already probed (present)");
        return true;
    }

    /* Why no GPIO heuristic anymore:
     *
     * Earlier versions tried to gate the probe on a quiescent reading of
     * the PWRKEY pin (assumption: modem-internal pull-up holds it high).
     * That assumption is wrong for the LilyGo T-SIM7080G-S3 — the
     * SIM7080G is *off* at cold boot (VBAT is gated by an external
     * MOSFET driven by PWRKEY itself, classic chicken-and-egg), so the
     * line reads low until we *pulse* PWRKEY. The heuristic therefore
     * always failed on the LilyGo and the probe never woke the modem.
     *
     * New strategy: always go through the full probe sequence (sync →
     * PPP-escape → power-pulse → sync) regardless of GPIO state. On a
     * board with no modem this still bails out gracefully (sync
     * timeouts, ~13 s total worst case), it just toggles GPIO 41
     * harmlessly along the way. If a future production WiFi-only PCB
     * routes GPIO 41 to something that *cares* about being toggled, we
     * can re-introduce a board-variant Kconfig gate then. */

    /* Build the temporary DTE/DCE. */
    esp_modem_dte_config_t dte_config = ESP_MODEM_DTE_DEFAULT_CONFIG();
    dte_config.uart_config.port_num   = MODEM_UART_PORT;
    dte_config.uart_config.baud_rate  = MODEM_BAUD;
    dte_config.uart_config.tx_io_num  = MODEM_PIN_TX;
    dte_config.uart_config.rx_io_num  = MODEM_PIN_RX;
    dte_config.uart_config.rts_io_num = -1;
    dte_config.uart_config.cts_io_num = -1;
    /* event_queue_size stays at the default 30 — esp_modem's UartTerminal
     * task asserts on a NULL event queue, so we cannot disable it.
     * The intr_alloc-shared-vector workaround for IDF v5.5.1 is in the
     * esp_modem managed_components patch (see modem_components_patch). */

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
        /* Modem either off (LilyGo cold boot) or absent. Pulse PWRKEY:
         * if a modem is wired up this turns it on; if not, the pulse
         * is harmless on most boards (revisit if a production PCB
         * connects GPIO 41 to something sensitive). */
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

bool modem_is_present(void) {
    return s_probed_present;
}

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

    /* Network mode: 38 = LTE only (we don't want GSM fallback).
     * CNMP/CMNB/CEREG=1 are best-effort — some SIM7080G firmware revisions
     * accept the value but still negotiate the right RAT, others reject
     * the command and pick a default that's good enough. We log the
     * outcome but do not fail modem_init() on it; the registration check
     * in modem_connect() is the load-bearing gate. */
    err = esp_modem_at(s_dce, "AT+CNMP=38", NULL, 3000);
    ESP_LOGI(TAG, "AT+CNMP=38: %s", esp_err_to_name(err));

    /* CMNB selects within LTE: 1=Cat-M, 2=NB-IoT, 3=both. */
    char cmnb_cmd[24];
    snprintf(cmnb_cmd, sizeof(cmnb_cmd), "AT+CMNB=%d", (int)mode);
    err = esp_modem_at(s_dce, cmnb_cmd, NULL, 3000);
    ESP_LOGI(TAG, "%s: %s", cmnb_cmd, esp_err_to_name(err));

    /* Configure APN via the esp_modem helper (writes AT+CGDCONT). This
     * one IS load-bearing — without an APN the modem cannot attach. */
    err = esp_modem_set_apn(s_dce, apn);
    ESP_LOGI(TAG, "esp_modem_set_apn(%s): %s", apn, esp_err_to_name(err));
    if (err != ESP_OK) return err;

    /* Enable +CEREG URC so we can poll registration cleanly later.
     * Best-effort like CNMP/CMNB. */
    esp_modem_at(s_dce, "AT+CEREG=1", NULL, 3000);

    return ESP_OK;
}

/* Extract the registration `stat` field from a +CEREG response.
 * Format: "+CEREG: <n>,<stat>[,...]". Returns -1 if unparseable. */
static int parse_cereg_stat(const char *resp) {
    const char *p = strstr(resp, "+CEREG:");
    if (!p) return -1;
    int n = 0, stat = -1;
    if (sscanf(p, "+CEREG: %d,%d", &n, &stat) != 2) return -1;
    return stat;
}

/* Poll AT+CEREG? until stat == 1 (home) or 5 (roaming). Up to 60 s.
 * Uses positional parsing rather than strstr(",1") to avoid false
 * positives on trailing AcT or location fields. */
static esp_err_t modem_wait_registered(void) {
    /* esp_modem_at copies up to CONFIG_ESP_MODEM_C_API_STR_MAX (128) bytes
     * regardless of buffer size — match that to avoid stack overflow on
     * verbose firmware responses. */
    char resp[128];
    for (int i = 0; i < 30; i++) {
        memset(resp, 0, sizeof(resp));
        esp_err_t err = esp_modem_at(s_dce, "AT+CEREG?", resp, 3000);
        if (err == ESP_OK) {
            int stat = parse_cereg_stat(resp);
            if (stat == 1 || stat == 5) {
                ESP_LOGI(TAG, "EPS registered (stat=%d): %s", stat, resp);
                return ESP_OK;
            }
        }
        ESP_LOGW(TAG, "not registered (attempt %d/30): %s", i + 1, resp);
        vTaskDelay(pdMS_TO_TICKS(2000));
    }
    return ESP_ERR_TIMEOUT;
}

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

esp_err_t modem_disconnect(void) {
    if (!s_dce) return ESP_OK;
    esp_err_t err = esp_modem_set_mode(s_dce, ESP_MODEM_MODE_COMMAND);
    ESP_LOGI(TAG, "set COMMAND mode: %s", esp_err_to_name(err));
    return err;
}

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

/* Convert AT+CSQ raw value (0-31, 99 = unknown) to dBm. Per 3GPP 27.007:
 *   raw = 0   → -113 dBm
 *   raw = 31  → -51 dBm
 *   raw = 99  → unknown (return 0)
 *   else      → -113 + 2 * raw */
static int8_t csq_to_dbm(int raw) {
    if (raw == 99 || raw < 0 || raw > 31) return 0;
    return -113 + (raw * 2);
}

void modem_status(modem_status_t *out) {
    if (!out) return;
    memset(out, 0, sizeof(*out));
    out->active_mode = MODEM_LTE_MODE_BOTH;

    if (!s_dce) return;

    /* Buffer size matches CONFIG_ESP_MODEM_C_API_STR_MAX (128) — see
     * modem_wait_registered() for the rationale. */
    char resp[128];

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

    /* Registration — positional parse to avoid false positives on
     * trailing AcT/location fields. */
    if (esp_modem_at(s_dce, "AT+CEREG?", resp, 2000) == ESP_OK) {
        int stat = parse_cereg_stat(resp);
        out->registered = (stat == 1 || stat == 5);
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

#define WATCHDOG_TICK_SEC            30
#define WATCHDOG_FAIL_TO_POWER_CYCLE  3
#define WATCHDOG_POWER_CYCLE_LIMIT    2

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
