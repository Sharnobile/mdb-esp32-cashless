"""WROOM-1U enclosure - LED light pipe (dome button + stem) for the lid LED window.

Print in clear/natural PLA. The stem carries the WS2812B light up through the lid and the
dome cap diffuses it. Fits both variants (same LED window and lid height).

Run from this folder:
  "C:\\Program Files\\FreeCAD 1.1\\bin\\freecadcmd.exe" build_led_pipe.py

Writes led_pipe.step and led_pipe.stl (STL flipped: cap face on the bed, stem up, no
supports). Checks the pipe against the board and the clips lid, prints the result.
"""
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

# Must match build_case.py
PCB_Z = 2.0 + 5.0                 # FLOOR + STANDOFF
H = PCB_Z + 17.6 + 1.4            # lid underside
LID = 2.0
LED = (-47.76, -3.43)             # WS2812B-2121 "LED D0", lid window is 4.0 mm
LED_TOP = PCB_Z + 1.52 + 0.9      # no LED model in the STEP: 2121 package is ~0.9 mm high

CAP_D, CAP_T, CAP_R = 8.0, 1.8, 0.9   # dome button on top of the lid, rounded top edge
NECK_D = 3.85                     # in the 4.0 window (printed ~3.9): snug, add a drop of glue if loose
STEM_D = 3.0                      # below the lid: clears the ESP32 module edge (y=-1.2) by 0.7 mm
TIP_GAP = 0.6                     # air gap above the LED

x, y = LED
z_tip = LED_TOP + TIP_GAP
stem = Part.makeCylinder(STEM_D / 2, H - z_tip, V(x, y, z_tip))
neck = Part.makeCylinder(NECK_D / 2, LID, V(x, y, H))
cap = Part.makeCylinder(CAP_D / 2, CAP_T, V(x, y, H + LID))
cap = cap.makeFillet(CAP_R, [e for e in cap.Edges if abs(e.BoundBox.ZMin - (H + LID + CAP_T)) < 1e-6])
pipe = stem.fuse(neck).fuse(cap).removeSplitter()
assert pipe.isValid() and len(pipe.Solids) == 1

# ---------------------------------------------------------------- checks
doc = App.newDocument("pcb")
Import.insert(os.path.join(HERE, "pcb_wroom-u1.step"), doc.Name)
hits = []
for o in doc.Objects:
    if o.TypeId == "Part::Feature" and o.Shape.Solids and o.Label != "mdb_slave_esp32s3-wroom-1u_PCB":
        s = o.Shape.copy()
        s.translate(V(0, 0, PCB_Z))
        if s.BoundBox.intersect(pipe.BoundBox) and pipe.common(s).Volume > 1e-3:
            hits.append(o.Label)
lid = Part.read(os.path.join(HERE, "clips", "lid.step"))
lid_overlap = pipe.common(lid).Volume
print(f"pipe: tip z={z_tip:.2f}, length {H + LID + CAP_T - z_tip:.2f} mm, volume {pipe.Volume:.1f} mm3")
print(f"lid top z={lid.BoundBox.ZMax:.2f} (cap seats at {H + LID:.2f}), overlap with lid {lid_overlap:.4f} mm3")
print("board collisions:", hits or "none")

# ---------------------------------------------------------------- export
pipe.exportStep(os.path.join(HERE, "led_pipe.step"))
flat = pipe.copy()
flat.rotate(V(x, y, 0), V(1, 0, 0), 180)
flat.translate(V(-x, -y, -flat.BoundBox.ZMin))
MeshPart.meshFromShape(flat, LinearDeflection=0.02, AngularDeflection=0.2).write(os.path.join(HERE, "led_pipe.stl"))
print("written led_pipe.step, led_pipe.stl")
