/*
 * sale_queue.c — NVS-backed persistent sales queue (see sale_queue.h).
 */

#include "sale_queue.h"

#include <string.h>
#include <esp_log.h>
#include <esp_sntp.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <freertos/semphr.h>
#include <nvs_flash.h>
#include <nvs.h>
#include <time.h>

#define TAG "sale_queue"

// NVS namespace — separate from "vmflow" so a device-config wipe can be
// performed without discarding pending sales.
#define NS "sale_q"

// Metadata keys
#define K_HEAD      "head"      // u32: next slot to publish
#define K_TAIL      "tail"      // u32: next slot to write
#define K_OVERFLOW  "overflow"  // u32: count of dropped sales
#define K_LAST_SEQ  "last_seq"  // u32: last assigned sale_seq

// Per-slot key prefix. Keys are "s" + decimal index (max "s511" = 4 chars +
// NUL = 5 chars, well under the 15-char NVS limit).
#define SLOT_KEY_FMT "s%u"

// Device identity — filled from globals during publish; we do not store
// them in the queue records because they're constants per device and
// change only on re-provisioning (queue assumed empty then).
extern char my_company_id[40];
extern char my_device_id[40];
extern char my_passkey[18];

extern void xorEncodeWithPasskey(uint8_t cmd, uint16_t itemPrice,
                                 uint16_t itemNumber, uint16_t paxCounter,
                                 uint8_t *payload);
extern int mqtt_publish_safe(esp_mqtt_client_handle_t client, const char *topic,
                             const char *data, int len, int qos, int retain);
extern bool mqtt_started;

static esp_mqtt_client_handle_t s_client = NULL;
static SemaphoreHandle_t s_lock = NULL;   // protects head/tail/last_seq/in_flight
static SemaphoreHandle_t s_wake = NULL;   // drain task wakeup

static uint32_t s_head = 0;
static uint32_t s_tail = 0;
static uint32_t s_overflow = 0;
static uint32_t s_last_seq = 0;

// msg_id of the sale currently in flight to the broker (0 = none).
// Cleared on PUBACK or on MQTT disconnect.
static int s_in_flight_msg_id = 0;

static void load_u32(nvs_handle_t h, const char *key, uint32_t *out) {
    if (nvs_get_u32(h, key, out) != ESP_OK) *out = 0;
}

void sale_queue_init(void) {
    if (s_lock == NULL) s_lock = xSemaphoreCreateMutex();
    if (s_wake == NULL) s_wake = xSemaphoreCreateBinary();

    nvs_handle_t h;
    if (nvs_open(NS, NVS_READWRITE, &h) != ESP_OK) {
        ESP_LOGE(TAG, "nvs_open(%s) failed — queue will be in-memory only", NS);
        return;
    }
    load_u32(h, K_HEAD,     &s_head);
    load_u32(h, K_TAIL,     &s_tail);
    load_u32(h, K_OVERFLOW, &s_overflow);
    load_u32(h, K_LAST_SEQ, &s_last_seq);
    nvs_close(h);

    uint32_t pending = s_tail - s_head;
    ESP_LOGI(TAG, "queue restored: head=%u tail=%u pending=%u overflow=%u last_seq=%u",
             (unsigned)s_head, (unsigned)s_tail, (unsigned)pending,
             (unsigned)s_overflow, (unsigned)s_last_seq);
}

