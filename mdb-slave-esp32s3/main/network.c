/*
 * VMflow.xyz
 *
 * network.c — Network manager implementation.
 *
 * Owns:
 *   - WIFI_EVENT / IP_EVENT handler (lifted out of mdb-slave-esp32s3.c
 *     in P2 C2 — Task 4)
 *   - WiFi STA reconnect-with-SoftAP-fallback policy
 *   - Boot-time modem probe + WiFi-vs-cellular branch (cellular branch
 *     lands in P2 C3)
 *   - SoftAP lifecycle (start/stop on demand, plus the implicit fallback
 *     after WIFI_SOFTAP_AFTER failed STA connect attempts)
 *
 * The single registered consumer callback receives UPLINK_UP/DOWN +
 * SOFTAP_STARTED/STOPPED. The app code (mdb-slave-esp32s3.c) uses that
 * callback to start MQTT, NTP, and the MQTT watchdog — instead of
 * touching WiFi events directly.
 */

#include "network.h"

#include <string.h>
#include <esp_log.h>
#include <esp_err.h>
#include <esp_wifi.h>
#include <esp_event.h>
#include <esp_netif.h>
#include <esp_timer.h>

#include "webui_server.h"

#define TAG "network"

/* SoftAP fallback policy — moved verbatim from mdb-slave-esp32s3.c
 * (was main.c lines 77-78). DO NOT change values without coordinating
 * with field-deployed firmware behaviour expectations. */
#define WIFI_SOFTAP_AFTER             5    /* start SoftAP after this many STA failures */
#define WIFI_RECONNECT_INTERVAL_SEC   60   /* retry WiFi every 60s while in SoftAP */

/* ---- Module state ---- */

static network_state_t      s_state = NETWORK_STATE_BOOTING;

static int                  s_wifi_retry_num = 0;
static bool                 s_softap_active  = false;
static esp_timer_handle_t   s_wifi_reconnect_timer = NULL;

static network_event_cb_t   s_event_cb = NULL;
static void                *s_event_user_data = NULL;

/* ---- Helpers ---- */

static void network_fire_event(network_event_t event) {
    if (s_event_cb) s_event_cb(event, s_event_user_data);
}

static void wifi_reconnect_timer_cb(void *arg) {
    (void)arg;
    ESP_LOGI(TAG, "WiFi reconnect timer: retrying esp_wifi_connect()");
    esp_wifi_connect();
}

/* ---- WIFI / IP event handler (lifted from mdb-slave-esp32s3.c) ----
 *
 * Behavioural translation rules vs the original:
 *   - All side-effect calls into webui_server.c (start_softap,
 *     start_dns_server, start_rest_server, stop_*) are kept unchanged.
 *   - State writes go to s_state and fire NETWORK_EVENT_UPLINK_UP /
 *     UPLINK_DOWN at the equivalent transition points.
 *   - The IP_EVENT_STA_GOT_IP branch ONLY does network-level cleanup +
 *     state update + UPLINK_UP fire. The app-level work that used to
 *     live here (provision_claim_task / sntp_init / esp_mqtt_client_start
 *     / mqtt_watchdog_timer setup) now happens in the consumer callback
 *     in mdb-slave-esp32s3.c.
 */
