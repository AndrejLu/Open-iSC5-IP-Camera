/*
 * CameraUartRxBridge — receive-only UART bridge for UDOO X86 Arduino 101 (Intel Curie)
 *
 * Serial  (USB CDC to host): camera bytes forwarded unchanged
 * Serial1 (D0/RX, D1/TX):    camera TX → D0/RX at 115200 8N1
 *
 * Never transmits to the camera. No banners, timestamps, or debug text on the stream.
 */

void setup() {
  Serial.begin(115200);
  Serial1.begin(115200);
  // Do not block forever waiting for the host USB terminal.
  // Wait briefly so early camera bytes are less likely to be lost after reset.
  unsigned long start = millis();
  while (!Serial && (millis() - start) < 2000) {
    // wait up to 2s for USB host
  }
}

void loop() {
  // Batch-forward camera → USB without per-character delays.
  int available = Serial1.available();
  if (available > 0) {
    // Cap batch size to keep USB CDC happy without starving the UART RX path.
    if (available > 64) {
      available = 64;
    }
    uint8_t buf[64];
    int n = Serial1.readBytes(buf, available);
    if (n > 0) {
      Serial.write(buf, n);
    }
  }
}
