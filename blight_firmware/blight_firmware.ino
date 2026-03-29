/**
 * BLight V1.0.7 - Main Firmware
 * Target: Wemos D1 Mini (ESP8266)
 *
 * Features:
 * - 6 relays with per-relay auto/manual mode
 * - Captive portal for WiFi configuration (WiFiManager)
 * - HTTP REST API for mobile app
 * - FSM LDR with safety delay
 * - Offline-first (WiFi resilience)
 * - LittleFS persistence (relays, modes, seuils)
 * - /api/relay/set : forçage d'état explicite (idempotent)
 * - mDNS restart automatique après reconnexion WiFi
 *
 * Dependencies: ArduinoJson v6, WiFiManager
 * Board package: esp8266 >= 3.0.0  (LittleFS inclus)
 *
 * API summary:
 *   GET  /api/status              → état complet JSON
 *   POST /api/relay/toggle        → {"index": N}          inverse l'état, passe en manuel
 *   POST /api/relay/set           → {"index": N, "state": bool}  force l'état, passe en manuel
 *   POST /api/mode                → {"index": N, "auto": bool}
 *   POST /api/thresholds          → {"seuil_nuit": N, "seuil_jour": N}
 *   POST /api/wifi/reset          → réinitialise les credentials WiFi
 */

#include <ESP8266WiFi.h>
#include <ESP8266WebServer.h>
#include <ESP8266mDNS.h>
#include <WiFiManager.h>
#include <ArduinoJson.h>
#include <LittleFS.h>
#include "config.h"

// --- Persistence ---
#define STATE_FILE "/state.json"

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
  Serial.println("\n--- BLight V1.0.7 ---");

  // Init relays OFF (Active LOW)
  for (int i = 0; i < NUM_RELAYS; i++) {
    pinMode(RELAY_PINS[i], OUTPUT);
    digitalWrite(RELAY_PINS[i], HIGH);
  }

  // LittleFS + restore state
  if (!LittleFS.begin()) {
    Serial.println("LittleFS: Mount failed — formatting...");
    LittleFS.format();
    LittleFS.begin();
  }
  loadState();

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
        // Redémarre mDNS — il ne survit pas à une coupure WiFi
        MDNS.end();
        if (MDNS.begin("blight")) {
          MDNS.addService("http", "tcp", 80);
          Serial.println("mDNS restarted: blight.local");
        } else {
          Serial.println("mDNS restart failed (non-bloquant)");
        }
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
  server.on("/api/status",       HTTP_GET,     handleStatus);
  server.on("/api/relay/toggle", HTTP_POST,    handleToggle);
  server.on("/api/relay/set",    HTTP_POST,    handleSet);
  server.on("/api/mode",         HTTP_POST,    handleMode);
  server.on("/api/thresholds",   HTTP_POST,    handleThresholds);
  server.on("/api/wifi/reset",   HTTP_POST,    handleWifiReset);

  // CORS preflight
  server.on("/api/status",       HTTP_OPTIONS, corsOK);
  server.on("/api/relay/toggle", HTTP_OPTIONS, corsOK);
  server.on("/api/relay/set",    HTTP_OPTIONS, corsOK);
  server.on("/api/mode",         HTTP_OPTIONS, corsOK);
  server.on("/api/thresholds",   HTTP_OPTIONS, corsOK);
  server.on("/api/wifi/reset",   HTTP_OPTIONS, corsOK);

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
  doc["app"] = "BLight V1.0.7";
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

// --- POST /api/relay/set ---
/**
 * Force l'état d'un relais à une valeur explicite (idempotent).
 * Contrairement à toggle, appeler set deux fois avec le même état
 * ne change rien — utile à la reconnexion de l'app Flutter.
 *
 * Body : {"index": N, "state": true|false}
 *
 * Passe le relais en mode manuel (même comportement que toggle).
 * Retourne aussi l'état appliqué pour confirmation côté Flutter.
 */
