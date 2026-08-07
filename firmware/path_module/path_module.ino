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

// One firmware for both boards: identity comes from the chip, not from a build flag, so the
// two modules cannot be swapped by flashing the wrong file. An unknown board says so rather
// than claiming to be path 1.
struct KnownBoard {
  uint64_t mac;
  int pathIndex;
};
const KnownBoard kBoards[] = {
    {0x288485'6F46E8ULL, 1},
    {0x288485'6F48E0ULL, 2},
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
// Colour and rhythm carry different things on purpose, so neither has to be waited out:
//   colour  -- which module this is, and whether it is faulted. Path 1 green, path 2 blue,
//              and red on either when the path is cut. Two modules on a bench are then
//              distinguishable without reading a label.
//   rhythm  -- whether the tablet is on the line. A slow breath means connected; a double
//              blink means running but unattended. Motion also separates a healthy board from
//              a frozen one showing a stale colour, which a steady LED cannot do.
void updateLed() {
  uint8_t r = 0, g = 0, b = 0;
  if (faulted) {
    r = 200;
  } else if (pathIndex == 2) {
    b = 170;
  } else {
    g = 170;  // path 1, and an unidentified board, which its BLE name already flags
  }

  uint32_t scale;
  if (tabletConnected) {
    // Triangle breath: the colour stays readable throughout rather than blinking out.
    const uint32_t phase = millis() % 3000;
    const uint32_t rise = phase < 1500 ? phase : 3000 - phase;
    scale = 40 + (rise * 60) / 1500;
  } else {
    const uint32_t phase = millis() % 2400;
    const bool on = phase < 250 || (phase >= 500 && phase < 750);
    scale = on ? 100 : 15;  // never fully dark: the board should still look powered
  }

  rgbLedWrite(kLedPin, uint8_t(r * scale / 100), uint8_t(g * scale / 100),
              uint8_t(b * scale / 100));
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
