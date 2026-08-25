# BLE GATT — KETI TSN demo (for the Android tablet controller)

The tablet is the BLE **central**; each demo node is a BLE **peripheral**. This is
the map the tablet app uses to discover and control everything.

## Nodes

| Node | Role | BLE name | on air |
|---|---|---|---|
| Pi1 (192.168.1.195) | traffic / flood **sender** | `KETI-TRAFGEN-TX` | pi-trafgen-ble.service |
| Pi2 (192.168.1.7) | **receiver** + 7" kiosk | `KETI-TRAFGEN-RX` | pi-trafgen-ble.service |
| Video-source Pi (192.168.1.9) | HD video → Pi2 | *(no BLE yet — see below)* | video-stream.service |
| ESP32-S3 *(retired from demo)* | old video source | `KETI-LIDAR-CLOUD` | firmware |

## pi-trafgen peripheral (Pi1 = TX, Pi2 = RX — same GATT, different name)

The names spell KETI/TGEN in the UUID.

```
service   4b455449-5447-454e-0000-000000000000
  control 4b455449-5447-454e-0000-000000000001   write / write-no-response   UTF-8 command
  status  4b455449-5447-454e-0000-000000000002   notify                      compact JSON, ~2 Hz
```

**Control commands** (UTF-8 written to the control characteristic — bridged to the
node's local HTTP API on :8080):

| write | effect |
|---|---|
| `start` | start the generator (Pi1: the flood) |
| `stop` | stop it |
| `preset:<key>` | load a built-in preset (e.g. `preset:cbs_tc2_tc6`, `preset:line_rate_1500`) |
| `user:<name>` | load a saved user preset |

**Status notify** (JSON): live `{mbps, pps, sent, running, ...}` — the tablet plots this.

## ESP32 peripheral (retired — kept for reference)

```
service   6b1e0001-4b2a-4f6d-9c3a-0f1e2d3c4b5a   (name KETI-LIDAR-CLOUD)
  6b1e0002  notify   frame chunks
  6b1e0003  read     beam geometry JSON
  6b1e0004  read/notify  status line
  6b1e0005  notify   IMU
```

## TODO — video-source Pi BLE

The video-source Pi currently has **no BLE peripheral** (it just autostarts
`video-stream.service`). To let the tablet start/stop/switch the video, add a
small peripheral there advertising e.g. `KETI-VIDEO-SRC` with a control char that
runs `systemctl start/stop video-stream` (or switches the clip). Not built yet —
the video autostarts on boot, so it's optional for the core demo.
