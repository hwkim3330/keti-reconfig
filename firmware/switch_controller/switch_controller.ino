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
#include <ETH.h>
#include <NetworkUdp.h>

#include "sid_table.h"

constexpr int kSck = 48, kMosi = 21, kCs = 45, kMiso = 47;

const IPAddress kSelf(192, 168, 1, 20);
const IPAddress kSwitch(192, 168, 1, 10);
const IPAddress kMask(255, 255, 255, 0);
const IPAddress kGateway(192, 168, 1, 1);
constexpr uint16_t kCoapPort = 5683;
constexpr uint8_t kCoapFetch = 0x05;
constexpr uint16_t kContentFormatYangIdentifiersCbor = 141;

NetworkUDP udp;
uint16_t messageId = 1;

size_t cborUint(uint8_t *out, uint32_t value, uint8_t majorType) {
  const uint8_t mt = majorType << 5;
  if (value < 24)          { out[0] = mt | value; return 1; }
  if (value < 0x100)       { out[0] = mt | 24; out[1] = value; return 2; }
  if (value < 0x10000)     { out[0] = mt | 25; out[1] = value >> 8; out[2] = value; return 3; }
  out[0] = mt | 26;
  out[1] = value >> 24; out[2] = value >> 16; out[3] = value >> 8; out[4] = value;
  return 5;
}

// Sends an iFETCH for one SID. Returns the response payload length, or -1 on timeout.
int fetchSid(uint32_t sid, uint8_t *response, size_t responseCapacity, uint8_t *responseCode) {
  uint8_t packet[64];
  size_t n = 0;
  packet[n++] = 0x40;             // version 1, confirmable, no token
  packet[n++] = kCoapFetch;
  const uint16_t id = messageId++;
  packet[n++] = id >> 8;
  packet[n++] = id & 0xFF;

  packet[n++] = 0xB1;             // Uri-Path (11), delta 11, length 1
  packet[n++] = 'c';              // the CORECONF endpoint
  packet[n++] = 0x11;             // Content-Format (12), delta 1, length 1
  packet[n++] = uint8_t(kContentFormatYangIdentifiersCbor);

  packet[n++] = 0xFF;             // payload marker
  n += cborUint(packet + n, 1, 4);    // array of one
  n += cborUint(packet + n, sid, 0);  // the SID

  udp.beginPacket(kSwitch, kCoapPort);
  udp.write(packet, n);
  udp.endPacket();

  const uint32_t deadline = millis() + 3000;
  while (millis() < deadline) {
    const int size = udp.parsePacket();
    if (size <= 0) { delay(2); continue; }
    uint8_t buffer[1024];
    const int got = udp.read(buffer, sizeof(buffer));
    if (got < 4) continue;
    if (uint16_t((buffer[2] << 8) | buffer[3]) != id) continue;  // not our exchange
    *responseCode = buffer[1];
    const uint8_t tokenLength = buffer[0] & 0x0F;
    int i = 4 + tokenLength;
    while (i < got && buffer[i] != 0xFF) {          // step over options to the payload
      const uint8_t lengthNibble = buffer[i] & 0x0F;
      const uint8_t deltaNibble = buffer[i] >> 4;
      ++i;
      if (deltaNibble == 13) i += 1; else if (deltaNibble == 14) i += 2;
      uint32_t length = lengthNibble;
      if (lengthNibble == 13) { length = 13 + buffer[i]; i += 1; }
      else if (lengthNibble == 14) { length = 269 + ((buffer[i] << 8) | buffer[i + 1]); i += 2; }
      i += length;
    }
    if (i >= got) return 0;                          // answered, but with no payload
    ++i;
    const int payloadLength = got - i;
    const int copied = min(payloadLength, int(responseCapacity));
    memcpy(response, buffer + i, copied);
    return copied;
  }
  return -1;
}

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

void setup() {
  Serial.begin(115200);
  delay(1500);
  Serial.println("\n=== KETI switch controller ===");
  Serial.printf("SID table built from catalog %s (%d entries)\n", KETI_SID_CATALOG_CHECKSUM,
                kKetiSidCount);

  if (!ETH.begin(ETH_PHY_W5500, 1, kCs, -1, -1, SPI2_HOST, kSck, kMiso, kMosi)) {
    Serial.println("ETH.begin failed");
    return;
  }
  ETH.config(kSelf, kGateway, kMask);
  for (int i = 0; i < 40 && !ETH.linkUp(); ++i) delay(100);
  Serial.printf("link %s, IP %s\n", ETH.linkUp() ? "UP" : "DOWN",
                ETH.localIP().toString().c_str());
  udp.begin(kCoapPort + 1);
}

void loop() {
  uint8_t payload[512];
  uint8_t code = 0;
  const int n = fetchSid(KETI_SID_YANG_CHECKSUM, payload, sizeof(payload), &code);

  if (n < 0) {
    Serial.println("checksum fetch: no answer");
  } else {
    Serial.printf("checksum fetch: code %d.%02d, %d payload bytes\n", code >> 5, code & 0x1F, n);
    char reported[64] = "";
    if (extractChecksum(payload, n, reported, sizeof(reported))) {
      catalogMatches = strcmp(reported, KETI_SID_CATALOG_CHECKSUM) == 0;
      Serial.printf("  device catalog %s -> %s\n", reported,
                    catalogMatches ? "MATCHES the SID table"
                                   : "DIFFERENT -- SID table must not be used");
    } else {
      Serial.print("  raw: ");
      for (int i = 0; i < n && i < 48; ++i) Serial.printf("%02X ", payload[i]);
      Serial.println();
    }
  }
  delay(5000);
}
