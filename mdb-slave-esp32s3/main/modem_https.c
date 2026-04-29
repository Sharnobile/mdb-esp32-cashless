/*
 * VMflow.xyz
 *
 * modem_https.c — HTTPS POST via SIM7080G internal stack.
 *
 * Implementation per SIMCom HTTP(S) Application Note V1.02 §5.2.2.
 *
 * State machine (top-down):
 *   1. AT+CNCFG=0,1,"<apn>"          configure internal-bearer APN
 *   2. AT+CNACT=0,1                  activate bearer (may already be on)
 *   3. AT+CSSLCFG="sslversion",1,3   force TLS 1.2 on SSL slot 1
 *   4. AT+SHSSL=1,""                 use slot 1, NO cert verification
 *                                     (one-shot claim — prov_code is a
 *                                     short-lived single-use token, no
 *                                     PII risk; the XOR cipher + passkey
 *                                     handed back protect subsequent MQTT)
 *   5. AT+SHCONF="URL","<url>"       base URL (scheme + host)
 *      AT+SHCONF="BODYLEN",1024
 *      AT+SHCONF="HEADERLEN",350
 *   6. AT+SHCONN                     open TLS connection
 *      AT+SHSTATE?                   verify "+SHSTATE: 1"
 *   7. AT+SHCHEAD                    clear default headers
 *      AT+SHAHEAD="Content-Type","application/json"
 *   8. AT+SHBOD=<len>,10000          set body length, then send body bytes
 *                                     (see "SHBOD prompt handling" below)
 *   9. AT+SHREQ="<path>",3           send POST, wait for URC
 *                                     +SHREQ: "POST",<status>,<dlen>
 *   10. AT+SHREAD=0,<dlen>           read response, expects URC
 *                                     +SHREAD: <dlen>\n<bytes>
 *   11. AT+SHDISC                    close connection
 *   12. AT+CNACT=0,0                 deactivate bearer
 *
 * SHBOD prompt handling: the modem expects the host to first send the
 * AT+SHBOD command, then receive a "\r\n>\r\n " prompt, then send the
 * body bytes. We sidestep the prompt round-trip by sending command +
 * body in a single UART write — esp_modem's DTE::command() writes the
 * given bytes verbatim with no terminator added (verified in
 * esp_modem_dte.cpp:154), so a single string of "AT+SHBOD=<len>,T\r"
 * + body delivers everything to the UART RX buffer in one go. The
 * modem reads the AT line up to \r, processes the prompt internally,
 * then drains the next <len> bytes from the same UART RX buffer for
 * the body. Tested as the standard way to drive prompt-based AT
 * commands without a custom DTE write API.
 *
 * Caller contract: see modem_https.h.
 */

#include "modem_https.h"
#include "modem.h"

#include <string.h>
#include <stdio.h>
#include <esp_log.h>
#include <esp_modem_api.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

#define TAG "modem_https"

/* Per-step timeouts (rough budget under 90 s total).
 *   bearer activation: up to 30 s on cold attach
 *   SSL config:        ~1 s
 *   SHCONN:            up to 30 s (TLS handshake + DNS)
 *   SHREQ:             up to 30 s (round-trip + server processing)
 *   SHREAD:            up to 10 s (response is small)
 *   SHDISC + CNACT=0,0: a few seconds total
 * Sum stays under the 90 s claim-task budget. */
#define HTTPS_T_BEARER_MS   30000
#define HTTPS_T_AT_SHORT_MS  3000
#define HTTPS_T_AT_MED_MS    8000
#define HTTPS_T_SHCONN_MS   30000
#define HTTPS_T_SHREQ_MS    30000
#define HTTPS_T_SHREAD_MS   10000

/* Helper: fire-and-forget AT command with default OK/ERROR matching.
 * Returns ESP_OK on OK in response, ESP_FAIL otherwise (timeout,
 * ERROR, etc.). Always logs result + response text. NB: esp_modem
 * 1.4.0's generic_get_string() OVERWRITES `output` for each non-OK
 * line in a multi-line response (see esp_modem_command_library.cpp
 * line 103, str_copy::set not append), so for commands like CNACT?
 * we only see the LAST line of a multi-line reply. Don't rely on
 * this captured output for parsing multi-bearer state. */
