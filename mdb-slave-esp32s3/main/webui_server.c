#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_wifi.h"
#include "esp_http_server.h"
#include "nvs_flash.h"
#include "cJSON.h"
#include <esp_log.h>
#include "lwip/udp.h"
#include "lwip/ip_addr.h"
#include "esp_chip_info.h"
#include "webui_server.h"
#include "network.h"
#include "modem.h"
#include "provision.h"

#define TAG "webui"


static httpd_handle_t rest_server = NULL;

extern const uint8_t index_html_start[] asm("_binary_index_html_start");
extern const uint8_t index_html_end[]   asm("_binary_index_html_end");
static struct udp_pcb *dns_pcb;

/* -----------     DNS captive portal     ---------- */

static void dns_recv(void *arg, struct udp_pcb *pcb, struct pbuf *p, const ip_addr_t *addr, u16_t port) {

    if (!p) return;

    uint8_t *data = (uint8_t *)p->payload;
    data[2] |= 0x80;  // QR = response
    data[3] |= 0x80;  // RA = recursion available
    data[7]  = 1;     // ANCOUNT = 1

    uint8_t response[] = {
        0xC0, 0x0C,             // pointer to domain name
        0x00, 0x01,             // type A
        0x00, 0x01,             // class IN
        0x00, 0x00, 0x00, 0x3C, // TTL 60s
        0x00, 0x04,             // data length
        192, 168, 4, 1          // AP IP
    };

    struct pbuf *resp = pbuf_alloc(PBUF_TRANSPORT, p->len + sizeof(response), PBUF_RAM);
    memcpy(resp->payload, data, p->len);
    memcpy((uint8_t *)resp->payload + p->len, response, sizeof(response));
    udp_sendto(pcb, resp, addr, port);
    pbuf_free(resp);
    pbuf_free(p);
}

/* ---------- HTTP handlers ---------- */

static esp_err_t index_get_handler(httpd_req_t *req) {
    const size_t html_len = index_html_end - index_html_start;
    httpd_resp_set_type(req, "text/html");
    httpd_resp_send(req, (const char *)index_html_start, html_len);
    return ESP_OK;
}

static const char *wizard_state_str(network_state_t s) {
    switch (s) {
        case NETWORK_STATE_BOOTING:               return "booting";
        case NETWORK_STATE_OFFLINE:               return "offline";
        case NETWORK_STATE_SOFTAP_ONLY:           return "cellular_config";
        case NETWORK_STATE_WIFI_CONNECTING:       return "wifi_connecting";
        case NETWORK_STATE_WIFI_UP:               return "ready_to_claim";  /* if not claimed yet */
        case NETWORK_STATE_CELLULAR_REGISTERING:  return "cellular_registering";
        case NETWORK_STATE_CELLULAR_UP:           return "ready_to_claim";  /* if not claimed yet */
    }
    return "unknown";
}

static const char *lte_mode_str(modem_lte_mode_t m) {
    switch (m) {
        case MODEM_LTE_MODE_CATM:  return "LTE-M";
        case MODEM_LTE_MODE_NBIOT: return "NB-IoT";
        case MODEM_LTE_MODE_BOTH:  return "Auto";
    }
    return "unknown";
}

