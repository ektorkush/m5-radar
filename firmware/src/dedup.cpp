// Cache associatif (512 ensembles x 4 voies) : évite de renvoyer en boucle les
// mêmes réseaux/appareils. Une éviction ne provoque qu'un renvoi : sans gravité.
#include "app.h"

namespace Dedup {
namespace {
constexpr int SETS = 512, WAYS = 4;
struct Slot {
  uint64_t key;
  uint32_t lastSeen;  // 0 = libre
  uint32_t lastSent;
  int8_t rssi;
};
Slot table[SETS][WAYS];
// check() est appelé depuis loop() (Wi-Fi) et depuis la tâche NimBLE (scan BLE).
portMUX_TYPE mux = portMUX_INITIALIZER_UNLOCKED;

uint64_t makeKey(uint8_t kind, const uint8_t a[6]) {
  uint64_t k = kind;
  for (int i = 0; i < 6; ++i) k = (k << 8) | a[i];
  return k;
}
uint32_t hash(uint64_t k) {
  k ^= k >> 33;
  k *= 0xff51afd7ed558ccdULL;
  k ^= k >> 33;
  return (uint32_t)k;
}
}  // namespace

bool check(uint8_t kind, const uint8_t addr[6], int8_t rssi, bool& isNew) {
  uint32_t now = millis() | 1;
  uint64_t key = makeKey(kind, addr);
  Slot* set = table[hash(key) & (SETS - 1)];
  bool send = true;
  taskENTER_CRITICAL(&mux);
  int found = -1;
  for (int i = 0; i < WAYS; ++i) {
    if (set[i].lastSeen && set[i].key == key) { found = i; break; }
  }
  if (found >= 0) {
    Slot& s = set[found];
    s.lastSeen = now;
    isNew = false;
    send = abs(rssi - s.rssi) >= RSSI_DELTA || now - s.lastSent >= SEEN_REFRESH_MS;
    if (send) {
      s.lastSent = now;
      s.rssi = rssi;
    }
  } else {
    int victim = 0;
    for (int i = 0; i < WAYS; ++i) {
      if (!set[i].lastSeen) { victim = i; break; }
      if (now - set[i].lastSeen > now - set[victim].lastSeen) victim = i;  // le plus ancien
    }
    set[victim] = {key, now, now, rssi};
    isNew = true;
  }
  taskEXIT_CRITICAL(&mux);
  return send;
}

uint16_t countRecent(uint8_t kind, uint32_t windowMs) {
  uint32_t now = millis();
  uint16_t n = 0;
  for (auto& set : table) {
    taskENTER_CRITICAL(&mux);  // section critique courte : un ensemble à la fois
    for (auto& s : set)
      if (s.lastSeen && (uint8_t)(s.key >> 48) == kind && now - s.lastSeen < windowMs) ++n;
    taskEXIT_CRITICAL(&mux);
  }
  return n;
}
}  // namespace Dedup
