// ============================================================================
//  Stroop Game - pins and settings you may change
// ============================================================================
#pragma once

// ---------- Button pins (ESP32-WROOM-32 DevKit) ----------
// Each arcade button: COM terminal -> GND, NO terminal -> the GPIO below.
// The ESP32's internal pull-up resistors are used, so no resistors are needed.
#define PIN_RED      13
#define PIN_BLUE     14
#define PIN_GREEN    27
#define PIN_YELLOW   26
#define PIN_ORANGE   25
#define PIN_PURPLE   33
#define PIN_START    32
#define PIN_RESTART   4

#define PIN_LED       2      // the ESP32's blue on-board LED: on while the phone is connected

// ---------- Wi-Fi made by the ESP32 ----------
#define WIFI_NAME     "STROOP GAME"
#define WIFI_PASSWORD "stroop123"    // at least 8 characters
#define WIFI_CHANNEL  6
#define WS_PORT       81             // the app connects to ws://192.168.4.1:81

#define DEBOUNCE_MS   25
