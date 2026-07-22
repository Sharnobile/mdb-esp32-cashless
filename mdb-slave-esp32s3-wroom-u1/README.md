# ESP32-S3-WROOM-1U Cashless Firmware (prep branch)

Firmware target for the new custom PCB in `kicad/mdb_slave_esp32s3-wroom-u1/`
(branch `feature/esp32s3-wroom-u1-pcb`). This is a **copy of
[`mdb-slave-esp32s3`](../mdb-slave-esp32s3)**, adapted so the existing MDB /
WiFi / MQTT / provisioning logic runs unchanged on the new board. **Not yet
flashed or tested on real hardware** — the PCB layout is still in progress.

## Status

- Board logic (MDB protocol, WiFi/MQTT, BLE, provisioning, sale queue) is
  identical to `mdb-slave-esp32s3` — no cellular modem on this board, so
  `network.c`'s existing "no modem → WiFi-only boot" path is used as-is.
- Pin assignments below are the authoritative table from the schematic's
  own IO legend (`kicad/mdb_slave_esp32s3-wroom-u1`, sheet notes), not the
  earlier script-extracted guess.

## Pin mapping vs. schematic

Per the schematic's IO legend:

| GPIO | Function | Firmware define | Status |
|---|---|---|---|
| 0 | Boot button | `PIN_BOOT_BTN` | matches, no change |
| 1 | Relay 1 (J2) | — | **new, no driver yet** |
| 2 | Relay 2 (J3) | — | **new, no driver yet** |
| 3 | free | — | |
| 4 | MDB RX | `PIN_MDB_RX` | matches, no change |
| 5 | MDB TX | `PIN_MDB_TX` | matches, no change |
| 6 | Custom input 1 (J11) | — | **new, no driver yet** |
| 7 | Thermistor (TH1) | — | **new, no driver yet (ADC)** |
| 8 | Custom input 2 (J13) | `PIN_DEX_RX` ⚠️ | **conflict — see below** |
| 9 | Custom input 3 (J14) | `PIN_DEX_TX` ⚠️ | **conflict — see below** |
| 10 | I2C SDA (J10) | `PIN_I2C_SDA` | matches, no change |
| 11 | I2C SCL (J10) | `PIN_I2C_SCL` | matches, no change |
| 12 | Buzzer (BZ1) | `PIN_BUZZER_PWR` | matches, no change |
| 13 | Pulse output (J8) | `PIN_PULSE_1` | matches, no change |
| 14, 17, 18 | free | — | |
| 15 | 1-Wire bus 1 (J4) | — | **new, no driver yet** |
| 16 | 1-Wire bus 2 (J5/J6) | — | **new, no driver yet** |
| 21 | Status LED (D2, WS2812) | `PIN_MDB_LED` | matches, no change |
| u0txd/u0rxd | UART debug (J9) | — | ESP-IDF console default, no change |
| 39–42 | JTAG (J7) | — | ESP32-S3 default JTAG pins, no change |
| 35,36,37,38,47,48 | free | — | |

**DEX conflict**: this board has **no DEX/telemetry connector** — GPIO8/9
are wired to two generic screw-terminal inputs (J13, J14) instead. The
copied firmware still calls `uart_set_pin(UART_NUM_1, PIN_DEX_TX,
PIN_DEX_RX, -1, -1)` on those same pins for DEX telemetry
(`mdb-slave-esp32s3-wroom-u1.c`). Nothing reads `custom_input2/3` yet
(no driver exists), so there's no active runtime clash today, but DEX
support must be compiled out (or gated behind a board-variant Kconfig
choice) before anyone builds a digital-input driver on those two pins,
or before the `mdb-master-esp32s3` DEX-emitting test path is used against
this board.

`SIM7080G_*` pin defines and `modem.c`/`modem_https.c` are inherited from
the copy but unused on this WiFi-only board — harmless no-op via the
existing `modem_probe()` fallback, kept for parity rather than stripped out.

## Before first flash

- Run `idf.py menuconfig` → **Serial Flasher Config** → set flash size to
  **16 MB** (this board's module is 16MB flash / 2MB PSRAM vs. the original
  board's 4MB config currently in `sdkconfig`).
- Enable **Component config → ESP PSRAM** for the 2MB PSRAM (mode
  Quad/Octal — confirm against the exact WROOM-1U-N16R2 datasheet page
  before committing to a mode).
- Confirm relay / 1-Wire / digital-input pins against the schematic, add
  the corresponding `PIN_*` defines and driver code before relying on
  those features.
