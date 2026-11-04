"""WROOM-1U MDB slave enclosure - FreeCAD 1.x script (Part workbench). Units: mm.

Run from this folder:
  "C:\\Program Files\\FreeCAD 1.1\\bin\\freecadcmd.exe" build_case.py

Reads the board STEP from STEP_PATH (KiCad export: board centred on the origin,
bottom face at z=0) and places the board at PCB_Z inside the base.

Writes base.step/.stl and lid.step/.stl next to this script. The lid STL is flipped
so its outer face lies on the print bed. Geometry checks (solid validity, overlap
between parts, collisions with the board) are printed to stdout.
"""
import json
import math
import os

import FreeCAD as App
import Import
import MeshPart
import Part

V = App.Vector
try:
    HERE = os.path.dirname(os.path.abspath(__file__))
except NameError:
    HERE = os.getcwd()
STEP_PATH = os.path.join(HERE, "..", "pcb_wroom-u1.step")      # board model, shared by both variants

# ---------------------------------------------------------------- variant
LID_SCREWS = True                       # True: clips + optional M2.5 screws, False: clips only
CLIP_X = (-64.5, 47.0)                  # clip positions on north and south walls

# ---------------------------------------------------------------- parameters
WALL = 2.0            # wall thickness
FLOOR = 2.0           # floor thickness
LID = 2.0             # lid thickness
GAP = 0.6             # board to wall clearance
STANDOFF = 5.0        # standoff height (through-hole leads reach -2.9 mm)
PCB_Z = FLOOR + STANDOFF
PCB_T = 1.52
TOP_CLEAR = 1.4       # clearance above the tallest part (relays, 17.6 mm)
INSERT_BORE = 3.3     # M2.5 x 5 x OD3.5 heat insert, validated on a test coupon
INSERT_DEPTH = 5.6
LID_SCREW = 2.9       # M2.5 clearance hole in the lid
FIT = 0.25            # lid lip to wall clearance
TERM_W = 3.2          # terminal wire window width. Poles sit 5.08 mm apart: 3.2 leaves 1.88 mm
                      # webs, four lines of a 0.4 mm nozzle (4.0 left 1.08 mm, which printed
                      # as thin wavy strands that broke; 4.8 left 0.28 mm and dropped out)
TERM_HOLE = 4.0       # lid screwdriver hole diameter (lid prints flat, its 1.08 mm webs are fine)

BOARD_X, BOARD_Y = 74.91, 19.25
PCB_HOLES = [(-71.414936, -15.75), (-71.414936, 15.75), (41.4757, -15.7906), (41.4857, 14.7496)]

X0, X1 = -75.6, BOARD_X + GAP          # inner cavity (USB-C sticks out to -75.42)
Y0, Y1 = -(BOARD_Y + 0.5), BOARD_Y + 0.5
H = PCB_Z + 17.6 + TOP_CLEAR           # base height (top of the walls)


# WJ500V terminal blocks: pole centres (board frame). side = wall the wire goes through.
def poles(first, other, side, axis="x"):
    return [((first + i * 5.08, other) if axis == "x" else (other, first + i * 5.08), side) for i in range(3)]


TERMINALS = []
for xf in (-57.79, -42.23, -26.68, -11.14):              # P4 P5 P6 P3 (south)
    TERMINALS += poles(xf, -14.30, "S")
for xf in (9.09, 24.63):                                  # P2 P1 (north)
    TERMINALS += poles(xf, 14.30, "N")
for yf in (-13.75, 2.74):                                 # P8 P9 (east)
    TERMINALS += poles(yf, 70.06, "E", axis="y")
WIRE_Z = (3.08 - 0.6, 9.32 + 0.6)                         # wire entry height, board frame

