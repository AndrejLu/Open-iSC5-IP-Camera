/*
 * CameraUartBridge — full-duplex UART bridge for UDOO X86 Arduino 101 (Intel Curie)
 *
 * Serial  (USB CDC to host)  ↔  Serial1 (D0/RX, D1/TX) camera UART @ 115200 8N1
 *
 * Forwards both directions in small batches. No banners/timestamps on the stream.
 * Does not block forever if the USB host is absent.
 */

void setup() {
  Serial.begin(115200);
  Serial1.begin(115200);
  unsigned long start = millis();
  while (!Serial && (millis() - start) < 2000) {
    // wait briefly for USB host
  }
}

void loop() {
  // Camera → USB
  int n1 = Serial1.available();
  if (n1 > 0) {
    if (n1 > 64) {
      n1 = 64;
    }
    uint8_t buf[64];
    int n = Serial1.readBytes(buf, n1);
    if (n > 0) {
      Serial.write(buf, n);
    }
  }

  // USB → Camera
  int n0 = Serial.available();
  if (n0 > 0) {
    if (n0 > 64) {
      n0 = 64;
    }
    uint8_t buf[64];
    int n = Serial.readBytes(buf, n0);
    if (n > 0) {
      Serial1.write(buf, n);
    }
  }
}
