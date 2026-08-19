/*
  ESP32 Smart Home + multiple PCF8574 I/O modules + Ellie voice assistant

  The Flutter app configures up to two independent hardware I2C buses:
    Bus 0 example: SDA GPIO21, SCL GPIO22
    Bus 1 example: SDA GPIO4,  SCL GPIO14

  More than two PCF8574 modules are supported by sharing either bus and using
  different PCF8574 addresses through A0/A1/A2. The original ESP32 has two
  hardware I2C controllers, so only bus IDs 0 and 1 are accepted.

  Ellie architecture:
    Flutter on-device microphone recognition -> local HTTP/BLE intent parser
    -> relay control + deterministic local replies + optional ESP32 speech

  The assistant has no OpenAI client, API key, cloud conversation fallback,
  remote TTS URL, or assistant backend. Firebase below remains optional home
  state/registration sync only; it never generates assistant replies or audio.

  Device addressing:
    moduleId + channel 0..7
    Example: io_1/P0 and io_2/P0 are different outputs.
*/

#ifndef ELLIE_SPEAKER_ENABLED
#define ELLIE_SPEAKER_ENABLED 1
#endif

// Speaker support is optional. AudioOutputI2S from ESP8266Audio drives the I2S
// amplifier and ESP8266SAM generates English speech completely on-device.
// The sketch still compiles when these libraries are absent; only ESP speech
// output is disabled. Intent matching and device control continue to work.
#if ELLIE_SPEAKER_ENABLED
  #ifdef __has_include
    #if __has_include(<AudioOutputI2S.h>)
      #define ELLIE_AUDIO_LIBRARIES_AVAILABLE 1
    #else
      #define ELLIE_AUDIO_LIBRARIES_AVAILABLE 0
    #endif
    #if __has_include(<ESP8266SAM.h>)
      #define ELLIE_SAM_LIBRARY_AVAILABLE 1
    #else
      #define ELLIE_SAM_LIBRARY_AVAILABLE 0
    #endif
  #else
    #define ELLIE_AUDIO_LIBRARIES_AVAILABLE 0
    #define ELLIE_SAM_LIBRARY_AVAILABLE 0
  #endif
#else
  #define ELLIE_AUDIO_LIBRARIES_AVAILABLE 0
  #define ELLIE_SAM_LIBRARY_AVAILABLE 0
#endif

#if ELLIE_SPEAKER_ENABLED && !ELLIE_AUDIO_LIBRARIES_AVAILABLE
  #warning "Local ESP32 speech disabled: install ESP8266Audio for AudioOutputI2S."
  #undef ELLIE_SPEAKER_ENABLED
  #define ELLIE_SPEAKER_ENABLED 0
#endif

#if ELLIE_SPEAKER_ENABLED && !ELLIE_SAM_LIBRARY_AVAILABLE
  #warning "Local ESP32 speech disabled: install ESP8266SAM for offline English speech."
  #undef ELLIE_SPEAKER_ENABLED
  #define ELLIE_SPEAKER_ENABLED 0
#endif

#include <WiFi.h>
#include <HTTPClient.h>
#include <WiFiClientSecure.h>
#include <DHT.h>
#include <Preferences.h>
#include <DNSServer.h>
#include <WebServer.h>
#include <ArduinoJson.h>
#include <time.h>
#include <map>
#include <vector>
#include <esp_chip_info.h>
#include <esp_mac.h>
#include <NimBLEDevice.h>
#include <Wire.h>
#include <ctype.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <freertos/task.h>

#if ELLIE_SPEAKER_ENABLED
#include <AudioOutputI2S.h>
#include <ESP8266SAM.h>
#endif

// =======================
// PINS & SENSORS
// =======================
#define DHTPIN 15
#define DHTTYPE DHT11
DHT dht(DHTPIN, DHTTYPE);
#define FLAME_SENSOR_PIN 34

// =======================
// ELLIE VOICE ASSISTANT
// =======================
#define ELLIE_DEFAULT_NAME "Ellie"
#define SMART_HOME_FIRMWARE_VERSION "2.6.0-music-multidevice"
#define ELLIE_MAX_NAME_BYTES 72
#define ELLIE_I2S_BCLK_PIN 26
#define ELLIE_I2S_LRC_PIN 25
#define ELLIE_I2S_DOUT_PIN 27
#define ELLIE_SPEECH_QUEUE_LENGTH 4
#define ELLIE_MAX_SPEECH_CHARS 220
#define ELLIE_MAX_INPUT_CHARS 320
#define ELLIE_SPEAKER_GAIN 0.55f

// =======================
// DYNAMIC I2C / PCF8574 HARDWARE
// =======================
#define MAX_I2C_BUSES 2
#define MAX_IO_MODULES 16
#define PCF8574_CHANNEL_COUNT 8
#define DEFAULT_I2C_FREQUENCY 100000
#define I2C_TRANSACTION_TIMEOUT_MS 30
#define DEFAULT_MODULE_ID "io_1"
#define PCF8574_RETRY_INTERVAL 5000

// =======================
// FIREBASE
// =======================
#define DATABASE_URL "https://iot-smart-home-81abd-default-rtdb.europe-west1.firebasedatabase.app"

// =======================
// AP CONFIG
// =======================
#define AP_SSID "ESP32_Config"
#define AP_PASSWORD "12345678"
#define WIFI_TIMEOUT_SEC 30

// =======================
// TIMING INTERVALS
// =======================
// Sensor/heartbeat traffic should not block real-time control too often.
// Control latency comes from local HTTP + SSE, not from these background uploads.
const unsigned long SEND_INTERVAL = 30000;
const unsigned long HEARTBEAT_INTERVAL = 30000;
const unsigned long STREAM_RECONNECT_INTERVAL = 5000;
const unsigned long OWNER_CHECK_INTERVAL = 30000;
const unsigned long SYNC_INTERVAL = 300000;  // SSE handles device changes; fallback sync every 5 minutes
const unsigned long HARDWARE_SYNC_INTERVAL = 30000; // Apply I/O module changes from the app
// Ignore delayed Firebase echoes that disagree with a recent local/BLE command.
// This prevents a stale cloud event from switching the relay back and causing chatter.
const unsigned long LOCAL_COMMAND_GUARD_MS = 15000;
const unsigned long CLOUD_UPLOAD_RETRY_MS = 2000;

// Firebase REST is still synchronous on Arduino HTTPClient. Keep timeouts short so
// one slow HTTPS request cannot freeze local control for several seconds.
const uint16_t FIREBASE_HTTP_TIMEOUT_MS = 1200;
const uint16_t FIREBASE_LONG_HTTP_TIMEOUT_MS = 2500;
const bool VERBOSE_LOGS = false;

// =======================
// GLOBALS
// =======================
WiFiClientSecure client;
Preferences prefs;
WebServer server(80);
DNSServer dnsServer;

String savedSSID, savedPass;
bool useCaptivePortal = false;

unsigned long lastSend = 0;
unsigned long lastHeartbeat = 0;
unsigned long lastStreamReconnect = 0;
unsigned long lastOwnerCheck = 0;
unsigned long lastSync = 0;
bool manualSyncRequested = false;

// Two independent hardware I2C controllers on the original ESP32.
// Use the Arduino global Wire object for controller 0 and a separate object for controller 1.
TwoWire i2cBus1 = TwoWire(1);

struct I2CBusConfig {
  int id;
  int sda;
  int scl;
  uint32_t frequency;
  bool enabled;
  bool started;

  I2CBusConfig() : id(0), sda(21), scl(22), frequency(DEFAULT_I2C_FREQUENCY), enabled(false), started(false) {}
};

struct IOModule {
  String id;
  String name;
  int busId;
  uint8_t address;
  bool activeLow;
  bool enabled;
  bool ready;
  uint8_t outputState;
  unsigned long lastRetry;

  IOModule()
      : id(""), name(""), busId(0), address(0x20), activeLow(true), enabled(true),
        ready(false), outputState(0xFF), lastRetry(0) {}
};

I2CBusConfig i2cBuses[MAX_I2C_BUSES];
std::map<String, IOModule> ioModules;
Preferences hardwarePrefs;
unsigned long lastHardwareSync = 0;
bool manualHardwareSyncRequested = false;
String hardwareConfigSignature = "";

WiFiClientSecure streamClient;
bool streamConnected = false;
String streamBuffer = "";

// Registration & UID
String esp32UniqueCode = "";
String registeredUID = "";
String registeredEmail = "";
bool isRegistered = false;
String firebasePath = "";

// Assistant identity is customer-specific and stored locally in ESP32 NVS.
// It is never written to Firebase or sent to an assistant service.
Preferences assistantPrefs;
String assistantName = ELLIE_DEFAULT_NAME;

// =======================
// DEVICE MANAGEMENT
// =======================
struct Device {
  String id;
  String name;
  int type;
  String moduleId;
  int channel;
  bool state;
  String room;
  bool enabled;

  Device()
      : id(""), name(""), type(0), moduleId(DEFAULT_MODULE_ID), channel(0),
        state(false), room(""), enabled(true) {}
  Device(String _id, String _name, int _type, String _moduleId, int _channel, String _room)
      : id(_id), name(_name), type(_type), moduleId(_moduleId), channel(_channel),
        state(false), room(_room), enabled(true) {}
};

struct EllieResult {
  bool handled;
  bool needsFallback;
  String intent;
  String reply;
  String offlineReply;
  std::vector<String> affectedIds;

  EllieResult()
      : handled(false), needsFallback(false), intent("unknown"), reply(""),
        offlineReply("I did not understand that local request. Try a device, room, sensor, time, or help command.") {}
};

std::map<String, Device> devices;
Preferences devicePrefs;
std::map<String, bool> outputStates;

// Forward declarations for local API/CORS helpers
void addCorsHeaders();
void sendCorsJson(int code, const String& json);
void handleCorsOptions();
void registerCorsOptions(const char* path);

// Local toggles must switch the PCF8574 channel immediately. Firebase upload is queued
// and flushed after the HTTP response so the phone UI does not wait for HTTPS.
// This map stores the latest pending cloud state per device, so fast toggles
// on different devices do not overwrite each other.
bool pendingCloudStateUpload = false;
std::map<String, bool> pendingCloudStates;
unsigned long pendingCloudStateAt = 0;
unsigned long nextCloudUploadAttemptAt = 0;
bool cloudUploadInFlight = false;

// Firebase HTTPS is synchronous. A dedicated low-priority task performs the
// TLS request so a slow router or Internet outage can never block WebServer,
// BLE, I2C relay control, or the Arduino loop after a local command.
#define CLOUD_UPLOAD_ID_BYTES 96
#define CLOUD_UPLOAD_PATH_BYTES 256
struct CloudStateUploadJob {
  char id[CLOUD_UPLOAD_ID_BYTES];
  char path[CLOUD_UPLOAD_PATH_BYTES];
  bool state;
};

struct CloudStateUploadResult {
  char id[CLOUD_UPLOAD_ID_BYTES];
  bool state;
  bool success;
};

QueueHandle_t cloudUploadQueue = nullptr;
QueueHandle_t cloudUploadResultQueue = nullptr;
TaskHandle_t cloudUploadTaskHandle = nullptr;

// Desired states from the most recent direct command. While the guard is active,
// older Firebase/SSE values are not allowed to reverse the physical relay.
std::map<String, bool> guardedDeviceStates;
std::map<String, unsigned long> guardedDeviceStateTimes;

// Wi-Fi reconnect is non-blocking so BLE backup stays responsive when internet/router is down.
const unsigned long WIFI_RECONNECT_INTERVAL = 5000;
unsigned long lastWifiReconnectAttempt = 0;
bool wifiWasConnected = false;

// Wi-Fi changes are acknowledged first, then the ESP restarts shortly after.
bool pendingWifiRestart = false;
unsigned long pendingWifiRestartAt = 0;

#if ELLIE_SPEAKER_ENABLED
struct EllieSpeechMessage {
  char text[ELLIE_MAX_SPEECH_CHARS + 1];
};

QueueHandle_t ellieSpeechQueue = nullptr;
TaskHandle_t ellieSpeechTaskHandle = nullptr;
#endif

// =======================
// BLE BACKUP CONTROL
// =======================
// Lightweight BLE layer used only as a backup when internet/local Wi-Fi control is not available.
// Requires Arduino Library Manager: NimBLE-Arduino
#define BLE_DEVICE_NAME "ESP32_SmartHome"
#define BLE_SERVICE_UUID "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define BLE_COMMAND_CHAR_UUID "d8e3b8a2-4f5c-4b6e-9a2f-1a2b3c4d5e6f"

// Optional BLE PIN protection for write commands.
// Keep BLE_REQUIRE_PIN false until your Flutter app sends {"pin":"1234"} with BLE write commands.
// After the app supports it, set BLE_REQUIRE_PIN to true for customer builds.
#define BLE_REQUIRE_PIN false
#define BLE_CONTROL_PIN "1234"

NimBLEServer* bleServer = nullptr;
NimBLECharacteristic* bleCommandChar = nullptr;
volatile bool bleClientConnected = false;

// NimBLE callbacks run on a Bluetooth host task, not on Arduino's loop task.
// Only copy the incoming bytes there. Device maps, I2C and notifications are
// handled later from loop(), avoiding cross-task map corruption and callback
// re-entrancy deadlocks.
#define BLE_COMMAND_QUEUE_LENGTH 6
#define BLE_MAX_COMMAND_BYTES 511
struct BleCommandMessage {
  char json[BLE_MAX_COMMAND_BYTES + 1];
};

QueueHandle_t bleCommandQueue = nullptr;
volatile bool bleCommandQueueOverflow = false;
uint32_t bleResponseSequence = 0;

void setupBleBackup();
void processPendingBleCommands();
void handleBleCommand(const String& raw);
void bleReply(const String& json);
String buildBleDevicesJson();
String buildBleStatusJson();
bool setDeviceOutputLocal(const String& id, const String& newModuleId, int newChannel);
bool isBleWriteAuthorized(DynamicJsonDocument& doc);

// Ellie assistant helpers
void setupEllieSpeaker();
bool queueEllieSpeech(const String& text);
String sanitizeAssistantName(const String& requestedName);
void loadAssistantName();
bool setAssistantName(const String& requestedName, bool persist = true);
String processEllieText(const String& rawText, bool speakResponse, bool compactResponse = false);

// Core forward declarations required by Arduino/ESP32 builds.
// Some Arduino preprocessors do not auto-generate prototypes correctly
// when functions use String, std::map, callbacks, or are called before definition.
void completeRegistration(String uid);
void syncHardwareFromFirebase();
void syncDevicesFromFirebase();
void applyFirebaseDevices(JsonObject firebaseDevices, bool allowCloudConflictPatch);
void clearAllDevicesLocal();
String buildStatusJson(time_t now, const String& ip, const String& currentSsid, const String& gatewayIp, int rssi);
void updateOnlineStatus();
void setupDeviceAPI();
void connectSSEStream();
void readSSEStream();
void sendSensorsToFirebase();
void setupCloudUploadWorker();
void cloudStateUploadTask(void* parameter);
void flushPendingCloudUploads();
void startCaptivePortal();
void loadRegistration();
void loadCredentials();
void connectToWiFi();
void checkOwnerUID();
void loadDevicesFromPreferences();
void setDeviceStateInternal(String id, bool state, bool writeFirebase);
void setDeviceState(String id, bool state);
String addDevice(String name, int type, String moduleId, int channel, String room, String requestedId = "", bool writeFirebase = true);
void removeDevice(String id);

// Dynamic PCF8574 / I2C helpers
void setDefaultHardwareConfig();
void loadHardwareFromPreferences();
void saveHardwareToPreferences();
String buildHardwareConfigJson();
bool applyHardwareConfigJson(const String& json, bool persist, bool reinitialize);
void setupAllIOModules();
void retryOfflineIOModules(unsigned long now);
TwoWire* getI2CBus(int busId);
bool isValidI2CPin(int pin);
bool isValidPcfChannel(int channel);
bool moduleExists(const String& moduleId);
String outputKey(const String& moduleId, int channel);
bool setRelayOutput(const String& moduleId, int channel, bool state);
uint8_t buildDesiredModuleByte(const IOModule& module);
bool shouldIgnoreCloudState(const String& id, bool cloudState);
void turnAllRelaysOff();
void reapplyCachedRelayStates();

