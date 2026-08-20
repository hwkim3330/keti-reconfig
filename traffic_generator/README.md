# Traffic generator (pi-trafgen)

A line-rate-ish traffic source for the TSN bench, built on the Linux kernel's
`pktgen`. It runs on a Raspberry Pi 4B, drives the Pi's gigabit `eth0`, and is
controlled two ways from the same server:

- **the tablet** (KETI Reconfig Console) over WiFi — a `Traffic` button on the
  console opens a live throughput screen;
- **a 7" touch LCD** wired to the Pi — the same UI in a Chromium kiosk.

Both talk to one FastAPI server on the Pi (`:8080`). The generator is a separate
IP node — it is **not** one of the BLE switch controllers. Keeping it on its own
box means its control traffic (WiFi) never rides the link being measured (`eth0`).

```
 tablet  ──WiFi──┐
                 ├──► FastAPI :8080 ──► /proc/net/pktgen ──► eth0 ──► LAN9662/9692
 7" LCD  ──HDMI──┘        (Pi 4B, root)
   (kiosk on the Pi)
```

## What it can actually push

A Pi 4B's `eth0` (`bcmgenet`) is real gigabit — not USB-bridged like the Pi 3 —
so big frames hit the wire at line rate. Small frames are CPU-bound:

| Frame | Line-rate pps | Pi 4B verdict |
|------:|--------------:|---------------|
| 1500 B | 81 k | ✓ 940 Mbps, trivial |
| 512 B  | 235 k | ✓ reachable with `clone_skb` + `burst` |
| 256 B  | 452 k | △ marginal |
| 64 B   | 1.49 M | ✗ CPU-bound (~300–500 kpps); this measures the ceiling, not line rate |

64 B line rate is not physically reachable on a Pi — that needs x86 + i210/i226
+ DPDK. The `64B stress` preset exists to measure the ceiling, and the UI labels
it as such rather than pretending.

## Requirements

`pktgen` must be a loadable module. **Ubuntu Server 24.04 arm64** ships it
(`modprobe pktgen` just works). Raspberry Pi OS is often built without
`CONFIG_NET_PKTGEN` — `install.sh` checks and tells you if so.

## Install (on the Pi, as root)

```bash
git clone https://github.com/hwkim3330/keti-reconfig.git
cd keti-reconfig/traffic_generator
sudo ./install.sh            # server only (tablet drives it over WiFi)
sudo ./install.sh --kiosk    # also launch the 7" LCD kiosk browser
```

The server lands in `/opt/pi-trafgen`, config in `/etc/pi-trafgen/config.json`,
and runs as a systemd unit. UI at `http://<pi>:8080/`.

Point the tablet at the Pi with the address button in the top bar of the Traffic
screen (default `172.31.51.228:8080`, the Pi as it appears on the KETI WiFi —
hostname `keti`).

## Presets

| Preset | What it sends |
|--------|---------------|
| `CBS TC2 + TC6` | 3.5 Mbps PCP 1 (→TC6) + 1.5 Mbps PCP 5 (→TC2), VLAN 100 |
| `1G line rate (1500B)` | one bulk stream, big frames, unthrottled |
| `1G line rate (512B)` | one bulk stream, 512 B, `clone_skb`+`burst` |
| `64B stress (4 cores)` | four cores hammering 64 B — ceiling test |
| `PCP sweep (0/2/4/6)` | four tagged 10 Mbps streams, one per PCP |
| `Background 100 Mbps` | untagged best-effort load to sit under a measurement |

The PCP→TC mapping matches the bench: PCP 0-3 → TC6, PCP 4-7 → TC2.

## Layout

```
traffic_generator/
  server/
    pktgen.py     # driver over /proc/net/pktgen (Stream + Runner)
    netstat.py    # sysfs TX-counter rate meter (adds back FCS+preamble+IFG)
    presets.py    # the canned stream sets above
    main.py       # FastAPI: REST + /ws live push
  web/            # dark kiosk UI (canvas chart, no external libs)
  systemd/        # pi-trafgen.service + optional kiosk unit
  install.sh
  requirements.txt
```

## Notes / gotchas

- `echo start > pgctrl` **blocks** until every thread stops. With `count 0`
  (run forever) that never returns, so the start write runs on its own thread
  and `stop` is written from the request handler. `Runner` handles this.
- `add_device eth0@0` creates a proc entry literally named `eth0@0`; the per-device
  parameter file is `/proc/net/pktgen/eth0@0`, not `.../eth0`.
- On-wire rate = `tx_bytes` + 24 B/frame (FCS 4 + preamble/SFD 8 + IFG 12); the
  sysfs counter sees none of that, so `netstat.py` adds it back.
- The systemd unit writes `stop` on shutdown — pktgen otherwise keeps blasting
  from inside the kernel after the server is gone.
