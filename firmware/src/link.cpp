// Liaison BLE avec l'iPhone : serveur GATT NimBLE (service SVC_UUID).
//
// Sécurité : STATUS et CMD exigent un lien chiffré ET authentifié. L'appairage se fait
// par code à 6 chiffres affiché sur l'écran du M5 (le M5 n'a pas de clavier), puis la
// liaison est mémorisée en NVS : l'iPhone se reconnecte ensuite sans code.
// DATA n'est jamais notifié tant que le lien n'est pas sécurisé (voir canSend()).
#include <M5Unified.h>
#include <NimBLEDevice.h>

#include "app.h"

namespace Link {
namespace {
constexpr uint32_t STATUS_PERIOD_MS = 2000;
constexpr uint32_t UNSECURED_TIMEOUT_MS = 90000;  // un inconnu ne peut pas monopoliser le M5

NimBLEServer* server = nullptr;
NimBLECharacteristic* dataChr = nullptr;
NimBLECharacteristic* statusChr = nullptr;

volatile uint16_t connHandle = BLE_HS_CONN_HANDLE_NONE;
volatile uint16_t mtu = 23;
volatile bool advDirty = true;
volatile bool statusDirty = true;
uint32_t connectedAt = 0;
uint32_t lastStatus = 0;

struct Cmd {
  uint8_t len;
  uint8_t data[127];
};
QueueHandle_t cmdQueue = nullptr;

class ServerCb : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* s, NimBLEConnInfo& ci) override {
    if (connHandle != BLE_HS_CONN_HANDLE_NONE) {  // un seul iPhone à la fois
      s->disconnect(ci);
      return;
    }
    connHandle = ci.getConnHandle();
    g.linkConnected = true;
    g.linkSecure = ci.isEncrypted() && ci.isAuthenticated();
    g.linkSubscribed = false;
    advDirty = true;
    // Demande de sécurité immédiate : iOS chiffre avec la clé mémorisée,
    // ou affiche la demande d'appairage la première fois.
    NimBLEDevice::startSecurity(ci.getConnHandle());
  }

  void onDisconnect(NimBLEServer*, NimBLEConnInfo& ci, int reason) override {
    if (ci.getConnHandle() != connHandle) return;
    connHandle = BLE_HS_CONN_HANDLE_NONE;
    g.linkConnected = g.linkSecure = g.linkSubscribed = false;
    g.passkey = 0;
    mtu = 23;
    advDirty = true;
  }

  void onMTUChange(uint16_t m, NimBLEConnInfo& ci) override {
    if (ci.getConnHandle() == connHandle) mtu = m;
  }

  uint32_t onPassKeyDisplay() override {
    uint32_t pk = 100000 + esp_random() % 900000;
    g.passkey = pk;  // l'écran se rallume et l'affiche (UI::service)
    return pk;
  }

  void onAuthenticationComplete(NimBLEConnInfo& ci) override {
    if (ci.getConnHandle() != connHandle) return;
    g.passkey = 0;
    if (!ci.isEncrypted() || !ci.isAuthenticated()) {
      server->disconnect(ci);  // code refusé ou appairage sans protection MITM
      return;
    }
    g.linkSecure = true;
    statusDirty = true;
  }
};

class DataCb : public NimBLECharacteristicCallbacks {
  void onSubscribe(NimBLECharacteristic*, NimBLEConnInfo& ci, uint16_t subValue) override {
    if (ci.getConnHandle() == connHandle) g.linkSubscribed = (subValue & 1) != 0;
  }
};

class CmdCb : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* c, NimBLEConnInfo& ci) override {
    if (ci.getConnHandle() != connHandle) return;
    NimBLEAttValue v = c->getValue();
    if (!v.size() || v.size() > sizeof(Cmd::data)) return;
    Cmd cmd;
    cmd.len = v.size();
    memcpy(cmd.data, v.data(), v.size());
    xQueueSend(cmdQueue, &cmd, 0);  // traité dans loop() : pas d'accès concurrent
  }
};

ServerCb serverCb;
DataCb dataCb;
CmdCb cmdCb;

uint32_t le32(const uint8_t* p) { return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24); }

void handleCmd(const uint8_t* d, size_t n) {
  switch (d[0]) {
    case proto::CMD_SET_TIME:
      if (n >= 5 && le32(d + 1) > 1700000000) applyUnixTime(le32(d + 1));
      break;
    case proto::CMD_SCAN:
      if (n >= 2) {
        g.scanning = d[1] != 0;
        if (!g.scanning) BleScan::pause();
      }
      break;
    case proto::CMD_BEACON: {
      if (n < 3) break;
      size_t len = d[2];
      if (len > proto::BEACON_MAX || n < 3 + len) break;
      char msg[proto::BEACON_MAX + 1];
      memcpy(msg, d + 3, len);
      msg[len] = 0;
      Emit::setBeacon(d[1] != 0, msg);
      break;
    }
    case proto::CMD_AP: {
      if (n < 4) break;
      size_t sl = d[3];
      if (sl > 32 || n < 4 + sl + 1) break;
      size_t pl = d[4 + sl];
      if (pl > 63 || n < 5 + sl + pl) break;
      char ssid[33], pass[64];
      memcpy(ssid, d + 4, sl);
      ssid[sl] = 0;
      memcpy(pass, d + 5 + sl, pl);
      pass[pl] = 0;
      Emit::requestAp(d[1] != 0, ssid, pass, d[2]);
      break;
    }
    case proto::CMD_PURGE:
      Store::purge();
      UI::toast("Tampon vide");
      break;
    case proto::CMD_ECO:
      if (n >= 2) g.eco = d[1] != 0;
      break;
  }
  statusDirty = true;
}

