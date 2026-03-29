# BLight - Domotique Intelligente

## Firmware ESP8266
- `blight_firmware/blight_firmware.ino` - Code principal
- `blight_firmware/config.h` - Configuration (pins, seuils, WiFi)

## Application Mobile Flutter
- `mobile_app/` - Application de contrôle

## Dépendances
- ArduinoJson v6
- WiFiManager

## Flash
```bash
arduino-cli compile --fqbn esp8266:esp8266:d1_mini blight_firmware/
arduino-cli upload -p /dev/ttyUSB0 --fqbn esp8266:esp8266:d1_mini blight_firmware/
```

## API Endpoints
| Endpoint | Méthode | Description |
|---|---|---|
| `/api/status` | GET | État complet (JSON) |
| `/api/relay/toggle` | POST | Bascule un relais |
| `/api/mode` | POST | Mode auto/manuel |
| `/api/thresholds` | POST | Seuils LDR |
| `/api/wifi/reset` | POST | Reset WiFi |