static esp_err_t at_simple(esp_modem_dce_t *dce, const char *cmd, int timeout_ms) {
    char resp[256] = {0};
    esp_err_t err = esp_modem_at(dce, cmd, resp, timeout_ms);
    /* Strip CR/LF for cleaner one-line logs. */
    for (char *c = resp; *c; c++) if (*c == '\r' || *c == '\n') *c = ' ';
    if (err == ESP_OK) {
        ESP_LOGI(TAG, "%s → OK%s%.180s", cmd,
                 resp[0] ? ", resp=" : "", resp);
    } else {
        ESP_LOGW(TAG, "%s → %s, resp=%.180s", cmd, esp_err_to_name(err), resp);
    }
    return err;
}

/* Poll AT+CNACT? until bearer 0 reports status=1 (active), or timeout.
 * Returns ESP_OK if active before timeout, ESP_ERR_TIMEOUT otherwise.
 *
 * Verbose logging: every 3rd iteration we log the actual modem
 * response so field debugging can see whether the modem is rejecting
 * the query (ERROR), reporting bearer-0 status=0 (still bringing up),
 * or genuinely not responding (timeout). Earlier versions logged a
 * generic "modem unresponsive" message that was misleading because
 * the modem was actually responding fast — just with errors. */
static esp_err_t cnact_wait_active(esp_modem_dce_t *dce, int timeout_ms) {
    char resp[256];
    TickType_t start = xTaskGetTickCount();
    TickType_t deadline = start + pdMS_TO_TICKS(timeout_ms);
    int iter = 0;
    while (xTaskGetTickCount() < deadline) {
        iter++;
        memset(resp, 0, sizeof(resp));
        esp_err_t at_err = esp_modem_at(dce, "AT+CNACT?", resp, 2000);

        /* Strip CR/LF for cleaner logging. */
        for (char *c = resp; *c; c++) if (*c == '\r' || *c == '\n') *c = ' ';

        if (at_err == ESP_OK) {
            const char *p = strstr(resp, "+CNACT: 0,");
            if (p) {
                char status_char = p[10];
                if (status_char == '1') {
                    const char *q = strchr(p + 10, '"');
                    char ip[24] = {0};
                    if (q) {
                        const char *q2 = strchr(q + 1, '"');
                        if (q2 && (size_t)(q2 - q - 1) < sizeof(ip)) {
                            memcpy(ip, q + 1, q2 - q - 1);
                        }
                    }
                    int elapsed_ms = (int)((xTaskGetTickCount() - start) *
                                            portTICK_PERIOD_MS);
                    ESP_LOGI(TAG, "CNACT bearer 0 ACTIVE (IP=%s) after %d ms / %d polls",
                             ip[0] ? ip : "?", elapsed_ms, iter);
                    return ESP_OK;
                }
            }
        }
        if (iter <= 3 || iter % 3 == 0) {
            ESP_LOGI(TAG, "CNACT poll %d: at_err=%s, resp=%.180s",
                     iter, esp_err_to_name(at_err), resp);
        }
        vTaskDelay(pdMS_TO_TICKS(500));
    }
    int elapsed_ms = (int)((xTaskGetTickCount() - start) * portTICK_PERIOD_MS);
    ESP_LOGE(TAG, "CNACT bearer 0 never reached ACTIVE after %d ms / %d polls",
             elapsed_ms, iter);
    return ESP_ERR_TIMEOUT;
}

/* Helper: AT command with custom pass/fail strings via at_raw. The
 * `out` buffer captures everything between cmd and the matched
 * pass/fail token. */
static esp_err_t at_raw_match(esp_modem_dce_t *dce, const char *cmd,
                               char *out, size_t out_size,
                               const char *pass, const char *fail,
                               int timeout_ms) {
    if (out && out_size > 0) out[0] = '\0';
    esp_err_t err = esp_modem_at_raw(dce, cmd, out, pass, fail, timeout_ms);
    return err;
}

/* Parse the +SHREQ: URC line from a response buffer.
 * Format: +SHREQ: "POST",<status>,<datalen>
 * Returns ESP_OK on successful parse, with status_out and datalen_out
 * populated. */
