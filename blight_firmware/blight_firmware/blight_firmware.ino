/**
 * BLight V1.3.0 - Firebase REST HTTP (Sans Stream SSL)
 * Target: Wemos D1 Mini (ESP8266)
 *
 * Pourquoi ce changement :
 * L'ESP8266 ne peut pas maintenir deux connexions SSL simultanées
 * (stream + écriture) — heap insuffisant (~50KB libre seulement).
 * Solution : poll HTTP toutes les 1s avec UNE seule connexion,
 * réutilisée via keep-alive. Délai réel < 2s, stable à 100%.
 *
 * Bibliothèques requises :
 *   - ArduinoJson  by Benoit Blanchon (v6.x)
 *   - WiFiManager  by tzapu  (v2.x)
 *   (Firebase ESP8266 Client n'est plus nécessaire)
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

// ============================================================
// Firebase REST
// ============================================================
#define FIREBASE_HOST  "blight-28253-default-rtdb.europe-west1.firebasedatabase.app"
#define FIREBASE_BASE  "https://" FIREBASE_HOST

#define FB_STATUS_PATH   "/blight/status.json"
#define FB_COMMANDS_PATH "/blight/commands.json"

// Intervalles
#define FB_POLL_MS   500UL   // Poll commandes toutes les 0.5s
#define FB_PUSH_MS  5000UL   // Push état toutes les 5s

unsigned long lastFbPoll = 0;
unsigned long lastFbPush = 0;

// Client SSL réutilisable (keep-alive)
BearSSL::WiFiClientSecure sslClient;

// ============================================================
// Persistence
// ============================================================
#define STATE_FILE "/state.json"

// ============================================================
// HTTP Server local
// ============================================================
ESP8266WebServer server(80);

// ============================================================
// LDR FSM
// ============================================================
enum LDRState { ST_JOUR, ST_DEBUT_NUIT, ST_NUIT, ST_DEBUT_JOUR };
LDRState      currentState  = ST_JOUR;
unsigned long stateTimer    = 0;
int           lastLdrValue  = 0;
unsigned long lastLdrSample = 0;

// ============================================================
// État relais
// ============================================================
bool relayStates[NUM_RELAYS]    = {false};
bool relayAutoModes[NUM_RELAYS] = {true, true, true, true};
int  seuilNuit = DEFAULT_SEUIL_NUIT;
int  seuilJour = DEFAULT_SEUIL_JOUR;

// ============================================================
// WiFi
// ============================================================
bool          wifiConnected = false;
unsigned long lastWifiCheck = 0;

// ============================================================
// Prototypes
// ============================================================
void setupWiFi();
void setupServer();
void saveState();
void loadState();
void setRelay(int idx, bool on);
String getLDRStateString(LDRState s);
bool isNightState(LDRState s);
void updateFSM(int ldr, unsigned long now);
bool fbGET(const String& path, String& response);
bool fbPUT(const String& path, const String& body);
bool fbPATCH(const String& path, const String& body);
void pollFirebaseCommands();
void pushStatusToFirebase();

// ============================================================
// SETUP
// ============================================================
void setup() {
  Serial.begin(115200);
  Serial.println("\n--- BLight V1.3.0 (Firebase REST) ---");

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

    // SSL : désactiver vérification certificat (OK pour IoT)
    sslClient.setInsecure();

    pushStatusToFirebase();
  }
}

// ============================================================
// LOOP
// ============================================================
void loop() {
  server.handleClient();
  if (wifiConnected) MDNS.update();

  unsigned long now = millis();

  // WiFi monitor
  if (now - lastWifiCheck >= WIFI_RECONNECT_MS) {
    lastWifiCheck = now;
    if (WiFi.status() != WL_CONNECTED) {
      if (wifiConnected) {
        wifiConnected = false;
        Serial.println("WiFi: Disconnected");
      }
      WiFi.reconnect();
    } else if (!wifiConnected) {
      wifiConnected = true;
      Serial.println("WiFi: Reconnected → " + WiFi.localIP().toString());
      MDNS.end();
      if (MDNS.begin("blight")) MDNS.addService("http", "tcp", 80);
      sslClient.setInsecure();
      pushStatusToFirebase();
    }
  }

  // LDR
  if (now - lastLdrSample >= LDR_SAMPLE_MS) {
    lastLdrSample = now;
    lastLdrValue  = analogRead(LDR_PIN);
    updateFSM(lastLdrValue, now);
  }

  // Poll Firebase commandes (1s)
  if (wifiConnected && now - lastFbPoll >= FB_POLL_MS) {
    lastFbPoll = now;
    pollFirebaseCommands();
  }

  // Push Firebase état (10s)
  if (wifiConnected && now - lastFbPush >= FB_PUSH_MS) {
    lastFbPush = now;
    pushStatusToFirebase();
  }

  yield();
}

// ============================================================
// FIREBASE HTTP HELPERS — une seule connexion réutilisée
// ============================================================
bool fbGET(const String& path, String& response) {
  HTTPClient https;
  if (!https.begin(sslClient, FIREBASE_BASE + path)) return false;
  https.setTimeout(2000);

  int code = https.GET();
  if (code == 200) {
    response = https.getString();
    https.end();
    return true;
  }
  https.end();
  return false;
}

bool fbPUT(const String& path, const String& body) {
  HTTPClient https;
  if (!https.begin(sslClient, FIREBASE_BASE + path)) return false;
  https.setTimeout(2000);
  https.addHeader("Content-Type", "application/json");

  int code = https.PUT(body);
  https.end();
  return code == 200;
}

bool fbPATCH(const String& path, const String& body) {
  HTTPClient https;
  if (!https.begin(sslClient, FIREBASE_BASE + path)) return false;
  https.setTimeout(2000);
  https.addHeader("Content-Type", "application/json");
  https.addHeader("X-HTTP-Method-Override", "PATCH");

  int code = https.POST(body);
  https.end();
  return code == 200;
}

// ============================================================
// POLL COMMANDES FIREBASE
// ============================================================
void pollFirebaseCommands() {
  String response;
  if (!fbGET(FB_COMMANDS_PATH, response)) return;
  if (response == "null" || response.isEmpty()) return;

  StaticJsonDocument<512> doc;
  if (deserializeJson(doc, response)) return;

  bool changed = false;

  // Commandes relais
  for (int i = 0; i < NUM_RELAYS; i++) {
    String key = "relay_" + String(i);
    if (!doc.containsKey(key)) continue;

    JsonObject cmd  = doc[key];
    bool done       = cmd["done"] | true;
    if (done) continue;

    bool newState       = cmd["state"] | relayStates[i];
    relayStates[i]      = newState;
    relayAutoModes[i]   = false;
    setRelay(i, newState);
    Serial.println("FB CMD " + key + " → " + String(newState ? "ON" : "OFF"));

    // Marquer done
    fbPATCH("/blight/commands/" + key + ".json", "{\"done\":true}");
    changed = true;
  }

  // Commandes mode
  for (int i = 0; i < NUM_RELAYS; i++) {
    String key = "mode_" + String(i);
    if (!doc.containsKey(key)) continue;

    JsonObject cmd = doc[key];
    bool done      = cmd["done"] | true;
    if (done) continue;

    bool autoMode     = cmd["auto"] | false;
    relayAutoModes[i] = autoMode;
    if (autoMode) {
      bool on = isNightState(currentState);
      relayStates[i] = on;
      setRelay(i, on);
    }
    Serial.println("FB CMD " + key + " → " + String(autoMode ? "Auto" : "Manuel"));
    fbPATCH("/blight/commands/" + key + ".json", "{\"done\":true}");
    changed = true;
  }

  // Commande seuils
  if (doc.containsKey("thresholds")) {
    JsonObject cmd = doc["thresholds"];
    bool done      = cmd["done"] | true;
    if (!done) {
      int n = cmd["seuil_nuit"] | seuilNuit;
      int j = cmd["seuil_jour"] | seuilJour;
      if (n >= 0 && j <= 1023 && n < j) {
        seuilNuit = n; seuilJour = j;
        Serial.println("FB CMD thresholds nuit=" + String(n) + " jour=" + String(j));
      }
      fbPATCH("/blight/commands/thresholds.json", "{\"done\":true}");
      changed = true;
    }
  }

  if (changed) {
    saveState();
    pushStatusToFirebase();
  }
}

// ============================================================
// PUSH ÉTAT FIREBASE
// ============================================================
void pushStatusToFirebase() {
  StaticJsonDocument<512> doc;
  doc["app"]        = "BLight V1.3.0";
  doc["etat_ldr"]   = getLDRStateString(currentState);
  doc["ldr_value"]  = lastLdrValue;
  doc["seuil_nuit"] = seuilNuit;
  doc["seuil_jour"] = seuilJour;
  doc["ip"]         = WiFi.localIP().toString();
  doc["updated_at"] = (int)millis();

  JsonArray relays = doc.createNestedArray("relays");
  JsonArray modes  = doc.createNestedArray("relay_modes");
  for (int i = 0; i < NUM_RELAYS; i++) {
    relays.add(relayStates[i]);
    modes.add(relayAutoModes[i]);
  }

  String body;
  serializeJson(doc, body);

  if (fbPUT(FB_STATUS_PATH, body)) {
    Serial.println("Firebase: Status OK");
    lastFbPush = millis();
  } else {
    Serial.println("Firebase: Push failed");
  }
}

// ============================================================
// WiFi
// ============================================================
void setupWiFi() {
  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(true);
  WiFi.persistent(true);

  if (WiFi.SSID().length() > 0) {
    Serial.println("WiFi: Connecting to " + WiFi.SSID() + "...");
    WiFi.begin();
    unsigned long start = millis();
    while (WiFi.status() != WL_CONNECTED && millis() - start < 15000) {
      delay(500); Serial.print(".");
    }
    Serial.println();
  }

  if (WiFi.status() == WL_CONNECTED) {
    wifiConnected = true;
    Serial.println("WiFi: Connected → " + WiFi.localIP().toString());
    return;
  }

  WiFiManager wm;
  wm.setConfigPortalTimeout(180);
  wm.setAPStaticIPConfig(
    IPAddress(192,168,4,1), IPAddress(192,168,4,1),
    IPAddress(255,255,255,0));

  if (wm.autoConnect(AP_SSID, AP_PASSWORD)) {
    wifiConnected = true;
    delay(1000);
    Serial.println("WiFi: Portal → " + WiFi.localIP().toString());
  } else {
    wifiConnected = false;
    Serial.println("WiFi: Offline.");
  }
}

// ============================================================
// HTTP API locale (inchangée)
// ============================================================
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
  Serial.println("HTTP: Server started");
}

void corsOK() {
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.sendHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  server.sendHeader("Access-Control-Allow-Headers", "Content-Type");
  server.send(204);
}

void sendJSON(int code, const String& body) {
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.send(code, "application/json", body);
}

String readBody() {
  return server.hasArg("plain") ? server.arg("plain") : "";
}

void handleStatus() {
  StaticJsonDocument<768> doc;
  doc["app"]            = "BLight V1.3.0";
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
  String out; serializeJson(doc, out);
  sendJSON(200, out);
}

void handleSet() {
  StaticJsonDocument<64> doc;
  if (deserializeJson(doc, readBody())) {
    sendJSON(400, "{\"error\":\"JSON\"}"); return;
  }
  int idx = doc["index"] | -1;
  if (idx < 0 || idx >= NUM_RELAYS) {
    sendJSON(400, "{\"error\":\"index\"}"); return;
  }
  if (!doc.containsKey("state")) {
    sendJSON(400, "{\"error\":\"state\"}"); return;
  }
  relayStates[idx]    = doc["state"].as<bool>();
  relayAutoModes[idx] = false;
  setRelay(idx, relayStates[idx]);
  saveState(); pushStatusToFirebase();
  sendJSON(200, "{\"status\":\"ok\",\"index\":" + String(idx) +
    ",\"state\":" + String(relayStates[idx] ? "true" : "false") + "}");
}

void handleToggle() {
  StaticJsonDocument<64> doc;
  if (deserializeJson(doc, readBody())) {
    sendJSON(400, "{\"error\":\"JSON\"}"); return;
  }
  int idx = doc["index"] | -1;
  if (idx < 0 || idx >= NUM_RELAYS) {
    sendJSON(400, "{\"error\":\"index\"}"); return;
  }
  relayStates[idx]    = !relayStates[idx];
  relayAutoModes[idx] = false;
  setRelay(idx, relayStates[idx]);
  saveState(); pushStatusToFirebase();
  sendJSON(200, "{\"status\":\"ok\"}");
}

void handleMode() {
  StaticJsonDocument<64> doc;
  if (deserializeJson(doc, readBody())) {
    sendJSON(400, "{\"error\":\"JSON\"}"); return;
  }
  int idx = doc["index"] | -1;
  if (idx < 0 || idx >= NUM_RELAYS) {
    sendJSON(400, "{\"error\":\"index\"}"); return;
  }
  bool autoMode       = doc["auto"] | false;
  relayAutoModes[idx] = autoMode;
  if (autoMode) {
    bool on = isNightState(currentState);
    relayStates[idx] = on; setRelay(idx, on);
  }
  saveState(); pushStatusToFirebase();
  sendJSON(200, "{\"status\":\"ok\"}");
}

void handleThresholds() {
  StaticJsonDocument<128> doc;
  if (deserializeJson(doc, readBody())) {
    sendJSON(400, "{\"error\":\"JSON\"}"); return;
  }
  int n = doc["seuil_nuit"] | -1;
  int j = doc["seuil_jour"] | -1;
  if (n < 0 || j > 1023 || n >= j) {
    sendJSON(400, "{\"error\":\"values\"}"); return;
  }
  seuilNuit = n; seuilJour = j;
  saveState(); pushStatusToFirebase();
  sendJSON(200, "{\"status\":\"ok\"}");
}

void handleWifiReset() {
  sendJSON(200, "{\"status\":\"resetting\"}");
  delay(500); WiFi.disconnect(true); ESP.restart();
}

// ============================================================
// Persistence LittleFS
// ============================================================
void saveState() {
  File f = LittleFS.open(STATE_FILE, "w");
  if (!f) return;
  StaticJsonDocument<256> doc;
  JsonArray st = doc.createNestedArray("relay_states");
  JsonArray mo = doc.createNestedArray("relay_modes");
  for (int i = 0; i < NUM_RELAYS; i++) {
    st.add(relayStates[i]); mo.add(relayAutoModes[i]);
  }
  doc["seuil_nuit"] = seuilNuit;
  doc["seuil_jour"] = seuilJour;
  serializeJson(doc, f); f.close();
}

void loadState() {
  if (!LittleFS.exists(STATE_FILE)) return;
  File f = LittleFS.open(STATE_FILE, "r");
  if (!f) return;
  StaticJsonDocument<256> doc;
  if (deserializeJson(doc, f)) {
    f.close(); LittleFS.remove(STATE_FILE); return;
  }
  f.close();
  seuilNuit = doc["seuil_nuit"] | DEFAULT_SEUIL_NUIT;
  seuilJour = doc["seuil_jour"] | DEFAULT_SEUIL_JOUR;
  if (seuilNuit >= seuilJour) {
    seuilNuit = DEFAULT_SEUIL_NUIT; seuilJour = DEFAULT_SEUIL_JOUR;
  }
  JsonArray st = doc["relay_states"];
  JsonArray mo = doc["relay_modes"];
  for (int i = 0; i < NUM_RELAYS; i++) {
    if (i < (int)st.size()) relayStates[i]    = st[i].as<bool>();
    if (i < (int)mo.size()) relayAutoModes[i] = mo[i].as<bool>();
    setRelay(i, relayStates[i]);
  }
  Serial.println("LittleFS: State loaded");
}

// ============================================================
// Relay + LDR FSM
// ============================================================
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
