#pragma once
// ---------------------------------------------------------------------------
// Seul fichier à modifier. Les broches NRF24 viennent de tools/nrf_probe.
// ---------------------------------------------------------------------------

// NRF24L01 (analyseur de spectre 2,4 GHz passif). Mettre NRF_ENABLED à 0 pour l'ignorer.
#define NRF_ENABLED 1
// Câblage détecté par tools/nrf_probe (CE confirmé). G25 partage son plot avec G36.
#define NRF_PIN_SCK 0
#define NRF_PIN_MOSI 32
#define NRF_PIN_MISO 33
#define NRF_PIN_CSN 26
#define NRF_PIN_CE 25

#define DEVICE_NAME "M5Radar"

// Wi-Fi : scan asynchrone. Passif = on écoute les beacons sans envoyer de probe request.
#define WIFI_SCAN_INTERVAL_MS 10000
#define WIFI_SCAN_INTERVAL_ECO_MS 30000
#define WIFI_PASSIVE_SCAN true
#define WIFI_SCAN_MS_PER_CHAN 150

// BLE : scan actif = demande la "scan response" (souvent le nom de l'appareil),
// comme le fait n'importe quel téléphone. Mettre false pour un scan 100 % passif.
#define BLE_ACTIVE_SCAN true

// NRF24 : un balayage des 126 canaux toutes les X ms, un rapport toutes les Y ms.
#define NRF_SWEEP_PERIOD_MS 60
#define NRF_REPORT_MS 2000
#define NRF_REPORT_ECO_MS 10000
#define NRF_DWELL_US 170

// Dédoublonnage : on ne renvoie un appareil déjà vu que si son RSSI change
// d'au moins RSSI_DELTA dB ou toutes les SEEN_REFRESH_MS.
#define RSSI_DELTA 6
#define SEEN_REFRESH_MS 60000

// Tampon hors ligne (LittleFS, partition de ~4,9 Mo).
#define BACKLOG_MAX_BYTES (4500UL * 1024UL)

// Écran : extinction progressive après inactivité.
#define SCREEN_DIM_MS 30000

// Fuseau horaire pour l'affichage (heure de Paris).
#define TZ_INFO "CET-1CEST,M3.5.0,M10.5.0/3"