// =======================
// GENERATE UNIQUE ESP32 CODE
// =======================
String generateUniqueCode() {
  uint8_t mac[6];
  esp_read_mac(mac, ESP_MAC_WIFI_STA);
  char macStr[18];
  snprintf(macStr, sizeof(macStr), "%02X%02X%02X%02X%02X%02X", mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
  esp_chip_info_t chip_info;
  esp_chip_info(&chip_info);
  String code = "ESP32-";
  code += String(macStr);
  code += "-";
  code += String(chip_info.revision);
  code += "-";
  code += String(chip_info.model);
  return code;
}

String jsonEscape(const String& value) {
  String out = "";
  for (size_t i = 0; i < value.length(); i++) {
    char c = value.charAt(i);
    if (c == '\\') out += "\\\\";
    else if (c == '"') out += "\\\"";
    else if (c == '\n') out += "\\n";
    else if (c == '\r') out += "\\r";
    else if (c == '\t') out += "\\t";
    else out += c;
  }
  return out;
}

String wifiEncryptionName(wifi_auth_mode_t type) {
  switch (type) {
    case WIFI_AUTH_OPEN: return "open";
    case WIFI_AUTH_WEP: return "WEP";
    case WIFI_AUTH_WPA_PSK: return "WPA";
    case WIFI_AUTH_WPA2_PSK: return "WPA2";
    case WIFI_AUTH_WPA_WPA2_PSK: return "WPA/WPA2";
    case WIFI_AUTH_WPA2_ENTERPRISE: return "WPA2-Enterprise";
    case WIFI_AUTH_WPA3_PSK: return "WPA3";
    case WIFI_AUTH_WPA2_WPA3_PSK: return "WPA2/WPA3";
    default: return "secured";
  }
}

bool isSecureWifi(wifi_auth_mode_t type) {
  return type != WIFI_AUTH_OPEN;
}

String readRequestArg(const String& key) {
  if (server.hasArg(key)) return server.arg(key);

  if (server.hasArg("plain")) {
    String body = server.arg("plain");
    if (body.length() > 0) {
      DynamicJsonDocument doc(1024);
      DeserializationError err = deserializeJson(doc, body);
      if (!err && doc.containsKey(key)) {
        return doc[key].as<String>();
      }
    }
  }

  return "";
}

// =======================
// DYNAMIC PCF8574 / I2C FUNCTIONS
// =======================
TwoWire* getI2CBus(int busId) {
  if (busId == 0) return &Wire;
  if (busId == 1) return &i2cBus1;
  return nullptr;
}

bool isValidI2CPin(int pin) {
  if (pin < 0 || pin > 33) return false;
  if (pin >= 6 && pin <= 11) return false; // connected to ESP32 flash
  if (pin == DHTPIN) return false;
#if ELLIE_SPEAKER_ENABLED
  if (pin == ELLIE_I2S_BCLK_PIN || pin == ELLIE_I2S_LRC_PIN || pin == ELLIE_I2S_DOUT_PIN) return false;
#endif
  return true;
}

bool isValidPcfChannel(int channel) {
  return channel >= 0 && channel < PCF8574_CHANNEL_COUNT;
}

String outputKey(const String& moduleId, int channel) {
  return moduleId + ":" + String(channel);
}

bool moduleExists(const String& moduleId) {
  auto it = ioModules.find(moduleId);
  return it != ioModules.end() && it->second.enabled;
}

void setDefaultHardwareConfig() {
  for (int i = 0; i < MAX_I2C_BUSES; i++) {
    i2cBuses[i] = I2CBusConfig();
    i2cBuses[i].id = i;
  }

  i2cBuses[0].sda = 21;
  i2cBuses[0].scl = 22;
  i2cBuses[0].frequency = DEFAULT_I2C_FREQUENCY;
  i2cBuses[0].enabled = true;

  i2cBuses[1].sda = 4;
  i2cBuses[1].scl = 14;
  i2cBuses[1].frequency = DEFAULT_I2C_FREQUENCY;
  i2cBuses[1].enabled = false;

  ioModules.clear();
  IOModule module;
  module.id = DEFAULT_MODULE_ID;
  module.name = "I/O Module 1";
  module.busId = 0;
  module.address = 0x20;
  module.activeLow = true;
  module.enabled = true;
  module.outputState = 0xFF;
  ioModules[module.id] = module;
}

String buildHardwareConfigJson() {
  DynamicJsonDocument doc(8192);
  JsonObject root = doc.to<JsonObject>();

  JsonObject buses = root.createNestedObject("i2cBuses");
  for (int i = 0; i < MAX_I2C_BUSES; i++) {
    JsonObject bus = buses.createNestedObject(String("bus") + String(i));
    bus["id"] = i;
    bus["sda"] = i2cBuses[i].sda;
    bus["scl"] = i2cBuses[i].scl;
    bus["frequency"] = i2cBuses[i].frequency;
    bus["enabled"] = i2cBuses[i].enabled;
  }

  JsonObject modules = root.createNestedObject("ioModules");
  for (auto& pair : ioModules) {
    IOModule& module = pair.second;
    JsonObject item = modules.createNestedObject(module.id);
    item["id"] = module.id;
    item["name"] = module.name;
    item["type"] = "PCF8574";
    item["busId"] = module.busId;
    item["address"] = module.address;
    item["channels"] = PCF8574_CHANNEL_COUNT;
    item["activeLow"] = module.activeLow;
    item["enabled"] = module.enabled;
  }

  String json;
  serializeJson(root, json);
  return json;
}

void saveHardwareToPreferences() {
  hardwarePrefs.begin("hardware", false);
  hardwarePrefs.putString("config", buildHardwareConfigJson());
  hardwarePrefs.end();
}

bool validateHardwareConfig() {
  int moduleCount = 0;
  std::map<String, bool> addressUse;

  for (int i = 0; i < MAX_I2C_BUSES; i++) {
    I2CBusConfig& bus = i2cBuses[i];
    if (!bus.enabled) continue;
    if (!isValidI2CPin(bus.sda) || !isValidI2CPin(bus.scl) || bus.sda == bus.scl) {
      Serial.printf("❌ Invalid I2C bus %d pins: SDA=%d SCL=%d\n", i, bus.sda, bus.scl);
      return false;
    }
    if (bus.frequency < 10000 || bus.frequency > 400000) bus.frequency = DEFAULT_I2C_FREQUENCY;
  }

  for (int a = 0; a < MAX_I2C_BUSES; a++) {
    if (!i2cBuses[a].enabled) continue;
    for (int b = a + 1; b < MAX_I2C_BUSES; b++) {
      if (!i2cBuses[b].enabled) continue;
      if (i2cBuses[a].sda == i2cBuses[b].sda ||
          i2cBuses[a].sda == i2cBuses[b].scl ||
          i2cBuses[a].scl == i2cBuses[b].sda ||
          i2cBuses[a].scl == i2cBuses[b].scl) {
        Serial.printf("❌ I2C buses %d and %d share a GPIO pin\n", a, b);
        return false;
      }
    }
  }

  for (auto& pair : ioModules) {
    IOModule& module = pair.second;
    if (!module.enabled) continue;
    moduleCount++;
    if (moduleCount > MAX_IO_MODULES) return false;
    if (module.busId < 0 || module.busId >= MAX_I2C_BUSES) return false;
    if (!i2cBuses[module.busId].enabled) return false;
    if (!((module.address >= 0x20 && module.address <= 0x27) ||
          (module.address >= 0x38 && module.address <= 0x3F))) {
      return false;
    }
    String key = String(module.busId) + ":" + String(module.address);
    if (addressUse[key]) {
      Serial.println("❌ Duplicate PCF8574 address on the same I2C bus: " + key);
      return false;
    }
    addressUse[key] = true;
  }

  return moduleCount > 0;
}

bool applyHardwareConfigJson(const String& json, bool persist, bool reinitialize) {
  DynamicJsonDocument doc(12288);
  DeserializationError error = deserializeJson(doc, json);
  if (error || !doc.is<JsonObject>()) {
    Serial.println("❌ Invalid hardware configuration JSON");
    return false;
  }

  I2CBusConfig oldBuses[MAX_I2C_BUSES];
  for (int i = 0; i < MAX_I2C_BUSES; i++) oldBuses[i] = i2cBuses[i];
  std::map<String, IOModule> oldModules = ioModules;

  for (int i = 0; i < MAX_I2C_BUSES; i++) {
    i2cBuses[i] = I2CBusConfig();
    i2cBuses[i].id = i;
  }
  ioModules.clear();

  JsonObject root = doc.as<JsonObject>();
  JsonObject buses = root["i2cBuses"].as<JsonObject>();

  // Backward compatibility with the previous single-bus hardware.i2c structure.
  if (buses.isNull() && root["i2c"].is<JsonObject>()) {
    JsonObject oldBus = root["i2c"].as<JsonObject>();
    i2cBuses[0].sda = oldBus["sda"] | 21;
    i2cBuses[0].scl = oldBus["scl"] | 22;
    i2cBuses[0].frequency = oldBus["frequency"] | DEFAULT_I2C_FREQUENCY;
    i2cBuses[0].enabled = true;
  } else {
    for (int i = 0; i < MAX_I2C_BUSES; i++) {
      String key = String("bus") + String(i);
      JsonObject bus = buses[key].as<JsonObject>();
      if (bus.isNull()) continue;
      i2cBuses[i].sda = bus["sda"] | (i == 0 ? 21 : 4);
      i2cBuses[i].scl = bus["scl"] | (i == 0 ? 22 : 14);
      i2cBuses[i].frequency = bus["frequency"] | DEFAULT_I2C_FREQUENCY;
      i2cBuses[i].enabled = bus["enabled"] | true;
    }
  }

  JsonObject modules = root["ioModules"].as<JsonObject>();
  if (modules.isNull()) modules = root["expanders"].as<JsonObject>();

  if (!modules.isNull()) {
    for (JsonPair pair : modules) {
      if (ioModules.size() >= MAX_IO_MODULES || !pair.value().is<JsonObject>()) break;
      JsonObject data = pair.value().as<JsonObject>();
      IOModule module;
      module.id = data["id"] | pair.key().c_str();
      String configuredName = data["name"] | "";
      module.name = configuredName.length() > 0 ? configuredName : module.id;
      module.busId = data["busId"] | 0;
      module.address = (uint8_t)(data["address"] | 32);
      module.activeLow = data["activeLow"] | true;
      module.enabled = data["enabled"] | true;
      module.outputState = module.activeLow ? 0xFF : 0x00;
      ioModules[module.id] = module;
    }
  }

  if (ioModules.empty()) {
    IOModule module;
    module.id = DEFAULT_MODULE_ID;
    module.name = "I/O Module 1";
    module.busId = 0;
    module.address = 0x20;
    module.activeLow = true;
    module.enabled = true;
    ioModules[module.id] = module;
    i2cBuses[0].enabled = true;
    if (i2cBuses[0].sda == 21 && i2cBuses[0].scl == 22) {
      // defaults already suitable
    }
  }

  if (!validateHardwareConfig()) {
    for (int i = 0; i < MAX_I2C_BUSES; i++) i2cBuses[i] = oldBuses[i];
    ioModules = oldModules;
    return false;
  }

  String newSignature = buildHardwareConfigJson();
  bool changed = newSignature != hardwareConfigSignature;
  hardwareConfigSignature = newSignature;

  if (persist) saveHardwareToPreferences();
  if (reinitialize && changed) {
    turnAllRelaysOff();
    Wire.end();
    i2cBus1.end();
    for (int i = 0; i < MAX_I2C_BUSES; i++) i2cBuses[i].started = false;
    setupAllIOModules();
    reapplyCachedRelayStates();
  }
  return true;
}

void loadHardwareFromPreferences() {
  setDefaultHardwareConfig();
  hardwarePrefs.begin("hardware", true);
  String json = hardwarePrefs.getString("config", "");
  hardwarePrefs.end();

  if (json.length() > 2) {
    if (!applyHardwareConfigJson(json, false, false)) {
      setDefaultHardwareConfig();
    }
  }
  hardwareConfigSignature = buildHardwareConfigJson();
}

bool startI2CBus(int busId) {
  if (busId < 0 || busId >= MAX_I2C_BUSES) return false;
  I2CBusConfig& config = i2cBuses[busId];
  if (!config.enabled) return false;
  if (config.started) return true;

  TwoWire* wire = getI2CBus(busId);
  if (!wire) return false;
  bool ok = wire->begin(config.sda, config.scl, config.frequency);
  if (!ok) {
    Serial.printf("❌ Failed to start I2C bus %d on SDA=%d SCL=%d\n", busId, config.sda, config.scl);
    return false;
  }
  wire->setClock(config.frequency);
  wire->setTimeOut(I2C_TRANSACTION_TIMEOUT_MS);
  config.started = true;
  Serial.printf("✅ I2C bus %d started: SDA=%d SCL=%d @ %lu Hz\n",
                busId, config.sda, config.scl, (unsigned long)config.frequency);
  return true;
}

uint8_t buildDesiredModuleByte(const IOModule& module) {
  uint8_t value = module.activeLow ? 0xFF : 0x00;
  for (auto& pair : devices) {
    const Device& device = pair.second;
    if (!device.enabled || device.moduleId != module.id || !isValidPcfChannel(device.channel)) continue;
    const bool outputLow = module.activeLow ? device.state : !device.state;
    if (outputLow) bitClear(value, device.channel);
    else bitSet(value, device.channel);
  }
  return value;
}

bool initializeIOModule(IOModule& module) {
  module.ready = false;
  if (!module.enabled || !startI2CBus(module.busId)) return false;

  TwoWire* wire = getI2CBus(module.busId);
  wire->beginTransmission(module.address);
  if (wire->endTransmission() != 0) {
    Serial.printf("❌ %s not found on bus %d at 0x%02X\n",
                  module.id.c_str(), module.busId, module.address);
    return false;
  }

  // Restore the complete desired byte in one write. The previous implementation
  // wrote all outputs OFF first and then reapplied devices, which created a visible
  // OFF/ON pulse whenever an I2C module reconnected.
  module.outputState = buildDesiredModuleByte(module);
  wire->beginTransmission(module.address);
  wire->write(module.outputState);
  uint8_t result = wire->endTransmission();
  module.ready = result == 0;

  if (module.ready) {
    Serial.printf("✅ %s ready on bus %d at 0x%02X\n",
                  module.id.c_str(), module.busId, module.address);
  }
  return module.ready;
}

void setupAllIOModules() {
  for (auto& pair : ioModules) initializeIOModule(pair.second);
}

void retryOfflineIOModules(unsigned long now) {
  for (auto& pair : ioModules) {
    IOModule& module = pair.second;
    if (!module.enabled || module.ready) continue;
    if (now - module.lastRetry < PCF8574_RETRY_INTERVAL) continue;
    module.lastRetry = now;
    if (initializeIOModule(module)) reapplyCachedRelayStates();
  }
}

bool writeModuleByte(IOModule& module, uint8_t value) {
  if (!module.ready) return false;
  TwoWire* wire = getI2CBus(module.busId);
  if (!wire) return false;

  wire->beginTransmission(module.address);
  wire->write(value);
  uint8_t result = wire->endTransmission();
  if (result != 0) {
    module.ready = false;
    Serial.printf("❌ Write failed for %s at 0x%02X, error=%u\n",
                  module.id.c_str(), module.address, result);
    return false;
  }
  module.outputState = value;
  return true;
}

bool setRelayOutput(const String& moduleId, int channel, bool state) {
  if (!isValidPcfChannel(channel)) return false;
  auto it = ioModules.find(moduleId);
  if (it == ioModules.end() || !it->second.enabled || !it->second.ready) return false;

  IOModule& module = it->second;
  uint8_t next = module.outputState;
  bool outputLow = module.activeLow ? state : !state;
  if (outputLow) bitClear(next, channel);
  else bitSet(next, channel);
  if (next == module.outputState) return true;
  return writeModuleByte(module, next);
}

void turnAllRelaysOff() {
  for (auto& pair : ioModules) {
    IOModule& module = pair.second;
    if (!module.ready) continue;
    writeModuleByte(module, module.activeLow ? 0xFF : 0x00);
  }
}

void reapplyCachedRelayStates() {
  for (auto& pair : devices) {
    Device& device = pair.second;
    setRelayOutput(device.moduleId, device.channel, device.state);
  }
}

// =======================
// FIREBASE HTTP FUNCTIONS
// =======================
void httpPut(const String& path, const String& json, uint16_t timeoutMs = FIREBASE_HTTP_TIMEOUT_MS) {
  if (WiFi.status() != WL_CONNECTED) return;
  HTTPClient http;
  client.setInsecure();
  http.setReuse(true);
  http.begin(client, DATABASE_URL + path);
  http.setTimeout(timeoutMs);
  http.addHeader("Content-Type", "application/json");
  http.addHeader("Connection", "keep-alive");
  int code = http.PUT(json);
  if (VERBOSE_LOGS) {
    if (code > 0) Serial.println("✅ HTTP PUT success: " + path);
    else Serial.printf("❌ HTTP PUT failed: %s\n", http.errorToString(code).c_str());
  }
  http.end();
}

String httpGet(const String& path, uint16_t timeoutMs = FIREBASE_HTTP_TIMEOUT_MS) {
  if (WiFi.status() != WL_CONNECTED) return "";
  HTTPClient http;
  client.setInsecure();
  http.setReuse(true);
  http.begin(client, DATABASE_URL + path);
  http.setTimeout(timeoutMs);
  http.addHeader("Connection", "keep-alive");
  int code = http.GET();
  String payload = (code == 200) ? http.getString() : "";
  if (VERBOSE_LOGS && code <= 0) {
    Serial.printf("❌ HTTP GET failed: %s\n", http.errorToString(code).c_str());
  }
  http.end();
  return payload;
}

String httpPatch(const String& path, const String& json, uint16_t timeoutMs = FIREBASE_HTTP_TIMEOUT_MS) {
  if (WiFi.status() != WL_CONNECTED) return "";
  HTTPClient http;
  client.setInsecure();
  http.setReuse(true);
  http.begin(client, DATABASE_URL + path);
  http.setTimeout(timeoutMs);
  http.addHeader("Content-Type", "application/json");
  http.addHeader("Connection", "keep-alive");
  int code = http.PATCH(json);
  String response = (code == 200) ? http.getString() : "";
  if (VERBOSE_LOGS && code <= 0) {
    Serial.printf("❌ HTTP PATCH failed: %s\n", http.errorToString(code).c_str());
  }
  http.end();
  return response;
}

// =======================
// REGISTRATION FUNCTIONS
// =======================
void checkOwnerUID() {
  if (WiFi.status() != WL_CONNECTED) return;

  String path = "/esp_public/" + esp32UniqueCode + "/ownerUID.json";
  String response = httpGet(path);

  if (response.length() > 0 && response != "null") {
    String uid = response;
    uid.replace("\"", "");
    if (uid.length() > 0) {
      Serial.println("✅ ESP claimed by UID: " + uid);
      completeRegistration(uid);
    }
  }
}

void completeRegistration(String uid) {
  registeredUID = uid;
  firebasePath = "/smartHome/" + uid + "/";
  isRegistered = true;

  prefs.begin("registration", false);
  prefs.putString("uid", registeredUID);
  prefs.putBool("registered", true);
  prefs.end();

  // FIX #5: strip trailing slash when targeting the node itself
  String nodePath = firebasePath;
  if (nodePath.endsWith("/")) nodePath.remove(nodePath.length() - 1);

  String initJson = "{";
  initJson += "\"temperature\":0,";
  initJson += "\"humidity\":0,";
  initJson += "\"flame\":false,";
  initJson += "\"lights\":{},";
  initJson += "\"sensors\":{";
  initJson += "\"temperature\":0,";
  initJson += "\"humidity\":0,";
  initJson += "\"flame\":false";
  initJson += "},";
  initJson += "\"status\":{";
  initJson += "\"online\":true,";
  initJson += "\"lastSeen\":" + String(time(nullptr)) + ",";
  initJson += "\"ip\":\"" + WiFi.localIP().toString() + "\",";
  initJson += "\"rssi\":" + String(WiFi.RSSI()) + ",";
  initJson += "\"ping\":12,";
  initJson += "\"uniqueCode\":\"" + esp32UniqueCode + "\"";
  initJson += "}";
  initJson += "}";
  httpPut(nodePath + ".json", initJson, FIREBASE_LONG_HTTP_TIMEOUT_MS);

  Serial.println("✅ Registration completed for UID: " + uid);
  syncHardwareFromFirebase();
  syncDevicesFromFirebase();
  updateOnlineStatus();
}

void loadRegistration() {
  prefs.begin("registration", true);
  registeredUID = prefs.getString("uid", "");
  isRegistered = prefs.getBool("registered", false);
  prefs.end();

  if (isRegistered && registeredUID.length() > 0) {
    firebasePath = "/smartHome/" + registeredUID + "/";
    Serial.println("📧 Loaded registration for UID: " + registeredUID);
  }
}

// =======================
// DEVICE FUNCTIONS
// =======================
void saveDevicesToPreferences() {
  DynamicJsonDocument doc(12288);
  JsonArray list = doc.to<JsonArray>();
  for (auto& pair : devices) {
    Device& d = pair.second;
    JsonObject item = list.createNestedObject();
    item["id"] = d.id;
    item["name"] = d.name;
    item["type"] = d.type;
    item["moduleId"] = d.moduleId;
    item["channel"] = d.channel;
    item["room"] = d.room;
    item["state"] = d.state;
    item["enabled"] = d.enabled;
  }
  String json;
  serializeJson(list, json);
  devicePrefs.begin("devices", false);
  devicePrefs.clear();
  devicePrefs.putString("json", json);
  devicePrefs.end();
}

void loadDevicesFromPreferences() {
  devices.clear();
  outputStates.clear();
  devicePrefs.begin("devices", true);
  String json = devicePrefs.getString("json", "");
  int legacyCount = devicePrefs.getInt("count", 0);

  if (json.length() > 2) {
    DynamicJsonDocument doc(12288);
    if (!deserializeJson(doc, json) && doc.is<JsonArray>()) {
      for (JsonObject data : doc.as<JsonArray>()) {
        String moduleId = data["moduleId"] | DEFAULT_MODULE_ID;
        int channel = data["channel"] | -1;
        if (!moduleExists(moduleId) || !isValidPcfChannel(channel)) continue;
        Device d(
          data["id"] | "",
          data["name"] | "Device",
          data["type"] | 0,
          moduleId,
          channel,
          data["room"] | ""
        );
        d.state = data["state"] | false;
        d.enabled = data["enabled"] | true;
        if (d.id.length() == 0) continue;
        devices[d.id] = d;
        setRelayOutput(d.moduleId, d.channel, d.state);
        outputStates[outputKey(d.moduleId, d.channel)] = d.state;
      }
    }
  } else {
    // Migration from the previous single-module delimiter format.
    for (int i = 0; i < legacyCount; i++) {
      String raw = devicePrefs.getString((String("dev_") + String(i)).c_str(), "");
      std::vector<String> parts;
      int start = 0;
      while (true) {
        int pos = raw.indexOf('|', start);
        if (pos < 0) { parts.push_back(raw.substring(start)); break; }
        parts.push_back(raw.substring(start, pos));
        start = pos + 1;
      }
      if (parts.size() < 6) continue;
      Device d(parts[0], parts[1], parts[2].toInt(), DEFAULT_MODULE_ID, parts[3].toInt(), parts[4]);
      d.state = parts[5].toInt() == 1;
      if (!moduleExists(d.moduleId) || !isValidPcfChannel(d.channel)) continue;
      devices[d.id] = d;
      setRelayOutput(d.moduleId, d.channel, d.state);
      outputStates[outputKey(d.moduleId, d.channel)] = d.state;
    }
  }
  devicePrefs.end();
  saveDevicesToPreferences();
  Serial.printf("📱 Loaded %d devices from preferences\n", devices.size());
}

void queueDeviceStateCloudUpload(String id, bool state) {
  pendingCloudStates[id] = state;
  pendingCloudStateAt = millis();
  nextCloudUploadAttemptAt = 0;
  pendingCloudStateUpload = true;
}

void cloudStateUploadTask(void* parameter) {
  (void)parameter;
  CloudStateUploadJob job = {};

  for (;;) {
    if (xQueueReceive(cloudUploadQueue, &job, portMAX_DELAY) != pdTRUE) continue;

    bool uploaded = false;
    if (WiFi.status() == WL_CONNECTED) {
      // Never share the main task's TLS client with this worker.
      WiFiClientSecure uploadClient;
      uploadClient.setInsecure();
      HTTPClient http;
      http.setReuse(false);
      http.setTimeout(FIREBASE_HTTP_TIMEOUT_MS);

      const String url = String(DATABASE_URL) + String(job.path);
      if (http.begin(uploadClient, url)) {
        http.addHeader("Content-Type", "application/json");
        http.addHeader("Connection", "close");
        const String json = String("{\"state\":") +
                            (job.state ? "true" : "false") + "}";
        const int code = http.PATCH(json);
        uploaded = code >= 200 && code < 300;
        if (!uploaded && VERBOSE_LOGS) {
          if (code <= 0) {
            Serial.printf("❌ Background state PATCH failed: %s\n",
                          http.errorToString(code).c_str());
          } else {
            Serial.printf("❌ Background state PATCH HTTP %d for %s\n",
                          code, job.path);
          }
        }
        http.end();
      }
    }

    CloudStateUploadResult result = {};
    snprintf(result.id, sizeof(result.id), "%s", job.id);
    result.state = job.state;
    result.success = uploaded;
    // There is only one in-flight upload, so a one-item result mailbox is safe.
    xQueueOverwrite(cloudUploadResultQueue, &result);
    taskYIELD();
  }
}

void setupCloudUploadWorker() {
  if (cloudUploadQueue != nullptr && cloudUploadResultQueue != nullptr) return;

  cloudUploadQueue = xQueueCreate(1, sizeof(CloudStateUploadJob));
  cloudUploadResultQueue = xQueueCreate(1, sizeof(CloudStateUploadResult));
  if (cloudUploadQueue == nullptr || cloudUploadResultQueue == nullptr) {
    if (cloudUploadQueue != nullptr) vQueueDelete(cloudUploadQueue);
    if (cloudUploadResultQueue != nullptr) vQueueDelete(cloudUploadResultQueue);
    cloudUploadQueue = nullptr;
    cloudUploadResultQueue = nullptr;
    Serial.println("❌ Background Firebase upload queue allocation failed");
    return;
  }

  const BaseType_t created = xTaskCreate(
      cloudStateUploadTask,
      "cloud_state",
      8192,
      nullptr,
      1,
      &cloudUploadTaskHandle);
  if (created != pdPASS) {
    vQueueDelete(cloudUploadQueue);
    vQueueDelete(cloudUploadResultQueue);
    cloudUploadQueue = nullptr;
    cloudUploadResultQueue = nullptr;
    cloudUploadTaskHandle = nullptr;
    Serial.println("❌ Background Firebase upload task allocation failed");
    return;
  }

  Serial.println("✅ Non-blocking Firebase state uploader ready");
}

void flushPendingCloudUploads() {
  if (cloudUploadResultQueue != nullptr) {
    CloudStateUploadResult result = {};
    if (xQueueReceive(cloudUploadResultQueue, &result, 0) == pdTRUE) {
      cloudUploadInFlight = false;
      const String completedId = String(result.id);
      auto pending = pendingCloudStates.find(completedId);

      if (result.success) {
        // Do not erase a newer state that was queued while this upload ran.
        if (pending != pendingCloudStates.end() &&
            pending->second == result.state) {
          pendingCloudStates.erase(pending);
        }
        pendingCloudStateUpload = !pendingCloudStates.empty();
        pendingCloudStateAt = millis();
        nextCloudUploadAttemptAt = 0;
      } else {
        pendingCloudStateUpload = !pendingCloudStates.empty();
        nextCloudUploadAttemptAt = millis() + CLOUD_UPLOAD_RETRY_MS;
      }
    }
  }

  if (cloudUploadInFlight || !pendingCloudStateUpload ||
      WiFi.status() != WL_CONNECTED || !isRegistered) return;
  if (millis() - pendingCloudStateAt < 20 || pendingCloudStates.empty()) return;
  if (nextCloudUploadAttemptAt != 0 && (long)(millis() - nextCloudUploadAttemptAt) < 0) return;
  if (cloudUploadQueue == nullptr || cloudUploadResultQueue == nullptr) return;

  auto it = pendingCloudStates.begin();
  const String id = it->first;
  const bool state = it->second;
  if (devices.find(id) == devices.end()) {
    pendingCloudStates.erase(it);
    pendingCloudStateUpload = !pendingCloudStates.empty();
    return;
  }

  CloudStateUploadJob job = {};
  const String path = firebasePath + "devices/" + id + ".json";
  if (id.length() >= sizeof(job.id) || path.length() >= sizeof(job.path)) {
    Serial.println("❌ Firebase state path is too long; upload skipped");
    nextCloudUploadAttemptAt = millis() + CLOUD_UPLOAD_RETRY_MS;
    return;
  }
  snprintf(job.id, sizeof(job.id), "%s", id.c_str());
  snprintf(job.path, sizeof(job.path), "%s", path.c_str());
  job.state = state;

  if (xQueueSend(cloudUploadQueue, &job, 0) == pdTRUE) {
    cloudUploadInFlight = true;
  } else {
    nextCloudUploadAttemptAt = millis() + 50;
  }
}

bool shouldIgnoreCloudState(const String& id, bool cloudState) {
  auto desiredIt = guardedDeviceStates.find(id);
  auto timeIt = guardedDeviceStateTimes.find(id);
  if (desiredIt == guardedDeviceStates.end() || timeIt == guardedDeviceStateTimes.end()) return false;

  const unsigned long age = millis() - timeIt->second;
  if (age > LOCAL_COMMAND_GUARD_MS) {
    guardedDeviceStates.erase(id);
    guardedDeviceStateTimes.erase(id);
    return false;
  }

  const bool desiredState = desiredIt->second;
  if (cloudState != desiredState) {
    if (VERBOSE_LOGS) {
      Serial.printf("🛡️ Ignored stale cloud state for %s: cloud=%d desired=%d\n",
                    id.c_str(), cloudState, desiredState);
    }
    return true;
  }

  // A matching event normally acknowledges our own write. Keep the guard until
  // the REST upload has completed, so an older opposite SSE event cannot arrive
  // immediately afterward and reverse the relay.
  if (pendingCloudStates.find(id) == pendingCloudStates.end()) {
    guardedDeviceStates.erase(id);
    guardedDeviceStateTimes.erase(id);
  }
  return false;
}

void setDeviceStateInternal(String id, bool state, bool writeFirebase) {
  auto it = devices.find(id);
  if (it == devices.end()) return;
  Device& device = it->second;
  String key = outputKey(device.moduleId, device.channel);

  if (writeFirebase) {
    guardedDeviceStates[id] = state;
    guardedDeviceStateTimes[id] = millis();
  }

  if (device.state == state && outputStates[key] == state) {
    if (writeFirebase && isRegistered) queueDeviceStateCloudUpload(id, state);
    return;
  }

  if (!setRelayOutput(device.moduleId, device.channel, state)) {
    if (writeFirebase) {
      guardedDeviceStates.erase(id);
      guardedDeviceStateTimes.erase(id);
    }
    Serial.printf("❌ Failed to switch %s through %s/P%d\n",
                  device.name.c_str(), device.moduleId.c_str(), device.channel);
    return;
  }
  device.state = state;
  outputStates[key] = state;
  if (writeFirebase && isRegistered) queueDeviceStateCloudUpload(id, state);
}

void setDeviceState(String id, bool state) {
  setDeviceStateInternal(id, state, true);
}

bool outputAlreadyUsed(const String& moduleId, int channel, const String& excludingId = "") {
  for (auto& pair : devices) {
    if (pair.first == excludingId) continue;
    if (pair.second.moduleId == moduleId && pair.second.channel == channel) return true;
  }
  return false;
}

String addDevice(String name, int type, String moduleId, int channel, String room, String requestedId, bool writeFirebase) {
  requestedId.trim();
  const String id = requestedId.length() > 0 ? requestedId : ("dev_" + String(millis()));

  if (!moduleExists(moduleId) || !isValidPcfChannel(channel) ||
      outputAlreadyUsed(moduleId, channel, id)) {
    return "";
  }

  auto existing = devices.find(id);
  if (existing != devices.end()) {
    Device& device = existing->second;
    if (device.moduleId != moduleId || device.channel != channel) {
      setRelayOutput(device.moduleId, device.channel, false);
      outputStates.erase(outputKey(device.moduleId, device.channel));
      device.moduleId = moduleId;
      device.channel = channel;
    }
    device.name = name;
    device.type = type;
    device.room = room;
    device.enabled = true;
    setRelayOutput(moduleId, channel, device.state);
    outputStates[outputKey(moduleId, channel)] = device.state;
  } else {
    Device device(id, name, type, moduleId, channel, room);
    if (!setRelayOutput(moduleId, channel, false)) return "";
    outputStates[outputKey(moduleId, channel)] = false;
    devices[id] = device;
  }

  saveDevicesToPreferences();

  if (writeFirebase && isRegistered) {
    DynamicJsonDocument doc(1024);
    Device& saved = devices[id];
    doc["id"] = id;
    doc["name"] = saved.name;
    doc["type"] = saved.type;
    doc["moduleId"] = saved.moduleId;
    doc["expanderId"] = saved.moduleId;
    doc["channel"] = saved.channel;
    doc["room"] = saved.room;
    doc["state"] = saved.state;
    doc["enabled"] = saved.enabled;
    String json;
    serializeJson(doc, json);
    httpPut(firebasePath + "devices/" + id + ".json", json);
  }

  Serial.printf("✅ Device ready without restart: %s (%s/P%d)\n",
                id.c_str(), moduleId.c_str(), channel);
  return id;
}

void removeDevice(String id) {
  auto it = devices.find(id);
  if (it == devices.end()) return;
  Device d = it->second;
  setRelayOutput(d.moduleId, d.channel, false);
  outputStates.erase(outputKey(d.moduleId, d.channel));
  guardedDeviceStates.erase(id);
  guardedDeviceStateTimes.erase(id);
  pendingCloudStates.erase(id);
  if (isRegistered) httpPut(firebasePath + "devices/" + id + ".json", "null");
  devices.erase(it);
  saveDevicesToPreferences();
}

// =======================
// SYNC HARDWARE + DEVICES FROM FIREBASE
// =======================
void syncHardwareFromFirebase() {
  if (WiFi.status() != WL_CONNECTED || !isRegistered) return;
  String response = httpGet(firebasePath + "hardware.json", FIREBASE_LONG_HTTP_TIMEOUT_MS);
  if (response.length() == 0) return;

  if (response == "null") {
    httpPut(firebasePath + "hardware.json", buildHardwareConfigJson(), FIREBASE_LONG_HTTP_TIMEOUT_MS);
    return;
  }
  applyHardwareConfigJson(response, true, true);
}

void clearAllDevicesLocal() {
  for (auto& pair : devices) setRelayOutput(pair.second.moduleId, pair.second.channel, false);
  devices.clear();
  outputStates.clear();
  guardedDeviceStates.clear();
  guardedDeviceStateTimes.clear();
  pendingCloudStates.clear();
  pendingCloudStateUpload = false;
  nextCloudUploadAttemptAt = 0;
  saveDevicesToPreferences();
}

void applyFirebaseDevices(JsonObject firebaseDevices, bool allowCloudConflictPatch) {
  std::map<String, String> used;
  for (auto& pair : devices) used[outputKey(pair.second.moduleId, pair.second.channel)] = pair.first;

  for (JsonPair pair : firebaseDevices) {
    if (!pair.value().is<JsonObject>()) continue;
    String deviceId = pair.key().c_str();
    JsonObject data = pair.value().as<JsonObject>();
    String moduleId = data["moduleId"] | "";
    if (moduleId.length() == 0) moduleId = data["expanderId"] | DEFAULT_MODULE_ID;
    int channel = data["channel"] | -1;

    if (!moduleExists(moduleId) || !isValidPcfChannel(channel)) {
      if (allowCloudConflictPatch) {
        httpPatch(firebasePath + "devices/" + deviceId + ".json",
                  "{\"enabled\":false,\"error\":\"Assign a valid I/O module and channel\"}");
      }
      continue;
    }

    String key = outputKey(moduleId, channel);
    auto conflict = used.find(key);
    if (conflict != used.end() && conflict->second != deviceId) {
      if (allowCloudConflictPatch) {
        httpPatch(firebasePath + "devices/" + deviceId + ".json",
                  "{\"enabled\":false,\"error\":\"I/O output already assigned\"}");
      }
      continue;
    }

    String name = data["name"] | "Device";
    int type = data["type"] | 0;
    String room = data["room"] | "Living Room";
    bool state = data["state"] | false;
    bool enabled = data["enabled"] | true;

    if (devices.find(deviceId) == devices.end()) {
      Device d(deviceId, name, type, moduleId, channel, room);
      d.state = state;
      d.enabled = enabled;
      devices[deviceId] = d;
      used[key] = deviceId;
      setRelayOutput(moduleId, channel, state);
      outputStates[key] = state;
    } else {
      Device& d = devices[deviceId];
      if (d.moduleId != moduleId || d.channel != channel) {
        setRelayOutput(d.moduleId, d.channel, false);
        outputStates.erase(outputKey(d.moduleId, d.channel));
        used.erase(outputKey(d.moduleId, d.channel));
        d.moduleId = moduleId;
        d.channel = channel;
        used[key] = deviceId;
      }
      d.name = name;
      d.type = type;
      d.room = room;
      d.enabled = enabled;
      if (!shouldIgnoreCloudState(deviceId, state) &&
          (d.state != state || outputStates[key] != state)) {
        setRelayOutput(moduleId, channel, state);
        d.state = state;
        outputStates[key] = state;
      }
    }
  }

  std::vector<String> removeIds;
  for (auto& pair : devices) if (!firebaseDevices.containsKey(pair.first)) removeIds.push_back(pair.first);
  for (String id : removeIds) {
    Device d = devices[id];
    setRelayOutput(d.moduleId, d.channel, false);
    outputStates.erase(outputKey(d.moduleId, d.channel));
    devices.erase(id);
  }
  saveDevicesToPreferences();
}

void syncDevicesFromFirebase() {
  if (WiFi.status() != WL_CONNECTED || !isRegistered) return;
  String response = httpGet(firebasePath + "devices.json", FIREBASE_LONG_HTTP_TIMEOUT_MS);
  if (response.length() == 0) return;
  if (response == "null") { clearAllDevicesLocal(); return; }

  DynamicJsonDocument doc(12288);
  if (deserializeJson(doc, response) || !doc.is<JsonObject>()) return;
  applyFirebaseDevices(doc.as<JsonObject>(), true);
}

// =======================
// CREDENTIALS MANAGEMENT
// =======================
void loadCredentials() {
  prefs.begin("wifi", true);
  savedSSID = prefs.getString("ssid", "");
  savedPass = prefs.getString("pass", "");
  prefs.end();
}

void saveCredentials(String ssid, String pass) {
  prefs.begin("wifi", false);
  prefs.putString("ssid", ssid);
  prefs.putString("pass", pass);
  prefs.end();
}

// =======================
// WIFI CONNECTION
// =======================
void connectToWiFi() {
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);  // lower Wi-Fi latency for local HTTP/BLE control
  if (savedSSID.length() == 0) {
    useCaptivePortal = true;
    return;
  }
  WiFi.begin(savedSSID.c_str(), savedPass.c_str());
  int attempts = 0;
  while (WiFi.status() != WL_CONNECTED && attempts < (WIFI_TIMEOUT_SEC * 2)) {
    delay(500);
    Serial.print(".");
    attempts++;
  }
  if (WiFi.status() != WL_CONNECTED) {
    useCaptivePortal = true;
  }
}

