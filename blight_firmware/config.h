#pragma once

#define AP_SSID      "SmartLight_AP"
#define AP_PASSWORD  "smartlight123"

#define STA_SSID     ""
#define STA_PASSWORD ""

#define NUM_RELAYS 6
const uint8_t RELAY_PINS[NUM_RELAYS] = {5, 4, 14, 12, 13, 16};

#define LDR_PIN A0

#define DEFAULT_SEUIL_NUIT  300
#define DEFAULT_SEUIL_JOUR  700

#define DELAI_NUIT_MS       5000UL
#define DELAI_JOUR_MS       5000UL

#define LDR_SAMPLE_MS        200UL
#define WIFI_RECONNECT_MS  30000UL
