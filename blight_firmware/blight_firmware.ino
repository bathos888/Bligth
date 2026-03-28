/**
 * BLight V1.0.4 - Main Firmware
 * Target: Wemos D1 Mini (ESP8266)
 * 
 * Features:
 * - 6 relays with per-relay auto/manual mode
 * - Captive portal for WiFi configuration (WiFiManager)
 * - HTTP REST API for mobile app
 * - FSM LDR with safety delay
 * - Offline-first (WiFi resilience)
 * 
 * Dependencies: ArduinoJson v6, WiFiManager
 */

#include <ESP8266WiFi.h>
#include <ESP8266WebServer.h>
#include <ESP8266mDNS.h>
#include <WiFiManager.h>
#include <ArduinoJson.h>
#include "config.h"

// --- Server ---
ESP8266WebServer server(80);

// --- LDR FSM ---
enum LDRState { ST_JOUR, ST_DEBUT_NUIT, ST_NUIT, ST_DEBUT_JOUR };

LDRState currentState = ST_JOUR;
unsigned long stateTimer = 0;
int lastLdrValue = 0;
unsigned long lastLdrSample = 0;

// --- Relay State ---
bool relayStates[NUM_RELAYS] = {false};
bool relayAutoModes[NUM_RELAYS] = {true, true, true, true, true, true};

// --- Thresholds ---
int seuilNuit = DEFAULT_SEUIL_NUIT;
int seuilJour = DEFAULT_SEUIL_JOUR;

// --- WiFi ---
bool wifiConnected = false;
unsigned long lastWifiCheck = 0;

void setup() {
  Serial.begin(115200);
  Serial.println("\n--- BLight V1.0.4 ---");

  // Init relays OFF (Active LOW)
  for (int i = 0; i < NUM_RELAYS; i++) {
    pinMode(RELAY_PINS[i], OUTPUT);
    digitalWrite(RELAY_PINS[i], HIGH);
  }

  // WiFi
  setupWiFi();

  // HTTP API
  setupServer();

  // mDNS
  if (wifiConnected) {
    MDNS.begin("blight");
    MDNS.addService("http", "tcp", 80);
    Serial.println("mDNS: blight.local");
  }
}

void loop() {
  server.handleClient();
  if (wifiConnected) MDNS.update();

  // WiFi monitor (non-blocking, infrequent)
  unsigned long now = millis();
  if (now - lastWifiCheck >= WIFI_RECONNECT_MS) {
    lastWifiCheck = now;
    if (WiFi.status() != WL_CONNECTED) {
      if (wifiConnected) Serial.println("WiFi Disconnected");
      wifiConnected = false;
      WiFi.reconnect();
    } else {
      if (!wifiConnected) {
        wifiConnected = true;
        Serial.println("WiFi Reconnected: " + WiFi.localIP().toString());
      }
    }
  }

  // LDR sampling
  if (now - lastLdrSample >= LDR_SAMPLE_MS) {
    lastLdrSample = now;
    lastLdrValue = analogRead(LDR_PIN);
    updateFSM(lastLdrValue, now);
  }

  yield();
}

// =============================================================================
// WiFi
// =============================================================================
void setupWiFi() {
  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(true);
  WiFi.persistent(true);

  // If saved credentials exist, try connecting directly
  if (WiFi.SSID().length() > 0) {
    Serial.println("WiFi: Connecting to " + WiFi.SSID() + "...");
    WiFi.begin();

    unsigned long start = millis();
    while (WiFi.status() != WL_CONNECTED && millis() - start < 15000) {
      delay(500);
      Serial.print(".");
    }
    Serial.println();
  }

  if (WiFi.status() == WL_CONNECTED) {
    wifiConnected = true;
    Serial.println("WiFi: Connected. IP = " + WiFi.localIP().toString());
    return;
  }

  // No connection → captive portal
  Serial.println("WiFi: Starting captive portal '" + String(AP_SSID) + "'");
  WiFiManager wm;
  wm.setConfigPortalTimeout(180);
  wm.setAPStaticIPConfig(IPAddress(192, 168, 4, 1), IPAddress(192, 168, 4, 1), IPAddress(255, 255, 255, 0));

  bool connected = wm.autoConnect(AP_SSID, AP_PASSWORD);

  if (connected) {
    wifiConnected = true;
    delay(1000);
    Serial.println("WiFi: Connected via portal. IP = " + WiFi.localIP().toString());
  } else {
    wifiConnected = false;
    Serial.println("WiFi: Portal timed out. Running offline.");
  }
}

// =============================================================================
// HTTP API
// =============================================================================
void setupServer() {
  // CORS + endpoints
  server.on("/api/status", HTTP_GET, handleStatus);
  server.on("/api/relay/toggle", HTTP_POST, handleToggle);
  server.on("/api/mode", HTTP_POST, handleMode);
  server.on("/api/thresholds", HTTP_POST, handleThresholds);
  server.on("/api/wifi/reset", HTTP_POST, handleWifiReset);

  // CORS preflight
  server.on("/api/status", HTTP_OPTIONS, corsOK);
  server.on("/api/relay/toggle", HTTP_OPTIONS, corsOK);
  server.on("/api/mode", HTTP_OPTIONS, corsOK);
  server.on("/api/thresholds", HTTP_OPTIONS, corsOK);
  server.on("/api/wifi/reset", HTTP_OPTIONS, corsOK);

  server.begin();
  Serial.println("HTTP: Server started on port 80");
}

void corsOK() {
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.sendHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  server.sendHeader("Access-Control-Allow-Headers", "Content-Type");
  server.send(204);
}

void sendJSON(int code, const String& json) {
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.send(code, "application/json", json);
}

String readBody() {
  if (server.hasArg("plain")) return server.arg("plain");
  return "";
}

