// Analyseur de spectre 2,4 GHz avec le NRF24L01 en réception pure (aucune émission) :
// pour chaque canal (2400 + n MHz), on écoute ~170 µs et on lit le bit RPD
// (puissance reçue > -64 dBm). Niveau = part des balayages où le canal était occupé.
// Remarque : les émissions du M5 lui-même (BLE, AP de test) apparaissent aussi.
//
// L'écran utilise déjà le bus VSPI : le NRF24 est sur HSPI, broches libres via la matrice GPIO.
#include <SPI.h>

#include "app.h"

namespace Nrf {
namespace {
constexpr uint8_t R_REGISTER = 0x00, W_REGISTER = 0x20, FLUSH_RX = 0xE2;
constexpr uint8_t REG_CONFIG = 0x00, REG_EN_AA = 0x01, REG_SETUP_AW = 0x03, REG_RF_CH = 0x05,
                  REG_RF_SETUP = 0x06, REG_STATUS = 0x07, REG_RPD = 0x09;
constexpr int CHUNK = 42;  // canaux par appel de service() (~8 ms)
constexpr int HALF = proto::NRF_CHANNELS / 2;

SPIClass spi(HSPI);
const SPISettings settings(4000000, MSBFIRST, SPI_MODE0);
bool powered = false;
int nextCh = 0;
uint32_t sweepStart = 0, lastReport = 0;
uint16_t sweeps = 0;
uint16_t hits[proto::NRF_CHANNELS];

uint8_t readReg(uint8_t reg) {
  spi.beginTransaction(settings);
  digitalWrite(NRF_PIN_CSN, LOW);
  spi.transfer(R_REGISTER | reg);
  uint8_t v = spi.transfer(0xFF);
  digitalWrite(NRF_PIN_CSN, HIGH);
  spi.endTransaction();
  return v;
}

void writeReg(uint8_t reg, uint8_t v) {
  spi.beginTransaction(settings);
  digitalWrite(NRF_PIN_CSN, LOW);
  spi.transfer(W_REGISTER | reg);
  spi.transfer(v);
  digitalWrite(NRF_PIN_CSN, HIGH);
  spi.endTransaction();
}

void command(uint8_t c) {
  spi.beginTransaction(settings);
  digitalWrite(NRF_PIN_CSN, LOW);
  spi.transfer(c);
  digitalWrite(NRF_PIN_CSN, HIGH);
  spi.endTransaction();
}

void powerUp() {
  writeReg(REG_EN_AA, 0x00);      // pas d'acquittement automatique (donc jamais d'émission)
  writeReg(REG_RF_SETUP, 0x0F);   // 2 Mbit/s : bande d'écoute plus large, gain LNA max
  writeReg(REG_CONFIG, 0x03);     // PWR_UP + PRIM_RX, CRC désactivé
  writeReg(REG_STATUS, 0x70);
  command(FLUSH_RX);
  delay(5);                       // démarrage de l'oscillateur (1,5 ms max)
  powered = true;
  nextCh = 0;
  sweeps = 0;
  memset(hits, 0, sizeof hits);
  sweepStart = lastReport = millis();
}

void powerDown() {
  digitalWrite(NRF_PIN_CE, LOW);
  writeReg(REG_CONFIG, 0x00);
  powered = false;
}

void report() {
  uint8_t levels[proto::NRF_CHANNELS];
  for (int c = 0; c < proto::NRF_CHANNELS; ++c)
    levels[c] = sweeps ? (uint32_t)hits[c] * 255 / sweeps : 0;
  memcpy(g.spectrum, levels, sizeof levels);
  g.spectrumAt = millis();
  sweeps = 0;
  memset(hits, 0, sizeof hits);

  // Le spectre est une vue en direct : on ne le met pas dans le tampon hors ligne.
  if (!Link::canSend()) return;
  uint32_t ts = nowUnix();
  for (int off = 0; off < proto::NRF_CHANNELS; off += HALF) {  // 2 enregistrements : tient dans un MTU de 185
    uint8_t rec[2 + 6 + HALF];
    proto::Writer w(rec, sizeof rec);
    w.u8(proto::REC_SPECTRUM);
    w.u8(sizeof rec - 2);
    w.u32(ts);
    w.u8(off);
    w.u8(HALF);
    w.bytes(levels + off, HALF);
    Store::push(rec, w.len);
  }
}
}  // namespace

bool begin() {
#if NRF_ENABLED
  pinMode(NRF_PIN_CE, OUTPUT);
  digitalWrite(NRF_PIN_CE, LOW);
  pinMode(NRF_PIN_CSN, OUTPUT);
  digitalWrite(NRF_PIN_CSN, HIGH);
  spi.begin(NRF_PIN_SCK, NRF_PIN_MISO, NRF_PIN_MOSI, -1);
  delay(5);

  // Détection : SETUP_AW n'accepte que 2 bits, on vérifie la relecture.
  writeReg(REG_SETUP_AW, 0x01);
  bool ok = readReg(REG_SETUP_AW) == 0x01;
  writeReg(REG_SETUP_AW, 0x03);
  ok = ok && readReg(REG_SETUP_AW) == 0x03;
  if (!ok) {
    spi.end();
    return false;
  }
  powerDown();
  return true;
#else
  return false;
#endif
}

void service() {
  if (!g.nrfOk) return;
  if (!g.scanning) {
    if (powered) powerDown();
    return;
  }
  if (!powered) powerUp();

  uint32_t now = millis();
  if (nextCh == 0) {
    uint32_t every = g.eco ? NRF_REPORT_ECO_MS : NRF_REPORT_MS;
    if (sweeps && now - lastReport >= every) {
      lastReport = now;
      report();
    }
    uint32_t period = g.eco ? NRF_SWEEP_PERIOD_MS * 4 : NRF_SWEEP_PERIOD_MS;
    if (now - sweepStart < period) return;
    sweepStart = now;
  }

  int end = min(nextCh + CHUNK, proto::NRF_CHANNELS);
  for (int c = nextCh; c < end; ++c) {
    writeReg(REG_RF_CH, c);
    digitalWrite(NRF_PIN_CE, HIGH);
    delayMicroseconds(NRF_DWELL_US);  // 130 µs de calage PLL + 40 µs de mesure
    digitalWrite(NRF_PIN_CE, LOW);
    if (readReg(REG_RPD) & 1) ++hits[c];
  }
  nextCh = end;
  if (nextCh >= proto::NRF_CHANNELS) {
    nextCh = 0;
    ++sweeps;
  }
}
}  // namespace Nrf