static esp_err_t system_info_get_handler(httpd_req_t *req) {
    network_status_t st;
    network_get_status(&st);

    /* Read claim status from NVS */
    char company_id[40] = "";
    char prov_code[16]  = "";
    nvs_handle_t h;
    if (nvs_open("vmflow", NVS_READONLY, &h) == ESP_OK) {
        size_t sl = sizeof(company_id);
        nvs_get_str(h, "company_id", company_id, &sl);
        sl = sizeof(prov_code);
        nvs_get_str(h, "prov_code", prov_code, &sl);
        nvs_close(h);
    }
    bool claimed       = (strlen(company_id) > 0);
    bool prov_code_set = (strlen(prov_code)  > 0);

    /* Variant is keyed off the actual probe outcome, NOT off the current
     * network state. SOFTAP_ONLY can mean either "cellular board waiting
     * for APN" OR "WiFi-only board with no saved creds" — using
     * modem_is_present() disambiguates. */
    bool modem_present = modem_is_present();

    cJSON *root = cJSON_CreateObject();
    cJSON_AddStringToObject(root, "variant", modem_present ? "cellular" : "wifi");

    /* Wizard state mapping. SOFTAP_ONLY needs special handling because it
     * means different things on the two variants. */
    const char *ws;
    if (claimed) {
        ws = "claimed";
    } else if (st.state == NETWORK_STATE_SOFTAP_ONLY) {
        ws = modem_present ? "cellular_config" : "wifi_connecting";
    } else {
        ws = wizard_state_str(st.state);
    }
    cJSON_AddStringToObject(root, "wizard_state", ws);

    cJSON *uplink = cJSON_AddObjectToObject(root, "uplink");
    cJSON_AddStringToObject(uplink, "kind", st.uplink_kind);

    if (st.wifi_initialised) {
        cJSON *w = cJSON_AddObjectToObject(uplink, "wifi");
        cJSON_AddStringToObject(w, "ssid", st.wifi_ssid);
        cJSON_AddNumberToObject(w, "rssi", st.wifi_rssi);
        cJSON_AddStringToObject(w, "ip",   st.wifi_ip);
    } else {
        cJSON_AddNullToObject(uplink, "wifi");
    }

    if (modem_present) {
        cJSON *c = cJSON_AddObjectToObject(uplink, "cellular");
        cJSON_AddStringToObject(c, "operator",  st.cellular_operator);
        cJSON_AddStringToObject(c, "mode",      lte_mode_str(st.cellular_mode));
        cJSON_AddNumberToObject(c, "rssi_dbm",  st.cellular_rssi_dbm);
        cJSON_AddStringToObject(c, "ip",        st.cellular_ip);
        cJSON_AddBoolToObject(c,   "registered", st.cellular_registered);
    } else {
        cJSON_AddNullToObject(uplink, "cellular");
    }

    cJSON *claim = cJSON_AddObjectToObject(root, "claim");
    cJSON_AddBoolToObject(claim, "claimed",       claimed);
    cJSON_AddBoolToObject(claim, "prov_code_set", prov_code_set);

    char *json_str = cJSON_PrintUnformatted(root);
    httpd_resp_set_type(req, "application/json");
    httpd_resp_send(req, json_str, HTTPD_RESP_USE_STRLEN);
    cJSON_free(json_str);
    cJSON_Delete(root);
    return ESP_OK;
}

/* ---------- Wizard endpoint helpers ---------- */

static esp_err_t recv_json_body(httpd_req_t *req, char *buf, size_t bufsize) {
    int total = req->content_len;
    if (total <= 0 || total >= (int)bufsize) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "body too large or empty");
        return ESP_FAIL;
    }
    int cur = 0;
    while (cur < total) {
        int r = httpd_req_recv(req, buf + cur, total - cur);
        if (r <= 0) {
            httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "recv failed");
            return ESP_FAIL;
        }
        cur += r;
    }
    buf[total] = '\0';
    return ESP_OK;
}

static esp_err_t send_ok(httpd_req_t *req) {
    httpd_resp_set_type(req, "application/json");
    httpd_resp_sendstr(req, "{\"ok\":true}");
    return ESP_OK;
}

static esp_err_t send_err_json(httpd_req_t *req, const char *msg) {
    char buf[128];
    snprintf(buf, sizeof(buf), "{\"error\":\"%s\"}", msg);
    httpd_resp_set_type(req, "application/json");
    httpd_resp_sendstr(req, buf);
    return ESP_OK;
}

/* POST /api/v1/cellular/configure  body: {apn, pin, lte_mode}
 *   apn: required string
 *   pin: optional string (empty = no PIN)
 *   lte_mode: integer 1=CatM 2=NBIoT 3=Both */
static esp_err_t cellular_configure_handler(httpd_req_t *req) {
    char buf[512];
    if (recv_json_body(req, buf, sizeof(buf)) != ESP_OK) return ESP_OK;

    cJSON *root = cJSON_Parse(buf);
    if (!root) return send_err_json(req, "invalid JSON");

    cJSON *japn = cJSON_GetObjectItem(root, "apn");
    cJSON *jpin = cJSON_GetObjectItem(root, "pin");
    cJSON *jmode = cJSON_GetObjectItem(root, "lte_mode");
    if (!japn || !cJSON_IsString(japn) || strlen(japn->valuestring) == 0) {
        cJSON_Delete(root);
        return send_err_json(req, "apn required");
    }
    int mode = jmode && cJSON_IsNumber(jmode) ? (int)jmode->valuedouble : MODEM_LTE_MODE_BOTH;
    if (mode < 1 || mode > 3) mode = MODEM_LTE_MODE_BOTH;

    const char *pin = (jpin && cJSON_IsString(jpin)) ? jpin->valuestring : "";

    esp_err_t err = network_cellular_configure(japn->valuestring, pin, (modem_lte_mode_t)mode);
    cJSON_Delete(root);

    if (err == ESP_ERR_INVALID_STATE) return send_err_json(req, "bring-up already in progress");
    if (err != ESP_OK)                return send_err_json(req, esp_err_to_name(err));
    return send_ok(req);
}

