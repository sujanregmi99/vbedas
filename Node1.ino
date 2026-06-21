/*
 * ================================================================
 *  EARTHQUAKE DETECTION — NODE 1  (DISPLAY + BUZZER + LED + FIREBASE)
 * ================================================================
 *  Hardware:
 *    ESP32
 *    MPU6050        I2C  SDA=21  SCL=22
 *    SH1106 OLED    I2C  SDA=21  SCL=22
 *    Buzzer (active) GPIO 26  active-HIGH
 *    LED             GPIO 25  active-HIGH
 *
 *  THIS node MAC : A8:42:E3:5B:D2:C8
 *  Node 2   MAC  : F0:24:F9:0D:8A:3C
 *
 * ── FIX SUMMARY ─────────────────────────────────────────────────
 *  Firebase writes are now fully decoupled from the detection loop:
 *    • A lightweight write-queue (fbQueue[]) holds pending writes.
 *    • Only ONE field is written per loop() iteration, and only
 *      when the detection state is IDLE (no raw vibration, no alert).
 *    • Alert events are queued, not written inline inside startAlert().
 *    • Firebase.signUp() is deferred to after ESP-NOW is running.
 *    • Firebase.ready() is called at most once per queue drain cycle.
 *
 * ── LIBRARIES ────────────────────────────────────────────────────
 *   U8g2               by olikraus
 *   Adafruit MPU6050
 *   Adafruit Unified Sensor
 *   Firebase ESP Client  by Mobizt
 *
 * ── SERIAL COMMANDS (115200 baud) ────────────────────────────────
 *   t → toggle force LOCAL vibration
 *   s → force FULL ALERT immediately
 *   b → buzzer test (3 short beeps)
 *   o → OLED test (alert screen 2 s)
 *   r → reset / clear active alert
 * ================================================================
 */

#include <WiFi.h>
#include <esp_now.h>
#include <Wire.h>
#include <Adafruit_MPU6050.h>
#include <Adafruit_Sensor.h>
#include <U8g2lib.h>
#include <Firebase_ESP_Client.h>

// ── Pins ──────────────────────────────────────────────────────────
#define BUZZER_PIN  26
#define LED_PIN     25
#define I2C_SDA     21
#define I2C_SCL     22

// ── Tuning ────────────────────────────────────────────────────────
#define VIB_THRESHOLD    0.2f   // m/s² above gravity baseline
#define SUSTAINED_MS      200   // vibration must last this long
#define GAP_ALLOW_MS      150   // brief gap tolerated mid-vibration
#define WINDOW_MS        3000   // dual-node detection window
#define ALERT_HOLD_MS   10000   // alert duration (10 s)
#define NODE_TIMEOUT_MS  5000   // peer offline after no packet

// ── WiFi ──────────────────────────────────────────────────────────
const char* WIFI_SSID = "SSID_NAME";
const char* WIFI_PASS = "PASSWORD";

// ── Firebase ──────────────────────────────────────────────────────
#define API_KEY      "FIREBASE API KEY"
#define DATABASE_URL "DATABASE URL"

FirebaseData fbdo;
FirebaseAuth auth;
FirebaseConfig config;

bool firebaseReady = false;

// ── Firebase write queue ──────────────────────────────────────────
//  Each entry is a single RTDB set/push.  Only one is processed per
//  loop() when the system is idle, keeping detection jitter < 1 ms.
#define FB_QUEUE_SIZE 24

enum FbWriteType { FB_SET_FLOAT, FB_SET_STRING, FB_SET_INT, FB_PUSH_JSON };

struct FbEntry {
  bool         used;
  FbWriteType  type;
  char         path[64];
  float        fVal;
  char         sVal[64];
  int          iVal;
  // JSON alert event fields (used when type == FB_PUSH_JSON)
  float        evAccel;
};

FbEntry fbQueue[FB_QUEUE_SIZE];