// =======================
// CAPTIVE PORTAL
// =======================
void startCaptivePortal() {
  // AP+STA mode keeps ESP32_Config visible while allowing reliable Wi-Fi scans.
  WiFi.mode(WIFI_AP_STA);
  WiFi.softAP(AP_SSID, AP_PASSWORD);
  dnsServer.start(53, "*", WiFi.softAPIP());

  server.on("/scan", HTTP_OPTIONS, handleCorsOptions);
  server.on("/save", HTTP_OPTIONS, handleCorsOptions);

  server.on("/scan", HTTP_GET, []() {
    Serial.println("📡 Captive portal Wi-Fi scan requested");
    WiFi.scanDelete();
    delay(50);

    StaticJsonDocument<4096> doc;
    JsonArray networks = doc.createNestedArray("networks");

    int n = WiFi.scanNetworks(false, true);
    if (n < 0) {
      doc["success"] = false;
      doc["scanError"] = n;
      n = 0;
    } else {
      doc["success"] = true;
    }

    std::vector<String> seenSsids;
    for (int i = 0; i < n; ++i) {
      String ssid = WiFi.SSID(i);
      if (ssid.length() == 0) continue;

      bool duplicate = false;
      for (String existing : seenSsids) {
        if (existing == ssid) {
          duplicate = true;
          break;
        }
      }
      if (duplicate) continue;
      seenSsids.push_back(ssid);

      wifi_auth_mode_t auth = WiFi.encryptionType(i);
      JsonObject net = networks.createNestedObject();
      net["ssid"] = ssid;
      net["rssi"] = WiFi.RSSI(i);
      net["channel"] = WiFi.channel(i);
      net["encryption"] = wifiEncryptionName(auth);
      net["secure"] = isSecureWifi(auth);
    }

    WiFi.scanDelete();
    String jsonStr;
    serializeJson(doc, jsonStr);
    sendCorsJson(200, jsonStr);
    Serial.printf("📡 Captive portal scan returned %d unique networks\n", networks.size());
  });

  server.on("/save", HTTP_POST, []() {
    String newSSID = readRequestArg("ssid");
    String newPass = readRequestArg("pass");
    if (newPass.length() == 0) newPass = readRequestArg("password");

    newSSID.trim();
    if (newSSID.length() == 0) {
      sendCorsJson(400, "{\"success\":false,\"error\":\"Missing SSID\"}");
      return;
    }

    saveCredentials(newSSID, newPass);

    String json = "{";
    json += "\"success\":true,";
    json += "\"message\":\"Wi-Fi saved. ESP32 will restart and reconnect.\",";
    json += "\"ssid\":\"" + jsonEscape(newSSID) + "\"";
    json += "}";
    sendCorsJson(200, json);

    pendingWifiRestart = true;
    pendingWifiRestartAt = millis() + 900;
    Serial.println("📡 Captive portal credentials saved. Restart scheduled for SSID: " + newSSID);
  });

  server.onNotFound([]() {
    String html = R"rawliteral(
<!DOCTYPE html>
<html lang="en">
<head>
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>ESP32 Wi-Fi Setup</title>
<style>
  :root { color-scheme: dark; font-family: Inter, system-ui, -apple-system, Segoe UI, sans-serif; }
  body { margin:0; min-height:100vh; display:flex; align-items:center; justify-content:center; background:radial-gradient(circle at top left,#31227a,#0b0d1a 45%,#12091f); color:#fff; padding:20px; }
  .card { width:min(440px,100%); border:1px solid rgba(255,255,255,.12); background:linear-gradient(135deg,rgba(255,255,255,.10),rgba(255,255,255,.04)); backdrop-filter:blur(20px); border-radius:28px; padding:24px; box-shadow:0 24px 70px rgba(0,0,0,.35); }
  .icon { width:58px; height:58px; display:grid; place-items:center; border-radius:18px; background:rgba(108,99,255,.2); color:#8b7fff; font-size:30px; }
  h1 { margin:18px 0 6px; font-size:28px; line-height:1.1; }
  p { color:rgba(255,255,255,.65); line-height:1.45; margin:0 0 18px; }
  label { display:block; margin:14px 0 8px; font-size:13px; color:rgba(255,255,255,.72); font-weight:700; }
  input { width:100%; box-sizing:border-box; border:1px solid rgba(255,255,255,.14); outline:none; background:rgba(0,0,0,.22); color:#fff; border-radius:16px; padding:15px 14px; font-size:16px; }
  button { width:100%; border:0; border-radius:16px; padding:15px; margin-top:18px; color:#fff; font-size:16px; font-weight:800; background:linear-gradient(135deg,#8b7fff,#6c63ff); box-shadow:0 14px 34px rgba(108,99,255,.34); }
  .secondary { background:rgba(255,255,255,.08); box-shadow:none; border:1px solid rgba(255,255,255,.12); margin-top:10px; }
  .net { padding:12px; border-radius:16px; background:rgba(255,255,255,.07); margin-top:10px; display:flex; justify-content:space-between; gap:12px; cursor:pointer; }
  .muted { color:rgba(255,255,255,.55); font-size:13px; }
  .status { margin-top:14px; min-height:22px; color:#4dffa0; font-size:14px; }
</style>
</head>
<body>
  <div class="card">
    <div class="icon">&#128246;</div>
    <h1>ESP32 Wi-Fi Setup</h1>
    <p>Choose a nearby network or enter the SSID manually. The ESP32 will restart after saving.</p>
    <label>SSID</label>
    <input id="ssid" placeholder="Network name" autocomplete="off">
    <label>Password</label>
    <input id="pass" placeholder="Wi-Fi password" type="password">
    <button onclick="save()">Save and Restart ESP32</button>
    <button class="secondary" onclick="scan()">Scan Nearby Networks</button>
    <div id="status" class="status"></div>
    <div id="list"></div>
  </div>
<script>
async function scan(){
  const status=document.getElementById('status');
  const list=document.getElementById('list');
  status.textContent='Scanning...'; list.innerHTML='';
  try{
    const r=await fetch('/scan'); const j=await r.json();
    const nets=j.networks||[]; status.textContent=nets.length?('Found '+nets.length+' networks'):'No networks found';
    list.innerHTML=nets.map(n=>`<div class="net" onclick="pick('${String(n.ssid).replace(/'/g,"\\'")}')"><strong>${n.ssid}</strong><span class="muted">${n.rssi} dBm</span></div>`).join('');
  }catch(e){ status.textContent='Scan failed: '+e; }
}
function pick(s){ document.getElementById('ssid').value=s; document.getElementById('pass').focus(); }
async function save(){
  const ssid=document.getElementById('ssid').value.trim();
  const pass=document.getElementById('pass').value;
  const status=document.getElementById('status');
  if(!ssid){ status.textContent='Please enter SSID'; return; }
  status.textContent='Saving...';
  try{
    const r=await fetch('/save',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({ssid:ssid,pass:pass})});
    const text=await r.text(); status.textContent=r.ok?'Saved. ESP32 is restarting...':text;
  }catch(e){ status.textContent='Save failed: '+e; }
}
scan();
</script>
</body>
</html>
)rawliteral";
    server.send(200, "text/html", html);
  });

  server.begin();
  Serial.println("📱 Captive portal started. Connect to ESP32_Config");
}

// =======================
// SSE STREAM FUNCTIONS
// =======================
void connectSSEStream() {
  if (streamConnected) return;
  if (WiFi.status() != WL_CONNECTED) return;
  if (!isRegistered || firebasePath.length() == 0) return;

  unsigned long now = millis();
  if (now - lastStreamReconnect < STREAM_RECONNECT_INTERVAL) return;
  lastStreamReconnect = now;

  String streamPath = firebasePath.substring(0, firebasePath.length() - 1) + "/devices";

  Serial.println("📡 Connecting to SSE stream: " + streamPath);
  streamClient.setInsecure();
  streamClient.setTimeout(1);
  if (!streamClient.connect("iot-smart-home-81abd-default-rtdb.europe-west1.firebasedatabase.app", 443)) {
    Serial.println("❌ SSE connection failed");
    return;
  }
  streamClient.println("GET " + streamPath + ".json?format=event-stream HTTP/1.1");
  streamClient.println("Host: iot-smart-home-81abd-default-rtdb.europe-west1.firebasedatabase.app");
  streamClient.println("Accept: text/event-stream");
  streamClient.println("Cache-Control: no-cache");
  streamClient.println("Connection: keep-alive");
  streamClient.println();
  streamConnected = true;
  streamBuffer = "";
  Serial.println("✅ SSE stream connected!");
}

void processLightsPayload(const String& payload) {
  DynamicJsonDocument doc(4096);
  DeserializationError error = deserializeJson(doc, payload);
  if (error) {
    if (VERBOSE_LOGS) {
      Serial.print("❌ Failed to parse SSE JSON: ");
      Serial.println(error.c_str());
    }
    return;
  }

  if (!doc.containsKey("path") || !doc.containsKey("data")) return;

  String path = doc["path"].as<String>();
  JsonVariant data = doc["data"];

  // Initial Firebase SSE event sends path "/" with the full /devices object.
  // Use it directly instead of doing another blocking HTTPS GET.
  if (path == "/") {
    if (data.isNull()) {
      if (!devices.empty()) clearAllDevicesLocal();
      return;
    }
    if (data.is<JsonObject>()) {
      applyFirebaseDevices(data.as<JsonObject>(), false);
      return;
    }
  }

  String cleanPath = path;
  if (cleanPath.startsWith("/")) cleanPath = cleanPath.substring(1);

  int slashIndex = cleanPath.indexOf('/');
  String deviceId = slashIndex >= 0 ? cleanPath.substring(0, slashIndex) : cleanPath;
  String fieldName = slashIndex >= 0 ? cleanPath.substring(slashIndex + 1) : "";

  if (deviceId.length() == 0) {
    manualSyncRequested = true;
    return;
  }

  // /deviceId deleted
  if (data.isNull()) {
    if (devices.find(deviceId) != devices.end()) {
      setRelayOutput(devices[deviceId].moduleId, devices[deviceId].channel, false);
      outputStates.erase(outputKey(devices[deviceId].moduleId, devices[deviceId].channel));
      devices.erase(deviceId);
      saveDevicesToPreferences();
    }
    return;
  }

  // /deviceId/state changed directly and data is true/false.
  if (fieldName == "state" && data.is<bool>()) {
    bool state = data.as<bool>();
    if (devices.find(deviceId) != devices.end()) {
      if (!shouldIgnoreCloudState(deviceId, state)) {
        setDeviceStateInternal(deviceId, state, false);
      }
    } else {
      manualSyncRequested = true;
    }
    return;
  }

  // /deviceId patched with a full or partial object.
  if (data.is<JsonObject>()) {
    JsonObject obj = data.as<JsonObject>();

    // Pure state patch can be applied instantly.
    if (obj.containsKey("state") && !obj.containsKey("channel") && !obj.containsKey("moduleId") && !obj.containsKey("expanderId") && !obj.containsKey("name") &&
        !obj.containsKey("room") && !obj.containsKey("type") && !obj.containsKey("enabled") &&
        devices.find(deviceId) != devices.end()) {
      const bool state = obj["state"].as<bool>();
      if (!shouldIgnoreCloudState(deviceId, state)) {
        setDeviceStateInternal(deviceId, state, false);
      }
      return;
    }

    // Structure changed/new device: do a deferred sync so the SSE callback stays short.
    manualSyncRequested = true;
    return;
  }

  manualSyncRequested = true;
}

// FIX #1: use streamBuffer to accumulate characters so partial TCP packets
//         are reassembled correctly before processing.
void readSSEStream() {
  if (!streamConnected) return;

  if (!streamClient.connected()) {
    Serial.println("⚠️ SSE stream disconnected! Reconnecting...");
    streamConnected = false;
    streamBuffer = "";
    streamClient.stop();
    return;
  }

  // Do not drain unlimited TCP data in one loop pass; local HTTP control must stay responsive.
  const int MAX_SSE_BYTES_PER_LOOP = 1536;
  int bytesProcessed = 0;

  while (streamClient.available() && bytesProcessed < MAX_SSE_BYTES_PER_LOOP) {
    char c = streamClient.read();
    bytesProcessed++;

    if (c == '\n') {
      String line = streamBuffer;
      streamBuffer = "";
      line.trim();
      if (line.startsWith("data:")) {
        String payload = line.substring(5);
        payload.trim();
        if (payload.length() > 2 && payload != "null") {
          processLightsPayload(payload);
        }
      }
    } else if (c != '\r') {
      streamBuffer += c;
      if (streamBuffer.length() > 4096) {
        // Protect heap if a malformed stream line arrives.
        streamBuffer = "";
      }
    }
  }
}

// =======================
// CORE FUNCTIONS
// =======================
void sendSensorsToFirebase() {
  if (WiFi.status() != WL_CONNECTED) return;
  if (!isRegistered || firebasePath.length() == 0) return;

  // Single DHT read: retries + delay can freeze the loop and hurt switch latency.
  float t = dht.readTemperature();
  float h = dht.readHumidity();
  if (isnan(t) || isnan(h)) {
    if (VERBOSE_LOGS) Serial.println("❌ DHT read failed");
    return;
  }

  bool flame = (digitalRead(FLAME_SENSOR_PIN) == LOW);

  String nodePath = firebasePath;
  if (nodePath.endsWith("/")) nodePath.remove(nodePath.length() - 1);

  // One PATCH instead of two HTTPS requests. This reduces blocking time in loop(),
  // so local /api/devices/control requests are handled faster.
  String rootJson = "{";
  rootJson += "\"temperature\":" + String(t, 1) + ",";
  rootJson += "\"humidity\":" + String(h, 1) + ",";
  rootJson += "\"flame\":" + String(flame ? "true" : "false") + ",";
  rootJson += "\"sensors\":{";
  rootJson += "\"temperature\":" + String(t, 1) + ",";
  rootJson += "\"humidity\":" + String(h, 1) + ",";
  rootJson += "\"flame\":" + String(flame ? "true" : "false");
  rootJson += "}";
  rootJson += "}";
  httpPatch(nodePath + ".json", rootJson);

  Serial.printf("📤 Sensors sent: T=%.1f°C, H=%.1f%%, Flame=%s\n", t, h, flame ? "YES" : "NO");
}

String buildStatusJson(time_t now, const String& ip, const String& currentSsid, const String& gatewayIp, int rssi) {
  String statusJson = "{";
  statusJson += "\"online\":true,";
  statusJson += "\"lastSeen\":" + String(now) + ",";
  statusJson += "\"ip\":\"" + ip + "\",";
  statusJson += "\"ssid\":\"" + jsonEscape(currentSsid) + "\",";
  statusJson += "\"gateway\":\"" + gatewayIp + "\",";
  statusJson += "\"rssi\":" + String(rssi) + ",";
  statusJson += "\"ping\":12,";
  statusJson += "\"uniqueCode\":\"" + esp32UniqueCode + "\"";
  statusJson += "}";
  return statusJson;
}

void updateOnlineStatus() {
  if (WiFi.status() != WL_CONNECTED) return;

  time_t now;
  time(&now);
  String ip = WiFi.localIP().toString();
  String currentSsid = WiFi.SSID();
  String gatewayIp = WiFi.gatewayIP().toString();
  int rssi = WiFi.RSSI();

  String statusJson = buildStatusJson(now, ip, currentSsid, gatewayIp, rssi);

  // Write to the exact nodes instead of PATCHing the database root.
  // Root PATCH is commonly rejected by Firebase rules, which made the app show
  // the ESP32 as offline even while local control was working.
  httpPut("/esp_public/" + esp32UniqueCode + "/status.json", statusJson);

  if (isRegistered && registeredUID.length() > 0) {
    httpPut(firebasePath + "status.json", statusJson);
  }

  if (VERBOSE_LOGS) Serial.println("💚 Heartbeat sent to public/private status nodes");
}

// =======================
// ELLIE OFFLINE ASSISTANT + SPEAKER
// =======================
String sanitizeAssistantName(const String& requestedName) {
  String source = requestedName;
  source.trim();
  if (source.length() < 2 || source.length() > ELLIE_MAX_NAME_BYTES) return "";

  String cleaned = "";
  bool previousWasSpace = false;
  for (size_t i = 0; i < source.length(); i++) {
    const unsigned char raw = static_cast<unsigned char>(source.charAt(i));
    if (raw < 128) {
      if (isalnum(raw) || raw == '\'' || raw == '-') {
        cleaned += static_cast<char>(raw);
        previousWasSpace = false;
      } else if (isspace(raw) && !previousWasSpace && cleaned.length() > 0) {
        cleaned += ' ';
        previousWasSpace = true;
      } else if (!isspace(raw)) {
        return "";
      }
    } else {
      // Keep UTF-8 letters (including Arabic names). Flutter performs the
      // stricter Unicode validation before sending the value to the ESP32.
      cleaned += static_cast<char>(raw);
      previousWasSpace = false;
    }
  }

  cleaned.trim();
  return cleaned.length() >= 2 ? cleaned : String("");
}

void loadAssistantName() {
  assistantPrefs.begin("assistant", true);
  const String stored = assistantPrefs.getString("name", ELLIE_DEFAULT_NAME);
  assistantPrefs.end();

  const String cleaned = sanitizeAssistantName(stored);
  assistantName = cleaned.length() > 0 ? cleaned : String(ELLIE_DEFAULT_NAME);
  Serial.println("🎙️ Local assistant name: " + assistantName);
}

bool setAssistantName(const String& requestedName, bool persist) {
  const String cleaned = sanitizeAssistantName(requestedName);
  if (cleaned.length() == 0) return false;
  if (cleaned == assistantName) return true;

  if (persist) {
    assistantPrefs.begin("assistant", false);
    const bool saved = assistantPrefs.putString("name", cleaned) > 0;
    assistantPrefs.end();
    if (!saved) return false;
  }
  assistantName = cleaned;
  Serial.println("🎙️ Local assistant renamed to: " + assistantName);
  return true;
}

String ellieNormalize(const String& value) {
  String cleaned = value;
  // Normalize common Arabic letter variants and remove diacritics/tatweel so
  // Egyptian and Modern Standard Arabic commands match the same intent.
  cleaned.replace("أ", "ا");
  cleaned.replace("إ", "ا");
  cleaned.replace("آ", "ا");
  cleaned.replace("ى", "ي");
  cleaned.replace("ؤ", "و");
  cleaned.replace("ئ", "ي");
  cleaned.replace("ـ", "");
  cleaned.replace("َ", "");
  cleaned.replace("ً", "");
  cleaned.replace("ُ", "");
  cleaned.replace("ٌ", "");
  cleaned.replace("ِ", "");
  cleaned.replace("ٍ", "");
  cleaned.replace("ْ", "");
  cleaned.replace("ّ", "");
  cleaned.replace("ٰ", "");
  cleaned.replace("،", " ");
  cleaned.replace("؛", " ");
  cleaned.replace("؟", " ");

  String out = "";
  bool previousWasSpace = true;

  for (size_t i = 0; i < cleaned.length(); i++) {
    const unsigned char raw = static_cast<unsigned char>(cleaned.charAt(i));
    if (raw < 128 && isalnum(raw)) {
      out += static_cast<char>(tolower(raw));
      previousWasSpace = false;
    } else if (raw >= 128) {
      // Arduino String stores UTF-8 bytes. Preserve non-ASCII bytes so Arabic
      // device and room names remain searchable without allocating a decoder.
      out += static_cast<char>(raw);
      previousWasSpace = false;
    } else if (!previousWasSpace) {
      out += ' ';
      previousWasSpace = true;
    }
  }

  out.trim();
  return out;
}

bool ellieContainsPhrase(const String& normalizedText, const String& normalizedPhrase) {
  if (normalizedPhrase.length() == 0) return false;
  const String haystack = " " + normalizedText + " ";
  const String needle = " " + normalizedPhrase + " ";
  return haystack.indexOf(needle) >= 0;
}

String ellieWithoutWakeName(const String& normalizedText) {
  String result = normalizedText;
  const String wakeNames[] = {
    ellieNormalize(assistantName),
    ellieNormalize(ELLIE_DEFAULT_NAME),
    "ايلي",
  };

  for (const String& wakeName : wakeNames) {
    const int position = result.indexOf(wakeName);
    if (position >= 0) {
      const bool startsAtWord = position == 0 || result.charAt(position - 1) == ' ';
      const int end = position + wakeName.length();
      const bool endsAtWord = end >= static_cast<int>(result.length()) || result.charAt(end) == ' ';
      if (startsAtWord && endsAtWord) {
        result.remove(position, wakeName.length());
        result = ellieNormalize(result);
        break;
      }
    }
  }

  if (result.startsWith("hey ")) result = result.substring(4);
  if (result.startsWith("please ")) result = result.substring(7);
  if (result.startsWith("يا ")) result = result.substring(String("يا ").length());
  if (result.startsWith("لو سمحت ")) result = result.substring(String("لو سمحت ").length());
  if (result.startsWith("من فضلك ")) result = result.substring(String("من فضلك ").length());
  result.trim();
  return result;
}

String ellieDeviceTypeName(int type, bool plural, bool arabic = false) {
  if (arabic) {
    if (type == 0) return plural ? "الانوار" : "النور";
    if (type == 1) return plural ? "المراوح" : "المروحة";
    if (type == 2) return plural ? "المفاتيح" : "المفتاح";
    if (type == 3) return plural ? "المقابس" : "المقبس";
    return plural ? "الاجهزة" : "الجهاز";
  }
  if (type == 0) return plural ? "lights" : "light";
  if (type == 1) return plural ? "fans" : "fan";
  if (type == 2) return plural ? "switches" : "switch";
  if (type == 3) return plural ? "sockets" : "socket";
  return plural ? "devices" : "device";
}

int ellieRequestedDeviceType(const String& text) {
  if (ellieContainsPhrase(text, "light") || ellieContainsPhrase(text, "lights") ||
      ellieContainsPhrase(text, "lamp") || ellieContainsPhrase(text, "lamps") ||
      ellieContainsPhrase(text, "نور") || ellieContainsPhrase(text, "النور") ||
      ellieContainsPhrase(text, "ضوء") || ellieContainsPhrase(text, "الضوء") ||
      ellieContainsPhrase(text, "لمبة") || ellieContainsPhrase(text, "لمبات") ||
      ellieContainsPhrase(text, "اضاءة") || ellieContainsPhrase(text, "الاضاءة")) return 0;
  if (ellieContainsPhrase(text, "fan") || ellieContainsPhrase(text, "fans") ||
      ellieContainsPhrase(text, "مروحة") || ellieContainsPhrase(text, "المروحة") ||
      ellieContainsPhrase(text, "مراوح") || ellieContainsPhrase(text, "المراوح")) return 1;
  if (ellieContainsPhrase(text, "socket") || ellieContainsPhrase(text, "sockets") ||
      ellieContainsPhrase(text, "outlet") || ellieContainsPhrase(text, "outlets") ||
      ellieContainsPhrase(text, "plug") || ellieContainsPhrase(text, "plugs") ||
      ellieContainsPhrase(text, "مقبس") || ellieContainsPhrase(text, "المقبس") ||
      ellieContainsPhrase(text, "فيشة") || ellieContainsPhrase(text, "الفيشة")) return 3;
  // Check the switch device type last because "switch on" is also an action phrase.
  if (ellieContainsPhrase(text, "switch") || ellieContainsPhrase(text, "switches") ||
      ellieContainsPhrase(text, "مفتاح") || ellieContainsPhrase(text, "المفتاح") ||
      ellieContainsPhrase(text, "مفاتيح") || ellieContainsPhrase(text, "المفاتيح")) return 2;
  return -1;
}

void ellieAddTarget(std::vector<String>& targetIds, const String& id) {
  for (const String& existing : targetIds) {
    if (existing == id) return;
  }
  targetIds.push_back(id);
}

struct EllieNamedDeviceCandidate {
  String id;
  String name;
};

std::vector<String> ellieFindNamedDevices(const String& text) {
  std::vector<EllieNamedDeviceCandidate> candidates;
  std::vector<String> matches;
  candidates.reserve(devices.size());
  matches.reserve(devices.size());

  for (auto& pair : devices) {
    Device& device = pair.second;
    if (!device.enabled) continue;
    const String name = ellieNormalize(device.name);
    if (name.length() < 2 || !ellieContainsPhrase(text, name)) continue;

    EllieNamedDeviceCandidate candidate;
    candidate.id = device.id;
    candidate.name = name;
    candidates.push_back(candidate);
  }

  for (size_t candidateIndex = 0; candidateIndex < candidates.size(); candidateIndex++) {
    const EllieNamedDeviceCandidate& candidate = candidates[candidateIndex];
    // A command may contain several differently sized names, for example
    // "turn off television and desk lamp". The old longest-name-only logic
    // silently discarded one of them. Keep every distinct named target, while
    // ignoring a short name that is fully contained in a longer matched name
    // (for example devices named "Light" and "Living Room Light").
    bool shadowedByLongerName = false;
    for (size_t otherIndex = 0; otherIndex < candidates.size(); otherIndex++) {
      if (otherIndex == candidateIndex) continue;
      const EllieNamedDeviceCandidate& other = candidates[otherIndex];
      if (other.name.length() <= candidate.name.length()) continue;
      if (ellieContainsPhrase(other.name, candidate.name)) {
        shadowedByLongerName = true;
        break;
      }
    }
    if (!shadowedByLongerName) ellieAddTarget(matches, candidate.id);
  }

  return matches;
}

String ellieJoinDeviceNames(const std::vector<String>& ids, size_t maximumNames = 4, bool arabic = false) {
  String joined = "";
  size_t added = 0;

  for (const String& id : ids) {
    auto it = devices.find(id);
    if (it == devices.end()) continue;
    if (added > 0) {
      joined += arabic
          ? ((added + 1 == ids.size() || added + 1 == maximumNames) ? " و" : "، ")
          : ((added + 1 == ids.size() || added + 1 == maximumNames) ? " and " : ", ");
    }
    joined += it->second.name;
    added++;
    if (added >= maximumNames) break;
  }

  if (ids.size() > maximumNames) {
    joined += arabic
        ? " و" + String(ids.size() - maximumNames) + " اجهزة اخرى"
        : " and " + String(ids.size() - maximumNames) + " more";
  }
  return joined;
}

bool ellieIsArabicText(const String& value) {
  for (size_t i = 0; i < value.length(); i++) {
    const unsigned char raw = static_cast<unsigned char>(value.charAt(i));
    // Common Arabic UTF-8 sequences start with D8-DB. This covers Arabic,
    // Arabic Supplement, and the characters used by the supported commands.
    if (raw >= 0xD8 && raw <= 0xDB) return true;
  }
  return false;
}

EllieResult runEllieIntent(const String& rawText) {
  EllieResult result;
  const bool arabic = ellieIsArabicText(rawText);
  if (arabic) {
    result.offlineReply = "لم افهم الطلب المحلي. جربي امر جهاز او غرفة او حساس او قولي مساعدة.";
  }
  String text = ellieWithoutWakeName(ellieNormalize(rawText));

  if (text.length() == 0 || text == "hello" || text == "hi" || text == "hello there" ||
      text == "good morning" || text == "good afternoon" || text == "good evening" ||
      text == "مرحبا" || text == "اهلا" || text == "السلام عليكم" ||
      text == "صباح الخير" || text == "مساء الخير") {
    result.handled = true;
    result.intent = "greeting";
    result.reply = arabic
        ? "اهلا، انا " + assistantName + ". ازاي اقدر اساعدك؟"
        : "Hello. I'm " + assistantName + ". How can I help?";
    return result;
  }

  if (ellieContainsPhrase(text, "what is your name") || ellieContainsPhrase(text, "whats your name") ||
      ellieContainsPhrase(text, "what s your name") ||
      ellieContainsPhrase(text, "who are you") ||
      ellieContainsPhrase(text, "ما اسمك") || ellieContainsPhrase(text, "اسمك ايه") ||
      ellieContainsPhrase(text, "من انت") || ellieContainsPhrase(text, "مين انتي")) {
    result.handled = true;
    result.intent = "identity";
    result.reply = arabic
        ? "انا " + assistantName + "، مساعدة المنزل الذكي المحلية."
        : "I'm " + assistantName + ", your local smart home assistant.";
    return result;
  }

  if (ellieContainsPhrase(text, "what can you do") || text == "help" ||
      ellieContainsPhrase(text, "voice commands") ||
      ellieContainsPhrase(text, "تقدري تعملي ايه") ||
      ellieContainsPhrase(text, "ماذا تستطيعين") ||
      ellieContainsPhrase(text, "الاوامر الصوتية") || text == "مساعدة") {
    result.handled = true;
    result.intent = "help";
    result.reply = arabic
        ? "اقدر اتحكم في الاجهزة والغرف، واعرفك حالتها ودرجة الحرارة والرطوبة وانذار الحريق."
        : "I can control devices and rooms, report their status, and check temperature, humidity, or fire.";
    return result;
  }

  if (ellieContainsPhrase(text, "temperature") ||
      ellieContainsPhrase(text, "درجة الحرارة") ||
      ellieContainsPhrase(text, "درجة الحراره") ||
      ellieContainsPhrase(text, "الحرارة") || ellieContainsPhrase(text, "الحراره")) {
    const float temperature = dht.readTemperature();
    result.handled = true;
    result.intent = "temperature";
    if (arabic) {
      result.reply = isnan(temperature)
          ? "حساس درجة الحرارة غير متاح حاليا."
          : "درجة الحرارة " + String(temperature, 1) + " درجة مئوية.";
    } else {
      result.reply = isnan(temperature)
          ? "The temperature sensor is unavailable right now."
          : "The temperature is " + String(temperature, 1) + " degrees Celsius.";
    }
    return result;
  }

  if (ellieContainsPhrase(text, "humidity") ||
      ellieContainsPhrase(text, "الرطوبة") || ellieContainsPhrase(text, "الرطوبه")) {
    const float humidity = dht.readHumidity();
    result.handled = true;
    result.intent = "humidity";
    if (arabic) {
      result.reply = isnan(humidity)
          ? "حساس الرطوبة غير متاح حاليا."
          : "نسبة الرطوبة " + String(humidity, 0) + " في المية.";
    } else {
      result.reply = isnan(humidity)
          ? "The humidity sensor is unavailable right now."
          : "The humidity is " + String(humidity, 0) + " percent.";
    }
    return result;
  }

  if (ellieContainsPhrase(text, "fire") || ellieContainsPhrase(text, "flame") ||
      ellieContainsPhrase(text, "حريق") || ellieContainsPhrase(text, "نار") ||
      ellieContainsPhrase(text, "لهب")) {
    const bool flame = digitalRead(FLAME_SENSOR_PIN) == LOW;
    result.handled = true;
    result.intent = "fire_status";
    result.reply = arabic
        ? (flame ? "تحذير، حساس اللهب يعمل ويوجد احتمال حريق." : "لا يوجد لهب مكتشف.")
        : (flame ? "Warning. The flame sensor is active." : "No flame is detected.");
    return result;
  }

  const bool asksWhatIsOn = ellieContainsPhrase(text, "what is on") ||
                            ellieContainsPhrase(text, "whats on") ||
                            ellieContainsPhrase(text, "what s on") ||
                            ellieContainsPhrase(text, "which devices are on") ||
                            text == "device status" || text == "home status" ||
                            ellieContainsPhrase(text, "ايه اللي شغال") ||
                            ellieContainsPhrase(text, "ما الذي يعمل") ||
                            ellieContainsPhrase(text, "الاجهزة الشغالة") ||
                            ellieContainsPhrase(text, "الاجهزه الشغاله") ||
                            text == "حالة المنزل" || text == "حاله المنزل";
  if (asksWhatIsOn) {
    std::vector<String> activeIds;
    for (auto& pair : devices) {
      if (pair.second.enabled && pair.second.state) activeIds.push_back(pair.first);
    }
    result.handled = true;
    result.intent = "active_devices";
    result.affectedIds = activeIds;
    if (arabic) {
      result.reply = activeIds.empty()
          ? "كل الاجهزة مطفاة."
          : ellieJoinDeviceNames(activeIds, 4, true) + " شغال حاليا.";
    } else {
      result.reply = activeIds.empty()
          ? "Everything is off."
          : ellieJoinDeviceNames(activeIds) + (activeIds.size() == 1 ? " is on." : " are on.");
    }
    return result;
  }

  const bool asksForDevices = ellieContainsPhrase(text, "list devices") ||
                              ellieContainsPhrase(text, "what devices") ||
                              ellieContainsPhrase(text, "which devices") ||
                              ellieContainsPhrase(text, "قائمة الاجهزة") ||
                              ellieContainsPhrase(text, "قائمه الاجهزه") ||
                              ellieContainsPhrase(text, "ما هي الاجهزة") ||
                              ellieContainsPhrase(text, "الاجهزة الموجودة");
  if (asksForDevices) {
    std::vector<String> allIds;
    for (auto& pair : devices) if (pair.second.enabled) allIds.push_back(pair.first);
    result.handled = true;
    result.intent = "list_devices";
    result.affectedIds = allIds;
    result.reply = arabic
        ? (allIds.empty()
            ? "لا توجد اجهزة مسجلة حتى الان."
            : "الاجهزة الموجودة هي " + ellieJoinDeviceNames(allIds, 4, true) + ".")
        : (allIds.empty() ? "No devices are configured yet." : "I found " + ellieJoinDeviceNames(allIds) + ".");
    return result;
  }

  const bool statusQuestion = text.startsWith("is ") || text.startsWith("are ") ||
                              ellieContainsPhrase(text, "status of") || text.endsWith(" status") ||
                              text.startsWith("هل ") || ellieContainsPhrase(text, "حالة") ||
                              ellieContainsPhrase(text, "حاله") || text.endsWith(" شغال") ||
                              text.endsWith(" شغالة") || text.endsWith(" شغاله") ||
                              text.endsWith(" مطفي") || text.endsWith(" مطفية") ||
                              text.endsWith(" مطفيه");
  if (statusQuestion) {
    const std::vector<String> namedIds = ellieFindNamedDevices(text);
    if (!namedIds.empty()) {
      result.handled = true;
      result.intent = "device_status";
      result.affectedIds = namedIds;
      if (namedIds.size() == 1) {
        Device& device = devices[namedIds.front()];
        result.reply = arabic
            ? device.name + String(device.state ? " شغال." : " مطفي.")
            : device.name + " is " + String(device.state ? "on." : "off.");
      } else {
        int onCount = 0;
        for (const String& id : namedIds) if (devices[id].state) onCount++;
        result.reply = arabic
            ? String(onCount) + " من " + String(namedIds.size()) + " اجهزة شغالة."
            : String(onCount) + " of those " + String(namedIds.size()) + " devices are on.";
      }
      return result;
    }
  }

  int desiredState = -1;
  if (ellieContainsPhrase(text, "turn on") || ellieContainsPhrase(text, "switch on") ||
      ellieContainsPhrase(text, "power on") || ellieContainsPhrase(text, "activate") ||
      ellieContainsPhrase(text, "شغل") || ellieContainsPhrase(text, "شغلي") ||
      ellieContainsPhrase(text, "افتح") || ellieContainsPhrase(text, "افتحي") ||
      ellieContainsPhrase(text, "تشغيل")) {
    desiredState = 1;
  } else if (ellieContainsPhrase(text, "turn off") || ellieContainsPhrase(text, "switch off") ||
             ellieContainsPhrase(text, "power off") || ellieContainsPhrase(text, "deactivate") ||
             ellieContainsPhrase(text, "shut down") || ellieContainsPhrase(text, "اطفي") ||
             ellieContainsPhrase(text, "اطفئ") || ellieContainsPhrase(text, "اقفل") ||
             ellieContainsPhrase(text, "اقفلي") || ellieContainsPhrase(text, "اغلق") ||
             ellieContainsPhrase(text, "اطفاء")) {
    desiredState = 0;
  } else if (!statusQuestion && text.endsWith(" on")) {
    desiredState = 1;
  } else if (!statusQuestion && text.endsWith(" off")) {
    desiredState = 0;
  }

  if (desiredState >= 0) {
    std::vector<String> targetIds = ellieFindNamedDevices(text);
    const int requestedType = ellieRequestedDeviceType(text);

    if (targetIds.empty()) {
      String matchedRoom = "";
      size_t longestRoom = 0;
      for (auto& pair : devices) {
        const String normalizedRoom = ellieNormalize(pair.second.room);
        if (normalizedRoom.length() > longestRoom && ellieContainsPhrase(text, normalizedRoom)) {
          matchedRoom = normalizedRoom;
          longestRoom = normalizedRoom.length();
        }
      }

      const bool mentionsRoom = ellieContainsPhrase(text, "room") ||
                                ellieContainsPhrase(text, "غرفة") || ellieContainsPhrase(text, "الغرفة") ||
                                ellieContainsPhrase(text, "غرفه") || ellieContainsPhrase(text, "اوضة") ||
                                ellieContainsPhrase(text, "الاوضة");
      if (matchedRoom.length() > 0 && (requestedType >= 0 || mentionsRoom)) {
        for (auto& pair : devices) {
          Device& device = pair.second;
          if (!device.enabled || ellieNormalize(device.room) != matchedRoom) continue;
          if (requestedType >= 0 && device.type != requestedType) continue;
          ellieAddTarget(targetIds, device.id);
        }
      }
    }

    const bool asksForAll = ellieContainsPhrase(text, "all") || ellieContainsPhrase(text, "every") ||
                            ellieContainsPhrase(text, "everything") ||
                            ellieContainsPhrase(text, "كل") || ellieContainsPhrase(text, "الكل") ||
                            ellieContainsPhrase(text, "جميع") || ellieContainsPhrase(text, "كل حاجة");
    if (targetIds.empty() && (asksForAll || requestedType >= 0)) {
      for (auto& pair : devices) {
        Device& device = pair.second;
        if (!device.enabled) continue;
        if (requestedType >= 0 && device.type != requestedType) continue;
        ellieAddTarget(targetIds, device.id);
      }

      if (!asksForAll && requestedType >= 0 && targetIds.size() > 1) {
        targetIds.clear();
        result.handled = true;
        result.intent = "ambiguous_control";
        result.reply = arabic
            ? "من فضلك حددي " + ellieDeviceTypeName(requestedType, false, true) + " او الغرفة المقصودة."
            : "Please say which " + ellieDeviceTypeName(requestedType, false) + " or room you mean.";
        return result;
      }
    }

    const bool asksForTwoUnnamedDevices =
        ellieContainsPhrase(text, "two devices") ||
        ellieContainsPhrase(text, "2 devices") ||
        ellieContainsPhrase(text, "two things") ||
        ellieContainsPhrase(text, "جهازين") ||
        ellieContainsPhrase(text, "جهازان") ||
        ellieContainsPhrase(text, "اتنين جهاز");
    if (targetIds.empty() && asksForTwoUnnamedDevices) {
      result.handled = true;
      result.intent = "ambiguous_two_devices";
      result.reply = arabic
          ? "قولي اسم الجهازين، مثلا اطفي التلفزيون والمروحة."
          : "Please say both device names, for example: turn off TV and Fan.";
      return result;
    }

    if (targetIds.empty()) {
      result.handled = true;
      result.intent = "device_not_found";
      result.reply = arabic
          ? (devices.empty() ? "لا توجد اجهزة مسجلة حتى الان." : "لم اجد هذا الجهاز او الغرفة.")
          : (devices.empty() ? "No devices are configured yet." : "I couldn't find that device or room.");
      return result;
    }

    bool alreadyInState = true;
    for (const String& id : targetIds) {
      auto it = devices.find(id);
      if (it == devices.end()) continue;
      if (it->second.state != (desiredState == 1)) alreadyInState = false;
      setDeviceStateInternal(id, desiredState == 1, true);
    }

    result.handled = true;
    result.intent = desiredState == 1 ? "turn_on" : "turn_off";
    result.affectedIds = targetIds;
    if (targetIds.size() == 1) {
      Device& device = devices[targetIds.front()];
      if (arabic) {
        result.reply = alreadyInState
            ? device.name + String(desiredState == 1 ? " شغال بالفعل." : " مطفي بالفعل.")
            : String(desiredState == 1 ? "تم تشغيل " : "تم اطفاء ") + device.name + ".";
      } else {
        const String stateWord = desiredState == 1 ? "on" : "off";
        result.reply = alreadyInState
            ? device.name + " is already " + stateWord + "."
            : "Turning " + stateWord + " " + device.name + ".";
      }
    } else {
      if (arabic) {
        result.reply = alreadyInState
            ? ellieJoinDeviceNames(targetIds, 4, true) +
                String(desiredState == 1 ? " شغالة بالفعل." : " مطفاة بالفعل.")
            : String(desiredState == 1 ? "تم تشغيل " : "تم اطفاء ") +
                ellieJoinDeviceNames(targetIds, 4, true) + ".";
      } else {
        const String stateWord = desiredState == 1 ? "on" : "off";
        result.reply = alreadyInState
            ? ellieJoinDeviceNames(targetIds) + " are already " + stateWord + "."
            : "Turning " + stateWord + " " + ellieJoinDeviceNames(targetIds) + ".";
      }
    }
    return result;
  }

  result.handled = false;
  result.needsFallback = true;
  result.intent = "conversation";
  return result;
}

#if ELLIE_SPEAKER_ENABLED
void ellieSpeechTask(void* parameter) {
  AudioOutputI2S* output = new AudioOutputI2S();
  if (output == nullptr) {
    Serial.println("❌ Ellie speaker could not allocate I2S output");
    vTaskDelete(nullptr);
    return;
  }

  output->SetPinout(ELLIE_I2S_BCLK_PIN, ELLIE_I2S_LRC_PIN, ELLIE_I2S_DOUT_PIN);
  output->SetGain(ELLIE_SPEAKER_GAIN);
  ESP8266SAM sam;
  EllieSpeechMessage message;

  for (;;) {
    if (xQueueReceive(ellieSpeechQueue, &message, portMAX_DELAY) == pdTRUE) {
      Serial.println("🔊 " + assistantName + ": " + String(message.text));
      sam.Say(output, message.text);
    }
  }
}
#endif

void setupEllieSpeaker() {
#if ELLIE_SPEAKER_ENABLED
  if (ellieSpeechQueue != nullptr) return;
  ellieSpeechQueue = xQueueCreate(ELLIE_SPEECH_QUEUE_LENGTH, sizeof(EllieSpeechMessage));
  if (ellieSpeechQueue == nullptr) {
    Serial.println("❌ Local assistant speaker queue allocation failed");
    return;
  }

  const BaseType_t created = xTaskCreate(
      ellieSpeechTask, "ellie_speech", 8192, nullptr, 1, &ellieSpeechTaskHandle);
  if (created != pdPASS) {
    vQueueDelete(ellieSpeechQueue);
    ellieSpeechQueue = nullptr;
    Serial.println("❌ Local assistant speaker task allocation failed");
    return;
  }
  Serial.printf("🔊 Local assistant speaker ready: BCLK=%d LRC=%d DIN=%d\n",
                ELLIE_I2S_BCLK_PIN, ELLIE_I2S_LRC_PIN, ELLIE_I2S_DOUT_PIN);
#else
  Serial.println("🔇 Local ESP32 speech is disabled; intent control remains available");
#endif
}

bool queueEllieSpeech(const String& text) {
#if ELLIE_SPEAKER_ENABLED && ELLIE_SAM_LIBRARY_AVAILABLE
  if (ellieSpeechQueue == nullptr || text.length() == 0) return false;

  EllieSpeechMessage message = {};
  String safe = "";
  bool previousWasSpace = false;
  for (size_t i = 0; i < text.length() && safe.length() < ELLIE_MAX_SPEECH_CHARS; i++) {
    const unsigned char raw = static_cast<unsigned char>(text.charAt(i));
    if (raw >= 32 && raw <= 126) {
      safe += static_cast<char>(raw);
      previousWasSpace = raw == ' ';
    } else if (!previousWasSpace) {
      safe += ' ';
      previousWasSpace = true;
    }
  }
  safe.trim();
  if (safe.length() == 0) return false;

  safe.toCharArray(message.text, sizeof(message.text));
  return xQueueSend(ellieSpeechQueue, &message, 0) == pdTRUE;
#else
  (void)text;
  return false;
#endif
}

String processEllieText(const String& rawText, bool speakResponse, bool compactResponse) {
  EllieResult result = runEllieIntent(rawText);
  const bool speakerQueued = speakResponse && result.handled && queueEllieSpeech(result.reply);
  String responseReply = result.reply;
  if (compactResponse && responseReply.length() > 240) {
    size_t cut = 237;
    while (cut > 0 &&
           (static_cast<unsigned char>(responseReply.charAt(cut)) & 0xC0) == 0x80) {
      cut--;
    }
    responseReply = responseReply.substring(0, cut) + "...";
  }

  DynamicJsonDocument doc(compactResponse ? 1024 : 4096);
  doc[compactResponse ? "ok" : "success"] = true;
  if (compactResponse) doc["cmd"] = "ellie";
  doc["assistant"] = assistantName;
  doc["language"] = ellieIsArabicText(rawText) ? "ar" : "en";
  doc["handled"] = result.handled;
  doc["needsFallback"] = result.needsFallback;
  if (responseReply.length() > 0) doc["reply"] = responseReply;
  if (result.needsFallback) doc["offlineReply"] = result.offlineReply;
  doc["speakerQueued"] = speakerQueued;

  if (!compactResponse) {
    doc["heard"] = rawText;
    doc["intent"] = result.intent;
    doc["speakerEnabled"] = ELLIE_SPEAKER_ENABLED == 1;
    doc["offlineEnglishSpeechEnabled"] =
        ELLIE_SPEAKER_ENABLED == 1 && ELLIE_SAM_LIBRARY_AVAILABLE == 1;
    JsonArray affected = doc.createNestedArray("affectedDeviceIds");
    for (const String& id : result.affectedIds) affected.add(id);
  }

  String json;
  serializeJson(doc, json);
  return json;
}



// =======================
// BLE BACKUP CONTROL IMPLEMENTATION
// =======================
class BleServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* server, NimBLEConnInfo& connInfo) override {
    bleClientConnected = true;
    Serial.println("🔵 BLE client connected");
  }

  void onDisconnect(NimBLEServer* server, NimBLEConnInfo& connInfo, int reason) override {
    bleClientConnected = false;
    Serial.println("🔵 BLE client disconnected");
    NimBLEDevice::startAdvertising();
  }
};

class BleCommandCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* characteristic, NimBLEConnInfo& connInfo) override {
    (void)connInfo;
    std::string value = characteristic->getValue();
    if (value.empty()) return;
    if (bleCommandQueue == nullptr || value.size() > BLE_MAX_COMMAND_BYTES) {
      bleCommandQueueOverflow = true;
      return;
    }

    BleCommandMessage message = {};
    memcpy(message.json, value.data(), value.size());
    message.json[value.size()] = '\0';
    if (xQueueSend(bleCommandQueue, &message, 0) != pdTRUE) {
      bleCommandQueueOverflow = true;
    }
  }
};

