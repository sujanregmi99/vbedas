/*
 * ================================================================
 *  EARTHQUAKE DETECTION — NODE 2  (GSM SMS ALERT + FIREBASE)
 * ================================================================
 *  Hardware:
 *    ESP32
 *    MPU6050   I2C  SDA=22  SCL=21
 *    SIM800L   UART TX→GPIO16(ESP RX), RX→GPIO17(ESP TX via divider)
 *              !! External 3.7-4.2 V / 2 A supply — NOT from ESP32 !!
 *              !! Voltage divider on ESP TX: 2kΩ → SIM RX → 3.3kΩ → GND !!
 *
 *  THIS node MAC : F0:24:F9:0D:8A:3C
 *  Node 1   MAC  : A8:42:E3:5B:D2:C8
 *
 * ── FIX SUMMARY ─────────────────────────────────────────────────
 *  Same queue-based Firebase decoupling as Node 1:
 *    • fbQueue[] holds pending writes processed one-per-loop when idle.
 *    • SMS alert sent to up to 5 phone numbers (SMS_NUMBERS[] array).
 *      Add numbers and increment SMS_COUNT to enable them.
 *    • Firebase.ready() check moved out of the hot detection path.
 *    • Snapshot interval raised to 2 s (was 500 ms) to reduce queue
 *      pressure; overwrite logic prevents stale data pile-up.
 *    • ESP-NOW registered before Firebase signUp.
 *
 * ── LIBRARIES ────────────────────────────────────────────────────
 *   Adafruit MPU6050
 *   Adafruit Unified Sensor
 *   Firebase ESP Client  by Mobizt
 *
 * ── SERIAL COMMANDS (115200 baud) ────────────────────────────────
 *   t → toggle force LOCAL vibration
 *   s → force FULL ALERT + send SMS now
 *   m → send test SMS immediately
 *   i → re-run SIM800L init
 *   r → reset alert state
 * ================================================================
 */

#include <WiFi.h>
#include <esp_now.h>
#include <Wire.h>
#include <Adafruit_MPU6050.h>
#include <Adafruit_Sensor.h>
#include <HardwareSerial.h>
#include <Firebase_ESP_Client.h>

// ── Pins ──────────────────────────────────────────────────────────
#define SIM_ESP_RX  16
#define SIM_ESP_TX  17
#define I2C_SCL     21
#define I2C_SDA     22

// ── Tuning ────────────────────────────────────────────────────────
#define VIB_THRESHOLD    0.25f
#define SUSTAINED_MS      200
#define GAP_ALLOW_MS      150
#define WINDOW_MS        3000
#define ALERT_HOLD_MS   10000
#define NODE_TIMEOUT_MS  5000
#define SMS_COOLDOWN_MS 60000

// ── WiFi ──────────────────────────────────────────────────────────
const char* WIFI_SSID = "shashank";
const char* WIFI_PASS = "shashank";

// ── Firebase ──────────────────────────────────────────────────────
#define API_KEY      "AIzaSyC_VAznxpLqoi9xiCXa1SlTNCIaLT4qrRc"
#define DATABASE_URL "https://vbedas-default-rtdb.asia-southeast1.firebasedatabase.app/"

FirebaseData fbdo;
FirebaseAuth auth;
FirebaseConfig config;

bool firebaseReady = false;

// ── Firebase write queue ──────────────────────────────────────────
#define FB_QUEUE_SIZE 24

enum FbWriteType { FB_SET_FLOAT, FB_SET_STRING, FB_SET_INT, FB_PUSH_JSON };

struct FbEntry {
  bool        used;
  FbWriteType type;
  char        path[64];
  float       fVal;
  char        sVal[64];
  int         iVal;
  float       evAccel;
};

FbEntry fbQueue[FB_QUEUE_SIZE];

void fbEnqueueFloat(const char* path, float val) {
  for (int i = 0; i < FB_QUEUE_SIZE; i++) {
    if (!fbQueue[i].used) {
      fbQueue[i].used = true;
      fbQueue[i].type = FB_SET_FLOAT;
      strlcpy(fbQueue[i].path, path, sizeof(fbQueue[i].path));
      fbQueue[i].fVal = val;
      return;
    }
  }
  Serial.println(F("[FB-Q] FULL — float dropped"));
}

void fbEnqueueString(const char* path, const char* val) {
  for (int i = 0; i < FB_QUEUE_SIZE; i++) {
    if (!fbQueue[i].used) {
      fbQueue[i].used = true;
      fbQueue[i].type = FB_SET_STRING;
      strlcpy(fbQueue[i].path, path, sizeof(fbQueue[i].path));
      strlcpy(fbQueue[i].sVal, val,  sizeof(fbQueue[i].sVal));
      return;
    }
  }
  Serial.println(F("[FB-Q] FULL — string dropped"));
}

