// ============================================================================
//  Stroop Game - game rules (no hardware code in this file)
//
//  This file holds the whole game: screens, modes, levels, word choice,
//  the Modifier Lab, the 60-second round, and the correct/wrong counts.
//  The sketch (main.cpp) only feeds it button presses and the time, and
//  sends what it decides to the phone. Because it has no hardware code,
//  it was also tested on a computer.
// ============================================================================
#pragma once
#include <stdint.h>
#include <string.h>

namespace sg {

// ----- the six answer colors (same order as the buttons) -----
enum Color : uint8_t { RED, BLUE, GREEN, YELLOW, ORANGE, PURPLE, NCOLORS };
static const char* const COLOR_ID[NCOLORS]   = {"red", "blue", "green", "yellow", "orange", "purple"};
static const char* const COLOR_WORD[NCOLORS] = {"RED", "BLUE", "GREEN", "YELLOW", "ORANGE", "PURPLE"};

// emotional words used in High-Conflict Level 3 and 4
static const uint8_t NEMO = 8;
static const char* const EMO_WORD[NEMO] = {"ANGER", "FEAR", "SAD", "HATE", "PANIC", "GRIEF", "RAGE", "DREAD"};

// ----- buttons on the board -----
enum Button : uint8_t { BTN_RED, BTN_BLUE, BTN_GREEN, BTN_YELLOW, BTN_ORANGE, BTN_PURPLE, BTN_START, BTN_RESTART, NBUTTONS };

enum Screen : uint8_t { MENU, MODE_SELECT, COUNTDOWN, PLAYING, RESULTS };
enum Mode : uint8_t { NO_MODE, STANDARD, HIGH_CONFLICT, LAB };
enum Rule : uint8_t { RULE_INK, RULE_WORD };           // name the ink color / read the word
enum Motion : uint8_t { STILL, SCROLL, FLASH, VANISH };

static const uint32_t COUNT_STEP_MS = 800;              // 3-2-1 countdown speed

// FIX (double inputs): nobody can read a new word and answer it in under
// 150 ms, so a color press that comes sooner after the word appeared is a
// double tap or a bouncing button meant for the PREVIOUS word. It is ignored
// instead of being counted as wrong on the new word.
static const uint32_t MIN_ANSWER_MS = 150;

static const uint8_t MAX_NAME = 16;              // longest player name

struct Word {
  int8_t emo;      // -1 = a color word, otherwise index into EMO_WORD
  uint8_t said;    // the color the word spells (only when emo < 0)
  uint8_t ink;     // the color it is printed in
};

struct Item {
  Word w[3];
  uint8_t n;         // 1 word, or 2-3 words (Double / Triple Trouble)
  uint8_t target;    // which word to answer
  Rule rule;
  uint16_t rot;      // 0, 90 or 180 degrees
  uint8_t mirror;    // 0 none, 1 left-right, 2 up-down
  uint8_t warp;      // 0 none, 1..3 warp style
  Motion motion;
  bool primed;       // answer = the color ignored in the previous word
  uint8_t answer;    // the correct button color
  uint8_t nsay;      // how many voices the phone speaks for this word (0..3)
  uint8_t say[3];    // the color each voice says (distractors)
  uint32_t seq;      // goes up for every new word
};

struct Config {          // settings the phone can change (Modifier Lab + round length + voices)
  uint8_t roundSec;
  bool multi, reverse, prime, motion, invert;
  bool voice;            // voice distractors in High-Conflict and Modifier Lab
};

// Voice distractors: % chance that a word gets voices, by level 1..4 (index 0 unused)
static const uint8_t HC_VOICE_CHANCE[5]  = {0, 20, 40, 60, 80};
static const uint8_t LAB_VOICE_CHANCE[5] = {0, 70, 85, 100, 100};
static const uint8_t VOICE_TRUTH = 20;   // % of voices that say the correct color (so voices can't be trusted)

class Game {
 public:
  // ----- state (read it; change it only with the functions below) -----
  Screen screen;
  Mode mode;
  uint8_t level;           // High-Conflict and Modifier Lab level 1..4
  int8_t run;              // +n = n correct in a row, -n = n wrong in a row
  uint16_t correct, wrong;
  uint8_t count;           // countdown number 3, 2, 1
  uint32_t stepAt;         // when the countdown number last changed
  uint32_t roundEnd;       // millis() when the round ends
  Item cur;
  uint32_t answerSeq;      // goes up for every answer
  bool lastOk;
  uint8_t lastPressed, lastAnswer;
  uint32_t levelSeq;       // goes up for every level change
  int8_t levelDir;         // +1 up, -1 down
  uint32_t version;        // goes up on every change (main.cpp sends the state when it changes)
  uint32_t itemAt;         // millis() when the current word appeared
  char player[MAX_NAME + 1];  // player name typed in the app ("" = none yet)
  uint32_t needNameSeq;    // goes up when START is pressed before a name was entered
  Config cfg;

