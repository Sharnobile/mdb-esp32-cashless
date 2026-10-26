"""Parametric FreeCAD document for the WROOM-1U enclosure. Units: mm.

Builds the same base and lid as <variant>/build_case.py, but as a live feature tree:
every dimension sits in the `Params` spreadsheet, every primitive is bound to it by an
expression, and the boolean steps (shell, standoffs, bosses, ears, wall cuts, lid lip,
clips, lid cuts) are separate, named tree nodes. Change a cell, press Recompute.

Run from this folder (FreeCAD 1.x):
  freecadcmd build_fcstd.py                       # both variants
  VARIANT=clips freecadcmd build_fcstd.py         # one variant

The values are read from the parameter section of <variant>/build_case.py, so both
stay in sync. Writes <variant>/case_wroom-u1-<variant>.FCStd.

Adding or removing whole features (another terminal block, a different number of
vent slots) changes the tree itself: edit build_case.py and run this script again.
"""
import os

import FreeCAD as App
import Part  # noqa: F401  (registers the Part:: types)
import Spreadsheet  # noqa: F401

V = App.Vector
try:
    HERE = os.path.dirname(os.path.abspath(__file__))
except NameError:
    HERE = os.getcwd()
MARK = "# ---------------------------------------------------------------- base"


def load_params(variant):
    src = open(os.path.join(HERE, variant, "build_case.py"), encoding="utf-8").read()
    ns = {"__file__": os.path.join(HERE, variant, "build_case.py")}
    exec(compile(src[:src.index(MARK)], "build_case.py", "exec"), ns)
    return ns


