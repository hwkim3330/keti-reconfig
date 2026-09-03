# keti_launcher

The 7" tablet's **home screen**, and the BLE central for the **five path modules**.

Package `com.keti.tsn.launcher`, so it installs alongside the other consoles rather than
replacing them. Verified on the rig tablet: **Lenovo TB-8504F, Android 7.1.1 (API 25),
arm64, 2 GB RAM, 800×1280 @ 213 dpi**.

```
flutter build apk --release --split-per-abi --target-platform android-arm64
adb install -r -g build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
adb shell cmd package set-home-activity com.keti.tsn.launcher/.MainActivity
```

`-g` grants `ACCESS_FINE_LOCATION` up front. Without it the app asks on first run, and until it
is granted a BLE scan on this Android version returns **nothing at all, with no error**.

## Why a separate app

`keti_tsn_console` is the console for the Galaxy Tab S7 FE: a glTF vehicle in a WebView, a
native axonometric, live charts. None of that runs on a Snapdragon 425 with 2 GB of RAM, which
is what this tablet is. So this is not a port of that app with things switched off — it is the
one control surface the rig needs, drawn cheaply:

- no WebView, no `model_viewer_plus`, no charts, no 3D;
- one dependency, `flutter_blue_plus`. The app drawer, the launcher state and the runtime
  permissions all go through `MainActivity.kt` instead of a plugin each;
- flat dark surfaces — no gradients, no elevation shadows, no blurs anywhere;
- one 1 Hz timer for the whole screen rather than one per tile.

It cold-starts in about a second on that tablet.

## What it controls

Five fault-injection modules over GATT — see `firmware/path_module` and
`traffic_generator/BLE_GATT.md`:

```
service  9a1e0001-4d3b-4a2f-9c6e-3f1d7b8a2c40
control  9a1e0002-4d3b-4a2f-9c6e-3f1d7b8a2c40   write  !SET:FAULT | !SET:NORMAL | !SYNC
                                                notify !STATE:<seq>:<path>:<state>:<relay>:<event>
```

There is **no pairing and no key**: a command is a UTF-8 string written to a well-known handle.
That is why modules 3, 4 and 5 needed only a MAC-table entry in the firmware and a reflash to
join, and why one code path here reaches all of them. `pathCount` in `lib/rig.dart` is the only
number in this app that has to agree with the firmware's table.

Each module decides its own number from its eFuse MAC, so a board whose MAC is not in
`kBoards[]` advertises as `KETI-PATH-UNKNOWN`; the app says so in the log rather than guessing.

Tile colours match each board's LED, so the person holding the tablet and the person looking at
the bench are talking about the same module. The canonical table lives in the repo README; the
two places this app has to keep in step with it are `K.pathColours` in `lib/theme.dart` and
`pathCount` in `lib/rig.dart`.

| # | LED on the board | tile | note |
|---|---|---|---|
| 1 | 초록 | `#22C55E` | |
| 2 | 파랑 | `#3B82F6` | |
| 3 | 흰색 | `#E6EAF0` | 원래 시안이었다 — 초록/시안/파랑이 뭉쳐서 뺐다 |
| 4 | 마젠타 | `#D946EF` | |
| 5 | 시안 | `#06B6D4` | 3 을 흰색으로 빼서 생긴 자리 |
| 고장 | 빨강 | `#EF4444` | 어느 모듈이든 |
| 미등록 | 앰버 | — | `KETI-PATH-UNKNOWN` |

The colour is on the module's **name**, not only the dot next to it: at 10 dp the difference
between blue and cyan is a guess.

**A connection is not a link.** Every tile carries the module's sequence number and how long ago
it was heard. The modules heartbeat once a second while a central is attached; anything older
than four seconds is drawn as *응답 없음*, not redrawn at its last value. On disconnect the
firmware restores its own relay to NORMAL, so the last state we hold is known to be wrong from
that moment and is dropped rather than greyed out.

## Screen

- **Tiles** — one per module. The whole tile is the button; `CUT` / `RESTORE` is also its own
  target for anyone who wants to aim.
- **Scenario bar** — `전체 복구`, `n 만 절단`, `전체 절단`. `n 만 절단` restores every other
  module rather than adding to whatever was cut before it; a scenario button that depends on
  what was pressed before it is not a scenario button.
- **Banner** — appears only when a scan cannot work, with the fix attached: Bluetooth off (turns
  it on in place, rather than sending you into Settings — this app *is* the home screen),
  permission missing, location services off, or not the default home.
- **Log** — what happened and when. Kept off the home screen so the tiles answer one question.
- **앱** — the drawer, so the tablet is still a tablet. Loaded on first open, not at startup.

## Scan cadence

12 s scanning, 6 s idle. Android allows **five scan starts per 30 s** and past that quietly stops
returning results — no exception, no empty callback, just a rig that looks unpowered. The first
version of this app restarted the scan every 7 s because it treated `startScan()` returning as
the scan *finishing*; it returns as soon as the scan is running. Scanning state now comes from
`FlutterBluePlus.isScanning`, and the gap is timed from the scan actually stopping.

The scan is stopped before each connect. This tablet's controller is from 2017 and connecting
underneath a running scan is unreliable on it; the modules come up one at a time instead —
connect, resume the scan, find the next. A module that drops is reconnected straight to its
remembered address rather than waiting for a scan window, on a widening delay so that one held
by another central is not hammered.

## Known

- One central at a time. The older consoles also scan for `KETI-PATH1..3`; whichever central
  connects first holds the module, and the module stops advertising while held, so the loser sees
  nothing at all. If a tile stays at *연결 안 됨* while the board's serial says `tablet=yes`,
  something else has it — close that app, or pulse the board's EN line to make it drop and
  re-advertise (`dtr=False, rts=True, 0.3 s, rts=False` over its USB serial).
- A tile says which of the two failures it is: *광고는 잡힘* means the board is powered and in
  range and only the connect is pending, *광고 안 보임* means we have never heard it at all.
- **A board seated badly boots into download mode.** Its USB enumerates and esptool talks to it
  perfectly, so the chip looks healthy, but the app never runs: no LED, no serial, no
  advertisement. `boot:0x20 (DOWNLOAD(USB/UART0))` in the boot log instead of
  `boot:0x28 (SPI_FAST_FLASH_BOOT)` is the tell — GPIO0 is being held low. Reseat it.
