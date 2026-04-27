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
#include <freertos/semphr.h>
#include <driver/i2c_master.h>

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

/* PWRKEY polarity: true if the LilyGo board uses an inverting transistor
 * between ESP GPIO 41 and the SIM7080G PWRKEY pin (GPIO high → transistor
 * conducts → PWRKEY low = "press"). false if wired direct.
 *
 * Verified empirically against LilyGo's reference Arduino sketch which
 * does LOW → HIGH (1s) → LOW. That matches an inverting transistor:
 * ESP idles LOW, drives HIGH for 1s to assert PWRKEY low, then back.
 * Hence INVERTED = 1 for the LilyGo T-SIM7080G boards. */
#define MODEM_PWRKEY_INVERTED 1

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

/* The actual probe body — runs in a CPU-1-pinned helper task to dodge
 * an ESP-IDF v5.5.1 bug where iterating CPU-0 shared-vector descriptors
 * inside esp_intr_alloc trips an assert (find_desc_for_source
 * intr_alloc.c:199 svd != NULL). By running on CPU 1, the iteration
 * skips CPU-0 vectors entirely (else-if condition `vd->cpu == cpu`),
 * sidestepping the corrupted entry. The PPP netif and UART driver
 * end up bound to CPU 1, but that's fine — interrupts on either core
 * service the same UART hardware. */
static bool modem_probe_body(void);

typedef struct {
    SemaphoreHandle_t done;
    bool result;
} probe_args_t;

static void modem_probe_cpu1_task(void *arg) {
    probe_args_t *p = (probe_args_t *)arg;
    p->result = modem_probe_body();
    xSemaphoreGive(p->done);
    vTaskDelete(NULL);
}

bool modem_probe(void) {
    if (s_probed_present) {
        ESP_LOGI(TAG, "modem_probe: already probed (present)");
        return true;
    }

    probe_args_t args = { .done = xSemaphoreCreateBinary(), .result = false };
    if (!args.done) {
        ESP_LOGE(TAG, "modem_probe: semaphore alloc failed");
        return false;
    }
    BaseType_t ok = xTaskCreatePinnedToCore(modem_probe_cpu1_task,
                                              "modem_probe",
                                              8192, &args, 5, NULL, 1 /* CPU 1 */);
    if (ok != pdPASS) {
        ESP_LOGE(TAG, "modem_probe: failed to spawn CPU-1 task");
        vSemaphoreDelete(args.done);
        return false;
    }
    xSemaphoreTake(args.done, portMAX_DELAY);
    vSemaphoreDelete(args.done);
    return args.result;
}

/* === AXP2101 PMU power-up =============================================
 *
 * The LilyGo T-SIM7080G-S3 board has an AXP2101 power management IC that
 * gates the SIM7080G's main VBAT (DC3 channel, 3.0V) and the level-
 * conversion supply (BLDO1 channel, 3.3V) — both addressed via I2C.
 * Without these channels enabled the modem has zero power, ignores
 * PWRKEY pulses, and never responds on UART.
 *
 * Discovered by reading LilyGo's official ATDebug.ino reference sketch
 * (github.com/Xinyuan-LilyGO/LilyGo-T-SIM7080G/examples/ATDebug). Pin
 * candidates we tried earlier (GPIO 12/47/48 driven HIGH) were all
 * misses because there's no plain GPIO POWERON — it's I2C all the way.
 *
 * Register addresses come from XPowersLib/AXP2101Constants.h. We do
 * the bare-minimum sequence here in C without pulling the C++ library:
 *   1. Verify chip ID at 0x03 → 0x4A
 *   2. Set DC3 voltage (0x84) to 3000 mV (code 102)
 *   3. Enable DC3 (0x80, set bit 2) → modem main power
 *   4. Set BLDO1 voltage (0x96) to 3300 mV (code 28)
 *   5. Enable BLDO1 (0x90, set bit 4) → level-conversion supply
 *
 * If the AXP2101 isn't present (production WiFi-only PCB) the I2C probe
 * fails with ESP_ERR_TIMEOUT; we log and continue so the modem probe
 * sequence still runs (it'll bail out at AT-sync, just like before).
 */