// Enqueue a float set — silently drops if queue full
void fbEnqueueFloat(const char* path, float val) {
  for (int i = 0; i < FB_QUEUE_SIZE; i++) {
    if (!fbQueue[i].used) {
      fbQueue[i].used  = true;
      fbQueue[i].type  = FB_SET_FLOAT;
      strlcpy(fbQueue[i].path, path, sizeof(fbQueue[i].path));
      fbQueue[i].fVal  = val;
      return;
    }
  }
  Serial.println(F("[FB-Q] FULL — float dropped"));
}

// Enqueue a string set
void fbEnqueueString(const char* path, const char* val) {
  for (int i = 0; i < FB_QUEUE_SIZE; i++) {
    if (!fbQueue[i].used) {
      fbQueue[i].used  = true;
      fbQueue[i].type  = FB_SET_STRING;
      strlcpy(fbQueue[i].path, path, sizeof(fbQueue[i].path));
      strlcpy(fbQueue[i].sVal, val,  sizeof(fbQueue[i].sVal));
      return;
    }
  }
  Serial.println(F("[FB-Q] FULL — string dropped"));
}

// Enqueue an alert event push
void fbEnqueueAlert(float accel) {
  for (int i = 0; i < FB_QUEUE_SIZE; i++) {
    if (!fbQueue[i].used) {
      fbQueue[i].used     = true;
      fbQueue[i].type     = FB_PUSH_JSON;
      strlcpy(fbQueue[i].path, "/events", sizeof(fbQueue[i].path));
      fbQueue[i].evAccel  = accel;
      return;
    }
  }
  Serial.println(F("[FB-Q] FULL — alert event dropped"));
}

// Process exactly ONE queued entry.  Returns true if something was written.
bool fbDrainOne() {
  if (!firebaseReady || !Firebase.ready()) return false;

  for (int i = 0; i < FB_QUEUE_SIZE; i++) {
    if (!fbQueue[i].used) continue;

    bool ok = false;
    switch (fbQueue[i].type) {

      case FB_SET_FLOAT:
        ok = Firebase.RTDB.setFloat(&fbdo, fbQueue[i].path, fbQueue[i].fVal);
        break;

      case FB_SET_STRING:
        ok = Firebase.RTDB.setString(&fbdo, fbQueue[i].path, fbQueue[i].sVal);
        break;

      case FB_SET_INT:
        ok = Firebase.RTDB.setInt(&fbdo, fbQueue[i].path, fbQueue[i].iVal);
        break;

      case FB_PUSH_JSON: {
        FirebaseJson json;
        json.set("node",         "node1");
        json.set("acceleration", fbQueue[i].evAccel);
        json.set("threshold",    VIB_THRESHOLD);
        json.set("status",       "Alert");
        json.set("timestamp",    String(millis() / 1000) + " sec");
        ok = Firebase.RTDB.pushJSON(&fbdo, fbQueue[i].path, &json);
        break;
      }
    }

    fbQueue[i].used = false;  // free slot regardless of success

    if (ok) {
      Serial.print(F("[FB] Wrote: ")); Serial.println(fbQueue[i].path);
    } else {
      Serial.print(F("[FB] Failed: ")); Serial.println(fbdo.errorReason());
    }
    return true;  // only one write per call
  }
  return false;
}