  Game() : rng(2463534242u) {
    cfg.roundSec = 60; cfg.multi = cfg.reverse = cfg.prime = cfg.motion = cfg.invert = true;
    cfg.voice = true;
    cur.seq = 0; answerSeq = levelSeq = 0; version = 0; levelDir = 0;
    player[0] = 0; needNameSeq = 0;
    lastOk = false; lastPressed = lastAnswer = 0; roundEnd = stepAt = itemAt = 0;
    toMenu();
  }

  void seed(uint32_t s) { rng = s ? s : 2463534242u; }

  // A button was pressed
  // Returns false if the press was ignored (too soon after a new word).
  bool press(Button b, uint32_t now) {
    // FIX: bring the clock up to date first. Before, a press that arrived just
    // after the time ran out (but before loop() called update) still counted.
    update(now);
    switch (screen) {
      case MENU:
        if (b == BTN_START) {
          // the player must type a name in the app first (for the leaderboards)
          if (player[0] == 0) { needNameSeq++; version++; return false; }
          screen = MODE_SELECT; version++;
        }
        break;
      case MODE_SELECT:
        if (b == BTN_GREEN) startRound(STANDARD, now);
        else if (b == BTN_RED) startRound(HIGH_CONFLICT, now);
        else if (b == BTN_BLUE) startRound(LAB, now);
        else if (b == BTN_RESTART) toMenu();
        break;
      case COUNTDOWN:
        if (b == BTN_RESTART) toMenu();
        break;
      case PLAYING:
        if (b == BTN_RESTART) toMenu();
        else if ((uint8_t)b < (uint8_t)NCOLORS) {
          if (now - itemAt < MIN_ANSWER_MS) return false;   // double tap / bounce
          answer((uint8_t)b, now);
        }
        break;
      case RESULTS:
        // round finished: the next player enters their own name
        if (b == BTN_START || b == BTN_RESTART) { player[0] = 0; toMenu(); }
        break;
    }
    return true;
  }

  // Call often: runs the countdown and ends the round when time is up
  void update(uint32_t now) {
    if (screen == COUNTDOWN && now - stepAt >= COUNT_STEP_MS) {
      stepAt = now;
      if (count > 1) { count--; version++; }
      else {
        screen = PLAYING;
        roundEnd = now + (uint32_t)cfg.roundSec * 1000UL;
        nextItem();
        itemAt = now;
        version++;
      }
    }
    if (screen == PLAYING && (int32_t)(now - roundEnd) >= 0) { screen = RESULTS; version++; }
  }

  uint16_t timeLeft(uint32_t now) const {
    if (screen == COUNTDOWN || screen == MODE_SELECT || screen == MENU) return cfg.roundSec;
    if (screen != PLAYING) return 0;
    int32_t ms = (int32_t)(roundEnd - now);
    return ms <= 0 ? 0 : (uint16_t)((ms + 999) / 1000);
  }

  uint16_t total() const { return correct + wrong; }