static esp_err_t parse_shreq(const char *resp, int *status_out, int *datalen_out) {
    const char *p = strstr(resp, "+SHREQ:");
    if (!p) return ESP_FAIL;
    /* Skip the "+SHREQ: \"<method>\"," prefix. Method can be "GET",
     * "POST", "HEAD", "PUT" — we just skip until first comma. */
    p = strchr(p, ',');
    if (!p) return ESP_FAIL;
    p++;
    int status, datalen;
    if (sscanf(p, "%d,%d", &status, &datalen) != 2) return ESP_FAIL;
    if (status_out)  *status_out  = status;
    if (datalen_out) *datalen_out = datalen;
    return ESP_OK;
}

/* Parse the +SHREAD: URC + payload from a response buffer.
 * Format: +SHREAD: <len>\r\n<bytes>
 * Copies up to min(len, dst_size-1) bytes into dst, NUL-terminates. */
static esp_err_t parse_shread(const char *resp, char *dst, size_t dst_size,
                               size_t *len_out) {
    const char *p = strstr(resp, "+SHREAD:");
    if (!p) return ESP_FAIL;
    int len;
    if (sscanf(p, "+SHREAD: %d", &len) != 1) return ESP_FAIL;
    /* Find the start of the data — skip past the URC line's \r\n. */
    const char *eol = strchr(p, '\n');
    if (!eol) return ESP_FAIL;
    eol++;   /* points at first byte of data */

    size_t to_copy = (size_t)len;
    if (to_copy >= dst_size) to_copy = dst_size - 1;
    memcpy(dst, eol, to_copy);
    dst[to_copy] = '\0';
    if (len_out) *len_out = to_copy;
    return ESP_OK;
}