void fbEnqueueAlert(float accel) {
  for (int i = 0; i < FB_QUEUE_SIZE; i++) {
    if (!fbQueue[i].used) {
      fbQueue[i].used    = true;
      fbQueue[i].type    = FB_PUSH_JSON;
      strlcpy(fbQueue[i].path, "/events", sizeof(fbQueue[i].path));
      fbQueue[i].evAccel = accel;
      return;
    }
  }
  Serial.println(F("[FB-Q] FULL — alert event dropped"));
}

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
        json.set("node",         "node2");
        json.set("acceleration", fbQueue[i].evAccel);
        json.set("threshold",    VIB_THRESHOLD);
        json.set("status",       "Alert");
        json.set("timestamp",    String(millis() / 1000) + " sec");
        ok = Firebase.RTDB.pushJSON(&fbdo, fbQueue[i].path, &json);
        break;
      }
    }

    fbQueue[i].used = false;

    if (ok) {
      Serial.print(F("[FB] Wrote: ")); Serial.println(fbQueue[i].path);
    } else {
      Serial.print(F("[FB] Failed: ")); Serial.println(fbdo.errorReason());
    }
    return true;
  }
  return false;
}

// Queue a fresh snapshot, overwriting any already-queued values for
// the same paths so stale readings never pile up.
void fbQueueLatest(float delta, const char* status) {
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

  overwriteFloat ("/node2/delta",     delta);
  overwriteFloat ("/node2/threshold", VIB_THRESHOLD);
  overwriteString("/node2/status",    status);
  overwriteString("/node2/online",    "true");
  overwriteString("/node2/device",    "Secondary SMS Node");

  char tsBuf[24];
  snprintf(tsBuf, sizeof(tsBuf), "%lu sec", millis() / 1000);
  overwriteString("/node2/timestamp", tsBuf);
}

// ── Firebase init ─────────────────────────────────────────────────
void firebaseInit() {
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println(F("[Firebase] No WiFi — skipping"));
    return;
  }
  Serial.println(F("[Firebase] Connecting..."));

  config.api_key      = API_KEY;
  config.database_url = DATABASE_URL;

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

// ── SMS recipients (add up to 5 numbers; set SMS_COUNT to match) ──
#define SMS_MAX     5
#define SMS_COUNT   2   // ← change this when you add more numbers

const char* SMS_NUMBERS[SMS_MAX] = {
  "+9779814735285",   // recipient 1
  "+9779806131147",                 // recipient 2  (leave "" if unused)
  "",                 // recipient 3
  "",                 // recipient 4
  "",                 // recipient 5
};

// ── Peer MAC ──────────────────────────────────────────────────────
uint8_t peer1Mac[6] = {0xA8, 0x42, 0xE3, 0x5B, 0xD2, 0xC8};

// ── Packet structure ──────────────────────────────────────────────
typedef struct __attribute__((packed)) {
  uint8_t       nodeId;
  bool          vibrating;
  float         magnitude;
  unsigned long timestamp;
} VibPacket;

// ── SIM800L ───────────────────────────────────────────────────────
HardwareSerial simSerial(1);

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
unsigned long lastSmsMs    = 0;

VibPacket     peer1Pkt;
bool          peer1Online  = false;
unsigned long peer1LastMs  = 0;

bool simReady       = false;
bool forceLocalVib  = false;
bool forceFullAlert = false;

unsigned long lastSnapshotMs           = 0;
const unsigned long SNAPSHOT_MS        = 2000;

unsigned long lastAlertEventMs               = 0;
const unsigned long ALERT_EVENT_COOLDOWN_MS  = 60000;

// ── SIM800L helpers ───────────────────────────────────────────────
void simFlush() {
  delay(20);
  while (simSerial.available()) simSerial.read();
}

String simCmd(const char* cmd, const char* expect = "OK", uint32_t timeoutMs = 3000) {
  simFlush();
  simSerial.println(cmd);
  String resp = "";
  unsigned long t = millis();
  while (millis() - t < timeoutMs) {
    while (simSerial.available()) resp += (char)simSerial.read();
    if (resp.indexOf(expect) >= 0) break;
    delay(10);
  }
  resp.trim();
  return resp;
}

