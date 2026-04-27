/*
 * VMflow.xyz
 *
 * modem.h — SIM7080G driver public API
 *
 * Single source of truth for the cellular modem lifecycle. Consumers
 * (network.c in P2, webui_server.c in P3) interact with the modem only
 * through this header — no esp_modem_* symbols leak.
 */

#ifndef MODEM_H
#define MODEM_H

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <esp_err.h>

#ifdef __cplusplus
extern "C" {
#endif

/* LTE network mode encoding — matches AT+CMNB and SIM7080G_CMNB Kconfig. */
typedef enum {
    MODEM_LTE_MODE_CATM  = 1,
    MODEM_LTE_MODE_NBIOT = 2,
    MODEM_LTE_MODE_BOTH  = 3,
} modem_lte_mode_t;

/* Snapshot of modem state. All fields are best-effort; consumers must
 * tolerate empty strings and rssi_dbm == 0 (means "unknown"). */
typedef struct {
    bool                registered;       /* AT+CEREG stat 1 (home) or 5 (roaming) */
    int8_t              rssi_dbm;         /* derived from AT+CSQ; 0 = unknown */
    char                operator_name[32];/* e.g. "Vodafone DE"; empty if unknown */
    char                ip[16];           /* PPP-assigned IPv4 dotted; empty if no PPP */
    modem_lte_mode_t    active_mode;      /* what the modem actually negotiated */
} modem_status_t;

/* ---- Lifecycle ---- */

/*
 * Detect whether a SIM7080G is wired and responsive.
 *
 * Sequence (safe on boards without a modem):
 *   1. Configure UART2 at 115200, GPIOs RX/TX/PWR per pin defaults.
 *   2. Try esp_modem_sync() (modem may already be on after warm reset).
 *   3. If fail: switch to ESP_MODEM_MODE_COMMAND (PPP escape), retry sync.
 *   4. If still fail: pulse PWRKEY (turns the modem on if attached), retry.
 *   5. Returns true only if AT sync succeeds; false otherwise.
 *
 * Total worst-case duration: ~13 s on a board without a modem (sync
 * timeouts + a no-op power pulse). Quick path (warm modem already on):
 * < 500 ms.
 *
 * Idempotent — safe to call multiple times. Does NOT enable any cellular
 * function (CFUN stays at whatever the modem booted with).
 */
bool modem_probe(void);

/*
 * Returns whether the most recent modem_probe() succeeded — i.e. whether
 * a SIM7080G is actually attached and synced. Used by network.c to
 * disambiguate `NETWORK_STATE_SOFTAP_ONLY` (which can be reached either
 * from a cellular board without an APN OR a WiFi-only board with no
 * saved credentials) so the captive portal renders the correct variant.
 */
bool modem_is_present(void);

/*
 * Configure the modem with credentials and prepare for network attach.
 * Must be called after a successful modem_probe(). Does not establish
 * PPP — call modem_connect() for that.
 *
 * `apn` is required (non-NULL, non-empty). `pin` may be NULL or empty
 * (no PIN). `mode` selects LTE-M / NB-IoT / both.
 */
esp_err_t modem_init(const char *apn, const char *pin, modem_lte_mode_t mode);

/*
 * Bring the modem online: enable RF (CFUN=1), wait for network
 * registration (AT+CEREG, up to 60 s), switch to PPP data mode. On
 * success, the PPP netif becomes the default route.
 */
esp_err_t modem_connect(void);

/*
 * Tear down the PPP link cleanly and return to AT command mode. Safe
 * to call even if PPP is not currently active.
 */
esp_err_t modem_disconnect(void);

/*
 * Hard power-cycle the modem: assert PWRKEY for 1.2 s, wait 5 s for
 * boot. Used by the recovery layer (P4) when AT sync stops responding.
 * Caller should re-init/re-connect afterwards.
 */
void modem_power_cycle(void);

/*
 * Refresh and return current modem status. Cheap to call (issues
 * AT+CSQ, AT+CEREG?, AT+COPS?). Times out fast (<3 s).
 */
void modem_status(modem_status_t *out);

/* ---- NVS helpers (cellular config) ---- */

/* Recommended buffer sizes for the load helper. */
#define MODEM_APN_MAX   64
#define MODEM_PIN_MAX   12

/*
 * Load cellular config from NVS namespace "vmflow", keys
 * "apn" / "sim_pin" / "lte_mode". Returns ESP_OK on success and fills
 * the outputs. Returns ESP_ERR_NVS_NOT_FOUND if either the namespace
 * does not exist yet OR the apn key is missing/empty (caller treats
 * both as "no cellular config saved"). Returns ESP_ERR_INVALID_ARG if
 * apn_out is NULL or apn_size is 0. pin_out and mode_out are optional.
 */
esp_err_t modem_nvs_load(char *apn_out, size_t apn_size,
                         char *pin_out, size_t pin_size,
                         modem_lte_mode_t *mode_out);

/*
 * Save cellular config to NVS. apn must be non-NULL and non-empty;
 * pin may be NULL or empty. Returns the underlying NVS error on
 * failure.
 */
esp_err_t modem_nvs_save(const char *apn, const char *pin, modem_lte_mode_t mode);

/* ---- Watchdog ---- */

/*
 * Periodic AT keepalive sent to the modem from a low-priority FreeRTOS
 * task (started via modem_start_watchdog). Returns ESP_OK if the modem
 * responded to the bare "AT" within ~3s. Failure modes:
 *   - In PPP DATA mode the modem won't respond to AT — caller must
 *     issue an escape (+++) first; the watchdog handles this internally.
 *   - Three consecutive failures trigger modem_power_cycle + re-init.
 */
esp_err_t modem_at_keepalive_ping(void);

/*
 * Start the watchdog task. Must be called only after a successful
 * modem_connect. Idempotent — second call is a no-op. The task runs
 * forever (no stop API in P4; modem_stop_watchdog is a placeholder
 * for future use).
 */
void modem_start_watchdog(void);
void modem_stop_watchdog(void);   /* P4: no-op; reserved */

#ifdef __cplusplus
}
#endif

#endif /* MODEM_H */
