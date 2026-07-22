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
- Pin assignments below were cross-checked between the schematic's net
  labels and the `PIN_*` defines already in
  [`main/mdb-slave-esp32s3-wroom-u1.c`](main/mdb-slave-esp32s3-wroom-u1.c) —
  **please re-confirm in KiCad before flashing**, this was extracted with a
  script, not verified against the physical board.

## Pin mapping vs. schematic

Confirmed matches (schematic net label = existing firmware define, no code change needed):

| Function | GPIO | Firmware define |
|---|---|---|
| MDB RX | 4 | `PIN_MDB_RX` |
| MDB TX | 5 | `PIN_MDB_TX` |
| DEX RX | 8 | `PIN_DEX_RX` |
| DEX TX | 9 | `PIN_DEX_TX` |
| I2C SDA (J10) | 10 | `PIN_I2C_SDA` |
| I2C SCL (J10) | 11 | `PIN_I2C_SCL` |
| Buzzer (BZ1) | 12 | `PIN_BUZZER_PWR` |
| Pulse output (J8) | 13 | `PIN_PULSE_1` |
| Status LED (D2, WS2812) | 21 | `PIN_MDB_LED` |
| Boot button | 0 | `PIN_BOOT_BTN` |

Not yet in firmware (new hardware on this board, needs driver code once
confirmed — treat as TODO, not implemented):

| Function | Candidate GPIO | Notes |
|---|---|---|
| NTC thermistor (TH1) | 7 | ADC input, divider via R7 |
| Relay outputs (J2, J3) | unresolved | not captured by the label-based net extraction, confirm in KiCad |
| 1-Wire buses (J4, J5, J6) | unresolved | same |
| Digital inputs (J11, J13, J14) | unresolved | same |
| Spare / unlabeled | 1, 2, 6, 15 | seen in net extraction but not tied to a specific connector yet |

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
