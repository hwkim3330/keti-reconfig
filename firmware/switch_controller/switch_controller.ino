// ESP32-S3 + W5500 -> LAN9662/9692 CORECONF over Ethernet.
//
// Milestone here: ask the switch for its YANG catalog checksum with a real CoAP iFETCH and
// check it against the catalog the SID table was generated from. That single exchange
// exercises the whole stack -- Ethernet, CoAP, CBOR, SIDs -- and it is also the safety
// interlock for moving from the bench LAN9662 to the target LAN9692: SIDs belong to a
// catalog, so a table used against a different one addresses the wrong nodes and returns
// plausible nonsense. Refusing is the only honest response.
//
// Request shape taken from keti-tsn-cli (tsc2cbor/lib/coap/coap.js buildiFetchRequest):
// FETCH 0.05, Uri-Path "c", Content-Format 141, payload = CBOR array of SIDs.
#include <Arduino.h>
#include <BLE2902.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <ETH.h>
#include <NetworkUdp.h>

#include "coap_client.h"
#include "coreconf.h"
#include "sid_table.h"

constexpr int kSck = 48, kMosi = 21, kCs = 45, kMiso = 47;

// One firmware for every controller. Which switch a board serves, where that switch lives and
// which port the board is plugged into all come from the board's own MAC, so adding the second
// and third controllers is a line each rather than a separate build to keep in step.
struct ControllerConfig {
  uint64_t mac;          // as printed on the board, not as getEfuseMac returns it
  int switchIndex;       // becomes KETI-SWITCH<n>
  uint8_t selfAddress;   // last octet of this controller's own address
  uint8_t switchAddress; // last octet of its switch's management address
  const char *uplinkPort;  // the port this controller reaches the switch through
};
static const ControllerConfig kControllers[] = {
    {0x288485809BD0ULL, 1, 20, 12, "12"},
    // {0x............ULL, 2, 21, 22, "12"},
    // {0x............ULL, 3, 22, 32, "12"},
};

const IPAddress kMask(255, 255, 255, 0);
const IPAddress kGateway(192, 168, 1, 1);

// Filled in from the table at startup. An unrecognised board gets no addresses at all rather
// than borrowing switch 1's -- two controllers answering for the same switch would be worse
// than one that plainly does not work.
IPAddress kSelf(0, 0, 0, 0);
IPAddress kSwitch(0, 0, 0, 0);
const char *kProtectedPort = "";
int switchIndex = 0;
const uint16_t kCoapPort = 5683;

NetworkUDP udp;
uint16_t messageId = 1;

// The checksum comes back as CBOR {29304: h'...'}. Two details the first attempt at this got
// wrong, both visible in the wire dump: the switch sends an *indefinite-length* map (0xBF ...
// 0xFF), not a counted one, and the checksum is a byte string rather than text -- so it has
// to be rendered as hex, not copied out as characters.
bool extractChecksum(const uint8_t *payload, int length, char *out, size_t capacity) {
  int i = 0;
  if (i >= length) return false;
  if ((payload[i] >> 5) == 5) {                      // map, counted or indefinite
    ++i;
    if (i >= length) return false;
    const uint8_t keyInfo = payload[i] & 0x1F;       // step over the integer key
    ++i;
    if (keyInfo == 24) i += 1; else if (keyInfo == 25) i += 2; else if (keyInfo == 26) i += 4;
  }
  if (i >= length) return false;
  const uint8_t major = payload[i] >> 5;
  if (major != 2 && major != 3) return false;        // byte string or text string
  uint32_t stringLength = payload[i] & 0x1F;
  ++i;
  if (stringLength == 24) { stringLength = payload[i]; i += 1; }
  else if (stringLength == 25) { stringLength = (payload[i] << 8) | payload[i + 1]; i += 2; }
  if (i + int(stringLength) > length) return false;

  if (major == 3) {                                  // already text
    const uint32_t copied = min(stringLength, uint32_t(capacity - 1));
    memcpy(out, payload + i, copied);
    out[copied] = 0;
    return true;
  }
  if (stringLength * 2 + 1 > capacity) return false;  // hex needs two characters per byte
  for (uint32_t b = 0; b < stringLength; ++b) {
    snprintf(out + b * 2, 3, "%02x", payload[i + b]);
  }
  out[stringLength * 2] = 0;
  return true;
}

