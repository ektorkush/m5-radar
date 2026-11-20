// Scan BLE continu (NimBLE). Les annonces arrivent dans la tâche NimBLE : on y fait
// le dédoublonnage (thread-safe) et la mise en forme, puis on passe l'enregistrement
// à loop() par une file FreeRTOS. Store n'est donc utilisé que depuis loop().
#include <NimBLEDevice.h>

#include "app.h"

namespace BleScan {
namespace {
constexpr size_t BLE_NAME_LEN = 29, BLE_MFR_LEN = 31, BLE_SVC_N = 8;

struct Item {
  uint8_t isNew;
  uint8_t len;
  uint8_t rec[2 + 14 + 1 + BLE_NAME_LEN + 1 + BLE_MFR_LEN + 1 + 2 * BLE_SVC_N];
};
QueueHandle_t queue = nullptr;
NimBLEScan* scan = nullptr;
volatile bool held = false;  // en pause pendant un scan Wi-Fi
bool running = false;

void addSvc16(uint16_t* list, uint8_t& n, const NimBLEUUID& u) {
  if (u.bitSize() != BLE_UUID_TYPE_16 || n >= BLE_SVC_N) return;
  uint16_t v;
  memcpy(&v, u.getValue(), 2);
  for (uint8_t i = 0; i < n; ++i)
    if (list[i] == v) return;
  list[n++] = v;
}

class ScanCb : public NimBLEScanCallbacks {
  void onResult(const NimBLEAdvertisedDevice* d) override {
    const NimBLEAddress& a = d->getAddress();
    const uint8_t* le = a.getVal();  // octet de poids faible en premier
    uint8_t addr[6];
    for (int i = 0; i < 6; ++i) addr[i] = le[5 - i];
    int8_t rssi = d->getRSSI();

    bool isNew;
    if (!Dedup::check(Dedup::KIND_BLE, addr, rssi, isNew)) return;

    Item it;
    it.isNew = isNew;
    proto::Writer w(it.rec, sizeof it.rec);
    w.u8(proto::REC_BLE);
    w.u8(0);
    w.u32(nowUnix());
    w.bytes(addr, 6);
    w.u8(a.getType());
    w.u8((uint8_t)rssi);
    bool hasTx = d->haveTXPower();
    w.u8((d->isConnectable() ? 1 : 0) | (hasTx ? 2 : 0));
    w.u8(hasTx ? (uint8_t)d->getTXPower() : 0);

    std::string name = d->haveName() ? d->getName() : std::string();
    size_t nl = name.size() > BLE_NAME_LEN ? BLE_NAME_LEN : name.size();
    w.u8(nl);
    w.bytes(name.data(), nl);

    std::string mfr = d->haveManufacturerData() ? d->getManufacturerData() : std::string();
    size_t ml = mfr.size() > BLE_MFR_LEN ? BLE_MFR_LEN : mfr.size();
    w.u8(ml);
    w.bytes(mfr.data(), ml);

    uint16_t svc[BLE_SVC_N];
    uint8_t sn = 0;
    for (uint8_t i = 0; i < d->getServiceUUIDCount(); ++i) addSvc16(svc, sn, d->getServiceUUID(i));
    for (uint8_t i = 0; i < d->getServiceDataCount(); ++i) addSvc16(svc, sn, d->getServiceDataUUID(i));
    w.u8(sn);
    for (uint8_t i = 0; i < sn; ++i) w.u16(svc[i]);

    if (!w.ok) return;
    it.rec[1] = w.len - 2;
    it.len = w.len;
    xQueueSend(queue, &it, 0);  // file pleine : l'annonce suivante du même appareil passera
  }

  void onScanEnd(const NimBLEScanResults&, int) override {}
};
ScanCb scanCb;
}  // namespace

void begin() {
  queue = xQueueCreate(24, sizeof(Item));
  scan = NimBLEDevice::getScan();
  scan->setScanCallbacks(&scanCb, true);  // doublons voulus : suivi du RSSI (filtré par Dedup)
  scan->setDuplicateFilter(0);
  scan->setActiveScan(BLE_ACTIVE_SCAN);
  scan->setInterval(160);
  scan->setWindow(80);  // 50 % : laisse du temps radio à la connexion iPhone et au Wi-Fi
  scan->setMaxResults(0);  // rien n'est stocké par NimBLE
}

void service() {
  Item it;
  for (int k = 0; k < 24 && xQueueReceive(queue, &it, 0) == pdTRUE; ++k) {
    if (it.isNew) ++g.bleSeen;
    Store::push(it.rec, it.len);
  }

  if (held && !WifiScan::busy()) held = false;
  bool want = g.scanning && !held;
  if (want && !running) running = scan->start(0, false, true);
  else if (!want && running) {
    scan->stop();
    running = false;
  }
  if (running && !scan->isScanning()) running = false;  // arrêt imprévu : relance au tour suivant
}

void pause() {
  held = true;
  if (running) {
    scan->stop();
    running = false;
  }
}

void resume() { held = false; }
}  // namespace BleScan
