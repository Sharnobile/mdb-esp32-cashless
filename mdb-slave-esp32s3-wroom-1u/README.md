# ESP32-S3-WROOM-1U Cashless Firmware (prep branch)

Firmware target for the new custom PCB in `kicad/mdb_slave_esp32s3-wroom-1u/`
(branch `feature/esp32s3-wroom-u1-pcb`). This is a **copy of
[`mdb-slave-esp32s3`](../mdb-slave-esp32s3)**, adapted so the existing MDB /
WiFi / MQTT / provisioning logic runs unchanged on the new board. Builds
clean with `idf.py build` (ESP-IDF v5.5.1, esp32s3 target). **Not yet
flashed or tested on real hardware** — the PCB layout is still in progress.

## Status

- Board logic (MDB protocol, WiFi/MQTT, BLE, provisioning, sale queue) is
  identical to `mdb-slave-esp32s3` — **confirmed WiFi-only, no
  GPS/LTE-M/NB-IoT on this board**, so `network.c`'s existing "no modem →
  WiFi-only boot" path is used as-is and `modem.c`/`modem_https.c` stay
  fully inert.
- Pin assignments below are the authoritative table from the schematic's
  own IO legend (`kicad/mdb_slave_esp32s3-wroom-1u`, sheet notes), not the
  earlier script-extracted guess.
- Relay, custom-input, and 1-Wire drivers are implemented (see per-pin
  status below and "Board-specific drivers" for details). Everything
  board-specific is gated behind `detect_board_variant()` so the same
  firmware image stays safe to flash on either PCB.
- Relay/custom-input/1-Wire/NTC events are buffered offline in a local
  debug log (`debug_log.c`, custom `dbglog` flash partition) so a
  connectivity gap doesn't lose them — see "Local debug log" below.

## Pin mapping vs. schematic

Per the schematic's IO legend:

| GPIO | Function | Firmware define | Status |
|---|---|---|---|
| 0 | Boot button | `PIN_BOOT_BTN` | matches, no change |
| 1 | Relay 1 (J2) | `PIN_RELAY_1` | **driver done** — output, MQTT config cmd `0x33` |
| 2 | Relay 2 (J3) | `PIN_RELAY_2` | **driver done** — output, MQTT config cmd `0x34` |
| 3 | Board-ID strap | `PIN_BOARD_ID` | **repurposed, see below** |
| 4 | MDB RX | `PIN_MDB_RX` | matches, no change |
| 5 | MDB TX | `PIN_MDB_TX` | matches, no change |
| 6 | Custom input 1 (J11) | `PIN_CUSTOM_INPUT1` | **driver done** — debounced, published on `/input` |
| 7 | Thermistor (TH1) | `ADC_CHANNEL_THERMISTOR` (ADC1_CH6) | **driver done** — real °C via NCP18XH103F03RB B-constant, tracked every 5min (see below) |
| 8 | *(unused — was custom input 2)* | `PIN_DEX_RX` | freed up, see below |
| 9 | *(unused — was custom input 3)* | `PIN_DEX_TX` | freed up, see below |
| 10 | I2C SDA (J10) | `PIN_I2C_SDA` | matches, no change |
| 11 | I2C SCL (J10) | `PIN_I2C_SCL` | matches, no change |
| 12 | Buzzer (BZ1) | `PIN_BUZZER_PWR` | matches, no change |
| 13 | Pulse output (J8) | `PIN_PULSE_1` | matches, no change |
| 14, 17, 18 | free | — | |
| 15 | 1-Wire bus 1 (J4) | `PIN_ONEWIRE_1` | **driver done** — boot scan + 5min DS18B20 tracking (see below) |
| 16 | 1-Wire bus 2 (J5/J6) | `PIN_ONEWIRE_2` | **driver done** — boot scan + 5min DS18B20 tracking (see below) |
| 21 | Status LED (D2, WS2812) | `PIN_MDB_LED` | matches, no change |
| 47 | Custom input 2 (J13) | `PIN_CUSTOM_INPUT2` | **driver done** — debounced, published on `/input` |
| 48 | Custom input 3 (J14) | `PIN_CUSTOM_INPUT3` | **driver done** — debounced, published on `/input` |
| u0txd/u0rxd | UART debug (J9) | — | ESP-IDF console default, no change |
| 39–42 | JTAG (J7) | — | ESP32-S3 default JTAG pins, no change |
| 35,36,37,38 | free | — | |

### Custom inputs moved off the DEX pins (GPIO8/9 → GPIO47/48)

