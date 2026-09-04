// Path module: one fault-injection relay, driven straight from the Android tablet over BLE.
//
// This board is a BLE peripheral and nothing else. In the previous demo an ESP32 acted as a
// GATT *client* to reach these nodes, and that is exactly where the rig wedged: the Bluedroid
// client blocks with no timeout, and everything that was supposed to recover it lived in the
// same loop it had blocked. With the tablet as the only central, no ESP ever runs that code
// path again.
//
// Board: ESP32-S3 SuperMini (4MB flash, 2MB PSRAM, native USB).
#include <Arduino.h>
#include <BLE2902.h>
#include <BLEDevice.h>
#include <BLEServer.h>

// Signal to the injection relay. Level is set before the pin becomes an output so a reset
// cannot glitch the relay closed on the way up.
constexpr int kRelayPin = 13;
constexpr int kLedPin = 48;  // addressable WS2812; confirmed by tools/led_probe

constexpr uint32_t kHeartbeatMs = 1000;

// One firmware for every board: identity comes from the chip, not from a build flag, so the
// modules cannot be swapped by flashing the wrong file. An unknown board says so rather
// than claiming to be path 1.
//
// Six modules now. 1 and 2 are the original pair; 3 to 6 were added on 2026-09-03, each read off
// its USB serial descriptor, which the ESP32-S3 fills in with the same base MAC this table
// matches on. Verify the board agrees rather than trusting that: it prints its own identity
// every 5 s in loop(), and an entry pasted one digit wrong shows up as PATH-UNKNOWN.
struct KnownBoard {
  uint64_t mac;
  int pathIndex;
};
// Exactly one board per number. A second entry claiming a number already taken is the failure
// this table exists to prevent: both would advertise the same name and the tablet would connect
// to whichever it happened to see first. Add a number, do not double up on one.
const KnownBoard kBoards[] = {
    {0x288485'6F46E8ULL, 1},
    {0x288485'6F48E0ULL, 2},
    {0x288485'6F4A54ULL, 3},
    {0x288485'6F4868ULL, 4},
    {0x288485'6F299CULL, 5},
    {0x288485'6F4928ULL, 6},
};

static const char *kServiceUuid = "9a1e0001-4d3b-4a2f-9c6e-3f1d7b8a2c40";
static const char *kControlUuid = "9a1e0002-4d3b-4a2f-9c6e-3f1d7b8a2c40";

int pathIndex = 0;  // 0 = unidentified board
char identity[24] = "";
uint64_t boardMac = 0;
uint32_t lastAnnounce = 0;
bool faulted = false;
bool tabletConnected = false;
uint32_t sequenceNumber = 0;
uint32_t lastHeartbeat = 0;
BLECharacteristic *control = nullptr;

// The LED is driven only from loop(), never from a BLE callback. rgbLedWrite() goes through
// the RMT peripheral, and calling it from the Bluedroid callback task failed silently: the
// relay moved and the serial said FAULT while the LED stayed on its old colour.
//
// A plain, even blink. Two earlier attempts were worse: a brightness fade was invisible
// (perceived brightness is roughly logarithmic, so a 40-to-100% ramp reads as steady on a
// small bright LED), and a mostly-on wink read as a glitch rather than a rhythm.
//
// The blink is not about power. This LED draws single-digit milliamps against 40-100 mA for
// the board with BLE running. It is there because a steady LED and a frozen board look
// identical, and the rhythm is the only thing that says the firmware is still running.
//
// Two channels, one meaning each:
//   colour -- which module, and whether the path is cut. The modules on a bench are then told
//             apart without a label:
//
//               1  green    0,180,0
//               2  blue     0,0,210
//               3  white    150,150,150
//               4  magenta  170,0,170
//               5  cyan     0,150,150
//               6  yellow   180,180,0
//               -  alternating white and blue, one colour per blink
//               any red     220,0,0      path cut, whichever module it is
//
//             Red is spent on FAULT, so no numbered colour carries red enough to be mistaken for
//             it. Yellow is the edge of that rule and stays on the right side of it only because
//             its red and green are equal -- an amber, with red dominant, does read as a dim red
//             across a bench. That is also why an unidentified board no longer *is* amber.
//
//             Six steady hues is the ceiling with red reserved, and 6 spends the last one. So the
//             unidentified board stopped competing for a hue and moved to a different channel
//             instead: it changes colour between blinks. No numbered module ever does, so "the
//             one that keeps changing" is unmistakable, and it costs no hue at all. A seventh
//             module should take the same route rather than hunting for a seventh colour.
//   rate   -- whether the tablet is attached. Slow is connected, fast is running unattended.
//             Fault deliberately does not change the rate: it already has a colour, and
//             overloading the rate would cost the link indication.
void updateLed() {
  // Hoisted above the colour choice: an unidentified board alternates its colour once per blink,
  // so it needs to know how long a blink is.
  const uint32_t period = tabletConnected ? 2000 : 500;

  uint8_t r = 0, g = 0, b = 0;
  if (faulted) {
    r = 220;
  } else {
    switch (pathIndex) {
      case 1: g = 180; break;
      case 2: b = 210; break;
      case 3: r = 150; g = 150; b = 150; break;
      case 4: r = 170; b = 170; break;
      case 5: g = 150; b = 150; break;
      case 6: r = 180; g = 180; break;
      default:
        // Unidentified: alternate white and blue, one colour per blink. Its BLE name flags it
        // too, but this is the one anybody standing at the bench will notice first.
        if ((millis() / period) % 2 == 0) {
          r = g = b = 150;
        } else {
          b = 210;
        }
        break;
    }
  }

  // Slow blink at 2 s is calm enough to read as a state rather than an alarm, and still makes
  // a stopped board obvious within a couple of seconds. Unattended is four times faster, which
  // reads as searching without either rate looking irregular.
  const bool dark = (millis() % period) >= period / 2;

  if (dark) {
    rgbLedWrite(kLedPin, 0, 0, 0);
  } else {
    rgbLedWrite(kLedPin, r, g, b);
  }
}

void applyRelay() {
  digitalWrite(kRelayPin, faulted ? HIGH : LOW);
}

void notifyState(const char *event) {
  if (control == nullptr || !tabletConnected) return;
  char message[64];
  // The sequence number is what lets the tablet tell a quiet link from a dead one: a console
  // that only watches the GATT connection will show stale values as though they were current.
  snprintf(message, sizeof(message), "!STATE:%lu:%d:%s:%d:%s", (unsigned long)++sequenceNumber,
           pathIndex, faulted ? "FAULT" : "NORMAL", faulted ? 1 : 0, event);
  control->setValue(message);
  control->notify();
}

void setFaulted(bool value, const char *event) {
  faulted = value;
  applyRelay();
  // Printed straight after the pin moves, before the BLE notification is built, so the timestamp
  // is as close to the relay as this board can report. It exists so the rig can be measured from
  // outside the app: with several boards on USB, `tools/skew.py` compares when these lines arrive
  // and reports how far apart the modules actually moved. An app that measures only itself is not
  // evidence.
  Serial.printf("%lu EDGE %s %s %s\n", (unsigned long)millis(), identity,
                value ? "FAULT" : "NORMAL", event);
  notifyState(event);
}

class ServerCallbacks final : public BLEServerCallbacks {
  void onConnect(BLEServer *) override { tabletConnected = true; }
  void onDisconnect(BLEServer *server) override {
    tabletConnected = false;
    // A lost tablet must not leave the network cut. Whatever fault was being demonstrated,
    // the safe state is the one that keeps traffic flowing.
    setFaulted(false, "tablet_gone");
    server->startAdvertising();
  }
};

class ControlCallbacks final : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *characteristic) override {
    String command = characteristic->getValue();
    command.trim();
    if (command == "!SET:FAULT") {
      setFaulted(true, "remote");
    } else if (command == "!SET:NORMAL") {
      setFaulted(false, "remote");
    } else if (command == "!SYNC") {
      notifyState("sync");
    }
  }
};

void setup() {
  digitalWrite(kRelayPin, LOW);
  pinMode(kRelayPin, OUTPUT);
  Serial.begin(115200);

  const uint64_t mac = ESP.getEfuseMac();
  // getEfuseMac returns the address byte-reversed against how it is printed.
  uint64_t printed = 0;
  for (int i = 0; i < 6; ++i) printed = (printed << 8) | ((mac >> (8 * i)) & 0xFF);
  for (const auto &board : kBoards) {
    if (board.mac == printed) pathIndex = board.pathIndex;
  }

  char name[24];
  if (pathIndex == 0) {
    snprintf(name, sizeof(name), "KETI-PATH-UNKNOWN");
  } else {
    snprintf(name, sizeof(name), "KETI-PATH%d", pathIndex);
  }

  BLEDevice::init(name);
  BLEServer *server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());
  BLEService *service = server->createService(kServiceUuid);
  control = service->createCharacteristic(
      kControlUuid, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_WRITE |
                        BLECharacteristic::PROPERTY_WRITE_NR | BLECharacteristic::PROPERTY_NOTIFY);
  control->addDescriptor(new BLE2902());
  control->setCallbacks(new ControlCallbacks());
  service->start();

  BLEAdvertising *advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(kServiceUuid);
  advertising->setScanResponse(true);
  BLEDevice::startAdvertising();

  applyRelay();
  strncpy(identity, name, sizeof(identity) - 1);
  boardMac = printed;
}

void loop() {
  const uint32_t now = millis();
  updateLed();
  // Printed from loop(), not setup(): the native USB re-enumerates on reset, so anything
  // setup() prints is gone before a host can open the port. This is the only way to read back
  // which path a board decided it is.
  if (now - lastAnnounce >= 5000) {
    lastAnnounce = now;
    Serial.printf("%s  mac=%012llX  relay=GPIO%d %s  tablet=%s\n", identity, boardMac,
                  kRelayPin, faulted ? "FAULT" : "NORMAL", tabletConnected ? "yes" : "no");
  }
  if (now - lastHeartbeat >= kHeartbeatMs) {
    lastHeartbeat = now;
    notifyState("heartbeat");
  }
  delay(20);
}
