"""SolidCraft design for the WROOM-1U enclosure. Units: mm.

Writes a SolidCraft command script (<variant>/case_wroom-u1-<variant>.solidcraft.json)
that builds the same base and lid as <variant>/build_case.py as a parametric timeline:
named parameters, dimensioned sketches and one named feature per step, grouped into
timeline folders. Values come from the parameter section of build_case.py.

  python3 build_solidcraft.py                  # both variants
  python3 build_solidcraft.py clips            # one variant

Then build and save the design with SolidCraft's CLI (0.14 or later):
  solidcraft-cli run clips/case_wroom-u1-clips.solidcraft.json --save clips/case_wroom-u1-clips.solidcraft

Plain Python, no FreeCAD needed.
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MARK = "# ---------------------------------------------------------------- base"


def load_params(variant):
    """Run the parameter section of build_case.py without FreeCAD."""
    path = os.path.join(HERE, variant, "build_case.py")
    src = open(path, encoding="utf-8").read()
    src = src[:src.index(MARK)]
    src = "\n".join(l for l in src.splitlines()
                    if not l.startswith(("import FreeCAD", "import Import", "import MeshPart", "import Part")))
    src = src.replace("V = App.Vector", "V = None")
    ns = {"__file__": path}
    exec(compile(src, path, "exec"), ns)
    return ns


# SolidCraft reserves some names (units such as h, functions such as floor): parameters are
# written in short form here and renamed on output.
RENAME = {"h": "base_h", "floor": "floor_t", "lid": "lid_t"}
NAME_KEYS = {"name", "body_name", "features", "targets", "plane", "command"}


def renamed(v, key=None):
    if key in NAME_KEYS:
        return v
    if isinstance(v, str):
        return re.sub(r"\b[A-Za-z_]\w*\b", lambda m: RENAME.get(m.group(0), m.group(0)), v)
    if isinstance(v, list):
        return [renamed(x) for x in v]
    if isinstance(v, dict):
        return {k: renamed(x, k) for k, x in v.items()}
    return v


class Script:
    def __init__(self):
        self.cmds = []
        self.vals = {}           # parameter values, to draw sketches at the right size
        self.groups = []         # (folder name, [feature names])

    def cmd(self, command, **params):
        self.cmds.append({"command": command, "params": renamed(params)})

    def ev(self, expr):
        return float(eval(str(expr), {"__builtins__": {}}, self.vals))

    def param(self, name, expr, comment="", unit=None):
        """expr: a number (mm unless unit) or an expression over earlier parameters."""
        if isinstance(expr, (int, float)):
            text = "%s %s" % (round(expr, 6), "mm" if unit is None else unit)
            text = text.strip()
            self.vals[name] = float(expr)
        else:
            text = expr
            self.vals[name] = self.ev(expr)
        p = {"name": RENAME.get(name, name), "expression": renamed(text)}
        if comment:
            p["comment"] = comment
        if unit is not None:
            p["unit"] = unit
        self.cmds.append({"command": "parameters.add", "params": p})
        return name

    def group(self, name, features):
        self.groups.append((name, features))

    def finish(self):
        for i, (name, feats) in enumerate(self.groups):
            self.cmd("timeline.group", name="%d %s" % (i + 1, name), features=feats)
        return {"commands": self.cmds}


def pos(s, expr):
    """Unsigned distance from the sketch origin as an expression that stays positive."""
    return "-(%s)" % expr if s.ev(expr) < 0 else str(expr)


class Sketch:
    """One sketch: draws with the current values, then dimensions everything to the origin
    with expressions, so the sketch follows the parameters. Ids are counted per sketch."""

    def __init__(self, s, name, plane, offset=None):
        self.s, self.name = s, name
        self.l = self.a = self.c = self.p = 0
        # No projected body edges: they would take the first line ids of the sketch.
        p = {"plane": plane, "name": name, "project_edges": False}
        if offset is not None:
            p["offset"] = str(offset)
        s.cmd("sketch.create", **p)

    def _dim(self, entities, value, typ=None):
        p = {"entities": entities, "value": str(value)}
        if typ:
            p["type"] = typ
        self.s.cmd("sketch.dimension", **p)

    def _place(self, sides, x0, x1, y0, y1):
        """Dimension a box-shaped outline to the origin by its left and bottom lines, or by
        its right and top lines when the left or bottom one runs through the origin."""
        ev = self.s.ev
        bottom, right, top, left = sides
        if abs(ev(x0)) > 0.05:
            self._dim(["origin", left], pos(self.s, x0))
        else:
            self._dim(["origin", right], pos(self.s, x1))
        if abs(ev(y0)) > 0.05:
            self._dim(["origin", bottom], pos(self.s, y0))
        else:
            self._dim(["origin", top], pos(self.s, y1))

    def rect(self, x0, x1, y0, y1, r=None):
        """Rectangle from (x0, y0) to (x1, y1), corners rounded with r when given."""
        ev = self.s.ev
        p0, p1 = [ev(x0), ev(y0)], [ev(x1), ev(y1)]
        n = self.l
        bottom, right, top, left = ("l%d" % (n + i) for i in (1, 2, 3, 4))
        self.l += 4
        if r is None:
            self.s.cmd("sketch.rectangle.two_point", p0=p0, p1=p1)
            self._dim([bottom], "(%s) - (%s)" % (x1, x0))
            self._dim([right], "(%s) - (%s)" % (y1, y0))
        else:
            self.a += 4
            self.s.cmd("sketch.rectangle.rounded", p0=p0, p1=p1, radius=str(r))
            self._dim([bottom], "(%s) - (%s) - 2 * (%s)" % (x1, x0, r))
            self._dim([right], "(%s) - (%s) - 2 * (%s)" % (y1, y0, r))
        self._place((bottom, right, top, left), x0, x1, y0, y1)
        return [bottom, right, top, left]

    def circle(self, cx, cy, d):
        ev = self.s.ev
        self.c += 1
        c = "c%d" % self.c
        self.s.cmd("sketch.circle.center", center=[ev(cx), ev(cy)], diameter=ev(d))
        self._dim([c], d, "diameter")
        for v, typ in ((cx, "horizontal"), (cy, "vertical")):
            assert abs(ev(v)) > 0.05, "circle centre on a sketch axis: dimension it another way"
            self._dim(["origin", c + ".center"], pos(self.s, v), typ)
        return c

    def point(self, x, y):
        ev = self.s.ev
        self.p += 1
        pt = "p%d" % self.p
        self.s.cmd("sketch.point", point=[ev(x), ev(y)])
        for v, typ in ((x, "horizontal"), (y, "vertical")):
            self._dim(["origin", pt], pos(self.s, v), typ)
        return pt

    def polygon(self, pts, lengths, places):
        """Closed polyline through pts [(x, y) expressions]; axis-aligned edges get horizontal or
        vertical constraints. lengths: [(edge index, expr)], places: [(edge index, expr)] as
        distances from the origin to an edge. Edge i runs from pts[i] to pts[i + 1]."""
        ev = self.s.ev
        n = self.l
        self.l += len(pts)
        self.s.cmd("sketch.line", points=[[ev(x), ev(y)] for x, y in pts], closed=True, infer=True)
        for i, e in lengths:
            self._dim(["l%d" % (n + i + 1)], e)
        for i, e in places:
            self._dim(["origin", "l%d" % (n + i + 1)], pos(self.s, e))

    def diamond(self, ac, bc, d):
        """Square turned 45 degrees, d across corners, centred on (ac, bc). Placed by the
        distances from the origin to two neighbouring sides (normals (1, -1) and (1, 1))."""
        h = "(%s) / 2" % d
        self.polygon([(ac, "%s - %s" % (bc, h)), ("%s + %s" % (ac, h), bc), (ac, "%s + %s" % (bc, h)),
                      ("%s - %s" % (ac, h), bc)],
                     [(i, "(%s) * 0.70710678" % d) for i in range(3)],
                     [(0, "((%s) - (%s) + %s) * 0.70710678" % (ac, bc, h)),
                      (1, "((%s) + (%s) + %s) * 0.70710678" % (ac, bc, h))])

    def hexagon(self, cx, cy, af):
        """Regular hexagon, af across flats, a corner on +y (flats facing +-x)."""
        r, w = "(%s) / 1.7320508" % af, "(%s) / 2" % af
        self.polygon([(cx, "%s + %s" % (cy, r)), ("%s - %s" % (cx, w), "%s + %s / 2" % (cy, r)),
                      ("%s - %s" % (cx, w), "%s - %s / 2" % (cy, r)), (cx, "%s - %s" % (cy, r)),
                      ("%s + %s" % (cx, w), "%s - %s / 2" % (cy, r)), ("%s + %s" % (cx, w), "%s + %s / 2" % (cy, r))],
                     [(i, r) for i in range(5)],
                     [(1, "%s - %s" % (cx, w)),
                      # side 0 (corner on +y to the upper-left corner), normal (0.5, -0.866)
                      (0, "0.5 * (%s) - 0.8660254 * (%s + %s)" % (cx, cy, r))])

    def chamfered(self, a0, a1, z0, z1, c):
        """Rectangle with 45 degree corner chamfers of leg c."""
        ev = self.s.ev
        A0, A1, Z0, Z1 = ("(%s)" % v for v in (a0, a1, z0, z1))
        c = "(%s)" % c
        wl, hl, sl = "%s - %s - 2 * %s" % (A1, A0, c), "%s - %s - 2 * %s" % (Z1, Z0, c), "%s * 1.41421356" % c
        self.polygon([("%s + %s" % (A0, c), Z0), ("%s - %s" % (A1, c), Z0), (A1, "%s + %s" % (Z0, c)),
                      (A1, "%s - %s" % (Z1, c)), ("%s - %s" % (A1, c), Z1), ("%s + %s" % (A0, c), Z1),
                      (A0, "%s - %s" % (Z1, c)), (A0, "%s + %s" % (Z0, c))],
                     [(0, wl), (2, hl), (4, wl), (6, hl), (1, sl), (3, sl), (5, sl), (7, sl)],
                     [(0, z0), (6, a0)])

    def done(self):
        self.s.cmd("sketch.finish")


# Sketch planes. Sketch (x, y) means:
XY = "XY"                                                             # world (X, Y), normal +Z
WALL_NS = {"origin": [0, 0, 0], "x_dir": [1, 0, 0], "y_dir": [0, 0, 1]}  # (X, Z), normal -Y
WALL_EW = {"origin": [0, 0, 0], "x_dir": [0, 1, 0], "y_dir": [0, 0, 1]}  # (Y, Z), normal +X


def build(variant):
    p = load_params(variant)
    s = Script()
    P = s.param

    # ---------------------------------------------------------------- parameters
    P("wall", p["WALL"], "wall thickness")
    P("floor", p["FLOOR"], "floor thickness")
    P("lid", p["LID"], "lid thickness")
    P("gap", p["GAP"], "board to wall clearance")
    P("standoff", p["STANDOFF"], "standoff height under the board")
    P("pcb_t", p["PCB_T"], "board thickness")
    P("tallest", 17.6, "tallest part on the board (relays)")
    P("top_clear", p["TOP_CLEAR"], "clearance above the tallest part")
    P("fit", p["FIT"], "lid lip to wall clearance")
    P("r_outer", 3.0, "outer corner radius")
    P("r_inner", 1.0, "cavity corner radius")
    P("board_x", p["BOARD_X"], "half board length (board centred on the origin)")
    P("board_y", p["BOARD_Y"], "half board width")
    P("cav_west", p["X0"], "west cavity wall (the USB-C plug sticks out)")
    P("cav_margin", p["Y1"] - p["BOARD_Y"], "cavity margin north and south")
    P("pcb_z", "floor + standoff", "board bottom")
    P("h", "pcb_z + tallest + top_clear", "base height")
    P("cav_x0", "cav_west")
    P("cav_x1", "board_x + gap")
    P("cav_y", "board_y + cav_margin", "half cavity width")
    P("out_x0", "cav_x0 - wall")
    P("out_x1", "cav_x1 + wall")
    P("out_y", "cav_y + wall", "half outer width")
    P("insert_bore", p["INSERT_BORE"], "M2.5 heat insert bore")
    P("insert_depth", p["INSERT_DEPTH"], "insert bore depth")
    P("standoff_d", 6.4, "standoff diameter")
    holes = []
    for i, (x, y) in enumerate(p["PCB_HOLES"]):
        holes.append((P("hole%d_x" % (i + 1), x, "board mounting hole"), P("hole%d_y" % (i + 1), y)))
    screws = bool(p["SCREW_BOSSES"])
    if screws:
        P("boss_d", 6.8, "lid screw boss diameter")
        P("boss_x", abs(p["SCREW_BOSSES"][0][0]), "lid screw boss x (mirrored)")
        P("boss_offset", 2.2, "boss centre outside the wall")
        P("boss_y", "out_y + boss_offset")
        P("lid_screw", p["LID_SCREW"], "M2.5 clearance hole in the lid")
    P("term_w", p["TERM_W"], "terminal wire window width and lid hole diameter")
    P("term_pitch", 5.08, "terminal pole pitch")
    P("wire_z0", p["WIRE_Z"][0], "wire window bottom above the board bottom")
    P("wire_z1", p["WIRE_Z"][1], "wire window top above the board bottom")
    names = ["P4", "P5", "P6", "P3", "P2", "P1", "P8", "P9"]
    blocks = []
    for bi in range(len(p["TERMINALS"]) // 3):
        (fx, fy), side = p["TERMINALS"][bi * 3]
        along_x = side in "NS"
        n = names[bi]
        blocks.append((n, side, along_x, P(n.lower() + "_first", fx if along_x else fy, "first pole, %s wall" % side),
                       P(n.lower() + "_row", fy if along_x else fx)))
    P("usb_y", p["USB_C"][0], "USB-C centre y")
    P("usb_z", p["USB_C"][1], "USB-C centre above the board bottom")
    P("usb_w", 12.8, "USB-C window width")
    P("usb_h", 7.2, "USB-C window height")
    P("usb_chamfer", 1.4, "USB-C window 45 degree corner chamfer")
    P("mdb_x0", p["MDB"][0], "MDB connector x min")
    P("mdb_x1", p["MDB"][1], "MDB connector x max")
    P("mdb_top", p["MDB"][3], "MDB connector top above the board bottom")
    P("antenna_x", p["ANTENNA_X"], "U.FL cable slot, north wall")
    P("uart_x", p["UART_X"], "UART debug slot, north wall")
    P("uart_w", p["UART_W"], "UART debug slot width")
    if p["SMA"]:
        P("sma_x", p["SMA"][0], "SMA jack hole centre x, north wall")
        P("sma_z", p["SMA"][1], "SMA jack hole centre height")
        P("sma_d", p["SMA_D"], "SMA jack hole diameter (panel cutout 6.5)")
        P("sma_cap", p["SMA_CAP"], "teardrop cut-off above the hole top")
    P("led_x", p["LEDS"][0][0], "LED window")
    P("led_y", p["LEDS"][0][1])
    P("led_d", 4.0, "LED window diameter")
    P("vent_d", p["VENT_D"], "wall vent diamond, across corners")
    P("vent_pitch", 5.0, "wall vent pitch")
    n_vent = sum(1 for i in range(-14, 15) if not any(abs(i * 5.0 - bx) < 5 for bx, _ in p["SCREW_BOSSES"]))
    P("vent_n", n_vent, "wall vents per long wall", unit="")
    P("hex_af", p["LID_HEX"][0], "lid vent hexagon across flats")
    P("hex_web", p["LID_HEX"][1], "web between lid vent hexagons")
    P("hex_pitch", "hex_af + hex_web")
    P("hex_row", "hex_pitch * 0.8660254", "lid vent row spacing")
    hex_zones = []
    for i, (zx0, zx1, zy0, zy1) in enumerate(p["LID_VENT_ZONES"]):
        z = "lv%d" % (i + 1)
        P(z + "_x0", zx0, "lid vent zone")
        P(z + "_x1", zx1)
        P(z + "_y0", zy0)
        P(z + "_y1", zy1)
        af, web = p["LID_HEX"]
        nx = int((zx1 - zx0 - af) // (af + web)) + 1
        ny = int((zy1 - zy0 - 2 * af / 3 ** 0.5) // ((af + web) * 3 ** 0.5 / 2)) + 1
        hex_zones.append((z, nx, ny))
    P("clip_w", 8.0, "clip tab width")
    P("clip_t", 1.2, "clip tab thickness")
    P("bump", p["BUMP"], "clip catch height")
    P("clip_pocket", p["CLIP_POCKET"], "blind clip notch depth into the wall")
    P("clip_z0", "h - 8", "clip window bottom")
    P("clip_z1", "h - 5.6", "clip window top")
    P("clip1_x", p["CLIP_X"][0], "first clip pair")
    P("clip2_x", p["CLIP_X"][1], "second clip pair")
    P("lip_d", 2.5, "lid lip depth")
    P("lip_t", 1.6, "lid lip thickness")
    P("ear_t", 4.0, "mounting ear thickness")
    P("ear_l", 20.0, "mounting ear length")
    P("ear_w", 32.0, "mounting ear width")

    base = ["Base"]
    lid_b = ["Lid"]

    def extrude(name, distance, **kw):
        s.cmd("solid.extrude", distance=str(distance), name=name, **kw)
        return name

    def wall_cut(name, side, shapes, extra=None):
        """Sketch on the middle of a wall and cut through it. shapes(sk) draws in wall coordinates."""
        if side in "NS":
            plane = WALL_NS
            off = "cav_y + wall / 2" if side == "S" else "-(cav_y + wall / 2)"
        else:
            plane = WALL_EW
            off = "cav_x1 + wall / 2" if side == "E" else "cav_x0 - wall / 2"
        sk = Sketch(s, name + " sketch", plane, off)
        shapes(sk)
        sk.done()
        return extrude(name, "wall + 2", direction="symmetric", operation="cut", targets=base)

    # ---------------------------------------------------------------- base: shell
    sk = Sketch(s, "Outline sketch", XY)
    sk.rect("out_x0", "out_x1", "-out_y", "out_y", "r_outer")
    sk.done()
    f_shell = [extrude("Outer body", "h", body_name="Base")]
    sk = Sketch(s, "Cavity sketch", XY, "floor")
    sk.rect("cav_x0", "cav_x1", "-cav_y", "cav_y", "r_inner")
    sk.done()
    f_shell.append(extrude("Cavity", "h", operation="cut", targets=base))
    s.group("Shell", ["Outline sketch", "Outer body", "Cavity sketch", "Cavity"])

    # ---------------------------------------------------------------- standoffs and inserts
    sk = Sketch(s, "Standoffs sketch", XY, "floor")
    for hx, hy in holes:
        sk.circle(hx, hy, "standoff_d")
    sk.done()
    extrude("Standoffs", "standoff", operation="join", targets=base)
    # Heat insert bores: a hole with a 0.4 mm 45 degree lead-in (countersink) at the top.
    def inserts(name, pts, top):
        sk = Sketch(s, name + " sketch", XY, top)
        for x, y in pts:
            sk.point(x, y)
        sk.done()
        s.cmd("solid.hole", sketch=name + " sketch", diameter="insert_bore", depth="insert_depth", type="countersink",
              cs_diameter="insert_bore + 0.8", cs_angle="90 deg", name=name)
        return [name + " sketch", name]

    s.group("Standoffs", ["Standoffs sketch", "Standoffs"] + inserts("Board inserts", holes, "pcb_z"))

    # ---------------------------------------------------------------- lid screw bosses
    bosses = []
    if screws:
        for sx in ("-", ""):
            for sy in ("-", ""):
                bosses.append(("%sboss_x" % sx, "%sboss_y" % sy, sy))
        sk = Sketch(s, "Screw bosses sketch", XY)
        for bx, by, sy in bosses:
            sk.circle(bx, by, "boss_d")
            yw = "-(cav_y + wall - 0.5)" if sy else "cav_y + wall - 0.5"
            lo, hi = (by, yw) if sy else (yw, by)
            sk.rect("%s - boss_d / 2" % bx, "%s + boss_d / 2" % bx, lo, hi)
        sk.done()
        extrude("Screw bosses", "h", operation="join", targets=base)
        s.group("Lid screw bosses", ["Screw bosses sketch", "Screw bosses"] +
                inserts("Boss inserts", [(bx, by) for bx, by, _ in bosses], "h"))

    # ---------------------------------------------------------------- mounting ears
    # One sketch for both ears, one for the M4 slots and zip-tie slots (a 10 x 4.5 stadium
    # drawn as a rectangle and two circles, and two 9 x 3.2 slots per ear).
    sk = Sketch(s, "Ears sketch", XY)
    sk.rect("out_x0 - ear_l", "out_x0 + 2", "-ear_w / 2", "ear_w / 2", "r_outer")
    sk.rect("out_x1 - 2", "out_x1 + ear_l", "-ear_w / 2", "ear_w / 2", "r_outer")
    sk.done()
    extrude("Ears", "ear_t", operation="join", targets=base)
    sk = Sketch(s, "Ear slots sketch", XY, "ear_t / 2")
    for xc in ("(out_x0 - ear_l / 2)", "(out_x1 + ear_l / 2)"):
        sk.rect("%s - 2.25" % xc, "%s + 2.25" % xc, "-2.75", "2.75")
        sk.circle(xc, "-2.75", "4.5")
        sk.circle(xc, "2.75", "4.5")
        for y in ("-11", "11"):
            sk.rect("%s - 4.5" % xc, "%s + 4.5" % xc, "%s - 1.6" % y, "%s + 1.6" % y)
    sk.done()
    extrude("Ear slots", "ear_t + 2", direction="symmetric", operation="cut", targets=base)
    s.group("Mounting ears", ["Ears sketch", "Ears", "Ear slots sketch", "Ear slots"])

    # ---------------------------------------------------------------- connectors
    # USB-C: 45 degree corner chamfers keep the top bridge short. MDB: slot open to the wall
    # rim (no bridge); the lid's MDB filler tab closes it above the plug.
    f = [wall_cut("USB-C window", "W", lambda k: k.chamfered("usb_y - usb_w / 2", "usb_y + usb_w / 2",
                                                              "pcb_z + usb_z - usb_h / 2", "pcb_z + usb_z + usb_h / 2",
                                                              "usb_chamfer")),
         wall_cut("MDB slot", "S", lambda k: k.rect("mdb_x0 - 0.8", "mdb_x1 + 0.8", "pcb_z + pcb_t + 0.3",
                                                    "h + 3", "1")),
         wall_cut("Cable slots", "N", lambda k: (k.rect("antenna_x - 1.5", "antenna_x + 1.5", "h - 2", "h + 1"),
                                                k.rect("uart_x - uart_w / 2", "uart_x + uart_w / 2", "h - 2", "h + 1")))]
    if p["SMA"]:
        # round hole plus a teardrop top cut off just above the circle (prints without support)
        def cap(k):
            a, b = "sma_d / 2 * 0.70710678", "(sma_d / 2 + sma_cap)"
            t = "(sma_d / 2 * 1.41421356 - %s)" % b
            k.polygon([("sma_x - %s" % a, "sma_z"), ("sma_x + %s" % a, "sma_z"), ("sma_x + %s" % a, "sma_z + %s" % a),
                       ("sma_x + %s" % t, "sma_z + %s" % b), ("sma_x - %s" % t, "sma_z + %s" % b),
                       ("sma_x - %s" % a, "sma_z + %s" % a)],
                      [(0, "2 * %s" % a), (1, a), (3, "2 * %s" % t), (5, a), (2, "(%s - %s) * 1.41421356" % (b, a))],
                      [(0, "sma_z"), (5, "sma_x - %s" % a), (3, "sma_z + %s" % b)])
        # two steps: SolidCraft does not split a circle and an overlapping polygon into regions
        f.append(wall_cut("SMA jack hole", "N", lambda k: k.circle("sma_x", "sma_z", "sma_d")))
        f.append(wall_cut("SMA jack hole cap", "N", cap))
    s.group("Connector windows", sum(([n + " sketch", n] for n in f), []))

    # ---------------------------------------------------------------- terminal wire windows
    # Round top: a rectangle up to the arc centre plus a circle, in two cuts (SolidCraft does not
    # split a circle and an overlapping rectangle into regions).
    feats = []
    zc = "pcb_z + wire_z1 - term_w / 2"
    for n, side, along_x, first, row in blocks:
        body = wall_cut("%s wire window" % n, side, lambda k, first=first: k.rect(
            "%s - term_w / 2" % first, "%s + term_w / 2" % first, "pcb_z + wire_z0", zc))
        top = wall_cut("%s wire window top" % n, side, lambda k, first=first: k.circle(first, zc, "term_w"))
        s.cmd("solid.pattern.rectangular", features=[body, top], dir1=[1, 0, 0] if along_x else [0, 1, 0],
              count1=3, spacing1="term_pitch", name="%s wire windows" % n)
        feats += [body + " sketch", body, top + " sketch", top, "%s wire windows" % n]
    s.group("Terminal wire windows", feats)

    # ---------------------------------------------------------------- low vents
    first = "-(vent_n - 1) / 2 * vent_pitch"
    vents = [wall_cut("Vent %s" % side, side, lambda k: k.diamond(first, "(floor + pcb_z) / 2", "vent_d"))
             for side in "SN"]
    s.cmd("solid.pattern.rectangular", features=vents, dir1=[1, 0, 0], count1="vent_n", spacing1="vent_pitch",
          name="Vent rows")
    s.group("Low vents", ["Vent S sketch", "Vent S", "Vent N sketch", "Vent N", "Vent rows"])

    # ---------------------------------------------------------------- clip notches
    # blind pockets clip_pocket deep in the inner wall faces, cut down from the notch top
    sk = Sketch(s, "Clip notches sketch", XY, "clip_z1")
    sk.rect("clip1_x - clip_w / 2 - 0.4", "clip1_x + clip_w / 2 + 0.4", "-cav_y - clip_pocket", "-cav_y + 1")
    sk.rect("clip1_x - clip_w / 2 - 0.4", "clip1_x + clip_w / 2 + 0.4", "cav_y - 1", "cav_y + clip_pocket")
    sk.done()
    extrude("Clip notch", "clip_z1 - clip_z0", direction="reverse", operation="cut", targets=base)
    s.cmd("solid.pattern.rectangular", features=["Clip notch"], dir1=[1, 0, 0], count1=2,
          spacing1="clip2_x - clip1_x", name="Clip notches")
    s.group("Clip notches", ["Clip notches sketch", "Clip notch", "Clip notches"])

    # ---------------------------------------------------------------- lid
    sk = Sketch(s, "Lid plate sketch", XY, "h")
    sk.rect("out_x0", "out_x1", "-out_y", "out_y", "r_outer")
    if screws:
        for bx, by, sy in bosses:
            sk.circle(bx, by, "boss_d")
            yw = "-(cav_y + wall - 0.5)" if sy else "cav_y + wall - 0.5"
            lo, hi = (by, yw) if sy else (yw, by)
            sk.rect("%s - boss_d / 2" % bx, "%s + boss_d / 2" % bx, lo, hi)
    sk.done()
    extrude("Lid plate", "lid", operation="new", body_name="Lid")
    sk = Sketch(s, "Lip sketch", XY, "h - lip_d")
    sk.rect("cav_x0 + fit", "cav_x1 - fit", "-(cav_y - fit)", "cav_y - fit", "r_inner")
    sk.rect("cav_x0 + fit + lip_t", "cav_x1 - fit - lip_t", "-(cav_y - fit - lip_t)", "cav_y - fit - lip_t", "0.5")
    sk.done()
    ring_pt = [(s.ev("cav_x0 + fit") + s.ev("cav_x0 + fit + lip_t")) / 2, 0]
    extrude("Lip", "lip_d + 0.01", operation="join", targets=lid_b, profiles=[{"point": ring_pt}])
    sk = Sketch(s, "Lip reliefs sketch", XY, "h - lip_d - 1")
    y1 = "cav_y"
    sk.rect("antenna_x - 2", "antenna_x + 2", "%s - 3" % y1, "%s + 1" % y1)
    sk.rect("uart_x - uart_w / 2 - 0.5", "uart_x + uart_w / 2 + 0.5", "%s - 3" % y1, "%s + 1" % y1)
    for cx in ("clip1_x", "clip2_x"):
        for yw in ("-cav_y", "cav_y"):
            sk.rect("%s - clip_w / 2 - 1" % cx, "%s + clip_w / 2 + 1" % cx, "%s - 3" % yw, "%s + 3" % yw)
    sk.done()
    extrude("Lip reliefs", "lip_d + 1", operation="cut", targets=lid_b)
    sk = Sketch(s, "MDB filler tab sketch", XY, "pcb_z + mdb_top + 2")
    sk.rect("mdb_x0 - 0.8 + fit", "mdb_x1 + 0.8 - fit", "-out_y", "-(cav_y - fit - 0.01)")
    sk.done()
    extrude("MDB filler tab", "h + 0.01 - (pcb_z + mdb_top + 2)", operation="join", targets=lid_b)
    s.group("Lid and lip", ["Lid plate sketch", "Lid plate", "Lip sketch", "Lip", "Lip reliefs sketch", "Lip reliefs",
                            "MDB filler tab sketch", "MDB filler tab"])

    # clips: per side one profile, the tab with its ramped catch on the outside, extruded both
    # ways from the clip's centre plane; the second pair is a pattern along x.
    feats = []
    z0, zb, zc, zt = "clip_z0 - 0.3", "clip_z0 - 0.1", "clip_z1 - 0.3", "h + 0.01"   # 0.01 into the plate
    for side in "SN":
        sk = Sketch(s, "Clip %s sketch" % side, WALL_EW, "clip1_x")
        if side == "S":
            out, inn, far = "(-cav_y + fit)", "(-cav_y + fit + clip_t)", "(-cav_y + fit - bump)"
            sk.polygon([(out, z0), (inn, z0), (inn, zt), (out, zt), (out, zc), (far, zc), (out, zb)],
                       [(0, "clip_t"), (2, "clip_t"), (1, "(%s) - (%s)" % (zt, z0)), (3, "(%s) - (%s)" % (zt, zc)),
                        (4, "bump"), (6, "(%s) - (%s)" % (zb, z0))],
                       [(0, z0), (1, inn)])
        else:
            out, inn, far = "(cav_y - fit)", "(cav_y - fit - clip_t)", "(cav_y - fit + bump)"
            sk.polygon([(inn, z0), (out, z0), (out, zb), (far, zc), (out, zc), (out, zt), (inn, zt)],
                       [(0, "clip_t"), (5, "clip_t"), (1, "(%s) - (%s)" % (zb, z0)), (4, "(%s) - (%s)" % (zt, zc)),
                        (3, "bump"), (6, "(%s) - (%s)" % (zt, z0))],
                       [(0, z0), (6, inn)])
        sk.done()
        feats += ["Clip %s sketch" % side,
                  extrude("Clip %s" % side, "clip_w", direction="symmetric", operation="join", targets=lid_b)]
    s.cmd("solid.pattern.rectangular", features=["Clip S", "Clip N"], dir1=[1, 0, 0], count1=2,
          spacing1="clip2_x - clip1_x", name="Clips")
    s.group("Clips", feats + ["Clips"])

    # lid cut-outs
    def lid_cut(name, shapes):
        sk = Sketch(s, name + " sketch", XY, "h + lid / 2")
        shapes(sk)
        sk.done()
        return extrude(name, "lid + 2", direction="symmetric", operation="cut", targets=lid_b)

    feats = []
    if screws:
        name = lid_cut("Lid screw holes", lambda k: [k.circle(bx, by, "lid_screw") for bx, by, _ in bosses])
        feats += [name + " sketch", name]
    for n, side, along_x, first, row in blocks:
        x, y = (first, row) if along_x else (row, first)
        name = lid_cut("%s screwdriver hole" % n, lambda k, x=x, y=y: k.circle(x, y, "term_w"))
        s.cmd("solid.pattern.rectangular", features=[name], dir1=[1, 0, 0] if along_x else [0, 1, 0],
              count1=3, spacing1="term_pitch", name="%s screwdriver holes" % n)
        feats += [name + " sketch", name, "%s screwdriver holes" % n]
    name = lid_cut("LED window", lambda k: k.circle("led_x", "led_y", "led_d"))
    feats += [name + " sketch", name]
    # Honeycomb: one hexagon per row, patterned along x; odd rows start half a pitch in and hold
    # one hole less (as build_case.py's hex_field).
    for z, nx, ny in hex_zones:
        ox = "((%s_x0 + %s_x1 - %d * hex_pitch) / 2)" % (z, z, nx - 1)
        oy = "((%s_y0 + %s_y1 - %d * hex_row) / 2)" % (z, z, ny - 1)
        for j in range(ny):
            cx, cy = "%s + %s * hex_pitch" % (ox, 0.5 * (j % 2)), "%s + %d * hex_row" % (oy, j)
            name = lid_cut("Lid vent %s row %d" % (z, j + 1), lambda k, cx=cx, cy=cy: k.hexagon(cx, cy, "hex_af"))
            s.cmd("solid.pattern.rectangular", features=[name], dir1=[1, 0, 0], count1=nx - j % 2,
                  spacing1="hex_pitch", name="Lid vents %s row %d" % (z, j + 1))
            feats += [name + " sketch", name, "Lid vents %s row %d" % (z, j + 1)]
    s.group("Lid cut-outs", feats)
    return s.finish()


if __name__ == "__main__":
    for v in (sys.argv[1:] or ["clips", "screw-clips"]):
        out = os.path.join(os.environ.get("SOLIDCRAFT_OUT", os.path.join(HERE, v)),
                           "case_wroom-u1-%s.solidcraft.json" % v)
        script = build(v)
        with open(out, "w", encoding="utf-8") as f:
            json.dump(script, f, indent=1)
        print("%s: %d commands -> %s" % (v, len(script["commands"]), out))
