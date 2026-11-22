// ============================================================================
//  Stroop Game - ESP32 board
//  Reads the 8 arcade buttons, runs the game (game.h), makes its own Wi-Fi,
//  and sends the game state to the Flutter app over a WebSocket.
//
//  Test without buttons: open the Serial Monitor (115200 baud) and type
//    s = START   x = RESTART   r b g y o p = RED BLUE GREEN YELLOW ORANGE PURPLE
// ============================================================================
#include <Arduino.h>
#include <WiFi.h>
#include <WebSocketsServer.h>
#include <ArduinoJson.h>
#include "config.h"
#include "game.h"

using namespace sg;

Game game;
WebSocketsServer ws(WS_PORT);

const uint8_t PINS[NBUTTONS] = {PIN_RED, PIN_BLUE, PIN_GREEN, PIN_YELLOW, PIN_ORANGE, PIN_PURPLE, PIN_START, PIN_RESTART};
const char* const BTN_NAME[NBUTTONS] = {"RED", "BLUE", "GREEN", "YELLOW", "ORANGE", "PURPLE", "START", "RESTART"};

// ---------------- button reading with debounce ----------------
struct Debounce {
  bool stable;     // true = released (INPUT_PULLUP reads HIGH)
  bool last;
  uint32_t since;
};
Debounce db[NBUTTONS];

const char* screenName(Screen s) {
  switch (s) {
    case MENU: return "menu";
    case MODE_SELECT: return "mode";
    case COUNTDOWN: return "count";
    case PLAYING: return "game";
    case RESULTS: return "res";
  }
  return "menu";
}

const char* modeName(Mode m) {
  switch (m) {
    case STANDARD: return "std";
    case HIGH_CONFLICT: return "hc";
    case LAB: return "lab";
    default: return "none";
  }
}

const char* motionName(Motion m) {
  switch (m) {
    case SCROLL: return "scroll";
    case FLASH: return "flash";
    case VANISH: return "vanish";
    default: return "none";
  }
}

// ---------------- the message sent to the app ----------------
String buildState() {
  JsonDocument doc;
  const uint32_t now = millis();
  doc["t"] = "s";
  doc["v"] = game.version;
  doc["screen"] = screenName(game.screen);
  doc["mode"] = modeName(game.mode);
  doc["level"] = game.level;
  doc["count"] = game.count;
  doc["time"] = game.timeLeft(now);
  doc["ok"] = game.correct;
  doc["bad"] = game.wrong;
  doc["total"] = game.total();
  doc["player"] = game.player;        // name typed in the app ("" = none yet)
  doc["nn"] = game.needNameSeq;       // START pressed without a name (the app shows a reminder)

  JsonObject c = doc["cfg"].to<JsonObject>();
  c["round"] = game.cfg.roundSec;
  c["multi"] = game.cfg.multi;
  c["reverse"] = game.cfg.reverse;
  c["prime"] = game.cfg.prime;
  c["motion"] = game.cfg.motion;
  c["invert"] = game.cfg.invert;
  c["voice"] = game.cfg.voice;

  if (game.screen == PLAYING) {
    const Item& it = game.cur;
    JsonObject o = doc["item"].to<JsonObject>();
    o["seq"] = it.seq;
    o["rule"] = it.rule == RULE_INK ? "ink" : "word";
    o["target"] = it.target;
    o["rot"] = it.rot;
    o["mirror"] = it.mirror;
    o["warp"] = it.warp;
    o["motion"] = motionName(it.motion);
    o["primed"] = it.primed;
    JsonArray words = o["words"].to<JsonArray>();
    for (uint8_t i = 0; i < it.n; i++) {
      JsonObject w = words.add<JsonObject>();
      w["text"] = game.text(i);
      w["ink"] = COLOR_ID[it.w[i].ink];
    }
    JsonArray say = o["say"].to<JsonArray>();      // voice distractors for the phone to speak
    for (uint8_t i = 0; i < it.nsay; i++) say.add(COLOR_ID[it.say[i]]);
  }

  JsonObject a = doc["ans"].to<JsonObject>();
  a["seq"] = game.answerSeq;
  a["ok"] = game.lastOk;
  a["pressed"] = COLOR_ID[game.lastPressed];
  a["answer"] = COLOR_ID[game.lastAnswer];

  JsonObject l = doc["lvl"].to<JsonObject>();
  l["seq"] = game.levelSeq;
  l["dir"] = game.levelDir;

  String out;
  serializeJson(doc, out);
  return out;
}

// ---------------- a button press (from the board, the Serial Monitor, or the app's test buttons) ----------------
void pressButton(uint8_t b) {
  if (b >= NBUTTONS) return;
  const uint32_t answersBefore = game.answerSeq;
  const uint8_t levelBefore = game.level;
  if (!game.press((Button)b, millis())) {
    Serial.printf("[BUTTON] %s ignored (%s)\n", BTN_NAME[b],
                  game.screen == MENU ? "enter a player name in the app first" : "too soon after the new word: double tap");
    return;
  }
  Serial.printf("[BUTTON] %s", BTN_NAME[b]);
  if (game.answerSeq != answersBefore)
    Serial.printf(" -> %s (correct %u, wrong %u)", game.lastOk ? "correct" : "wrong", game.correct, game.wrong);
  if (game.level != levelBefore) Serial.printf(" -> level %u", game.level);
  if (game.answerSeq != answersBefore && game.cur.nsay > 0) {     // voices for the next word
    Serial.print("   | voices:");
    for (uint8_t i = 0; i < game.cur.nsay; i++) Serial.printf(" %s", COLOR_ID[game.cur.say[i]]);
  }
  Serial.println();
}

