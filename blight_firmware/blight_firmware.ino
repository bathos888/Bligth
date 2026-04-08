/**
 * BLight V1.1.0 - Firmware avec Firebase REST
 * Target: Wemos D1 Mini (ESP8266)
 *
 * Nouveautés V1.1.0 :
 * - Publication de l'état sur Firebase Realtime Database (REST)
 * - Lecture des commandes Firebase toutes les 3 secondes
 * - Fonctionne en offline-first (Firebase optionnel)
 *
 * Structure Firebase :
 *   /blight/status/     ← ESP écrit son état ici
 *   /blight/commands/   ← App écrit les commandes ici, ESP les lit
 *
 * Dependencies: ArduinoJson v6, WiFiManager, ESP8266HTTPClient
 */

#include <ESP8266WiFi.h>
#include <ESP8266WebServer.h>
#include <ESP8266mDNS.h>
#include <ESP8266HTTPClient.h>
#include <WiFiClientSecureBearSSL.h>
#include <WiFiManager.h>
#include <ArduinoJson.h>
#include <LittleFS.h>
#include "config.h"

// -----------------------------------------------------------------------
// Firebase
// -----------------------------------------------------------------------
#define FIREBASE_HOST "blight-28253-default-rtdb.europe-west1.firebasedatabase.app"
#define FIREBASE_URL  "https://" FIREBASE_HOST
#define FB_STATUS_PATH  "/blight/status.json"
#define FB_COMMANDS_PATH "/blight/commands.json"

// Intervalles Firebase
#define FB_PUSH_INTERVAL_MS   10000UL   // Publier état toutes les 10s
#define FB_POLL_INTERVAL_MS    3000UL   // Lire commandes toutes les 3s

unsigned long lastFbPush = 0;
unsigned long lastFbPoll = 0;

// -----------------------------------------------------------------------
// Reste du firmware inchangé
// -----------------------------------------------------------------------
#define STATE_FILE "/state.json"

ESP8266WebServer server(80);

enum LDRState { ST_JOUR, ST_DEBUT_NUIT, ST_NUIT, ST_DEBUT_JOUR };
LDRState currentState = ST_JOUR;
unsigned long stateTimer = 0;
int lastLdrValue = 0;
unsigned long lastLdrSample = 0;

bool relayStates[NUM_RELAYS] = {false};
bool relayAutoModes[NUM_RELAYS] = {true, true, true, true};

int seuilNuit = DEFAULT_SEUIL_NUIT;
int seuilJour = DEFAULT_SEUIL_JOUR;

bool wifiConnected = false;
unsigned long lastWifiCheck = 0;

// -----------------------------------------------------------------------
// SETUP
// -----------------------------------------------------------------------
void setup() {
  Serial.begin(115200);
  Serial.println("\n--- BLight V1.1.0 (Firebase) ---");

  for (int i = 0; i < NUM_RELAYS; i++) {
    pinMode(RELAY_PINS[i], OUTPUT);
    digitalWrite(RELAY_PINS[i], HIGH);
  }

  if (!LittleFS.begin()) {
    LittleFS.format();
    LittleFS.begin();
  }
  loadState();
  setupWiFi();
  setupServer();

  if (wifiConnected) {
    MDNS.begin("blight");
    MDNS.addService("http", "tcp", 80);
    Serial.println("mDNS: blight.local");
    // Push initial vers Firebase
    pushStatusToFirebase();
  }
}

// -----------------------------------------------------------------------
// LOOP
// -----------------------------------------------------------------------
void loop() {
  server.handleClient();
  if (wifiConnected) MDNS.update();

  unsigned long now = millis();

  // WiFi monitor
  if (now - lastWifiCheck >= WIFI_RECONNECT_MS) {
    lastWifiCheck = now;
    if (WiFi.status() != WL_CONNECTED) {
      if (wifiConnected) Serial.println("WiFi Disconnected");
      wifiConnected = false;
      WiFi.reconnect();
    } else {
      if (!wifiConnected) {
        wifiConnected = true;
        MDNS.end();
        if (MDNS.begin("blight")) {
          MDNS.addService("http", "tcp", 80);
        }
        Serial.println("WiFi Reconnected: " + WiFi.localIP().toString());
        pushStatusToFirebase(); // Push immédiat après reconnexion
      }
    }
  }

  // LDR sampling
  if (now - lastLdrSample >= LDR_SAMPLE_MS) {
    lastLdrSample = now;
    lastLdrValue = analogRead(LDR_PIN);
    updateFSM(lastLdrValue, now);
  }

  // Firebase : lire les commandes
  if (wifiConnected && now - lastFbPoll >= FB_POLL_INTERVAL_MS) {
    lastFbPoll = now;
    pollFirebaseCommands();
  }

  // Firebase : publier l'état
  if (wifiConnected && now - lastFbPush >= FB_PUSH_INTERVAL_MS) {
    lastFbPush = now;
    pushStatusToFirebase();
  }

  yield();
}