  // The player's name from the app. Only on the menu and mode screens, so the
  // name can't change during a round. Keeps letters, digits, space . _ -
  bool setPlayer(const char* name) {
    if (screen != MENU && screen != MODE_SELECT) return false;
    char out[MAX_NAME + 1]; uint8_t n = 0;
    for (const char* p = name ? name : ""; *p && n < MAX_NAME; p++) {
      const char c = *p;
      const bool ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
                      c == ' ' || c == '.' || c == '_' || c == '-';
      if (ok && !(c == ' ' && (n == 0 || out[n - 1] == ' '))) out[n++] = c;   // no leading/double spaces
    }
    while (n > 0 && out[n - 1] == ' ') n--;                                    // no trailing space
    out[n] = 0;
    memcpy(player, out, n + 1);
    version++;
    return n > 0;
  }

  void setConfig(const Config& c) {
    cfg = c;
    if (cfg.roundSec != 20 && cfg.roundSec != 60) cfg.roundSec = 60;
    version++;
  }

  // Text of word i of the current item
  const char* text(uint8_t i) const {
    const Word& w = cur.w[i];
    return w.emo >= 0 ? EMO_WORD[w.emo] : COLOR_WORD[w.said];
  }

 private:
  uint32_t rng;
  int8_t prevIgnored;   // color ignored in the previous word (-1 = none)
  int8_t lastText;      // last target text: 0..5 color word, 10+i emotional word

  uint32_t rnd() { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng; }
  bool chance(uint16_t percent) { return (rnd() % 100) < percent; }
  uint8_t pick(uint8_t n) { return (uint8_t)(rnd() % n); }
  uint8_t otherThan(uint8_t c) { uint8_t o = pick(NCOLORS - 1); return o >= c ? o + 1 : o; }
  uint8_t otherThan2(uint8_t a, int8_t b) {          // a color that is not a and not b
    for (;;) { uint8_t o = pick(NCOLORS); if (o != a && o != b) return o; }
  }

  void toMenu() {
    screen = MENU; mode = NO_MODE; level = 1; run = 0; correct = wrong = 0; count = 3;
    prevIgnored = -1; lastText = -1;
    version++;
  }

  void startRound(Mode m, uint32_t now) {
    mode = m; level = 1; run = 0; correct = wrong = 0;
    prevIgnored = -1; lastText = -1;
    screen = COUNTDOWN; count = 3; stepAt = now;
    version++;
  }

  void answer(uint8_t pressed, uint32_t now) {
    const bool ok = (pressed == cur.answer);
    if (ok) { correct++; run = run > 0 ? run + 1 : 1; }
    else    { wrong++;   run = run < 0 ? run - 1 : -1; }
    lastOk = ok; lastPressed = pressed; lastAnswer = cur.answer; answerSeq++;
    if (mode == HIGH_CONFLICT || mode == LAB) {        // level up after 4 correct, down after 2 wrong
      if (run >= 4) { if (level < 4) { level++; levelDir = 1; levelSeq++; } run = 0; }
      if (run <= -2) { if (level > 1) { level--; levelDir = -1; levelSeq++; } run = 0; }
    }
    nextItem();
    itemAt = now;
    version++;
  }

  void clearItem() {
    cur.n = 1; cur.target = 0; cur.rule = RULE_INK; cur.rot = 0; cur.mirror = 0; cur.warp = 0;
    cur.motion = STILL; cur.primed = false; cur.nsay = 0;
  }

  // Voice distractors (the phone speaks them):
  //   Standard: never.
  //   High-Conflict: more often at higher levels (20/40/60/80%), up to 2 voices at L3, 3 at L4.
  //   Modifier Lab: from level 1 (70/85/100/100%), 1 voice at L1 up to 3 at L4.
  //   (The phone makes Lab voices faster, harsher and overlapping as the level rises.)
  void pickVoices(int8_t trap) {
    cur.nsay = 0;
    if (!cfg.voice || (mode != HIGH_CONFLICT && mode != LAB)) return;
    const uint8_t lv = level < 1 ? 1 : (level > 4 ? 4 : level);
    if (!chance(mode == LAB ? LAB_VOICE_CHANCE[lv] : HC_VOICE_CHANCE[lv])) return;
    uint8_t n = 1;
    if (mode == HIGH_CONFLICT) {
      if (lv == 3) n = 1 + pick(2);
      else if (lv == 4) n = 1 + pick(3);
    } else {
      if (lv == 2) n = 1 + pick(2);
      else if (lv == 3) n = 2 + pick(2);
      else if (lv == 4) n = 3;
    }
    for (uint8_t i = 0; i < n; i++) {
      if (chance(VOICE_TRUTH)) cur.say[i] = cur.answer;                     // sometimes the truth
      else if (i == 0 && trap >= 0 && chance(60)) cur.say[i] = (uint8_t)trap; // the color the eyes are tempted by
      else cur.say[i] = otherThan(cur.answer);
    }
    cur.nsay = n;
  }

