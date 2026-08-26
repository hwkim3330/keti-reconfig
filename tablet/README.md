# KETI TSN Console — Android tablet app

Native shell (Kotlin + WebView) around the keti-reconfig unified console. One
tablet app controls **everything the 3 Pis do** — it loads `/manage` on the
sender Pi, which already fronts the flood generator (pktgen), the two Kontron
D10 switches (CBS / TAS / FRER / QoS via WebStaX JSON-RPC), and the video
receiver state. So the tablet only needs to reach one host over Wi-Fi.

- **Package**: `com.keti.reconfig.console`  ·  landscape, fullscreen kiosk.
- **First launch** asks for the sender-Pi IP (default `192.168.77.11:8080`);
  **long-press** anywhere to change it later. Stored in SharedPreferences.
- **Build**: `./gradlew :app:assembleDebug` (Gradle 8.14 / AGP 8.11.1 / JDK 17+).
  APK → `app/build/outputs/apk/debug/app-debug.apk`; `adb install -r` it.

The tablet must be on a network that can reach the Pi (the .77 demo net, or set
the Pi's Wi-Fi IP in the dialog).