static void network_wifi_event_handler(void *arg, esp_event_base_t event_base, int32_t event_id, void *event_data) {

    if (event_base == WIFI_EVENT)
        switch (event_id) {
        case WIFI_EVENT_STA_START: {

            s_wifi_retry_num = 0;
            ESP_LOGI(TAG, "WIFI STA started");

            /* Check whether there is a saved SSID before attempting to connect.
             * esp_wifi_connect() with an empty SSID may return ESP_OK on some
             * IDF versions without ever emitting STA_DISCONNECTED, leaving the
             * SoftAP fallback unreachable. */
            wifi_config_t sta_cfg = {0};
            esp_wifi_get_config(WIFI_IF_STA, &sta_cfg);
            ESP_LOGI(TAG, "Saved SSID: \"%s\"", (char *)sta_cfg.sta.ssid);

            if (strlen((char *)sta_cfg.sta.ssid) == 0) {
                ESP_LOGI(TAG, "No saved WiFi credentials — starting SoftAP");
                start_softap();
                start_dns_server();
                start_rest_server();
                s_softap_active = true;
                s_state = NETWORK_STATE_SOFTAP_ONLY;
            } else {
                s_state = NETWORK_STATE_WIFI_CONNECTING;
                esp_err_t conn_err = esp_wifi_connect();
                ESP_LOGI(TAG, "esp_wifi_connect() → %s", esp_err_to_name(conn_err));
                if (conn_err != ESP_OK) {
                    ESP_LOGW(TAG, "Connect failed immediately — starting SoftAP");
                    start_softap();
                    start_dns_server();
                    start_rest_server();
                    s_softap_active = true;
                    s_state = NETWORK_STATE_SOFTAP_ONLY;
                }
            }
            break;
        }
        case WIFI_EVENT_AP_START:
            ESP_LOGI(TAG, "WIFI AP started — SSID \"" AP_SSID "\" should now be visible");
            break;
        case WIFI_EVENT_AP_STOP:
            ESP_LOGI(TAG, "WIFI AP stopped");
            break;
        case WIFI_EVENT_AP_STACONNECTED:
            ESP_LOGI(TAG, "Client connected to SoftAP");
            break;
        case WIFI_EVENT_STA_CONNECTED:
            break;
        case WIFI_EVENT_STA_DISCONNECTED: {

            /* Don't explicitly disconnect MQTT here — the MQTT client
             * detects the TCP loss itself and fires MQTT_EVENT_DISCONNECTED,
             * which resets mqtt_started. Calling esp_mqtt_client_disconnect()
             * on a dead socket can block or cause errors. */

            bool was_up = (s_state == NETWORK_STATE_WIFI_UP);

            s_wifi_retry_num++;

            if (s_wifi_retry_num <= WIFI_SOFTAP_AFTER) {
                /* Fast retries first */
                ESP_LOGW(TAG, "WiFi disconnected, retry %d/%d", s_wifi_retry_num, WIFI_SOFTAP_AFTER);
                s_state = NETWORK_STATE_WIFI_CONNECTING;
                esp_wifi_connect();
            } else if (!s_softap_active) {
                /* Start SoftAP for user access, but keep retrying via timer */
                ESP_LOGW(TAG, "WiFi retries exhausted — starting SoftAP + reconnect timer (every %ds)", WIFI_RECONNECT_INTERVAL_SEC);
                start_softap();
                start_dns_server();
                start_rest_server();
                s_softap_active = true;
                s_state = NETWORK_STATE_SOFTAP_ONLY;

                /* Start periodic reconnect timer */
                if (s_wifi_reconnect_timer == NULL) {
                    const esp_timer_create_args_t timer_args = {
                        .callback = wifi_reconnect_timer_cb,
                        .name = "wifi_reconnect"
                    };
                    esp_timer_create(&timer_args, &s_wifi_reconnect_timer);
                }
                esp_timer_start_periodic(s_wifi_reconnect_timer, WIFI_RECONNECT_INTERVAL_SEC * 1000000ULL);
            } else {
                /* SoftAP already active, timer handles retries — nothing to do */
                ESP_LOGI(TAG, "WiFi disconnected (SoftAP active, timer will retry)");
                s_state = NETWORK_STATE_SOFTAP_ONLY;
            }

            if (was_up) {
                network_fire_event(NETWORK_EVENT_UPLINK_DOWN);
            }
            break;
        }
        }

    if (event_base == IP_EVENT)
        switch (event_id) {
        case IP_EVENT_STA_GOT_IP: {

            ip_event_got_ip_t *event_ip = (ip_event_got_ip_t *)event_data;
            ESP_LOGW(TAG, "GOT IP: " IPSTR, IP2STR(&event_ip->ip_info.ip));

            s_wifi_retry_num = 0;

            /* Stop reconnect timer if running */
            if (s_wifi_reconnect_timer != NULL) {
                esp_timer_stop(s_wifi_reconnect_timer);
            }

            stop_rest_server();
            stop_dns_server();
            s_softap_active = false;

            /* Switch to STA-only mode now that we have a connection */
            esp_wifi_set_mode(WIFI_MODE_STA);

            s_state = NETWORK_STATE_WIFI_UP;
            network_fire_event(NETWORK_EVENT_UPLINK_UP);

            break;
        }
        }
}

/* ---- Public API ---- */

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
    s_event_cb = cb;
    s_event_user_data = user_data;
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
