# Design: 2×11 Extension Header for mdb-slave-esp32s3 (WiFi board)

**Date:** 2026-06-08
**Board:** `kicad/mdb-slave-esp32s3/` (WiFi-only ESP32-S3 slave)
**Goal:** Add a 0.1″ pin header that breaks out the most important ESP32-S3
signals so extension/daughter modules can be plugged on top later.

## Background

An earlier revision of this board already carried a full breakout header.
Its history (per git):

- oldest: `Conn_02x09_Odd_Even` (2×9)
- long-lived stable form: **`Conn_02x11_Odd_Even` (2×11, 22 pins)**
- briefly trimmed to `Conn_02x08_Odd_Even` (2×8)
- finally removed and replaced by two small JST connectors (I²C + DEX),
  commit `24558e7` "Add JST Connectors for I²C and Pulse Interfaces (#46)".

The user wants the **exact arrangement from back then** reproduced. The
reference is the complete **2×11** form, taken from commit **`c5da6d6`**
(reference `J3` in that revision, footprint
`PinHeader_2x11_P2.54mm_Vertical` at `(172.473332, 91.22)`).

## Decision

Reproduce the 2×11 header with the **exact historical pin→net mapping**,
keep all current parts (JST `J3`/`J8`, button `SW1`, …) untouched, and make
room by **enlarging the board** rather than removing anything.

## Component

- Symbol: `Connector_Generic:Conn_02x11_Odd_Even`
- Footprint: `Connector_PinHeader_2.54mm:PinHeader_2x11_P2.54mm_Vertical`
- Reference: **`J4`** (`J3` is now the I²C JST, so the historical `J3`
  number is taken → next free designator).

## Exact pin → net mapping (from `c5da6d6`)

Odd pins = left column, even pins = right column (Odd_Even numbering).

| Pin | Net      | Pin | Net    |
|-----|----------|-----|--------|
| 1   | `u0txd`  | 2   | `GND`  |
| 3   | `u0rxd`  | 4   | `io8`  |
| 5   | `io1`    | 6   | `io9`  |
| 7   | `io2`    | 8   | `io10` |
| 9   | `io4`    | 10  | `io11` |
| 11  | `io5`    | 12  | `io12` |
| 13  | `io6`    | 14  | `io13` |
| 15  | `io7`    | 16  | `io14` |
| 17  | `io17`   | 18  | `+3V3` |
| 19  | `io18`   | 20  | `GND`  |
| 21  | `io21`   | 22  | `vin`  |

Breaks out: UART0 (`u0txd`/`u0rxd`), all 16 GPIO nets
(`io1,2,4,5,6,7,8,9,10,11,12,13,14,17,18,21`), `+3V3`, `vin`, 3× `GND`.
All of these nets still exist in the current schematic, so the header is a
true electrical breakout of live nets (incl. the MDB-shared `io4`/`io5`).

## Board change

- Extend the **left** Edge.Cuts edge by **9.5 mm**: X `168.50` → `159.00`.
  Board becomes **48.5 × 40 mm** (was 39 × 40 mm). (Planned 8 mm; widened to
  9.5 mm so the header clears the `H1` mounting-hole courtyard — at 8 mm the
  courtyards grazed by 0.17 mm, the only DRC error the header would add.)
- Place the header **vertically** (rotation 0, footprint origin = pin 1) in
  the new left strip: pin-1 at `(161.00, 91.22)`, columns x = 161.00 / 163.54,
  rows y = 91.22 … 116.62. Clearances: 1.15 mm copper-to-edge, 0.83 mm
  courtyard-to-`H1`, 5.03 mm pad-to-`H1`-centre.
- Chosen left edge because the header sat there historically and the
  ESP32 GPIO nets land cleanly on that side. Keep clear of the 2.4 GHz
  chip antenna `AE1` (top-left, x ≈ 181) — ≥ 15 mm horizontal clearance.
- Mounting hole `H1` (old left edge) becomes interior; left in place.
- `J3`, `J8`, `SW1` and everything else are **not moved or removed**.

## Wiring & routing

- Each pad connects to its existing net via a net label / power symbol
  (matching the historical labels: `io*`, `u0rxd`, `u0txd`, `vin`,
  `+3V3`/`VDD3P3`, `GND`).
- Route all 22 connections best-effort so the ratsnest is fully closed.
  Any connection that cannot be routed cleanly in the dense area is
  reported back rather than left silently broken.
- Run DRC after placement + routing; report violations.

## Out of scope / notes

- No change to firmware, MQTT, DB, or any non-KiCad code.
- This is a **new board revision**; field devices keep their existing
  boards. Backward compatibility is therefore not affected (hardware add
  only, no net renames on existing connectors).
- The two JST connectors stay; the 2×11 is a superset breakout added
  alongside them, not a replacement.

## Acceptance

1. Schematic contains `J4` (Conn_02x11_Odd_Even) with the exact mapping above.
2. PCB outline is 48.5 × 40 mm; `J4` footprint placed in the new left strip,
   not overlapping any existing courtyard.
3. All 22 pads net-assigned per the table; routing pending (see build notes).
4. DRC adds no new violations vs. baseline.
5. `J3`/`J8`/`SW1` and all other footprints unchanged in position.

## Build notes (2026-06-08)

- **Pinout reproduced exactly** from `c5da6d6` (table above); verified
  pin-by-pin on both schematic and PCB, and schematic↔PCB net-consistent for
  all 22 pins.
- **MCP KiCad backend writes a non-standard PCB net format** (`(net "name")`
  with no net number and no net table) and rewrites the `.kicad_sch` as a
  single line — both unsuitable to commit. Workaround: the substantive work
  was done through the MCP tools (component add, net-label snap,
  `sync_schematic_to_board`, DRC), but the final files were produced by
  **surgical edits on the pristine originals** so the change set is a clean,
  minimal, valid-KiCad diff (PCB: J4 footprint block + outline; schematic:
  +1009 lines, 0 deletions). MCP DRC was used read-only for validation.
- **DRC:** baseline (no J4, project rules) = 2 errors + 37 warnings, all
  pre-existing (`annular_width` near the antenna, `hole_clearance` top edge,
  37 `lib_footprint_mismatch`). With J4 = **identical** → the header adds
  **zero** new DRC errors. Extending the edge also removed 4 pre-existing
  `copper_edge_clearance` issues that the old 168.5 edge had.
- **Routing is NOT done.** J4 pads are net-assigned (ratsnest connected) but
  no copper traces were drawn — the MCP router writes via the broken PCB
  serializer, and hand-routing 22 nets on this dense 2-layer board is out of
  scope here. Route `J4` in KiCad (autorouter or manual). No `GND` pour was
  extended into the new strip (kept clear of the 2.4 GHz antenna `AE1`), so
  the two `GND` pins also need routing.
- Reference `J4` chosen because the historical `J3` designator is now the
  I²C JST. `J3`/`J8`/`SW1`/`H1` and all other parts are unchanged.
