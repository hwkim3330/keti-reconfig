# ACU / LiDAR console

An Android tablet console for the 2026 a2z vehicle's ACU and LiDAR harness, cloned from
`apps/keti_reconfig_console` and rebuilt around the design sheets in
`ACU_LiDAR_reference_images.zip` (five sheets: ACU1_IT, LIDAR_FRNT&REAR (Hummingbird),
LIDAR_ROOF_FRNT&REAR (Falcon K1), LIDAR_LH&RH, ACU2_NO).

Package id `com.keti.aculidar.console`, so it installs alongside the reconfig console rather
than replacing it. Verified on the SM-T736N (Galaxy Tab S7 FE, 1280×800 logical, landscape).

```
flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

## What it shows

**Vehicle** — the same data in three renderings, switched from the rail on the left:

- *Model* — the ROii glTF body from the reconfig console with the LiDARs, ACUs and display
  pinned on as hotspots. Labelled as a stand-in: the sheets contain no vehicle model, so the
  body is not the a2z vehicle. Anchors are in the glTF's own space (bbox 22.1 × 21.7 × 40.0
  about (-1.94, 11.28, -0.08): ground y ≈ 0.4, roof y ≈ 22, front bumper z ≈ +20).
- *3D* — a native axonometric schematic. Drag to orbit, double-tap to reset. Same projector as
  Plan; at pitch π/2 the vertical axis collapses and it becomes the plan drawing, so the toggle
  animates between them.
- *Plan* — top-down.

Underneath, the ten ACU_IT ports and the five ACU_NO camera jacks as two strips. Tapping
anything — a device, a port, a jack — opens it in the inspector on the right.

**ACU** — both board edges. ACU_IT as its three connectors with the sheet's port labels on the
cavities they belong to, plus the case panel (TOTAL I/O, USB-C, LAN 1-3). ACU_NO as its
faceplate: five dual FAKRA jacks with the coding dots, the 4-way LAN block, TOTAL I/O.

**Pinouts** — the wire tables: Falcon K1 CN1 (gauge, colour, signal, cavity plugs), Hummingbird
CN1 pin definitions, the ACU_IT differential pairs, and what little sheet 4 gives for the side
LiDARs. Wire colours are drawn as colour, not only named.

**Sheets** — the source images, zoomable, with the superseded revisions marked as such.

## Rules this console keeps

*A value is either sourced or visibly marked as not sourced.* Link rates the sheets never state
(the LiDAR ports) render muted and italic with a `not on sheet` chip and a note explaining what
they were inferred from.

*An unattached console does not draw a healthy vehicle.* The default mode is REFERENCE: the
harness is drawn as designed and no link is claimed up or down. The DEMO mode in the rail runs
scripted faults and stamps SIMULATED across the top; every rate under it is generated.

*Say where the sheets disagree.* Sheet 1 carries its port-label photo twice, and the two copies
disagree on ports 2-3 and 2-4. The later copy names 허밍버드 후방 twice and FalconK 후방 never,
leaving a LiDAR unconnected, so the console follows the earlier copy and says so on the ACU page.
Sheet 5 has the same problem with the TF camera names and the struck-out Orin A link. Both
revisions ship under **Sheets**.

*Say what the sheets do not answer.* The side LiDARs (LH/RH) have part numbers and outlines but
no ACU port and no signal table anywhere in the set. They are drawn unwired, and the inspector
says why rather than inventing a port.

One thing to settle on the bench: sheet 2 describes the TE 2387380 D1/D2 pair as
receive/transmit, sheet 3 as D−/D+. A single differential pair cannot be both.

## Layout

- `lib/core/reference.dart` — the entire transcription. Nothing else reads the sheets.
- `lib/core/theme.dart` — palette (`Tone`) and the shared `Panel` / `SectionTitle` / `Chip2`.
- `lib/providers/rig_provider.dart` — reference vs simulated mode, scenarios, link state.
- `lib/widgets/vehicle_plan.dart` — the projector and painter behind both native views.
- `lib/screens/` — shell, vehicle, ACU, pinouts, sheets, model.
- `test/reference_test.dart` — consistency checks on the transcription (unique ids, ports and
  devices pointing at each other, ten camera feeds two per jack, inferred values carrying a note).

## Notes for the next editor

Two traps already hit here:

- The tablet is **1280×800 logical**, not 2560×1600. Ten cells across the content column give
  ~33 px each, which truncates every Korean label to its first syllable — and the syllable that
  gets cut is the one saying front or rear. Hence two rows of five, and `FittedBox` rather than
  ellipsis in the cavity cells.
- `CrossAxisAlignment.stretch` on a `Row` inside a `ListView` hands every child an infinite
  height. Release builds do not assert; the ACU page just silently lost every container fill and
  half its rows, and logged nothing.