bool catalogMatches = false;
char deviceCatalog[64] = "";
char devicePlatform[64] = "";

// BLE: this board is a peripheral and never a central. The tablet is the only central in the
// rig, which is what keeps any ESP out of the GATT client code that wedged the previous demo.
static const char *kServiceUuid = "9a1e0101-4d3b-4a2f-9c6e-3f1d7b8a2c40";
static const char *kStateUuid = "9a1e0102-4d3b-4a2f-9c6e-3f1d7b8a2c40";

BLECharacteristic *stateCharacteristic = nullptr;
bool tabletConnected = false;
uint32_t sequenceNumber = 0;

// Set by the BLE callback, acted on in loop(). Writing from the callback would put a blocking
// network round trip inside the Bluedroid task, which is the shape that wedged the last rig.
// The uplink port is declared in the controller table above rather than detected: a board
// cannot see which port its own frames arrive on without walking the bridge FDB, and a guard
// that guesses is worse than one written down. It is published in every snapshot so the
// console keeps no second copy to fall out of step with.

struct GateWindowSpec { uint8_t mask; uint32_t intervalNs; };

// Schedules the console can ask for. Kept here rather than sent over BLE as raw entries: the
// controller owns the SID table and is the only thing that checked the catalog, so it is the
// only thing entitled to compose a write.
struct SchedulePreset {
  const char *id;
  uint32_t cycleNumerator;
  uint32_t cycleDenominator;
  int windowCount;
  GateWindowSpec windows[4];
};
static const SchedulePreset kPresets[] = {
    {"tc7", 1, 1000, 2, {{0x80, 500000}, {0xFF, 500000}}},
    {"strict", 1, 1000, 3, {{0x80, 250000}, {0x40, 250000}, {0xFF, 500000}}},
    {"fast", 1, 5000, 2, {{0x80, 100000}, {0xFF, 100000}}},
};

volatile bool pendingScheduleWrite = false;
String pendingSchedulePort;
String pendingScheduleId;

volatile bool pendingPortWrite = false;
bool pendingPortEnable = false;
String pendingPort;

void notifyLine(const char *line) {
  if (stateCharacteristic == nullptr || !tabletConnected) return;
  stateCharacteristic->setValue((uint8_t *)line, strlen(line));
  stateCharacteristic->notify();
  delay(6);  // let the stack drain; a burst of notifications otherwise outruns one interval
}

