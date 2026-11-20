// Écran 240x135 (paysage). Trois pages : Résumé, Spectre 2,4 GHz, Émission.
// Bouton A : page suivante. Bouton B : scan marche/arrêt. Le premier appui
// sur un écran éteint ne fait que le rallumer.
// Tout est dessiné dans un sprite 8 bits (~32 Ko) puis poussé d'un bloc : pas de scintillement.
#include <M5Unified.h>

#include "app.h"

namespace UI {
namespace {
constexpr int W = 240, H = 135;
constexpr int PAGES = 3;
constexpr uint32_t FRAME_MS = 250;
constexpr uint32_t TOAST_MS = 2500;
constexpr uint8_t BRIGHT_ON = 150, BRIGHT_DIM = 20;

enum class Power : uint8_t { On, Dim, Off };

M5Canvas canvas(&M5.Display);
bool haveCanvas = false;
int page = 0;
Power power = Power::On;
uint32_t lastActivity = 0, lastFrame = 0;
char toastMsg[40] = {0};
uint32_t toastAt = 0;
uint32_t shownPasskey = 0;

void setPower(Power p) {
  if (p == power) return;
  if (power == Power::Off) M5.Display.wakeup();
  power = p;
  switch (p) {
    case Power::On: M5.Display.setBrightness(BRIGHT_ON); break;
    case Power::Dim: M5.Display.setBrightness(BRIGHT_DIM); break;
    case Power::Off:
      M5.Display.setBrightness(0);
      M5.Display.sleep();
      break;
  }
}

void fmtBytes(char* out, size_t n, uint32_t b) {
  if (b < 1024) snprintf(out, n, "%u o", (unsigned)b);
  else if (b < 1024UL * 1024) snprintf(out, n, "%.1f Ko", b / 1024.0f);
  else snprintf(out, n, "%.2f Mo", b / (1024.0f * 1024.0f));
}

// Barre du haut : heure, état de la liaison, batterie.
void drawHeader(const char* title) {
  canvas.fillRect(0, 0, W, 18, 0x18E3);
  canvas.setFont(&fonts::Font2);
  canvas.setTextColor(TFT_WHITE);
  canvas.setTextDatum(textdatum_t::middle_left);
  canvas.drawString(title, 4, 9);

  char buf[16];
  if (g.timeValid) {
    time_t t = time(nullptr);
    struct tm lt;
    localtime_r(&t, &lt);
    snprintf(buf, sizeof buf, "%02d:%02d", lt.tm_hour, lt.tm_min);
  } else {
    strcpy(buf, "--:--");
  }
  canvas.setTextDatum(textdatum_t::middle_center);
  canvas.drawString(buf, 120, 9);

  // Liaison iPhone : gris = rien, orange = connecté sans chiffrement, vert = sécurisé.
  uint16_t lc = !g.linkConnected ? TFT_DARKGREY : (g.linkSecure ? TFT_GREEN : TFT_ORANGE);
  canvas.fillCircle(166, 9, 4, lc);

  int pct = M5.Power.getBatteryLevel();
  if (pct < 0) pct = 0;
  if (pct > 100) pct = 100;
  bool charging = M5.Power.isCharging() == m5::Power_Class::is_charging_t::is_charging;
  uint16_t bc = pct <= 15 ? TFT_RED : (pct <= 35 ? TFT_YELLOW : TFT_GREEN);
  canvas.drawRect(203, 4, 30, 11, TFT_WHITE);
  canvas.fillRect(233, 7, 2, 5, TFT_WHITE);
  canvas.fillRect(205, 6, 26 * pct / 100, 7, bc);
  if (charging) canvas.fillTriangle(186, 9, 194, 4, 194, 14, TFT_YELLOW);
  else {
    snprintf(buf, sizeof buf, "%d", pct);
    canvas.setTextDatum(textdatum_t::middle_right);
    canvas.setFont(&fonts::Font0);
    canvas.drawString(buf, 200, 9);
  }
}

void drawFooter(const char* hint) {
  canvas.setFont(&fonts::Font0);
  canvas.setTextDatum(textdatum_t::bottom_left);
  bool toasting = toastMsg[0] && millis() - toastAt < TOAST_MS;
  if (toasting) {
    canvas.fillRect(0, H - 13, W, 13, TFT_NAVY);
    canvas.setTextColor(TFT_WHITE);
    canvas.drawString(toastMsg, 4, H - 2);
  } else {
    canvas.setTextColor(TFT_DARKGREY);
    canvas.drawString(hint, 4, H - 2);
  }
}

void row(int y, const char* label, const char* value, uint16_t color = TFT_WHITE) {
  canvas.setFont(&fonts::Font2);
  canvas.setTextDatum(textdatum_t::top_left);
  canvas.setTextColor(TFT_LIGHTGREY);
  canvas.drawString(label, 6, y);
  canvas.setTextColor(color);
  canvas.drawString(value, 78, y);
}

void drawSummary() {
  drawHeader("Radar");
  char buf[48], b2[16];

  const char* st = !g.scanning ? "ARRET" : (g.eco ? "ECO" : "ACTIF");
  uint16_t sc = !g.scanning ? TFT_RED : (g.eco ? TFT_YELLOW : TFT_GREEN);
  row(22, "Scan", st, sc);

  snprintf(buf, sizeof buf, "%u  (%u proches)", (unsigned)g.wifiSeen,
           (unsigned)Dedup::countRecent(Dedup::KIND_WIFI, 60000));
  row(40, "Wi-Fi", buf);
  snprintf(buf, sizeof buf, "%u  (%u proches)", (unsigned)g.bleSeen,
           (unsigned)Dedup::countRecent(Dedup::KIND_BLE, 60000));
  row(58, "Bluetooth", buf);

  const char* link = !g.linkConnected ? "deconnecte" : (g.linkSecure ? (g.linkSubscribed ? "connecte" : "connecte, en attente") : "appairage...");
  row(76, "iPhone", link, g.linkConnected ? (g.linkSecure ? TFT_GREEN : TFT_ORANGE) : TFT_DARKGREY);

  fmtBytes(b2, sizeof b2, Store::backlogBytes());
  row(94, "En attente", b2, Store::backlogBytes() ? TFT_YELLOW : TFT_WHITE);

  // Les émissions actives sont toujours visibles, quelle que soit la page.
  if (g.beaconOn || g.apOn) {
    snprintf(buf, sizeof buf, "EMISSION:%s%s", g.beaconOn ? " balise" : "", g.apOn ? " AP" : "");
    canvas.setFont(&fonts::Font0);
    canvas.setTextDatum(textdatum_t::top_right);
    canvas.setTextColor(TFT_MAGENTA);
    canvas.drawString(buf, W - 4, 113);
  }
  drawFooter("A: page   B: scan on/off");
}

void drawSpectrum() {
  drawHeader("Spectre 2,4 GHz");
  constexpr int top = 24, bottom = 108, gh = bottom - top;

  if (!g.nrfOk) {
    canvas.setFont(&fonts::Font2);
    canvas.setTextColor(TFT_DARKGREY);
    canvas.setTextDatum(textdatum_t::middle_center);
    canvas.drawString("NRF24 non detecte", W / 2, 60);
    canvas.drawString("(voir tools/nrf_probe)", W / 2, 80);
    drawFooter("A: page   B: scan on/off");
    return;
  }

  // Repères : canaux Wi-Fi 1/6/11 et canaux d'annonce BLE 37/38/39.
  struct Mark { int ch; const char* label; uint16_t color; };
  static const Mark marks[] = {
      {12, "1", TFT_CYAN}, {37, "6", TFT_CYAN}, {62, "11", TFT_CYAN},
      {2, "", TFT_BLUE}, {26, "", TFT_BLUE}, {80, "", TFT_BLUE},
  };
  canvas.setFont(&fonts::Font0);
  canvas.setTextDatum(textdatum_t::top_center);
  for (const Mark& m : marks) {
    int x = 2 + m.ch * (W - 4) / proto::NRF_CHANNELS;
    for (int y = top; y < bottom; y += 4) canvas.drawPixel(x, y, m.color);
    if (m.label[0]) {
      canvas.setTextColor(m.color);
      canvas.drawString(m.label, x, bottom + 2);
    }
  }

  bool stale = !g.spectrumAt || millis() - g.spectrumAt > (g.eco ? 25000UL : 6000UL);
  for (int c = 0; c < proto::NRF_CHANNELS; ++c) {
    int x0 = 2 + c * (W - 4) / proto::NRF_CHANNELS;
    int x1 = 2 + (c + 1) * (W - 4) / proto::NRF_CHANNELS;
    uint8_t v = g.spectrum[c];
    int h = v ? max(1, v * gh / 255) : 0;
    uint16_t col = stale ? TFT_DARKGREY : (v > 160 ? TFT_RED : (v > 60 ? TFT_YELLOW : TFT_GREEN));
    if (h) canvas.fillRect(x0, bottom - h, max(1, x1 - x0), h, col);
  }
  canvas.drawFastHLine(0, bottom, W, TFT_DARKGREY);

  canvas.setTextColor(TFT_DARKGREY);
  canvas.setTextDatum(textdatum_t::top_left);
  canvas.drawString("2400", 2, bottom + 2);
  canvas.setTextDatum(textdatum_t::top_right);
  canvas.drawString("2525 MHz", W - 2, bottom + 2);
  if (stale) {
    canvas.setTextDatum(textdatum_t::top_center);
    canvas.drawString(g.scanning ? "mesure en cours..." : "scan arrete", W / 2, top);
  }
  drawFooter("Wi-Fi 1/6/11 en cyan, annonces BLE en bleu");
}

void drawEmission() {
  drawHeader("Emission");
  char buf[48];

  row(24, "Balise", g.beaconOn ? "ACTIVE" : "coupee", g.beaconOn ? TFT_MAGENTA : TFT_DARKGREY);
  if (g.beaconOn) row(42, "", g.beaconMsg);

  row(64, "AP test", g.apOn ? "ACTIF" : "coupe", g.apOn ? TFT_MAGENTA : TFT_DARKGREY);
  if (g.apOn) {
    row(82, "", g.apSsid);
    snprintf(buf, sizeof buf, "canal %u, %u client(s)", g.apChannel, g.apClients);
    row(100, "", buf);
  }
  drawFooter("Commandes depuis l'app iPhone");
}

// Code d'appairage : affiché en grand tant que l'iPhone ne l'a pas validé.
void drawPasskey(uint32_t pk) {
  canvas.fillScreen(TFT_BLACK);
  canvas.setTextColor(TFT_WHITE);
  canvas.setTextDatum(textdatum_t::top_center);
  canvas.setFont(&fonts::Font2);
  canvas.drawString("Code d'appairage iPhone", W / 2, 12);
  char buf[8];
  snprintf(buf, sizeof buf, "%06u", (unsigned)pk);
  canvas.setFont(&fonts::Font7);
  canvas.setTextColor(TFT_GREEN);
  canvas.setTextDatum(textdatum_t::middle_center);
  canvas.drawString(buf, W / 2, 75);
}

void render() {
  canvas.fillScreen(TFT_BLACK);
  uint32_t pk = g.passkey;
  if (pk && !g.linkSecure) drawPasskey(pk);
  else if (page == 0) drawSummary();
  else if (page == 1) drawSpectrum();
  else drawEmission();
  canvas.pushSprite(0, 0);
}

// Sans sprite (mémoire insuffisante) : écran minimal dessiné directement.
void renderDirect() {
  auto& d = M5.Display;
  d.startWrite();
  d.fillRect(0, 0, W, 40, TFT_BLACK);
  d.setFont(&fonts::Font2);
  d.setTextColor(TFT_WHITE, TFT_BLACK);
  d.setTextDatum(textdatum_t::top_left);
  char buf[48];
  uint32_t pk = g.passkey;
  if (pk && !g.linkSecure) snprintf(buf, sizeof buf, "Code: %06u", (unsigned)pk);
  else snprintf(buf, sizeof buf, "WiFi %u  BLE %u", (unsigned)g.wifiSeen, (unsigned)g.bleSeen);
  d.drawString(buf, 4, 4);
  d.endWrite();
}
}  // namespace

void begin() {
  M5.Display.setRotation(1);  // paysage, boutons à droite
  M5.Display.setBrightness(BRIGHT_ON);
  M5.Display.fillScreen(TFT_BLACK);
  canvas.setColorDepth(8);
  canvas.setPsram(true);
  haveCanvas = canvas.createSprite(W, H) != nullptr;
  if (!haveCanvas) {
    canvas.setPsram(false);
    haveCanvas = canvas.createSprite(W, H) != nullptr;
  }
  lastActivity = millis();
}

void service() {
  uint32_t now = millis();

  // Un nouveau code d'appairage rallume l'écran.
  uint32_t pk = g.passkey;
  if (pk != shownPasskey) {
    shownPasskey = pk;
    if (pk) wake();
  }
  bool pairing = pk && !g.linkSecure;

  if (!pairing) {
    uint32_t idle = now - lastActivity;
    if (idle >= 2 * SCREEN_DIM_MS) setPower(Power::Off);
    else if (idle >= SCREEN_DIM_MS) setPower(Power::Dim);
  }
  if (power == Power::Off) return;

  if (now - lastFrame < FRAME_MS) return;
  lastFrame = now;
  if (haveCanvas) render();
  else renderDirect();
}

void wake() {
  lastActivity = millis();
  setPower(Power::On);
  lastFrame = 0;  // redessine tout de suite
}

void nextPage() {
  page = (page + 1) % PAGES;
  wake();
}

bool isDimmed() { return power != Power::On; }

void toast(const char* msg) {
  strlcpy(toastMsg, msg, sizeof toastMsg);
  toastAt = millis();
  wake();
}
}  // namespace UI