void buildStatus(uint8_t* out) {
  int32_t pct = M5.Power.getBatteryLevel();
  int32_t mv = M5.Power.getBatteryVoltage();
  uint8_t flags = (g.scanning ? 1 : 0) | (g.eco ? 2 : 0) | (g.nrfOk ? 4 : 0) | (g.beaconOn ? 8 : 0) |
                  (g.apOn ? 16 : 0) | (g.timeValid ? 32 : 0);
  proto::Writer w(out, proto::STATUS_LEN);
  w.u8(proto::STATUS_VERSION);
  w.u8(pct < 0 ? 0 : pct > 100 ? 100 : pct);
  w.u16(mv < 0 ? 0 : mv);
  w.u8(flags);
  w.u8(g.apClients);
  w.u32(g.wifiSeen);
  w.u32(g.bleSeen);
  w.u32(Store::backlogBytes());
  w.u32(millis() / 1000);
}

void applyAdvertising() {
  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  adv->stop();
  bool connected = connHandle != BLE_HS_CONN_HANDLE_NONE;
  if (connected && !g.beaconOn) return;  // connecté : on devient invisible

  NimBLEAdvertisementData ad, sr;
  ad.setFlags(BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP);
  ad.setCompleteServices(NimBLEUUID(SVC_UUID));
  // La balise remplace le nom visible ; l'app reconnaît le M5 par son UUID de service.
  sr.setName(g.beaconOn && g.beaconMsg[0] ? g.beaconMsg : DEVICE_NAME);
  adv->setAdvertisementData(ad);
  adv->setScanResponseData(sr);
  adv->enableScanResponse(true);
  // Déjà connecté : la balise reste visible mais n'accepte pas de seconde connexion.
  adv->setConnectableMode(connected ? BLE_GAP_CONN_MODE_NON : BLE_GAP_CONN_MODE_UND);
  adv->start();
}
}  // namespace

void begin() {
  cmdQueue = xQueueCreate(6, sizeof(Cmd));
  NimBLEDevice::init(DEVICE_NAME);
  NimBLEDevice::setMTU(247);
  NimBLEDevice::setSecurityAuth(true, true, true);  // liaison, MITM, Secure Connections
  NimBLEDevice::setSecurityIOCap(BLE_HS_IO_DISPLAY_ONLY);

  server = NimBLEDevice::createServer();
  server->setCallbacks(&serverCb, false);
  server->advertiseOnDisconnect(false);  // géré par applyAdvertising()

  NimBLEService* svc = server->createService(SVC_UUID);
  dataChr = svc->createCharacteristic(
      DATA_UUID, NIMBLE_PROPERTY::NOTIFY | NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::READ_ENC |
                     NIMBLE_PROPERTY::READ_AUTHEN);
  dataChr->setCallbacks(&dataCb);
  statusChr = svc->createCharacteristic(
      STATUS_UUID, NIMBLE_PROPERTY::NOTIFY | NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::READ_ENC |
                       NIMBLE_PROPERTY::READ_AUTHEN);
  NimBLECharacteristic* cmdChr = svc->createCharacteristic(
      CMD_UUID, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_ENC | NIMBLE_PROPERTY::WRITE_AUTHEN);
  cmdChr->setCallbacks(&cmdCb);  // NimBLE 2.x démarre les services avec le serveur

  uint8_t st[proto::STATUS_LEN];
  buildStatus(st);
  statusChr->setValue(st, sizeof st);
  advDirty = true;
}

void service() {
  uint32_t now = millis();

  Cmd cmd;
  while (xQueueReceive(cmdQueue, &cmd, 0) == pdTRUE) handleCmd(cmd.data, cmd.len);

  if (advDirty) {
    advDirty = false;
    applyAdvertising();
  }

  if (g.linkConnected && !connectedAt) connectedAt = now;
  if (!g.linkConnected) connectedAt = 0;
  if (connectedAt && !g.linkSecure && now - connectedAt > UNSECURED_TIMEOUT_MS) {
    uint16_t h = connHandle;
    if (h != BLE_HS_CONN_HANDLE_NONE) server->disconnect(h);
    connectedAt = 0;
  }

  if (statusDirty || now - lastStatus >= STATUS_PERIOD_MS) {
    statusDirty = false;
    lastStatus = now;
    uint8_t st[proto::STATUS_LEN];
    buildStatus(st);
    statusChr->setValue(st, sizeof st);
    if (g.linkConnected && g.linkSecure) statusChr->notify();  // seulement aux abonnés
  }
}

bool canSend() { return g.linkConnected && g.linkSecure && g.linkSubscribed; }

bool sendPacket(const uint8_t* data, size_t len) {
  uint16_t h = connHandle;
  if (!canSend() || h == BLE_HS_CONN_HANDLE_NONE || len > maxPayload()) return false;
  return dataChr->notify(data, len, h);  // false si la pile n'a plus de tampons
}

size_t maxPayload() {
  size_t p = mtu > 23 ? mtu - 3 : 20;
  return p > 244 ? 244 : p;
}

void refreshAdvertising() { advDirty = true; }
}  // namespace Link