MDB = (10.04, 24.04, -1.9, 12.3)                          # x0 x1 z0 z1 (board frame)
USB_C = (0.38, 3.33)                                      # centre y, z (board frame) of the receptacle
# mouth (z 1.75..4.91 at the front face). 2.78 was the bbox centre, pulled down by the legs
# below the board: the printed window sat 0.55 mm low.
# The receptacle face is 0.18 mm inside the wall and a plug overmould starts >= 6 mm behind the
# shell tip, so only the 8.25 x 2.4 plug shell passes the 2 mm wall: the window clears the
# 8.94 x 3.26 receptacle by ~0.5 mm all round (12.8 x 7.2 looked oversized on the print).
USB_W, USB_H, USB_CHAMFER = 10.0, 4.6, 1.0                # window, 45 degree corner chamfers
LEDS = [(-47.76, -3.43)]                                  # WS2812B-2121 "LED D0"
ANTENNA_X = -46.0                                         # U.FL cable slot, north wall
UART_X, UART_W = -33.15, 8.0                              # J1 UART debug cable slot, north wall
# SMA bulkhead jack (1/4-36 UNS thread, 8 mm hex, panel cutout 6.5 mm, max panel 4.4 mm) for an
# external antenna on a U.FL pigtail. North wall near the USB-C end, above the ESP32 module so
# the jack body and cable clear it, clear of the clip window. SMA = None leaves the wall closed.
SMA = (-53.0, 18.0)                                       # x, z of the hole centre
SMA_D = 6.6                                               # printed holes come out ~0.1 mm small
SMA_CAP = 0.3                                             # teardrop cut-off above the circle top
VENT_D = 3.4                                              # low wall vents: 45 deg diamonds, 5 mm pitch
LID_HEX = (3.0, 1.2)                                      # lid vents: hexagon across flats, web
LID_VENT_ZONES = [(45.2, 62.8, -7.5, 7.5),                # relays (x0 x1 y0 y1)
                  (-24.8, -0.8, -7.5, 7.5)]               # centre area
BUMP = 0.8                                                # clip catch height (0.6 held too loosely)
# Lid markings, engraved MARK_DEPTH into the outer face. The lid prints face down, so a
# filament change at z = MARK_DEPTH gives two-tone marks on a single-extruder printer.
# Per terminal block: group name on the wall side, one code per pole on the board side
# (+ = 3V3, G = GND, S = signal), a NC/COM/NO switch symbol for the relays.
# Pole order follows TERMINALS: south and east blocks list pin 1 first, north blocks pin 3.
MARKINGS = True
MARK_DEPTH = 0.6                                          # 3 layers of 0.2 mm
MARK_FONTS = ["C:/Windows/Fonts/arialbd.ttf",             # first font file found is used
              "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
              "/Library/Fonts/Arial Bold.ttf"]
MARK_GROUP_H, MARK_POLE_H = 2.8, 2.6                      # cap heights
MARK_BOLD = 0.12                                          # text outline offset per side: Arial Bold strokes
                                                          # of 0.52-0.56 mm become ~0.8 mm, two 0.4 mm lines,
                                                          # so first layer squish cannot close them
MARK_GAP = 0.7                                            # hole edge to text
MARK_GROUPS = ["1W1", "1W2", "1W1", "IN3",                # P4 P5 P6 P3 (south, P4 and P6 share bus #1)
               "IN2", "IN1",                              # P2 P1 (north)
               "R1", "R2"]                                # P8 P9 (east, relays K2 K3)
MARK_POLES = {"S": "G+S", "N": "S+G"}                     # relays get the switch symbol instead
MARK_LEGEND = ("+ = 3V3", 22.0, 0.0, 3.0)                 # text, x, y, cap height: free lid area
SCREW_BOSSES = ([(x, s * (Y1 + WALL + 2.2)) for x in (-73.0, 73.0) for s in (-1, 1)]
                if LID_SCREWS else [])


def box(x0, x1, y0, y1, z0, z1):
    return Part.makeBox(x1 - x0, y1 - y0, z1 - z0, V(x0, y0, z0))


def _fillet(b, r, axis):
    edges = [e for e in b.Edges if abs(getattr(e.Vertexes[0].Point - e.Vertexes[1].Point, axis)) > 1e-6]
    return b.makeFillet(r, edges)