#define AXP2101_I2C_PORT       I2C_NUM_1
#define AXP2101_I2C_SDA        GPIO_NUM_15
#define AXP2101_I2C_SCL        GPIO_NUM_7
#define AXP2101_SLAVE_ADDR     0x34
#define AXP2101_REG_CHIP_ID    0x03
#define AXP2101_CHIP_ID_VAL    0x4A
#define AXP2101_REG_DC_ONOFF   0x80
#define AXP2101_REG_DC3_VOL    0x84
#define AXP2101_REG_LDO_ONOFF0 0x90
#define AXP2101_REG_BLDO1_VOL  0x96

static i2c_master_bus_handle_t s_axp_bus = NULL;
static i2c_master_dev_handle_t s_axp_dev = NULL;

static esp_err_t axp_read_reg(uint8_t reg, uint8_t *out) {
    return i2c_master_transmit_receive(s_axp_dev, &reg, 1, out, 1, pdMS_TO_TICKS(100));
}

static esp_err_t axp_write_reg(uint8_t reg, uint8_t val) {
    uint8_t buf[2] = { reg, val };
    return i2c_master_transmit(s_axp_dev, buf, sizeof(buf), pdMS_TO_TICKS(100));
}

/* Read-modify-write: clear `clear_mask`, set bits in `set_mask`. */
static esp_err_t axp_rmw_reg(uint8_t reg, uint8_t clear_mask, uint8_t set_mask) {
    uint8_t v;
    esp_err_t err = axp_read_reg(reg, &v);
    if (err != ESP_OK) return err;
    v = (v & ~clear_mask) | set_mask;
    return axp_write_reg(reg, v);
}

/* Returns ESP_OK if AXP2101 was found and the modem rails were enabled.
 * Returns the I2C error otherwise. Idempotent — safe to call multiple
 * times in case the modem probe escalates. */
static esp_err_t modem_enable_pmu_rails(void) {
    if (!s_axp_bus) {
        i2c_master_bus_config_t bus_cfg = {
            .clk_source        = I2C_CLK_SRC_DEFAULT,
            .i2c_port          = AXP2101_I2C_PORT,
            .scl_io_num        = AXP2101_I2C_SCL,
            .sda_io_num        = AXP2101_I2C_SDA,
            .glitch_ignore_cnt = 7,
            .flags             = { .enable_internal_pullup = true },
        };
        esp_err_t err = i2c_new_master_bus(&bus_cfg, &s_axp_bus);
        if (err != ESP_OK) {
            ESP_LOGW(TAG, "PMU: i2c_new_master_bus failed: %s", esp_err_to_name(err));
            return err;
        }

        i2c_device_config_t dev_cfg = {
            .dev_addr_length = I2C_ADDR_BIT_LEN_7,
            .device_address  = AXP2101_SLAVE_ADDR,
            .scl_speed_hz    = 100000,
        };
        err = i2c_master_bus_add_device(s_axp_bus, &dev_cfg, &s_axp_dev);
        if (err != ESP_OK) {
            ESP_LOGW(TAG, "PMU: bus_add_device failed: %s", esp_err_to_name(err));
            i2c_del_master_bus(s_axp_bus);
            s_axp_bus = NULL;
            return err;
        }
    }

    uint8_t chip_id;
    esp_err_t err = axp_read_reg(AXP2101_REG_CHIP_ID, &chip_id);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "PMU: chip ID read failed (%s) — likely no AXP2101 on this board",
                 esp_err_to_name(err));
        return err;
    }
    if (chip_id != AXP2101_CHIP_ID_VAL) {
        ESP_LOGW(TAG, "PMU: unexpected chip ID 0x%02X (expected 0x%02X)",
                 chip_id, AXP2101_CHIP_ID_VAL);
        return ESP_ERR_INVALID_RESPONSE;
    }
    ESP_LOGI(TAG, "PMU: AXP2101 detected (chip ID 0x%02X)", chip_id);

    /* DC3 voltage = 3000 mV. AXP2101 DC3 voltage encoding has three ranges;
     * 1.6-3.4V at 100mV step starts at code 88. So 3000mV = 88 + 14 = 102. */
    uint8_t dc3_code = 102;
    err = axp_rmw_reg(AXP2101_REG_DC3_VOL, 0x7F, dc3_code & 0x7F);
    if (err != ESP_OK) { ESP_LOGE(TAG, "PMU: set DC3 voltage failed: %s", esp_err_to_name(err)); return err; }

    /* Enable DC3 (bit 2 of register 0x80) — modem main power */
    err = axp_rmw_reg(AXP2101_REG_DC_ONOFF, 0, 0x04);
    if (err != ESP_OK) { ESP_LOGE(TAG, "PMU: enable DC3 failed: %s", esp_err_to_name(err)); return err; }
    ESP_LOGI(TAG, "PMU: DC3 enabled at 3000 mV (modem main power)");

    /* BLDO1 voltage = 3300 mV. BLDO1 range 500-3500 mV at 100mV step,
     * code = (mV - 500) / 100. So 3300 → (3300-500)/100 = 28. */
    uint8_t bldo1_code = 28;
    err = axp_rmw_reg(AXP2101_REG_BLDO1_VOL, 0x1F, bldo1_code & 0x1F);
    if (err != ESP_OK) { ESP_LOGE(TAG, "PMU: set BLDO1 voltage failed: %s", esp_err_to_name(err)); return err; }

    /* Enable BLDO1 (bit 4 of register 0x90) — level conversion supply */
    err = axp_rmw_reg(AXP2101_REG_LDO_ONOFF0, 0, 0x10);
    if (err != ESP_OK) { ESP_LOGE(TAG, "PMU: enable BLDO1 failed: %s", esp_err_to_name(err)); return err; }
    ESP_LOGI(TAG, "PMU: BLDO1 enabled at 3300 mV (level-conversion supply)");

    /* Give the rails a moment to stabilise before the modem probes. */
    vTaskDelay(pdMS_TO_TICKS(200));
    return ESP_OK;
}

