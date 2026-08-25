#!/usr/bin/env python3
"""Seamless looping MPEG-TS UDP replayer for the video-source Pi.

ffmpeg `-stream_loop -1 -c copy` replays a file's timestamps from the top each
pass, so PTS/PCR jump *backwards* at the seam and mpegts.js (the kiosk player)
freezes there. Re-encoding fixes it but burns a couple CPU cores. This instead
copies the pre-transcoded bytes and, each loop, adds one clip's worth of 90 kHz
ticks to every PCR/PTS/DTS so the timeline stays monotonic - no re-encode, near
zero CPU, and a genuinely seamless loop. (Same trick the ESP firmware used.)

    pts_replay.py <clip.ts> <dst_ip> <dst_port> <mux_bps>
"""
import socket
import sys
import time

VIDEO_PID = 0x100          # ffmpeg mpegts default video PID
CHUNK = 1316               # 7 x 188-byte TS packets per datagram
MASK33 = 0x1FFFFFFFF


def add33(buf: bytearray, i: int, off: int) -> None:
    """Add off to the 5-byte PTS/DTS field at buf[i:], preserving marker bits."""
    v = (((buf[i] & 0x0E) << 29) | (buf[i + 1] << 22) |
         ((buf[i + 2] & 0xFE) << 14) | (buf[i + 3] << 7) | (buf[i + 4] >> 1))
    v = (v + off) & MASK33
    buf[i] = (buf[i] & 0xF0) | ((v >> 29) & 0x0E) | 0x01
    buf[i + 1] = (v >> 22) & 0xFF
    buf[i + 2] = ((v >> 14) & 0xFE) | 0x01
    buf[i + 3] = (v >> 7) & 0xFF
    buf[i + 4] = ((v << 1) & 0xFE) | 0x01


def rewrite(buf: bytearray, off: int) -> None:
    if not off:
        return
    n = len(buf)
    for i in range(0, n - 187, 188):
        if buf[i] != 0x47:
            continue
        pid = ((buf[i + 1] & 0x1F) << 8) | buf[i + 2]
        afc = (buf[i + 3] >> 4) & 3
        pusi = buf[i + 1] & 0x40
        idx = i + 4
        if afc in (2, 3):
            aflen = buf[i + 4]
            if aflen > 0 and (buf[i + 5] & 0x10):          # PCR present
                b = i + 6
                base = ((buf[b] << 25) | (buf[b + 1] << 17) | (buf[b + 2] << 9) |
                        (buf[b + 3] << 1) | (buf[b + 4] >> 7))
                base = (base + off) & MASK33
                buf[b] = (base >> 25) & 0xFF
                buf[b + 1] = (base >> 17) & 0xFF
                buf[b + 2] = (base >> 9) & 0xFF
                buf[b + 3] = (base >> 1) & 0xFF
                buf[b + 4] = ((base << 7) & 0x80) | (buf[b + 4] & 0x7F)
            idx = i + 5 + aflen
        if pusi and pid == VIDEO_PID and afc in (1, 3) and idx + 14 < i + 188:
            if buf[idx] == 0 and buf[idx + 1] == 0 and buf[idx + 2] == 1:  # PES start
                flags = (buf[idx + 7] >> 6) & 3
                if flags & 2:
                    add33(buf, idx + 9, off)               # PTS
                if flags == 3:
                    add33(buf, idx + 14, off)              # DTS


def main() -> None:
    clip, dst, port, mux = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
    data = open(clip, "rb").read()
    # a clip's PTS span = its byte-duration at the mux rate, in 90 kHz ticks
    ppl = int(round((len(data) * 8 / mux) * 90000))
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    off = 0
    epoch = time.monotonic()
    sent = 0
    while True:
        pos = 0
        while pos < len(data):
            n = CHUNK if len(data) - pos >= CHUNK else len(data) - pos
            buf = bytearray(data[pos:pos + n])
            rewrite(buf, off)
            s.sendto(buf, (dst, port))
            pos += n
            sent += n
            ahead = (sent * 8 / mux) - (time.monotonic() - epoch)   # pace to mux rate
            if ahead > 0:
                time.sleep(ahead)
        off += ppl                                                  # next loop, keep PTS rising


if __name__ == "__main__":
    main()