def rbox(x0, x1, y0, y1, z0, z1, r):
    """Box with rounded vertical edges."""
    r = min(r, (x1 - x0) / 2 - 0.01, (y1 - y0) / 2 - 0.01)
    return _fillet(box(x0, x1, y0, y1, z0, z1), r, "z")


def cyl(x, y, r, z0, z1):
    return Part.makeCylinder(r, z1 - z0, V(x, y, z0))


def wall_window(side, a0, a1, z0, z1, r=0.8):
    """Through-hole in a wall. a = x (north/south walls) or y (east/west walls)."""
    r = min(r, (a1 - a0) / 2 - 0.01, (z1 - z0) / 2 - 0.01)
    if side == "S":
        return _fillet(box(a0, a1, Y0 - WALL - 1, Y0 + 1, z0, z1), r, "y")
    if side == "N":
        return _fillet(box(a0, a1, Y1 - 1, Y1 + WALL + 1, z0, z1), r, "y")
    if side == "E":
        return _fillet(box(X1 - 1, X1 + WALL + 1, a0, a1, z0, z1), r, "x")
    return _fillet(box(X0 - WALL - 1, X0 + 1, a0, a1, z0, z1), r, "x")


def wall_prism(side, pts):
    """Through-hole in a wall with a polygon profile, pts = [(a, z), ...] as in wall_window."""
    if side in "NS":
        y = (Y0 - WALL - 1) if side == "S" else (Y1 - 1)
        poly = [V(a, y, z) for a, z in pts]
        d = V(0, WALL + 2, 0)
    else:
        x = (X0 - WALL - 1) if side == "W" else (X1 - 1)
        poly = [V(x, a, z) for a, z in pts]
        d = V(WALL + 2, 0, 0)
    return Part.Face(Part.makePolygon(poly + poly[:1])).extrude(d)


def arch_window(side, a0, a1, z0, z1):
    """Window with a semicircular top ending at z1: fits a round cable, short arch bridge."""
    r = (a1 - a0) / 2
    zc = z1 - r
    if side in "NS":
        y = (Y0 - WALL - 1) if side == "S" else (Y1 - 1)
        return box(a0, a1, y, y + WALL + 2, z0, zc).fuse(
            Part.makeCylinder(r, WALL + 2, V(a0 + r, y, zc), V(0, 1, 0)))
    x = (X0 - WALL - 1) if side == "W" else (X1 - 1)
    return box(x, x + WALL + 2, a0, a1, z0, zc).fuse(
        Part.makeCylinder(r, WALL + 2, V(x, a0 + r, zc), V(1, 0, 0)))


def diamond_window(side, ac, zc, d):
    """Square turned 45 degrees, d across corners: all four sides print without support."""
    return wall_prism(side, [(ac, zc - d / 2), (ac + d / 2, zc), (ac, zc + d / 2), (ac - d / 2, zc)])