static bool modem_probe_body(void) {
    /* First enable modem power rails via the AXP2101 PMU. On a board
     * without the PMU (production WiFi-only) this is a no-op + warning;
     * on the LilyGo it's load-bearing. */
    esp_err_t pmu_err = modem_enable_pmu_rails();
    if (pmu_err != ESP_OK) {
        ESP_LOGW(TAG, "PMU init failed: %s — continuing anyway (will bail on AT timeout)",
                 esp_err_to_name(pmu_err));
    }

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
     * in modem_connect() is the load-bearing gate.
     *
     * Bumped to 8s timeout: a freshly-booted SIM7080G often takes 4-6s
     * to acknowledge config commands while internal init is still
     * running. With 3s some firmware revs always look "broken". */
    err = esp_modem_at(s_dce, "AT+CNMP=38", NULL, 8000);
    ESP_LOGI(TAG, "AT+CNMP=38: %s", esp_err_to_name(err));

    /* CMNB selects within LTE: 1=Cat-M, 2=NB-IoT, 3=both. */
    char cmnb_cmd[24];
    snprintf(cmnb_cmd, sizeof(cmnb_cmd), "AT+CMNB=%d", (int)mode);
    err = esp_modem_at(s_dce, cmnb_cmd, NULL, 8000);
    ESP_LOGI(TAG, "%s: %s", cmnb_cmd, esp_err_to_name(err));

    /* Configure APN via the esp_modem helper (writes AT+CGDCONT). This
     * one IS load-bearing — without an APN the modem cannot attach. */
    err = esp_modem_set_apn(s_dce, apn);
    ESP_LOGI(TAG, "esp_modem_set_apn(%s): %s", apn, esp_err_to_name(err));
    if (err != ESP_OK) return err;

    /* Enable +CEREG URC so we can poll registration cleanly later.
     * Best-effort like CNMP/CMNB. */
    esp_modem_at(s_dce, "AT+CEREG=1", NULL, 8000);

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

    /* Make sure RF is on (some modems boot at CFUN=4 = airplane).
     *
     * CFUN=1 is the load-bearing radio-enable command — without it the
     * modem stays in airplane mode and CEREG never fires. SIM7080G can
     * take 10-25 seconds to acknowledge CFUN=1 on cold boot because it
     * has to bring up the RF front-end, scan bands, and read the SIM
     * card before responding OK. Earlier 5s timeout was way too short
     * and made the cellular path silently broken on a fresh boot —
     * AT+CEREG? would then keep returning empty because the radio
     * hadn't actually come up yet. 30 s is the practical safe ceiling. */
    esp_err_t err = esp_modem_at(s_dce, "AT+CFUN=1", NULL, 30000);
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

    /* SIM7080G boot time after PWRKEY release: typically 6-8s, can be up
     * to ~12s on cold start. 5s was too aggressive — the modem was still
     * initialising when we issued AT+CFUN=1. 8s is a safer floor; the
     * 30s CFUN=1 timeout in modem_connect absorbs any remaining slack. */
    ESP_LOGI(TAG, "PWRKEY pulsed; waiting 8 s for boot...");
    vTaskDelay(pdMS_TO_TICKS(8000));
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
