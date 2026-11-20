#pragma once
// Protocole binaire M5 <-> iPhone. Toute modification doit être reportée dans
// ios/M5Radar/Protocol.swift.
//
// Caractéristique DATA (notify) : suite d'enregistrements concaténés
//   [type u8][len u8][payload len octets]   — entiers en little-endian
//
// REC_WIFI     ts u32, bssid[6], rssi i8, channel u8, auth u8, ssid_len u8, ssid[]
// REC_BLE      ts u32, addr[6] (octet de poids fort en premier), addr_type u8, rssi i8,
//              flags u8 (bit0 connectable, bit1 tx_power présent), tx i8,
//              name_len u8, name[], mfr_len u8, mfr[] (ID fabricant inclus), svc_n u8, svc16 u16[svc_n]
// REC_SPECTRUM ts u32, offset u8, n u8, levels u8[n]   (0..255 = part du temps occupé)
//
// ts = secondes Unix UTC, 0 si l'heure n'est pas encore connue.
//
// Caractéristique STATUS (read/notify), 22 octets :
//   version u8, batt_pct u8, batt_mv u16, flags u8, ap_clients u8,
//   wifi_seen u32, ble_seen u32, backlog_bytes u32, uptime_s u32
//   flags : bit0 scan actif, bit1 éco, bit2 NRF ok, bit3 balise, bit4 AP, bit5 heure valide
//
// Caractéristique CMD (write) : [op u8][arguments]
//   CMD_SET_TIME  u32 unix
//   CMD_SCAN      u8 on
//   CMD_BEACON    u8 on, u8 len, msg[len]            (len <= 20)
//   CMD_AP        u8 on, u8 channel, u8 ssid_len, ssid[], u8 pass_len, pass[]
//   CMD_PURGE     —
//   CMD_ECO       u8 on

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define SVC_UUID "6e5a0001-7a3b-4c1d-9e2f-5b6a7c8d9e0f"
#define DATA_UUID "6e5a0002-7a3b-4c1d-9e2f-5b6a7c8d9e0f"
#define CMD_UUID "6e5a0003-7a3b-4c1d-9e2f-5b6a7c8d9e0f"
#define STATUS_UUID "6e5a0004-7a3b-4c1d-9e2f-5b6a7c8d9e0f"

namespace proto {
constexpr uint8_t REC_WIFI = 0x01;
constexpr uint8_t REC_BLE = 0x02;
constexpr uint8_t REC_SPECTRUM = 0x03;

constexpr uint8_t CMD_SET_TIME = 0x01;
constexpr uint8_t CMD_SCAN = 0x02;
constexpr uint8_t CMD_BEACON = 0x03;
constexpr uint8_t CMD_AP = 0x04;
constexpr uint8_t CMD_PURGE = 0x05;
constexpr uint8_t CMD_ECO = 0x06;

constexpr uint8_t STATUS_VERSION = 1;
constexpr uint8_t STATUS_LEN = 22;

constexpr uint8_t BEACON_MAX = 20;
constexpr int NRF_CHANNELS = 126;

// Petit écrivain de tampon : ajoute des champs et vérifie la place disponible.
struct Writer {
  uint8_t* buf;
  size_t cap;
  size_t len = 0;
  bool ok = true;
  Writer(uint8_t* b, size_t c) : buf(b), cap(c) {}
  void u8(uint8_t v) {
    if (len + 1 > cap) { ok = false; return; }
    buf[len++] = v;
  }
  void u16(uint16_t v) { u8(v & 0xFF); u8(v >> 8); }
  void u32(uint32_t v) { u16(v & 0xFFFF); u16(v >> 16); }
  void bytes(const void* p, size_t n) {
    if (len + n > cap) { ok = false; return; }
    memcpy(buf + len, p, n);
    len += n;
  }
};
}  // namespace proto
