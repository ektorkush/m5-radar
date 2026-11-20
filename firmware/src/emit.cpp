// Émissions volontaires, toujours désactivées au démarrage :
//  - balise BLE : un message court diffusé comme nom de l'annonce (voir Link) ;
//  - AP de test : un point d'accès Wi-Fi visible, sans portail ni serveur web.
// Garde-fou : un AP ne peut pas reprendre le nom d'un réseau vu à proximité
// (ce serait un « jumeau maléfique »).
#include <WiFi.h>

#include "app.h"

namespace Emit {
namespace {
struct ApRequest {
  bool pending = false;
  bool on = false;
  char ssid[33] = {0};
  char pass[64] = {0};
  uint8_t channel = 6;
} req;
uint32_t lastClientPoll = 0;

void applyAp() {
  req.pending = false;
  if (req.on) {
    WiFi.mode(WIFI_AP_STA);
    bool ok = WiFi.softAP(req.ssid, req.pass[0] ? req.pass : nullptr, req.channel, 0, 4);
    g.apOn = ok;
    if (ok) {
      strlcpy(g.apSsid, req.ssid, sizeof g.apSsid);
      g.apChannel = req.channel;
      UI::toast("AP actif");
    } else {
      WiFi.mode(WIFI_STA);
      UI::toast("AP: echec");
    }
  } else {
    WiFi.softAPdisconnect(false);
    WiFi.mode(WIFI_STA);
    g.apOn = false;
    g.apClients = 0;
    g.apSsid[0] = 0;
    UI::toast("AP coupe");
  }
  memset(req.pass, 0, sizeof req.pass);  // le mot de passe ne reste pas en RAM
}
}  // namespace

void setBeacon(bool on, const char* msg) {
  if (on) {
    char clean[proto::BEACON_MAX + 1];
    size_t n = 0;
    for (const char* p = msg; p && *p && n < proto::BEACON_MAX; ++p)
      clean[n++] = (uint8_t)*p < 0x20 ? ' ' : *p;  // pas de caractères de contrôle
    clean[n] = 0;
    if (!n) {
      UI::toast("Balise: message vide");
      return;
    }
    memcpy(g.beaconMsg, clean, n + 1);
  }
  g.beaconOn = on;
  Link::refreshAdvertising();
  UI::toast(on ? "Balise active" : "Balise coupee");
}

void requestAp(bool on, const char* ssid, const char* pass, uint8_t channel) {
  if (on) {
    size_t pl = strlen(pass);
    if (!*ssid || channel < 1 || channel > 13 || (pl && (pl < 8 || pl > 63))) {
      UI::toast("AP: parametres invalides");
      return;
    }
    if (WifiScan::ssidNearby(ssid)) {
      UI::toast("AP refuse: SSID deja present");
      return;
    }
    strlcpy(req.ssid, ssid, sizeof req.ssid);
    strlcpy(req.pass, pass, sizeof req.pass);
    req.channel = channel;
  }
  req.on = on;
  req.pending = true;  // appliqué hors scan Wi-Fi (changer de mode pendant un scan le casse)
}

void service() {
  if (req.pending && !WifiScan::busy()) applyAp();

  uint32_t now = millis();
  if (g.apOn && now - lastClientPoll >= 1000) {
    lastClientPoll = now;
    g.apClients = WiFi.softAPgetStationNum();
  }
}
}  // namespace Emit
