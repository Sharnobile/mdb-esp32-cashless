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
