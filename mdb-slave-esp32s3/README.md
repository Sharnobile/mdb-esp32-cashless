# ESP32 - MDB Cashless Device Implementation
This project aims to implement an MDB (Multi-Drop Bus) cashless device using an ESP32 microcontroller. The goal is to enable the ESP32 to interface with vending machines and other devices that support the MDB protocol, allowing for cashless transactions using modern payment methods such as mobile payments, contactless cards, or online accounts.

![MDB Cashless Device](mdb-slave-esp32s3_pcb_v3.jpg)

## Supported boards — single firmware source

This is now the **only** slave firmware tree. The original PCB and the
newer ESP32-S3-WROOM-1U PCB (`kicad/mdb_slave_esp32s3-wroom-1u/`) share the
same `main/mdb-slave-esp32s3.c`, gated at runtime by `detect_board_variant()`
so WROOM-1U-only peripherals never touch GPIOs that don't exist on the
original board. A previous `mdb-slave-esp32s3-wroom-1u/` directory held a
full duplicate of this project while the new board was being brought up;
it has been folded back into this one.

**Not unified**: flash size / PSRAM / partition table. The WROOM-1U module
is 16MB flash + 2MB Quad-mode PSRAM with a custom `partitions.csv` (adds a
`dbglog` data partition); this tree's checked-in `sdkconfig` still targets
the original board's 4MB flash and the stock `partitions_two_ota_large.csv`
(no `dbglog` partition). That's a real hardware difference, not something
firmware can autodetect — see "Before first flash" below. `debug_log_init()`
fails safe if the `dbglog` partition is missing (logs an error, the feature
just stays inert), so building/flashing this tree unmodified for the
original board is safe; the local debug log simply won't be active on it
yet.

### Automatic board detection (GPIO3 strap)

GPIO8/9 (`PIN_DEX_RX`/`PIN_DEX_TX`) carry DEX/DDCMP telemetry on the
original board; WROOM-1U has no DEX reader hardware, so those GPIOs are
simply free/unused there. `detect_board_variant()` (top of `app_main`)
reads GPIO3 once at boot to tell the boards apart:

- **GPIO3 reads HIGH** (internal pull-up wins, pin left floating) →
  original board → DEX/UART1 init runs, relay/custom-input/1-Wire/GPIO1,2,
  6,15,16,17,18 stay untouched.
- **GPIO3 reads LOW** (external 10kΩ pull-down to GND, fitted on the
  WROOM-1U PCB) → WROOM-1U board → DEX/UART1 init is skipped, relay/
  custom-input/1-Wire drivers run instead.

### Pin mapping — WROOM-1U specific

Per the schematic's own IO legend (unlisted pins match the original
board unchanged):

| GPIO | Function | Firmware define | Status |
|---|---|---|---|
| 1 | Relay 1 (J2) | `PIN_RELAY_1` | driver done — output, MQTT config cmd `0x33` |
| 2 | Relay 2 (J3) | `PIN_RELAY_2` | driver done — output, MQTT config cmd `0x34` |
| 3 | Board-ID strap | `PIN_BOARD_ID` | see board detection above |
| 6 | Custom input 1 (J11) | `PIN_CUSTOM_INPUT1` | driver done — debounced, published on `/input` |
| 8, 9 | unused | `PIN_DEX_RX`/`PIN_DEX_TX` on original | DEX-only on original board, no DEX hardware on WROOM-1U |
| 15 | 1-Wire bus 1 (J4) | `PIN_ONEWIRE_1` | driver done — boot scan + 5min DS18B20 tracking |
| 16 | 1-Wire bus 2 (J5/J6) | `PIN_ONEWIRE_2` | driver done — boot scan + 5min DS18B20 tracking |
| 17 | Custom input 2 (J13) | `PIN_CUSTOM_INPUT2` | driver done — debounced, published on `/input` |
| 18 | Custom input 3 (J14) | `PIN_CUSTOM_INPUT3` | driver done — debounced, published on `/input` |
| 46, 47, 48 | free | — | unused on this PCB revision |

GPIO13 (`PIN_PULSE_1`) was dropped: dead code on both boards (never wired
to a driver) and the pulse circuit has since been desoldered from the
WROOM-1U PCB revision.

WiFi-only board, confirmed no GPS/LTE-M/NB-IoT — `network.c`'s existing
"no modem → WiFi-only boot" path is used as-is, and `modem.c`/
`modem_https.c` stay fully inert via the existing `modem_probe()` fallback.