void handleSet() {
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

  if (!doc.containsKey("state")) {
    sendJSON(400, "{\"error\":\"Missing field: state\"}");
    return;
  }

  bool newState = doc["state"].as<bool>();
  relayStates[idx]    = newState;
  relayAutoModes[idx] = false;   // passage en manuel systématique
  setRelay(idx, newState);

  saveState();
  Serial.println("Relay " + String(idx) + " SET -> " + String(newState ? "ON" : "OFF"));

  // Réponse avec l'état confirmé (permet à Flutter de vérifier sans GET /status)
  String resp = "{\"status\":\"ok\",\"index\":" + String(idx) +
                ",\"state\":" + String(newState ? "true" : "false") + "}";
  sendJSON(200, resp);
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

  saveState();
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

  saveState();
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
    sendJSON(400, "{\"error\":\"Invalid values (0-1023)\"}");
    return;
  }
  if (n >= j) {
    sendJSON(400, "{\"error\":\"seuil_nuit must be < seuil_jour\"}");
    return;
  }

  seuilNuit = n;
  seuilJour = j;
  saveState();
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
// Persistence (LittleFS)
// =============================================================================

/**
 * saveState() — écrit l'état courant dans /state.json
 *
 * Format JSON :
 * {
 *   "relay_states": [false, false, ...],   // état ON/OFF de chaque relais
 *   "relay_modes":  [true,  true,  ...],   // true = auto, false = manuel
 *   "seuil_nuit": 300,
 *   "seuil_jour": 700
 * }
 *
 * Appelé après chaque modification via API.
 * Écrase l'ancien fichier à chaque fois (fichier petit, flash OK).
 */
void saveState() {
  File f = LittleFS.open(STATE_FILE, "w");
  if (!f) {
    Serial.println("LittleFS: Cannot open state.json for write");
    return;
  }

  StaticJsonDocument<256> doc;
  JsonArray states = doc.createNestedArray("relay_states");
  JsonArray modes  = doc.createNestedArray("relay_modes");
  for (int i = 0; i < NUM_RELAYS; i++) {
    states.add(relayStates[i]);
    modes.add(relayAutoModes[i]);
  }
  doc["seuil_nuit"] = seuilNuit;
  doc["seuil_jour"] = seuilJour;

  serializeJson(doc, f);
  f.close();
  Serial.println("LittleFS: State saved");
}

/**
 * loadState() — restaure l'état depuis /state.json au démarrage.
 *
 * Si le fichier est absent ou corrompu, les valeurs par défaut de config.h
 * sont conservées et les relais restent OFF (sécurité).
 * Les relais physiques sont mis à jour immédiatement après la restauration.
 */
void loadState() {
  if (!LittleFS.exists(STATE_FILE)) {
    Serial.println("LittleFS: No state file — using defaults");
    return;
  }

  File f = LittleFS.open(STATE_FILE, "r");
  if (!f) {
    Serial.println("LittleFS: Cannot open state.json for read");
    return;
  }

  StaticJsonDocument<256> doc;
  DeserializationError err = deserializeJson(doc, f);
  f.close();

  if (err) {
    Serial.println("LittleFS: state.json corrupted — using defaults");
    LittleFS.remove(STATE_FILE);
    return;
  }

  // Restore thresholds
  seuilNuit = doc["seuil_nuit"] | DEFAULT_SEUIL_NUIT;
  seuilJour = doc["seuil_jour"] | DEFAULT_SEUIL_JOUR;

  // Sanity check — protège contre un fichier écrit avec des valeurs inversées
  if (seuilNuit >= seuilJour) {
    Serial.println("LittleFS: Invalid thresholds in state — resetting to defaults");
    seuilNuit = DEFAULT_SEUIL_NUIT;
    seuilJour = DEFAULT_SEUIL_JOUR;
  }

  // Restore relay states and modes, then apply to GPIO
  JsonArray states = doc["relay_states"];
  JsonArray modes  = doc["relay_modes"];
  for (int i = 0; i < NUM_RELAYS; i++) {
    if (i < (int)states.size()) relayStates[i]    = states[i].as<bool>();
    if (i < (int)modes.size())  relayAutoModes[i] = modes[i].as<bool>();
    setRelay(i, relayStates[i]);
  }

  Serial.println("LittleFS: State loaded — nuit=" + String(seuilNuit) +
                 " jour=" + String(seuilJour));
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
  // ST_DEBUT_NUIT exclu intentionnellement : le signal n'est pas encore
  // confirmé stable (délai 5 s non écoulé). Activer les relais auto ici
  // provoquerait une impulsion parasite si la lumière revient avant confirmation.
  return (s == ST_NUIT);
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
