// ESP32-S3 + W5500 -> LAN9662/9692 over Ethernet.
//
// First milestone: prove the switch answers CoAP on the wire, not just over the serial MUP1
// link. Sends a GET to /.well-known/core, the standard CoAP discovery resource, because it
// needs no YANG catalog and no SID -- if this answers, the transport is real and everything
// above it (CORECONF, CBOR, delta-SID) is a software matter.
//
// Pinout came from tools/eth_probe's exhaustive search and is confirmed in tools/eth_verify.
#include <Arduino.h>
#include <ETH.h>
#include <NetworkUdp.h>

constexpr int kSck = 48, kMosi = 21, kCs = 45, kMiso = 47;

// Static, because this is a closed demo network with no DHCP server. The switch is .10; see
// the README for the address plan.
const IPAddress kSelf(192, 168, 1, 20);
const IPAddress kSwitch(192, 168, 1, 10);
const IPAddress kMask(255, 255, 255, 0);
const IPAddress kGateway(192, 168, 1, 1);
constexpr uint16_t kCoapPort = 5683;

NetworkUDP udp;
uint16_t messageId = 1;

void sendWellKnownCore() {
  uint8_t packet[32];
  size_t n = 0;
  packet[n++] = 0x40;                    // version 1, confirmable, no token
  packet[n++] = 0x01;                    // GET
  packet[n++] = messageId >> 8;
  packet[n++] = messageId & 0xFF;
  ++messageId;
  const char *first = ".well-known";     // Uri-Path option 11, delta 11
  packet[n++] = 0xB0 | strlen(first);
  memcpy(packet + n, first, strlen(first));
  n += strlen(first);
  const char *second = "core";           // second Uri-Path, delta 0
  packet[n++] = 0x00 | strlen(second);
  memcpy(packet + n, second, strlen(second));
  n += strlen(second);

  udp.beginPacket(kSwitch, kCoapPort);
  udp.write(packet, n);
  udp.endPacket();
  Serial.printf("-> CoAP GET /.well-known/core to %s (%u bytes)\n", kSwitch.toString().c_str(),
                unsigned(n));
}

void setup() {
  Serial.begin(115200);
  delay(1500);
  Serial.println("\n=== switch controller: Ethernet bring-up ===");

  if (!ETH.begin(ETH_PHY_W5500, 1, kCs, -1, -1, SPI2_HOST, kSck, kMiso, kMosi)) {
    Serial.println("ETH.begin failed");
    return;
  }
  if (!ETH.config(kSelf, kGateway, kMask)) {
    Serial.println("static address rejected");
  }
  for (int i = 0; i < 40 && !ETH.linkUp(); ++i) delay(100);
  Serial.printf("link %s, IP %s, MAC %s\n", ETH.linkUp() ? "UP" : "DOWN",
                ETH.localIP().toString().c_str(), ETH.macAddress().c_str());
  udp.begin(kCoapPort + 1);
}

void loop() {
  if (!ETH.linkUp()) {
    Serial.println("link down");
    delay(2000);
    return;
  }
  sendWellKnownCore();

  const uint32_t deadline = millis() + 2000;
  bool answered = false;
  while (millis() < deadline) {
    const int size = udp.parsePacket();
    if (size <= 0) { delay(5); continue; }
    uint8_t buffer[512];
    const int n = udp.read(buffer, sizeof(buffer));
    Serial.printf("<- %d bytes from %s: code 0x%02X\n", n, udp.remoteIP().toString().c_str(),
                  n > 1 ? buffer[1] : 0);
    Serial.print("   payload: ");
    for (int i = 4; i < n && i < 120; ++i) {
      Serial.print(isprint(buffer[i]) ? char(buffer[i]) : '.');
    }
    Serial.println();
    answered = true;
    break;
  }
  if (!answered) Serial.println("<- no answer in 2 s");
  delay(3000);
}