**Cellular (SIM7080G) board note**: `modem.c`'s pins target the LilyGo
T-SIM7080G-S3 devkit used for bring-up, not the custom
`kicad/mdb-slave-esp32s3-sim7080g` PCB — the two use different, colliding
GPIOs (that PCB's modem UART shares GPIO4/5 with the MDB bus in this
firmware's current pin map). Not plug-and-play yet; see
`kicad/mdb-slave-esp32s3-sim7080g/README.md` for the confirmed pin
mapping and what's needed to reconcile them.

### Board-specific drivers (relay / custom input / 1-Wire)

All gated behind `g_board_is_wroom_1u` so none of this ever runs on the
original board:

- **Relays** (`PIN_RELAY_1`/`PIN_RELAY_2`): plain digital outputs,
  initialised OFF at boot (`relay_init()`). Driven via the existing
  XOR-encrypted MQTT config command path — cmd `0x33` sets relay 1, `0x34`
  sets relay 2. Ignored with a warning log on the original board.
- **Custom inputs** (`PIN_CUSTOM_INPUT1/2/3`): `custom_input_task` polls
  all three every 100ms, debounces each transition over 50ms, and
  publishes `{channel, level, ts, prevHeldSec}` (QoS 1) to
  `/{company_id}/{device_id}/input` on every confirmed level change.
  Device-agnostic — interpreting events (door-open alarms, notification
  routing) is backend/app work.
- **1-Wire buses** (`PIN_ONEWIRE_1`/`PIN_ONEWIRE_2`): RMT-based bus scan
  via `espressif/onewire_bus` + `espressif/ds18b20`
  (`onewire_bus_scan_and_read()`), dispatched by ROM family code. DS18B20
  (family `0x28`) is read at boot; other families are logged as "no
  driver yet". Re-read every 5 minutes.

### Local debug log (relay / custom input / 1-Wire / NTC)

Offline-safe diagnostic buffer, separate from the sales queue
(`sale_queue.c`, unchanged). Implemented in `debug_log.c`/`.h`:

- **Storage**: a dedicated raw flash partition (`dbglog`, ~800KB — see
  `partitions.csv` on WROOM-1U) holding a ring of fixed 16-byte records,
  not NVS — per-key NVS overhead and page-relocation cost stop being
  worth it at this record count. Two small NVS counters track ring
  position across reboots (same role as `sale_queue.c`'s
  `K_HEAD`/`K_TAIL`).
- **What gets logged**: relay commands, every debounced custom-input
  transition, and periodic NTC/DS18B20 readings.
- **NTC thermistor conversion**: TH1 is a Murata NCP18XH103F03RB (10kΩ
  @ 25°C, B25/50 = 3380K). Divider per the schematic (`kicad/mdb-slave-
  esp32s3`, TH1/R15): `+3V3 → R15 (10kΩ) → ADC7 node → TH1 → GND`.
  `ntc_mv_to_celsius()` inverts the divider then applies the
  single-B-constant NTC equation, using ADC curve-fitting calibration
  where supported.
- **Periodic tracking**: a 5-minute `esp_timer` re-reads the NTC (both
  board variants) and, on WROOM-1U only, both 1-Wire buses — each only
  logs when its reading has moved ≥0.5°C since the last logged value.
- **Publishing**: reuses the existing `/mdb-log` MQTT topic with an added
  `"type"` field (`relay`/`input`/`onewire`/`ntc`). A drain task publishes
  the oldest un-acked record once MQTT is connected, mirroring
  `sale_queue.c`'s drain loop.
- **Fails safe if unavailable**: `debug_log_init()` looks up the `dbglog`
  partition by label; if it's not present in the flashed partition table
  (true today for the original board's `sdkconfig`), it logs an error and
  every other `debug_log_*` call becomes a no-op — no crash.

## Before first flash — WROOM-1U

- `sdkconfig` (this tree, as checked in) still targets the **original**
  board: 4MB flash, stock `partitions_two_ota_large.csv`, no PSRAM. For a
  WROOM-1U board, before flashing: run `idf.py menuconfig` → **Serial
  Flasher Config** → flash size **16MB**; **Component config → ESP
  PSRAM** → enable, mode **Quad** (the WROOM-1U-N16R2's `ESP32-S3R2` chip
  is 2MB PSRAM in Quad SPI, not Octal — Octal is only on the R8/R8V/R16V
  variants); **Partition Table** → Custom, filename `partitions.csv`
  (already checked in) to get the `dbglog` partition.
- GPIO3 pull-down (board-ID strap): note pin **3 on the WROOM-1 module**
  is `EN`, not GPIO3 — GPIO3 is pin **15** on the module's own pin table.
  Fit a 10kΩ pull-down from GPIO3 (module pin 15) to GND.
- Relay / custom-input / 1-Wire drivers and the debug log are implemented
  but **not yet exercised on real WROOM-1U hardware** — the PCB bring-up
  was still in progress as of this consolidation. Confirm behavior on a
  real board before relying on them in production.