class Doc:
    def __init__(self, name):
        self.doc = App.newDocument(name)
        self.sheet = self.doc.addObject("Spreadsheet::Sheet", "Params")
        self.sheet.Label = "Params"
        self.row = 1
        self._sheet_row("Name", "Value", "Note", header=True)

    # ------------------------------------------------------------ spreadsheet
    def _sheet_row(self, a, b, c, header=False):
        r = self.row
        self.sheet.set("A%d" % r, a)
        self.sheet.set("B%d" % r, b)
        self.sheet.set("C%d" % r, c)
        if header:
            self.sheet.setStyle("A%d:C%d" % (r, r), "bold")
        self.row += 1
        return r

    def section(self, title):
        self.row += 1
        self._sheet_row(title, "", "", header=True)

    def param(self, alias, value, note=""):
        """value: a number (editable) or a string starting with '=' (derived)."""
        v = value if isinstance(value, str) else repr(round(float(value), 6))
        r = self._sheet_row(alias, v, note)
        self.sheet.setAlias("B%d" % r, alias)
        return "Params." + alias

    # ------------------------------------------------------------ primitives
    def _new(self, typ, label, group):
        o = self.doc.addObject(typ, label.replace(" ", "_"))
        o.Label = label
        if group is not None:
            group.addObject(o)
        return o

    def box(self, label, x0, x1, y0, y1, z0, z1, group=None):
        b = self._new("Part::Box", label, group)
        b.setExpression("Length", "(%s) - (%s)" % (x1, x0))
        b.setExpression("Width", "(%s) - (%s)" % (y1, y0))
        b.setExpression("Height", "(%s) - (%s)" % (z1, z0))
        b.setExpression(".Placement.Base.x", str(x0))
        b.setExpression(".Placement.Base.y", str(y0))
        b.setExpression(".Placement.Base.z", str(z0))
        return b

    def cyl(self, label, cx, cy, r, z0, z1, group=None, axis="z"):
        """Cylinder. axis z: centre (cx, cy), z0..z1. axis y: centre (x=cx, z=cy), y from z0..z1.
        axis x: centre (y=cx, z=cy), x from z0..z1."""
        c = self._new("Part::Cylinder", label, group)
        c.setExpression("Radius", str(r))
        c.setExpression("Height", "(%s) - (%s)" % (z1, z0))
        if axis == "z":
            c.setExpression(".Placement.Base.x", str(cx))
            c.setExpression(".Placement.Base.y", str(cy))
            c.setExpression(".Placement.Base.z", str(z0))
        elif axis == "y":
            c.Placement.Rotation = App.Rotation(V(1, 0, 0), -90)
            c.setExpression(".Placement.Base.x", str(cx))
            c.setExpression(".Placement.Base.y", str(z0))
            c.setExpression(".Placement.Base.z", str(cy))
        else:
            c.Placement.Rotation = App.Rotation(V(0, 1, 0), 90)
            c.setExpression(".Placement.Base.x", str(z0))
            c.setExpression(".Placement.Base.y", str(cx))
            c.setExpression(".Placement.Base.z", str(cy))
        return c

    def cone(self, label, cx, cy, r1, r2, z0, h, group=None):
        c = self._new("Part::Cone", label, group)
        c.setExpression("Radius1", str(r1))
        c.setExpression("Radius2", str(r2))
        c.setExpression("Height", str(h))
        c.setExpression(".Placement.Base.x", str(cx))
        c.setExpression(".Placement.Base.y", str(cy))
        c.setExpression(".Placement.Base.z", str(z0))
        return c

    def fuse(self, label, shapes, group=None, refine=True):
        f = self._new("Part::MultiFuse", label, group)
        f.Shapes = shapes
        f.Refine = refine
        for s in shapes:
            s.Visibility = False
        return f

    def cut(self, label, base, tool, group=None):
        c = self._new("Part::Cut", label, group)
        c.Base, c.Tool = base, tool
        c.Refine = True
        base.Visibility = tool.Visibility = False
        return c

    def folder(self, label, parent=None):
        g = self._new("App::DocumentObjectGroup", label, parent)
        return g

    # ------------------------------------------------------------ compound shapes
    def rbox(self, label, x0, x1, y0, y1, z0, z1, r, group=None):
        """Box with rounded vertical edges: two crossed boxes plus four corner cylinders."""
        g = self.folder(label + " parts", group)
        parts = [self.box(label + " core x", "%s + %s" % (x0, r), "%s - %s" % (x1, r), y0, y1, z0, z1, g),
                 self.box(label + " core y", x0, x1, "%s + %s" % (y0, r), "%s - %s" % (y1, r), z0, z1, g)]
        for nx, xs in (("W", "%s + %s" % (x0, r)), ("E", "%s - %s" % (x1, r))):
            for ny, ys in (("S", "%s + %s" % (y0, r)), ("N", "%s - %s" % (y1, r))):
                parts.append(self.cyl("%s corner %s%s" % (label, ny, nx), xs, ys, r, z0, z1, g))
        return self.fuse(label, parts, group)

    def rwindow(self, label, plane, a0, a1, b0, b1, c0, c1, r, group=None):
        """Through-cut with rounded edges along the cut direction.
        plane 'xz': a = x, b = z, cut along y from c0..c1.  plane 'yz': a = y, b = z, cut along x."""
        g = self.folder(label + " parts", group)
        if plane == "xz":
            parts = [self.box(label + " core a", "%s + %s" % (a0, r), "%s - %s" % (a1, r), c0, c1, b0, b1, g),
                     self.box(label + " core b", a0, a1, c0, c1, "%s + %s" % (b0, r), "%s - %s" % (b1, r), g)]
            axis = "y"
        else:
            parts = [self.box(label + " core a", c0, c1, "%s + %s" % (a0, r), "%s - %s" % (a1, r), b0, b1, g),
                     self.box(label + " core b", c0, c1, a0, a1, "%s + %s" % (b0, r), "%s - %s" % (b1, r), g)]
            axis = "x"
        for aa in ("%s + %s" % (a0, r), "%s - %s" % (a1, r)):
            for bb in ("%s + %s" % (b0, r), "%s - %s" % (b1, r)):
                parts.append(self.cyl(label + " corner", aa, bb, r, c0, c1, g, axis=axis))
        return self.fuse(label, parts, group)

    def diamond(self, label, plane, ac, bc, D, c0, c1, group=None):
        """Square turned 45 deg in the wall plane: |a - ac| + |b - bc| <= D, cut from c0..c1.
        Gives the 45 deg roofs and chamfers of the wall windows."""
        b = self._new("Part::Box", label, group)
        side = "(%s) * 1.41421356" % D
        if plane == "xz":
            b.Placement.Rotation = App.Rotation(V(0, 1, 0), 45)     # local x down-right, z up-right
            b.setExpression("Length", side)
            b.setExpression("Width", "(%s) - (%s)" % (c1, c0))
            b.setExpression("Height", side)
            b.setExpression(".Placement.Base.x", "(%s) - (%s)" % (ac, D))
            b.setExpression(".Placement.Base.y", str(c0))
        else:
            b.Placement.Rotation = App.Rotation(V(1, 0, 0), -45)    # local y down-right, z up-right
            b.setExpression("Length", "(%s) - (%s)" % (c1, c0))
            b.setExpression("Width", side)
            b.setExpression("Height", side)
            b.setExpression(".Placement.Base.x", str(c0))
            b.setExpression(".Placement.Base.y", "(%s) - (%s)" % (ac, D))
        b.setExpression(".Placement.Base.z", str(bc))
        return b

    def common(self, label, shapes, group=None):
        c = self._new("Part::MultiCommon", label, group)
        c.Shapes = shapes
        c.Refine = True
        for x in shapes:
            x.Visibility = False
        return c

    def wedge(self, label, x0, x1, y_edge, y_far, z_edge, z_far, far_is_max, group=None):
        """Triangular prism along x: a sharp edge at (y_edge, z_edge), a face from y_edge to
        y_far at height z_far. Used for the clip catch ramps."""
        w = self._new("Part::Wedge", label, group)
        # Local wedge axes after a -90 deg turn about X: local y = -world z, local z = world y.
        w.Placement.Rotation = App.Rotation(V(1, 0, 0), -90)
        lo, hi = "(%s)" % y_edge, "(%s)" % y_far
        if not far_is_max:
            lo, hi = hi, lo
        w.setExpression("Xmin", str(x0))
        w.setExpression("Xmax", str(x1))
        w.setExpression("X2min", str(x0))
        w.setExpression("X2max", str(x1))
        w.setExpression("Ymin", "-(%s)" % z_far)
        w.setExpression("Ymax", "-(%s)" % z_edge)
        w.setExpression("Zmin", lo)
        w.setExpression("Zmax", hi)
        w.setExpression("Z2min", "(%s)" % y_edge)
        w.setExpression("Z2max", "(%s)" % y_edge)
        return w


