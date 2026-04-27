# Firmware Cellular P3 — Captive Portal Wizard

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the existing single-page captive portal into a wizard that adapts to the board variant. SIM-equipped devices must complete cellular configuration before the claim screen unlocks. WiFi-only devices get the existing single-page experience plus a status banner. The portal polls `/api/v1/system/info` every 2 s so the user sees live state (SIM registration progress, signal, operator, IP).

**Architecture:** `webui_server.c` becomes a wizard orchestrator: extends `/api/v1/system/info` to expose `network_get_status()` (variant + wizard step + uplink details + claim status), adds three POST endpoints (`/api/v1/cellular/configure`, `/api/v1/wifi/configure`, `/api/v1/claim`), removes the old combined `/api/v1/settings/set`. The handlers are thin — they validate JSON input and call into `network_*` functions; no business logic lives in `webui_server.c`. The HTML/JS gets a vanilla-JS rewrite (no framework, still embedded via `EMBED_FILES`): one polling loop drives a small state machine that renders one of three views (cellular-config, wifi+claim, cellular-claim) plus a permanent status banner.

**Tech Stack:** ESP-IDF httpd, cJSON, vanilla JavaScript (no framework — keeps the binary small and the dependency surface zero).

**Spec reference:** [docs/superpowers/specs/2026-04-27-firmware-cellular-network-design.md](../specs/2026-04-27-firmware-cellular-network-design.md) — see §3 (Captive portal wizard).

**Position in milestone:** Phase 3 of 6. P1+P2 complete (modem driver + network manager landing). P4 (watchdog), P5 (backend telemetry), P6 (field validation) follow.

**Backward-compat invariant:** The captive portal HTML is served by the firmware itself — no cross-device caching. Removing the old `/api/v1/settings/set` endpoint is safe; no third-party clients exist.

---

## File Structure

- **Modify:** `mdb-slave-esp32s3/main/webui_server.c` (current 375 lines → ~500 lines): replace `wifi_set_handler` + `system_info_get_handler` with new handlers; add `cellular_configure_handler`, `wifi_configure_handler`, `claim_handler`; extend `start_rest_server` URI table.
- **Modify:** `mdb-slave-esp32s3/main/webui_server.h`: no public API changes (handlers stay file-static).
- **Modify:** `mdb-slave-esp32s3/webui/index.html` (current 293 lines → ~600 lines): full vanilla-JS SPA rewrite with polling + banner + 3 step views.
- **Modify:** `mdb-slave-esp32s3/main/network.c`: implement `network_wifi_configure` (still a stub from P2); add a small claim helper if needed.
- **Modify:** `mdb-slave-esp32s3/main/mdb-slave-esp32s3.c`: extract `provision_claim_task` so the wizard's `/api/v1/claim` POST handler can also kick it off — small refactor (the task body stays as-is; only its triggering changes).

`webui_server.c` is well-suited to staying single-file — handlers + URI table fit naturally together. If it grows past ~700 lines, the SoftAP/DNS lifecycle is the candidate for extraction (but the spec explicitly defers that until further growth justifies it).

---

## Chunk 1: Backend wiring — extended /system/info + new POST handlers (Tasks 1–4)

This chunk is API-only. The HTML still renders the old single-page form, but the new endpoints exist and respond correctly. Manual testing via `curl` is possible.

### Task 1: Implement `network_wifi_configure`

**Files:** Modify `mdb-slave-esp32s3/main/network.c`.

- [ ] **Step 1:** Replace the stub with:

```c
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
```

- [ ] **Step 2:** Build, commit `firmware(network): implement network_wifi_configure with cellular-board guard`.

### Task 2: Refactor `provision_claim_task` for portal use

**Files:** Modify `mdb-slave-esp32s3/main/mdb-slave-esp32s3.c`.

