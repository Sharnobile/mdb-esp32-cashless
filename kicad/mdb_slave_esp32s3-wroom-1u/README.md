# MDB ESP32-S3 Cashless Module

Custom PCB adding cashless payment and telemetry to vending machines via the **MDB (Multi-Drop Bus)** protocol. Built around an **ESP32-S3-WROOM-1U** module with external antenna. Designed in KiCad 10.

Target platform: any vending machine equipped with an MDB bus. Backend (Supabase + MQTT + Nuxt, Dockerized) is out of scope for this repo.

Base reference: [lucienkerl/mdb-esp32-cashless](https://github.com/lucienkerl/mdb-esp32-cashless).

## Status

- Schematic: **complete, ERC-clean** (0 errors, 0 warnings)
- PCB layout: **complete, fully routed** — 4-layer board, 123.2 × 38.5 mm
- Revision: **1.2**
- Fabrication-ready: Gerbers, drill files, BOM, and CPL (pick-and-place) generated for JLCPCB, PCBWay, Elecrow, FusionPCB, and a generic fab profile

## Overview

The board sits between the vending machine's MDB bus and a cashless payment terminal / telemetry stack. It reads and drives the machine's MDB peripherals, exposes auxiliary sensor and actuator interfaces (1-Wire, I2C, relays, custom digital inputs), and connects to WiFi for backend communication.

Key design decisions:

- **ESP32-S3-WROOM-1U-N16R2** module (16MB flash / 2MB PSRAM) with external u.FL antenna, chosen over a bare ESP32-S3 die because vending machine enclosures are often metal and block internal WiFi.
- **4-layer PCB**, for a dedicated ground/power plane structure and better EMI control around the switching regulator and MDB interface.
- All field connectors placed at the board edge for easy wiring and to fit inside a 3D-printed enclosure.
- Physical separation between the MDB (isolated, high-voltage) side and the logic side, matching the optocoupler isolation barrier in the schematic.

## Functional blocks

**MCU — U1**
ESP32-S3-WROOM-1U-N16R2, with EN/BOOT reset circuit (buttons B1/B2, pull-ups R1/R2/R10, decoupling C1–C3). Onboard WS2812B-compatible RGB status LED (LED1, driven by GPIO21).

**Power**
- F2: PTC resettable fuse on the incoming MDB-side supply
- U8: AP63203QWU-7 buck converter, input 3.8V–32V, output 3.3V
- C6 (10µF input), C7 (100nF bootstrap), C8/C9 (2×22µF output), L1 (3.3µH inductor)
- Switching loop (U8–L1–output) kept as compact as possible — primary EMI concern

**USB-C — USBC1**
USB 2.0 receptacle for programming/debug, with D6 Schottky diode against VBUS backfeed and R21/R22 CC pull-downs.

**MDB interface — H1**
2×3 connector. Galvanically isolated via U5/U6 (TLP785 optocouplers) on TX (GPIO4) and RX (GPIO5), with D2/D4 and associated pull-up/series resistors.

**Relay outputs — P7, P8**
Two independent outputs, each driven by an MMBT3904 transistor with a Schottky flyback diode:
- P8: Relay #1, driven by Q2 (GPIO1)
- P7: Relay #2, driven by Q3 (GPIO2)

**1-Wire buses — P4, P5, P6**
Two 1-Wire interfaces plus a spare/parallel header, each with a pull-up resistor:
- P4: bus #1 (GPIO15)
- P5: bus #2 (GPIO16)
- P6: spare header on bus #1 (GPIO15)

**Custom digital inputs — P1, P2, P3**
Three screw-terminal inputs with pull-up resistors: P1 (GPIO6), P2 (GPIO17), P3 (GPIO18).

**I2C — J3**
JST XH 1×4 connector with pull-ups, SCL on GPIO11, SDA on GPIO10.

**Debug / programming**
- J1: UART debug header (1×6) — EN, TXD, RXD, IO0, GND, +3V3
- J2: JTAG header (1×6) — MTMS, MTDI, MTDO, MTCk, GND, +3V3

**Other**
- TH1: NTC thermistor input (GPIO7)
- BUZZER1: buzzer, driven by GPIO12 through Q1
- H2–H5: mounting holes
- GPIO3: reserved for firmware-based PCB/board detection

## Connectors summary

| Ref | Function | Type |
|---|---|---|
| USBC1 | USB-C (program/debug) | USB2.0 16P receptacle |
| J1 | UART debug | 1×6 pin header |
| J2 | JTAG | 1×6 pin header |
| J3 | I2C | 1×4 JST XH |
| P1, P2, P3 | Custom digital inputs (×3) | 3-pin screw terminal, 5.08mm |
| P4, P5, P6 | 1-Wire buses (bus #1, bus #2, bus #1 spare) | 3-pin screw terminal, 5.08mm |
| P7 | Relay #2 output | 2-pin screw terminal, 5.08mm |
| P8 | Relay #1 output | 2-pin screw terminal, 5.08mm |
| H1 | MDB bus | 2×3 connector, isolated |

## Repository structure

```
mdb_slave_esp32s3-wroom-1u/
├── mdb_slave_esp32s3-wroom-1u.kicad_pro   KiCad project
├── mdb_slave_esp32s3-wroom-1u.kicad_sch   Schematic
├── mdb_slave_esp32s3-wroom-1u.kicad_pcb   PCB layout (routed, rev 1.2)
├── gerber_to_order/                       Fabrication Gerbers per vendor (generated locally, not versioned)
└── production/                            BOM, CPL, netlist, fabrication zip (generated locally, not versioned)
```

Only the `.kicad_pro` / `.kicad_sch` / `.kicad_pcb` files and this README are version-controlled — see `.gitignore`.

## Tools

- KiCad 10.0.4
- JLCPCB / PCBWay for fabrication, assembly, and component sourcing

## License

*(add license — e.g. CERN-OHL-S, MIT for firmware, etc.)*
