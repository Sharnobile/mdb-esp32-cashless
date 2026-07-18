# MDB32 ESP32-S3 Cashless Module

Custom PCB adding cashless payment and telemetry to vending machines via the **MDB (Multi-Drop Bus)** protocol. Built around an **ESP32-S3-WROOM-1U** module with external antenna. Designed in KiCad 10.

Target platform: any vending machine equipped with an MDB bus. Backend (Supabase + MQTT + Nuxt, Dockerized) is out of scope for this repo.

Base reference: [lucienkerl/mdb-esp32-cashless](https://github.com/lucienkerl/mdb-esp32-cashless).

## Status

- Schematic: **complete, ERC-clean** (0 errors, 0 warnings)
- PCB layout: in progress (component placement / routing)
- Revision: 1.0

## Overview

The board sits between the vending machine's MDB bus and a cashless payment terminal / telemetry stack. It reads and drives the machine's MDB peripherals, exposes auxiliary sensor and actuator interfaces (1-Wire, I2C, relays, pulse, generic I/O), and connects to WiFi for backend communication.

Key design decisions:

- **ESP32-S3-WROOM-1U-N16R2** module (16MB flash / 2MB PSRAM) with external u.FL antenna, chosen over a bare ESP32-S3 die because vending machine enclosures are often metal and block internal WiFi.
- **4-layer PCB**, for a dedicated ground/power plane structure and better EMI control around the switching regulator and MDB interface.
- All field connectors placed at the board edge for easy wiring and to fit inside a 3D-printed enclosure.
- Physical separation between the MDB (isolated, high-voltage) side and the logic side, matching the optocoupler isolation barrier in the schematic.

## Functional blocks

**MCU — U1**
ESP32-S3-WROOM-1U-N16R2, with reset/boot circuit (SW1, pull-ups R1/R2, decoupling C1). Onboard WS2812B RGB status LED (D2).

**Power**
- F1: PTC resettable fuse (1.1A / 33V) on the incoming MDB-side supply
- U2: AP63203QWU-7 buck converter, output 3.3V
- C3 (10µF input), C4 (bootstrap), C5/C6 (2×22µF output), L1 (3.3µH inductor)
- Switching loop (U2–L1–output) kept as compact as possible — primary EMI concern

**USB-C — J1**
USB 2.0 receptacle for programming/debug, with D1 Schottky diode against VBUS backfeed and R3/R4 CC pull-downs.

**MDB interface — J12**
2×3 Molex-style connector. Galvanically isolated via U3/U4 (TLP785 optocouplers) on TX and RX, with D5/D6 and associated pull-up/series resistors.

**Relay outputs — J2, J3**
Two independent outputs, each driven by an MMBT3904 transistor (Q1/Q2) with a Schottky flyback diode (D3/D4) and base resistor.

**Pulse output — J8**
MMBT3904 (Q3) driver stage for a single pulse-type output.

**1-Wire buses — J4, J5, J6**
Two (plus a spare header) 1-Wire interfaces with pull-up resistors, for temperature or other 1-Wire sensors.

**I2C — J10**
JST PH 1×4 connector with pull-ups, for external I2C peripherals.

**Generic digital inputs — J11, J13, J14**
Three screw-terminal inputs with pull-up resistors.

**Debug / programming**
- J9: UART header (4-pin)
- J7: JTAG header (6-pin)

**Other**
- TH1: NTC thermistor input
- BZ1: buzzer with series resistor
- H1–H5: mounting holes

## Connectors summary

| Ref | Function | Type |
|---|---|---|
| J1 | USB-C (program/debug) | USB2.0 16P receptacle |
| J2, J3 | Relay outputs (×2) | 2-pin screw terminal |
| J4, J5, J6 | 1-Wire buses | 3-pin screw terminal |
| J7 | JTAG | 1×6 pin header |
| J8 | Pulse output | 1×3 pin header (JST) |
| J9 | UART debug | 1×4 pin header |
| J10 | I2C | 1×4 JST PH |
| J11, J13, J14 | Generic digital input (×3) | 3-pin screw terminal |
| J12 | MDB bus | 2×3 connector, isolated |

## Repository structure

```
/schematic      KiCad schematic (.kicad_sch)
/pcb            KiCad PCB layout (.kicad_pcb) — in progress
/gerbers        Fabrication output (once layout is finalized)
/bom            Bill of materials (LCSC references)
```

*(adjust to match actual repo layout)*

## Tools

- KiCad 10.0.4
- JLCPCB / PCBWay for fabrication, assembly, and component sourcing

## License

*(add license — e.g. CERN-OHL-S, MIT for firmware, etc.)*