Original layout reused GPIO8/9 for `custom_input2/3` (J13/J14), which
collide with `PIN_DEX_RX`/`PIN_DEX_TX` on the original board — flashing
the "wrong" firmware would silently disable one function or the other.
GPIO17/18 were considered and rejected — those collide instead with
`PIN_SIM7080G_TX`/`PIN_SIM7080G_RX` on the basic-plus/cellular variant.
GPIO47/48 are free on every variant and aren't affected by
Quad-vs-Octal PSRAM pin reservations (unlike GPIO35-37).

**Done, verified against the schematic**: `feature/esp32s3-wroom-u1-pcb`
commit `0fb67e0` reroutes J13/J14 (with their pull-up resistors) to
GPIO47/48 and leaves GPIO8/9 as no-connect. Parsing the committed
`.kicad_sch` confirms `io47`→R19→J13 and `io48`→R22→J14, matching
`PIN_CUSTOM_INPUT2`/`PIN_CUSTOM_INPUT3` in
`mdb-slave-esp32s3-wroom-1u.c` exactly — no further firmware change
needed for this. Still not built/tested on a physical board.

### Automatic board detection (GPIO3) — kept as defense-in-depth

Even with the pin overlap above resolved by never reusing a GPIO number
across boards, the firmware still detects which board it's running on
at boot, in case some other future function (relay, 1-Wire, or anything
not yet mapped) turns out to collide with something on the original
board that isn't visible from its firmware's `PIN_*` list alone (no
access to that board's own schematic to double check):

- `PIN_BOARD_ID` (GPIO3) is read with the internal pull-up enabled in
  `detect_board_variant()` (`mdb-slave-esp32s3-wroom-1u.c`, called first
  thing in `app_main`).
- **Hardware action needed**: fit a **10kΩ pull-down from GPIO3 to GND**
  on this board's schematic only (`kicad/mdb_slave_esp32s3-wroom-1u`).
  Nothing to change on the original board — its GPIO3 is unused/floating,
  so the internal pull-up reads it HIGH.
  - Reads **LOW** → WROOM-1U detected → DEX/UART1 init is skipped.
  - Reads **HIGH** → original board detected → DEX/UART1 init runs as before.
- Once the custom-input reroute above lands, GPIO8/9 are simply unused
  on WROOM-1U (same as the SIM7080G pins already are) — the board-ID
  check for DEX is no longer strictly load-bearing, but it's cheap
  insurance and stays in place for whichever driver gets written next
  (relay/1-Wire) to gate against the original board.
- The two directories (`mdb-slave-esp32s3` / `mdb-slave-esp32s3-wroom-1u`)
  still exist separately mainly because of the differing flash-size/PSRAM
  `sdkconfig` (see below); the detection logic itself should eventually
  be backported into `mdb-slave-esp32s3` too so a binary built from
  either tree is interchangeable.

`SIM7080G_*` pin defines and `modem.c`/`modem_https.c` are inherited from
the copy but unused on this WiFi-only board — already self-disabling via
the existing `modem_probe()` fallback (it AT-probes the modem UART and
falls back to WiFi-only if nothing answers), no board-ID check needed
there.

### Board-specific drivers (relay / custom input / 1-Wire)

All gated behind `g_board_is_wroom_1u` (from `detect_board_variant()`) so
none of this ever runs on the original board, which has no matching
hardware on these pins.

- **Relays (GPIO1/2, `PIN_RELAY_1`/`PIN_RELAY_2`)**: plain digital
  outputs, initialised OFF at boot (`relay_init()`). Driven via the
  existing XOR-encrypted MQTT config command path — cmd `0x33` sets
  relay 1, `0x34` sets relay 2 (`configParam` 0/1). Commands are ignored
  with a warning log on the original board.
- **Custom inputs (GPIO6/47/48, `PIN_CUSTOM_INPUT1/2/3`)**:
  `custom_input_task` polls all three every `CUSTOM_INPUT_POLL_MS`
  (100 ms), debounces each transition over `CUSTOM_INPUT_DEBOUNCE_MS`
  (50 ms), and publishes `{channel, level, ts, prevHeldSec}` (QoS 1) to
  `/{company_id}/{device_id}/input` on every confirmed level change. The
  firmware stays device-agnostic — it doesn't know or care what's wired
  to a given channel (door contact, pushbutton, presence sensor, ...).
  Interpreting the events (open-too-long alarms, notification routing,
  thresholds) is backend/app work, tracked separately under "custom
  inputs management".
- **1-Wire buses (GPIO15/16, `PIN_ONEWIRE_1`/`PIN_ONEWIRE_2`)**: RMT-based
  bus scan via the `espressif/onewire_bus` + `espressif/ds18b20`
  components (`onewire_bus_scan_and_read()`), dispatched by ROM family
  code so a bus can host mixed device types later without touching the
  enumeration logic. DS18B20 (family `0x28`) is triggered and read once
  at boot (discovery only); any other family code is logged as "no
  driver for this family yet". Periodic tracking (below) re-reads known
  DS18B20s every 5 minutes.

### Local debug log (relay / custom input / 1-Wire / NTC)

Offline-safe buffer for diagnostic events, separate from the sales queue
(`sale_queue.c`, unchanged and still the priority path for not losing
sales during a connectivity gap). Implemented in `debug_log.c`/`.h`:

- **Storage**: a dedicated raw flash partition (`dbglog`, ~800 KB, see
  `partitions.csv`) holding a ring of fixed 16-byte records — not NVS,
  because per-key NVS overhead and page-relocation cost stop being worth
  it at this many small records. Two small NVS counters (write/ack
  cursor) track ring position across reboots, the same role as
  `sale_queue.c`'s `K_HEAD`/`K_TAIL`. Capacity is intentionally generous
  (~51,200 records) but still bounded regardless of how much flash is
  free — it's a bridge over connectivity gaps, not a permanent archive.
- **What gets logged**: relay commands (every `set_relay()` call),
  every debounced custom-input transition (alongside the existing
  immediate `/input` publish — belt-and-suspenders so a missed publish
  during an outage is replayed once reconnected), and periodic NTC/
  DS18B20 temperature readings.
- **NTC thermistor conversion**: TH1 is a Murata NCP18XH103F03RB
  (10 kΩ @ 25°C, B25/50 = 3380K per the Murata NTC catalog). The divider
  per the committed schematic (`kicad/mdb-slave-esp32s3`, TH1/R15) is
  `+3V3 → R15 (10kΩ) → ADC7 node → TH1 → GND`. `ntc_mv_to_celsius()`
  inverts the divider then applies the single-B-constant NTC equation.
  ADC calibration uses `adc_cali_create_scheme_curve_fitting()` where
  supported, falling back to an uncalibrated linear estimate otherwise.
- **Periodic tracking**: a 5-minute `esp_timer` (`periodic_sensor_timer_cb`)
  re-reads the NTC (both board variants) and, on WROOM-1U only, both
  1-Wire buses. Each sensor only logs when its reading has moved ≥0.5°C
  since the last logged value (or on the first reading) — a stable
  temperature doesn't fill the ring with near-duplicate entries.
- **Publishing**: reuses the existing `/mdb-log` MQTT topic (same
  pipeline as `publish_mdb_diag()` — no new topic, forwarder subscription,
  or DB table needed) with an added `"type"` field (`relay`/`input`/
  `onewire`/`ntc`) so the backend can tell the entries apart. A drain
  task publishes the oldest un-acked record once MQTT is connected,
  one at a time with PUBACK confirmation before advancing, mirroring
  `sale_queue.c`'s drain loop.

## Before first flash

- Done in `sdkconfig`: flash size set to **16 MB**, PSRAM enabled in
  **Quad** mode (`CONFIG_SPIRAM_MODE_QUAD`). Confirmed against the
  ESP32-S3 datasheet's Table 1-1 Series Comparison — the `R2` chip variant
  behind WROOM-1U-**N16R2** is `ESP32-S3R2`, which is 2 MB PSRAM in
  **Quad SPI**, not Octal (Octal is only on the R8/R8V/R16V variants).
  Remaining PSRAM sub-options (size auto-detect, speed, malloc
  integration, memtest) have since been filled in from their Kconfig
  defaults by a real `idf.py build` (ESP-IDF v5.5.1) — spot-check them in
  `idf.py menuconfig` before flashing if you change the PSRAM mode.
- GPIO3 pull-down (board-ID strap): the earlier note here was based on a
  misidentified pin — **pin 3 on the WROOM-1 module is `EN`, not GPIO3**.
  GPIO3 is pin **15** on the module's own pin table. A 10kΩ pull-down from
  GPIO3 (pin 15) to GND has since been added to the PCB and pushed to
  `feature/esp32s3-wroom-u1-pcb`.
- Relay / custom-input / 1-Wire drivers are implemented (see
  "Board-specific drivers" above) — still needs a real board to confirm
  behavior, since none of this has been exercised outside `idf.py build`.
- Partition table switched from the stock `partitions_two_ota_large.csv`
  to a custom `partitions.csv` (`CONFIG_PARTITION_TABLE_CUSTOM=y`) to add
  the `dbglog` partition for the local debug log above. Same nvs/otadata/
  phy_init/ota_0/ota_1 layout as before — only ~3.7MB of the 16MB flash is
  used even with `dbglog` added, so this isn't a tight fit. Not yet run
  through a real `idf.py build` (the drivers/PSRAM commits before this one
  were; this partition-table change and the debug log itself have not).