def build(variant):
    p = load_params(variant)
    d = Doc("case_wroom_u1_" + variant.replace("-", "_"))
    P = d.param

    # ---------------------------------------------------------------- spreadsheet
    d.section("Shell")
    WALL = P("Wall", p["WALL"], "wall thickness")
    FLOOR = P("Floor", p["FLOOR"], "floor thickness")
    LID = P("Lid", p["LID"], "lid thickness")
    GAP = P("Gap", p["GAP"], "board to wall clearance")
    STANDOFF = P("Standoff", p["STANDOFF"], "standoff height under the board")
    PCB_T = P("PcbT", p["PCB_T"], "board thickness")
    TALLEST = P("Tallest", 17.6, "tallest part on the board (relays)")
    TOP_CLEAR = P("TopClear", p["TOP_CLEAR"], "clearance above the tallest part")
    FIT = P("Fit", p["FIT"], "lid lip to wall clearance")
    R_OUT = P("ROuter", 3.0, "outer corner radius")
    R_IN = P("RInner", 1.0, "cavity corner radius")

    d.section("Board")
    BX = P("BoardX", p["BOARD_X"], "half board length (board centred on the origin)")
    BY = P("BoardY", p["BOARD_Y"], "half board width")
    CAV_W = P("CavityWest", p["X0"], "west cavity wall (USB-C sticks out)")
    CAV_Y = P("CavityYGap", p["Y1"] - p["BOARD_Y"], "cavity margin north/south")
    PCB_Z = P("PcbZ", "=%s + %s" % (FLOOR, STANDOFF), "board bottom (derived)")
    X0 = P("CavX0", "=" + CAV_W, "cavity x min (derived)")
    X1 = P("CavX1", "=%s + %s" % (BX, GAP), "cavity x max (derived)")
    Y0 = P("CavY0", "=-(%s + %s)" % (BY, CAV_Y), "cavity y min (derived)")
    Y1 = P("CavY1", "=%s + %s" % (BY, CAV_Y), "cavity y max (derived)")
    H = P("BaseH", "=%s + %s + %s" % (PCB_Z, TALLEST, TOP_CLEAR), "base height (derived)")
    OX0 = P("OutX0", "=%s - %s" % (X0, WALL), "outer x min (derived)")
    OX1 = P("OutX1", "=%s + %s" % (X1, WALL), "outer x max (derived)")
    OY0 = P("OutY0", "=%s - %s" % (Y0, WALL), "outer y min (derived)")
    OY1 = P("OutY1", "=%s + %s" % (Y1, WALL), "outer y max (derived)")

    d.section("Inserts and standoffs")
    INS_D = P("InsertBore", p["INSERT_BORE"], "M2.5 heat insert bore")
    INS_H = P("InsertDepth", p["INSERT_DEPTH"], "insert bore depth")
    SO_R = P("StandoffR", 3.2, "standoff radius")
    holes = []
    for i, (x, y) in enumerate(p["PCB_HOLES"]):
        holes.append((P("Hole%dX" % (i + 1), x, "board mounting hole"), P("Hole%dY" % (i + 1), y)))

    bosses = []
    if p["SCREW_BOSSES"]:
        d.section("Lid screws")
        BOSS_R = P("BossR", 3.4, "external screw boss radius")
        BOSS_X = P("BossX", abs(p["SCREW_BOSSES"][0][0]), "boss x (mirrored)")
        BOSS_OFF = P("BossOffset", 2.2, "boss centre outside the wall")
        LID_SCREW = P("LidScrew", p["LID_SCREW"], "M2.5 clearance hole in the lid")
        for sx in (-1, 1):
            for sy in (-1, 1):
                bx = ("-" if sx < 0 else "") + BOSS_X
                by = ("-(%s + %s + %s)" if sy < 0 else "%s + %s + %s") % (Y1, WALL, BOSS_OFF)
                bosses.append((bx, by, sy))

    d.section("Terminals")
    TERM_W = P("TermW", p["TERM_W"], "wire window width / lid hole diameter")
    PITCH = P("TermPitch", 5.08, "pole pitch")
    WIRE_Z0 = P("WireZ0", p["WIRE_Z"][0], "wire window bottom, above board bottom")
    WIRE_Z1 = P("WireZ1", p["WIRE_Z"][1], "wire window top, above board bottom")
    blocks = []
    names = ["P4", "P5", "P6", "P3", "P2", "P1", "P8", "P9"]
    terms = p["TERMINALS"]
    for bi in range(len(terms) // 3):
        (fx, fy), side = terms[bi * 3]
        axis = "x" if side in "NS" else "y"
        first = fx if axis == "x" else fy
        other = fy if axis == "x" else fx
        n = names[bi] if bi < len(names) else "B%d" % bi
        blocks.append((n, side, axis, P(n + "First", first, "first pole, %s wall" % side), P(n + "Other", other)))

    d.section("Connectors")
    USB_Y = P("UsbY", p["USB_C"][0], "USB-C centre y")
    USB_Z = P("UsbZ", p["USB_C"][1], "USB-C centre z above board bottom")
    USB_W = P("UsbW", 12.8, "USB-C window width")
    USB_H = P("UsbH", 7.2, "USB-C window height")
    USB_CH = P("UsbChamfer", 1.4, "USB-C window 45 deg corner chamfer")
    MDB_X0 = P("MdbX0", p["MDB"][0], "MDB connector x min")
    MDB_X1 = P("MdbX1", p["MDB"][1], "MDB connector x max")
    MDB_Z1 = P("MdbZ1", p["MDB"][3], "MDB connector top above board bottom")
    ANT_X = P("AntennaX", p["ANTENNA_X"], "U.FL cable slot, north wall")
    UART_X = P("UartX", p["UART_X"], "UART debug slot, north wall")
    UART_W = P("UartW", p["UART_W"], "UART debug slot width")
    if p["SMA"]:
        SMA_X = P("SmaX", p["SMA"][0], "SMA jack hole centre x, north wall")
        SMA_Z = P("SmaZ", p["SMA"][1], "SMA jack hole centre height")
        SMA_D = P("SmaD", p["SMA_D"], "SMA jack hole diameter (panel cutout 6.5)")
        SMA_CAP = P("SmaCap", p["SMA_CAP"], "teardrop cut-off above the hole top")
    led = []
    for i, (x, y) in enumerate(p["LEDS"]):
        led.append((P("Led%dX" % (i + 1), x, "LED window"), P("Led%dY" % (i + 1), y)))
    LED_D = P("LedD", 4.0, "LED window diameter")

    d.section("Ventilation")
    VENT_W = P("VentW", 1.6, "slot width (walls and lid)")
    VENT_PITCH = P("VentPitch", 5.0, "wall slot pitch")
    LVENT_PITCH = P("LidVentPitch", 3.2, "lid slot pitch")
    LVENT_L = P("LidVentL", 12.0, "lid slot length")
    LVENT_A = P("LidVentRelayX", 46.0, "first lid slot above the relays")
    LVENT_B = P("LidVentCentreX", -24.0, "first lid slot in the centre area")

    d.section("Clips")
    CLIP_W = P("ClipW", 8.0, "clip tab width")
    CLIP_T = P("ClipT", 1.2, "clip tab thickness")
    BUMP = P("Bump", 0.6, "catch height")
    CLIP_Z0 = P("ClipZ0", "=%s - 8" % H, "clip window bottom (derived)")
    CLIP_Z1 = P("ClipZ1", "=%s - 5.6" % H, "clip window top (derived)")
    clips = [P("Clip%dX" % (i + 1), x, "clip position") for i, x in enumerate(p["CLIP_X"])]
    LIP_D = P("LipD", 2.5, "lid lip depth")
    LIP_T = P("LipT", 1.6, "lid lip thickness")

    d.section("Mounting ears")
    EAR_T = P("EarT", 4.0, "ear thickness")
    EAR_L = P("EarL", 20.0, "ear length")
    EAR_HW = P("EarHalfW", 16.0, "ear half width")

    # ---------------------------------------------------------------- base
    base_g = d.folder("Base")
    steps = d.folder("Base steps", base_g)
    outer = d.rbox("Outer body", OX0, OX1, OY0, OY1, "0", H, R_OUT, steps)
    cavity = d.rbox("Cavity", X0, X1, Y0, Y1, FLOOR, "%s + 1" % H, R_IN, steps)
    shell = d.cut("1 Shell", outer, cavity, steps)

    adds = [shell]
    g = d.folder("2 Standoffs", steps)
    for i, (hx, hy) in enumerate(holes):
        adds.append(d.cyl("Standoff %d" % (i + 1), hx, hy, SO_R, "%s - 0.1" % FLOOR, PCB_Z, g))
    if bosses:
        g = d.folder("3 Screw bosses", steps)
        for i, (bx, by, sy) in enumerate(bosses):
            yw = ("%s - %s + 0.5" % (Y0, WALL)) if sy < 0 else ("%s + %s - 0.5" % (Y1, WALL))
            adds.append(d.cyl("Boss %d" % (i + 1), bx, by, BOSS_R, "0", H, g))
            lo, hi = (by, yw) if sy < 0 else (yw, by)
            adds.append(d.box("Boss %d web" % (i + 1), "%s - %s" % (bx, BOSS_R), "%s + %s" % (bx, BOSS_R),
                              lo, hi, "0", H, g))
    g = d.folder("4 Mounting ears", steps)
    ear_cuts = []
    for sgn, xw, nm in ((-1, OX0, "West"), (1, OX1, "East")):
        if sgn < 0:
            xa, xb = "%s - %s" % (xw, EAR_L), "%s + 2" % xw
        else:
            xa, xb = "%s - 2" % xw, "%s + %s" % (xw, EAR_L)
        adds.append(d.rbox("Ear " + nm, xa, xb, "-" + EAR_HW, EAR_HW, "0", EAR_T, R_OUT, g))
        xc = "(%s %s %s / 2)" % (xw, "-" if sgn < 0 else "+", EAR_L)
        ear_cuts.append(d.box("Ear %s M4 slot" % nm, "%s - 2.25" % xc, "%s + 2.25" % xc, "-2.75", "2.75",
                              "-1", "%s + 1" % EAR_T, g))
        for y in ("-2.75", "2.75"):
            ear_cuts.append(d.cyl("Ear %s M4 slot end" % nm, xc, y, "2.25", "-1", "%s + 1" % EAR_T, g))
        for y in (-11.0, 11.0):
            ear_cuts.append(d.box("Ear %s zip-tie slot" % nm, "%s - 4.5" % xc, "%s + 4.5" % xc,
                                  "%s - 1.6" % y, "%s + 1.6" % y, "-1", "%s + 1" % EAR_T, g))
    body = d.fuse("5 Body", adds, steps)

    cut_g = d.folder("6 Cuts", steps)
    cuts = list(ear_cuts)
    g = d.folder("Insert bores", cut_g)
    ins = [(hx, hy, PCB_Z) for hx, hy in holes] + [(bx, by, H) for bx, by, _ in bosses]
    for i, (x, y, top) in enumerate(ins):
        cuts.append(d.cyl("Insert bore %d" % (i + 1), x, y, "%s / 2" % INS_D, "%s - %s" % (top, INS_H),
                          "%s + 0.1" % top, g))
        cuts.append(d.cone("Insert lead-in %d" % (i + 1), x, y, "%s / 2" % INS_D, "%s / 2 + 0.4" % INS_D,
                           "%s - 0.4" % top, "0.4", g))

    def wall_plane(side):
        """plane, cut start, cut end of a window through the given wall."""
        if side == "S":
            return "xz", "%s - %s - 1" % (Y0, WALL), "%s + 1" % Y0
        if side == "N":
            return "xz", "%s - 1" % Y1, "%s + %s + 1" % (Y1, WALL)
        if side == "E":
            return "yz", "%s - 1" % X1, "%s + %s + 1" % (X1, WALL)
        return "yz", "%s - %s - 1" % (X0, WALL), "%s + 1" % X0

    def plain(label, plane, a0, a1, z0, z1, c0, c1, group):
        if plane == "xz":
            return d.box(label, a0, a1, c0, c1, z0, z1, group)
        return d.box(label, c0, c1, a0, a1, z0, z1, group)

    def peaked(label, side, a0, a1, z0, z1, group):
        """Window with a 45 deg pointed roof above z1."""
        plane, c0, c1 = wall_plane(side)
        g = d.folder(label + " parts", group)
        ac, half = "((%s) + (%s)) / 2" % (a0, a1), "((%s) - (%s)) / 2" % (a1, a0)
        return d.fuse(label, [plain(label + " body", plane, a0, a1, z0, z1, c0, c1, g),
                              d.diamond(label + " roof", plane, ac, z1, half, c0, c1, g)], group)

    def chamfered(label, side, a0, a1, z0, z1, c, group):
        """Window with 45 deg corner chamfers of leg c."""
        plane, c0, c1 = wall_plane(side)
        g = d.folder(label + " parts", group)
        ac, zc = "((%s) + (%s)) / 2" % (a0, a1), "((%s) + (%s)) / 2" % (z0, z1)
        D = "((%s) - (%s) + (%s) - (%s)) / 2 - (%s)" % (a1, a0, z1, z0, c)
        return d.common(label, [plain(label + " body", plane, a0, a1, z0, z1, c0, c1, g),
                                d.diamond(label + " corners", plane, ac, zc, D, c0, c1, g)], group)

    def wall(label, side, a0, a1, z0, z1, r, group):
        if side == "S":
            return d.rwindow(label, "xz", a0, a1, z0, z1, "%s - %s - 1" % (Y0, WALL), "%s + 1" % Y0, r, group)
        if side == "N":
            return d.rwindow(label, "xz", a0, a1, z0, z1, "%s - 1" % Y1, "%s + %s + 1" % (Y1, WALL), r, group)
        if side == "E":
            return d.rwindow(label, "yz", a0, a1, z0, z1, "%s - 1" % X1, "%s + %s + 1" % (X1, WALL), r, group)
        return d.rwindow(label, "yz", a0, a1, z0, z1, "%s - %s - 1" % (X0, WALL), "%s + 1" % X0, r, group)

    g = d.folder("Connectors", cut_g)
    cuts.append(chamfered("USB-C window", "W", "%s - %s / 2" % (USB_Y, USB_W), "%s + %s / 2" % (USB_Y, USB_W),
                          "%s + %s - %s / 2" % (PCB_Z, USB_Z, USB_H), "%s + %s + %s / 2" % (PCB_Z, USB_Z, USB_H),
                          USB_CH, g))
    # open to the wall rim (no bridge); the lid's MDB filler tab closes it above the plug
    cuts.append(wall("MDB slot", "S", "%s - 0.8" % MDB_X0, "%s + 0.8" % MDB_X1,
                     "%s + %s + 0.3" % (PCB_Z, PCB_T), "%s + 3" % H, "1.0", g))
    cuts.append(d.box("Antenna slot", "%s - 1.5" % ANT_X, "%s + 1.5" % ANT_X, "%s - 1" % Y1,
                      "%s + %s + 1" % (Y1, WALL), "%s - 2" % H, "%s + 1" % H, g))
    cuts.append(d.box("UART slot", "%s - %s / 2" % (UART_X, UART_W), "%s + %s / 2" % (UART_X, UART_W),
                      "%s - 1" % Y1, "%s + %s + 1" % (Y1, WALL), "%s - 2" % H, "%s + 1" % H, g))

    if p["SMA"]:
        # round hole plus a teardrop top cut off just above the circle (prints without support)
        plane, c0, c1 = wall_plane("N")
        sg = d.folder("SMA jack hole parts", g)
        r = "(%s / 2)" % SMA_D
        cap = d.common("SMA hole cap", [
            d.diamond("SMA hole cap diamond", plane, SMA_X, SMA_Z, "%s * 1.41421356" % r, c0, c1, sg),
            plain("SMA hole cap band", plane, "%s - %s" % (SMA_X, r), "%s + %s" % (SMA_X, r),
                  "%s + %s * 0.70710678" % (SMA_Z, r), "%s + %s + %s" % (SMA_Z, r, SMA_CAP), c0, c1, sg)], sg)
        cuts.append(d.fuse("SMA jack hole", [d.cyl("SMA hole", SMA_X, SMA_Z, r, c0, c1, sg, axis="y"), cap], g))

    g = d.folder("Terminal wire windows", cut_g)
    for n, side, axis, first, other in blocks:
        for i in range(3):
            a = "(%s + %d * %s)" % (first, i, PITCH)
            cuts.append(peaked("%s pole %d" % (n, i + 1), side, "%s - %s / 2" % (a, TERM_W),
                               "%s + %s / 2" % (a, TERM_W), "%s + %s" % (PCB_Z, WIRE_Z0),
                               "%s + %s" % (PCB_Z, WIRE_Z1), g))

    g = d.folder("Low vent slots", cut_g)
    boss_x = [bx for bx, _ in p["SCREW_BOSSES"]]
    for i in range(-14, 15):
        if any(abs(i * 5.0 - bx) < 5 for bx in boss_x):
            continue
        x = "(%d * %s)" % (i, VENT_PITCH)
        for side in "NS":
            cuts.append(peaked("Vent %s %+d" % (side, i), side, "%s - %s / 2" % (x, VENT_W),
                               "%s + %s / 2" % (x, VENT_W), "%s + 0.8" % FLOOR, "%s - 0.8" % PCB_Z, g))

    g = d.folder("Clip windows", cut_g)
    for i, cx in enumerate(clips):
        for side in "NS":
            cuts.append(wall("Clip window %s%d" % (side, i + 1), side, "%s - %s / 2 - 0.4" % (cx, CLIP_W),
                             "%s + %s / 2 + 0.4" % (cx, CLIP_W), CLIP_Z0, CLIP_Z1, "0.4", g))

    tools = d.fuse("All cuts", cuts, cut_g, refine=False)
    base = d.cut("Base", body, tools, base_g)
    base.Visibility = True

    # ---------------------------------------------------------------- lid
    lid_g = d.folder("Lid")
    lsteps = d.folder("Lid steps", lid_g)
    ladds = [d.rbox("1 Lid plate", OX0, OX1, OY0, OY1, H, "%s + %s" % (H, LID), R_OUT, lsteps)]
    if bosses:
        g = d.folder("2 Lid bosses", lsteps)
        for i, (bx, by, sy) in enumerate(bosses):
            yw = ("%s - %s + 0.5" % (Y0, WALL)) if sy < 0 else ("%s + %s - 0.5" % (Y1, WALL))
            ladds.append(d.cyl("Lid boss %d" % (i + 1), bx, by, BOSS_R, H, "%s + %s" % (H, LID), g))
            lo, hi = (by, yw) if sy < 0 else (yw, by)
            ladds.append(d.box("Lid boss %d web" % (i + 1), "%s - %s" % (bx, BOSS_R), "%s + %s" % (bx, BOSS_R),
                               lo, hi, H, "%s + %s" % (H, LID), g))

    g = d.folder("3 Lip", lsteps)
    lip_o = d.rbox("Lip outer", "%s + %s" % (X0, FIT), "%s - %s" % (X1, FIT), "%s + %s" % (Y0, FIT),
                   "%s - %s" % (Y1, FIT), "%s - %s" % (H, LIP_D), "%s + 0.01" % H, R_IN, g)
    lip_i = d.rbox("Lip inner", "%s + %s + %s" % (X0, FIT, LIP_T), "%s - %s - %s" % (X1, FIT, LIP_T),
                   "%s + %s + %s" % (Y0, FIT, LIP_T), "%s - %s - %s" % (Y1, FIT, LIP_T),
                   "%s - %s - 1" % (H, LIP_D), "%s + 1" % H, "0.5", g)
    lip = d.cut("Lip ring", lip_o, lip_i, g)
    rel = [d.box("Lip relief antenna", "%s - 2" % ANT_X, "%s + 2" % ANT_X, "%s - 3" % Y1, "%s + 1" % Y1,
                 "%s - %s - 1" % (H, LIP_D), "%s + 1" % H, g),
           d.box("Lip relief UART", "%s - %s / 2 - 0.5" % (UART_X, UART_W), "%s + %s / 2 + 0.5" % (UART_X, UART_W),
                 "%s - 3" % Y1, "%s + 1" % Y1, "%s - %s - 1" % (H, LIP_D), "%s + 1" % H, g)]
    for i, cx in enumerate(clips):
        for yw, s in ((Y0, "S"), (Y1, "N")):
            rel.append(d.box("Lip relief clip %s%d" % (s, i + 1), "%s - %s / 2 - 1" % (cx, CLIP_W),
                             "%s + %s / 2 + 1" % (cx, CLIP_W), "%s - 3" % yw, "%s + 3" % yw,
                             "%s - %s - 1" % (H, LIP_D), "%s + 1" % H, g))
    ladds.append(d.cut("Lip", lip, d.fuse("Lip reliefs", rel, g, refine=False), lsteps))
    ladds.append(d.box("MDB filler tab", "%s - 0.8 + %s" % (MDB_X0, FIT), "%s + 0.8 - %s" % (MDB_X1, FIT),
                       OY0, "%s + %s + 0.01" % (Y0, FIT), "%s + %s + 2" % (PCB_Z, MDB_Z1), "%s + 0.01" % H, g))

    g = d.folder("4 Clips", lsteps)
    for i, cx in enumerate(clips):
        for sgn, yw, s in ((-1, Y0, "S"), (1, Y1, "N")):
            if sgn < 0:
                y_out, y_in = "%s + %s" % (yw, FIT), "%s + %s + %s" % (yw, FIT, CLIP_T)
                ya, yb = y_out, y_in
                edge, far = "%s + 0.01" % y_out, "%s - %s" % (y_out, BUMP)
            else:
                y_out, y_in = "%s - %s" % (yw, FIT), "%s - %s - %s" % (yw, FIT, CLIP_T)
                ya, yb = y_in, y_out
                edge, far = "%s - 0.01" % y_out, "%s + %s" % (y_out, BUMP)
            ladds.append(d.box("Clip tab %s%d" % (s, i + 1), "%s - %s / 2" % (cx, CLIP_W), "%s + %s / 2" % (cx, CLIP_W),
                               ya, yb, "%s - 0.3" % CLIP_Z0, "%s + 0.01" % H, g))
            ladds.append(d.wedge("Clip catch %s%d" % (s, i + 1), "%s - %s / 2" % (cx, CLIP_W),
                                 "%s + %s / 2" % (cx, CLIP_W), edge, far, "%s - 0.1" % CLIP_Z0,
                                 "%s - 0.3" % CLIP_Z1, sgn > 0, g))
    lid_body = d.fuse("5 Lid body", ladds, lsteps)

    lcut_g = d.folder("6 Lid cuts", lsteps)
    lcuts = []
    top0, top1 = "%s - 1" % H, "%s + %s + 1" % (H, LID)
    if bosses:
        g = d.folder("Screw holes", lcut_g)
        for i, (bx, by, _) in enumerate(bosses):
            lcuts.append(d.cyl("Screw hole %d" % (i + 1), bx, by, "%s / 2" % LID_SCREW, top0, top1, g))
    g = d.folder("Terminal screwdriver holes", lcut_g)
    for n, side, axis, first, other in blocks:
        for i in range(3):
            a = "(%s + %d * %s)" % (first, i, PITCH)
            x, y = (a, other) if axis == "x" else (other, a)
            lcuts.append(d.cyl("%s hole %d" % (n, i + 1), x, y, "%s / 2" % TERM_W, top0, top1, g))
    g = d.folder("LED window", lcut_g)
    for i, (lx, ly) in enumerate(led):
        lcuts.append(d.cyl("LED %d" % (i + 1), lx, ly, "%s / 2" % LED_D, top0, top1, g))
    g = d.folder("Lid vent slots", lcut_g)
    for start, n, nm in ((LVENT_A, 6, "relays"), (LVENT_B, 8, "centre")):
        for i in range(n):
            x = "(%s + %d * %s)" % (start, i, LVENT_PITCH)
            lcuts.append(d.box("Vent %s %d" % (nm, i + 1), "%s - %s / 2" % (x, VENT_W), "%s + %s / 2" % (x, VENT_W),
                               "-%s / 2" % LVENT_L, "%s / 2" % LVENT_L, top0, top1, g))
    lid = d.cut("Lid", lid_body, d.fuse("All lid cuts", lcuts, lcut_g, refine=False), lid_g)
    lid.Visibility = True

    d.doc.recompute()
    bad = [o.Label for o in d.doc.Objects if "Invalid" in o.State or "Error" in o.State]
    if bad:
        raise RuntimeError("recompute failed: %s" % bad[:10])
    out = os.path.join(os.environ.get("FCSTD_OUT", os.path.join(HERE, variant)),
                       "case_wroom-u1-%s.FCStd" % variant)
    d.doc.saveAs(out)
    print("%s: base %.1f mm3, lid %.1f mm3, %d objects -> %s" % (
        variant, base.Shape.Volume, lid.Shape.Volume, len(d.doc.Objects), out))
    return d.doc


# freecadcmd treats extra arguments as files to open, so the variant comes from the environment.
for v in (os.environ.get("VARIANT", "").split() or ["clips", "screw-clips"]):
    build(v)
