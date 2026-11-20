// Acheminement des enregistrements :
//  - iPhone connecté et rien en attente -> regroupés dans un paquet BLE (notify) ;
//  - sinon -> tampon RAM puis fichier LittleFS, vidé dès que l'iPhone revient.
// Le fichier est une simple concaténation d'enregistrements [type][len][payload].
#include <LittleFS.h>
#include <Preferences.h>

#include "app.h"

namespace Store {
namespace {
const char* BL_PATH = "/backlog.bin";
bool fsOk = false;

uint8_t pkt[256];
size_t pktLen = 0;
uint32_t pktSince = 0;

uint8_t ram[4096];  // tampon avant écriture flash
size_t ramLen = 0;
uint32_t ramSince = 0;

uint32_t fileSize = 0;
uint32_t readOff = 0;  // déjà transmis (persisté pour éviter les doublons après redémarrage)
uint32_t lastPersistedOff = 0;
bool full = false;
Preferences prefs;

void persistOffset() {
  if (readOff == lastPersistedOff) return;
  prefs.putUInt("off", readOff);
  lastPersistedOff = readOff;
}

void flushRamToFile() {
  if (!ramLen) return;
  if (!fsOk || fileSize + ramLen > BACKLOG_MAX_BYTES) {
    full = true;
    ramLen = 0;
    return;
  }
  File f = LittleFS.open(BL_PATH, FILE_APPEND);
  if (f) {
    size_t w = f.write(ram, ramLen);
    f.close();
    fileSize += w;
  }
  ramLen = 0;
}

void toBacklog(const uint8_t* rec, size_t len) {
  if (ramLen + len > sizeof ram) flushRamToFile();
  if (len > sizeof ram) return;
  if (!ramLen) ramSince = millis();
  memcpy(ram + ramLen, rec, len);
  ramLen += len;
}

bool flushPkt() {
  if (!pktLen) return true;
  if (Link::sendPacket(pkt, pktLen)) {
    pktLen = 0;
    return true;
  }
  // Pile BLE saturée : on ne perd rien, ça repart dans le tampon.
  toBacklog(pkt, pktLen);
  pktLen = 0;
  return false;
}

// Remplit `out` avec des enregistrements entiers pris dans `src` (max `cap` octets).
size_t packWhole(const uint8_t* src, size_t avail, uint8_t* out, size_t cap) {
  size_t used = 0;
  while (used + 2 <= avail) {
    size_t recLen = 2 + src[used + 1];
    if (used + recLen > avail || used + recLen > cap) break;
    used += recLen;
  }
  if (used == 0 && avail >= 2 && 2u + src[1] > cap) return SIZE_MAX;  // enregistrement trop gros : à sauter
  memcpy(out, src, used);
  return used;
}

void drainFile() {
  if (readOff >= fileSize) return;
  File f = LittleFS.open(BL_PATH, FILE_READ);
  if (!f) {
    fileSize = readOff = 0;
    return;
  }
  uint8_t chunk[256];
  uint8_t out[256];
  size_t cap = Link::maxPayload();
  for (int k = 0; k < 6 && readOff < fileSize; ++k) {
    f.seek(readOff);
    size_t n = f.read(chunk, min(sizeof chunk, (size_t)(fileSize - readOff)));
    if (!n) break;
    size_t used = packWhole(chunk, n, out, cap);
    if (used == SIZE_MAX) {  // ne devrait pas arriver, on saute l'enregistrement
      readOff += 2 + chunk[1];
      continue;
    }
    if (!used) {  // fichier tronqué (coupure pendant une écriture)
      readOff = fileSize;
      break;
    }
    if (!Link::sendPacket(out, used)) break;
    readOff += used;
  }
  f.close();
  if (readOff >= fileSize) {
    LittleFS.remove(BL_PATH);
    fileSize = readOff = 0;
    full = false;
  }
  if (readOff - lastPersistedOff > 32768 || readOff == 0) persistOffset();
}

void drainRam() {
  uint8_t out[256];
  size_t cap = Link::maxPayload();
  for (int k = 0; k < 6 && ramLen; ++k) {
    size_t used = packWhole(ram, ramLen, out, cap);
    if (used == SIZE_MAX) used = 2 + ram[1];
    else if (!used || !Link::sendPacket(out, used)) break;
    memmove(ram, ram + used, ramLen - used);
    ramLen -= used;
  }
}
}  // namespace

void begin() {
  fsOk = LittleFS.begin(true);
  prefs.begin("store", false);
  if (fsOk) {
    File f = LittleFS.open(BL_PATH, FILE_READ);
    if (f) {
      fileSize = f.size();
      f.close();
    }
    readOff = prefs.getUInt("off", 0);
    if (readOff > fileSize) readOff = 0;
    lastPersistedOff = readOff;
  }
  Serial.printf("[store] LittleFS %s, %u octets en attente\n", fsOk ? "OK" : "ERREUR",
                (unsigned)(fileSize - readOff));
}

void push(const uint8_t* rec, size_t len) {
  bool live = Link::canSend() && readOff >= fileSize && ramLen == 0;
  if (!live) {
    flushPkt();
    toBacklog(rec, len);
    return;
  }
  if (len > Link::maxPayload()) return;
  if (pktLen + len > Link::maxPayload()) flushPkt();
  if (!pktLen) pktSince = millis();
  if (pktLen + len <= sizeof pkt) {
    memcpy(pkt + pktLen, rec, len);
    pktLen += len;
  } else {
    toBacklog(rec, len);
  }
}

void service() {
  uint32_t now = millis();
  if (Link::canSend()) {
    if (pktLen && now - pktSince > 150) flushPkt();
    if (readOff < fileSize) drainFile();
    else if (ramLen) drainRam();
  } else {
    if (pktLen) flushPkt();  // l'iPhone vient de partir : le paquet va au tampon
    if (ramLen && (ramLen > sizeof ram / 2 || now - ramSince > 5000)) flushRamToFile();
    persistOffset();
  }
}

void purge() {
  if (fsOk) LittleFS.remove(BL_PATH);
  fileSize = readOff = 0;
  ramLen = pktLen = 0;
  full = false;
  persistOffset();
}

uint32_t backlogBytes() { return (fileSize - readOff) + ramLen; }
}  // namespace Store
