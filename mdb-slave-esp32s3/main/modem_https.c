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
     * comment) — the log is informational only, don't parse it. */
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

    /* === Step 3: SSL config (TLS 1.2 on SSL slot 1) ================== */
    at_simple(dce, "AT+CSSLCFG=\"sslversion\",1,3", HTTPS_T_AT_SHORT_MS);

    /* === Step 4: HTTPS session SSL slot, no cert verification ========
     * Empty cert filename ("") means: don't validate server cert. The
     * prov_code carried in the body is single-use and short-lived; the
     * security model accepts a one-shot MitM risk on this one call in
     * exchange for compatibility with arbitrary CAs (Cloudflare, GTS,
     * etc.) without uploading certs to the modem's filesystem. The
     * passkey we receive in the response is then used for XOR-encrypted
     * MQTT traffic going forward. */
    at_simple(dce, "AT+SHSSL=1,\"\"", HTTPS_T_AT_SHORT_MS);

    /* === Step 5: HTTPS session config ================================ */
    snprintf(cmd, sizeof(cmd), "AT+SHCONF=\"URL\",\"%s\"", url);
    err = at_simple(dce, cmd, HTTPS_T_AT_SHORT_MS);
    if (err != ESP_OK) goto cleanup_disc;

    at_simple(dce, "AT+SHCONF=\"BODYLEN\",1024",   HTTPS_T_AT_SHORT_MS);
    at_simple(dce, "AT+SHCONF=\"HEADERLEN\",350",  HTTPS_T_AT_SHORT_MS);

    /* === Step 6: connect ============================================
     * AT+SHCONN returns OK after the TCP+TLS handshake completes.
     * Long timeout — TLS handshake over LTE-M can take 5-30 s. */
    err = at_simple(dce, "AT+SHCONN", HTTPS_T_SHCONN_MS);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "SHCONN failed");
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

    /* === Step 8: body ===============================================
     * Per the docstring at top: we send the AT+SHBOD command and the
     * raw body bytes as one UART write. The modem reads the command
     * line up to '\r', then drains the next <len> bytes for the body
     * from the same UART RX buffer. esp_modem_at_raw waits for our
     * pass token "OK" which arrives after the modem finishes reading
     * the body — no separate prompt round-trip required.
     *
     * cmd buffer must be large enough for the AT line + body. With
     * sizeof(cmd)=512 and our claim body ~80 bytes (JSON with prov
     * code + MAC), we have plenty of headroom. */
    int n = snprintf(cmd, sizeof(cmd), "AT+SHBOD=%zu,10000\r", body_len);
    if (n < 0 || (size_t)n + body_len >= sizeof(cmd)) {
        ESP_LOGE(TAG, "SHBOD: body too large for cmd buffer (%zu bytes)", body_len);
        err = ESP_ERR_INVALID_ARG;
        goto cleanup_disc;
    }
    memcpy(cmd + n, body, body_len);
    /* IMPORTANT: cmd is now exactly n + body_len bytes long, but
     * esp_modem_at_raw passes the cmd to a std::string constructor
     * that uses strlen(). If body has any embedded NUL byte we'd
     * truncate. JSON has no NULs by construction, but be defensive:
     * we add a trailing NUL to cap the string at exactly the right
     * length. */
    cmd[n + body_len] = '\0';

    err = at_raw_match(dce, cmd, resp, sizeof(resp), "OK", "ERROR",
                       HTTPS_T_AT_MED_MS);
    ESP_LOGI(TAG, "SHBOD (cmd %d B + body %zu B) → %s", n, body_len,
             esp_err_to_name(err));
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "SHBOD response: %.200s", resp);
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
     * with "+SHREAD: <len>\r\n<bytes>".
     *
     * Note: response data buffer must be at least datalen + ~32 bytes
     * for the URC header. We use a stack-allocated scratch buffer of
     * 4 KB which fits the typical claim response (~250 bytes). */
    if (datalen > 0) {
        char readbuf[4096];
        snprintf(cmd, sizeof(cmd), "AT+SHREAD=0,%d", datalen);
        err = at_raw_match(dce, cmd, readbuf, sizeof(readbuf),
                           "OK", "ERROR", HTTPS_T_SHREAD_MS);
        ESP_LOGI(TAG, "SHREAD %d B → %s", datalen, esp_err_to_name(err));
        if (err == ESP_OK) {
            size_t copied = 0;
            if (parse_shread(readbuf, resp_buf, resp_buf_size, &copied) == ESP_OK) {
                if (resp_len_out) *resp_len_out = copied;
                final_err = ESP_OK;
            } else {
                ESP_LOGE(TAG, "SHREAD parse failed");
                err = ESP_FAIL;
            }
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