/* POST /api/v1/wifi/configure  body: {ssid, password} */
static esp_err_t wifi_configure_handler(httpd_req_t *req) {
    char buf[512];
    if (recv_json_body(req, buf, sizeof(buf)) != ESP_OK) return ESP_OK;

    cJSON *root = cJSON_Parse(buf);
    if (!root) return send_err_json(req, "invalid JSON");

    cJSON *jssid = cJSON_GetObjectItem(root, "ssid");
    cJSON *jpass = cJSON_GetObjectItem(root, "password");
    if (!jssid || !cJSON_IsString(jssid) || strlen(jssid->valuestring) == 0) {
        cJSON_Delete(root);
        return send_err_json(req, "ssid required");
    }
    const char *pass = (jpass && cJSON_IsString(jpass)) ? jpass->valuestring : "";

    esp_err_t err = network_wifi_configure(jssid->valuestring, pass);
    cJSON_Delete(root);

    if (err == ESP_ERR_NOT_SUPPORTED) return send_err_json(req, "WiFi not configurable on cellular board");
    if (err != ESP_OK)                return send_err_json(req, esp_err_to_name(err));
    return send_ok(req);
}

/* POST /api/v1/claim  body: {prov_code, srv_url} */
static esp_err_t claim_handler(httpd_req_t *req) {
    char buf[512];
    if (recv_json_body(req, buf, sizeof(buf)) != ESP_OK) return ESP_OK;

    cJSON *root = cJSON_Parse(buf);
    if (!root) return send_err_json(req, "invalid JSON");

    cJSON *jcode = cJSON_GetObjectItem(root, "prov_code");
    cJSON *jurl  = cJSON_GetObjectItem(root, "srv_url");
    if (!jcode || !cJSON_IsString(jcode) || strlen(jcode->valuestring) == 0) {
        cJSON_Delete(root);
        return send_err_json(req, "prov_code required");
    }
    if (!jurl || !cJSON_IsString(jurl) || strlen(jurl->valuestring) == 0) {
        cJSON_Delete(root);
        return send_err_json(req, "srv_url required");
    }

    /* Persist + spawn the claim task. The task reads from NVS and
     * reboots on success. */
    nvs_handle_t h;
    if (nvs_open("vmflow", NVS_READWRITE, &h) == ESP_OK) {
        nvs_set_str(h, "prov_code", jcode->valuestring);
        nvs_set_str(h, "srv_url",   jurl->valuestring);
        nvs_commit(h);
        nvs_close(h);
    }
    cJSON_Delete(root);

    xTaskCreate(provision_claim_task, "prov_claim", 8192, NULL, 5, NULL);
    return send_ok(req);
}

static esp_err_t wifi_scan_get_handler(httpd_req_t *req) {

    wifi_scan_config_t scan_cfg = {
        .ssid        = NULL,
        .bssid       = NULL,
        .channel     = 0,
        .show_hidden = false,
        .scan_type   = WIFI_SCAN_TYPE_ACTIVE,
        .scan_time   = { .active = { .min = 100, .max = 300 } },
    };

    esp_err_t err = esp_wifi_scan_start(&scan_cfg, true);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "WiFi scan failed: %s", esp_err_to_name(err));
        httpd_resp_set_type(req, "application/json");
        httpd_resp_sendstr(req, "{\"networks\":[],\"error\":\"scan_failed\"}");
        return ESP_OK;
    }

    uint16_t ap_count = 0;
    esp_wifi_scan_get_ap_num(&ap_count);
    if (ap_count > 20) ap_count = 20;

    wifi_ap_record_t *ap_records = calloc(ap_count, sizeof(wifi_ap_record_t));
    if (!ap_records) {
        httpd_resp_set_type(req, "application/json");
        httpd_resp_sendstr(req, "{\"networks\":[],\"error\":\"out_of_memory\"}");
        return ESP_OK;
    }
    esp_wifi_scan_get_ap_records(&ap_count, ap_records);

    /* Sort by RSSI descending (simple bubble sort, n<=20) */
    for (int i = 0; i < ap_count - 1; i++) {
        for (int j = 0; j < ap_count - i - 1; j++) {
            if (ap_records[j].rssi < ap_records[j + 1].rssi) {
                wifi_ap_record_t tmp = ap_records[j];
                ap_records[j] = ap_records[j + 1];
                ap_records[j + 1] = tmp;
            }
        }
    }

    /* Build deduplicated JSON array, filtering own AP and hidden networks */
    cJSON *root = cJSON_CreateObject();
    cJSON *networks = cJSON_AddArrayToObject(root, "networks");

    char seen_ssids[20][33];
    int seen_count = 0;

    for (int i = 0; i < ap_count; i++) {
        const char *ssid = (const char *)ap_records[i].ssid;

        /* Skip empty SSIDs (hidden networks) */
        if (strlen(ssid) == 0) continue;

        /* Skip own AP */
        if (strcmp(ssid, AP_SSID) == 0) continue;

        /* Skip duplicates (already sorted by RSSI, first occurrence is strongest) */
        bool dup = false;
        for (int s = 0; s < seen_count; s++) {
            if (strcmp(seen_ssids[s], ssid) == 0) { dup = true; break; }
        }
        if (dup) continue;

        if (seen_count < 20) {
            strncpy(seen_ssids[seen_count], ssid, 32);
            seen_ssids[seen_count][32] = '\0';
            seen_count++;
        }

        cJSON *net = cJSON_CreateObject();
        cJSON_AddStringToObject(net, "ssid", ssid);
        cJSON_AddNumberToObject(net, "rssi", ap_records[i].rssi);
        cJSON_AddBoolToObject(net, "secure", ap_records[i].authmode != WIFI_AUTH_OPEN);
        cJSON_AddItemToArray(networks, net);
    }

    free(ap_records);

    char *json_str = cJSON_PrintUnformatted(root);
    httpd_resp_set_type(req, "application/json");
    httpd_resp_send(req, json_str, HTTPD_RESP_USE_STRLEN);
    cJSON_free(json_str);
    cJSON_Delete(root);

    return ESP_OK;
}