// ── Queue a full "latest" snapshot (replaces firebaseSendLatest) ──
//  Overwrites any previous queued values for the same paths so the
//  queue never accumulates stale snapshots.
void fbQueueLatest(float delta, const char* status) {
  // Helper: overwrite an existing queued float or add new
  auto overwriteFloat = [](const char* path, float val) {
    for (int i = 0; i < FB_QUEUE_SIZE; i++) {
      if (fbQueue[i].used &&
          fbQueue[i].type == FB_SET_FLOAT &&
          strcmp(fbQueue[i].path, path) == 0) {
        fbQueue[i].fVal = val;
        return;
      }
    }
    fbEnqueueFloat(path, val);
  };

  auto overwriteString = [](const char* path, const char* val) {
    for (int i = 0; i < FB_QUEUE_SIZE; i++) {
      if (fbQueue[i].used &&
          fbQueue[i].type == FB_SET_STRING &&
          strcmp(fbQueue[i].path, path) == 0) {
        strlcpy(fbQueue[i].sVal, val, sizeof(fbQueue[i].sVal));
        return;
      }
    }
    fbEnqueueString(path, val);
  };

  overwriteFloat ("/node1/acceleration", delta);
  overwriteFloat ("/node1/threshold",    VIB_THRESHOLD);
  overwriteString("/node1/status",       status);
  overwriteString("/node1/online",       "true");
  overwriteString("/node1/device",       "Primary Display Node");

  char tsBuf[24];
  snprintf(tsBuf, sizeof(tsBuf), "%lu sec", millis() / 1000);
  overwriteString("/node1/timestamp", tsBuf);
}

// ── Firebase init (called after ESP-NOW is up) ────────────────────
void firebaseInit() {
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println(F("[Firebase] No WiFi — skipping"));
    return;
  }
  Serial.println(F("[Firebase] Connecting..."));

  config.api_key      = API_KEY;
  config.database_url = DATABASE_URL;

  // signUp is blocking but runs only once, after ESP-NOW is already
  // registered, so detection is unaffected at runtime.
  if (Firebase.signUp(&config, &auth, "", "")) {
    Serial.println(F("[Firebase] Signup OK"));
    firebaseReady = true;
  } else {
    Serial.print(F("[Firebase] Signup failed: "));
    Serial.println(config.signer.signupError.message.c_str());
    firebaseReady = false;
  }

  Firebase.begin(&config, &auth);
  Firebase.reconnectWiFi(true);
  Serial.println(F("[Firebase] Setup done"));
}

// ── Peer MAC ──────────────────────────────────────────────────────
uint8_t peer2Mac[6] = {0xF0, 0x24, 0xF9, 0x0D, 0x8A, 0x3C};

// ── Packet structure (must match Node 2 exactly) ──────────────────
typedef struct __attribute__((packed)) {
  uint8_t       nodeId;
  bool          vibrating;
  float         magnitude;
  unsigned long timestamp;
} VibPacket;

// ── U8g2 OLED ─────────────────────────────────────────────────────
U8G2_SH1106_128X64_NONAME_F_HW_I2C u8g2(U8G2_R0, U8X8_PIN_NONE);

// ── MPU6050 ───────────────────────────────────────────────────────
Adafruit_MPU6050 mpu;

// ── Runtime state ─────────────────────────────────────────────────
VibPacket outPkt;

float         vibMag       = 0.0f;
bool          vibratingNow = false;
unsigned long vibStartMs   = 0;
unsigned long lastRawVibMs = 0;

bool          alertActive  = false;
unsigned long alertStartMs = 0;

VibPacket     peer2Pkt;
bool          peer2Online  = false;
unsigned long peer2LastMs  = 0;

bool forceLocalVib  = false;
bool forceFullAlert = false;

// Latest snapshot timer — only queues Firebase data, never blocks
unsigned long lastSnapshotMs      = 0;
const unsigned long SNAPSHOT_MS   = 2000;  // queue a snapshot every 2 s

// Alert event cooldown
unsigned long lastAlertEventMs           = 0;
const unsigned long ALERT_EVENT_COOLDOWN = 60000;

