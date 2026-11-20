#include <M5Unified.h>
#include <sys/time.h>

#include "app.h"

AppState g;

uint32_t nowUnix() {
  time_t t = time(nullptr);
  return (g.timeValid && t > 1700000000) ? (uint32_t)t : 0;
}

static void restoreTimeFromRtc() {
  if (!M5.Rtc.isEnabled()) return;
  auto dt = M5.Rtc.getDateTime();
  if (dt.date.year < 2025) return;  // RTC jamais réglée ou batterie vidée
  struct tm tm = {};
  tm.tm_year = dt.date.year - 1900;
  tm.tm_mon = dt.date.month - 1;
  tm.tm_mday = dt.date.date;
  tm.tm_hour = dt.time.hours;
  tm.tm_min = dt.time.minutes;
  tm.tm_sec = dt.time.seconds;
  // La RTC est en UTC : mktime() interprète l'heure locale, on passe donc par TZ=UTC.
  setenv("TZ", "UTC0", 1);
  tzset();
  time_t t = mktime(&tm);
  setenv("TZ", TZ_INFO, 1);
  tzset();
  struct timeval tv = {t, 0};
  settimeofday(&tv, nullptr);
  g.timeValid = true;
}

void setup() {
  auto cfg = M5.config();
  cfg.serial_baudrate = 115200;
  cfg.internal_mic = false;  // G0 sert au NRF24, pas au micro
  M5.begin(cfg);             // M5Unified maintient GPIO4 (HOLD) à 1 : l'appareil reste allumé sur batterie

  setenv("TZ", TZ_INFO, 1);
  tzset();
  restoreTimeFromRtc();

  UI::begin();
  Store::begin();
  Link::begin();
  BleScan::begin();
  WifiScan::begin();
  g.nrfOk = Nrf::begin();
  Serial.printf("[boot] M5Radar pret, NRF24 %s, heure %s\n", g.nrfOk ? "OK" : "absent",
                g.timeValid ? "OK" : "inconnue");
}

void loop() {
  M5.update();

  if (M5.BtnA.wasClicked()) {
    if (UI::isDimmed()) UI::wake();
    else UI::nextPage();
  }
  if (M5.BtnB.wasClicked()) {
    if (UI::isDimmed()) {
      UI::wake();
    } else {
      g.scanning = !g.scanning;
      if (!g.scanning) BleScan::pause();
      UI::wake();
    }
  }
  if (M5.BtnPWR.wasClicked()) UI::wake();
  if (M5.BtnPWR.pressedFor(2000)) {
    M5.Display.wakeup();
    M5.Display.setBrightness(80);
    M5.Display.fillScreen(TFT_BLACK);
    M5.Display.setTextColor(TFT_WHITE);
    M5.Display.drawCenterString("Extinction...", 120, 60, &fonts::Font2);
    delay(800);
    M5.Power.powerOff();
  }

  Link::service();
  WifiScan::service();
  BleScan::service();
  Nrf::service();
  Store::service();
  Emit::service();
  UI::service();
  delay(2);
}

// Applique l'heure reçue de l'iPhone au système et à la RTC (en UTC).
void applyUnixTime(uint32_t t) {
  struct timeval tv = {(time_t)t, 0};
  settimeofday(&tv, nullptr);
  g.timeValid = true;
  if (M5.Rtc.isEnabled()) {
    time_t tt = t;
    struct tm utc;
    gmtime_r(&tt, &utc);
    m5::rtc_datetime_t dt;
    dt.date.year = utc.tm_year + 1900;
    dt.date.month = utc.tm_mon + 1;
    dt.date.date = utc.tm_mday;
    dt.date.weekDay = utc.tm_wday;
    dt.time.hours = utc.tm_hour;
    dt.time.minutes = utc.tm_min;
    dt.time.seconds = utc.tm_sec;
    M5.Rtc.setDateTime(dt);
  }
}
