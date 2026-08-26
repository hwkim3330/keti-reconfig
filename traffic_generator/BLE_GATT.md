# BLE GATT — KETI TSN demo (Android tablet controller)

The tablet (app **`com.keti.tsn.console`**, cloned from `keti_reconfig_console`)
is the BLE **central**; each demo node is a BLE **peripheral**. Wireless is
control-plane only — video and flood are wired; the tablet only ever *commands*
over BLE. This is the map the app uses to discover and drive everything.

## Nodes (D10 demo, 192.168.77.0/24 data net)

| Node | Role | BLE name | on air |
|---|---|---|---|
| Pi1 · Sender (192.168.77.11) | flood generator **+ D10 switch controller** (JSON-RPC to 192.168.100.2/.4) | `KETI-TRAFGEN-TX` | `pi-trafgen-ble.service` |
| Pi2 · Receiver (192.168.77.12) | 7" kiosk, plays the video (native cvlc) | `KETI-TRAFGEN-RX` | `pi-trafgen-ble.service` |
| Video Pi (192.168.77.10) | HD video → Pi2 | *(no BLE yet — TODO)* | `video-stream.service` |
| D10 switch 1 (192.168.100.2) | TSN switch (generation) | *(no BLE — reached via Pi1 JSON-RPC)* | WebStaX |
| D10 switch 2 (192.168.100.4) | TSN switch (recovery) | *(no BLE — reached via Pi1 JSON-RPC)* | WebStaX |

The two D10 switches have **no BLE**: only a Pi on 192.168.100.x reaches their
JSON-RPC, so **Pi1 (TX) is the bridge** — the tablet sends switch commands to
`KETI-TRAFGEN-TX`, which relays them to the D10s over `/api/d10/rpc`.

## Traffic-gen peripheral — `KETI-TRAFGEN-TX` / `-RX` (same GATT)

UUIDs spell KETI/TGEN. Implemented in `server/ble_gatt.py`, bridged to the
node's local HTTP API on :8080.

```
service   4b455449-5447-454e-0000-000000000000
  control 4b455449-5447-454e-0000-000000000001   write / write-no-response   UTF-8 command
  status  4b455449-5447-454e-0000-000000000002   notify                      compact JSON, ~2 Hz
```

**Control commands** (UTF-8 to the control characteristic):

| write | effect | status |
|---|---|---|
| `start` | start the flood | implemented |
| `stop` | stop it | implemented |
| `preset:<key>` | load a preset (`line_rate_1500`, `small_frame_stress`, `cbs_tc2_tc6`, …) | implemented |
| `user:<name>` | load a saved user preset | implemented |
| `cbs:on` / `cbs:off` · `cbs:mbps:<N>` | reserve/release the video queue.s CBS slice on SW2 Gi1/2 q6 | implemented |
| `frer:on/off` · `frer:alg:<vector|match>` | FRER instance 1 AdminActive/algorithm on both switches | implemented |
| `tas:on/off` · `tas:cycle:<us>` | TAS gate enable/cycle on SW2 Gi1/2 | implemented |
| `cut:<1|2>` / `restore:<1|2>` | shutdown/up ring port Gi1/4 or Gi1/6 on SW1 | implemented |

**Status notify** (JSON): flood `{mbps, pps, sent, running}` today; the D10 demo
should also carry `{frer, cbs, tas, links}` so the tablet's TSN-switch panel can
show live FRER/CBS/TAS state (Pi1 polls the D10 and folds it in).

## Switch-controller peripheral — `KETI-SWITCH1/2/3` (legacy ESP path)

Used by the ESP-based reconfig demo; the app still scans for these. On the D10
demo these are superseded by the Pi1 bridge above, but the GATT is kept.

```
service   9a1e0101-4d3b-4a2f-9c6e-3f1d7b8a2c40
  state   9a1e0102-4d3b-4a2f-9c6e-3f1d7b8a2c40   notify   switch state JSON
  control (write char on the same service)        write    UTF-8 command
```

| write | effect |
|---|---|
| `!SCHED:<port>:<preset>` | apply a built-in gate schedule (TAS) on a port |
| `!PORT:<port>:UP` / `:DOWN` | enable / disable a switch port |
| `!BASELINE` | clear gating on every scheduled port (undo, no factory reset) |
| `!SAVE` | write running-config to flash |

## Path peripheral — `KETI-PATH1` / `KETI-PATH2` (legacy ESP path)

```
service   9a1e0001-4d3b-4a2f-9c6e-3f1d7b8a2c40
  control 9a1e0002-4d3b-4a2f-9c6e-3f1d7b8a2c40   write   UTF-8 command
```

| write | effect |
|---|---|
| `!SET:FAULT` | cut the path (inject a link fault) |
| `!SET:NORMAL` | restore the path |

## ESP32 video peripheral (retired)

```
service   6b1e0001-4b2a-4f6d-9c3a-0f1e2d3c4b5a   (name KETI-LIDAR-CLOUD)
  6b1e0002 notify frame chunks · 6b1e0003 read geometry · 6b1e0004 status · 6b1e0005 IMU
```

## Tablet app model (keti_tsn_console)

- **Sequences** = the only control surface (Mode 0 normal / Mode 1-2 path down /
  switch port up-down). "Mode 3 both down" dropped — no path left for FRER.
- **Modules** = status only (no Cut buttons): the three Pis (Video / Sender /
  Receiver) + Path 1/2.
- **TSN switch** panel = D10 FRER/CBS/TAS state + gating (via the Pi1 bridge).
- FRER/CBS/TAS live in the switches' saved (startup) config, so sequences only
  flip links up/down; the shapers stay applied and are toggled, not rebuilt.