  // Standard and High-Conflict words (rules from the proposal)
  void classicItem() {
    const bool hc = (mode == HIGH_CONFLICT);
    const uint8_t mis = hc ? 70 : 50;                  // % of mismatched color words
    Word& w = cur.w[0];
    w.ink = pick(NCOLORS);
    if (hc && level >= 3 && chance(35)) {              // emotional word
      uint8_t e;
      do { e = pick(NEMO); } while (10 + e == lastText);
      w.emo = (int8_t)e; w.said = w.ink;
    } else if (chance(mis)) {                          // mismatched color word
      w.emo = -1; w.said = otherThan2(w.ink, lastText < 10 ? lastText : -1);
    } else {                                           // matching color word
      w.emo = -1; w.said = w.ink;
    }
    if (hc && level >= 2 && chance(50)) cur.rot = chance(50) ? 90 : 180;
    if (hc && level >= 4 && chance(60)) cur.warp = 1 + pick(3);
  }

  // Modifier Lab words
  void labItem() {
    cur.rule = (cfg.reverse && chance(40)) ? RULE_WORD : RULE_INK;
    int8_t want = -1;
    if (cfg.prime && prevIgnored >= 0 && chance(70)) { want = prevIgnored; cur.primed = true; }
    Word& t = cur.w[0];
    t.emo = -1;
    if (cur.rule == RULE_INK) {
      t.ink = want >= 0 ? (uint8_t)want : pick(NCOLORS);
      t.said = chance(80) ? otherThan(t.ink) : t.ink;
    } else {
      t.said = want >= 0 ? (uint8_t)want : pick(NCOLORS);
      t.ink = chance(85) ? otherThan(t.said) : t.said;
    }
    if (cfg.multi && chance(50)) {                     // Double / Triple Trouble
      cur.n = chance(50) ? 2 : 3;
      for (uint8_t i = 1; i < cur.n; i++) {
        cur.w[i].emo = -1; cur.w[i].said = pick(NCOLORS); cur.w[i].ink = otherThan(cur.w[i].said);
      }
      cur.target = pick(cur.n);
      Word tmp = cur.w[0]; cur.w[0] = cur.w[cur.target]; cur.w[cur.target] = tmp;
    }
    if (cfg.invert && chance(50)) {
      switch (pick(4)) {
        case 0: cur.rot = 180; break;
        case 1: cur.rot = 90; break;
        case 2: cur.mirror = 1; break;
        default: cur.mirror = 2; break;
      }
    }
    if (cfg.motion && chance(50)) cur.motion = (Motion)(1 + pick(3));
  }

  void nextItem() {
    clearItem();
    if (mode == LAB) labItem(); else classicItem();
    const Word& t = cur.w[cur.target];
    cur.answer = (cur.rule == RULE_INK) ? t.ink : t.said;
    // the color the player had to ignore this time (used for negative priming next time)
    int8_t ign = (cur.rule == RULE_INK) ? (t.emo < 0 ? (int8_t)t.said : -1) : (int8_t)t.ink;
    prevIgnored = (ign >= 0 && ign != (int8_t)cur.answer) ? ign : -1;
    lastText = t.emo >= 0 ? (int8_t)(10 + t.emo) : (int8_t)t.said;
    pickVoices(prevIgnored);
    cur.seq++;
  }
};

}  // namespace sg