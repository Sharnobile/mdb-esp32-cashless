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
