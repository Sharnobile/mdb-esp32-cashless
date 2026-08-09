# MDB ESP32-S3 Cashless Module

Custom PCB adding cashless payment and telemetry to vending machines via the **MDB (Multi-Drop Bus)** protocol. Built around an **ESP32-S3-WROOM-1U** module with external antenna. Designed in KiCad 10.

Target platform: any vending machine equipped with an MDB bus. Backend (Supabase + MQTT + Nuxt, Dockerized) is out of scope for this repo.

Base reference: [lucienkerl/mdb-esp32-cashless](https://github.com/lucienkerl/mdb-esp32-cashless).

## Status

- Schematic: complete — ERC has 4 minor housekeeping items left (floating power symbols / an
  unconnected test pad, no real connectivity impact)
- PCB layout: routed, 4-layer board, 149.8 × 38.5 mm — **PCB/schematic re-sync pending**
  (run *Update PCB from Schematic* before generating final fabrication files; a handful of
  references were renumbered when the rev1.3 relay driver stage was added and the board hasn't
  been re-synced yet)
- Revision: **1.3**
- Gerbers in `gerber_to_order/` (JLCPCB, PCBWay) reflect the pre-re-sync board — regenerate
  after the PCB update above before ordering

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

**MDB interface — H7**
2×3 connector. Galvanically isolated via U2/U3 (TLP785 optocouplers, DIP-4) on TX (GPIO4) and RX (GPIO5), with D2/D3 and associated pull-up/series resistors. F1 is the PTC resettable fuse on the incoming MDB-side supply.

**Relay outputs — P10, P11** *(rev1.3)*
Two 15A-class SPDT relays (K2, K3 — SRD-03VDC-SL-C, 3V coil on the +3V3 rail), each output exposed as a 3-pin COM/NO/NC screw terminal. Each coil is driven low-side by an MMBT3904 transistor (Q2/Q3) with a 1N4148WS flyback diode (D4/D5), itself switched through a TLP785 optocoupler (U5/U4, SMD-4) for GPIO isolation:
- P11: Relay #1 — K2 / Q2 / U5, driven from GPIO1
- P10: Relay #2 — K3 / Q3 / U4, driven from GPIO2

⚠️ Known open point: with the current TLP785 pull-up/pull-down arrangement, drive logic is inverted (GPIO low, or floating at boot, = relay energized; GPIO high = relay de-energized). Confirm this matches firmware expectations, or flip the pull-up/pull-down before ordering if a fail-safe de-energized default is required.

**1-Wire buses — P7, P8, P9**
Two 1-Wire interfaces plus a spare/parallel header, each with a pull-up resistor:
- P7: bus #1 (GPIO15)
- P8: bus #2 (GPIO16)
- P9: spare header on bus #1 (GPIO15)

**Custom digital inputs — P4, P5, P6**
Three screw-terminal inputs with pull-up resistors: P4 (GPIO6), P5 (GPIO17), P6 (GPIO18).

**I2C — J3**
JST XH 1×4 connector with pull-ups, SCL on GPIO11, SDA on GPIO10.

**Debug / programming**
- J1: UART debug header (1×6) — EN, TXD, RXD, IO0, GND, +3V3
- J2: JTAG header (1×6) — MTMS, MTDI, MTDO, MTCk, GND, +3V3

**Other**
- TH1: NTC thermistor input (GPIO7)
- BUZZER1: buzzer, driven by GPIO12 through Q1
- H1–H4: mounting holes
- H8–H12: test/probe pads (added in rev1.3, e.g. H10 taps the WS2812B LED1 data-out, H11/H12 the buzzer driver)
- GPIO3: reserved for firmware-based PCB/board detection

## Connectors summary

| Ref | Function | Type |
|---|---|---|
| USBC1 | USB-C (program/debug) | USB2.0 16P receptacle |
| J1 | UART debug | 1×6 pin header |
| J2 | JTAG | 1×6 pin header |
| J3 | I2C | 1×4 JST XH |
| P4, P5, P6 | Custom digital inputs (×3) | 3-pin screw terminal, 5.08mm |
| P7, P8, P9 | 1-Wire buses (bus #1, bus #2, bus #1 spare) | 3-pin screw terminal, 5.08mm |
| P10 | Relay #2 output (COM/NO/NC) | 3-pin screw terminal, 5.08mm |
| P11 | Relay #1 output (COM/NO/NC) | 3-pin screw terminal, 5.08mm |
| H7 | MDB bus | 2×3 connector, isolated |

## Repository structure

```
mdb_slave_esp32s3-wroom-1u/
├── mdb_slave_esp32s3-wroom-1u.kicad_pro   KiCad project
├── mdb_slave_esp32s3-wroom-1u.kicad_sch   Schematic
├── mdb_slave_esp32s3-wroom-1u.kicad_pcb   PCB layout (routed, rev 1.3)
├── gerber_to_order/                       Fabrication Gerbers per vendor (JLCPCB, PCBWay) — versioned
└── production/                            BOM, CPL, netlist (generated locally, not versioned)
```

The `.kicad_pro` / `.kicad_sch` / `.kicad_pcb` files, this README, and `gerber_to_order/` are
version-controlled — see `.gitignore`.

## Tools

- KiCad 10.0.4
- JLCPCB / PCBWay for fabrication, assembly, and component sourcing

## License

*(add license — e.g. CERN-OHL-S, MIT for firmware, etc.)*