static esp_err_t captive_handler(httpd_req_t *req) {
    ESP_LOGI(TAG, "Captive portal redirect: %s", req->uri);
    httpd_resp_set_status(req, "302 Found");
    httpd_resp_set_hdr(req, "Location", "/");
    httpd_resp_send(req, NULL, 0);
    return ESP_OK;
}

/* ---------- DNS ---------- */

void stop_dns_server(void) {
    if (dns_pcb == NULL) return;
    udp_recv(dns_pcb, NULL, NULL);
    udp_remove(dns_pcb);
    dns_pcb = NULL;
    ESP_LOGI(TAG, "DNS stopped");
}

void start_dns_server(void) {
    dns_pcb = udp_new();
    udp_bind(dns_pcb, IP_ADDR_ANY, 53);
    udp_recv(dns_pcb, dns_recv, NULL);
    ESP_LOGI(TAG, "DNS started");
}

/* ---------- HTTP server ---------- */

void stop_rest_server(void) {
    if (rest_server == NULL) return;
    httpd_stop(rest_server);
    rest_server = NULL;
}

void start_rest_server(void) {
    if (rest_server != NULL) return;

    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    httpd_start(&rest_server, &config);

    static const httpd_uri_t uris[] = {
        { .uri = "/",                          .method = HTTP_GET,  .handler = index_get_handler          },
        { .uri = "/api/v1/system/info",        .method = HTTP_GET,  .handler = system_info_get_handler    },
        { .uri = "/api/v1/wifi/scan",          .method = HTTP_GET,  .handler = wifi_scan_get_handler      },
        { .uri = "/api/v1/cellular/configure", .method = HTTP_POST, .handler = cellular_configure_handler },
        { .uri = "/api/v1/wifi/configure",     .method = HTTP_POST, .handler = wifi_configure_handler     },
        { .uri = "/api/v1/claim",              .method = HTTP_POST, .handler = claim_handler              },
        { .uri = "/generate_204",              .method = HTTP_GET,  .handler = captive_handler            },
        { .uri = "/hotspot-detect.html",       .method = HTTP_GET,  .handler = captive_handler            },
    };

    for (int i = 0; i < sizeof(uris) / sizeof(uris[0]); i++) {
        httpd_register_uri_handler(rest_server, &uris[i]);
    }
}

/* ---------- SoftAP ---------- */

void start_softap(void) {
    wifi_config_t wifi_config = {
        .ap = {
            .ssid           = AP_SSID,
            .ssid_len       = strlen(AP_SSID),
            .password       = AP_PASS,
            .max_connection = 4,
            .authmode       = WIFI_AUTH_WPA_WPA2_PSK,
        },
    };
    esp_err_t err = esp_wifi_set_config(WIFI_IF_AP, &wifi_config);
    ESP_LOGI(TAG, "SoftAP config set (SSID=\"%s\") → %s", AP_SSID, esp_err_to_name(err));
}