def hex_field(x0, x1, y0, y1, af, web):
    """Honeycomb of hexagonal holes through the lid, centred in the x0..x1 / y0..y1 zone.
    af = across flats; holes in a row are `web` apart, odd rows are shifted half a pitch."""
    p, r = af + web, af / math.sqrt(3)
    dy = p * math.sqrt(3) / 2
    nx, ny = int((x1 - x0 - af) // p) + 1, int((y1 - y0 - 2 * r) // dy) + 1
    ox, oy = (x0 + x1 - (nx - 1) * p) / 2, (y0 + y1 - (ny - 1) * dy) / 2
    holes = []
    for j in range(ny):
        for i in range(nx - j % 2):
            cx, cy = ox + (i + 0.5 * (j % 2)) * p, oy + j * dy
            pts = [V(cx + r * math.cos(math.radians(90 + 60 * k)), cy + r * math.sin(math.radians(90 + 60 * k)), H - 1)
                   for k in range(7)]
            holes.append(Part.Face(Part.makePolygon(pts)).extrude(V(0, 0, LID + 2)))
    return holes


def chamfered_window(side, a0, a1, z0, z1, c):
    """Window with 45 degree chamfered corners (c = leg length): the top bridge shrinks by 2c."""
    return wall_prism(side, [(a0 + c, z0), (a1 - c, z0), (a1, z0 + c), (a1, z1 - c),
                             (a1 - c, z1), (a0 + c, z1), (a0, z1 - c), (a0, z0 + c)])


def insert_cut(shape, x, y, top, diam=INSERT_BORE):
    bore = cyl(x, y, diam / 2, top - INSERT_DEPTH, top + 0.1)
    lead = Part.makeCone(diam / 2, diam / 2 + 0.4, 0.4, V(x, y, top - 0.4))
    return shape.cut(bore.fuse(lead))


def boss_shape(x, y, z0, z1):
    """External screw boss joined to the wall."""
    yw = Y1 + WALL - 0.5 if y > 0 else Y0 - WALL + 0.5
    return cyl(x, y, 3.4, z0, z1).fuse(box(x - 3.4, x + 3.4, min(y, yw), max(y, yw), z0, z1))


# ---------------------------------------------------------------- base
OX0, OX1, OY0, OY1 = X0 - WALL, X1 + WALL, Y0 - WALL, Y1 + WALL
base = rbox(OX0, OX1, OY0, OY1, 0, H, 3.0).cut(rbox(X0, X1, Y0, Y1, FLOOR, H + 1, 1.0))

for x, y in PCB_HOLES:                                    # board standoffs + inserts
    base = insert_cut(base.fuse(cyl(x, y, 3.2, FLOOR - 0.1, PCB_Z)), x, y, PCB_Z)

for x, y in SCREW_BOSSES:                                 # lid screw bosses + inserts
    base = insert_cut(base.fuse(boss_shape(x, y, 0, H)), x, y, H)

# Mounting ears (short ends): solid plate, 10 x 4.5 slot (M4 screw) + 2 zip-tie slots.
# No zip-tie tunnel: a hollow ear squeezes when the M4 screw is tightened, and the tie
# simply goes down one slot and back up the other.
EAR_T, EAR_L = 4.0, 20.0
for sgn, xw in ((-1, OX0), (1, OX1)):
    xc = xw + sgn * EAR_L / 2
    xa, xb = sorted((xw - sgn * 2, xw + sgn * EAR_L))
    ear = rbox(xa, xb, -16, 16, 0, EAR_T, 3.0)
    ear = ear.cut(box(xc - 2.25, xc + 2.25, -2.75, 2.75, -1, EAR_T + 1)
                  .fuse([cyl(xc, -2.75, 2.25, -1, EAR_T + 1), cyl(xc, 2.75, 2.25, -1, EAR_T + 1)]))
    for y in (-11.0, 11.0):
        ear = ear.cut(box(xc - 4.5, xc + 4.5, y - 1.6, y + 1.6, -1, EAR_T + 1))
    base = base.fuse(ear)

cuts = []
# USB-C: 45 degree corner chamfers instead of fillets, so the top bridge (8 mm) has no
# curved overhang.
cuts.append(chamfered_window("W", USB_C[0] - USB_W / 2, USB_C[0] + USB_W / 2,
                             PCB_Z + USB_C[1] - USB_H / 2, PCB_Z + USB_C[1] + USB_H / 2, USB_CHAMFER))
# MDB Mini-Fit 2x3 (plug + latch): slot open to the wall rim, so there is no 15.6 mm bridge.
# MDB_TAB_Z is the old window top (2 mm above the header); a tab on the lid fills the slot
# from there up.
MDB_TAB_Z = PCB_Z + MDB[3] + 2.0
cuts.append(wall_window("S", MDB[0] - 0.8, MDB[1] + 0.8, PCB_Z + PCB_T + 0.3, H + 3.0, 1.0))
# Terminal block wire entries (one window per pole), round top for the round cable
for (px, py), side in TERMINALS:
    a = px if side in "NS" else py
    cuts.append(arch_window(side, a - TERM_W / 2, a + TERM_W / 2, PCB_Z + WIRE_Z[0], PCB_Z + WIRE_Z[1]))
# Antenna: 3 x 2 mm slot at the top of the north wall, under the lid
cuts.append(box(ANTENNA_X - 1.5, ANTENNA_X + 1.5, Y1 - 1, Y1 + WALL + 1, H - 2.0, H + 1))
# UART debug wires: 8 x 2 mm slot at the top of the north wall, above J1
cuts.append(box(UART_X - UART_W / 2, UART_X + UART_W / 2, Y1 - 1, Y1 + WALL + 1, H - 2.0, H + 1))
# Low ventilation: row of VENT_D diamonds below the board, north and south walls
# (5 mm pitch leaves 1.1 mm webs)
for x in [i * 5.0 for i in range(-14, 15)]:
    if any(abs(x - bx) < 5 for bx, _ in SCREW_BOSSES):
        continue
    for side in "NS":
        cuts.append(diamond_window(side, x, (FLOOR + PCB_Z) / 2, VENT_D))
# SMA jack: round hole with a teardrop top cut off 0.3 mm above the circle, so it prints
# without support (2.1 mm bridge) and the thread still bears all round
if SMA:
    r, (sx, sz) = SMA_D / 2, SMA
    k = r / 2 ** 0.5                                      # 45 degree tangent points at (+-k, k)
    zt = r + SMA_CAP                                      # cut-off height above the centre
    t = r * 2 ** 0.5 - zt                                 # half width of the flat top
    cuts.append(Part.makeCylinder(r, WALL + 2, V(sx, Y1 - 1, sz), V(0, 1, 0)))
    cuts.append(wall_prism("N", [(sx - k, sz + k), (sx + k, sz + k), (sx + t, sz + zt), (sx - t, sz + zt)]))
# Clip windows through the wall: the catch can be pushed in from outside with a screwdriver
CLIP_W, CLIP_Z0, CLIP_Z1 = 8.0, H - 8.0, H - 5.6
for x in CLIP_X:
    for side in "NS":
        cuts.append(wall_window(side, x - CLIP_W / 2 - 0.4, x + CLIP_W / 2 + 0.4, CLIP_Z0, CLIP_Z1, 0.4))
for c in cuts:
    base = base.cut(c)
base = base.removeSplitter()

# ---------------------------------------------------------------- lid
lid = rbox(OX0, OX1, OY0, OY1, H, H + LID, 3.0)
for x, y in SCREW_BOSSES:
    lid = lid.fuse(boss_shape(x, y, H, H + LID))
LIP_D, LIP_T = 2.5, 1.6
lip = rbox(X0 + FIT, X1 - FIT, Y0 + FIT, Y1 - FIT, H - LIP_D, H + 0.01, 1.0).cut(
    rbox(X0 + FIT + LIP_T, X1 - FIT - LIP_T, Y0 + FIT + LIP_T, Y1 - FIT - LIP_T, H - LIP_D - 1, H + 1, 0.5))
lip = lip.cut(box(ANTENNA_X - 2.0, ANTENNA_X + 2.0, Y1 - 3, Y1 + 1, H - LIP_D - 1, H + 1))
lip = lip.cut(box(UART_X - UART_W / 2 - 0.5, UART_X + UART_W / 2 + 0.5, Y1 - 3, Y1 + 1, H - LIP_D - 1, H + 1))
for x in CLIP_X:                                  # lip relief around the clip tabs
    for yw in (Y0, Y1):
        lip = lip.cut(box(x - CLIP_W / 2 - 1.0, x + CLIP_W / 2 + 1.0, yw - 3, yw + 3, H - LIP_D - 1, H + 1))
lid = lid.fuse(lip)
# MDB filler tab: closes the open MDB slot above the plug, FIT clearance to the slot sides
lid = lid.fuse(box(MDB[0] - 0.8 + FIT, MDB[1] + 0.8 - FIT, OY0, Y0 + FIT + 0.01, MDB_TAB_Z, H + 0.01))

# Clips: 8 x 1.2 mm tab, ~8 mm free length, BUMP ramped catch.
CLIP_T = 1.2
for x in CLIP_X:
    for sgn, yw in ((-1, Y0), (1, Y1)):
        y_out = yw - sgn * FIT
        y_in = y_out - sgn * CLIP_T
        tab = box(x - CLIP_W / 2, x + CLIP_W / 2, min(y_in, y_out), max(y_in, y_out), CLIP_Z0 - 0.3, H + 0.01)
        zc, zb = CLIP_Z1 - 0.3, CLIP_Z0 - 0.1
        pts = [V(x - CLIP_W / 2, y_out - sgn * 0.01, zb), V(x - CLIP_W / 2, y_out + sgn * BUMP, zc),
               V(x - CLIP_W / 2, y_out - sgn * 0.01, zc), V(x - CLIP_W / 2, y_out - sgn * 0.01, zb)]
        tri = Part.Face(Part.makePolygon(pts)).extrude(V(CLIP_W, 0, 0))
        lid = lid.fuse(tab).fuse(tri)

lid_cuts = []
for x, y in SCREW_BOSSES:
    lid_cuts.append(cyl(x, y, LID_SCREW / 2, H - 1, H + LID + 1))
for (px, py), side in TERMINALS:                  # screwdriver access to terminal screws
    lid_cuts.append(cyl(px, py, TERM_HOLE / 2, H - 1, H + LID + 1))
for x, y in LEDS:                                 # LED window
    lid_cuts.append(cyl(x, y, 2.0, H - 1, H + LID + 1))
# High ventilation: honeycomb above the relays and the centre area
for zone in LID_VENT_ZONES:
    lid_cuts += hex_field(*zone, *LID_HEX)


def mark_text(s, h):
    """Engraving tool for a text line: cap height h, centred on the origin, MARK_DEPTH
    below the lid top and 1 mm above it."""
    font = next(f for f in MARK_FONTS if os.path.exists(f))
    ref = Part.Compound([w for c in Part.makeWireString("H", font, 10.0, 0) for w in c]).BoundBox.YLength
    faces = [Part.Face(c, "Part::FaceMakerBullseye") for c in Part.makeWireString(s, font, 10.0 * h / ref, 0) if c]
    if MARK_BOLD:
        # Outlines as polygons (0.01 mm deviation), offset with sharp (intersection) joins:
        # round joins on the font splines leave micro arcs that break the STL mesh, and
        # sharp joins fail on splines.
        def poly(w):
            pts = w.discretize(Deflection=0.01)
            return Part.makePolygon(pts if pts[0].isEqual(pts[-1], 1e-6) else pts + pts[:1])
        faces = [Part.Face([poly(w) for w in f.Wires], "Part::FaceMakerBullseye").makeOffset2D(MARK_BOLD, 2)
                 for f in faces]
    # fuse the letters: offset neighbours may overlap, and overlapping tools leave slivers
    shape = faces[0].fuse(faces[1:]).removeSplitter() if len(faces) > 1 else faces[0]
    b = shape.BoundBox
    shape.translate(V(-b.Center.x, -b.Center.y, H + LID - MARK_DEPTH))
    return shape.extrude(V(0, 0, MARK_DEPTH + 1))


def mark_at(tool, x, y):
    tool = tool.copy()
    tool.translate(V(x, y, 0))
    return tool


def mark_bar(x0, y0, x1, y1, w):
    """Straight engraved stroke of width w between two points."""
    d = V(x1 - x0, y1 - y0, 0)
    n = V(-d.y, d.x, 0).normalize() * (w / 2)
    z = H + LID - MARK_DEPTH
    pts = [V(x0, y0, z) + n, V(x1, y1, z) + n, V(x1, y1, z) - n, V(x0, y0, z) - n]
    return Part.Face(Part.makePolygon(pts + pts[:1])).extrude(V(0, 0, MARK_DEPTH + 1))


def mark_dot(x, y, r):
    return cyl(x, y, r, H + LID - MARK_DEPTH, H + LID + 1)


def relay_symbol(px, ys, w=0.8):
    """Change-over switch beside an east terminal block, poles ys = (NO, COM, NC) from TERMINALS:
    a stub from each hole to its contact, the blade from the COM pivot resting on NC."""
    edge = px - TERM_HOLE / 2 + 0.3                       # stubs start inside the hole
    dot_x, piv_x = px - TERM_HOLE / 2 - 2.0, px - TERM_HOLE / 2 - 4.0
    y_no, y_com, y_nc = ys
    return [mark_bar(dot_x, y_no, edge, y_no, w), mark_dot(dot_x, y_no, 0.75),
            mark_bar(dot_x, y_nc, edge, y_nc, w), mark_dot(dot_x, y_nc, 0.75),
            mark_bar(piv_x, y_com, edge, y_com, w), mark_dot(piv_x, y_com, 0.9),
            mark_bar(piv_x, y_com, dot_x, y_nc, w)]


marks = []
if MARKINGS:
    off_g = TERM_HOLE / 2 + MARK_GAP + MARK_GROUP_H / 2   # hole centre to text centre
    off_p = TERM_HOLE / 2 + MARK_GAP + MARK_POLE_H / 2
    for k, name in enumerate(MARK_GROUPS):
        block = TERMINALS[3 * k:3 * k + 3]
        side = block[0][1]
        (mx, my), _ = block[1]
        label = mark_text(name, MARK_GROUP_H)
        if side == "E":                                   # name on the wall side, symbol inside
            label.rotate(V(0, 0, 0), V(0, 0, 1), 90)      # reads from the east end: too narrow upright
            marks.append(mark_at(label, mx + off_g, my))
            marks += relay_symbol(mx, [p[1] for p, _ in block])
            continue
        s = -1 if side == "S" else 1                      # +1: wall to the north
        marks.append(mark_at(label, mx, my + s * off_g))
        for ((px, py), _), code in zip(block, MARK_POLES[side]):
            marks.append(mark_at(mark_text(code, MARK_POLE_H), px, py - s * off_p))
    if MARK_LEGEND:
        text, lx, ly, lh = MARK_LEGEND
        marks.append(mark_at(mark_text(text, lh), lx, ly))
    mb = Part.Compound(marks).BoundBox                    # keep 0.8 mm of rim outside the marks
    assert OX0 + 0.8 < mb.XMin and mb.XMax < OX1 - 0.8 and OY0 + 0.8 < mb.YMin and mb.YMax < OY1 - 0.8, mb
for c in lid_cuts:
    lid = lid.cut(c)
lid = lid.removeSplitter()
# Marks: engraved into the lid, and the same volume as a separate inlay body
# (lid_marks.stl) for a second filament on a multi-material printer.
lid_marks = None
if marks:
    mark_tool = marks[0].fuse(marks[1:])
    lid_marks = lid.common(mark_tool).removeSplitter()
    lid = lid.cut(mark_tool).removeSplitter()

# ---------------------------------------------------------------- checks
doc = App.newDocument("pcb")
Import.insert(STEP_PATH, doc.Name)
root = [o for o in doc.Objects if o.TypeId == "App::Part" and not o.InList][0]
pcb_solids = []
for o in root.Group:
    if hasattr(o, "Shape") and not o.Shape.isNull():
        for s in o.Shape.Solids:
            s = s.copy()
            s.translate(V(0, 0, PCB_Z))
            pcb_solids.append((o.Label, s))

collisions = []
for name, part in (("base", base), ("lid", lid)):
    for label, s in pcb_solids:
        if not part.BoundBox.intersect(s.BoundBox):
            continue
        v = part.common(s).Volume
        if v > 0.01:
            collisions.append({"part": name, "component": label, "volume_mm3": round(v, 3)})

checks = {}
for name, part in (("base", base), ("lid", lid)):
    b = part.BoundBox
    checks[name] = {"valid": part.isValid(), "solids": len(part.Solids), "volume_mm3": round(part.Volume, 1),
                    "size_mm": [round(b.XLength, 2), round(b.YLength, 2), round(b.ZLength, 2)]}
checks["base_lid_overlap_mm3"] = round(base.common(lid).Volume, 3)
checks["pcb_collisions"] = collisions
checks["base_height_mm"] = round(H, 2)
if SMA:
    # Room behind the wall for the jack: 8 mm hex flange (9.2 mm across corners) + crimp
    # ferrule, 12 mm deep, plus 0.5 mm. The lid lip must not touch it either.
    body = Part.makeCylinder(5.1, 12.0, V(SMA[0], Y1, SMA[1]), V(0, -1, 0))
    checks["sma_body_hits"] = [label for label, s in pcb_solids if body.common(s).Volume > 0.001]
    checks["sma_body_lid_mm3"] = round(body.common(lid).Volume, 3)
    assert not checks["sma_body_hits"] and checks["sma_body_lid_mm3"] == 0, checks
# MDB lid tab vs header top (the 2 mm left above it are for the plug latch, not modelled)
checks["mdb_tab_header_gap_mm"] = round(MDB_TAB_Z - max(
    s.BoundBox.ZMax for _, s in pcb_solids
    if s.BoundBox.XMax > MDB[0] and s.BoundBox.XMin < MDB[1] and s.BoundBox.YMin < Y0 + 5), 2)
assert checks["mdb_tab_header_gap_mm"] > 1.5, checks["mdb_tab_header_gap_mm"]
if SCREW_BOSSES:
    # Clip windows must stay reachable from outside: no screw boss in front of them.
    checks["clip_boss_min_gap_mm"] = round(min(
        abs(cx - bx) - (CLIP_W / 2 + 0.4) - 3.4 for cx in CLIP_X for bx, _ in SCREW_BOSSES), 2)
    assert checks["clip_boss_min_gap_mm"] > 0.5, checks["clip_boss_min_gap_mm"]


# ---------------------------------------------------------------- export
def stl(shape, path):
    m = MeshPart.meshFromShape(Shape=shape, LinearDeflection=0.03, AngularDeflection=0.2)
    m.write(path)
    return bool(m.isSolid() and not m.hasNonManifolds())


base.exportStep(os.path.join(HERE, "base.step"))
lid.exportStep(os.path.join(HERE, "lid.step"))
checks["base"]["stl_ok"] = stl(base, os.path.join(HERE, "base.stl"))
lid_print = lid.copy()
lid_print.rotate(V(0, 0, 0), V(1, 0, 0), 180)     # outer face on the print bed
dz = -lid_print.BoundBox.ZMin
lid_print.translate(V(0, 0, dz))
checks["lid"]["stl_ok"] = stl(lid_print, os.path.join(HERE, "lid.stl"))
if lid_marks:
    # Same transform as lid.stl: imported together, both files keep their relative position.
    marks_print = lid_marks.copy()
    marks_print.rotate(V(0, 0, 0), V(1, 0, 0), 180)
    marks_print.translate(V(0, 0, dz))
    checks["lid_marks"] = {"valid": lid_marks.isValid(), "solids": len(lid_marks.Solids),
                           "volume_mm3": round(lid_marks.Volume, 1),
                           "lid_overlap_mm3": round(lid.common(lid_marks).Volume, 3),
                           "z_range_print_mm": [round(marks_print.BoundBox.ZMin, 2), round(marks_print.BoundBox.ZMax, 2)],
                           "stl_ok": stl(marks_print, os.path.join(HERE, "lid_marks.stl"))}

print(json.dumps(checks, indent=2))