void setupBleBackup() {
  Serial.println("🔵 Starting lightweight BLE backup control...");
  if (bleCommandQueue == nullptr) {
    bleCommandQueue = xQueueCreate(
        BLE_COMMAND_QUEUE_LENGTH, sizeof(BleCommandMessage));
  }
  if (bleCommandQueue == nullptr) {
    Serial.println("❌ BLE command queue allocation failed");
    return;
  }

  NimBLEDevice::init(BLE_DEVICE_NAME);
  NimBLEDevice::setMTU(247);
  NimBLEDevice::setPower(ESP_PWR_LVL_P7);

  bleServer = NimBLEDevice::createServer();
  bleServer->setCallbacks(new BleServerCallbacks());

  NimBLEService* service = bleServer->createService(BLE_SERVICE_UUID);
  bleCommandChar = service->createCharacteristic(
    BLE_COMMAND_CHAR_UUID,
    NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR | NIMBLE_PROPERTY::NOTIFY
  );
  bleCommandChar->setCallbacks(new BleCommandCallbacks());
  bleCommandChar->setValue("{\"ok\":true,\"status\":\"ready\"}");

  service->start();

  NimBLEAdvertising* advertising = NimBLEDevice::getAdvertising();
  advertising->addServiceUUID(BLE_SERVICE_UUID);
  // NimBLE-Arduino newer versions do not have setScanResponse(bool).
  // Advertising the service UUID is enough for the Flutter app to find ESP32_SmartHome.
  advertising->start();

  Serial.println("✅ BLE backup control started: " + String(BLE_DEVICE_NAME));
  Serial.printf("🧠 Free heap after BLE start: %u\n", ESP.getFreeHeap());
}

