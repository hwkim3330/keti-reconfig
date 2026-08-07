// Confirm the W5500 pinout found by tools/eth_probe, and report whether the cable is live.
//
// Pinout came out of an exhaustive bit-banged search, not a datasheet, so it is checked here
// against registers whose reset values are known: VERSIONR is always 0x04, RTR defaults to
// 0x07D0 and RCR to 0x08. Three independent agreements make a wiring coincidence implausible.
#include <Arduino.h>
#include <SPI.h>

constexpr int kSck = 48, kMosi = 21, kCs = 45, kMiso = 47;

SPIClass spi(FSPI);

uint8_t readReg(uint16_t addr) {
  spi.beginTransaction(SPISettings(8000000, MSBFIRST, SPI_MODE0));
  digitalWrite(kCs, LOW);
  spi.transfer(addr >> 8);
  spi.transfer(addr & 0xFF);
  spi.transfer(0x01);
  const uint8_t v = spi.transfer(0x00);
  digitalWrite(kCs, HIGH);
  spi.endTransaction();
  return v;
}

void setup() {
  Serial.begin(115200);
  pinMode(kCs, OUTPUT);
  digitalWrite(kCs, HIGH);
  spi.begin(kSck, kMiso, kMosi, -1);
  delay(1500);
}

void loop() {
  const uint8_t version = readReg(0x0039);
  const uint16_t rtr = (uint16_t(readReg(0x0019)) << 8) | readReg(0x001A);
  const uint8_t rcr = readReg(0x001B);
  const uint8_t phy = readReg(0x002E);

  Serial.printf("\nVERSIONR 0x%02X (expect 0x04)   RTR 0x%04X (expect 0x07D0)   RCR 0x%02X (expect 0x08)\n",
                version, rtr, rcr);
  Serial.printf("PHYCFGR  0x%02X -> link %s, speed %s, duplex %s\n", phy,
                (phy & 0x01) ? "UP" : "DOWN",
                (phy & 0x02) ? "100M" : "10M",
                (phy & 0x04) ? "full" : "half");
  const bool sane = version == 0x04 && rtr == 0x07D0 && rcr == 0x08;
  Serial.println(sane ? "=> pinout CONFIRMED" : "=> registers disagree, pinout is wrong");
  delay(3000);
}