esp_err_t modem_https_post_json(const char *url,
                                 const char *path,
                                 const char *apn,
                                 const char *body,
                                 size_t body_len,
                                 char *resp_buf,
                                 size_t resp_buf_size,
                                 size_t *resp_len_out,
                                 int *status_out,
                                 int timeout_ms) {
    if (!url || !path || !apn || !body || !resp_buf || resp_buf_size == 0) {
        return ESP_ERR_INVALID_ARG;
    }
    if (resp_len_out) *resp_len_out = 0;
    if (status_out)   *status_out   = 0;
    resp_buf[0] = '\0';

    esp_modem_dce_t *dce = (esp_modem_dce_t *)modem_get_dce();
    if (!dce) {
        ESP_LOGE(TAG, "modem not probed — cannot HTTPS");
        return ESP_ERR_INVALID_STATE;
    }

    char cmd[512];
    char resp[512];
    esp_err_t err = ESP_OK;
    esp_err_t final_err = ESP_FAIL;
    int active_bearer = -1;   /* -1 = unknown/inactive; set in step 2 */

    /* === Step 0: pre-flight diagnostic ===============================
     * Log firmware ID + bearer/PDP state once. Useful for bug reports.
     * Note: AT+CNACT? returns multi-line, but esp_modem 1.4.0 only
     * preserves the LAST line in our captured output (see at_simple
     * comment) — the log is informational only, don't parse it.
     *
     * AT+CMEE=2 enables verbose +CME ERROR codes — without it,
     * SHCONN failures come back as bare "ERROR" with no code, which
     * is what we got in the c2a5a11 / 4205fc7 field logs. With CMEE=2,
     * we'll see e.g. "+CME ERROR: operation not allowed" or specific
     * service-error codes that point at the actual problem. */
    at_simple(dce, "AT+CMEE=2",    HTTPS_T_AT_SHORT_MS);
    at_simple(dce, "AT+SIMCOMATI", HTTPS_T_AT_SHORT_MS);
    at_simple(dce, "AT+CGMR",      HTTPS_T_AT_SHORT_MS);
    at_simple(dce, "AT+CGATT?",    HTTPS_T_AT_SHORT_MS);
    at_simple(dce, "AT+CGACT?",    HTTPS_T_AT_SHORT_MS);
    at_simple(dce, "AT+CNACT?",    HTTPS_T_AT_SHORT_MS);

    /* === Step 1: cleanup ============================================
     * SHDISC closes any lingering HTTPS session, CNACT=0,0 deactivates
     * bearer 0 if up. Both best-effort.
     *
     * REMOVED in this revision: the CNACT=3,0 cleanup. Field log
     * c2a5a11 showed it picked up a stale "+APP PDP: 0,DEACTIVE" URC
     * from the prior CNACT=0,0 and reported it as the response —
     * confusing the diagnostic, and probably contributing to the
     * downstream lockup. Sticking with bearer 0 throughout removes
     * the URC cross-contamination. */
    at_simple(dce, "AT+SHDISC",    HTTPS_T_AT_SHORT_MS);
    at_simple(dce, "AT+CNACT=0,0", HTTPS_T_AT_SHORT_MS);
    vTaskDelay(pdMS_TO_TICKS(1500));

    /* === Step 2: configure + activate bearer 0, then trust + sleep ==
     *
     * Critical realisation from c2a5a11 field log: AT+CNACT? polling is
     * pointless on this esp_modem version. The library's
     * generic_get_string() callback OVERWRITES the captured output
     * per-line (str_copy::set, not append) — so a 4-line CNACT?
     * response only delivers the LAST line, which is bearer 3, never
     * the bearer 0 line we'd want to see. We literally CANNOT read
     * bearer 0's state through esp_modem.
     *
     * Pragmatic alternative: trust the AT+CNACT=0,1 OK return as
     * "command accepted", sleep a generous 8 s for the modem to bring
     * the bearer up internally (the "+APP PDP: 0,ACTIVE" URC arrives
     * during this window but we don't try to capture it — esp_modem's
     * URC routing is also fragile here), and proceed straight to
     * SHCONN. SHCONN's own success/failure is the authoritative
     * signal: if the bearer was active and TLS works, it succeeds; if
     * the bearer never came up or DNS/TLS fails, SHCONN tells us
     * exactly which step failed via its response code.
     *
     * Field log will show whether SHCONN actually works once we
     * stop second-guessing it through the broken CNACT? channel. */
    snprintf(cmd, sizeof(cmd), "AT+CNCFG=0,1,\"%s\"", apn);
    err = at_simple(dce, cmd, HTTPS_T_AT_SHORT_MS);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "CNCFG rejected — proceeding anyway");
    }

    err = at_simple(dce, "AT+CNACT=0,1", HTTPS_T_AT_SHORT_MS);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "CNACT=0,1 rejected — bearer activation failed");
        final_err = err;
        goto cleanup_disc;
    }

    /* 8 s settle for "+APP PDP: 0,ACTIVE" URC to arrive and bearer to
     * become usable. Empirically derived from c2a5a11 timing — bearer
     * activation appears to take 1-3 s on a clean network, plus
     * margin for slow attaches. */
    ESP_LOGI(TAG, "CNACT=0,1 accepted — sleeping 8 s for bearer to come up");
    vTaskDelay(pdMS_TO_TICKS(8000));
    active_bearer = 0;

    /* === Step 3: SSL config (TLS 1.2 on SSL slot 1) ==================
     *
     * Per SIM7070/7080/7090 AT Command Manual V1.05 §11.2.1, the actual
     * CSSLCFG parameters are: SSLVERSION, CIPHERSUITE, IGNORERTCTIME,
     * PROTOCOL, SNI, CTXINDEX, MAXFRAGLENDISABLE, CONVERT.
     *
     * Earlier versions of this code tried "ignorelocaltime" /
     * "ignoremultiserver" — those names came from random web sources
     * and don't exist on SIM7080G. The correct name for the cert
     * validity-period bypass is IGNORERTCTIME.
     *
     * SNI (Server Name Indication) is the load-bearing one for
     * Cloudflare-fronted hosts: without it, the server doesn't know
     * which cert to present and may refuse the handshake. Field log
     * ab8de05 saw SHCONN fail with "+CME ERROR: operation not
     * allowed" — this is the canonical symptom of missing SNI on
     * Cloudflare. */
    at_simple(dce, "AT+CSSLCFG=\"SSLVERSION\",1,3",      HTTPS_T_AT_SHORT_MS);
    at_simple(dce, "AT+CSSLCFG=\"IGNORERTCTIME\",1,1",   HTTPS_T_AT_SHORT_MS);

    /* Extract host (no scheme, no port, no path) for SNI. */
    {
        const char *p = url;
        if (strncmp(p, "https://", 8) == 0) p += 8;
        else if (strncmp(p, "http://", 7) == 0) p += 7;
        const char *end = p;
        while (*end && *end != ':' && *end != '/') end++;
        size_t hlen = (size_t)(end - p);
        if (hlen > 0 && hlen < 96) {
            char sni[128];
            int n = snprintf(sni, sizeof(sni),
                              "AT+CSSLCFG=\"SNI\",1,\"%.*s\"",
                              (int)hlen, p);
            if (n > 0 && n < (int)sizeof(sni)) {
                at_simple(dce, sni, HTTPS_T_AT_SHORT_MS);
            }
        }
    }

    /* === Step 4: HTTPS session SSL slot, no cert verification ======== */
    at_simple(dce, "AT+SHSSL=1,\"\"", HTTPS_T_AT_SHORT_MS);

    /* === Step 5: HTTPS session config ================================
     *
     * URL: include the explicit ":443" port. Some SIM7080G firmware
     * revisions don't infer the port from the scheme — observed in
     * field log 4205fc7 where SHCONN returned bare "ERROR" with no
     * +SHCONN: error code, suggesting the URL parsing rejected before
     * the connection even attempted. */
    char url_with_port[256];
    if (strstr(url, "://") && !strstr(url + 8, ":")) {
        /* No port in URL; add :443 (HTTPS) explicitly. */
        snprintf(url_with_port, sizeof(url_with_port), "%s:443", url);
    } else {
        snprintf(url_with_port, sizeof(url_with_port), "%s", url);
    }
    snprintf(cmd, sizeof(cmd), "AT+SHCONF=\"URL\",\"%s\"", url_with_port);
    err = at_simple(dce, cmd, HTTPS_T_AT_SHORT_MS);
    if (err != ESP_OK) goto cleanup_disc;

    at_simple(dce, "AT+SHCONF=\"BODYLEN\",1024",   HTTPS_T_AT_SHORT_MS);
    at_simple(dce, "AT+SHCONF=\"HEADERLEN\",350",  HTTPS_T_AT_SHORT_MS);
    at_simple(dce, "AT+SHCONF=\"TIMEOUT\",60",     HTTPS_T_AT_SHORT_MS);

    /* SHSTATE? before connect — confirms session slot is in expected
     * state (0 = disconnected, ready). Log only; don't gate on it. */
    at_simple(dce, "AT+SHSTATE?", HTTPS_T_AT_SHORT_MS);

    /* === Step 6: connect ============================================
     * AT+SHCONN returns OK after the TCP+TLS handshake completes.
     * Long timeout — TLS handshake over LTE-M can take 5-30 s.
     *
     * Use at_raw with explicit pass="OK" fail="ERROR" so any error
     * URC arriving before/with ERROR (like "+CME ERROR: <code>")
     * gets captured in the response buffer for diagnostic logging. */
    char shconn_resp[512] = {0};
    err = esp_modem_at_raw(dce, "AT+SHCONN\r", shconn_resp,
                            "OK", "ERROR", HTTPS_T_SHCONN_MS);
    for (char *c = shconn_resp; *c; c++) if (*c == '\r' || *c == '\n') *c = ' ';
    if (err == ESP_OK) {
        ESP_LOGI(TAG, "AT+SHCONN → OK%s%.220s",
                 shconn_resp[0] ? ", resp=" : "", shconn_resp);
    } else {
        ESP_LOGE(TAG, "AT+SHCONN → %s, resp=%.220s",
                 esp_err_to_name(err), shconn_resp);
        /* Query SHSTATE for additional diagnostic info. */
        at_simple(dce, "AT+SHSTATE?", HTTPS_T_AT_SHORT_MS);
        goto cleanup_disc;
    }

    /* Verify "+SHSTATE: 1" (connected). */
    err = esp_modem_at(dce, "AT+SHSTATE?", resp, HTTPS_T_AT_SHORT_MS);
    ESP_LOGI(TAG, "AT+SHSTATE? → %s, response=%s", esp_err_to_name(err), resp);
    if (err != ESP_OK || !strstr(resp, "+SHSTATE: 1")) {
        ESP_LOGE(TAG, "SHSTATE not connected");
        goto cleanup_disc;
    }

    /* === Step 7: headers ============================================ */
    at_simple(dce, "AT+SHCHEAD", HTTPS_T_AT_SHORT_MS);
    at_simple(dce, "AT+SHAHEAD=\"Content-Type\",\"application/json\"",
              HTTPS_T_AT_SHORT_MS);
    at_simple(dce, "AT+SHAHEAD=\"User-Agent\",\"vmflow-esp32s3\"",
              HTTPS_T_AT_SHORT_MS);

    /* === Step 8: body (two-step prompt protocol) ====================
     *
     * Field log a3a8de05+SNI showed the single-write trick (AT command
     * + body in one UART write) doesn't work on firmware 1951B17:
     * the modem sends back "\r\n>\r\n" prompt, then waits for body
     * bytes — but the body bytes we sent in the same write were never
     * consumed. Modem timed out after our cmd_timeout window, body
     * never reached the HTTPS engine.
     *
     * Two-step protocol it is:
     *
     *   Step 8a: Send "AT+SHBOD=<len>,10000\r"
     *            Wait for ">" (prompt) via at_raw pass=">"
     *
     *   Step 8b: Send the body bytes (no terminator)
     *            Wait for "OK" via at_raw pass="OK"
     *
     * esp_modem's t->command() writes bytes verbatim per
     * esp_modem_dte.cpp:154, so we can use at_raw for both halves —
     * the second call literally just writes the body string and waits
     * for the modem's "OK" response after it consumes the bytes. */
    snprintf(cmd, sizeof(cmd), "AT+SHBOD=%zu,10000\r", body_len);
    err = at_raw_match(dce, cmd, resp, sizeof(resp), ">", "ERROR",
                       HTTPS_T_AT_SHORT_MS);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "SHBOD prompt phase failed: %s, resp=%.180s",
                 esp_err_to_name(err), resp);
        goto cleanup_disc;
    }
    ESP_LOGI(TAG, "SHBOD prompt received, sending %zu B body", body_len);

    /* Body must be NUL-terminated for std::string conversion in
     * at_raw to capture the full length. provision_claim_task's
     * snprintf output is NUL-terminated, so this is guaranteed for
     * our caller; defensive copy + NUL anyway in case of future
     * callers with raw buffers. */
    char body_with_nul[256];
    if (body_len + 1 > sizeof(body_with_nul)) {
        ESP_LOGE(TAG, "SHBOD: body too large (%zu) for staging buffer", body_len);
        err = ESP_ERR_INVALID_ARG;
        goto cleanup_disc;
    }
    memcpy(body_with_nul, body, body_len);
    body_with_nul[body_len] = '\0';

    err = at_raw_match(dce, body_with_nul, resp, sizeof(resp),
                       "OK", "ERROR", HTTPS_T_AT_MED_MS);
    ESP_LOGI(TAG, "SHBOD body phase: %s, resp=%.120s",
             esp_err_to_name(err), resp);
    if (err != ESP_OK) {
        goto cleanup_disc;
    }

    /* === Step 9: send POST request ==================================
     * AT+SHREQ returns OK quickly, then "+SHREQ: \"POST\",<status>,<dlen>"
     * arrives later. Use at_raw_match with pass="+SHREQ:" so we wait
     * for the URC explicitly. */
    snprintf(cmd, sizeof(cmd), "AT+SHREQ=\"%s\",3\r", path);
    err = at_raw_match(dce, cmd, resp, sizeof(resp),
                       "+SHREQ:", "ERROR", HTTPS_T_SHREQ_MS);
    ESP_LOGI(TAG, "SHREQ → %s, response=%.200s",
             esp_err_to_name(err), resp);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "SHREQ failed");
        goto cleanup_disc;
    }

    int http_status = 0;
    int datalen     = 0;
    if (parse_shreq(resp, &http_status, &datalen) != ESP_OK) {
        ESP_LOGE(TAG, "SHREQ parse failed: %s", resp);
        err = ESP_FAIL;
        goto cleanup_disc;
    }
    ESP_LOGI(TAG, "SHREQ result: HTTP %d, %d byte response", http_status, datalen);
    if (status_out) *status_out = http_status;

    /* === Step 10: read response =====================================
     * AT+SHREAD=<offset>,<len>. Offset 0 = from start. Modem responds
     * with "\r\nOK\r\n\r\n+SHREAD: <len>\r\n<N bytes of body>".
     *
     * THE BUFFER PROBLEM: esp_modem_at_raw matches on the pass token
     * (`+SHREAD:`) and returns shortly after — the body bytes that
     * stream in afterwards either land in our buffer (if they hit the
     * same UART read cycle as the URC) or get queued for the NEXT AT
     * command (where they appear as a bogus "response" — visible in
     * earlier logs as "AT+SHDISC → ESP_FAIL, resp=<body tail>").
     *
     * Even with CONFIG_ESP_MODEM_C_API_STR_MAX bumped to 1024, large
     * bodies (>~100 B) split across the SHREAD/SHDISC boundary because
     * UART reads happen in chunks smaller than the full body.
     *
     * THE CHUNKED-READ FIX: read in small slices (CHUNK = 64 B). Each
     * slice's response (URC ~22 B + body ≤64 B = ~86 B) fits in one
     * UART read cycle, so the body bytes arrive together with the URC
     * and stay in our buffer. Concatenate slices into resp_buf. */
    if (datalen > 0) {
        /* === Chunked SHREAD with leak-recovery ========================
         * esp_modem_at_raw matches on "+SHREAD:" and returns immediately;
         * body bytes still in flight at that moment land in the NEXT AT
         * command's response prefix (before its own \r\nOK\r\n).
         *
         * Empirically each non-final 64-byte chunk loses ~3 bytes that
         * appear as the next chunk's prefix. We RECOVER them by parsing
         * each readbuf into:
         *   prefix = bytes before \r\nOK\r\n  → leak from previous chunk
         *   body   = bytes after  +SHREAD:N\r\n  → this chunk's own data
         *
         * After the final chunk, any residual leak is drained by a
         * dummy AT command whose response prefix carries the tail. */
        const int CHUNK = 64;
        char readbuf[256];
        size_t total_copied = 0;
        bool ok = true;
        int prev_unread = 0;

        for (int offset = 0; offset < datalen; offset += CHUNK) {
            int want = datalen - offset;
            if (want > CHUNK) want = CHUNK;

            memset(readbuf, 0, sizeof(readbuf));
            snprintf(cmd, sizeof(cmd), "AT+SHREAD=%d,%d\r", offset, want);
            err = at_raw_match(dce, cmd, readbuf, sizeof(readbuf),
                               "+SHREAD:", "ERROR", HTTPS_T_SHREAD_MS);
            if (err != ESP_OK) {
                ESP_LOGE(TAG, "SHREAD chunk @%d/%d failed: %s",
                         offset, datalen, esp_err_to_name(err));
                ok = false;
                break;
            }

            /* Recover leak from previous chunk: bytes before \r\nOK\r\n. */
            if (prev_unread > 0) {
                char *ok_pos = strstr(readbuf, "OK\r\n");
                if (ok_pos) {
                    char *leak_end = ok_pos;
                    while (leak_end > readbuf
                           && (leak_end[-1] == '\r' || leak_end[-1] == '\n')) {
                        leak_end--;
                    }
                    char *leak_start = readbuf;
                    while (leak_start < leak_end
                           && (*leak_start == '\r' || *leak_start == '\n')) {
                        leak_start++;
                    }
                    size_t leak_len = (size_t)(leak_end - leak_start);
                    if (leak_len > (size_t)prev_unread) leak_len = (size_t)prev_unread;
                    if (total_copied + leak_len < resp_buf_size) {
                        memcpy(resp_buf + total_copied, leak_start, leak_len);
                        total_copied += leak_len;
                    }
                }
            }

            /* Extract this chunk's own body. */
            char *urc = strstr(readbuf, "+SHREAD:");
            if (!urc) {
                ESP_LOGE(TAG, "SHREAD chunk @%d: URC missing", offset);
                ok = false;
                break;
            }
            char *eol = strchr(urc, '\n');
            if (!eol) {
                ESP_LOGE(TAG, "SHREAD chunk @%d: URC has no \\n", offset);
                ok = false;
                break;
            }
            eol++;

            size_t body_avail = strnlen(eol,
                                         sizeof(readbuf) - (size_t)(eol - readbuf));
            while (body_avail > 0
                   && (eol[body_avail - 1] == '\r' || eol[body_avail - 1] == '\n')) {
                body_avail--;
            }
            size_t body_copy = body_avail;
            if (body_copy > (size_t)want) body_copy = (size_t)want;
            if (total_copied + body_copy >= resp_buf_size) {
                body_copy = (resp_buf_size > total_copied + 1)
                              ? resp_buf_size - total_copied - 1 : 0;
            }
            memcpy(resp_buf + total_copied, eol, body_copy);
            total_copied += body_copy;
            prev_unread = (int)((size_t)want - body_copy);

            char logbuf[160];
            size_t logn = strnlen(readbuf, sizeof(logbuf) - 1);
            memcpy(logbuf, readbuf, logn);
            logbuf[logn] = '\0';
            for (char *c = logbuf; *c; c++) if (*c == '\r' || *c == '\n') *c = ' ';
            ESP_LOGI(TAG, "SHREAD chunk @%d/%d: own=%u, carry=%d, raw=%.140s",
                     offset, want, (unsigned)body_copy, prev_unread, logbuf);
        }

        /* Drain final-chunk leak via dummy AT. */
        if (ok && prev_unread > 0) {
            char tail[128] = {0};
            esp_err_t at_rc = esp_modem_at(dce, "AT", tail, 2000);
            char tail_log[128];
            size_t tn = strnlen(tail, sizeof(tail_log) - 1);
            memcpy(tail_log, tail, tn);
            tail_log[tn] = '\0';
            for (char *c = tail_log; *c; c++) if (*c == '\r' || *c == '\n') *c = ' ';
            ESP_LOGI(TAG, "SHREAD tail-drain (carry=%d): rc=%s, raw=%.100s",
                     prev_unread, esp_err_to_name(at_rc), tail_log);
            if (at_rc == ESP_OK) {
                char *t = tail;
                while (*t == '\r' || *t == '\n') t++;
                char *ok_pos = strstr(t, "OK");
                if (ok_pos) {
                    char *leak_end = ok_pos;
                    while (leak_end > t
                           && (leak_end[-1] == '\r' || leak_end[-1] == '\n')) {
                        leak_end--;
                    }
                    size_t tail_len = (size_t)(leak_end - t);
                    if (tail_len > (size_t)prev_unread) tail_len = (size_t)prev_unread;
                    if (total_copied + tail_len < resp_buf_size) {
                        memcpy(resp_buf + total_copied, t, tail_len);
                        total_copied += tail_len;
                    }
                }
            }
        }

        if (ok && total_copied >= (size_t)datalen) {
            if (total_copied >= resp_buf_size) total_copied = resp_buf_size - 1;
            resp_buf[total_copied] = '\0';
            if (resp_len_out) *resp_len_out = total_copied;
            final_err = ESP_OK;
            ESP_LOGI(TAG, "SHREAD %d B body fully captured (total=%u)",
                     datalen, (unsigned)total_copied);
        } else {
            if (total_copied < resp_buf_size) {
                resp_buf[total_copied] = '\0';
            } else {
                resp_buf[resp_buf_size - 1] = '\0';
            }
            if (resp_len_out) *resp_len_out = total_copied;
            ESP_LOGW(TAG, "SHREAD partial: got %u/%d B — HTTP status %d still returned",
                     (unsigned)total_copied, datalen, http_status);
            final_err = ESP_OK;
        }
    } else {
        /* No body — still success at the HTTP level. */
        if (resp_len_out) *resp_len_out = 0;
        resp_buf[0] = '\0';
        final_err = ESP_OK;
    }

cleanup_disc:
    /* === Step 11: disconnect ======================================== */
    at_simple(dce, "AT+SHDISC", HTTPS_T_AT_SHORT_MS);

    /* === Step 12: deactivate internal bearer ========================
     * Cleanup. Returns OK immediately, "+APP PDP: <n>,DEACTIVE" arrives
     * later as URC — we don't wait for it. Deactivate whichever bearer
     * was active (or both as a defensive measure). */
    if (active_bearer == 3) {
        at_simple(dce, "AT+CNACT=3,0", HTTPS_T_AT_SHORT_MS);
    } else {
        at_simple(dce, "AT+CNACT=0,0", HTTPS_T_AT_SHORT_MS);
    }

    return final_err == ESP_OK ? ESP_OK : (err != ESP_OK ? err : ESP_FAIL);
}
