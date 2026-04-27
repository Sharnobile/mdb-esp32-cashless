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
#include <esp_netif_ip_addr.h>
#include <esp_timer.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

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

/* ---- Cellular bring-up ----
 *
 * Background task that runs modem_init + modem_connect using the APN
 * stored in NVS. Spawned by network_init (when APN is already in NVS)
 * or by network_cellular_configure (when the captive portal saves a
 * fresh APN). Fires NETWORK_EVENT_UPLINK_UP on success.
 */
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

/* PPP status event handler — fires on NETIF_PPP_LOST_IP and friends.
 * For now we just log + transition state. P4 watchdog escalates. */
static void network_ppp_event_handler(void *arg, esp_event_base_t event_base,
                                       int32_t event_id, void *event_data) {
    (void)arg; (void)event_data;
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

/* ---- Public API ---- */

void network_init(void) {
    /* PPP handler registered unconditionally and BEFORE modem_probe — the
     * probe may toggle PPP state and we want the handler ready for
     * IP_EVENT_PPP_LOST_IP / GOT_IP either way. The WiFi handlers are
     * registered later (and only on the WiFi branch) since cellular-only
     * boards never run esp_wifi_init. */
    esp_event_handler_instance_register(IP_EVENT, IP_EVENT_PPP_GOT_IP,
                                         network_ppp_event_handler, NULL, NULL);
    esp_event_handler_instance_register(IP_EVENT, IP_EVENT_PPP_LOST_IP,
                                         network_ppp_event_handler, NULL, NULL);

    ESP_LOGI(TAG, "network_init: probing modem...");
    bool modem_present = modem_probe();
    ESP_LOGI(TAG, "modem_probe → %s", modem_present ? "true" : "false");

    if (modem_present) {
        ESP_LOGI(TAG, "cellular branch — WiFi STA will NOT be initialised");

        /* Bring up SoftAP only — the captive portal serves the
         * cellular config wizard (P3) so the user can enter APN/PIN.
         * P3 wires this; for now we still need SoftAP up so the user
         * has something to talk to. We init WiFi in AP-only mode and
         * start the radio here so network_start_softap() can apply
         * the AP config. */
        esp_netif_create_default_wifi_ap();
        wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
        esp_wifi_init(&cfg);
        esp_wifi_set_mode(WIFI_MODE_AP);
        esp_wifi_start();
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

    /* ---- WiFi-only branch ---- */
    s_state = NETWORK_STATE_WIFI_CONNECTING;

    esp_netif_create_default_wifi_sta();
    esp_netif_create_default_wifi_ap();

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    esp_wifi_init(&cfg);

    esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID,
                                         network_wifi_event_handler, NULL, NULL);
    esp_event_handler_instance_register(IP_EVENT, ESP_EVENT_ANY_ID,
                                         network_wifi_event_handler, NULL, NULL);

    /* APSTA so SoftAP can come up alongside STA on demand. The handler
     * narrows mode back to STA-only on IP_EVENT_STA_GOT_IP. */
    esp_wifi_set_mode(WIFI_MODE_APSTA);
    esp_wifi_start();
}

network_state_t network_get_state(void) {
    return s_state;
}

void network_get_status(network_status_t *out) {
    if (!out) return;
    memset(out, 0, sizeof(*out));
    out->state = s_state;
    out->uplink_up = (s_state == NETWORK_STATE_WIFI_UP || s_state == NETWORK_STATE_CELLULAR_UP);

    if (s_state == NETWORK_STATE_WIFI_UP)        strcpy(out->uplink_kind, "wifi");
    else if (s_state == NETWORK_STATE_CELLULAR_UP) strcpy(out->uplink_kind, "cellular");
    else                                          strcpy(out->uplink_kind, "none");

    /* WiFi block — populated only when WiFi STA has been initialised
     * AND a SSID has been saved/configured. esp_wifi_get_config returns
     * an error pre-init or when WiFi was never started (cellular boards),
     * so we use it as the gate. */
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

    /* Cellular block — populated only if modem was detected (we sit in
     * one of the cellular states or in SOFTAP_ONLY post-cellular-branch). */
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

void network_register_callback(network_event_cb_t cb, void *user_data) {
    s_event_cb = cb;
    s_event_user_data = user_data;
}

esp_err_t network_start_softap(void) {
    if (s_softap_active) {
        ESP_LOGI(TAG, "network_start_softap: already active");
        return ESP_OK;
    }
    start_softap();
    start_dns_server();
    start_rest_server();
    s_softap_active = true;
    network_fire_event(NETWORK_EVENT_SOFTAP_STARTED);
    return ESP_OK;
}

esp_err_t network_stop_softap(void) {
    if (!s_softap_active) {
        return ESP_OK;
    }
    stop_rest_server();
    stop_dns_server();
    s_softap_active = false;
    network_fire_event(NETWORK_EVENT_SOFTAP_STOPPED);
    return ESP_OK;
}

esp_err_t network_cellular_configure(const char *apn, const char *pin, modem_lte_mode_t mode) {
    /* Reject re-entry while a bring-up is in flight. Without this guard a
     * rapidly-resubmitting captive portal could spawn parallel cell_up
     * tasks racing on s_state and double-firing UPLINK_UP. */
    if (s_state == NETWORK_STATE_CELLULAR_REGISTERING) {
        ESP_LOGW(TAG, "network_cellular_configure: bring-up already in progress");
        return ESP_ERR_INVALID_STATE;
    }

    esp_err_t err = modem_nvs_save(apn, pin, mode);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "network_cellular_configure: modem_nvs_save failed: %s",
                 esp_err_to_name(err));
        return err;
    }
    /* Spawn the bring-up task — same one network_init uses. */
    xTaskCreate(cellular_bring_up_task, "cell_up", 4096, NULL, 4, NULL);
    return ESP_OK;
}

esp_err_t network_wifi_configure(const char *ssid, const char *password) {
    (void)ssid; (void)password;
    ESP_LOGW(TAG, "network_wifi_configure: stub returns ESP_ERR_NOT_SUPPORTED");
    return ESP_ERR_NOT_SUPPORTED;
}
