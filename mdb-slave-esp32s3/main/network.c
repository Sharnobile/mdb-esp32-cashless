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
#include "freertos/event_groups.h"

#include "webui_server.h"

/* PPP synchronisation: esp_modem_set_mode(DATA) returns as soon as PPP
 * starts negotiating, NOT when IPCP completes — at that moment lwIP has
 * no IP, no DNS server, and no default route. If we fired UPLINK_UP
 * here, MQTT/HTTP clients would immediately try getaddrinfo() and fail
 * with EAI_NODATA. We therefore wait for IP_EVENT_PPP_GOT_IP (set as a
 * bit on this event group from network_ppp_event_handler) before
 * declaring the cellular uplink up. */
#define PPP_GOT_IP_BIT          BIT0
static EventGroupHandle_t       s_ppp_event_group = NULL;

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
                network_fire_event(NETWORK_EVENT_SOFTAP_STARTED);
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
                    network_fire_event(NETWORK_EVENT_SOFTAP_STARTED);
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
                network_fire_event(NETWORK_EVENT_SOFTAP_STARTED);

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

    /* esp_modem_set_mode(DATA) only kicks PPP off — it doesn't wait for
     * IPCP to install IP/DNS/route. Without this wait the upstream
     * UPLINK_UP consumer (claim task, MQTT client) hits getaddrinfo
     * with no DNS server and fails with EAI_NODATA. PPP IPCP is
     * usually <2s; allow up to 30s on slow carriers. */
    if (s_ppp_event_group) {
        EventBits_t bits = xEventGroupWaitBits(s_ppp_event_group, PPP_GOT_IP_BIT,
                                               pdFALSE, pdTRUE, pdMS_TO_TICKS(30000));
        if (!(bits & PPP_GOT_IP_BIT)) {
            ESP_LOGE(TAG, "PPP IPCP timeout — no IP after 30s");
            s_state = NETWORK_STATE_OFFLINE;
            vTaskDelete(NULL);
            return;
        }
    }

    s_state = NETWORK_STATE_CELLULAR_UP;
    ESP_LOGI(TAG, "cellular up");
    /* Start the modem watchdog (Layer 2 recovery). Idempotent — re-spawning
     * cellular_bring_up_task after a Layer-2 power-cycle won't double-start
     * the task. Gated to this task ONLY so WiFi-only boards never spawn it. */
    modem_start_watchdog();
    network_fire_event(NETWORK_EVENT_UPLINK_UP);
    vTaskDelete(NULL);
}

/* Layer 1 PPP reconnect: 3 fast attempts via modem_disconnect + modem_connect
 * before falling back to OFFLINE (where the modem watchdog Layer 2 picks up
 * on its next tick). Total worst-case duration ~6-30s depending on how long
 * each modem_connect takes (CFUN + registration + PPP). */
#define PPP_RECONNECT_ATTEMPTS  3
#define OFFLINE_RETRY_DELAY_S   30
static int s_ppp_reconnect_attempts = 0;
static void schedule_offline_retry(void);

static void ppp_reconnect_task(void *arg) {
    (void)arg;
    while (s_ppp_reconnect_attempts < PPP_RECONNECT_ATTEMPTS) {
        s_ppp_reconnect_attempts++;
        ESP_LOGW(TAG, "PPP reconnect attempt %d/%d",
                 s_ppp_reconnect_attempts, PPP_RECONNECT_ATTEMPTS);

        modem_disconnect();
        vTaskDelay(pdMS_TO_TICKS(2000));

        if (modem_connect() == ESP_OK) {
            ESP_LOGI(TAG, "PPP reconnect: modem_connect ok, waiting for IPCP");
            /* Same gate as cellular_bring_up_task — wait for actual
             * IP/DNS install, not just for set_mode(DATA) to return. */
            if (s_ppp_event_group) {
                EventBits_t bits = xEventGroupWaitBits(s_ppp_event_group, PPP_GOT_IP_BIT,
                                                       pdFALSE, pdTRUE, pdMS_TO_TICKS(30000));
                if (!(bits & PPP_GOT_IP_BIT)) {
                    ESP_LOGW(TAG, "PPP reconnect: IPCP timeout, retrying");
                    continue;
                }
            }
            ESP_LOGI(TAG, "PPP reconnect succeeded on attempt %d", s_ppp_reconnect_attempts);
            s_state = NETWORK_STATE_CELLULAR_UP;
            s_ppp_reconnect_attempts = 0;
            network_fire_event(NETWORK_EVENT_UPLINK_UP);
            vTaskDelete(NULL);
            return;
        }
    }
    /* All Layer-1 attempts exhausted — drop to OFFLINE and schedule a
     * delayed retry. Without this, OFFLINE was a dead-end: the modem
     * watchdog (Layer 2) only fires on AT-ping failure and skips the
     * ping entirely while PPP looks alive, so it could miss the
     * unreachable state for minutes; mqtt_watchdog (Layer 3) only
     * hard-reboots after 10 min. We prefer to keep retrying.
     *
     * Schedule a fresh cellular_bring_up_task after OFFLINE_RETRY_DELAY_S
     * — that path runs the full modem_init + modem_connect sequence,
     * which is the right thing to do if Layer 1 couldn't recover (e.g.
     * the modem itself is hung and needs power-cycling, or registration
     * was lost). */
    ESP_LOGE(TAG, "PPP Layer-1 reconnect exhausted — dropping to OFFLINE, "
                  "will retry in %d s", OFFLINE_RETRY_DELAY_S);
    s_ppp_reconnect_attempts = 0;
    s_state = NETWORK_STATE_OFFLINE;
    network_fire_event(NETWORK_EVENT_UPLINK_DOWN);
    schedule_offline_retry();
    vTaskDelete(NULL);
}

