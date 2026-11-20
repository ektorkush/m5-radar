// Scan Wi-Fi asynchrone (passif par défaut : écoute des beacons, aucune probe request).
// Le scan BLE est mis en pause pendant le balayage : la radio 2,4 GHz est partagée.
#include <WiFi.h>

#include "app.h"

namespace WifiScan {
namespace {
constexpr uint32_t SCAN_TIMEOUT_MS = 15000;
constexpr uint32_t SSID_MEMORY_MS = 5 * 60 * 1000;

bool running = false;
uint32_t startedAt = 0;
uint32_t lastScan = 0;

// SSID vus récemment (empreintes FNV-1a) : sert à refuser un AP de test qui
// usurperait le nom d'un réseau voisin.
struct SsidSeen {
  uint32_t hash;
  uint32_t at;  // 0 = libre
};
SsidSeen ssids[128];

uint32_t fnv1a(const char* s) {
  uint32_t h = 2166136261u;
  while (*s) h = (h ^ (uint8_t)*s++) * 16777619u;
  return h;
}

void rememberSsid(const char* s) {
  if (!*s) return;
  uint32_t h = fnv1a(s), now = millis() | 1;
  int freeSlot = -1, oldest = 0;
  for (int i = 0; i < (int)(sizeof ssids / sizeof ssids[0]); ++i) {
    if (!ssids[i].at) {
      if (freeSlot < 0) freeSlot = i;
      continue;
    }
    if (ssids[i].hash == h) {
      ssids[i].at = now;
      return;
    }
    if (now - ssids[i].at > now - ssids[oldest].at) oldest = i;
  }
  ssids[freeSlot >= 0 ? freeSlot : oldest] = {h, now};
}

void finish(int n) {
  uint32_t ts = nowUnix();
  for (int i = 0; i < n; ++i) {
    const uint8_t* bssid = WiFi.BSSID(i);
    if (!bssid) continue;
    int8_t rssi = WiFi.RSSI(i);
    String ssid = WiFi.SSID(i);
    rememberSsid(ssid.c_str());

    bool isNew;
    if (!Dedup::check(Dedup::KIND_WIFI, bssid, rssi, isNew)) continue;
    if (isNew) ++g.wifiSeen;

    size_t sl = ssid.length() > 32 ? 32 : ssid.length();
    uint8_t rec[2 + 14 + 32];
    proto::Writer w(rec, sizeof rec);
    w.u8(proto::REC_WIFI);
    w.u8(0);  // longueur, complétée plus bas
    w.u32(ts);
    w.bytes(bssid, 6);
    w.u8((uint8_t)rssi);
    w.u8(WiFi.channel(i));
    w.u8((uint8_t)WiFi.encryptionType(i));  // wifi_auth_mode_t brut, décodé côté iPhone
    w.u8(sl);
    w.bytes(ssid.c_str(), sl);
    if (!w.ok) continue;
    rec[1] = w.len - 2;
    Store::push(rec, w.len);
  }
  g.wifiLastScan = n;
}
}  // namespace

void begin() {
  WiFi.persistent(false);  // ne rien écrire en flash
  WiFi.mode(WIFI_STA);
  WiFi.disconnect();
}

void service() {
  uint32_t now = millis();

  if (running) {
    int n = WiFi.scanComplete();
    // Arduino renvoie WIFI_SCAN_FAILED dès max_ms_per_chan × 20 (3 s), mais quand le Bluetooth
    // partage la radio le vrai scan dure plus longtemps et finit quand même : on attend son
    // résultat (scanComplete() le renvoie dès la fin réelle), jusqu'à notre propre délai.
    if (n < 0 && now - startedAt < SCAN_TIMEOUT_MS) return;
    uint32_t before = g.wifiSeen;
    if (n >= 0) finish(n);
    Serial.printf("[wifi] scan fini : %d resultats, %u nouveaux, %u ms\n", n, (unsigned)(g.wifiSeen - before),
                  (unsigned)(now - startedAt));
    WiFi.scanDelete();
    running = false;
    lastScan = now;
    BleScan::resume();
    return;
  }

  if (!g.scanning) return;
  uint32_t interval = g.eco ? WIFI_SCAN_INTERVAL_ECO_MS : WIFI_SCAN_INTERVAL_MS;
  if (lastScan && now - lastScan < interval) return;

  BleScan::pause();
  int r = WiFi.scanNetworks(true, true, WIFI_PASSIVE_SCAN, WIFI_SCAN_MS_PER_CHAN);
  if (r == WIFI_SCAN_FAILED) {
    Serial.println("[wifi] echec du lancement du scan");
    lastScan = now;  // on réessaiera au prochain intervalle
    BleScan::resume();
    return;
  }
  running = true;
  startedAt = now;
}

bool busy() { return running; }

bool ssidNearby(const char* ssid) {
  if (!ssid || !*ssid) return false;
  uint32_t h = fnv1a(ssid), now = millis();
  for (auto& s : ssids)
    if (s.at && s.hash == h && now - s.at < SSID_MEMORY_MS) return true;
  return false;
}
}  // namespace WifiScan