// --- GET /api/status ---
void handleStatus() {
  StaticJsonDocument<768> doc;
  doc["app"] = "BLight";
  doc["etat_ldr"] = getLDRStateString(currentState);
  doc["valeur_ldr"] = lastLdrValue;
  doc["seuil_nuit"] = seuilNuit;
  doc["seuil_jour"] = seuilJour;
  doc["wifi_connected"] = wifiConnected;
  doc["ip"] = WiFi.localIP().toString();

  JsonArray relays = doc.createNestedArray("relays");
  JsonArray modes = doc.createNestedArray("relay_modes");
  for (int i = 0; i < NUM_RELAYS; i++) {
    relays.add(relayStates[i]);
    modes.add(relayAutoModes[i]);
  }

  String out;
  serializeJson(doc, out);
  sendJSON(200, out);
}

// --- POST /api/relay/toggle ---
void handleToggle() {
  StaticJsonDocument<64> doc;
  if (deserializeJson(doc, readBody())) {
    sendJSON(400, "{\"error\":\"Invalid JSON\"}");
    return;
  }

  int idx = doc["index"] | -1;
  if (idx < 0 || idx >= NUM_RELAYS) {
    sendJSON(400, "{\"error\":\"Invalid index\"}");
    return;
  }

  relayStates[idx] = !relayStates[idx];
  relayAutoModes[idx] = false;
  setRelay(idx, relayStates[idx]);

  Serial.println("Relay " + String(idx) + " -> " + String(relayStates[idx] ? "ON" : "OFF"));
  sendJSON(200, "{\"status\":\"ok\"}");
}

// --- POST /api/mode ---
void handleMode() {
  StaticJsonDocument<64> doc;
  if (deserializeJson(doc, readBody())) {
    sendJSON(400, "{\"error\":\"Invalid JSON\"}");
    return;
  }

  int idx = doc["index"] | -1;
  if (idx < 0 || idx >= NUM_RELAYS) {
    sendJSON(400, "{\"error\":\"Invalid index\"}");
    return;
  }

  bool autoMode = doc["auto"] | false;
  relayAutoModes[idx] = autoMode;

  if (autoMode) {
    bool shouldBeOn = isNightState(currentState);
    relayStates[idx] = shouldBeOn;
    setRelay(idx, shouldBeOn);
  }

  Serial.println("Relay " + String(idx) + " -> " + String(autoMode ? "Auto" : "Manual"));
  sendJSON(200, "{\"status\":\"ok\"}");
}

// --- POST /api/thresholds ---
void handleThresholds() {
  StaticJsonDocument<128> doc;
  if (deserializeJson(doc, readBody())) {
    sendJSON(400, "{\"error\":\"Invalid JSON\"}");
    return;
  }

  int n = doc["seuil_nuit"] | -1;
  int j = doc["seuil_jour"] | -1;
  if (n < 0 || n > 1023 || j < 0 || j > 1023) {
    sendJSON(400, "{\"error\":\"Invalid values\"}");
    return;
  }

  seuilNuit = n;
  seuilJour = j;
  Serial.println("Thresholds: nuit=" + String(seuilNuit) + " jour=" + String(seuilJour));
  sendJSON(200, "{\"status\":\"ok\"}");
}

// --- POST /api/wifi/reset ---
void handleWifiReset() {
  sendJSON(200, "{\"status\":\"resetting\"}");
  delay(500);
  WiFi.disconnect(true);
  ESP.restart();
}

// =============================================================================
// Relay
// =============================================================================
void setRelay(int idx, bool on) {
  digitalWrite(RELAY_PINS[idx], on ? LOW : HIGH);
}

// =============================================================================
// LDR
// =============================================================================
String getLDRStateString(LDRState s) {
  switch (s) {
    case ST_JOUR: return "JOUR";
    case ST_DEBUT_NUIT: return "DEBUT_NUIT";
    case ST_NUIT: return "NUIT";
    case ST_DEBUT_JOUR: return "DEBUT_JOUR";
    default: return "JOUR";
  }
}

bool isNightState(LDRState s) {
  return (s == ST_NUIT || s == ST_DEBUT_NUIT);
}

void updateFSM(int ldr, unsigned long now) {
  switch (currentState) {
    case ST_JOUR:
      if (ldr <= seuilNuit) {
        currentState = ST_DEBUT_NUIT;
        stateTimer = now;
        Serial.println("LDR: Night? (" + String(ldr) + "<=" + String(seuilNuit) + ")");
      }
      break;

    case ST_DEBUT_NUIT:
      if (ldr > seuilNuit) {
        currentState = ST_JOUR;
      } else if (now - stateTimer >= DELAI_NUIT_MS) {
        currentState = ST_NUIT;
        for (int i = 0; i < NUM_RELAYS; i++) {
          if (relayAutoModes[i]) { relayStates[i] = true; setRelay(i, true); }
        }
        Serial.println("LDR: Night confirmed. Auto relays ON.");
      }
      break;

    case ST_NUIT:
      if (ldr >= seuilJour) {
        currentState = ST_DEBUT_JOUR;
        stateTimer = now;
        Serial.println("LDR: Day? (" + String(ldr) + ">=" + String(seuilJour) + ")");
      }
      break;

    case ST_DEBUT_JOUR:
      if (ldr < seuilJour) {
        currentState = ST_NUIT;
      } else if (now - stateTimer >= DELAI_JOUR_MS) {
        currentState = ST_JOUR;
        for (int i = 0; i < NUM_RELAYS; i++) {
          if (relayAutoModes[i]) { relayStates[i] = false; setRelay(i, false); }
        }
        Serial.println("LDR: Day confirmed. Auto relays OFF.");
      }
      break;
  }
}