void processPendingBleCommands() {
  if (bleCommandQueueOverflow) {
    bleCommandQueueOverflow = false;
    bleReply("{\"ok\":false,\"error\":\"BLE command queue full or payload too large\"}");
  }
  if (bleCommandQueue == nullptr) return;

  // One command per loop keeps HTTP, SSE and watchdog servicing predictable.
  BleCommandMessage message = {};
  if (xQueueReceive(bleCommandQueue, &message, 0) == pdTRUE) {
    handleBleCommand(String(message.json));
  }
}

void bleReply(const String& json) {
  if (!bleCommandChar) return;
  String sequenced = json;
  const uint32_t sequence = ++bleResponseSequence;
  if (json.startsWith("{") && json.length() > 1) {
    sequenced = String("{\"responseSequence\":") + String(sequence) +
                "," + json.substring(1);
  }
  bleCommandChar->setValue(sequenced.c_str());
  if (bleClientConnected) {
    bleCommandChar->notify();
  }
}

String buildBleStatusJson() {
  int readyModules = 0;
  for (auto& pair : ioModules) if (pair.second.ready) readyModules++;
  const float temperature = dht.readTemperature();
  const float humidity = dht.readHumidity();
  const bool flame = digitalRead(FLAME_SENSOR_PIN) == LOW;
  String json = "{";
  json += "\"ok\":true,";
  json += "\"firmwareVersion\":\"" SMART_HOME_FIRMWARE_VERSION "\",";
  json += "\"assistantReady\":true,";
  json += "\"speakerEnabled\":" + String(ELLIE_SPEAKER_ENABLED == 1 ? "true" : "false") + ",";
  json += "\"uniqueCode\":\"" + esp32UniqueCode + "\",";
  json += "\"assistantName\":\"" + jsonEscape(assistantName) + "\",";
  json += "\"temperature\":";
  if (isnan(temperature)) json += "null";
  else json += String(temperature, 1);
  json += ",";
  json += "\"humidity\":";
  if (isnan(humidity)) json += "null";
  else json += String(humidity, 1);
  json += ",";
  json += "\"flame\":" + String(flame ? "true" : "false") + ",";
  json += "\"wifiConnected\":" + String(WiFi.status() == WL_CONNECTED ? "true" : "false") + ",";
  json += "\"ssid\":\"" + jsonEscape(WiFi.SSID()) + "\",";
  json += "\"ip\":\"" + WiFi.localIP().toString() + "\",";
  json += "\"rssi\":" + String(WiFi.RSSI()) + ",";
  json += "\"registered\":" + String(isRegistered ? "true" : "false") + ",";
  json += "\"ioModules\":" + String((int)ioModules.size()) + ",";
  json += "\"readyModules\":" + String(readyModules) + ",";
  json += "\"devices\":" + String((int)devices.size());
  json += "}";
  return json;
}

