// Détection du câblage NRF24L01 sur M5StickC Plus2.
//
// Broches accessibles sur le Plus2 : en-tête HAT (G0, G26, et le plot partagé
// G25/G36) + port Grove (G32, G33). Le NRF24 a besoin de 5 signaux
// (SCK, MOSI, MISO, CSN, CE) : il utilise donc forcément ces 5 plots.
// G36 est en entrée seule : sur le plot partagé, on sort par G25 et on lit par G36.
//
// Méthode : pour chaque attribution des rôles SPI, on écrit deux valeurs
// différentes dans RF_CH et SETUP_AW puis on les relit (pas d'émission radio).
// Le plot restant est testé comme CE en envoyant UN paquet de 1 octet sans
// acquittement et en regardant le bit TX_DS (preuve que CE pilote la puce).

#include <M5Unified.h>

static const int PADS = 5;
// Chaque plot : broche de sortie, broche d'entrée (différentes pour le plot partagé)
struct Pad { int out; int in; const char* label; };
static const Pad pads[PADS] = {
    {0, 0, "G0"},
    {26, 26, "G26"},
    {25, 36, "G25/G36"},
    {32, 32, "G32"},
    {33, 33, "G33"},
};

static int pSCK, pMOSI, pMISO, pCSN;

static void releaseAll() {
  for (auto& p : pads) {
    gpio_reset_pin((gpio_num_t)p.out);
    pinMode(p.out, INPUT);
    if (p.in != p.out) pinMode(p.in, INPUT);
  }
  gpio_pullup_dis(GPIO_NUM_25);
  gpio_pulldown_dis(GPIO_NUM_25);
}

static uint8_t xfer(uint8_t out) {
  uint8_t in = 0;
  for (int i = 7; i >= 0; --i) {
    digitalWrite(pMOSI, (out >> i) & 1);
    delayMicroseconds(2);
    digitalWrite(pSCK, HIGH);
    delayMicroseconds(2);
    in = (in << 1) | (digitalRead(pMISO) & 1);
    digitalWrite(pSCK, LOW);
  }
  return in;
}

static void writeReg(uint8_t reg, uint8_t v) {
  digitalWrite(pCSN, LOW);
  xfer(0x20 | (reg & 0x1F));
  xfer(v);
  digitalWrite(pCSN, HIGH);
  delayMicroseconds(5);
}

static uint8_t readReg(uint8_t reg) {
  digitalWrite(pCSN, LOW);
  xfer(reg & 0x1F);
  uint8_t v = xfer(0xFF);
  digitalWrite(pCSN, HIGH);
  delayMicroseconds(5);
  return v;
}

static void command(uint8_t cmd) {
  digitalWrite(pCSN, LOW);
  xfer(cmd);
  digitalWrite(pCSN, HIGH);
}

static bool trySpi(int sck, int mosi, int miso, int csn) {
  releaseAll();
  pSCK = pads[sck].out;
  pMOSI = pads[mosi].out;
  pMISO = pads[miso].in;
  pCSN = pads[csn].out;
  if (pads[miso].in != pads[miso].out) pinMode(pads[miso].out, INPUT);  // G25 flottant
  pinMode(pMISO, INPUT);
  pinMode(pCSN, OUTPUT);
  digitalWrite(pCSN, HIGH);
  pinMode(pSCK, OUTPUT);
  digitalWrite(pSCK, LOW);
  pinMode(pMOSI, OUTPUT);
  digitalWrite(pMOSI, LOW);
  delay(2);

  const uint8_t RF_CH = 0x05, SETUP_AW = 0x03;
  writeReg(RF_CH, 0x2A);
  if (readReg(RF_CH) != 0x2A) return false;
  writeReg(RF_CH, 0x55);
  if (readReg(RF_CH) != 0x55) return false;
  writeReg(SETUP_AW, 0x01);
  if (readReg(SETUP_AW) != 0x01) return false;
  writeReg(SETUP_AW, 0x03);
  if (readReg(SETUP_AW) != 0x03) return false;
  writeReg(RF_CH, 0x02);  // valeurs par défaut
  return true;
}