// One line per port, plus a header the tablet can use to tell a whole snapshot from a partial
// one. Every snapshot carries a sequence number: a console that watches only the GATT
// connection cannot tell a quiet link from a dead one, and will show stale counters as
// current -- which is exactly how the previous rig misled us.
void publishSnapshot(const PortTable &table, bool linkUp) {
  ++sequenceNumber;
  char line[192];
  snprintf(line, sizeof(line), "!SWITCH:%lu:%d:%s:%s:%s:%s", (unsigned long)sequenceNumber,
           table.count, linkUp ? "LINK" : "NOLINK", catalogMatches ? "CATALOG_OK" : "CATALOG_BAD",
           deviceCatalog, kProtectedPort);
  notifyLine(line);
  // The device names itself. A part number written into the console would be wrong the day the
  // LAN9692 replaces the bench LAN9662, with nothing to catch it.
  snprintf(line, sizeof(line), "!PLATFORM:%lu:%s", (unsigned long)sequenceNumber,
           devicePlatform[0] ? devicePlatform : "unknown");
  notifyLine(line);
  for (int i = 0; i < table.count; ++i) {
    const PortState &p = table.ports[i];
    snprintf(line, sizeof(line), "!PORT:%lu:%d:%s:%s:%llu:%llu:%llu:%llu:%llu:%llu:%llu:%llu",
             (unsigned long)sequenceNumber, i, p.name, p.operStatus == 1 ? "UP" : "DOWN",
             p.inOctets, p.outOctets, p.inUnicast, p.outUnicast, p.inErrors, p.outErrors,
             p.inDiscards, p.outDiscards);
    notifyLine(line);
    // Only ports with something to say. A snapshot was reaching forty notifications across
    // thirteen ports, each paced by 6 ms, and the tail of that burst was being dropped -- the
    // speed line simply never arrived. A down port has no speed, no traffic and, unless it is
    // scheduled, nothing to report.
    if (p.operStatus == 1 || p.fcsErrors || p.oversizeFrames || p.undersizeFrames) {
      snprintf(line, sizeof(line), "!ETH:%lu:%s:%lu:%llu:%llu:%llu",
               (unsigned long)sequenceNumber, p.name, (unsigned long)p.speedMbps, p.fcsErrors,
               p.oversizeFrames, p.undersizeFrames);
      notifyLine(line);
    }
    if (p.tasSeen && (p.gateEnabled || p.gateCount > 0)) {
      const uint64_t cycleNs = p.cycleDenominator == 0
                                   ? 0
                                   : (p.cycleNumerator * 1000000000ULL) / p.cycleDenominator;
      snprintf(line, sizeof(line), "!TAS:%lu:%s:%s:%llu:%llu", (unsigned long)sequenceNumber,
               p.name, p.gateEnabled ? "ON" : "OFF", cycleNs, p.gateStates);
      notifyLine(line);
      if (p.gateCount > 0) {
        // !GCL:<seq>:<port>:<mask>,<ns>;<mask>,<ns>;...
        char gcl[192];
        int used = snprintf(gcl, sizeof(gcl), "!GCL:%lu:%s:", (unsigned long)sequenceNumber,
                            p.name);
        for (int g = 0; g < p.gateCount && used < int(sizeof(gcl)) - 24; ++g) {
          used += snprintf(gcl + used, sizeof(gcl) - used, "%s%u,%llu", g == 0 ? "" : ";",
                           p.gateMask[g], p.gateInterval[g]);
        }
        notifyLine(gcl);
      }
    }
  }
}

// Commands from the tablet. Kept to a shape the console can form without knowing any SIDs --
// the controller owns the SID table, and it is the only thing that checked the catalog.
class ControlCallbacks final : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *characteristic) override {
    String command = characteristic->getValue();
    command.trim();
    // !SCHED:<port>:<preset|off>
    if (command.startsWith("!SCHED:")) {
      const int separator = command.indexOf(':', 7);
      if (separator < 0) return;
      if (!catalogMatches) {
        notifyLine("!ACK:SCHED:REFUSED:catalog mismatch");
        return;
      }
      const String port = command.substring(7, separator);
      // Same reasoning as refusing to disable this port, and the gap the last commit left
      // open: a schedule that closes the gates the management traffic uses would starve the
      // link this controller depends on, and it could not undo that. Scheduling the uplink is
      // refused outright rather than inspected -- deciding which schedules are survivable is
      // a judgement the demo does not need to make.
      if (port == kProtectedPort) {
        notifyLine("!ACK:SCHED:REFUSED:that is the controller's own uplink");
        Serial.printf("refused: schedule on port %s would gate this controller's link\n",
                      port.c_str());
        return;
      }
      pendingSchedulePort = port;
      pendingScheduleId = command.substring(separator + 1);
      pendingScheduleWrite = true;
      return;
    }
    // !PORT:<name>:<UP|DOWN>
    if (!command.startsWith("!PORT:")) return;
    const int separator = command.indexOf(':', 6);
    if (separator < 0) return;
    const String name = command.substring(6, separator);
    const bool enable = command.substring(separator + 1) == "UP";
    // Refuse rather than write against a catalog the SID table was not built for: the SIDs
    // would land on different nodes and the switch would accept a change nobody asked for.
    if (!catalogMatches) {
      notifyLine("!ACK:PORT:REFUSED:catalog mismatch");
      return;
    }
    if (!enable && name == kProtectedPort) {
      notifyLine("!ACK:PORT:REFUSED:that is the controller's own uplink");
      Serial.printf("refused: port %s carries this controller's link\n", name.c_str());
      return;
    }
    pendingPort = name;
    pendingPortEnable = enable;
    pendingPortWrite = true;
  }
};