// -----------------------------------------------------------------------
// FIREBASE — Publier l'état
// -----------------------------------------------------------------------
void pushStatusToFirebase() {
  if (!wifiConnected) return;

  BearSSL::WiFiClientSecure client;
  client.setInsecure(); // Pas de vérification certificat (OK pour IoT local)

  HTTPClient https;
  if (!https.begin(client, FIREBASE_URL FB_STATUS_PATH)) return;

  https.addHeader("Content-Type", "application/json");

  // Construire le JSON d'état
  StaticJsonDocument<512> doc;
  doc["app"]          = "BLight V1.1.0";
  doc["etat_ldr"]     = getLDRStateString(currentState);
  doc["ldr_value"]    = lastLdrValue;
  doc["seuil_nuit"]   = seuilNuit;
  doc["seuil_jour"]   = seuilJour;
  doc["ip"]           = WiFi.localIP().toString();
  doc["updated_at"]   = millis();

  JsonArray relays = doc.createNestedArray("relays");
  JsonArray modes  = doc.createNestedArray("relay_modes");
  for (int i = 0; i < NUM_RELAYS; i++) {
    relays.add(relayStates[i]);
    modes.add(relayAutoModes[i]);
  }

  String body;
  serializeJson(doc, body);

  int code = https.PUT(body);
  if (code == 200) {
    Serial.println("Firebase: Status pushed OK");
  } else {
    Serial.println("Firebase: Push failed " + String(code));
  }
  https.end();
}

// -----------------------------------------------------------------------
// FIREBASE — Lire et exécuter les commandes
// -----------------------------------------------------------------------
void pollFirebaseCommands() {
  if (!wifiConnected) return;

  BearSSL::WiFiClientSecure client;
  client.setInsecure();

  HTTPClient https;
  if (!https.begin(client, FIREBASE_URL FB_COMMANDS_PATH)) return;

  int code = https.GET();
  if (code != 200) {
    https.end();
    return;
  }

  String payload = https.getString();
  https.end();

  if (payload == "null" || payload.isEmpty()) return;

  StaticJsonDocument<512> doc;
  DeserializationError err = deserializeJson(doc, payload);
  if (err) return;

  bool changed = false;

  // Traiter commandes relais (relay_0 à relay_3)
  for (int i = 0; i < NUM_RELAYS; i++) {
    String key = "relay_" + String(i);
    if (doc.containsKey(key)) {
      JsonObject cmd = doc[key];
      bool done = cmd["done"] | true;
      if (!done) {
        bool newState = cmd["state"] | relayStates[i];
        relayStates[i]    = newState;
        relayAutoModes[i] = false;
        setRelay(i, newState);
        Serial.println("Firebase cmd: relay_" + String(i) + " -> " + String(newState ? "ON" : "OFF"));
        changed = true;

        // Marquer comme traité
        markCommandDone(key);
      }
    }
  }

  // Traiter commandes mode (mode_0 à mode_3)
  for (int i = 0; i < NUM_RELAYS; i++) {
    String key = "mode_" + String(i);
    if (doc.containsKey(key)) {
      JsonObject cmd = doc[key];
      bool done = cmd["done"] | true;
      if (!done) {
        bool autoMode = cmd["auto"] | false;
        relayAutoModes[i] = autoMode;
        if (autoMode) {
          bool shouldBeOn = isNightState(currentState);
          relayStates[i] = shouldBeOn;
          setRelay(i, shouldBeOn);
        }
        Serial.println("Firebase cmd: mode_" + String(i) + " -> " + String(autoMode ? "Auto" : "Manuel"));
        changed = true;
        markCommandDone(key);
      }
    }
  }

  // Traiter commande seuils
  if (doc.containsKey("thresholds")) {
    JsonObject cmd = doc["thresholds"];
    bool done = cmd["done"] | true;
    if (!done) {
      int n = cmd["seuil_nuit"] | seuilNuit;
      int j = cmd["seuil_jour"] | seuilJour;
      if (n >= 0 && j <= 1023 && n < j) {
        seuilNuit = n;
        seuilJour = j;
        Serial.println("Firebase cmd: thresholds nuit=" + String(n) + " jour=" + String(j));
      }
      changed = true;
      markCommandDone("thresholds");
    }
  }

  if (changed) {
    saveState();
    pushStatusToFirebase(); // Push immédiat après exécution
  }
}

