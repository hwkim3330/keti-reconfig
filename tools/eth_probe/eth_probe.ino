// Locate the W5500's SPI pins by exhaustive search.
//
// The part is known to be a W5500; what is not known is which pins it sits on, and guessing
// from published pinouts failed repeatedly. So this searches instead of guessing.
//
// The trick that makes an exhaustive search cheap: bit-bang the transfer rather than using the
// SPI peripheral, and on every clock edge snapshot the whole GPIO input register. Every
// candidate pin is then sampled at once, so MISO costs nothing to find and only the
// (SCK, MOSI, CS) triple has to be enumerated -- thousands of combinations instead of
// hundreds of thousands.
//
// Two exclusions matter and both were learned the hard way:
//   GPIO19/20 are the native USB D-/D+. Driving them drops the link to the board mid-scan and
//   costs a BOOT-held replug to recover.
//   GPIO33-37 are the octal PSRAM bus on an R8 part. Earlier probes tried them as SPI pins,
//   which could never have worked.
#include <Arduino.h>
#include "soc/gpio_struct.h"

// Everything usable on an S3 with 16MB flash and octal PSRAM.
const int kPins[] = {1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14, 15,
                     16, 17, 18, 21, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48};
constexpr int kPinCount = sizeof(kPins) / sizeof(kPins[0]);

inline void snapshot(uint32_t &lo, uint32_t &hi) {
  lo = GPIO.in;
  hi = GPIO.in1.val;
}

inline bool pinHigh(int pin, uint32_t lo, uint32_t hi) {
  return pin < 32 ? (lo >> pin) & 1u : (hi >> (pin - 32)) & 1u;
}

// One W5500 register read, bit-banged. Captures the input register on each of the eight data
// clocks so any pin can be checked afterwards as a candidate MISO.
void readCapture(int sck, int mosi, int cs, uint16_t addr, uint32_t *lo, uint32_t *hi) {
  const uint8_t header[3] = {uint8_t(addr >> 8), uint8_t(addr & 0xFF), 0x01};
  digitalWrite(cs, LOW);
  for (int byteIndex = 0; byteIndex < 3; ++byteIndex) {
    for (int bit = 7; bit >= 0; --bit) {
      digitalWrite(mosi, (header[byteIndex] >> bit) & 1);
      delayMicroseconds(1);
      digitalWrite(sck, HIGH);
      delayMicroseconds(1);
      digitalWrite(sck, LOW);
    }
  }
  for (int bit = 0; bit < 8; ++bit) {
    delayMicroseconds(1);
    digitalWrite(sck, HIGH);
    snapshot(lo[bit], hi[bit]);   // W5500 shifts out on the falling edge; sample on the rising
    delayMicroseconds(1);
    digitalWrite(sck, LOW);
  }
  digitalWrite(cs, HIGH);
}

uint8_t assemble(int miso, const uint32_t *lo, const uint32_t *hi) {
  uint8_t value = 0;
  for (int bit = 0; bit < 8; ++bit) {
    value = (value << 1) | (pinHigh(miso, lo[bit], hi[bit]) ? 1 : 0);
  }
  return value;
}

void setup() {
  Serial.begin(115200);
  delay(1500);
}

void loop() {
  Serial.println("\n=== W5500 pin search (bit-banged, all GPIO sampled per clock) ===");
  Serial.printf("candidate pins: %d, triples to try: %d\n", kPinCount,
                kPinCount * (kPinCount - 1) * (kPinCount - 2));
  const uint32_t started = millis();
  int hits = 0;

  for (int a = 0; a < kPinCount; ++a) {
    // Idle state: everything an input with a pull-up. A pull-up also releases any active-low
    // reset line the board may have, which a floating pin would leave asserted.
    for (int i = 0; i < kPinCount; ++i) pinMode(kPins[i], INPUT_PULLUP);
    const int sck = kPins[a];
    pinMode(sck, OUTPUT);
    digitalWrite(sck, LOW);

    for (int b = 0; b < kPinCount; ++b) {
      if (b == a) continue;
      const int mosi = kPins[b];
      pinMode(mosi, OUTPUT);

      for (int c = 0; c < kPinCount; ++c) {
        if (c == a || c == b) continue;
        const int cs = kPins[c];
        pinMode(cs, OUTPUT);
        digitalWrite(cs, HIGH);

        uint32_t lo[8], hi[8];
        readCapture(sck, mosi, cs, 0x0039, lo, hi);
        for (int m = 0; m < kPinCount; ++m) {
          if (m == a || m == b || m == c) continue;
          if (assemble(kPins[m], lo, hi) != 0x04) continue;
          // Confirm: a second read must agree, and a different register must not also read
          // 0x04, which is what a stuck or coupled line would do.
          uint32_t lo2[8], hi2[8], lo3[8], hi3[8];
          readCapture(sck, mosi, cs, 0x0039, lo2, hi2);
          readCapture(sck, mosi, cs, 0x0000, lo3, hi3);
          const uint8_t again = assemble(kPins[m], lo2, hi2);
          const uint8_t other = assemble(kPins[m], lo3, hi3);
          if (again == 0x04 && other != 0x04) {
            Serial.printf("  W5500 FOUND  sck=%d mosi=%d cs=%d miso=%d  (MR=0x%02X)\n", sck,
                          mosi, cs, kPins[m], other);
            ++hits;
          }
        }
        pinMode(cs, INPUT_PULLUP);
      }
      pinMode(mosi, INPUT_PULLUP);
    }
    Serial.printf("  ... sck=%d done (%lu s elapsed, %d hit%s)\n", sck,
                  (millis() - started) / 1000, hits, hits == 1 ? "" : "s");
  }

  Serial.printf("=== search complete: %d hit%s in %lu s ===\n", hits, hits == 1 ? "" : "s",
                (millis() - started) / 1000);
  delay(10000);
}
