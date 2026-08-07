// Which pin is the LED? Answered by colour, not by counting.
//
// The first version of this probe cycled four numbered phases and asked which one lit, which
// turned out to be ambiguous to watch -- the phases are only distinguishable if you catch the
// start of the cycle. This one gives each candidate its own colour and holds it long enough
// to be unmistakable, so a single glance answers the question:
//
//   RED    held 4 s  -> the LED is the addressable one on GPIO21
//   GREEN  held 4 s  -> the LED is the addressable one on GPIO48
//   BLUE   held 4 s  -> GPIO38, seen on some SuperMini variants
//   then 3 s dark, and repeat
//
// If a plain (non-addressable) LED is fitted instead, none of the above will show and the
// fast white flicker at the end will: that section drives 21, 48 and 38 as ordinary outputs.
#include <Arduino.h>

void hold(int pin, uint8_t r, uint8_t g, uint8_t b, uint32_t ms) {
  const uint32_t until = millis() + ms;
  while (millis() < until) {
    rgbLedWrite(pin, r, g, b);   // refreshed rather than set once: a WS2812 latches, but a
    delay(200);                  // refresh also survives a glitch on the data line
  }
  rgbLedWrite(pin, 0, 0, 0);
}

void setup() { Serial.begin(115200); }

void loop() {
  Serial.println("RED = GPIO21");
  hold(21, 160, 0, 0, 4000);
  Serial.println("GREEN = GPIO48");
  hold(48, 0, 160, 0, 4000);
  Serial.println("BLUE = GPIO38");
  hold(38, 0, 0, 160, 4000);

  Serial.println("plain-output flicker on 21 / 48 / 38");
  for (const int pin : {21, 48, 38}) {
    pinMode(pin, OUTPUT);
    for (int i = 0; i < 10; ++i) {
      digitalWrite(pin, HIGH);
      delay(80);
      digitalWrite(pin, LOW);
      delay(80);
    }
  }

  Serial.println("dark 3 s");
  delay(3000);
}
