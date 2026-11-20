#pragma once
#include <Arduino.h>

#include "config.h"
#include "protocol.h"

// État global partagé entre les modules (modifié uniquement depuis loop(),
// sauf les champs marqués volatile qui sont écrits par la pile BLE).
struct AppState {
  bool scanning = true;
  bool eco = false;
  bool timeValid = false;
  bool nrfOk = false;

  volatile bool linkConnected = false;
  volatile bool linkSecure = false;
  volatile bool linkSubscribed = false;
  volatile uint32_t passkey = 0;  // affiché à l'écran pendant l'appairage

  bool beaconOn = false;
  char beaconMsg[proto::BEACON_MAX + 1] = {0};
  bool apOn = false;
  char apSsid[33] = {0};
  uint8_t apChannel = 6;
  uint8_t apClients = 0;

  uint32_t wifiSeen = 0;  // nouveaux identifiants depuis le démarrage
  uint32_t bleSeen = 0;
  uint16_t wifiLastScan = 0;  // réseaux du dernier scan

  uint8_t spectrum[proto::NRF_CHANNELS] = {0};
  uint32_t spectrumAt = 0;
};
extern AppState g;

uint32_t nowUnix();  // 0 si l'heure n'est pas connue
void applyUnixTime(uint32_t t);

namespace Dedup {
constexpr uint8_t KIND_WIFI = 1, KIND_BLE = 2;
// true si l'enregistrement doit être transmis ; isNew = jamais vu (ou oublié)
bool check(uint8_t kind, const uint8_t addr[6], int8_t rssi, bool& isNew);
uint16_t countRecent(uint8_t kind, uint32_t windowMs);
}  // namespace Dedup

namespace Store {
void begin();
void push(const uint8_t* rec, size_t len);
void service();
void purge();
uint32_t backlogBytes();
}  // namespace Store

namespace Link {
void begin();
void service();
bool canSend();
bool sendPacket(const uint8_t* data, size_t len);
size_t maxPayload();
void refreshAdvertising();
}  // namespace Link

namespace WifiScan {
void begin();
void service();
bool busy();
bool ssidNearby(const char* ssid);  // SSID présent dans les derniers scans
}  // namespace WifiScan

namespace BleScan {
void begin();
void service();
void pause();
void resume();
}  // namespace BleScan

namespace Nrf {
bool begin();
void service();
}  // namespace Nrf

namespace Emit {
void setBeacon(bool on, const char* msg);
void requestAp(bool on, const char* ssid, const char* pass, uint8_t channel);
void service();
}  // namespace Emit

namespace UI {
void begin();
void service();
void wake();
void nextPage();
bool isDimmed();
void toast(const char* msg);  // message temporaire en bas de l'écran
}  // namespace UI
