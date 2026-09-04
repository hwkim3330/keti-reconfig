#!/usr/bin/env python3
"""Measure how simultaneously the path modules actually move.

The tablet reports its own dispatch numbers, but an app that measures only itself is not
evidence. This watches the modules directly: every board prints an `EDGE` line the instant its
relay pin changes, so with several of them on USB the spread between those lines is the skew,
measured outside the thing being tested.

    tools/skew.py                  # watch every board that is plugged in
    tools/skew.py --for 120        # ...for two minutes
    tools/skew.py /dev/ttyACM1 /dev/ttyACM2

Then press CUT ALL (or a scenario button) on the tablet. Each group command prints one row.

What it can and cannot tell you. The timestamp is taken when the line *arrives at this host*, so
it carries USB CDC latency and this machine's scheduling -- expect a couple of milliseconds of
noise per board, and read the spread as an upper bound rather than a measurement of the relays
themselves. That is still the right shape of answer: if the reported spread is small, the true
one is smaller.
"""

import argparse
import glob
import subprocess
import sys
import threading
import time

BAUD = 115200
# Lines belonging to one command. Well above the ~15 ms connection interval the tablet asks for,
# well below anything a human could produce by pressing two buttons.
GROUP_WINDOW = 0.75


def esp_ports():
    """Serial ports that are an ESP32-S3, by USB descriptor rather than by name.

    Port numbers move with plug order and this machine has other CDC devices on ttyACM*; the
    vendor string is the only thing that does not lie about what a port is.
    """
    found = []
    for port in sorted(glob.glob('/dev/ttyACM*')):
        try:
            out = subprocess.run(['udevadm', 'info', '-q', 'property', '-n', port],
                                 capture_output=True, text=True, timeout=3).stdout
        except Exception:
            continue
        if 'ID_VENDOR_ID=303a' in out:
            found.append(port)
    return found


def reader(port, sink, stop):
    try:
        import serial
    except ImportError:
        print('pyserial is missing: pip3 install --break-system-packages pyserial', file=sys.stderr)
        stop.set()
        return
    try:
        handle = serial.Serial(port, BAUD, timeout=0.2)
    except Exception as exc:
        print(f'{port}: {exc}', file=sys.stderr)
        return
    with handle:
        while not stop.is_set():
            try:
                raw = handle.readline()
            except Exception:
                return
            if not raw:
                continue
            at = time.monotonic()
            text = raw.decode('utf8', 'replace').strip()
            if ' EDGE ' in text:
                parts = text.split()
                # <millis> EDGE <identity> <FAULT|NORMAL> <event>
                if len(parts) >= 5:
                    sink(at, parts[2], parts[3], parts[4])


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('ports', nargs='*', help='serial ports; default is every ESP32-S3 plugged in')
    ap.add_argument('--for', dest='seconds', type=float, default=0,
                    help='stop after this many seconds (default: until Ctrl-C)')
    args = ap.parse_args()

    ports = args.ports or esp_ports()
    if not ports:
        print('no ESP32-S3 serial ports found -- plug the modules in', file=sys.stderr)
        return 1

    print(f'watching {len(ports)} board(s): {" ".join(ports)}')
    print('press a group command on the tablet\n')

    lock = threading.Lock()
    pending = []          # [(arrival, identity, state)] for the group being collected
    last_at = [0.0]
    stop = threading.Event()

    def flush():
        """Print one row for the group that has just closed."""
        if not pending:
            return
        rows = sorted(pending, key=lambda r: r[0])
        pending.clear()
        first = rows[0][0]
        spread = (rows[-1][0] - first) * 1000
        states = {r[2] for r in rows}
        state = states.pop() if len(states) == 1 else 'MIXED'
        order = ' '.join(f'{r[1].replace("KETI-PATH", "")}+{(r[0] - first) * 1000:.0f}' for r in rows)
        print(f'{time.strftime("%H:%M:%S")}  {len(rows)} module(s)  {state:<6}'
              f'  spread {spread:6.1f} ms   [{order}]')

    def sink(at, identity, state, event):
        with lock:
            if pending and at - last_at[0] > GROUP_WINDOW:
                flush()
            pending.append((at, identity, state))
            last_at[0] = at

    threads = [threading.Thread(target=reader, args=(p, sink, stop), daemon=True) for p in ports]
    for t in threads:
        t.start()

    deadline = time.monotonic() + args.seconds if args.seconds else None
    try:
        while not stop.is_set():
            time.sleep(0.1)
            with lock:
                if pending and time.monotonic() - last_at[0] > GROUP_WINDOW:
                    flush()
            if deadline and time.monotonic() > deadline:
                break
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        with lock:
            flush()
    return 0


if __name__ == '__main__':
    sys.exit(main())