class ServerCallbacks final : public BLEServerCallbacks {
  void onConnect(BLEServer *) override { tabletConnected = true; }
  void onDisconnect(BLEServer *server) override {
    tabletConnected = false;
    server->startAdvertising();
  }
};

char bleName[24] = "KETI-SWITCH-UNKNOWN";

void setup() {
  Serial.begin(115200);
  delay(1500);
  Serial.println("\n=== KETI switch controller ===");

  // Identity first: everything below depends on which switch this board serves.
  uint64_t printedMac = 0;
  {
    const uint64_t mac = ESP.getEfuseMac();
    for (int i = 0; i < 6; ++i) printedMac = (printedMac << 8) | ((mac >> (8 * i)) & 0xFF);
  }
  for (const auto &c : kControllers) {
    if (c.mac != printedMac) continue;
    switchIndex = c.switchIndex;
    kSelf = IPAddress(192, 168, 1, c.selfAddress);
    kSwitch = IPAddress(192, 168, 1, c.switchAddress);
    kProtectedPort = c.uplinkPort;
    snprintf(bleName, sizeof(bleName), "KETI-SWITCH%d", switchIndex);
  }
  Serial.printf("identity: %s (mac %012llX)\n", bleName, printedMac);
  if (switchIndex == 0) {
    // Advertise anyway so the board is findable and obviously wrong, but do not touch the
    // network: a board with no entry has no business claiming an address.
    Serial.println("this board is not in the controller table -- add its MAC to serve a switch");
  }
  Serial.printf("SID table built from catalog %s (%d entries)\n", KETI_SID_CATALOG_CHECKSUM,
                kKetiSidCount);

  if (switchIndex == 0) return;
  if (!ETH.begin(ETH_PHY_W5500, 1, kCs, -1, -1, SPI2_HOST, kSck, kMiso, kMosi)) {
    Serial.println("ETH.begin failed");
    return;
  }
  ETH.config(kSelf, kGateway, kMask);
  for (int i = 0; i < 40 && !ETH.linkUp(); ++i) delay(100);
  Serial.printf("link %s, IP %s\n", ETH.linkUp() ? "UP" : "DOWN",
                ETH.localIP().toString().c_str());
  udp.begin(kCoapPort + 1);

  BLEDevice::init(bleName);
  BLEServer *server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());
  BLEService *service = server->createService(kServiceUuid);
  stateCharacteristic = service->createCharacteristic(
      kStateUuid, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY |
                      BLECharacteristic::PROPERTY_WRITE |
                      BLECharacteristic::PROPERTY_WRITE_NR);
  stateCharacteristic->addDescriptor(new BLE2902());
  stateCharacteristic->setCallbacks(new ControlCallbacks());
  service->start();
  BLEAdvertising *advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(kServiceUuid);
  advertising->setScanResponse(true);
  BLEDevice::startAdvertising();
  Serial.println("BLE advertising as KETI-SWITCH");
}