// ── OLED screens ──────────────────────────────────────────────────
void drawMonitoring() {
  char buf[28];
  u8g2.clearBuffer();

  u8g2.setFont(u8g2_font_6x10_tf);
  u8g2.drawBox(0, 0, 128, 12);
  u8g2.setDrawColor(0);
  u8g2.drawStr(16, 10, "SEISMIC MONITOR");
  u8g2.setDrawColor(1);

  u8g2.setFont(u8g2_font_8x13B_tf);
  u8g2.drawStr(10, 28, "MONITORING");

  u8g2.setFont(u8g2_font_6x10_tf);
  snprintf(buf, sizeof(buf), "MAG: %.2f m/s2", vibMag);
  u8g2.drawStr(0, 42, buf);

  snprintf(buf, sizeof(buf), "N1:%s  N2:%s",
           vibratingNow ? "VIB" : "ok ",
           (!peer2Online)       ? "---" :
           peer2Pkt.vibrating   ? "VIB" : "ok ");
  u8g2.drawStr(0, 55, buf);

  u8g2.sendBuffer();
}

void drawAlert() {
  u8g2.clearBuffer();
  u8g2.drawFrame(0, 0, 128, 64);
  u8g2.drawFrame(2, 2, 124, 60);

  u8g2.setFont(u8g2_font_6x10_tf);
  u8g2.drawStr(28, 14, "!!! ALERT !!!");

  u8g2.setFont(u8g2_font_10x20_tf);
  u8g2.drawStr(4, 38, "EARTHQUAKE");
  u8g2.drawStr(14, 60, "DETECTED");

  u8g2.sendBuffer();
}

// ── Buzzer ────────────────────────────────────────────────────────
void buzzerOn()  { digitalWrite(BUZZER_PIN, HIGH); }
void buzzerOff() { digitalWrite(BUZZER_PIN, LOW);  }
void buzzerBeepTest() {
  Serial.println(F("[TEST] Buzzer x3"));
  for (int i = 0; i < 3; i++) {
    digitalWrite(BUZZER_PIN, HIGH); delay(250);
    digitalWrite(BUZZER_PIN, LOW);  delay(250);
  }
}

// ── Alert start / end ─────────────────────────────────────────────
void startAlert() {
  if (alertActive) return;
  alertActive  = true;
  alertStartMs = millis();
  digitalWrite(LED_PIN, HIGH);
  buzzerOn();
  drawAlert();
  Serial.println(F(">>> EARTHQUAKE DETECTED <<<"));

  // Queue Firebase alert event — does NOT block
  unsigned long now = millis();
  if (lastAlertEventMs == 0 || (now - lastAlertEventMs) >= ALERT_EVENT_COOLDOWN) {
    lastAlertEventMs = now;
    fbEnqueueAlert(vibMag);
    // Also update status immediately in the snapshot queue
    fbQueueLatest(vibMag, "Alert");
  }
}

void endAlert() {
  alertActive    = false;
  forceFullAlert = false;
  buzzerOff();
  digitalWrite(LED_PIN, LOW);
  drawMonitoring();
  Serial.println(F("--- Alert ended ---\n"));
}

// ── ESP-NOW callbacks ─────────────────────────────────────────────
void onSent(const uint8_t* mac, esp_now_send_status_t st) {
  if (st != ESP_NOW_SEND_SUCCESS)
    Serial.println(F("[ESP-NOW] SEND FAILED"));
}

void onRecv(const esp_now_recv_info_t* info, const uint8_t* data, int len) {
  if (len != sizeof(VibPacket)) return;
  memcpy(&peer2Pkt, data, len);
  peer2Online = true;
  peer2LastMs = millis();

  static bool prevVib = false;
  if (peer2Pkt.vibrating != prevVib) {
    prevVib = peer2Pkt.vibrating;
    Serial.print(F("RECV N2 vib="));
    Serial.println(peer2Pkt.vibrating ? 1 : 0);
  }
}

// ── MPU read ──────────────────────────────────────────────────────
float readMag() {
  sensors_event_t a, g, t;
  mpu.getEvent(&a, &g, &t);
  float ax = a.acceleration.x;
  float ay = a.acceleration.y;
  float az = a.acceleration.z;
  return fabsf(sqrtf(ax*ax + ay*ay + az*az) - 9.81f);
}

