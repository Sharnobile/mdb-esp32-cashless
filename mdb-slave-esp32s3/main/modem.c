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

#define TAG "modem"

#define NVS_NAMESPACE   "vmflow"
#define NVS_KEY_APN     "apn"
#define NVS_KEY_PIN     "sim_pin"
#define NVS_KEY_MODE    "lte_mode"

#define MODEM_APN_MAX   64
#define MODEM_PIN_MAX   12

/* === Internal API — promoted to modem.h in P3 ===================== */
esp_err_t modem_nvs_load(char *apn_out, size_t apn_size,
                         char *pin_out, size_t pin_size,
                         modem_lte_mode_t *mode_out);
esp_err_t modem_nvs_save(const char *apn, const char *pin, modem_lte_mode_t mode);
/* ================================================================== */

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
