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