bool simInit() {
  Serial.println(F("[SIM] Starting SIM800L init..."));
  simReady = false;
  delay(5000);

  String r;
  bool atOk = false;
  for (int i = 0; i < 10; i++) {
    simSerial.println("AT");
    delay(500);
    r = "";
    while (simSerial.available()) r += (char)simSerial.read();
    if (r.indexOf("OK") >= 0) { atOk = true; break; }
    Serial.print(F("[SIM] AT try ")); Serial.println(i + 1);
  }
  if (!atOk) { Serial.println(F("[SIM] No response")); return false; }

  simCmd("ATE0");
  r = simCmd("AT+CMGF=1");
  if (r.indexOf("OK") < 0) { Serial.println(F("[SIM] CMGF FAILED")); return false; }
  simCmd("AT+CSCS=\"GSM\"");

  r = simCmd("AT+CPIN?", "READY", 5000);
  if (r.indexOf("READY") < 0) { Serial.println(F("[SIM] No SIM card")); return false; }

  bool netOk = false;
  for (int i = 0; i < 15; i++) {
    r = simCmd("AT+CREG?", "OK", 2000);
    if (r.indexOf(",1") >= 0 || r.indexOf(",5") >= 0) { netOk = true; break; }
    Serial.print(F("[SIM] Waiting network... ")); Serial.println(i + 1);
    delay(2000);
  }
  if (!netOk) { Serial.println(F("[SIM] No network")); return false; }

  r = simCmd("AT+CSQ");
  Serial.print(F("[SIM] Signal: ")); Serial.println(r);

  simReady = true;
  Serial.println(F("SIM INIT OK"));
  return true;
}

bool sendSMS(const char* number, const char* msg) {
  if (!simReady) { Serial.println(F("[SMS] SIM not ready")); return false; }
  Serial.print(F("[SMS] Sending to ")); Serial.println(number);

  String cmd = String("AT+CMGS=\"") + number + "\"";
  simFlush();
  simSerial.println(cmd);

  unsigned long t = millis();
  String resp = "";
  while (millis() - t < 5000) {
    while (simSerial.available()) resp += (char)simSerial.read();
    if (resp.indexOf('>') >= 0) break;
    delay(10);
  }
  if (resp.indexOf('>') < 0) { Serial.println(F("[SMS] No > prompt")); return false; }

  simSerial.print(msg);
  delay(200);
  simSerial.write(26);

  resp = ""; t = millis();
  while (millis() - t < 15000) {
    while (simSerial.available()) resp += (char)simSerial.read();
    if (resp.indexOf("+CMGS:") >= 0) { Serial.println(F("SMS SENT")); return true; }
    if (resp.indexOf("ERROR")  >= 0) { Serial.println(F("[SMS] ERROR")); return false; }
    delay(10);
  }
  Serial.println(F("[SMS] Timeout"));
  return false;
}

// ── Alert start / end ─────────────────────────────────────────────
void startAlert() {
  if (alertActive) return;
  alertActive  = true;
  alertStartMs = millis();
  Serial.println(F(">>> EARTHQUAKE DETECTED <<<"));

  // Send SMS to every configured recipient (up to SMS_COUNT).
  // Each sendSMS() has its own 15 s timeout; the loop runs only
  // once per SMS_COOLDOWN_MS so it never spams.
  unsigned long now = millis();
  if (lastSmsMs == 0 || (now - lastSmsMs) >= SMS_COOLDOWN_MS) {
    lastSmsMs = now;
    int sent = 0;
    for (int i = 0; i < SMS_COUNT && i < SMS_MAX; i++) {
      if (SMS_NUMBERS[i][0] == '\0') continue;  // skip blank slots
      Serial.print(F("[SMS] Sending to recipient "));
      Serial.println(i + 1);
      if (sendSMS(SMS_NUMBERS[i], "EARTHQUAKE DETECTED - BOTH NODES CONFIRMED"))
        sent++;
    }
    Serial.print(F("[SMS] Sent to "));
    Serial.print(sent);
    Serial.print(F(" / "));
    Serial.print(SMS_COUNT);
    Serial.println(F(" recipients"));
  } else {
    Serial.print(F("[SMS] Cooldown: "));
    Serial.print((SMS_COOLDOWN_MS - (now - lastSmsMs)) / 1000);
    Serial.println(F(" s remaining"));
  }

  // Queue Firebase alert event — does NOT block
  if (lastAlertEventMs == 0 || (now - lastAlertEventMs) >= ALERT_EVENT_COOLDOWN_MS) {
    lastAlertEventMs = now;
    fbEnqueueAlert(vibMag);
    fbQueueLatest(vibMag, "Alert");
  }
}

void endAlert() {
  alertActive    = false;
  forceFullAlert = false;
  Serial.println(F("--- Alert cleared ---\n"));
}

// ── ESP-NOW callbacks ─────────────────────────────────────────────
void onSent(const uint8_t* mac, esp_now_send_status_t st) {
  if (st != ESP_NOW_SEND_SUCCESS)
    Serial.println(F("[ESP-NOW] SEND FAILED"));
}