void loop() {
  static uint8_t payload[8192];
  uint8_t code = 0;
  int blocks = 0;
  const int n = fetchSid(KETI_SID_YANG_CHECKSUM, payload, sizeof(payload), &code, &blocks);

  if (n < 0) {
    Serial.println("checksum fetch: no answer");
  } else {
    Serial.printf("checksum fetch: code %d.%02d, %d payload bytes in %d block(s)\n", code >> 5,
                  code & 0x1F, n, blocks);
    char reported[64] = "";
    if (extractChecksum(payload, n, reported, sizeof(reported))) {
      catalogMatches = strcmp(reported, KETI_SID_CATALOG_CHECKSUM) == 0;
      strncpy(deviceCatalog, reported, sizeof(deviceCatalog) - 1);
      Serial.printf("  device catalog %s -> %s\n", reported,
                    catalogMatches ? "MATCHES the SID table"
                                   : "DIFFERENT -- SID table must not be used");
    } else {
      Serial.print("  raw: ");
      for (int i = 0; i < n && i < 48; ++i) Serial.printf("%02X ", payload[i]);
      Serial.println();
    }
  }
  if (catalogMatches && devicePlatform[0] == 0) {
    int platformBlocks = 0;
    const int pn = fetchSid(ketiSidFor("ietf-system:system-state/platform"), payload,
                            sizeof(payload), &code, &platformBlocks);
    Serial.printf("platform fetch: sid %lu, code %d.%02d, %d bytes\n",
                  (unsigned long)ketiSidFor("ietf-system:system-state/platform"), code >> 5,
                  code & 0x1F, pn);
    if (pn > 0) {
      Serial.print("  raw: ");
      for (int i = 0; i < pn && i < 40; ++i) Serial.printf("%02X ", payload[i]);
      Serial.println();
      char machine[64] = "";
      if (coreconfMachine(payload, pn, ketiSidFor("ietf-system:system-state/platform/machine"),
                          machine, sizeof(machine))) {
        strncpy(devicePlatform, machine, sizeof(devicePlatform) - 1);
        Serial.printf("platform: %s\n", devicePlatform);
      } else {
        Serial.println("  machine string not found");
      }
    }
  }

  if (pendingScheduleWrite) {
    pendingScheduleWrite = false;
    const char *port = pendingSchedulePort.c_str();
    const char *base = "ietf-interfaces:interfaces/interface/ieee802-dot1q-bridge:bridge-port/"
                       "ieee802-dot1q-sched-bridge:gate-parameter-table";
    char path[220];
    uint8_t buffer[192];
    uint8_t patchCode = 0;
    bool ok = true;

    if (pendingScheduleId == "off") {
      snprintf(path, sizeof(path), "%s/gate-enabled", base);
      ok = patchRaw(buffer, buildPatchBool(buffer, ketiSidFor(path), port, false), &patchCode);
      snprintf(path, sizeof(path), "%s/config-change", base);
      ok = patchRaw(buffer, buildPatchBool(buffer, ketiSidFor(path), port, true), &patchCode) && ok;
    } else {
      const SchedulePreset *preset = nullptr;
      for (const auto &p : kPresets) {
        if (pendingScheduleId == p.id) preset = &p;
      }
      if (preset == nullptr) {
        notifyLine("!ACK:SCHED:REFUSED:unknown preset");
        ok = false;
      } else {
        // The control list, then the cycle, then enable, then the change trigger -- the order
        // the CLI uses. config-change last is what makes the switch adopt the admin list.
        size_t n = 0;
        n += cborUint(buffer + n, 1, 5);
        n += cborUint(buffer + n, 2, 4);
        snprintf(path, sizeof(path), "%s/admin-control-list/gate-control-entry", base);
        n += cborUint(buffer + n, ketiSidFor(path), 0);
        const size_t keyLength = strlen(port);
        n += cborUint(buffer + n, keyLength, 3);
        memcpy(buffer + n, port, keyLength);
        n += keyLength;
        n += cborUint(buffer + n, preset->windowCount, 4);
        for (int i = 0; i < preset->windowCount; ++i) {
          n += cborUint(buffer + n, 4, 5);       // map of four leaves
          n += cborUint(buffer + n, 2, 0);       // delta 2 -> index
          n += cborUint(buffer + n, i, 0);
          n += cborUint(buffer + n, 3, 0);       // delta 3 -> operation-name
          n += cborUint(buffer + n, 23003, 0);   // identity: set-gate-states
          n += cborUint(buffer + n, 4, 0);       // delta 4 -> time-interval-value
          n += cborUint(buffer + n, preset->windows[i].intervalNs, 0);
          n += cborUint(buffer + n, 1, 0);       // delta 1 -> gate-states-value
          n += cborUint(buffer + n, preset->windows[i].mask, 0);
        }
        ok = patchRaw(buffer, n, &patchCode);

        snprintf(path, sizeof(path), "%s/admin-cycle-time/numerator", base);
        ok = patchRaw(buffer, buildPatchUint(buffer, ketiSidFor(path), port,
                                             preset->cycleNumerator), &patchCode) && ok;
        snprintf(path, sizeof(path), "%s/admin-cycle-time/denominator", base);
        ok = patchRaw(buffer, buildPatchUint(buffer, ketiSidFor(path), port,
                                             preset->cycleDenominator), &patchCode) && ok;
        snprintf(path, sizeof(path), "%s/gate-enabled", base);
        ok = patchRaw(buffer, buildPatchBool(buffer, ketiSidFor(path), port, true),
                      &patchCode) && ok;
        snprintf(path, sizeof(path), "%s/config-change", base);
        ok = patchRaw(buffer, buildPatchBool(buffer, ketiSidFor(path), port, true),
                      &patchCode) && ok;
      }
    }

    Serial.printf("schedule %s -> %s: %s (last code %d.%02d)\n", port,
                  pendingScheduleId.c_str(), ok ? "accepted" : "rejected", patchCode >> 5,
                  patchCode & 0x1F);
    char ack[96];
    snprintf(ack, sizeof(ack), "!ACK:SCHED:%s:%s:%d.%02d", port, ok ? "OK" : "FAIL",
             patchCode >> 5, patchCode & 0x1F);
    notifyLine(ack);
  }

  if (pendingPortWrite) {
    pendingPortWrite = false;
    uint8_t patchCode = 0;
    const bool ok =
        patchListLeafBool(pendingPort.c_str(),
                          ketiSidFor("ietf-interfaces:interfaces/interface/enabled"),
                          pendingPortEnable, &patchCode, true);
    Serial.printf("iPATCH port %s -> %s: code %d.%02d (%s)\n", pendingPort.c_str(),
                  pendingPortEnable ? "UP" : "DOWN", patchCode >> 5, patchCode & 0x1F,
                  ok ? "accepted" : "rejected");
    char ack[96];
    snprintf(ack, sizeof(ack), "!ACK:PORT:%s:%s:%d.%02d", pendingPort.c_str(),
             ok ? "OK" : "FAIL", patchCode >> 5, patchCode & 0x1F);
    notifyLine(ack);
  }

  // The interface subtree is the dashboard's actual source of data, and it is far too large
  // for one datagram -- this is what the block assembly above exists for.
  if (catalogMatches) {
    const uint32_t sid = ketiSidFor("ietf-interfaces:interfaces");
    int interfaceBlocks = 0;
    const int m = fetchSid(sid, payload, sizeof(payload), &code, &interfaceBlocks);
    Serial.printf("interfaces (SID %lu): code %d.%02d, %d bytes in %d block(s)\n",
                  (unsigned long)sid, code >> 5, code & 0x1F, m, interfaceBlocks);
    if (m > 0) {
      static PortTable table;
      if (parseInterfaces(payload, m, &table)) {
        Serial.printf("  %d port(s) discovered\n", table.count);
        for (int i = 0; i < table.count; ++i) {
          const PortState &p = table.ports[i];
          Serial.printf("   port %-4s %-6s %lu Mbps  in %llu B / %llu pkt   out %llu B / %llu pkt   "
                        "err %llu/%llu  disc %llu/%llu  %s\n",
                        p.name, p.operStatus == 1 ? "UP" : "DOWN",
                        (unsigned long)p.speedMbps, p.inOctets, p.inUnicast,
                        p.outOctets, p.outUnicast, p.inErrors, p.outErrors, p.inDiscards,
                        p.outDiscards, p.physAddress);
        }
        publishSnapshot(table, ETH.linkUp());
      } else {
        Serial.println("  parse failed");
      }
    }
  }

  if (!catalogMatches) {
    static PortTable empty;
    empty.count = 0;
    publishSnapshot(empty, ETH.linkUp());
  }

  delay(2000);
}
