# Video-source Pi — HD video → Pi2 kiosk

The third Pi is the demo's **video source**: it streams a looping HD clip as
MPEG-TS over UDP to the receiver Pi's relay (`udp://192.168.1.7:5000`), which the
7" kiosk plays. This is the flow TSN is meant to protect from the flood.

## Design (why it's built this way)

- **Transcode once on a PC, stream with `-c copy` on the Pi.** The Pi does *no*
  re-encoding (~5% CPU) — a beefy machine prepares a 720p CBR MPEG-TS, the Pi
  just paces the bytes out with ffmpeg `-re`. Software x264 on the Pi was ~230%
  CPU and wasteful; there is no need to encode at runtime.
- **A long clip (full Big Buck Bunny, ~10 min) instead of a short loop.** A
  looped `-c copy` file replays its timestamps from the top each pass, so PTS/PCR
  jump backwards at the seam and mpegts.js freezes there. A 10-min clip simply
  never loops during a demo, sidestepping it. (For a short clip that must loop
  seamlessly, `pts_replay.py` rewrites PTS/PCR per loop instead — no re-encode,
  seamless — but ffmpeg `-re -c copy` on a long clip has steadier pacing.)
- **`repeat-headers=1`** in the transcode puts SPS/PPS before every keyframe so a
  kiosk joining mid-stream syncs within ~1s instead of waiting a whole loop.
- Content is **Big Buck Bunny (CC-BY, license-clean)**. Self-made driving/AV viz
  also works and is license-clean; third-party datasets (Alpamayo etc.) are fine
  for a local demo but must not be committed/redistributed.

## Prepare the clip (on a PC)

```bash
# full Big Buck Bunny -> 720p 2.5 Mbit/s CBR MPEG-TS, headers every keyframe
ffmpeg -i BigBuckBunny.mp4 \
  -vf "scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2,fps=30" \
  -c:v libx264 -preset veryfast -profile:v baseline -pix_fmt yuv420p \
  -x264-params "keyint=60:min-keyint=60:scenecut=0:repeat-headers=1" \
  -b:v 2500k -maxrate 2500k -bufsize 1500k -an -muxrate 2700k -f mpegts bbb.ts
scp bbb.ts keti@<video-pi>:/home/keti/bbb.ts
```

## Service on the Pi (autostart)

`/etc/systemd/system/video-stream.service` — adds the demo IP then streams:

```ini
[Unit]
Description=HD video (Big Buck Bunny, CC-BY) -> Pi2 kiosk
After=network-online.target
[Service]
ExecStartPre=/bin/sh -c "ip addr add 192.168.1.9/24 dev eth0 2>/dev/null; true"
ExecStart=/usr/bin/ffmpeg -hide_banner -loglevel error -re -stream_loop -1 -i /home/keti/bbb.ts -c copy -f mpegts udp://192.168.1.7:5000?pkt_size=1316
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
```

`sudo systemctl enable --now video-stream`. It survives reboot/power-loss and
re-streams on its own — no PC at runtime.

`pts_replay.py` (in this dir) is the alternative seamless-loop replayer for short
clips.