/* Periodic retry while in OFFLINE — re-spawns cellular_bring_up_task
 * after a fixed delay. Independent of the modem watchdog so we recover
 * even when AT pings are skipped (which happens whenever PPP looks
 * locally alive even though carrier-side is dead). */
static esp_timer_handle_t s_offline_retry_timer = NULL;

static void offline_retry_cb(void *arg) {
    (void)arg;
    if (s_state != NETWORK_STATE_OFFLINE) {
        ESP_LOGI(TAG, "offline retry: state changed to %d, skipping", s_state);
        return;
    }
    ESP_LOGW(TAG, "offline retry: re-spawning cellular_bring_up_task");
    s_state = NETWORK_STATE_CELLULAR_REGISTERING;
    xTaskCreate(cellular_bring_up_task, "cell_up", 4096, NULL, 4, NULL);
}

static void schedule_offline_retry(void) {
    if (!s_offline_retry_timer) {
        const esp_timer_create_args_t args = {
            .callback = offline_retry_cb,
            .name     = "offline_retry"
        };
        esp_timer_create(&args, &s_offline_retry_timer);
    }
    /* one-shot — re-armed by next exhaustion */
    esp_timer_stop(s_offline_retry_timer);
    esp_timer_start_once(s_offline_retry_timer, OFFLINE_RETRY_DELAY_S * 1000000ULL);
}

/* PPP status event handler — fires on NETIF_PPP_LOST_IP and friends.
 * On LOST_IP we spawn ppp_reconnect_task (Layer 1) instead of dropping
 * straight to OFFLINE. */
