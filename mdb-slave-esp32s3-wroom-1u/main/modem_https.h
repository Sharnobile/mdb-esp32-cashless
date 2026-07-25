/*
 * VMflow.xyz
 *
 * modem_https.h — HTTPS POST via SIM7080G internal IP/SSL stack
 *
 * Bypasses the host's PPP+lwIP+mbedtls path entirely. Instead drives the
 * modem's built-in HTTPS engine via AT+CNCFG/CNACT/CSSLCFG/SHCONF/SHCONN/
 * SHBOD/SHREQ/SHREAD/SHDISC. The modem handles TCP, TLS, and HTTP all
 * internally; we only see the final HTTP status + response body via AT.
 *
 * Why: field test 2026-04-29 demonstrated the same SIM card works
 * cleanly in a separate LTE router, while our PPP+lwIP path on the
 * SIM7080G+esp_modem 1.4.0 stack stalls TLS handshakes after the
 * server certificate. The PPP path is not the modem's "official" data
 * path — the modem's internal TCP/IP stack is what every consumer
 * router uses for HTTPS. Switching to it for the one-shot claim
 * mirrors what's already known-to-work.
 *
 * Scope: ONLY used for the provisioning claim. Steady-state MQTT
 * continues over PPP (which works for small-payload steady-state
 * traffic where the failure mode doesn't manifest).
 *
 * Caller contract: modem MUST be in COMMAND mode (NOT PPP DATA mode)
 * when this function is called, and MUST already be attached to the
 * cellular network (CEREG: 1 or 5). Caller is responsible for tearing
 * PPP down via modem_disconnect() before calling and bringing it back
 * up with modem_connect() afterwards if needed.
 *
 * Per SIMCom HTTP(S) Application Note V1.02 §5.2.2.
 */

#ifndef MODEM_HTTPS_H
#define MODEM_HTTPS_H

#include <stdbool.h>
#include <stddef.h>
#include <esp_err.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Issue an HTTPS POST request via the modem's internal stack.
 *
 *   url           Full URL including scheme + host (no path).
 *                 e.g. "https://supabase-test.kerl-handel.de"
 *   path          Request path starting with /.
 *                 e.g. "/functions/v1/claim-device"
 *   apn           APN to configure the internal bearer with.
 *                 e.g. "sensor.net"
 *   body          Pointer to JSON request body (no NUL required).
 *   body_len      Number of bytes in body.
 *   resp_buf      Caller-provided buffer for response body.
 *   resp_buf_size Size of resp_buf (response gets NUL-terminated).
 *   resp_len_out  Out: bytes received in resp_buf (excluding the NUL).
 *   status_out    Out: HTTP status code (e.g. 200).
 *   timeout_ms    Total budget for the entire transaction (connect,
 *                 send, receive). SIMCom's per-step timeouts are
 *                 derived from this.
 *
 * Returns:
 *   ESP_OK if the entire transaction completed and an HTTP response
 *     was obtained. status_out reflects the actual HTTP status; non-2xx
 *     status is NOT an error here — caller decides how to handle it.
 *   ESP_ERR_TIMEOUT if any step exceeded its slice of timeout_ms.
 *   ESP_ERR_INVALID_STATE if the modem isn't responsive or the
 *     internal bearer fails to activate.
 *   ESP_FAIL on any other failure (parse error, response truncation,
 *     etc.).
 */
esp_err_t modem_https_post_json(const char *url,
                                 const char *path,
                                 const char *apn,
                                 const char *body,
                                 size_t body_len,
                                 char *resp_buf,
                                 size_t resp_buf_size,
                                 size_t *resp_len_out,
                                 int *status_out,
                                 int timeout_ms);

#ifdef __cplusplus
}
#endif

#endif /* MODEM_HTTPS_H */