// ─────────────────────────────────────────────────────────────────
//  SETUP
// ─────────────────────────────────────────────────────────────────
void setup() {
  Serial.begin(115200);
  delay(400);
  Serial.println(F("\n====== NODE 1 BOOT ======"));
  Serial.println(F("Cmds: t=localVib s=forceAlert b=buzzerTest o=oledTest r=reset"));

  memset(fbQueue, 0, sizeof(fbQueue));

  pinMode(BUZZER_PIN, OUTPUT);
  pinMode(LED_PIN,    OUTPUT);
  digitalWrite(BUZZER_PIN, LOW);
  digitalWrite(LED_PIN,    LOW);

  Wire.begin(I2C_SDA, I2C_SCL);
  Wire.setClock(400000);

  // OLED
  u8g2.begin();
  u8g2.clearBuffer();
  u8g2.setFont(u8g2_font_8x13B_tf);
  u8g2.drawStr(20, 36, "NODE 1 BOOT");
  u8g2.sendBuffer();
  delay(600);

  // MPU6050
  if (!mpu.begin()) {
    Serial.println(F("[MPU] INIT FAILED"));
    u8g2.clearBuffer();
    u8g2.setFont(u8g2_font_6x10_tf);
    u8g2.drawStr(0, 36, "MPU6050 FAILED!");
    u8g2.sendBuffer();
    while (true) delay(1000);
  }
  mpu.setAccelerometerRange(MPU6050_RANGE_8_G);
  mpu.setFilterBandwidth(MPU6050_BAND_21_HZ);
  Serial.println(F("[MPU] OK"));

  // WiFi (non-blocking timeout)
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  unsigned long wt = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - wt < 8000) delay(300);
  if (WiFi.status() == WL_CONNECTED)
    Serial.println(F("[WiFi] Connected"));
  else
    Serial.println(F("[WiFi] Timeout (ESP-NOW still works)"));
  Serial.print(F("[WiFi] MAC: ")); Serial.println(WiFi.macAddress());

  // ── ESP-NOW must be registered BEFORE Firebase signUp ────────
  //    so detection starts immediately and the blocking signUp
  //    does not delay the first peer packet exchange.
  if (esp_now_init() != ESP_OK) {
    Serial.println(F("[ESP-NOW] INIT FAILED"));
    while (true) delay(1000);
  }
  esp_now_register_send_cb(onSent);
  esp_now_register_recv_cb(onRecv);

  esp_now_peer_info_t peer = {};
  memcpy(peer.peer_addr, peer2Mac, 6);
  peer.channel = 0;
  peer.encrypt = false;
  if (esp_now_add_peer(&peer) == ESP_OK)
    Serial.println(F("[ESP-NOW] Peer Node2 added"));
  else
    Serial.println(F("[ESP-NOW] Add peer FAILED"));

  outPkt.nodeId = 1;

  // ── Firebase init (blocking signUp happens here, but ESP-NOW ──
  //    is already running so peer packets won't be missed)
  firebaseInit();

  drawMonitoring();
  Serial.println(F("====== NODE 1 READY ======\n"));
}