bool sale_queue_enqueue(uint8_t cmd, uint16_t item_price, uint16_t item_number) {
    if (s_lock == NULL) {
        ESP_LOGE(TAG, "enqueue before init — dropping sale");
        return false;
    }
    xSemaphoreTake(s_lock, portMAX_DELAY);

    // Capacity check: reject only if the queue is completely full. We
    // prefer to overflow (count) rather than block the MDB response —
    // even a lost sale is better than hanging the bus.
    uint32_t pending = s_tail - s_head;
    if (pending >= SALE_QUEUE_CAPACITY) {
        s_overflow++;
        nvs_handle_t oh;
        if (nvs_open(NS, NVS_READWRITE, &oh) == ESP_OK) {
            nvs_set_u32(oh, K_OVERFLOW, s_overflow);
            nvs_commit(oh);
            nvs_close(oh);
        }
        ESP_LOGE(TAG, "queue full (capacity=%u) — sale DROPPED (overflow=%u)",
                 (unsigned)SALE_QUEUE_CAPACITY, (unsigned)s_overflow);
        xSemaphoreGive(s_lock);
        return false;
    }

    // Clock sync check: if SNTP has never locked we don't have a reliable
    // wall clock. Record the sale anyway with occurred_at=0 + time_uncertain,
    // server will substitute its receive time.
    sntp_sync_status_t sync = sntp_get_sync_status();
    bool time_ok = (sync == SNTP_SYNC_STATUS_COMPLETED);
    time_t now_sec = time_ok ? time(NULL) : 0;
    // Extra guard: plausible unix time ≥ 2023-01-01
    if (time_ok && now_sec < 1672531200) {
        time_ok = false;
        now_sec = 0;
    }

    sale_record_t rec = {
        .cmd            = cmd,
        .item_price     = item_price,
        .item_number    = item_number,
        .occurred_at    = (uint32_t)now_sec,
        .sale_seq       = ++s_last_seq,
        .time_uncertain = time_ok ? 0 : 1,
    };

    uint32_t slot = s_tail % SALE_QUEUE_CAPACITY;
    char key[8];
    snprintf(key, sizeof(key), SLOT_KEY_FMT, (unsigned)slot);

    nvs_handle_t h;
    esp_err_t err = nvs_open(NS, NVS_READWRITE, &h);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "nvs_open failed: %s — dropping sale seq=%u",
                 esp_err_to_name(err), (unsigned)rec.sale_seq);
        s_last_seq--; // roll back the allocation so we don't leave gaps
        xSemaphoreGive(s_lock);
        return false;
    }

    // Write record + new tail + new last_seq, commit ONCE. If the commit
    // fails (power loss), none of the three is persisted — consistent.
    bool ok = true;
    if (nvs_set_blob(h, key, &rec, sizeof(rec)) != ESP_OK) ok = false;
    if (ok && nvs_set_u32(h, K_LAST_SEQ, s_last_seq)    != ESP_OK) ok = false;
    if (ok && nvs_set_u32(h, K_TAIL,     s_tail + 1)    != ESP_OK) ok = false;
    if (ok && nvs_commit(h)                             != ESP_OK) ok = false;
    nvs_close(h);

    if (!ok) {
        ESP_LOGE(TAG, "NVS write failed for seq=%u — sale NOT persisted",
                 (unsigned)rec.sale_seq);
        s_last_seq--;
        xSemaphoreGive(s_lock);
        return false;
    }

    s_tail++;
    ESP_LOGI(TAG, "enqueued seq=%u slot=%u price=%u item=%u time_uncertain=%u (pending=%u)",
             (unsigned)rec.sale_seq, (unsigned)slot,
             (unsigned)rec.item_price, (unsigned)rec.item_number,
             (unsigned)rec.time_uncertain, (unsigned)(s_tail - s_head));

    xSemaphoreGive(s_lock);
    xSemaphoreGive(s_wake); // nudge drain task
    return true;
}

// Loads the head record. Caller must hold s_lock. Returns false when queue empty.
static bool load_head_record(sale_record_t *out) {
    if (s_tail == s_head) return false;
    uint32_t slot = s_head % SALE_QUEUE_CAPACITY;
    char key[8];
    snprintf(key, sizeof(key), SLOT_KEY_FMT, (unsigned)slot);

    nvs_handle_t h;
    if (nvs_open(NS, NVS_READONLY, &h) != ESP_OK) return false;

    size_t len = sizeof(sale_record_t);
    esp_err_t err = nvs_get_blob(h, key, out, &len);
    nvs_close(h);

    if (err != ESP_OK || len != sizeof(sale_record_t)) {
        ESP_LOGE(TAG, "head slot %u corrupt (err=%s len=%u) — advancing past it",
                 (unsigned)slot, esp_err_to_name(err), (unsigned)len);
        return false;
    }
    return true;
}

// Builds a 19-byte v2 sale payload with idempotency fields.
//
// v2 layout (after XOR decrypt):
//   byte 0    : cmd
//   byte 1    : version = 0x02
//   bytes 2-5 : item_price (4 bytes, big-endian, scale-factor encoded)
//   bytes 6-7 : item_number (2 bytes, big-endian)
//   bytes 8-11: occurred_at (unix seconds, big-endian) — 0 if time_uncertain
//   byte 12   : flags (bit 0 = time_uncertain)
//   byte 13   : reserved
//   bytes 14-17: sale_seq (uint32, big-endian)
//   byte 18   : checksum = sum(bytes 0..17) & 0xFF
static void build_v2_payload(const sale_record_t *rec, uint8_t *payload) {
    // Delegate to the existing encoder for the scale-factor conversion and
    // the random filler: xorEncodeWithPasskey fills the unused bytes with
    // esp_fill_random() before XOR-encrypting, which prevents a replay
    // adversary from trivially distinguishing otherwise-identical sales.
    // We then decrypt, stamp the v2-specific fields (version, occurred_at,
    // flags, sale_seq), recompute the checksum, and re-encrypt with the
    // same passkey — the only way to preserve the random-filler contract
    // without reimplementing the encoder.
    xorEncodeWithPasskey(rec->cmd, rec->item_price, rec->item_number, 0, payload);

    uint8_t v2[19];
    memcpy(v2, payload, 19);

    for (int i = 0; i < 18; i++) {
        v2[i + 1] ^= (uint8_t)my_passkey[i];
    }

    v2[1]  = SALE_PAYLOAD_V2;
    v2[8]  = (uint8_t)(rec->occurred_at >> 24);
    v2[9]  = (uint8_t)(rec->occurred_at >> 16);
    v2[10] = (uint8_t)(rec->occurred_at >> 8);
    v2[11] = (uint8_t)(rec->occurred_at);
    v2[12] = rec->time_uncertain ? 0x01 : 0x00;
    v2[13] = 0x00;
    v2[14] = (uint8_t)(rec->sale_seq >> 24);
    v2[15] = (uint8_t)(rec->sale_seq >> 16);
    v2[16] = (uint8_t)(rec->sale_seq >> 8);
    v2[17] = (uint8_t)(rec->sale_seq);

    // Recompute checksum on plaintext
    uint8_t chk = 0;
    for (int i = 0; i < 18; i++) chk += v2[i];
    v2[18] = chk;

    // Re-encrypt bytes 1..17
    for (int i = 0; i < 18; i++) {
        v2[i + 1] ^= (uint8_t)my_passkey[i];
    }

    memcpy(payload, v2, 19);
}