bool isBleWriteAuthorized(DynamicJsonDocument& doc) {
  if (!BLE_REQUIRE_PIN) return true;
  String pin = doc["pin"] | "";
  return pin == BLE_CONTROL_PIN;
}

String buildBleDevicesJson() {
  String json = "{\"ok\":true,\"devices\":[";
  bool first = true;
  for (auto& pair : devices) {
    Device& d = pair.second;
    if (!first) json += ",";
    first = false;
    json += "{";
    json += "\"id\":\"" + jsonEscape(d.id) + "\",";
    json += "\"name\":\"" + jsonEscape(d.name) + "\",";
    json += "\"type\":" + String(d.type) + ",";
    json += "\"moduleId\":\"" + jsonEscape(d.moduleId) + "\",";
    json += "\"channel\":" + String(d.channel) + ",";
    json += "\"relayOutput\":\"" + jsonEscape(d.moduleId) + "/P" + String(d.channel) + "\",";
    json += "\"state\":" + String(d.state ? "true" : "false") + ",";
    json += "\"room\":\"" + jsonEscape(d.room) + "\",";
    json += "\"enabled\":" + String(d.enabled ? "true" : "false");
    json += "}";
  }
  json += "]}";
  return json;
}

String buildBleWifiScanJson() {
  String json = "{\"ok\":true,\"cmd\":\"wifi_scan\",\"networks\":[";

  WiFi.scanDelete();
  delay(30);
  int count = WiFi.scanNetworks(false, true);
  if (count < 0) {
    json += "],\"scanError\":" + String(count) + "}";
    return json;
  }

  std::vector<String> seenSsids;
  int added = 0;
  const int maxBleNetworks = 8; // Keep BLE response small and reliable.

  for (int i = 0; i < count && added < maxBleNetworks; i++) {
    String ssid = WiFi.SSID(i);
    if (ssid.length() == 0) continue;

    bool alreadySeen = false;
    for (String existing : seenSsids) {
      if (existing == ssid) {
        alreadySeen = true;
        break;
      }
    }
    if (alreadySeen) continue;
    seenSsids.push_back(ssid);

    wifi_auth_mode_t auth = WiFi.encryptionType(i);
    if (added > 0) json += ",";
    json += "{";
    json += "\"ssid\":\"" + jsonEscape(ssid) + "\",";
    json += "\"rssi\":" + String(WiFi.RSSI(i)) + ",";
    json += "\"channel\":" + String(WiFi.channel(i)) + ",";
    json += "\"encryption\":\"" + wifiEncryptionName(auth) + "\",";
    json += "\"secure\":" + String(isSecureWifi(auth) ? "true" : "false") + ",";
    json += "\"current\":" + String(ssid == WiFi.SSID() ? "true" : "false");
    json += "}";
    added++;
  }

  WiFi.scanDelete();
  json += "],\"count\":" + String(added) + "}";
  return json;
}

