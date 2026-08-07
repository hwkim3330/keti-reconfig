// Find the WIZnet part: which chip, and on which pins.
//
// Guessing pinouts found nothing, including the documented Waveshare ESP32-S3-ETH layout, so
// this widens the search on both axes. WIZnet's parts do not share an SPI framing: the W5500
// takes a 3-byte header (addr hi, addr lo, control) and answers VERSIONR 0x0039 with 0x04,
// while the W5100S takes an opcode plus a 2-byte address and answers VER 0x0080 with 0x51,
// and the W6100 identifies itself at CIDR 0x0000 with 0x61 0x00. A probe that only speaks
// W5500 is blind to the other two, which is the likely reason the first attempts saw nothing.
//
// NEVER put GPIO19 or GPIO20 in this list. They are the ESP32-S3's native USB D-/D+, and
// reassigning them drops the USB link mid-probe -- the board then needs a BOOT-held replug
// to recover. That is how the first run of this probe ended.
#include <Arduino.h>
#include <SPI.h>

struct Pinout {
  const char *name;
  int sck, miso, mosi, cs, rst;
};

const Pinout kPinouts[] = {
    {"Waveshare S3-ETH", 13, 12, 11, 14,  9},
    {"WIZnet shield",    12, 13, 11, 10,  9},
    {"alt 36/37/35",     36, 37, 35, 39, 38},
    {"alt 40/41/42",     40, 41, 42, 39, 38},
    {"alt 5/6/7",         5,  6,  7,  4,  3},
    {"alt 1/2/3",         1,  2,  3,  4,  5},
    {"alt 47/48/45",     47, 48, 45, 46, 21},
};

void releaseReset(int rst) {
  if (rst < 0) return;
  pinMode(rst, OUTPUT);
  digitalWrite(rst, LOW);
  delay(5);
  digitalWrite(rst, HIGH);
  delay(120);
}

uint8_t w5500Read(SPIClass &spi, int cs, uint16_t addr) {
  spi.beginTransaction(SPISettings(4000000, MSBFIRST, SPI_MODE0));
  digitalWrite(cs, LOW);
  spi.transfer(addr >> 8);
  spi.transfer(addr & 0xFF);
  spi.transfer(0x01);
  const uint8_t v = spi.transfer(0x00);
  digitalWrite(cs, HIGH);
  spi.endTransaction();
  return v;
}

uint8_t w5100Read(SPIClass &spi, int cs, uint16_t addr) {
  spi.beginTransaction(SPISettings(4000000, MSBFIRST, SPI_MODE0));
  digitalWrite(cs, LOW);
  spi.transfer(0x0F);  // read opcode
  spi.transfer(addr >> 8);
  spi.transfer(addr & 0xFF);
  const uint8_t v = spi.transfer(0x00);
  digitalWrite(cs, HIGH);
  spi.endTransaction();
  return v;
}

// Returns a chip name when something identifies itself, else nullptr.
const char *identify(SPIClass &spi, int cs) {
  if (w5500Read(spi, cs, 0x0039) == 0x04 && w5500Read(spi, cs, 0x0039) == 0x04) return "W5500";
  if (w5100Read(spi, cs, 0x0080) == 0x51 && w5100Read(spi, cs, 0x0080) == 0x51) return "W5100S";
  if (w5500Read(spi, cs, 0x0000) == 0x61 && w5500Read(spi, cs, 0x0001) == 0x00) return "W6100";
  return nullptr;
}

// Every pin worth trying as MISO. 19 and 20 are the USB lines and must never appear here;
// 26-32 are the internal flash/PSRAM bus.
const int kMisoSweep[] = {1, 2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14, 15,
                          16, 17, 18, 21, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48};

void setup() { Serial.begin(115200); }

void loop() {
  Serial.println("\n=== WIZnet probe: known pinouts, three chip families ===");
  bool found = false;
  for (const auto &p : kPinouts) {
    releaseReset(p.rst);
    pinMode(p.cs, OUTPUT);
    digitalWrite(p.cs, HIGH);
    SPIClass spi(FSPI);
    spi.begin(p.sck, p.miso, p.mosi, -1);
    const char *chip = identify(spi, p.cs);
    spi.end();
    Serial.printf("%-18s sck=%2d miso=%2d mosi=%2d cs=%2d rst=%2d -> %s\n", p.name, p.sck,
                  p.miso, p.mosi, p.cs, p.rst, chip ? chip : "-");
    if (chip) found = true;
  }

  if (!found) {
    // Maybe only the MISO guess is wrong. Hold the Waveshare bus and sweep the rest.
    Serial.println("--- sweeping MISO with sck=13 mosi=11 cs=14 rst=9 ---");
    releaseReset(9);
    pinMode(14, OUTPUT);
    digitalWrite(14, HIGH);
    for (const int miso : kMisoSweep) {
      if (miso == 13 || miso == 11 || miso == 14 || miso == 9) continue;
      SPIClass spi(FSPI);
      spi.begin(13, miso, 11, -1);
      const char *chip = identify(spi, 14);
      spi.end();
      if (chip) {
        Serial.printf("  MISO=%d -> %s   <== FOUND\n", miso, chip);
        found = true;
      }
    }
    if (!found) Serial.println("  nothing on any MISO");
  }
  Serial.println(found ? "=== FOUND ===" : "=== still nothing ===");
  delay(5000);
}
