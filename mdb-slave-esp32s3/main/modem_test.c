/*
 * VMflow.xyz
 *
 * modem_test.c — P1 hardware validation entry point.
 *
 * Activated by Kconfig CASHLESS_TEST_MODE_MODEM. When enabled, this
 * app_main runs instead of the production one — exercises modem_probe,
 * init, connect, status repeatedly, logs to serial.
 *
 * Removed during P2.
 */

#include "sdkconfig.h"

#if CONFIG_CASHLESS_TEST_MODE_MODEM

#include <string.h>
#include <esp_log.h>
#include <esp_netif.h>
#include <esp_event.h>
#include <nvs_flash.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

#include "modem.h"

#define TAG "modem_test"

/* Forward-declared in modem.c (will move to modem.h in P3). */
esp_err_t modem_nvs_load(char *apn_out, size_t apn_size,
                         char *pin_out, size_t pin_size,
                         modem_lte_mode_t *mode_out);

void app_main(void) {
    ESP_LOGW(TAG, "================================================");
    ESP_LOGW(TAG, "  P1 modem driver test main (NOT PRODUCTION)   ");
    ESP_LOGW(TAG, "================================================");

    /* NVS init (modem_nvs_load needs it) */
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        nvs_flash_erase();
        nvs_flash_init();
    }

    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());

    ESP_LOGI(TAG, "calling modem_probe()...");
    bool present = modem_probe();
    ESP_LOGI(TAG, "modem_probe → %s", present ? "TRUE (modem detected)" : "FALSE (no modem)");

    if (!present) {
        ESP_LOGI(TAG, "no modem; sleeping forever (this is the WiFi-only-board outcome)");
        while (1) vTaskDelay(pdMS_TO_TICKS(60000));
    }

    /* Modem present. Try to bring it online. */
    char apn[64], pin[12];
    modem_lte_mode_t mode;
    err = modem_nvs_load(apn, sizeof(apn), pin, sizeof(pin), &mode);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "no APN in NVS — falling back to compile-time default '%s'",
                 CONFIG_SIM7080G_APN);
        strcpy(apn, CONFIG_SIM7080G_APN);
        pin[0] = '\0';
        mode = (modem_lte_mode_t)CONFIG_SIM7080G_CMNB;
    } else {
        ESP_LOGI(TAG, "loaded NVS: apn=%s, pin=%s, mode=%d", apn,
                 pin[0] ? "(set)" : "(none)", mode);
    }

    err = modem_init(apn, pin, mode);
    ESP_LOGI(TAG, "modem_init → %s", esp_err_to_name(err));
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "init failed; sleeping");
        while (1) vTaskDelay(pdMS_TO_TICKS(60000));
    }

    err = modem_connect();
    ESP_LOGI(TAG, "modem_connect → %s", esp_err_to_name(err));

    /* Status loop, every 10 s for inspection */
    while (1) {
        modem_status_t st;
        modem_status(&st);
        ESP_LOGI(TAG, "STATUS: registered=%d rssi=%d dBm op='%s' ip=%s mode=%d",
                 st.registered, st.rssi_dbm, st.operator_name, st.ip, st.active_mode);
        vTaskDelay(pdMS_TO_TICKS(10000));
    }
}

#endif /* CONFIG_CASHLESS_TEST_MODE_MODEM */
