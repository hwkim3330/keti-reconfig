#!/usr/bin/env python3
"""Drive the rig from the tablet and watch the controller for gaps.

The previous demo failed by wedging under sustained operation, not by failing a single
action, so this cycles the RECON modes and checks the one thing a wedge breaks: the
controller's snapshot sequence has to keep advancing. A run that only proves each button
works once proves nothing about leaving the rig alone.

Usage: python3 tools/soak.py [minutes]
"""
import re
import subprocess
import sys
import time

import serial

CONTROLLER = "/dev/ttyACM3"
# The four RECON modes in the sequence rail, in screen order.
MODE_TAPS = [(347, 312), (347, 397), (347, 483), (347, 568)]
DWELL_S = 20
# The controller publishes every 2 s; ten seconds of silence is several missed snapshots.
SILENCE_LIMIT_S = 10

minutes = float(sys.argv[1]) if len(sys.argv) > 1 else 10
deadline = time.time() + minutes * 60

port = serial.Serial(CONTROLLER, 115200, timeout=1)
last_seen = time.time()
last_sequence = None
snapshots = 0
gaps = []
stalls = []
cycles = 0
next_tap = time.time()
mode = 0

print(f"soaking for {minutes:g} min, cycling modes every {DWELL_S}s")
while time.time() < deadline:
    line = port.readline().decode("utf8", "replace").strip()
    if line:
        found = re.search(r"interfaces \(SID \d+\): code (\d)\.(\d+), (\d+) bytes", line)
        if found:
            snapshots += 1
            last_seen = time.time()
        if "port(s) discovered" in line:
            count = int(line.split()[0])
            # The port list is discovered, so a changing count means a real change or a
            # truncated parse. Either is worth knowing about.
            if last_sequence is not None and count != last_sequence:
                gaps.append(f"port count {last_sequence} -> {count}")
            last_sequence = count
        if "refused" in line or "rejected" in line:
            gaps.append(line)

    if time.time() - last_seen > SILENCE_LIMIT_S:
        stalls.append(time.strftime("%H:%M:%S"))
        print(f"  STALL: no snapshot for {SILENCE_LIMIT_S}s at {stalls[-1]}", flush=True)
        last_seen = time.time()

    if time.time() >= next_tap:
        x, y = MODE_TAPS[mode % len(MODE_TAPS)]
        subprocess.run(["adb", "shell", "input", "tap", str(x), str(y)],
                       capture_output=True)
        print(f"  mode {mode % len(MODE_TAPS)} at {time.strftime('%H:%M:%S')}"
              f"  snapshots={snapshots}", flush=True)
        mode += 1
        if mode % len(MODE_TAPS) == 0:
            cycles += 1
        next_tap = time.time() + DWELL_S

print(f"\n=== soak done ===")
print(f"snapshots seen : {snapshots}")
print(f"mode changes   : {mode} ({cycles} full cycles)")
print(f"stalls         : {len(stalls)} {stalls if stalls else ''}")
print(f"anomalies      : {len(gaps)}")
for g in gaps[:10]:
    print(f"  {g}")
print("PASS" if not stalls and not gaps else "FAIL")