void readButtons(uint32_t now) {
  for (uint8_t i = 0; i < NBUTTONS; i++) {
    const bool r = digitalRead(PINS[i]);
    if (r != db[i].last) { db[i].last = r; db[i].since = now; }
    if (now - db[i].since >= DEBOUNCE_MS && r != db[i].stable) {
      db[i].stable = r;
      if (!r) pressButton(i);            // LOW = pressed
    }
  }
}

void readSerial() {
  while (Serial.available()) {
    const char c = (char)tolower(Serial.read());
    const char* keys = "rbgyopsx";
    const char* p = strchr(keys, c);
    if (c && p) pressButton((uint8_t)(p - keys));
  }
}

int8_t buttonFromName(const char* n) {
  if (!n) return -1;
  for (uint8_t i = 0; i < NBUTTONS; i++)
    if (strcasecmp(n, BTN_NAME[i]) == 0) return (int8_t)i;
  return -1;
}

// ---------------- messages from the app ----------------
void handleCommand(uint8_t num, uint8_t* payload, size_t length) {
  JsonDocument doc;
  if (deserializeJson(doc, (const char*)payload, length)) return;   // not valid JSON
  const char* cmd = doc["cmd"] | "";
  if (strcmp(cmd, "hello") == 0) {
    String s = buildState();
    ws.sendTXT(num, s);
  } else if (strcmp(cmd, "cfg") == 0) {
    Config c = game.cfg;
    c.roundSec = doc["round"] | c.roundSec;
    c.multi = doc["multi"] | c.multi;
    c.reverse = doc["reverse"] | c.reverse;
    c.prime = doc["prime"] | c.prime;
    c.motion = doc["motion"] | c.motion;
    c.invert = doc["invert"] | c.invert;
    c.voice = doc["voice"] | c.voice;
    game.setConfig(c);
    Serial.printf("[APP] settings: round %u s, multi %d, reverse %d, prime %d, motion %d, invert %d, voice %d\n",
                  game.cfg.roundSec, game.cfg.multi, game.cfg.reverse, game.cfg.prime, game.cfg.motion,
                  game.cfg.invert, game.cfg.voice);
  } else if (strcmp(cmd, "name") == 0) {           // player name for the leaderboards
    game.setPlayer(doc["name"] | "");
    Serial.printf("[APP] player: \"%s\"\n", game.player);
  } else if (strcmp(cmd, "press") == 0) {           // test buttons in the app
    const int8_t b = buttonFromName(doc["b"] | "");
    if (b < 0) return;
    // FIX: the app sends the number of the word the player was looking at
    // ("seq"). If a new word has appeared since (the press was late or doubled),
    // the press was meant for the old word, so it is ignored, not counted wrong.
    if (b < NCOLORS && game.screen == PLAYING && doc["seq"].is<long>()) {
      const long seq = doc["seq"].as<long>();
      if (seq >= 0 && (uint32_t)seq != game.cur.seq) {
        Serial.printf("[APP] %s ignored (meant for an older word)\n", BTN_NAME[b]);
        return;
      }
    }
    pressButton((uint8_t)b);
  }
}

void onWebSocket(uint8_t num, WStype_t type, uint8_t* payload, size_t length) {
  switch (type) {
    case WStype_CONNECTED: {
      Serial.printf("[APP] phone connected (#%u)\n", num);
      String s = buildState();
      ws.sendTXT(num, s);
      break;
    }
    case WStype_DISCONNECTED:
      Serial.printf("[APP] phone disconnected (#%u)\n", num);
      break;
    case WStype_TEXT:
      handleCommand(num, payload, length);
      break;
    default:
      break;
  }
}

// ---------------- setup and loop ----------------
uint32_t sentVersion = 0xFFFFFFFF;
uint16_t sentTime = 0xFFFF;

void setup() {
  Serial.begin(115200);
  delay(200);
  for (uint8_t i = 0; i < NBUTTONS; i++) {
    pinMode(PINS[i], INPUT_PULLUP);
    db[i].stable = db[i].last = digitalRead(PINS[i]);
    db[i].since = 0;
  }
  pinMode(PIN_LED, OUTPUT);
  digitalWrite(PIN_LED, LOW);

  WiFi.persistent(false);
  WiFi.mode(WIFI_AP);
  WiFi.softAPConfig(IPAddress(192, 168, 4, 1), IPAddress(192, 168, 4, 1), IPAddress(255, 255, 255, 0));
  WiFi.softAP(WIFI_NAME, WIFI_PASSWORD, WIFI_CHANNEL, 0, 4);
  WiFi.setSleep(false);   // no Wi-Fi power saving: steadier, faster replies to the phone

  game.seed((uint32_t)random(1, 0x7FFFFFFF) ^ micros());
  ws.begin();
  ws.onEvent(onWebSocket);
  ws.enableHeartbeat(5000, 3000, 2);     // notices a phone that left without saying goodbye

  Serial.println();
  Serial.println("Stroop Game board ready");
  Serial.printf("Wi-Fi: %s   password: %s   app address: ws://%s:%d\n",
                WIFI_NAME, WIFI_PASSWORD, WiFi.softAPIP().toString().c_str(), WS_PORT);
  Serial.println("Test keys: s=START x=RESTART r b g y o p = color buttons");
}

void loop() {
  ws.loop();
  const uint32_t now = millis();
  readButtons(now);
  readSerial();
  game.update(now);

  // send the state to the app whenever something changes or the timer ticks
  const uint16_t t = game.timeLeft(now);
  if (game.version != sentVersion || t != sentTime) {
    sentVersion = game.version;
    sentTime = t;
    String s = buildState();
    ws.broadcastTXT(s);
  }
  digitalWrite(PIN_LED, ws.connectedClients() > 0 ? HIGH : LOW);
  delay(1);
}