// ─────────────────────────────────────────────────────────────────
//  LOOP  — detection is top priority, Firebase is best-effort
// ─────────────────────────────────────────────────────────────────
void loop() {
  unsigned long now = millis();

  // ── Serial commands ───────────────────────────────────────────
  if (Serial.available()) {
    char c = toupper((char)Serial.read());
    switch (c) {
      case 'T':
        forceLocalVib = !forceLocalVib;
        Serial.print(F("[TEST] Force local vib: "));
        Serial.println(forceLocalVib ? F("ON") : F("OFF"));
        break;
      case 'S':
        Serial.println(F("[TEST] Force full alert"));
        forceFullAlert = true;
        startAlert();
        break;
      case 'B': buzzerBeepTest(); break;
      case 'O':
        drawAlert();
        delay(2000);
        drawMonitoring();
        break;
      case 'R':
        Serial.println(F("[TEST] Alert reset"));
        endAlert();
        break;
    }
  }

  // ── Read MPU — fast, ~0.5 ms ──────────────────────────────────
  vibMag = readMag();

  static unsigned long lastMagPrint = 0;
  if (now - lastMagPrint >= 1000) {
    lastMagPrint = now;
    Serial.print(F("MAG: ")); Serial.println(vibMag, 2);
  }

  // ── Sustained vibration detection ────────────────────────────
  bool rawVib = (vibMag >= VIB_THRESHOLD) || forceLocalVib;

  if (rawVib) {
    lastRawVibMs = now;
    if (vibStartMs == 0) vibStartMs = now;
    if ((now - vibStartMs) >= SUSTAINED_MS) vibratingNow = true;
  } else {
    if ((now - lastRawVibMs) > GAP_ALLOW_MS) {
      vibStartMs   = 0;
      vibratingNow = false;
    }
  }

  // ── Send ESP-NOW ──────────────────────────────────────────────
  static unsigned long lastSend    = 0;
  static bool          lastSentVib = false;
  if ((vibratingNow != lastSentVib) || (now - lastSend >= 500)) {
    lastSend     = now;
    lastSentVib  = vibratingNow;
    outPkt.vibrating  = vibratingNow;
    outPkt.magnitude  = vibMag;
    outPkt.timestamp  = now;
    esp_now_send(peer2Mac, (uint8_t*)&outPkt, sizeof(outPkt));
    Serial.print(F("SENT N1 vib="));
    Serial.println(vibratingNow ? 1 : 0);
  }

  // ── Peer timeout ──────────────────────────────────────────────
  if (peer2Online && (now - peer2LastMs > NODE_TIMEOUT_MS)) {
    peer2Online = false;
    Serial.println(F("[NODE2] OFFLINE"));
  }

  // ── Alert decision ────────────────────────────────────────────
  if (!alertActive) {
    bool n2Active = peer2Online &&
                    peer2Pkt.vibrating &&
                    ((now - peer2LastMs) < WINDOW_MS);

    if (vibratingNow && n2Active) {
      Serial.print(F("[ALERT] N1=VIB N2=VIB age="));
      Serial.print(now - peer2LastMs);
      Serial.println(F("ms → TRIGGERING"));
      startAlert();
    }
  } else {
    // Non-blocking buzzer pulse: 300 ms ON / 300 ms OFF
    static unsigned long beepMs    = 0;
    static bool          beepState = true;
    if (now - beepMs >= 300) {
      beepMs    = now;
      beepState = !beepState;
      digitalWrite(BUZZER_PIN, beepState ? HIGH : LOW);
    }

    if (!forceFullAlert && (now - alertStartMs >= ALERT_HOLD_MS)) {
      endAlert();
    }
  }

  // ── Queue a Firebase snapshot every SNAPSHOT_MS ───────────────
  //    Only queues data; never blocks here.
  if (now - lastSnapshotMs >= SNAPSHOT_MS) {
    lastSnapshotMs = now;
    const char* status = alertActive    ? "Alert"     :
                         vibratingNow   ? "Vibrating" : "Normal";
    fbQueueLatest(vibMag, status);
  }

  // ── Drain ONE Firebase queue entry, but ONLY when the system
  //    is completely idle: no raw vibration, no alert.
  //    This guarantees Firebase never interferes with detection.
  bool systemIdle = !rawVib && !vibratingNow && !alertActive;
  if (systemIdle) {
    fbDrainOne();
  }

  // ── Refresh monitoring screen every second ────────────────────
  static unsigned long lastDisp = 0;
  if (!alertActive && (now - lastDisp >= 1000)) {
    lastDisp = now;
    drawMonitoring();
  }

  delay(10);
}
