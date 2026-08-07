// Find the W5500 and its pinout.
//
// The first version of this probe found nothing, and the reason was almost certainly that it
// never released the chip's reset: these boards wire W5500 RST to a GPIO, and a pin left as a
// floating input can hold the chip in reset, where it answers nothing on SPI. So each
// candidate here drives RST high and waits before reading. VERSIONR (0x0039) is a fixed 0x04,
// so a correct read is proof of both presence and pinout.
//
// NEVER put GPIO19 or GPIO20 in this list. They are the ESP32-S3's native USB D-/D+, and
// reassigning them drops the USB link mid-probe -- the board then needs a BOOT-held replug
// to recover. That is how the first run of this probe ended.
#include <Arduino.h>
#include <SPI.h>

struct Candidate {
  const char *name;
  int sck, miso, mosi, cs, rst;
};

const Candidate kCandidates[] = {
    {"Waveshare ESP32-S3-ETH", 13, 12, 11, 14,  9},
    {"WIZnet W5500 shield",    12, 13, 11, 10,  9},
    {"S3 + W5500 (36/37/35)",  36, 37, 35, 39, 38},
    {"S3 + W5500 (12/13/11)",  12, 13, 11,  9, 10},
    {"S3 + W5500 (14/12/13)",  14, 12, 13, 15, -1},
    {"S3 + W5500 (7/5/6)",      7,  5,  6,  4, -1},
    {"S3 + W5500 (39/40/41)",  39, 40, 41, 42, 43},
    {"S3 + W5500 (4/5/6)",      4,  5,  6,  7,  8},
    {"S3 + W5500 (13/11/12)",  13, 11, 12, 10,  9},
};

uint8_t readVersion(SPIClass &spi, int cs) {
  spi.beginTransaction(SPISettings(4000000, MSBFIRST, SPI_MODE0));
  digitalWrite(cs, LOW);
  spi.transfer(0x00);
  spi.transfer(0x39);
  spi.transfer(0x01);
  const uint8_t value = spi.transfer(0x00);
  digitalWrite(cs, HIGH);
  spi.endTransaction();
  return value;
}

void setup() { Serial.begin(115200); }

void loop() {
  Serial.println("\n=== W5500 probe (with reset release) ===");
  bool found = false;
  for (const auto &c : kCandidates) {
    if (c.rst >= 0) {
      pinMode(c.rst, OUTPUT);
      digitalWrite(c.rst, LOW);
      delay(5);
      digitalWrite(c.rst, HIGH);
      delay(120);  // W5500 needs tens of ms after reset before it answers
    }
    pinMode(c.cs, OUTPUT);
    digitalWrite(c.cs, HIGH);
    SPIClass spi(FSPI);
    spi.begin(c.sck, c.miso, c.mosi, -1);
    const uint8_t v1 = readVersion(spi, c.cs);
    const uint8_t v2 = readVersion(spi, c.cs);  // twice: a stable 0x04 is not a floating line
    spi.end();
    Serial.printf("%-24s sck=%2d miso=%2d mosi=%2d cs=%2d rst=%2d -> 0x%02X 0x%02X%s\n",
                  c.name, c.sck, c.miso, c.mosi, c.cs, c.rst, v1, v2,
                  (v1 == 0x04 && v2 == 0x04) ? "   <== W5500 FOUND" : "");
    if (v1 == 0x04 && v2 == 0x04) found = true;
    delay(30);
  }
  Serial.println(found ? "=== FOUND ===" : "=== none of these pinouts ===");
  delay(4000);
}
