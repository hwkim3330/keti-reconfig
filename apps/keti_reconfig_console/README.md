# KETI Reconfig Studio

ROII 3D vehicle architecture, Autoware sensor multimode and ESP32 inline fault-injection hardware are integrated in one PLEOS app.

`tools/build_reconfig_model.py` generates `roii_reconfig.glb` from the original ROII asset. It preserves the native split FrontZC, Path1/Path2 and connection meshes, and adds only the ESP-AB/AR/BR enclosures.

```bash
python3 tools/build_reconfig_model.py \
  apps/pleos_reconfig_console/lib/assets/roii.glb \
  apps/keti_reconfig_console/lib/assets/roii_reconfig.glb
```

## Run

Start the hardware bridge from the repository root:

```bash
./hardware/esp32_reconfig/bridge/run.sh --serial /dev/tty.usbmodem59580282341
```

Build, install and launch:

```bash
cd apps/keti_reconfig_console
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb shell am start \
  -n com.keti.reconfig.console/com.keti.reconfig.MainActivity
```

The applicationId (`com.keti.reconfig.console`) deliberately differs from the
Kotlin namespace so this build installs alongside a copy signed with a different
debug keystore instead of failing with INSTALL_FAILED_UPDATE_INCOMPATIBLE. That
is why the launch command needs the fully qualified activity class.

The emulator reaches the Mac bridge at `ws://10.0.2.2:8766`. The model rotates only when dragged and supports pinch/wheel zoom; automatic rotation is disabled. `Safe bypass` means no USB inline injector is armed. Physical relay actuation is disabled by default and must remain disabled until the normally-closed relay PCB and watchdog behavior are verified.
