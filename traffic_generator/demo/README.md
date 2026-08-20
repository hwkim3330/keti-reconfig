# TSN on/off demo — video survives a flood

The point of the whole rig in one picture: a **video** and a **background flood**
share one link through the **LAN9662**. With TSN **on**, the switch reserves a
slice for the video's class (CBS/TAS) and it keeps playing; with TSN **off**, the
flood starves it and the video stutters.

```
 Pi #1 (sender)                       LAN9662                    Pi #2 / tablet / PC
   video  (PCP 3, protected) ─┐                                   ┌─ ffplay udp://@:5000
   flood  (PCP 0, best effort)├──► port ──[CBS/TAS]──► port ──────┤
   pi-trafgen + stream_video   ┘      TSN on: video protected      └─ pi-trafgen rx / meters
                                      TSN off: video starved
```

## The contrast

| | TSN off (no gating) | TSN on (CBS on PCP 3) |
|---|---|---|
| flood | takes the whole link | capped below line rate |
| video | drops/stutters | smooth, its slice is reserved |

## Run it

**Sender (Pi #1):**
```bash
# background flood - best effort (PCP 0), fills the link
curl -s -X POST http://localhost:8080/api/preset/line_rate_1500
curl -s -X POST http://localhost:8080/api/start
# the protected video on PCP 3
./stream_video.sh <receiver_ip> ~/media/Big_Buck_Bunny_720_10s_5MB.mp4 3
```

**Receiver (Pi #2 / tablet / PC):**
```bash
ffplay -fflags nobuffer -flags low_delay udp://@:5000
```

**Toggle TSN on the 9662** (CBS on the video's PCP): apply from the reconfig
console (a schedule/CBS preset) or `mvdct`. Off = clear gating. Watch the video
go smooth ⇄ stutter as you toggle.

## What's needed vs what's here

- **Here now:** the sender side — `stream_video.sh` (ffmpeg, VLAN/PCP tagging) and
  the flood via pi-trafgen. The sample clip is on the Pi at
  `~/media/Big_Buck_Bunny_720_10s_5MB.mp4`.
- **Needed for the real contrast:** the **9662 in the data path** (sender → 9662 →
  receiver) and a **second endpoint** (2nd Pi, the tablet, or this PC). The QoS
  effect only appears at the bottleneck the switch creates — a direct sender→
  receiver cable has no contention to protect against.
- **Software-only preview (no switch):** the same effect can be shown with Linux
  `tc` on the Pi's egress — `tc qdisc ... cbs` (802.1Qav) or `taprio` (802.1Qbv)
  reserve the video class in software. Useful to rehearse before the HW is wired.