The existing `provision_claim_task` reads `prov_code` and `srv_url` from NVS, POSTs to the backend, saves the response, and reboots. The wizard wants to invoke this same task on demand from the `/api/v1/claim` HTTP handler — but the handler runs in the httpd task context with limited stack. Instead the handler saves prov_code+srv_url to NVS, then signals the existing task.

Simpler path: the handler writes the values to NVS, and **immediately calls `xTaskCreate(provision_claim_task, "prov_claim", 8192, NULL, 5, NULL);`** — same way `network_event_cb` already does it. The task reads NVS, doesn't need any new arguments.

- [ ] **Step 1:** Verify `provision_claim_task` is non-static (so it's callable from outside main.c). If it's static, change to non-static and add a forward declaration in a new internal header `mdb-slave-esp32s3/main/provision.h`:

```c
#ifndef PROVISION_H
#define PROVISION_H
void provision_claim_task(void *arg);
#endif
```

- [ ] **Step 2:** `webui_server.c` will include this header in Task 4. Build to confirm nothing breaks.

- [ ] **Step 3:** Commit `firmware(provision): expose provision_claim_task for captive portal claim handler`.

### Task 3: Extend `system_info_get_handler` to expose network_get_status

**Files:** Modify `mdb-slave-esp32s3/main/webui_server.c`.

Replace the current `system_info_get_handler` body (lines 162–217 today). New JSON shape:

```json
{
  "variant": "cellular",
  "wizard_state": "cellular_registering",
  "uplink": {
    "kind": "cellular",
    "wifi": null,
    "cellular": {
      "operator": "Vodafone DE",
      "mode": "LTE-M",
      "rssi_dbm": -78,
      "ip": "10.64.12.5",
      "registered": true
    }
  },
  "claim": { "claimed": false, "prov_code_set": false }
}
```

Implementation:

```c
#include "network.h"

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

    cJSON *root = cJSON_CreateObject();
    cJSON_AddStringToObject(root, "variant",
        st.modem_present ? "cellular" : "wifi");

    /* If claimed already, treat the wizard as "complete" so the SPA
     * shows a steady-state view rather than the claim form. */
    cJSON_AddStringToObject(root, "wizard_state",
        claimed ? "claimed" : wizard_state_str(st.state));

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

    if (st.modem_present) {
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
```

- [ ] **Step 1:** Replace handler. Build. Commit `firmware(webui): /system/info now serves wizard state via network_get_status`.

### Task 4: Add `/api/v1/cellular/configure`, `/api/v1/wifi/configure`, `/api/v1/claim`; remove `/settings/set`

**Files:** Modify `mdb-slave-esp32s3/main/webui_server.c`.

- [ ] **Step 1:** Add a small generic POST-body reader helper (private static) that buffers up to 512 bytes:

```c
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
```

- [ ] **Step 2:** Add the three handlers:

```c
#include "modem.h"
#include "provision.h"

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
```

- [ ] **Step 3:** Update `start_rest_server` URI table:

```c
    static const httpd_uri_t uris[] = {
        { .uri = "/",                          .method = HTTP_GET,  .handler = index_get_handler         },
        { .uri = "/api/v1/system/info",        .method = HTTP_GET,  .handler = system_info_get_handler   },
        { .uri = "/api/v1/wifi/scan",          .method = HTTP_GET,  .handler = wifi_scan_get_handler     },
        { .uri = "/api/v1/cellular/configure", .method = HTTP_POST, .handler = cellular_configure_handler },
        { .uri = "/api/v1/wifi/configure",     .method = HTTP_POST, .handler = wifi_configure_handler     },
        { .uri = "/api/v1/claim",              .method = HTTP_POST, .handler = claim_handler              },
        { .uri = "/generate_204",              .method = HTTP_GET,  .handler = captive_handler            },
        { .uri = "/hotspot-detect.html",       .method = HTTP_GET,  .handler = captive_handler            },
    };
```

The old `wifi_set_handler` and `/api/v1/settings/set` can be removed entirely — no caller after the HTML rewrite.

- [ ] **Step 4:** Build. Commit `firmware(webui): wizard endpoints (cellular/wifi/claim configure) + remove old settings/set`.

---

## Chunk 2: HTML SPA rewrite (Tasks 5–6)

The current 293-line index.html is a single-page form with vanilla JS. The new version is a polling SPA that renders one of three views based on `wizard_state`:

- `cellular_config` — APN + PIN + LTE-mode form (SIM variant pre-config)
- `cellular_registering` — read-only "registering..." view
- `ready_to_claim` — claim form (prov_code + srv_url)
- `wifi_connecting` (WiFi-only variant) — show WiFi picker + claim form combined (today's behaviour)
- `claimed` — success message

Permanent banner at top shows: variant icon, current state in plain German, signal/operator/IP if applicable, claim status.

### Task 5: HTML structure + CSS + status banner

**Files:** Modify `mdb-slave-esp32s3/webui/index.html` (full rewrite).

- [ ] **Step 1:** Replace `index.html` with the new SPA. Structure:

```html
<!DOCTYPE html>
<html lang="de">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>VMflow Setup</title>
  <link rel="icon" type="image/svg+xml" href="data:image/svg+xml;base64,...">
  <style>
    /* Compact reset + base styles + banner + form + button styles. */
    *{box-sizing:border-box;margin:0;padding:0}
    body{font-family:system-ui,-apple-system,Arial,sans-serif;background:#0F172A;color:#fff;padding:0;min-height:100vh}
    .container{max-width:480px;margin:0 auto;padding:16px;padding-top:24px}
    .banner{background:#1E293B;border-radius:8px;padding:16px;margin-bottom:24px;display:flex;flex-direction:column;gap:8px}
    .banner .row{display:flex;align-items:center;gap:8px;font-size:14px}
    .banner .icon{width:24px;height:24px}
    .banner .state{font-weight:600;font-size:16px}
    .banner .meta{color:#94A3B8;font-size:13px}
    .step{background:#1E293B;border-radius:8px;padding:20px}
    .step h2{font-size:18px;margin-bottom:16px}
    .field{margin-bottom:16px}
    .field label{display:block;font-size:13px;color:#94A3B8;margin-bottom:6px}
    .field input,.field select{width:100%;padding:10px;background:#0F172A;color:#fff;border:1px solid #334155;border-radius:6px;font-size:14px}
    .btn{display:block;width:100%;padding:12px;background:#A3E635;color:#0F172A;border:none;border-radius:6px;font-weight:600;cursor:pointer;font-size:15px}
    .btn:disabled{opacity:0.5;cursor:not-allowed}
    .err{background:#7F1D1D;color:#fff;padding:10px;border-radius:6px;font-size:13px;margin-bottom:16px}
    .info{color:#94A3B8;font-size:13px;line-height:1.5}
    .signal-bars{display:inline-flex;gap:2px}
    .signal-bars span{width:4px;background:#334155;border-radius:1px}
    .signal-bars span:nth-child(1){height:6px}
    .signal-bars span:nth-child(2){height:9px}
    .signal-bars span:nth-child(3){height:12px}
    .signal-bars span:nth-child(4){height:15px}
    .signal-bars span.on{background:#A3E635}
  </style>
</head>
<body>
  <div class="container">
    <div class="banner" id="banner"><!-- rendered by JS --></div>
    <div id="view"><!-- rendered by JS --></div>
  </div>
  <script>/* full JS in Task 6 */</script>
</body>
</html>
```

- [ ] **Step 2:** Build (the HTML is embedded — `idf.py build` re-bundles it). Commit `firmware(webui): rewrite index.html shell + CSS + status banner`.

### Task 6: Vanilla JS — polling loop, state-machine view router, form handlers

**Files:** Modify `mdb-slave-esp32s3/webui/index.html`.

- [ ] **Step 1:** Add the JS in the `<script>` block. Pseudocode (full implementation):

```javascript
const STATE_LABELS = {
  booting:                'Bootet…',
  offline:                'Kein Uplink',
  cellular_config:        'SIM nicht konfiguriert',
  wifi_connecting:        'WiFi verbindet…',
  cellular_registering:   'Registriere bei Mobilfunknetz…',
  ready_to_claim:         'Bereit zur Anmeldung',
  claimed:                'Online — angemeldet',
};

let lastInfo = null;

async function fetchInfo() {
  try {
    const r = await fetch('/api/v1/system/info');
    const j = await r.json();
    if (JSON.stringify(j) !== JSON.stringify(lastInfo)) {
      lastInfo = j;
      render(j);
    }
  } catch (e) {
    // network error — likely user disconnected from SoftAP
  }
}

function render(info) {
  renderBanner(info);
  renderView(info);
}

function renderBanner(info) {
  const banner = document.getElementById('banner');
  const stateLabel = STATE_LABELS[info.wizard_state] || info.wizard_state;
  let metaLines = [];

  if (info.uplink && info.uplink.cellular) {
    const c = info.uplink.cellular;
    const bars = signalBarsHTML(c.rssi_dbm);
    metaLines.push(`<div class="meta">${escape(c.operator || 'Suche Operator…')} · ${c.rssi_dbm} dBm ${bars} · ${escape(c.mode || '—')}</div>`);
    if (c.ip) metaLines.push(`<div class="meta">IP: ${escape(c.ip)}</div>`);
  } else if (info.uplink && info.uplink.wifi) {
    const w = info.uplink.wifi;
    metaLines.push(`<div class="meta">${escape(w.ssid)} · ${w.rssi} dBm</div>`);
    if (w.ip) metaLines.push(`<div class="meta">IP: ${escape(w.ip)}</div>`);
  }

  const variantIcon = info.variant === 'cellular' ? '📡' : '📶';
  const claimText = info.claim.claimed ? 'Angemeldet ✓' : 'Nicht angemeldet';

  banner.innerHTML = `
    <div class="row"><span class="icon">${variantIcon}</span><span class="state">${escape(stateLabel)}</span></div>
    ${metaLines.join('')}
    <div class="meta">${claimText}</div>
  `;
}

function signalBarsHTML(dbm) {
  // -50…-65 = 4 bars, -65…-80 = 3, -80…-95 = 2, -95…-105 = 1, ≤-105 = 0
  const n = dbm >= -65 ? 4 : dbm >= -80 ? 3 : dbm >= -95 ? 2 : dbm >= -105 ? 1 : 0;
  let html = '<span class="signal-bars">';
  for (let i = 0; i < 4; i++) html += `<span class="${i < n ? 'on' : ''}"></span>`;
  html += '</span>';
  return html;
}

function renderView(info) {
  const view = document.getElementById('view');

  if (info.wizard_state === 'claimed') {
    view.innerHTML = '<div class="step"><h2>Setup abgeschlossen</h2><p class="info">Das Gerät ist angemeldet und betriebsbereit.</p></div>';
    return;
  }

  if (info.variant === 'cellular' && info.wizard_state === 'cellular_config') {
    view.innerHTML = renderCellularConfigForm();
    document.getElementById('cellularForm').onsubmit = submitCellularConfig;
    return;
  }

  if (info.variant === 'cellular' && info.wizard_state === 'cellular_registering') {
    view.innerHTML = '<div class="step"><h2>Mobilfunk verbindet…</h2><p class="info">Das Modem registriert sich gerade beim Netzbetreiber. Das kann bis zu 60 Sekunden dauern.</p></div>';
    return;
  }

  if (info.wizard_state === 'ready_to_claim') {
    view.innerHTML = renderClaimForm();
    document.getElementById('claimForm').onsubmit = submitClaim;
    return;
  }

  // WiFi-only variant, not yet connected — single-page form (today's UX)
  if (info.variant === 'wifi') {
    view.innerHTML = renderWifiAndClaimForm();
    document.getElementById('wifiForm').onsubmit = submitWifiAndClaim;
    return;
  }

  view.innerHTML = '<div class="step"><h2>…</h2></div>';
}

function renderCellularConfigForm() { /* APN + PIN + LTE mode */ }
function renderClaimForm()           { /* prov_code + srv_url */ }
function renderWifiAndClaimForm()    { /* SSID picker + password + prov_code + srv_url */ }

async function submitCellularConfig(ev) { /* POST /api/v1/cellular/configure */ }
async function submitClaim(ev)          { /* POST /api/v1/claim */ }
async function submitWifiAndClaim(ev)   { /* POST /api/v1/wifi/configure then POST /api/v1/claim */ }

function escape(s) { return String(s ?? '').replace(/[<>&"]/g, c => ({'<':'&lt;','>':'&gt;','&':'&amp;','"':'&quot;'}[c])); }

// Boot
fetchInfo();
setInterval(fetchInfo, 2000);
```

The full implementation expands the placeholder functions. Forms must:
- disable submit button while waiting for response (prevents the duplicate-spawn race noted in P2)
- show error text from the JSON response
- re-enable on error / leave disabled on success (poll picks up the state change)

- [ ] **Step 2:** Test by `idf.py build` and visually inspecting the rendered HTML in a browser if practical. Commit `firmware(webui): vanilla-JS SPA — polling + view router + form handlers`.

---

## Chunk 3: Cleanup + verification (Tasks 7–8)

### Task 7: Remove dead code from webui_server.c

**Files:** Modify `mdb-slave-esp32s3/main/webui_server.c`.

- [ ] **Step 1:** The old `wifi_set_handler` is no longer referenced after Task 4 (URI table updated). Delete the function definition entirely. Build to confirm.
- [ ] **Step 2:** Commit `firmware(webui): remove dead wifi_set_handler (replaced by /wifi/configure + /claim split)`.

### Task 8: Update CLAUDE.md and document deferred hardware acceptance

**Files:** Modify `CLAUDE.md`.

- [ ] **Step 1:** Update the network-manager paragraph to mention the wizard portal:

> Add: "P3 captive portal wizard: status banner polled from `/api/v1/system/info` every 2 s; SIM variant requires cellular config (APN/PIN/LTE-mode) before the claim form unlocks; WiFi-only variant retains the single-page form. Three POST endpoints: `/api/v1/cellular/configure`, `/api/v1/wifi/configure`, `/api/v1/claim`."

- [ ] **Step 2:** Acceptance test (DEFERRED to user hardware testing):

  1. Flash post-P3 firmware on a current production WiFi-only board → captive portal shows banner + WiFi picker + claim form combined (visually similar to today). Submitting credentials + prov_code completes claim.
  2. Flash on LilyGo with no APN in NVS → captive portal shows banner ("SIM nicht konfiguriert"), then cellular config form. Submitting APN + PIN + mode triggers registration; banner updates live; claim form unlocks; claim completes.

- [ ] **Step 3:** Commit `firmware(webui): document P3 captive portal wizard in CLAUDE.md`.

---

## P3 Definition of Done

- [ ] `/api/v1/system/info` returns the new shape (variant, wizard_state, uplink.{wifi,cellular}, claim).
- [ ] All three new POST endpoints exist and validate JSON input.
- [ ] Old `/api/v1/settings/set` endpoint removed (no caller in the new HTML).
- [ ] `network_wifi_configure` is implemented (no longer a stub).
- [ ] `provision_claim_task` is callable from `webui_server.c`.
- [ ] `index.html` is a polling SPA with banner + view router.
- [ ] Build clean.
- [ ] CLAUDE.md updated.
- [ ] Acceptance tests pasted into Task 8 by the user after hardware run.