bool setDeviceOutputLocal(const String& id, const String& newModuleId, int newChannel) {
  auto it = devices.find(id);
  if (it == devices.end() || !moduleExists(newModuleId) || !isValidPcfChannel(newChannel)) return false;
  if (outputAlreadyUsed(newModuleId, newChannel, id)) return false;

  Device& d = it->second;
  String oldModule = d.moduleId;
  int oldChannel = d.channel;
  setRelayOutput(oldModule, oldChannel, false);
  outputStates.erase(outputKey(oldModule, oldChannel));

  d.moduleId = newModuleId;
  d.channel = newChannel;
  if (!setRelayOutput(newModuleId, newChannel, d.state)) {
    d.moduleId = oldModule;
    d.channel = oldChannel;
    setRelayOutput(oldModule, oldChannel, d.state);
    outputStates[outputKey(oldModule, oldChannel)] = d.state;
    return false;
  }
  outputStates[outputKey(newModuleId, newChannel)] = d.state;
  saveDevicesToPreferences();

  if (isRegistered && WiFi.status() == WL_CONNECTED) {
    String json = "{\"moduleId\":\"" + jsonEscape(newModuleId) + "\",\"expanderId\":\"" +
                  jsonEscape(newModuleId) + "\",\"channel\":" + String(newChannel) + "}";
    httpPatch(firebasePath + "devices/" + id + ".json", json);
  }
  return true;
}

void handleBleCommand(const String& raw) {
  Serial.println("🔵 BLE command: " + raw);

  DynamicJsonDocument doc(2048);
  DeserializationError err = deserializeJson(doc, raw);
  if (err) {
    bleReply("{\"ok\":false,\"error\":\"Invalid JSON\"}");
    return;
  }

  String cmd = doc["cmd"] | "";

  if (cmd == "ping" || cmd == "status") {
    bleReply(buildBleStatusJson());
    return;
  }

  if (cmd == "get_devices") {
    String json = buildBleDevicesJson();
    if (json.length() > 1800) {
      bleReply("{\"ok\":false,\"error\":\"Device list too large for BLE response\",\"count\":" + String((int)devices.size()) + "}");
    } else {
      bleReply(json);
    }
    return;
  }

  if (cmd == "get_assistant_name") {
    bleReply("{\"ok\":true,\"assistantName\":\"" +
             jsonEscape(assistantName) + "\"}");
    return;
  }

  if (cmd == "set_assistant_name") {
    if (!isBleWriteAuthorized(doc)) {
      bleReply("{\"ok\":false,\"error\":\"Invalid BLE PIN\"}");
      return;
    }
    const String requestedName = doc["assistantName"] | "";
    if (!setAssistantName(requestedName)) {
      bleReply("{\"ok\":false,\"error\":\"Invalid assistant name\"}");
      return;
    }
    bleReply("{\"ok\":true,\"assistantName\":\"" +
             jsonEscape(assistantName) + "\"}");
    return;
  }

  if (cmd == "ellie" || cmd == "assistant") {
    if (!isBleWriteAuthorized(doc)) {
      bleReply("{\"ok\":false,\"error\":\"Invalid BLE PIN\"}");
      return;
    }
    const String requestedName = doc["assistantName"] | "";
    if (requestedName.length() > 0 && !setAssistantName(requestedName)) {
      bleReply("{\"ok\":false,\"error\":\"Invalid assistant name\"}");
      return;
    }
    String text = doc["text"] | "";
    const bool speak = doc["speak"] | true;
    text.trim();
    if (text.length() == 0) {
      bleReply("{\"ok\":false,\"error\":\"Missing assistant text\"}");
      return;
    }
    if (text.length() > ELLIE_MAX_INPUT_CHARS) {
      bleReply("{\"ok\":false,\"error\":\"Assistant text is too long\"}");
      return;
    }
    bleReply(processEllieText(text, speak, true));
    return;
  }

  if (cmd == "ellie_speak" || cmd == "assistant_speak") {
    if (!isBleWriteAuthorized(doc)) {
      bleReply("{\"ok\":false,\"error\":\"Invalid BLE PIN\"}");
      return;
    }
    String text = doc["text"] | "";
    text.trim();
    if (text.length() > ELLIE_MAX_SPEECH_CHARS) text = text.substring(0, ELLIE_MAX_SPEECH_CHARS);
    const bool queued = queueEllieSpeech(text);
    bleReply(String("{\"ok\":") + (queued ? "true" : "false") +
             ",\"speakerQueued\":" + (queued ? "true" : "false") + "}");
    return;
  }

  if (cmd == "set_device") {
    if (!isBleWriteAuthorized(doc)) {
      bleReply("{\"ok\":false,\"error\":\"Invalid BLE PIN\"}");
      return;
    }
    String id = doc["id"] | "";
    bool state = doc["state"] | false;
    if (id.length() == 0 || devices.find(id) == devices.end()) {
      bleReply("{\"ok\":false,\"error\":\"Device not found\"}");
      return;
    }
    setDeviceStateInternal(id, state, true);
    bleReply("{\"ok\":true,\"cmd\":\"set_device\",\"id\":\"" + jsonEscape(id) + "\",\"state\":" + String(state ? "true" : "false") + "}");
    return;
  }

  // Backward-compatible room light command, useful for older app builds.
  if (cmd == "set_light" || cmd == "set_room") {
    if (!isBleWriteAuthorized(doc)) {
      bleReply("{\"ok\":false,\"error\":\"Invalid BLE PIN\"}");
      return;
    }
    String room = doc["room"] | "";
    bool state = doc["state"] | false;
    for (auto& pair : devices) {
      Device& d = pair.second;
      if (d.room == room && d.type == 0) {
        setDeviceStateInternal(d.id, state, true);
        bleReply("{\"ok\":true,\"cmd\":\"set_room\",\"room\":\"" + jsonEscape(room) + "\",\"state\":" + String(state ? "true" : "false") + "}");
        return;
      }
    }
    bleReply("{\"ok\":false,\"error\":\"No light found in room\"}");
    return;
  }

  if (cmd == "edit_output" || cmd == "edit_channel" || cmd == "edit_gpio") {
    if (!isBleWriteAuthorized(doc)) {
      bleReply("{\"ok\":false,\"error\":\"Invalid BLE PIN\"}");
      return;
    }
    String id = doc["id"] | "";
    String moduleId = doc["moduleId"] | DEFAULT_MODULE_ID;
    int channel = doc["channel"] | -1;
    bool ok = setDeviceOutputLocal(id, moduleId, channel);
    bleReply(String("{\"ok\":") + (ok ? "true" : "false") + ",\"cmd\":\"edit_output\"}");
    return;
  }

  if (cmd == "sync_devices" || cmd == "reload_devices") {
    if (WiFi.status() != WL_CONNECTED || !isRegistered) {
      bleReply("{\"ok\":false,\"cmd\":\"sync_devices\",\"error\":\"Wi-Fi or registration unavailable\"}");
      return;
    }
    manualSyncRequested = true;
    bleReply("{\"ok\":true,\"cmd\":\"sync_devices\",\"queued\":true}");
    return;
  }

  if (cmd == "get_io_modules") {
    String json = String("{\"ok\":true,\"hardware\":") + buildHardwareConfigJson() + "}";
    if (json.length() > 3500) bleReply("{\"ok\":false,\"error\":\"Hardware response too large\"}");
    else bleReply(json);
    return;
  }

  if (cmd == "wifi_status") {
    bleReply(buildBleStatusJson());
    return;
  }

  if (cmd == "wifi_scan") {
    String json = buildBleWifiScanJson();
    if (json.length() > 1800) {
      bleReply("{\"ok\":false,\"cmd\":\"wifi_scan\",\"error\":\"Wi-Fi scan response too large\"}");
    } else {
      bleReply(json);
    }
    return;
  }

  if (cmd == "wifi_connect") {
    if (!isBleWriteAuthorized(doc)) {
      bleReply("{\"ok\":false,\"error\":\"Invalid BLE PIN\"}");
      return;
    }
    String ssid = doc["ssid"] | "";
    String pass = doc["password"] | "";
    if (pass.length() == 0) {
      const char* passAlt = doc["pass"] | "";
      pass = String(passAlt);
    }
    ssid.trim();
    if (ssid.length() == 0) {
      bleReply("{\"ok\":false,\"error\":\"Missing SSID\"}");
      return;
    }
    saveCredentials(ssid, pass);
    bleReply("{\"ok\":true,\"message\":\"Wi-Fi saved. Restarting ESP32.\"}");
    pendingWifiRestart = true;
    pendingWifiRestartAt = millis() + 900;
    return;
  }

  if (cmd == "forget_wifi" || cmd == "wifi_forget") {
    if (!isBleWriteAuthorized(doc)) {
      bleReply("{\"ok\":false,\"error\":\"Invalid BLE PIN\"}");
      return;
    }
    prefs.begin("wifi", false);
    prefs.clear();
    prefs.end();
    savedSSID = "";
    savedPass = "";
    bleReply("{\"ok\":true,\"message\":\"Wi-Fi forgotten. Restarting setup mode.\"}");
    pendingWifiRestart = true;
    pendingWifiRestartAt = millis() + 900;
    return;
  }

  bleReply("{\"ok\":false,\"error\":\"Unknown command\"}");
}

// =======================
// CORS HELPERS FOR FLUTTER WEB
// =======================
void addCorsHeaders() {
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.sendHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  server.sendHeader("Access-Control-Allow-Headers", "Content-Type, Cache-Control");
  server.sendHeader("Access-Control-Max-Age", "86400");
}

void sendCorsJson(int code, const String& json) {
  addCorsHeaders();
  server.send(code, "application/json", json);
}

void handleCorsOptions() {
  addCorsHeaders();
  server.send(204);
}

void registerCorsOptions(const char* path) {
  server.on(path, HTTP_OPTIONS, handleCorsOptions);
}