void sale_queue_on_published(int msg_id) {
    if (msg_id == 0) return;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (msg_id != s_in_flight_msg_id) {
        // Ack for some other publish (status, paxcounter, mdb-log) — ignore.
        xSemaphoreGive(s_lock);
        return;
    }

    // Advance head: the oldest sale is now confirmed on the broker.
    uint32_t new_head = s_head + 1;
    nvs_handle_t h;
    if (nvs_open(NS, NVS_READWRITE, &h) == ESP_OK) {
        nvs_set_u32(h, K_HEAD, new_head);
        nvs_commit(h);
        nvs_close(h);
        s_head = new_head;
    } else {
        ESP_LOGE(TAG, "PUBACK: nvs_open failed — head stays at %u (will retry on drain)",
                 (unsigned)s_head);
    }
    s_in_flight_msg_id = 0;
    xSemaphoreGive(s_lock);
    xSemaphoreGive(s_wake); // send next
}

void sale_queue_on_disconnect(void) {
    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_in_flight_msg_id = 0; // drain task will re-publish on reconnect
    xSemaphoreGive(s_lock);
}

uint32_t sale_queue_pending_count(void) {
    return s_tail - s_head;
}

uint32_t sale_queue_overflow_count(void) {
    return s_overflow;
}

uint32_t sale_queue_last_seq(void) {
    return s_last_seq;
}

static void sale_queue_publish_task(void *arg) {
    ESP_LOGI(TAG, "drain task started");
    for (;;) {
        // Wait up to 5s for wake; also retry periodically in case we missed a wake.
        xSemaphoreTake(s_wake, pdMS_TO_TICKS(5000));

        if (!mqtt_started) continue;

        xSemaphoreTake(s_lock, portMAX_DELAY);
        if (s_in_flight_msg_id != 0) {
            // Already waiting on a PUBACK — don't send another. QoS 1 with
            // a single-entry inflight window gives strictly ordered delivery.
            xSemaphoreGive(s_lock);
            continue;
        }
        sale_record_t rec;
        bool have = load_head_record(&rec);
        if (!have) {
            if (s_tail != s_head) {
                // corrupt slot — skip it so we don't deadlock
                uint32_t new_head = s_head + 1;
                nvs_handle_t h;
                if (nvs_open(NS, NVS_READWRITE, &h) == ESP_OK) {
                    nvs_set_u32(h, K_HEAD, new_head);
                    nvs_commit(h);
                    nvs_close(h);
                    s_head = new_head;
                }
            }
            xSemaphoreGive(s_lock);
            continue;
        }

        uint8_t payload[19];
        build_v2_payload(&rec, payload);

        char topic[128];
        snprintf(topic, sizeof(topic), "/%s/%s/sale", my_company_id, my_device_id);

        int msg_id = mqtt_publish_safe(s_client, topic, (const char *)payload,
                                       sizeof(payload), 1 /*QoS*/, 0);
        // QoS 1 publishes must return a positive msg_id; 0 is the sentinel
        // for "no in-flight", and negative values indicate publish failure.
        // In either failure case leave s_in_flight_msg_id == 0 so the next
        // wake retries this same slot.
        if (msg_id > 0) {
            s_in_flight_msg_id = msg_id;
            ESP_LOGI(TAG, "publishing seq=%u msg_id=%d (pending=%u)",
                     (unsigned)rec.sale_seq, msg_id,
                     (unsigned)(s_tail - s_head));
        } else {
            ESP_LOGW(TAG, "publish failed for seq=%u (msg_id=%d) — will retry",
                     (unsigned)rec.sale_seq, msg_id);
        }
        xSemaphoreGive(s_lock);
    }
}

void sale_queue_start(esp_mqtt_client_handle_t client) {
    s_client = client;
    xTaskCreate(sale_queue_publish_task, "sale_drain", 4096, NULL, 5, NULL);
    // Kick once in case we booted with pending entries.
    if (s_wake) xSemaphoreGive(s_wake);
}
