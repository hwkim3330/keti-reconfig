// Which pin is the LED, and is it addressable or plain?
// Four phases, each visually distinct, so one look settles it without a schematic.
#include <Arduino.h>

void addressable(int pin) {
  rgbLedWrite(pin, 40, 0, 0);  delay(1200);   // red
  rgbLedWrite(pin, 0, 40, 0);  delay(1200);   // green
  rgbLedWrite(pin, 0, 0, 40);  delay(1200);   // blue
  rgbLedWrite(pin, 0, 0, 0);   delay(600);
}

void plain(int pin) {
  pinMode(pin, OUTPUT);
  for (int i = 0; i < 6; ++i) {          // fast blink, unmistakable next to the slow fades
    digitalWrite(pin, HIGH); delay(150);
    digitalWrite(pin, LOW);  delay(150);
  }
  delay(600);
}

void setup() { Serial.begin(115200); }

void loop() {
  Serial.println("phase 1: addressable GPIO48 (red green blue)");
  addressable(48);
  Serial.println("phase 2: addressable GPIO21 (red green blue)");
  addressable(21);
  Serial.println("phase 3: plain GPIO48 (fast blink)");
  plain(48);
  Serial.println("phase 4: plain GPIO21 (fast blink)");
  plain(21);
  Serial.println("--- cycle end, 3 s gap ---");
  delay(3000);
}