static void network_ppp_event_handler(void *arg, esp_event_base_t event_base,
                                       int32_t event_id, void *event_data) {
    (void)arg; (void)event_data;
    if (event_base != IP_EVENT) return;
    if (event_id == IP_EVENT_PPP_GOT_IP) {
        ip_event_got_ip_t *ev = (ip_event_got_ip_t *)event_data;
        ESP_LOGI(TAG, "PPP GOT_IP: " IPSTR, IP2STR(&ev->ip_info.ip));

        /* Force PPP as the outbound default netif. Otherwise the SoftAP
         * (route_prio 10) competes with PPP (20) — usually PPP wins,
         * but we set it explicitly to remove ambiguity. */
        esp_netif_set_default_netif(ev->esp_netif);

        /* Make sure DNS works.
         *
         * CONFIG_ESP_NETIF_SET_DNS_PER_DEFAULT_NETIF is off, so lwIP
         * uses the global dns_setserver list. The carrier *should* push
         * DNS during IPCP, but several APNs (sensors.net included) don't,
         * leaving the list empty and getaddrinfo() returning EAI_NONAME
         * (errno 202). Read whatever the PPP layer negotiated, and only
         * force public fallbacks if both slots are empty. */
        esp_netif_dns_info_t main_dns, backup_dns;
        bool have_main = (esp_netif_get_dns_info(ev->esp_netif, ESP_NETIF_DNS_MAIN, &main_dns) == ESP_OK
                          && main_dns.ip.u_addr.ip4.addr != 0);
        bool have_backup = (esp_netif_get_dns_info(ev->esp_netif, ESP_NETIF_DNS_BACKUP, &backup_dns) == ESP_OK
                            && backup_dns.ip.u_addr.ip4.addr != 0);
        char main_str[16] = "(none)", backup_str[16] = "(none)";
        if (have_main)   esp_ip4addr_ntoa(&main_dns.ip.u_addr.ip4,   main_str,   sizeof(main_str));
        if (have_backup) esp_ip4addr_ntoa(&backup_dns.ip.u_addr.ip4, backup_str, sizeof(backup_str));
        ESP_LOGI(TAG, "PPP DNS: main=%s backup=%s", main_str, backup_str);

        if (!have_main) {
            esp_netif_dns_info_t fallback = { 0 };
            fallback.ip.type = ESP_IPADDR_TYPE_V4;
            fallback.ip.u_addr.ip4.addr = esp_ip4addr_aton("8.8.8.8");
            esp_netif_set_dns_info(ev->esp_netif, ESP_NETIF_DNS_MAIN, &fallback);
            ESP_LOGW(TAG, "PPP DNS: carrier did not push DNS — installing 8.8.8.8 as primary");
        }
        if (!have_backup) {
            esp_netif_dns_info_t fallback = { 0 };
            fallback.ip.type = ESP_IPADDR_TYPE_V4;
            fallback.ip.u_addr.ip4.addr = esp_ip4addr_aton("1.1.1.1");
            esp_netif_set_dns_info(ev->esp_netif, ESP_NETIF_DNS_BACKUP, &fallback);
            ESP_LOGW(TAG, "PPP DNS: installing 1.1.1.1 as backup");
        }

        /* Unblock cellular_bring_up_task / ppp_reconnect_task, which
         * wait on this bit before declaring uplink up. esp_modem_set_mode
         * returns before IPCP finishes, so we MUST gate UPLINK_UP on
         * this event — otherwise upstream code (claim, MQTT) runs
         * getaddrinfo before lwIP has installed any DNS server. */
        if (s_ppp_event_group) {
            xEventGroupSetBits(s_ppp_event_group, PPP_GOT_IP_BIT);
        }
    } else if (event_id == IP_EVENT_PPP_LOST_IP) {
        ESP_LOGW(TAG, "PPP LOST_IP");
        if (s_ppp_event_group) {
            xEventGroupClearBits(s_ppp_event_group, PPP_GOT_IP_BIT);
        }
        if (s_state == NETWORK_STATE_CELLULAR_UP) {
            /* Layer 1: spawn a reconnect task. We do this in a task
             * because modem_disconnect/modem_connect can take seconds,
             * and the event handler must not block. */
            xTaskCreate(ppp_reconnect_task, "ppp_reconn", 4096, NULL, 4, NULL);
        }
    }
}

/* ---- Public API ---- */

void network_init(void) {
    /* PPP IPCP-completion event group — created before any handler
     * registration so the GOT_IP callback always finds a non-NULL handle. */
    if (!s_ppp_event_group) s_ppp_event_group = xEventGroupCreate();

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

    /* Cellular block — populated whenever a modem was successfully
     * probed at boot, regardless of current network state. modem_status
     * is a pure cache read (no AT, no blocking), and the cache holds
     * the last-known operator/rssi/mode/registered values from the
     * registration loop and post-CEREG COPS query.
     *
     * Earlier this branch gated on `s_state in
     * {REGISTERING, CELLULAR_UP, SOFTAP_ONLY}`, which made the captive
     * portal banner suddenly show empty Signal/Operator/Mode whenever
     * the state machine flipped to OFFLINE briefly (e.g. mid-PPP
     * reconnect, or any other state transition glitch). Reported in
     * the field as "Daten verschwinden nach einigen Sekunden" — the
     * user sees stale-but-correct data evaporate just because the
     * state momentarily moved. Always-on cellular block fixes that
     * without any data integrity concern: if the modem is present,
     * the cache is meaningful. */
    if (modem_is_present()) {
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
    if (!ssid || strlen(ssid) == 0) return ESP_ERR_INVALID_ARG;

    /* On cellular boards (modem present) we deliberately ignore WiFi
     * credentials — policy is cellular-only when modem detected. */
    if (s_state == NETWORK_STATE_SOFTAP_ONLY ||
        s_state == NETWORK_STATE_CELLULAR_REGISTERING ||
        s_state == NETWORK_STATE_CELLULAR_UP) {
        ESP_LOGW(TAG, "network_wifi_configure: ignored on cellular board");
        return ESP_ERR_NOT_SUPPORTED;
    }

    wifi_config_t cfg = {0};
    esp_wifi_get_config(WIFI_IF_STA, &cfg);
    strncpy((char *)cfg.sta.ssid,     ssid,     sizeof(cfg.sta.ssid)     - 1);
    strncpy((char *)cfg.sta.password, password ? password : "",
                                                sizeof(cfg.sta.password) - 1);
    esp_err_t err = esp_wifi_set_config(WIFI_IF_STA, &cfg);
    if (err != ESP_OK) return err;

    return esp_wifi_connect();
}