// Teste si `pad` est relié à CE : un paquet de 1 octet sans ACK doit lever TX_DS.
static bool tryCe(int pad) {
  int ce = pads[pad].out;
  pinMode(ce, OUTPUT);
  digitalWrite(ce, LOW);
  writeReg(0x07, 0x70);  // STATUS : efface les drapeaux
  writeReg(0x01, 0x00);  // EN_AA = 0 (pas d'acquittement)
  writeReg(0x04, 0x00);  // SETUP_RETR = 0
  writeReg(0x06, 0x00);  // RF_SETUP : 1 Mb/s, puissance minimale (-18 dBm)
  writeReg(0x05, 0x02);  // canal 2402 MHz
  writeReg(0x00, 0x02);  // CONFIG : PWR_UP, PRIM_RX = 0 (TX)
  delay(5);
  command(0xE1);  // FLUSH_TX
  digitalWrite(pCSN, LOW);
  xfer(0xA0);  // W_TX_PAYLOAD
  xfer(0x00);
  digitalWrite(pCSN, HIGH);
  digitalWrite(ce, HIGH);
  delayMicroseconds(20);
  digitalWrite(ce, LOW);
  delay(2);
  bool sent = readReg(0x07) & 0x20;  // TX_DS
  writeReg(0x07, 0x70);
  command(0xE1);
  writeReg(0x00, 0x00);  // power down
  pinMode(ce, INPUT);
  return sent;
}

static void show(const String& s, uint16_t color = TFT_WHITE) {
  Serial.println(s);
  M5.Display.setTextColor(color, TFT_BLACK);
  M5.Display.println(s);
}

void setup() {
  auto cfg = M5.config();
  cfg.internal_mic = false;  // le micro utilise G0
  M5.begin(cfg);
  Serial.begin(115200);
  M5.Display.setRotation(1);
  M5.Display.fillScreen(TFT_BLACK);
  M5.Display.setTextSize(1);
  M5.Display.setCursor(0, 0);
  delay(500);
  show("Recherche du NRF24...");

  int found = 0;
  for (int sck = 0; sck < PADS; ++sck)
    for (int mosi = 0; mosi < PADS; ++mosi)
      for (int miso = 0; miso < PADS; ++miso)
        for (int csn = 0; csn < PADS; ++csn) {
          if (sck == mosi || sck == miso || sck == csn || mosi == miso || mosi == csn || miso == csn) continue;
          // Le plot partagé ne peut pas servir à la fois d'entrée et de sortie : OK, chaque rôle est unique.
          if (!trySpi(sck, mosi, miso, csn)) continue;
          int ce = 0 + 1 + 2 + 3 + 4 - sck - mosi - miso - csn;
          bool ceOk = tryCe(ce);
          ++found;
          char buf[160];
          snprintf(buf, sizeof buf, "TROUVE: SCK=%s MOSI=%s MISO=%s CSN=%s CE=%s%s", pads[sck].label, pads[mosi].label,
                   pads[miso].label, pads[csn].label, pads[ce].label, ceOk ? " (CE confirme)" : " (CE non confirme)");
          show(buf, TFT_GREEN);
          snprintf(buf, sizeof buf,
                   "config.h -> #define NRF_PIN_SCK %d / MOSI %d / MISO %d / CSN %d / CE %d", pads[sck].out,
                   pads[mosi].out, pads[miso].in, pads[csn].out, pads[ce].out);
          Serial.println(buf);
        }
  releaseAll();
  if (!found) {
    show("Aucun NRF24 detecte.", TFT_RED);
    show("Verifie 3V3/GND et le cablage.");
  }
  show("Termine.");
}

void loop() {
  M5.update();
  delay(50);
}
