# ACU / LiDAR console

An Android tablet console for the 2026 a2z vehicle's ACU and LiDAR harness, cloned from
`apps/keti_reconfig_console` and rebuilt around the design sheets in
`ACU_LiDAR_reference_images.zip` (five sheets: ACU1_IT, LIDAR_FRNT&REAR (Hummingbird),
LIDAR_ROOF_FRNT&REAR (Falcon K1), LIDAR_LH&RH, ACU2_NO), plus the KETI TSN backbone that gets
inserted into it.

Package id `com.keti.aculidar.console`, so it installs alongside the reconfig console rather
than replacing it. Verified on the SM-T736N (Galaxy Tab S7 FE, 1280×800 logical, landscape).

```
flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

## The four pages

**Vehicle** — one hero, three renderings of the same data, switched from a capsule floating over
it:

- *Model* — the ROii glTF body with the LiDARs, ACUs, switches and display pinned on. Labelled as
  a stand-in: the sheets contain no vehicle model. The body is genuinely translucent, on a
  slider — a material edit through model-viewer's API, because opaque it marks the interior
  hotspots occluded and fades out exactly the boxes worth looking at. Nothing moves by itself:
  no auto-rotate, no autoplay, no interaction prompt.
- *3D* — a native axonometric with every device modelled as a solid (see below). Drag to orbit,
  double-tap to reset.
- *Plan* — top-down. Same projector as *3D*; at pitch π/2 the vertical axis collapses, so the
  toggle animates between them rather than swapping widgets.

Under it, one port bar switched between the ten ACU_IT Ethernet ports and the five ACU_NO camera
jacks. Tapping anything — device, port, jack — opens the inspector drawer.

**Wiring** — the connection diagram: every box, every run between them, and the port number
riding the run. Two diagrams behind one toggle:

- *Sheet wiring* — the harness exactly as the sheets draw it. Every sensor straight into an ACU
  port; the two side LiDARs reaching for a port the document set never names.
- *With TSN backbone* — the KETI insertion. The three switches sit as a triangle with TSN-R on
  its own apex, because a column of three says nothing about which of them the traffic ends at.
  Three links between them, each with an inline injection module drawn on the link it opens and
  tappable. The cameras stay out of it: they run on their own coax into the Orin.

**Pinouts** — the wire tables: Falcon K1 CN1 (gauge, colour, signal, cavity plugs), Hummingbird
CN1 pin definitions, the ACU_IT differential pairs, and what little sheet 4 gives for the side
LiDARs. Wire colours are drawn as colour, not only named.

**Sheets** — the source images, zoomable, with the superseded revisions marked as such, under a
note saying where the sheets disagree.

## The vehicle model

`assets/roii_reconfig.glb` turned out not to be a GLB. It is a glTF JSON document with a base64
data-URI buffer, written by THREE.GLTFExporter out of the reconfig console's own scene. Of its
110 meshes exactly one is the vehicle — `textured_meshobj`, material `roii`, two baked JPEGs. The
other 109 are that project's overlay: ZC / ACU / TCU / Path boxes, a wireframe twin per device,
port stubs, connection tubes, and three `InlineESP` nodes named ESP_AB, ESP_AR and ESP_BR — the
three inter-switch modules, which is independent confirmation of the topology this console draws.

So the body was carrying another project's answer underneath ours, and a third of the file was
base64. `tools/repack_roii_body.py` keeps the body, prunes every accessor, view, texture and
image it does not use, and writes a real binary GLB:

```
python3 tools/repack_roii_body.py assets/roii_reconfig.glb assets/roii_body.glb
# kept 1 of 110 meshes, 1 of 110 materials, 40000 triangles
# 2.08 MB binary GLB (was 3.68 MB JSON)
```

Hotspots are placed from normalised coordinates — the same `pos` and height the native 3D view
reads out of `reference.dart` — resolved at load time against whatever body is loaded. Hard-coded
metres had to be re-probed every time the model changed and put every pin in a heap when they
were not.

If the body is ever rebuilt in Blender, what this app needs from it is: a binary `.glb`; the body
and nothing else, or named nodes (`BODY`, `GLASS`, `WHEEL`, `INTERIOR`) so parts can be hidden
instead of every material being alpha-blended at once; front on +Z, up on +Y; and real-world
scale. Triangle count is not the problem — the body is 40 k.

## Rules this console keeps

*A value is either sourced or visibly marked as not sourced.* Link rates the sheets never state
(the LiDAR ports) render muted and italic with a `not on sheet` chip and a note saying what they
were inferred from. The injection module on the A-to-B cross-link is expected but not confirmed
on the rig, so it is drawn amber with a question mark rather than as a fact.

*An unattached console does not draw a healthy vehicle.* The default is REFERENCE: the harness is
drawn as designed and no link is claimed up or down, and the injection modules will not fire. The
DEMO mode in the rail runs scripted faults and stamps SIMULATED across the top; every rate under
it is generated.

*Say where the sheets disagree.* Sheet 1 carries its port-label photo twice and the copies
disagree on ports 2-3 and 2-4; the later copy names 허밍버드 후방 twice and FalconK 후방 never,
leaving a LiDAR unconnected, so the console follows the earlier one and says so. Sheet 5 has the
same problem with the TF camera names and the struck-out Orin A link. Both revisions ship.

*Say what the sheets do not answer.* The side LiDARs have part numbers and outlines but no ACU
port and no signal table anywhere in the set. They are drawn unwired and the inspector says why.

*Keep the a2z document and the KETI insertion separable.* The switches and their links carry a
hue nothing on the sheets uses, are absent from the sheet-wiring diagram entirely, and say what
they are wherever they appear.

One thing to settle on the bench: sheet 2 describes the TE 2387380 D1/D2 pair as receive/transmit,
sheet 3 as D−/D+. A single differential pair cannot be both.

## Layout

- `lib/core/reference.dart` — the entire transcription, plus the TSN backbone. Nothing else reads
  the sheets.
- `lib/core/geom.dart` — the solid kit: V3, quads, boxes, extruded profiles, cylinders, face-on
  discs, an orthographic projector, and a painter's-algorithm draw. No renderer: the projection is
  orthographic and the parts are convex and separated, so sorting quads by centre depth is correct
  and costs nothing.
- `lib/core/theme.dart` — two surface families (paper for the transcription, hardware for the
  boards), one interaction colour used for selection and nothing else, device hues that never mean
  a state, state colours that never mean a device, and identifiers set monospaced with tabular
  figures because they are read as codes and compared down a column.
- `lib/widgets/device_meshes.dart` — each part built from a named picture: the ACU casting with
  its chamfered finned crown, the Hummingbird block with two stacked apertures and a fin stack
  down one flank, the Falcon K1 pod with the window let into its nose, the Hesai drum with its
  glass waist, the TSN switch with its port row. Devices are drawn 2.6× oversize and the view
  says so — at true scale an ACU is 6% of the vehicle's length and lands on ten pixels.
- `lib/widgets/vehicle_plan.dart` — the projector, the scene and the painter for the two native
  vehicle views.
- `lib/providers/rig_provider.dart` — reference vs simulated, scenarios, link state, and the cut
  state of the three injection modules.
- `lib/screens/` — shell, vehicle, wiring, pinouts, sheets, model.
- `test/reference_test.dart` — consistency checks on the transcription: unique ids, ports and
  devices pointing at each other, ten camera feeds two per jack, inferred values carrying a note.

## Notes for the next editor

Traps already hit here, in the order they cost the most time:

- `CrossAxisAlignment.stretch` on a `Row` inside a `ListView` hands every child an infinite
  height. Release builds do not assert; the page just silently loses its container fills and half
  its rows, and logs nothing. Impeller was suspected first and was innocent.
- The tablet is **1280×800 logical**, not 2560×1600. Ten cells across the content column give
  ~33 px each, which truncates every Korean label to its first syllable — and the syllable that
  gets cut is the one saying front or rear.
- `Mesh.cylinder` extrudes along z, so its caps lie flat. A socket on a vertical mating face needs
  `Mesh.disc`, or it renders as an ellipse lying on the floor.
- Build the mating face on **+y**. Built on −y it points away from the axonometric camera and the
  part renders as a row of blank blocks.
- glTF hotspot anchors have to be read off the model (`getDimensions`), not carried over from the
  sibling app: those were tuned against the other variant of this file and put every pin in a heap
  at mid-body.
- `adb install` failing is easy to miss when its output is piped to /dev/null; the app then keeps
  running the old build and the screenshots look identical for reasons that have nothing to do
  with the code.