// Marque une commande comme traitée (done: true)
void markCommandDone(String key) {
  BearSSL::WiFiClientSecure client;
  client.setInsecure();

  HTTPClient https;
  String url = String(FIREBASE_URL) + "/blight/commands/" + key + ".json";
  if (!https.begin(client, url)) return;

  https.addHeader("Content-Type", "application/json");
  https.PATCH("{\"done\":true}");
  https.end();
}

// -----------------------------------------------------------------------
// WiFi
// -----------------------------------------------------------------------
void setupWiFi() {
  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(true);
  WiFi.persistent(true);

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

  Serial.println("WiFi: Starting captive portal...");
  WiFiManager wm;
  wm.setConfigPortalTimeout(180);
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

// -----------------------------------------------------------------------
// HTTP API locale (inchangée)
// -----------------------------------------------------------------------
void setupServer() {
  server.on("/api/status",       HTTP_GET,     handleStatus);
  server.on("/api/relay/toggle", HTTP_POST,    handleToggle);
  server.on("/api/relay/set",    HTTP_POST,    handleSet);
  server.on("/api/mode",         HTTP_POST,    handleMode);
  server.on("/api/thresholds",   HTTP_POST,    handleThresholds);
  server.on("/api/wifi/reset",   HTTP_POST,    handleWifiReset);
  server.on("/api/status",       HTTP_OPTIONS, corsOK);
  server.on("/api/relay/toggle", HTTP_OPTIONS, corsOK);
  server.on("/api/relay/set",    HTTP_OPTIONS, corsOK);
  server.on("/api/mode",         HTTP_OPTIONS, corsOK);
  server.on("/api/thresholds",   HTTP_OPTIONS, corsOK);
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

void handleStatus() {
  StaticJsonDocument<768> doc;
  doc["app"]            = "BLight V1.1.0";
  doc["etat_ldr"]       = getLDRStateString(currentState);
  doc["valeur_ldr"]     = lastLdrValue;
  doc["seuil_nuit"]     = seuilNuit;
  doc["seuil_jour"]     = seuilJour;
  doc["wifi_connected"] = wifiConnected;
  doc["ip"]             = WiFi.localIP().toString();

  JsonArray relays = doc.createNestedArray("relays");
  JsonArray modes  = doc.createNestedArray("relay_modes");
  for (int i = 0; i < NUM_RELAYS; i++) {
    relays.add(relayStates[i]);
    modes.add(relayAutoModes[i]);
  }

  String out;
  serializeJson(doc, out);
  sendJSON(200, out);
}

void handleSet() {
  StaticJsonDocument<64> doc;
  if (deserializeJson(doc, readBody())) { sendJSON(400, "{\"error\":\"Invalid JSON\"}"); return; }
  int idx = doc["index"] | -1;
  if (idx < 0 || idx >= NUM_RELAYS) { sendJSON(400, "{\"error\":\"Invalid index\"}"); return; }
  if (!doc.containsKey("state")) { sendJSON(400, "{\"error\":\"Missing state\"}"); return; }
  bool newState = doc["state"].as<bool>();
  relayStates[idx] = newState;
  relayAutoModes[idx] = false;
  setRelay(idx, newState);
  saveState();
  pushStatusToFirebase();
  String resp = "{\"status\":\"ok\",\"index\":" + String(idx) + ",\"state\":" + String(newState ? "true" : "false") + "}";
  sendJSON(200, resp);
}

void handleToggle() {
  StaticJsonDocument<64> doc;
  if (deserializeJson(doc, readBody())) { sendJSON(400, "{\"error\":\"Invalid JSON\"}"); return; }
  int idx = doc["index"] | -1;
  if (idx < 0 || idx >= NUM_RELAYS) { sendJSON(400, "{\"error\":\"Invalid index\"}"); return; }
  relayStates[idx] = !relayStates[idx];
  relayAutoModes[idx] = false;
  setRelay(idx, relayStates[idx]);
  saveState();
  pushStatusToFirebase(); // Synchroniser Firebase après action locale
  sendJSON(200, "{\"status\":\"ok\"}");
}

void handleMode() {
  StaticJsonDocument<64> doc;
  if (deserializeJson(doc, readBody())) { sendJSON(400, "{\"error\":\"Invalid JSON\"}"); return; }
  int idx = doc["index"] | -1;
  if (idx < 0 || idx >= NUM_RELAYS) { sendJSON(400, "{\"error\":\"Invalid index\"}"); return; }
  bool autoMode = doc["auto"] | false;
  relayAutoModes[idx] = autoMode;
  if (autoMode) {
    bool shouldBeOn = isNightState(currentState);
    relayStates[idx] = shouldBeOn;
    setRelay(idx, shouldBeOn);
  }
  saveState();
  pushStatusToFirebase();
  sendJSON(200, "{\"status\":\"ok\"}");
}

void handleThresholds() {
  StaticJsonDocument<128> doc;
  if (deserializeJson(doc, readBody())) { sendJSON(400, "{\"error\":\"Invalid JSON\"}"); return; }
  int n = doc["seuil_nuit"] | -1;
  int j = doc["seuil_jour"] | -1;
  if (n < 0 || n > 1023 || j < 0 || j > 1023 || n >= j) { sendJSON(400, "{\"error\":\"Invalid values\"}"); return; }
  seuilNuit = n; seuilJour = j;
  saveState();
  pushStatusToFirebase();
  sendJSON(200, "{\"status\":\"ok\"}");
}

void handleWifiReset() {
  sendJSON(200, "{\"status\":\"resetting\"}");
  delay(500);
  WiFi.disconnect(true);
  ESP.restart();
}

// -----------------------------------------------------------------------
// Persistence
// -----------------------------------------------------------------------
void saveState() {
  File f = LittleFS.open(STATE_FILE, "w");
  if (!f) return;
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
}

void loadState() {
  if (!LittleFS.exists(STATE_FILE)) return;
  File f = LittleFS.open(STATE_FILE, "r");
  if (!f) return;
  StaticJsonDocument<256> doc;
  if (deserializeJson(doc, f)) { f.close(); return; }
  f.close();
  seuilNuit = doc["seuil_nuit"] | DEFAULT_SEUIL_NUIT;
  seuilJour = doc["seuil_jour"] | DEFAULT_SEUIL_JOUR;
  if (seuilNuit >= seuilJour) { seuilNuit = DEFAULT_SEUIL_NUIT; seuilJour = DEFAULT_SEUIL_JOUR; }
  JsonArray states = doc["relay_states"];
  JsonArray modes  = doc["relay_modes"];
  for (int i = 0; i < NUM_RELAYS; i++) {
    if (i < (int)states.size()) relayStates[i]    = states[i].as<bool>();
    if (i < (int)modes.size())  relayAutoModes[i] = modes[i].as<bool>();
    setRelay(i, relayStates[i]);
  }
  Serial.println("LittleFS: State loaded");
}

// -----------------------------------------------------------------------
// Relay + LDR (inchangés)
// -----------------------------------------------------------------------
void setRelay(int idx, bool on) {
  digitalWrite(RELAY_PINS[idx], on ? LOW : HIGH);
}

String getLDRStateString(LDRState s) {
  switch (s) {
    case ST_JOUR:       return "JOUR";
    case ST_DEBUT_NUIT: return "DEBUT_NUIT";
    case ST_NUIT:       return "NUIT";
    case ST_DEBUT_JOUR: return "DEBUT_JOUR";
    default:            return "JOUR";
  }
}

bool isNightState(LDRState s) { return (s == ST_NUIT); }

void updateFSM(int ldr, unsigned long now) {
  switch (currentState) {
    case ST_JOUR:
      if (ldr <= seuilNuit) { currentState = ST_DEBUT_NUIT; stateTimer = now; }
      break;
    case ST_DEBUT_NUIT:
      if (ldr > seuilNuit) { currentState = ST_JOUR; }
      else if (now - stateTimer >= DELAI_NUIT_MS) {
        currentState = ST_NUIT;
        for (int i = 0; i < NUM_RELAYS; i++)
          if (relayAutoModes[i]) { relayStates[i] = true; setRelay(i, true); }
        pushStatusToFirebase();
      }
      break;
    case ST_NUIT:
      if (ldr >= seuilJour) { currentState = ST_DEBUT_JOUR; stateTimer = now; }
      break;
    case ST_DEBUT_JOUR:
      if (ldr < seuilJour) { currentState = ST_NUIT; }
      else if (now - stateTimer >= DELAI_JOUR_MS) {
        currentState = ST_JOUR;
        for (int i = 0; i < NUM_RELAYS; i++)
          if (relayAutoModes[i]) { relayStates[i] = false; setRelay(i, false); }
        pushStatusToFirebase();
      }
      break;
  }
}