void onRecv(const esp_now_recv_info_t* info, const uint8_t* data, int len) {
  if (len != sizeof(VibPacket)) return;
  memcpy(&peer1Pkt, data, len);
  peer1Online = true;
  peer1LastMs = millis();

  static bool prevVib = false;
  if (peer1Pkt.vibrating != prevVib) {
    prevVib = peer1Pkt.vibrating;
    Serial.print(F("RECV N1 vib="));
    Serial.println(peer1Pkt.vibrating ? 1 : 0);
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
  Serial.println(F("\n====== NODE 2 BOOT ======"));
  Serial.println(F("Cmds: t=localVib s=forceAlert m=testSMS i=simInit r=reset"));

  memset(fbQueue, 0, sizeof(fbQueue));

  simSerial.begin(9600, SERIAL_8N1, SIM_ESP_RX, SIM_ESP_TX);
  delay(100);

  Wire.begin(I2C_SDA, I2C_SCL);
  Wire.setClock(400000);

  if (!mpu.begin()) {
    Serial.println(F("[MPU] INIT FAILED"));
    while (true) delay(1000);
  }
  mpu.setAccelerometerRange(MPU6050_RANGE_8_G);
  mpu.setFilterBandwidth(MPU6050_BAND_21_HZ);
  Serial.println(F("[MPU] OK"));

  // WiFi
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  unsigned long wt = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - wt < 8000) delay(300);
  if (WiFi.status() == WL_CONNECTED)
    Serial.println(F("[WiFi] Connected"));
  else
    Serial.println(F("[WiFi] Timeout (ESP-NOW still works)"));
  Serial.print(F("[WiFi] MAC: ")); Serial.println(WiFi.macAddress());

  // ── ESP-NOW before Firebase signUp (same reasoning as Node 1) ─
  if (esp_now_init() != ESP_OK) {
    Serial.println(F("[ESP-NOW] INIT FAILED"));
    while (true) delay(1000);
  }
  esp_now_register_send_cb(onSent);
  esp_now_register_recv_cb(onRecv);

  esp_now_peer_info_t peer = {};
  memcpy(peer.peer_addr, peer1Mac, 6);
  peer.channel = 0;
  peer.encrypt = false;
  if (esp_now_add_peer(&peer) == ESP_OK)
    Serial.println(F("[ESP-NOW] Peer Node1 added"));
  else
    Serial.println(F("[ESP-NOW] Add peer FAILED"));

  outPkt.nodeId = 2;

  // SIM800L (blocking init — happens only once at boot)
  simInit();
  // Firebase (blocking signUp, but ESP-NOW already running)
  firebaseInit();


  Serial.println(F("====== NODE 2 READY ======\n"));
}

// ─────────────────────────────────────────────────────────────────
//  LOOP
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
      case 'M':
        Serial.println(F("[TEST] Sending test SMS to all recipients"));
        for (int i = 0; i < SMS_COUNT && i < SMS_MAX; i++) {
          if (SMS_NUMBERS[i][0] == '\0') continue;
          Serial.print(F("[TEST] Recipient ")); Serial.println(i + 1);
          sendSMS(SMS_NUMBERS[i], "TEST - Node2 SMS working");
        }
        break;
      case 'I': simInit(); break;
      case 'R':
        Serial.println(F("[TEST] Alert reset"));
        endAlert();
        break;
    }
  }

  // ── Read MPU ──────────────────────────────────────────────────
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
    esp_now_send(peer1Mac, (uint8_t*)&outPkt, sizeof(outPkt));
    Serial.print(F("SENT N2 vib="));
    Serial.println(vibratingNow ? 1 : 0);
  }

  // ── Peer timeout ──────────────────────────────────────────────
  if (peer1Online && (now - peer1LastMs > NODE_TIMEOUT_MS)) {
    peer1Online = false;
    Serial.println(F("[NODE1] OFFLINE"));
  }

  // ── Alert decision ────────────────────────────────────────────
  if (!alertActive) {
    bool n1Active = peer1Online &&
                    peer1Pkt.vibrating &&
                    ((now - peer1LastMs) < WINDOW_MS);

    if (vibratingNow && n1Active) {
      Serial.print(F("[ALERT] N2=VIB N1=VIB age="));
      Serial.print(now - peer1LastMs);
      Serial.println(F("ms → TRIGGERING"));
      startAlert();
    }
  } else {
    if (!forceFullAlert && (now - alertStartMs >= ALERT_HOLD_MS)) {
      endAlert();
    }
  }

  // ── Queue Firebase snapshot every SNAPSHOT_MS ────────────────
  if (now - lastSnapshotMs >= SNAPSHOT_MS) {
    lastSnapshotMs = now;
    const char* status = alertActive  ? "Alert"     :
                         vibratingNow ? "Vibrating" : "Normal";
    fbQueueLatest(vibMag, status);
  }

  // ── Drain ONE Firebase entry only when system is idle ─────────
  bool systemIdle = !rawVib && !vibratingNow && !alertActive;
  if (systemIdle) {
    fbDrainOne();
  }

  delay(10);
}