// =======================
// HTTP API FOR DEVICE MANAGEMENT
// =======================
void setupDeviceAPI() {
  registerCorsOptions("/api/sync");
  registerCorsOptions("/api/devices/add");
  registerCorsOptions("/api/devices/remove");
  registerCorsOptions("/api/devices");
  registerCorsOptions("/api/devices/control");
  registerCorsOptions("/api/channels");
  registerCorsOptions("/api/io/modules");
  registerCorsOptions("/api/io/modules/save");
  registerCorsOptions("/api/io/reload");
  registerCorsOptions("/api/devices/output");
  registerCorsOptions("/api/io/scan");
  registerCorsOptions("/api/gpio/scan");  // backward-compatible alias
  registerCorsOptions("/api/rooms");
  registerCorsOptions("/api/wifi/status");
  registerCorsOptions("/api/wifi/scan");
  registerCorsOptions("/api/wifi/connect");
  registerCorsOptions("/api/wifi/forget");
  registerCorsOptions("/api/devicetypes");
  registerCorsOptions("/api/ellie");
  registerCorsOptions("/api/ellie/speak");
  registerCorsOptions("/api/ellie/capabilities");
  registerCorsOptions("/api/assistant/name");

  server.on("/api/assistant/name", HTTP_GET, []() {
    sendCorsJson(200, "{\"success\":true,\"assistantName\":\"" +
                           jsonEscape(assistantName) + "\"}");
  });

  server.on("/api/assistant/name", HTTP_POST, []() {
    const String requestedName = readRequestArg("assistantName");
    if (!setAssistantName(requestedName)) {
      sendCorsJson(400, "{\"success\":false,\"error\":\"Invalid assistant name\"}");
      return;
    }
    sendCorsJson(200, "{\"success\":true,\"assistantName\":\"" +
                           jsonEscape(assistantName) + "\"}");
  });

  server.on("/api/ellie/capabilities", HTTP_GET, []() {
    DynamicJsonDocument doc(1536);
    doc["success"] = true;
    doc["firmwareVersion"] = SMART_HOME_FIRMWARE_VERSION;
    doc["assistantReady"] = true;
    doc["assistant"] = assistantName;
    doc["offlineControl"] = true;
    doc["conversationMode"] = "deterministic_local";
    doc["remoteAudioEnabled"] = false;
    doc["nameStoredOnEsp32"] = true;
    doc["bilingualText"] = true;
    doc["englishOfflineSpeech"] =
        ELLIE_SPEAKER_ENABLED == 1 && ELLIE_SAM_LIBRARY_AVAILABLE == 1;
    doc["arabicEsp32Speech"] = false;
    doc["speakerEnabled"] = ELLIE_SPEAKER_ENABLED == 1;
    doc["samLibraryAvailable"] = ELLIE_SAM_LIBRARY_AVAILABLE == 1;
    JsonArray languages = doc.createNestedArray("languages");
    languages.add("en");
    languages.add("ar");
#if ELLIE_SPEAKER_ENABLED
    JsonObject pins = doc.createNestedObject("i2sPins");
    pins["bclk"] = ELLIE_I2S_BCLK_PIN;
    pins["lrc"] = ELLIE_I2S_LRC_PIN;
    pins["dout"] = ELLIE_I2S_DOUT_PIN;
#endif
    JsonArray intents = doc.createNestedArray("offlineIntents");
    intents.add("device_on_off");
    intents.add("multiple_named_devices_on_off");
    intents.add("room_on_off");
    intents.add("all_devices_on_off");
    intents.add("device_status");
    intents.add("temperature");
    intents.add("humidity");
    intents.add("fire_status");
    String json;
    serializeJson(doc, json);
    sendCorsJson(200, json);
  });

  server.on("/api/ellie", HTTP_POST, []() {
    String text = readRequestArg("text");
    String speakValue = readRequestArg("speak");
    const String requestedName = readRequestArg("assistantName");
    text.trim();

    if (requestedName.length() > 0 && !setAssistantName(requestedName)) {
      sendCorsJson(400, "{\"success\":false,\"error\":\"Invalid assistant name\"}");
      return;
    }

    if (text.length() == 0) {
      sendCorsJson(400, "{\"success\":false,\"error\":\"Missing assistant text\"}");
      return;
    }
    if (text.length() > ELLIE_MAX_INPUT_CHARS) {
      sendCorsJson(413, "{\"success\":false,\"error\":\"Assistant text is too long\"}");
      return;
    }

    const bool speak = speakValue.length() == 0 || speakValue == "true" || speakValue == "1";
    sendCorsJson(200, processEllieText(text, speak));
  });

  server.on("/api/ellie/speak", HTTP_POST, []() {
    String text = readRequestArg("text");
    text.trim();
    if (text.length() == 0) {
      sendCorsJson(400, "{\"success\":false,\"error\":\"Missing speech text\"}");
      return;
    }
    if (text.length() > ELLIE_MAX_SPEECH_CHARS) text = text.substring(0, ELLIE_MAX_SPEECH_CHARS);
    const bool queued = queueEllieSpeech(text);
    String json = String("{\"success\":") + (queued ? "true" : "false") +
                  ",\"speakerQueued\":" + (queued ? "true" : "false") + "}";
    sendCorsJson(queued ? 202 : 503, json);
  });

  server.on("/api/sync", HTTP_GET, []() {
    Serial.println("🔄 Manual sync triggered from API");
    syncHardwareFromFirebase();
    syncDevicesFromFirebase();
    sendCorsJson(200, "{\"success\":true,\"message\":\"Sync completed\"}");
  });

  server.on("/api/devices/add", HTTP_POST, []() {
    if (server.hasArg("name") && server.hasArg("type") && server.hasArg("moduleId") && server.hasArg("channel") && server.hasArg("room")) {
      String name = server.arg("name");
      int type = server.arg("type").toInt();
      String moduleId = server.arg("moduleId");
      int channel = server.arg("channel").toInt();
      String room = server.arg("room");
      String requestedId = readRequestArg("id");
      if (!moduleExists(moduleId) || !isValidPcfChannel(channel)) {
        String error = "{\"error\":\"Invalid I/O module or channel.\"}";
        sendCorsJson(400, error);
        return;
      }
      if (outputAlreadyUsed(moduleId, channel, requestedId)) {
        sendCorsJson(400, "{\"error\":\"I/O module channel already in use\"}");
        return;
      }
      // Flutter may provide the Firebase-generated ID. Using the same ID lets
      // the ESP32 activate the new output immediately without a restart.
      String newId = addDevice(name, type, moduleId, channel, room, requestedId, requestedId.length() == 0);
      if (newId.length() == 0) {
        sendCorsJson(500, "{\"error\":\"Failed to add device\"}");
        return;
      }
      String response = "{\"success\":true,\"id\":\"" + newId + "\"}";
      sendCorsJson(200, response);
    } else {
      sendCorsJson(400, "{\"error\":\"Missing parameters\"}");
    }
  });

  server.on("/api/devices/remove", HTTP_POST, []() {
    if (server.hasArg("id")) {
      String id = server.arg("id");
      removeDevice(id);
      sendCorsJson(200, "{\"success\":true}");
    } else {
      sendCorsJson(400, "{\"error\":\"Missing device ID\"}");
    }
  });

  server.on("/api/devices", HTTP_GET, []() {
    StaticJsonDocument<4096> doc;
    JsonArray devicesArray = doc.createNestedArray("devices");
    for (auto& pair : devices) {
      Device& device = pair.second;
      JsonObject devObj = devicesArray.createNestedObject();
      devObj["id"] = device.id;
      devObj["name"] = device.name;
      devObj["type"] = device.type;
      devObj["moduleId"] = device.moduleId;
      devObj["expanderId"] = device.moduleId;
      devObj["channel"] = device.channel;
      devObj["relayOutput"] = device.moduleId + String("/P") + String(device.channel);
      devObj["state"] = device.state;
      devObj["room"] = device.room;
      devObj["enabled"] = device.enabled;
    }
    String jsonStr;
    serializeJson(doc, jsonStr);
    sendCorsJson(200, jsonStr);
  });

  server.on("/api/devices/control", HTTP_POST, []() {
    if (server.hasArg("id") && server.hasArg("state")) {
      String id = server.arg("id");
      bool state = server.arg("state") == "true";

      if (devices.find(id) == devices.end()) {
        sendCorsJson(404, "{\"error\":\"Device not found\"}");
        return;
      }

      setDeviceState(id, state);
      sendCorsJson(200, "{\"success\":true}");
    } else {
      sendCorsJson(400, "{\"error\":\"Missing parameters\"}");
    }
  });

  auto sendModuleChannels = []() {
    String requestedModule = server.hasArg("moduleId") ? server.arg("moduleId") : String(DEFAULT_MODULE_ID);
    DynamicJsonDocument doc(8192);
    doc["success"] = moduleExists(requestedModule);
    doc["moduleId"] = requestedModule;
    JsonArray available = doc.createNestedArray("available");
    JsonArray used = doc.createNestedArray("used");

    if (moduleExists(requestedModule)) {
      IOModule& module = ioModules[requestedModule];
      doc["ready"] = module.ready;
      doc["busId"] = module.busId;
      doc["address"] = module.address;
      doc["sda"] = i2cBuses[module.busId].sda;
      doc["scl"] = i2cBuses[module.busId].scl;

      for (int channel = 0; channel < PCF8574_CHANNEL_COUNT; channel++) {
        String deviceId = "";
        String deviceName = "";
        for (auto& pair : devices) {
          if (pair.second.moduleId == requestedModule && pair.second.channel == channel) {
            deviceId = pair.first;
            deviceName = pair.second.name;
            break;
          }
        }
        bool inUse = deviceId.length() > 0;
        JsonObject item = (inUse ? used : available).createNestedObject();
        item["moduleId"] = requestedModule;
        item["channel"] = channel;
        item["output"] = String("P") + String(channel);
        item["relay"] = channel + 1;
        item["label"] = requestedModule + String(" / P") + String(channel) + String(" / Relay ") + String(channel + 1);
        item["available"] = !inUse;
        if (inUse) { item["deviceId"] = deviceId; item["deviceName"] = deviceName; }
      }
    }
    String json;
    serializeJson(doc, json);
    sendCorsJson(200, json);
  };

  server.on("/api/channels", HTTP_GET, sendModuleChannels);
  server.on("/api/io/scan", HTTP_GET, sendModuleChannels);
  server.on("/api/gpio/scan", HTTP_GET, sendModuleChannels);

  server.on("/api/io/modules", HTTP_GET, []() {
    DynamicJsonDocument doc(12288);
    deserializeJson(doc, buildHardwareConfigJson());
    JsonObject root = doc.as<JsonObject>();
    JsonObject modules = root["ioModules"].as<JsonObject>();
    for (JsonPair pair : modules) {
      if (ioModules.find(pair.key().c_str()) != ioModules.end()) {
        pair.value()["ready"] = ioModules[pair.key().c_str()].ready;
      }
    }
    String json;
    serializeJson(root, json);
    sendCorsJson(200, json);
  });

  server.on("/api/io/modules/save", HTTP_POST, []() {
    String body = server.hasArg("plain") ? server.arg("plain") : "";
    if (body.length() < 2 || !applyHardwareConfigJson(body, true, true)) {
      sendCorsJson(400, "{\"success\":false,\"error\":\"Invalid hardware configuration\"}");
      return;
    }
    if (isRegistered && WiFi.status() == WL_CONNECTED) {
      httpPut(firebasePath + "hardware.json", buildHardwareConfigJson(), FIREBASE_LONG_HTTP_TIMEOUT_MS);
    }
    sendCorsJson(200, "{\"success\":true,\"message\":\"I/O modules applied\"}");
  });

  server.on("/api/io/reload", HTTP_POST, []() {
    manualHardwareSyncRequested = true;
    sendCorsJson(200, "{\"success\":true,\"message\":\"Hardware reload queued\"}");
  });

  server.on("/api/devices/output", HTTP_POST, []() {
    String id = readRequestArg("id");
    String moduleId = readRequestArg("moduleId");
    int channel = readRequestArg("channel").toInt();
    bool ok = setDeviceOutputLocal(id, moduleId, channel);
    sendCorsJson(ok ? 200 : 400, ok ? "{\"success\":true}" : "{\"success\":false,\"error\":\"Output unavailable\"}");
  });

  server.on("/api/rooms", HTTP_GET, []() {
    StaticJsonDocument<2048> doc;
    JsonArray rooms = doc.createNestedArray("rooms");

    // Return the real Firebase rooms list. Do not inject fake default rooms.
    if (isRegistered && firebasePath.length() > 0) {
      String response = httpGet(firebasePath + "rooms.json");
      if (response.length() > 0 && response != "null") {
        DynamicJsonDocument roomsDoc(2048);
        DeserializationError err = deserializeJson(roomsDoc, response);
        if (!err) {
          if (roomsDoc.is<JsonArray>()) {
            for (JsonVariant v : roomsDoc.as<JsonArray>()) {
              rooms.add(v.as<String>());
            }
          } else if (roomsDoc.is<JsonObject>()) {
            for (JsonPair p : roomsDoc.as<JsonObject>()) {
              rooms.add(p.value().as<String>());
            }
          }
        }
      }
    }

    String jsonStr;
    serializeJson(doc, jsonStr);
    sendCorsJson(200, jsonStr);
  });

  server.on("/api/wifi/status", HTTP_GET, []() {
    StaticJsonDocument<512> doc;
    doc["success"] = true;
    doc["firmwareVersion"] = SMART_HOME_FIRMWARE_VERSION;
    doc["assistantReady"] = true;
    doc["assistantName"] = assistantName;
    doc["speakerEnabled"] = ELLIE_SPEAKER_ENABLED == 1;
    doc["online"] = WiFi.status() == WL_CONNECTED;
    doc["ssid"] = WiFi.SSID();
    doc["ip"] = WiFi.localIP().toString();
    doc["gateway"] = WiFi.gatewayIP().toString();
    doc["rssi"] = WiFi.RSSI();
    doc["mac"] = WiFi.macAddress();
    doc["uniqueCode"] = esp32UniqueCode;
    doc["lastSeen"] = (long long)time(nullptr);
    doc["registered"] = isRegistered;
    int readyModules = 0;
    for (auto& pair : ioModules) if (pair.second.ready) readyModules++;
    doc["ioModuleCount"] = (int)ioModules.size();
    doc["readyModuleCount"] = readyModules;
    String jsonStr;
    serializeJson(doc, jsonStr);
    sendCorsJson(200, jsonStr);
  });

  server.on("/api/wifi/scan", HTTP_GET, []() {
    Serial.println("📡 Wi-Fi scan requested from app");

    StaticJsonDocument<8192> doc;
    doc["success"] = true;

    JsonObject connected = doc.createNestedObject("connected");
    connected["ssid"] = WiFi.SSID();
    connected["ip"] = WiFi.localIP().toString();
    connected["gateway"] = WiFi.gatewayIP().toString();
    connected["rssi"] = WiFi.RSSI();
    connected["mac"] = WiFi.macAddress();

    JsonArray networks = doc.createNestedArray("networks");

    WiFi.scanDelete();
    delay(50);

    // false = synchronous scan, true = include hidden networks.
    int count = WiFi.scanNetworks(false, true);
    if (count < 0) {
      doc["scanError"] = count;
      count = 0;
    }

    std::vector<String> seenSsids;
    String currentSsid = WiFi.SSID();

    for (int i = 0; i < count; i++) {
      String ssid = WiFi.SSID(i);
      if (ssid.length() == 0) continue;

      bool alreadySeen = false;
      for (String existing : seenSsids) {
        if (existing == ssid) {
          alreadySeen = true;
          break;
        }
      }
      if (alreadySeen) continue;
      seenSsids.push_back(ssid);

      wifi_auth_mode_t auth = WiFi.encryptionType(i);
      JsonObject net = networks.createNestedObject();
      net["ssid"] = ssid;
      net["rssi"] = WiFi.RSSI(i);
      net["channel"] = WiFi.channel(i);
      net["encryption"] = wifiEncryptionName(auth);
      net["secure"] = isSecureWifi(auth);
      net["current"] = ssid == currentSsid;
    }

    WiFi.scanDelete();

    String jsonStr;
    serializeJson(doc, jsonStr);
    sendCorsJson(200, jsonStr);
    Serial.printf("📡 Wi-Fi scan returned %d unique networks\n", networks.size());
  });

  server.on("/api/wifi/connect", HTTP_POST, []() {
    String ssid = readRequestArg("ssid");
    String pass = readRequestArg("pass");
    if (pass.length() == 0) pass = readRequestArg("password");

    ssid.trim();
    if (ssid.length() == 0) {
      sendCorsJson(400, "{\"success\":false,\"error\":\"Missing SSID\"}");
      return;
    }

    saveCredentials(ssid, pass);

    String json = "{";
    json += "\"success\":true,";
    json += "\"message\":\"Wi-Fi saved. ESP32 will restart and reconnect.\",";
    json += "\"ssid\":\"" + jsonEscape(ssid) + "\"";
    json += "}";
    sendCorsJson(200, json);

    pendingWifiRestart = true;
    pendingWifiRestartAt = millis() + 900;
    Serial.println("📡 New Wi-Fi credentials saved. Restart scheduled for SSID: " + ssid);
  });

  server.on("/api/wifi/forget", HTTP_POST, []() {
    prefs.begin("wifi", false);
    prefs.clear();
    prefs.end();
    savedSSID = "";
    savedPass = "";

    sendCorsJson(200, "{\"success\":true,\"message\":\"Wi-Fi credentials cleared. Restarting into setup mode.\"}");

    pendingWifiRestart = true;
    pendingWifiRestartAt = millis() + 900;
    Serial.println("🧹 Wi-Fi credentials cleared. Restart scheduled.");
  });

  server.on("/api/devicetypes", HTTP_GET, []() {
    StaticJsonDocument<1024> doc;
    JsonArray types = doc.createNestedArray("types");
    JsonObject light = types.createNestedObject();
    light["type"] = 0;
    light["name"] = "Light";
    light["icon"] = "lightbulb";
    JsonObject fan = types.createNestedObject();
    fan["type"] = 1;
    fan["name"] = "Fan";
    fan["icon"] = "fan";
    JsonObject switchObj = types.createNestedObject();
    switchObj["type"] = 2;
    switchObj["name"] = "Switch";
    switchObj["icon"] = "power";
    JsonObject socket = types.createNestedObject();
    socket["type"] = 3;
    socket["name"] = "Socket";
    socket["icon"] = "power_plug";
    String jsonStr;
    serializeJson(doc, jsonStr);
    sendCorsJson(200, jsonStr);
  });
}

// =======================
// SETUP
// =======================
void setup() {
  Serial.begin(115200);
  delay(1000);
  esp32UniqueCode = generateUniqueCode();
  Serial.println("🆔 ESP32 Unique Code: " + esp32UniqueCode);
  loadRegistration();
  pinMode(FLAME_SENSOR_PIN, INPUT);
  dht.begin();
  client.setInsecure();
  loadAssistantName();
  setupEllieSpeaker();
  setupCloudUploadWorker();

  // Restore I2C buses and I/O modules first, then cached devices for offline control.
  loadHardwareFromPreferences();
  setupAllIOModules();
  loadDevicesFromPreferences();
  setupBleBackup();

  loadCredentials();
  connectToWiFi();
  if (useCaptivePortal) {
    startCaptivePortal();
    return;
  }
  wifiWasConnected = true;
  Serial.println("✅ Connected to WiFi, IP: " + WiFi.localIP().toString());
  configTime(0, 0, "pool.ntp.org", "time.nist.gov");
  Serial.print("⏰ Waiting for NTP time");
  int retry = 0;
  time_t now = time(nullptr);
  while (now < 10000 && retry < 20) {
    delay(500);
    Serial.print(".");
    now = time(nullptr);
    retry++;
  }
  if (now > 10000) {
    Serial.println("\n✅ Time synchronized");
  } else {
    Serial.println("\n⚠️ Time sync failed");
  }

  Serial.println("📡 FORCE BROADCASTING to esp_public...");
  updateOnlineStatus();

  if (!isRegistered) {
    checkOwnerUID();
  }

  // Devices already loaded before Wi-Fi for BLE backup.

  if (isRegistered) {
    Serial.println("🔄 Syncing I/O modules and devices from Firebase on boot...");
    syncHardwareFromFirebase();
    syncDevicesFromFirebase();
  }

  if (devices.empty()) {
    Serial.println("📱 No devices found. Waiting for devices added from the dashboard...");
  }

  setupDeviceAPI();
  server.begin();
  Serial.println("🌐 HTTP server started");
  connectSSEStream();
}

// =======================
// LOOP
// =======================
void loop() {
  unsigned long now = millis();

  retryOfflineIOModules(now);
  processPendingBleCommands();

  if (useCaptivePortal) {
    dnsServer.processNextRequest();
    server.handleClient();

    if (pendingWifiRestart && now >= pendingWifiRestartAt) {
      Serial.println("🔄 Restarting ESP32 after Wi-Fi/BLE command...");
      delay(50);
      ESP.restart();
    }

    delay(1);
    return;
  }

  if (WiFi.status() != WL_CONNECTED) {
    wifiWasConnected = false;
    // Non-blocking reconnect. BLE callbacks still work while Wi-Fi/router/internet is down.
    if (now - lastWifiReconnectAttempt >= WIFI_RECONNECT_INTERVAL) {
      lastWifiReconnectAttempt = now;
      Serial.println("⚠️ WiFi lost, reconnecting in background...");
      WiFi.reconnect();
    }

    if (pendingWifiRestart && now >= pendingWifiRestartAt) {
      Serial.println("🔄 Restarting ESP32 after Wi-Fi/BLE command...");
      delay(50);
      ESP.restart();
    }

    delay(1);
    return;
  }

  if (!wifiWasConnected) {
    wifiWasConnected = true;
    streamConnected = false;
    streamClient.stop();
    updateOnlineStatus();
    manualSyncRequested = isRegistered;
    Serial.println("✅ Wi-Fi restored; status and device sync refreshed");
  }

  // Highest priority: local HTTP commands and cloud stream commands.
  server.handleClient();

  if (!streamConnected && isRegistered) {
    connectSSEStream();
  } else if (streamConnected) {
    readSSEStream();
  }

  server.handleClient();

  // Cloud writes are lower priority than local control/SSE reads.
  flushPendingCloudUploads();

  if (manualHardwareSyncRequested && isRegistered) {
    manualHardwareSyncRequested = false;
    syncHardwareFromFirebase();
    syncDevicesFromFirebase();
  }

  if (manualSyncRequested && isRegistered) {
    manualSyncRequested = false;
    syncDevicesFromFirebase();
  }

  server.handleClient();

  if (now - lastSend >= SEND_INTERVAL && isRegistered) {
    lastSend = now;
    sendSensorsToFirebase();
  }

  server.handleClient();

  if (now - lastHeartbeat >= HEARTBEAT_INTERVAL) {
    lastHeartbeat = now;
    updateOnlineStatus();
  }

  if (now - lastHardwareSync >= HARDWARE_SYNC_INTERVAL && isRegistered) {
    lastHardwareSync = now;
    syncHardwareFromFirebase();
  }

  if (now - lastSync >= SYNC_INTERVAL && isRegistered) {
    lastSync = now;
    syncDevicesFromFirebase();
  }

  if (now - lastOwnerCheck >= OWNER_CHECK_INTERVAL) {
    lastOwnerCheck = now;
    if (!isRegistered) {
      checkOwnerUID();
    }
  }

  if (pendingWifiRestart && now >= pendingWifiRestartAt) {
    Serial.println("🔄 Restarting ESP32 after Wi-Fi/BLE command...");
    delay(50);
    ESP.restart();
  }

  delay(1);
}
