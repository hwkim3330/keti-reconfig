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

#include "coap_client.h"
#include "coreconf.h"
#include "sid_table.h"

constexpr int kSck = 48, kMosi = 21, kCs = 45, kMiso = 47;

const IPAddress kSelf(192, 168, 1, 20);
const IPAddress kSwitch(192, 168, 1, 10);
const IPAddress kMask(255, 255, 255, 0);
const IPAddress kGateway(192, 168, 1, 1);
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
      Serial.printf("  device catalog %s -> %s\n", reported,
                    catalogMatches ? "MATCHES the SID table"
                                   : "DIFFERENT -- SID table must not be used");
    } else {
      Serial.print("  raw: ");
      for (int i = 0; i < n && i < 48; ++i) Serial.printf("%02X ", payload[i]);
      Serial.println();
    }
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
          Serial.printf("   port %-4s %-6s in %llu B / %llu pkt   out %llu B / %llu pkt   "
                        "err %llu/%llu  disc %llu/%llu  %s\n",
                        p.name, p.operStatus == 1 ? "UP" : "DOWN", p.inOctets, p.inUnicast,
                        p.outOctets, p.outUnicast, p.inErrors, p.outErrors, p.inDiscards,
                        p.outDiscards, p.physAddress);
        }
      } else {
        Serial.println("  parse failed");
      }
    }
  }

  delay(5000);
}
