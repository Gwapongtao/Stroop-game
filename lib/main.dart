// ============================================================================
//  Stroop Game - phone app (Flutter)
//
//  The phone is the game screen. It joins the ESP32's Wi-Fi ("STROOP-GAME"),
//  connects to ws://192.168.4.1:81, and shows whatever the ESP32 sends.
//  All the game rules run on the ESP32; the buttons on the board are the
//  controls. The gear icon opens Settings (round length, Modifier Lab
//  switches, sounds, and on-screen test buttons).
// ============================================================================
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;

import 'package:app_settings/app_settings.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Address of the ESP32 game board.
const String kBoardUrl = 'ws://192.168.4.1:81';
const String kWifiName = 'STROOP-GAME';
const String kWifiPassword = 'stroop123';

/// Password for clearing the leaderboards (Settings > Clear leaderboards).
const String kAdminPassword = 'stroop123';
const int kMaxNameLength = 16;

/// Background music. Put the files in assets/sounds/ (.mp3 or .wav).
/// Use '' for no music on that part.
const String kMenuMusic = 'menu.mp3'; // app start-up, main menu, mode screen
const String kGameMusic = '';               // during the round, e.g. 'game_music.mp3'
const double kMusicVolume = 1.0;            // 0.0 (silent) to 1.0 (full)
const double kVoiceSpeed = 1.4;             // voice talking speed: 1.0 = original, 1.4 = 40% faster, 1.8 = much faster

// Colors (the six answer colors match the arcade buttons)
const Map<String, Color> kInk = {
  'red': Color(0xFFE2483D),
  'blue': Color(0xFF2F6FE0),
  'green': Color(0xFF1F9E57),
  'pink': Color(0xFFE8459B),
  'orange': Color(0xFFEE7A12),
  'purple': Color(0xFF8B3FD4),
};
const Color kScreenBg = Color(0xFFF6F7FB);
const Color kText = Color(0xFF1F2329);
const Color kMuted = Color(0xFF6B7280);
const Color kCardBorder = Color(0xFFD6DEF5);
const Color kTimeColor = Color(0xFF5054D6);
const Color kOkColor = Color(0xFF10B981);
const Color kBadColor = Color(0xFFE2483D);
const Color kReverse = Color(0xFF8B3FD4);

/// Opens Android's Wi-Fi list on top of the app (Android 10+), or the Wi-Fi settings on older phones.
Future<void> openWifi() async {
  try {
    await AppSettings.openAppSettingsPanel(AppSettingsPanelType.wifi);
  } catch (_) {
    try {
      await AppSettings.openAppSettings(type: AppSettingsType.wifi);
    } catch (_) {}
  }
}

// ---------------------------------------------------------------------------
// Adaptive sizing
// The app is landscape-only, so the screen HEIGHT (shortest side) is what limits
// the layout. kDesignHeight is the height the sizes below were first made for
// (a typical phone). uiScale() grows everything on tablets and shrinks it a
// little on small phones. Use  context.sc(24)  instead of a fixed 24.
// ---------------------------------------------------------------------------
const double kDesignHeight = 392;

double uiScale(BuildContext context) {
  final shortest = MediaQuery.sizeOf(context).shortestSide;
  return (shortest / kDesignHeight).clamp(0.75, 2.4).toDouble();
}

extension AdaptiveSize on BuildContext {
  double sc(double v) => v * uiScale(this);
}

/// Opens the Bluetooth settings (to pair a Bluetooth speaker).
Future<void> openBluetooth() async {
  try {
    await AppSettings.openAppSettings(type: AppSettingsType.bluetooth);
  } catch (_) {}
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const StroopApp());
}

class StroopApp extends StatelessWidget {
  const StroopApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Stroop Game',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF2F6FE0),
        scaffoldBackgroundColor: kScreenBg,
      ),
      home: const GamePage(),
    );
  }
}

// ---------------------------------------------------------------------------
// Small helpers for reading the JSON from the ESP32 safely
// ---------------------------------------------------------------------------
int asInt(dynamic v, [int fallback = 0]) => v is num ? v.toInt() : fallback;
bool asBool(dynamic v) => v == true;
String asStr(dynamic v, [String fallback = '']) => v is String ? v : fallback;
Map<String, dynamic> asMap(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

// ---------------------------------------------------------------------------
// Connection to the ESP32
// ---------------------------------------------------------------------------
class Board extends ChangeNotifier {
  WebSocket? _ws;
  Timer? _retry;
  bool _connecting = false;
  bool _disposed = false;
  bool connected = false;

  /// The latest game state sent by the ESP32.
  Map<String, dynamic> state = {};

  // Events for sounds and effects: ok, bad, tick, go, end, level
  final StreamController<String> _events = StreamController<String>.broadcast();
  Stream<String> get events => _events.stream;

  bool _first = true;
  int _ansSeq = -1, _lvlSeq = -1, _time = -1, _count = -1, _itemSeq = -1;
  String _screen = '';
  String _lastRaw = ''; // last message text, to skip exact repeats
  int _nn = -1;          // 'nn' = START was pressed with no player name

  void start() => _connect();

  Future<void> _connect() async {
    if (_disposed || _connecting || _ws != null) return;
    _connecting = true;
    // FIX: the HttpClient used to be left open after every attempt, so a phone
    // waiting on the "Connecting" screen leaked one client every 2 seconds.
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final ws = await WebSocket.connect(
        kBoardUrl,
        compression: CompressionOptions.compressionOff,
        customClient: client,
      );
      if (_disposed) {
        ws.close();
        return;
      }
      // 3 s was tight: a busy ESP32 that answers a ping late made the app drop
      // the connection (and the test buttons) in the middle of a fast round.
      ws.pingInterval = const Duration(seconds: 5);
      _ws = ws;
      _first = true;
      _lastRaw = '';
      connected = true;
      notifyListeners();
      ws.listen(
        _onMessage,
        onDone: () => _lost(ws),
        onError: (Object _) => _lost(ws),
        cancelOnError: true,
      );
      send({'cmd': 'hello'});
    } catch (_) {
      _scheduleRetry();
    } finally {
      _connecting = false;
      client.close(); // the WebSocket keeps its own socket; the client is not needed
    }
  }

  void _lost(WebSocket which) {
    // FIX: ignore a late "done" from an old socket, so it can't kill a newer connection
    if (!identical(_ws, which)) return;
    try {
      which.close();
    } catch (_) {}
    _ws = null;
    if (connected) {
      connected = false;
      notifyListeners();
    }
    _scheduleRetry();
  }

  /// Try again right away (e.g. after coming back from the Wi-Fi list).
  void retryNow() {
    if (connected || _disposed) return;
    _retry?.cancel();
    _connect();
  }

  void _scheduleRetry() {
    _retry?.cancel();
    if (!_disposed) _retry = Timer(const Duration(seconds: 2), _connect);
  }

  void send(Map<String, dynamic> message) {
    final ws = _ws;
    if (ws == null) return;
    try {
      ws.add(jsonEncode(message)); // FIX: adding to a socket that is closing used to throw
    } catch (_) {}
  }

  void _onMessage(dynamic data) {
    if (data is! String || data == _lastRaw) return; // exact repeat: nothing to redraw
    Map<String, dynamic> m;
    try {
      m = asMap(jsonDecode(data));
    } catch (_) {
      return;
    }
    if (m['t'] != 's') return;
    _lastRaw = data;

    final screen = asStr(m['screen'], 'menu');

    // FIX: if the ESP32 sends a short update without the word or the settings
    // (for example only the time), keep the ones we already have. Before, the
    // word, the "READ THE WORD" sign and the voices disappeared for that moment.
    final prev = state;
    if (m['cfg'] is! Map && prev['cfg'] is Map) m['cfg'] = prev['cfg'];
    if (screen == 'game' && m['item'] is! Map && prev['screen'] == 'game' && prev['item'] is Map) {
      m['item'] = prev['item'];
    }

    final ans = asMap(m['ans']);
    final ansSeq = asInt(ans['seq']);
    final lvlSeq = asInt(asMap(m['lvl'])['seq']);
    final time = asInt(m['time']);
    final count = asInt(m['count']);
    final itemSeq = asInt(asMap(m['item'])['seq'], -1);
    final nn = asInt(m['nn']);

    if (!_first) {
      if (screen == 'count' && (count != _count || _screen != 'count')) _events.add('tick');
      if (screen == 'game' && _screen != 'game') _events.add('go');
      if (screen == 'game' && ansSeq != _ansSeq) _events.add(asBool(ans['ok']) ? 'ok' : 'bad');
      if (screen == 'game' && itemSeq != _itemSeq) _events.add('item'); // a new word (voices)
      if (screen == 'game' && lvlSeq != _lvlSeq && (m['mode'] == 'hc' || m['mode'] == 'lab')) {
        _events.add('level');
      }
      if (screen == 'game' && time != _time && time > 0 && time <= 5) _events.add('tick');
      if (screen == 'res' && _screen != 'res') _events.add('end');
      if (nn != _nn) _events.add('needname');
    }
    _nn = nn;
    _first = false;
    _itemSeq = itemSeq;
    _ansSeq = ansSeq;
    _lvlSeq = lvlSeq;
    _time = time;
    _count = count;
    _screen = screen;

    state = m;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _ws?.close();
    _events.close();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// Leaderboards, saved on this phone (they stay after the app is closed).
// One list per mode. Each name appears once, with its best score.
// ---------------------------------------------------------------------------
const List<String> kBoardModes = ['std', 'hc', 'lab'];
const Map<String, String> kBoardTitles = {
  'std': 'Standard',
  'hc': 'High Conflict',
  'lab': 'Modifier Lab',
};

class ScoreEntry {
  ScoreEntry(this.name, this.score);
  String name;
  int score;
}

class Leaderboard extends ChangeNotifier {
  static const String _key = 'leaderboards_v1';
  final Map<String, List<ScoreEntry>> _lists = {for (final m in kBoardModes) m: <ScoreEntry>[]};

  /// Highest score first (same score: by name).
  List<ScoreEntry> sorted(String mode) {
    final list = List<ScoreEntry>.of(_lists[mode] ?? const []);
    list.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      return byScore != 0 ? byScore : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null) {
        final data = asMap(jsonDecode(raw));
        for (final m in kBoardModes) {
          final list = data[m] is List ? data[m] as List : const [];
          _lists[m] = [
            for (final e in list)
              if (e is Map && asStr(e['n']).isNotEmpty) ScoreEntry(asStr(e['n']), asInt(e['s'])),
          ];
        }
      }
    } catch (_) {
      // unreadable data: start with empty leaderboards
    }
    notifyListeners();
  }

  /// Saves a finished round. Keeps only the player's best score per mode.
  Future<void> add(String mode, String name, int score) async {
    final list = _lists[mode];
    name = name.trim();
    if (list == null || name.isEmpty) return;
    final i = list.indexWhere((e) => e.name.toLowerCase() == name.toLowerCase());
    if (i < 0) {
      list.add(ScoreEntry(name, score));
    } else if (score > list[i].score) {
      list[i]
        ..name = name
        ..score = score;
    } else {
      return; // not a new best
    }
    notifyListeners();
    await _save();
  }

  Future<void> clearAll() async {
    for (final m in kBoardModes) {
      _lists[m] = [];
    }
    notifyListeners();
    await _save();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode({
        for (final m in kBoardModes) m: [for (final e in _lists[m]!) {'n': e.name, 's': e.score}],
      }));
    } catch (_) {}
  }
}

// ---------------------------------------------------------------------------
// Sounds (played through the phone, or a Bluetooth speaker connected to it)
// ---------------------------------------------------------------------------
class Sfx {
  final Map<String, AudioPlayer> _players = {};
  bool enabled = true;

  // ----- background music (one track at a time, on loop) -----
  final AudioPlayer _music = AudioPlayer();
  String _track = ''; // file playing now ('' = none)

  /// Plays [file] on loop. '' (or sounds switched off) stops the music.
  Future<void> music(String file) async {
    if (!enabled) file = '';
    if (file == _track) return;
    _track = file;
    try {
      await _music.stop();
      if (file.isEmpty || _track != file) return;
      await _music.setReleaseMode(ReleaseMode.loop);
      await _music.setVolume(kMusicVolume);
      if (_track != file) return;
      await _music.play(AssetSource('sounds/$file'));
    } catch (_) {
      // a missing music file should never stop the game
    }
  }

  Future<void> init() async {
    for (final name in const ['ok', 'bad', 'tick', 'go', 'end', 'level']) {
      try {
        final p = AudioPlayer();
        await p.setReleaseMode(ReleaseMode.stop);
        await p.setSource(AssetSource('sounds/$name.wav'));
        _players[name] = p;
      } catch (_) {
        // a missing sound file should never stop the game
      }
    }
  }

  Future<void> play(String name) async {
    if (!enabled) return;
    final p = _players[name];
    if (p == null) return;
    try {
      await p.stop();
      await p.resume();
    } catch (_) {}
  }

  void dispose() {
    _music.dispose();
    for (final p in _players.values) {
      p.dispose();
    }
  }
}

// ---------------------------------------------------------------------------
// Voice distractors, spoken by the phone's text-to-speech.
// The ESP32 decides WHEN voices speak and WHICH colors they say (item "say").
// The phone picks the speaker and, in the Modifier Lab, makes the voices
// faster, harsher and cut into each other as the level goes up.
// ---------------------------------------------------------------------------
class Persona {
  const Persona(this.name, this.gender, this.pitch, this.rate);
  final String name;
  final String gender; // 'm' = male voice, 'f' = female voice
  final double pitch; // 0.5 (low) .. 2.0 (high)
  final double rate; // 0.5 = normal speed on Android
}

/// The speakers. High-Conflict unlocks more of them at higher levels
/// (level 1: first 2, level 2: first 4, level 3: first 6, level 4: all 8).
const List<Persona> kPersonas = [
  Persona('Adult man', 'm', 0.85, 0.5),
  Persona('Adult woman', 'f', 1.0, 0.5),
  Persona('Young man', 'm', 1.05, 0.55),
  Persona('Teen girl', 'f', 1.3, 0.58),
  Persona('Old man', 'm', 0.65, 0.4),
  Persona('Little kid', 'f', 1.75, 0.55),
  Persona('Deep voice', 'm', 0.5, 0.45),
  Persona('Fast talker', 'f', 1.15, 0.8),
];

class Voices {
  final FlutterTts _tts = FlutterTts();
  final Random _rng = Random();
  final List<Map<String, String>> _male = [], _female = [], _all = [];
  final Map<String, AudioPlayer> _fx = {};
  bool enabled = true;
  bool _ready = false;
  bool _busy = false;
  bool _fxOn = false; // static / glitch / boom may be playing
  int _gen = 0;

  // FIX (main cause of the "hard to press" buttons): on Android, every
  // setVoice() asks the speech engine for its whole voice list on the phone's
  // main thread. That was done for EVERY line, up to 6 times a second at high
  // levels, and it froze touch input and screen updates for a moment each time.
  // Now one male and one female voice are chosen once, and setVoice() is only
  // called when the voice really changes (at most once per word). The speakers
  // still sound different through pitch and speed, which cost nothing.
  Map<String, String>? _maleVoice, _femaleVoice, _anyVoice;
  String _currentVoice = '';

  Future<void> init() async {
    try {
      await _tts.setLanguage('en-US');
      await _tts.setVolume(1.0);
      await _tts.setQueueMode(0); // a new voice cuts in on the one speaking
      final list = await _tts.getVoices;
      if (list is List) {
        for (final v in list) {
          if (v is! Map) continue;
          final name = '${v['name'] ?? ''}';
          final locale = '${v['locale'] ?? ''}';
          if (name.isEmpty || !locale.toLowerCase().startsWith('en')) continue;
          if (name.contains('network') || '${v['network_required']}' == '1') continue; // offline voices only
          final voice = {'name': name, 'locale': locale};
          _all.add(voice);
          final g = _genderOf(name);
          if (g == 'm') _male.add(voice);
          if (g == 'f') _female.add(voice);
        }
      }
      Map<String, String>? any(List<Map<String, String>> l) => l.isEmpty ? null : l[_rng.nextInt(l.length)];
      _maleVoice = any(_male);
      _femaleVoice = any(_female);
      _anyVoice = any(_all);
      _ready = true;
    } catch (_) {
      // no text-to-speech on this phone: the game still works without voices
    }
    for (final name in const ['static', 'glitch', 'boom']) {
      try {
        final p = AudioPlayer();
        await p.setReleaseMode(ReleaseMode.stop);
        await p.setSource(AssetSource('sounds/$name.wav'));
        _fx[name] = p;
      } catch (_) {}
    }
  }

  // Guess a voice's gender from its name (Google and Samsung voice names)
  static String _genderOf(String voiceName) {
    final n = voiceName.toLowerCase();
    if (n.contains('female') || RegExp(r'smtf|-x-(sfg|iob|iog|tpc|tpf)').hasMatch(n)) return 'f';
    if (n.contains('male') || RegExp(r'smtm|-x-(iom|iol|tpd)').hasMatch(n)) return 'm';
    return '';
  }

  Map<String, String>? _voiceFor(String gender) {
    if (gender == 'm') return _maleVoice ?? _anyVoice;
    if (gender == 'f') return _femaleVoice ?? _anyVoice;
    return _anyVoice;
  }

  /// Switch the speech engine's voice only if it is a different one.
  Future<void> _useVoice(String gender) async {
    final v = _voiceFor(gender);
    if (v == null || v['name'] == _currentVoice) return;
    try {
      await _tts.setVoice(v);
      _currentVoice = v['name'] ?? '';
    } catch (_) {}
  }

  String _pick(List<String> options) => options[_rng.nextInt(options.length)];

  /// Stop all voices (new word, round over, app in the background).
  void stop() {
    _gen++;
    if (_ready && _busy) {
      _busy = false;
      _tts.stop();
    }
  }

  /// Stop voices AND the static/glitch/boom noise (round over, app hidden,
  /// sounds switched off). FIX: the noise used to keep playing after the round.
  void stopAll() {
    stop();
    if (!_fxOn) return;
    _fxOn = false;
    for (final p in _fx.values) {
      p.stop().catchError((Object _) {});
    }
  }

  /// Speak the colors the ESP32 chose for the new word.
  void speak(List<String> colors, String mode, int level) {
    stop();
    if (!enabled || !_ready || colors.isEmpty) return;
    final lv = level < 1 ? 1 : (level > 4 ? 4 : level);
    _busy = true;
    _run(_gen, colors, mode == 'lab', lv);
  }

  Future<void> _run(int gen, List<String> colors, bool lab, int lv) async {
    // the Lab at level 3-4 repeats some colors for more chaos
    final lines = List<String>.of(colors);
    if (lab && lv == 3 && _rng.nextBool()) lines.add(_pick(colors));
    if (lab && lv == 4) lines.addAll([_pick(colors), _pick(colors)]);

    final chaos = lab && lv >= 3;
    await Future.delayed(Duration(milliseconds: chaos ? 80 + _rng.nextInt(150) : 200 + _rng.nextInt(400)));
    if (gen != _gen) return;
    if (chaos) _noise(gen, lv);

    for (int i = 0; i < lines.length; i++) {
      final color = lines[i];
      if (gen != _gen) return;
      await _setSpeaker(lab, lv, pickVoice: i == 0); // voice switch: once per word at most
      if (gen != _gen) return;
      try {
        await _tts.speak(_line(color, lab, lv));
      } catch (_) {}
      // calm voices wait their turn; chaos voices cut in on each other
      final gap = !lab
          ? 700 + _rng.nextInt(400)
          : (lv == 1
              ? 750 + _rng.nextInt(300)
              : (lv == 2 ? 450 + _rng.nextInt(300) : (lv == 3 ? 260 + _rng.nextInt(200) : 160 + _rng.nextInt(160))));
      await Future.delayed(Duration(milliseconds: gap));
    }
  }

  Future<void> _setSpeaker(bool lab, int lv, {bool pickVoice = false}) async {
    final pool = lab ? kPersonas.length : const [2, 4, 6, 8][lv - 1];
    final p = kPersonas[_rng.nextInt(pool)];
    double pitch = p.pitch, rate = p.rate;
    if (lab && lv == 2) {
      pitch *= _rng.nextBool() ? 0.85 : 1.2; // a little strange
      rate *= 1.2;
    } else if (lab && lv == 3) {
      pitch = _rng.nextBool() ? 0.5 + _rng.nextDouble() * 0.15 : 1.75 + _rng.nextDouble() * 0.25; // growl or shriek
      rate = 0.7 + _rng.nextDouble() * 0.15;
    } else if (lab && lv == 4) {
      pitch = _rng.nextBool() ? 0.5 : 1.85 + _rng.nextDouble() * 0.15;
      rate = 0.8 + _rng.nextDouble() * 0.2;
    }
    if (pickVoice) await _useVoice(p.gender);
    try {
      await _tts.setPitch(pitch.clamp(0.5, 2.0).toDouble());
      await _tts.setSpeechRate((rate * kVoiceSpeed).clamp(0.1, 1.0).toDouble()); // 1.0 = fastest on Android
    } catch (_) {}
  }

  // What the voice says. Calm voices say just the color; the Lab gets pushier.
  String _line(String color, bool lab, int lv) {
    final c = color.toLowerCase();
    if (!lab || lv == 1) return c;
    if (lv == 2) return _pick(['$c!', c, "it's $c"]);
    if (lv == 3) return _pick(['$c!', 'press $c!', '$c, $c!']);
    return _pick(['$c! $c!', 'press $c now!', 'no! $c!', '$c, $c, $c!']);
  }

  // Noise under the voices (Lab level 3: static; level 4: static, glitch and boom)
  void _noise(int gen, int lv) {
    final names = lv >= 4 ? const ['static', 'glitch', 'boom'] : const ['static'];
    for (final name in names) {
      final p = _fx[name];
      if (p == null || (lv < 4 && _rng.nextBool())) continue;
      Future.delayed(Duration(milliseconds: _rng.nextInt(500)), () async {
        if (gen != _gen) return;
        _fxOn = true;
        try {
          await p.stop();
          await p.setVolume(lv >= 4 ? 0.7 : 0.45);
          await p.resume();
        } catch (_) {}
      });
    }
  }

  void dispose() {
    stopAll();
    for (final p in _fx.values) {
      p.dispose();
    }
  }
}

// ---------------------------------------------------------------------------
// The game page
// ---------------------------------------------------------------------------
class GamePage extends StatefulWidget {
  const GamePage({super.key});

  @override
  State<GamePage> createState() => _GamePageState();
}

class _GamePageState extends State<GamePage> with WidgetsBindingObserver {
  final Board board = Board();
  final Sfx sfx = Sfx();
  final Voices voices = Voices();
  final Leaderboard leaderboard = Leaderboard();
  final TextEditingController _nameCtrl = TextEditingController();
  final FocusNode _nameFocus = FocusNode();
  StreamSubscription<String>? _sub;
  String _flash = '';
  Timer? _flashTimer;
  String _toast = '';
  Timer? _toastTimer;
  bool _testPad = false;
  bool _inBackground = false;

  // Press guard for the on-screen buttons (see _press)
  final Stopwatch _clock = Stopwatch()..start();
  int _colorMs = -100000, _ctrlMs = -100000;
  String _pressStamp = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    board.addListener(_changed);
    _sub = board.events.listen(_onEvent);
    sfx.init();
    voices.init();
    leaderboard.load();
    board.start();
    _updateMusic(); // start-up music
  }

  bool _wasConnected = false;

  void _changed() {
    // (Re)connected with a name already typed: tell the board again
    if (board.connected && !_wasConnected && _nameCtrl.text.trim().isNotEmpty) _sendName();
    _wasConnected = board.connected;
    _updateMusic();
    if (!board.connected || board.state['screen'] != 'game') voices.stopAll();
    if (mounted) setState(() {});
  }

  /// What the board has shown so far. Changes when it has handled a press.
  String _stamp() {
    final s = board.state;
    return '${s['screen']}|${asMap(s['ans'])['seq']}|${asMap(s['item'])['seq']}|${s['count']}';
  }

  /// One on-screen button press.
  /// FIX for double inputs: a second color press is ignored until the board
  /// has answered the first one (new word / new answer), or 400 ms have passed
  /// in case the board ignored it. A press faster than 90 ms after the last
  /// one is always a double touch. START / RESTART need 500 ms between presses,
  /// so a double tap can't skip the mode screen.
  void _press(String b) {
    final now = _clock.elapsedMilliseconds;
    if (kInk.containsKey(b)) {
      final since = now - _colorMs;
      if (since < 90) return;
      if (since < 400 && _stamp() == _pressStamp) return;
      _colorMs = now;
      _pressStamp = _stamp();
    } else {
      if (now - _ctrlMs < 500) return;
      _ctrlMs = now;
    }
    HapticFeedback.selectionClick();
    // 'seq' = the word this press was meant for. The ESP32 can ignore a press
    // whose seq is not the current word (an old press arriving late). Boards
    // that don't read it simply ignore the extra field.
    board.send({'cmd': 'press', 'b': b, 'seq': asInt(asMap(board.state['item'])['seq'], -1)});
  }

  // A new word: speak the voices the ESP32 chose for it (if any)
  void _speakItem() {
    final s = board.state;
    final item = asMap(s['item']);
    final say = item['say'] is List ? (item['say'] as List).map((c) => '$c').toList() : <String>[];
    voices.speak(say, asStr(s['mode']), asInt(s['level'], 1));
  }

  /// Which music should play on the current screen.
  String _musicFor() {
    if (!board.connected) return kMenuMusic; // start-up, while connecting
    switch (asStr(board.state['screen'], 'menu')) {
      case 'menu':
      case 'mode':
        return kMenuMusic;
      case 'game':
        return kGameMusic;
      default:
        return ''; // countdown and results: no music
    }
  }

  void _updateMusic() => sfx.music(_inBackground ? '' : _musicFor());

  // Stop the music when the app is closed or in the background
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _inBackground = state != AppLifecycleState.resumed;
    _updateMusic();
    if (_inBackground) voices.stopAll();
    if (state == AppLifecycleState.resumed) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky); // full screen again
      board.retryNow(); // e.g. just joined STROOP-GAME in the Wi-Fi list
    }
  }

  void _showToast(String text) {
    _toastTimer?.cancel();
    setState(() => _toast = text);
    _toastTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _toast = '');
    });
  }

  /// Tells the board the player's name while it is typed, so START works as
  /// soon as there is a name (and is blocked again if the field is emptied).
  void _sendName() => board.send({'cmd': 'name', 'name': _nameCtrl.text.trim()});

  /// A round ended: save the score to the leaderboard of its mode.
  void _saveScore() {
    final s = board.state;
    final mode = asStr(s['mode']);
    var name = asStr(s['player']).trim();
    if (name.isEmpty) name = _nameCtrl.text.trim();
    if (kBoardModes.contains(mode) && name.isNotEmpty) leaderboard.add(mode, name, asInt(s['ok']));
    _nameCtrl.clear(); // the next player types their own name
  }

  void _onEvent(String e) {
    if (e == 'item') {
      if (!_inBackground) _speakItem();
      return;
    }
    if (e == 'needname') {
      // START was pressed (board or test button) before a name was entered
      if (mounted) {
        _showToast('ENTER YOUR NAME FIRST');
        if (asStr(board.state['screen'], 'menu') == 'menu') _nameFocus.requestFocus();
      }
      return;
    }
    if (e == 'end') {
      voices.stopAll();
      _saveScore();
    }
    sfx.play(e);
    if (!mounted) return;
    if (e == 'ok' || e == 'bad') {
      _flashTimer?.cancel();
      setState(() => _flash = e);
      _flashTimer = Timer(const Duration(milliseconds: 300), () {
        if (mounted) setState(() => _flash = '');
      });
    }
    if (e == 'level') {
      final dir = asInt(asMap(board.state['lvl'])['dir']);
      final level = asInt(board.state['level'], 1);
      _showToast(dir > 0 ? 'LEVEL UP  →  $level' : 'LEVEL DOWN  →  $level');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _flashTimer?.cancel();
    _toastTimer?.cancel();
    board.removeListener(_changed);
    board.dispose();
    sfx.dispose();
    voices.dispose();
    leaderboard.dispose();
    _nameCtrl.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = board.state;
    final screen = asStr(s['screen'], 'menu');
    final item = s['item'] is Map ? asMap(s['item']) : null;
    final k = uiScale(context);

    return Scaffold(
      // The game draws its own text sizes (scaled by uiScale), so the phone's
      // "font size" setting must not enlarge them a second time.
      body: MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
        child: SafeArea(
          child: Stack(
            children: [
              Positioned.fill(
                child: Container(
                  padding: EdgeInsets.fromLTRB(16 * k, 10 * k, 16 * k, _testPad ? 74 * k : 10 * k),
                  child: board.connected ? _screenFor(screen, s, item) : _connectingView(),
                ),
              ),
              Positioned(
                top: 4 * k,
                right: 4 * k,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      iconSize: 24 * k,
                      icon: const Icon(Icons.leaderboard, color: kMuted),
                      tooltip: 'Leaderboards',
                      onPressed: _openLeaderboards,
                    ),
                    IconButton(
                      iconSize: 24 * k,
                      icon: const Icon(Icons.settings, color: kMuted),
                      tooltip: 'Settings',
                      onPressed: _openSettings,
                    ),
                  ],
                ),
              ),
              if (_toast.isNotEmpty)
                Positioned(
                  top: 10 * k,
                  left: 0,
                  right: 0,
                  child: Center(child: Pill(text: _toast, color: kText)),
                ),
              if (_testPad && board.connected)
                Positioned(
                  left: 8 * k,
                  right: 8 * k,
                  bottom: 6 * k,
                  child: RepaintBoundary(child: TestPad(onPress: _press)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _screenFor(String screen, Map<String, dynamic> s, Map<String, dynamic>? item) {
    switch (screen) {
      case 'mode':
        return _modeView();
      case 'count':
        return Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text('${asInt(s['count'], 3)}',
                style: TextStyle(fontSize: context.sc(150), fontWeight: FontWeight.w900, color: kText)),
          ),
        );
      case 'game':
        return _gameView(s, item);
      case 'res':
        return _resultsView(s);
      default:
        return _menuView();
    }
  }

  Widget _connectingView() {
    final k = uiScale(context);
    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 36 * k,
              height: 36 * k,
              child: CircularProgressIndicator(strokeWidth: 4 * k),
            ),
            SizedBox(height: 18 * k),
            Text('Connecting to the board…',
                style: TextStyle(fontSize: 48 * k, fontWeight: FontWeight.w800, color: kText)),
            SizedBox(height: 26 * k),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconCircleButton(icon: Icons.wifi, color: kInk['blue']!, tooltip: 'Wi-Fi', onTap: openWifi),
                SizedBox(width: 48 * k),
                IconCircleButton(icon: Icons.bluetooth, color: kTimeColor, tooltip: 'Bluetooth', onTap: openBluetooth),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _menuView() {
    final k = uiScale(context);
    final player = asStr(board.state['player']);
    final ready = player.isNotEmpty;
    final startText = Text('Press START',
        style: TextStyle(fontSize: 26 * k, fontWeight: FontWeight.w600, color: kMuted));
    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('STROOP CHALLENGE',
                style: TextStyle(
                    fontSize: 60 * k, fontWeight: FontWeight.w900, color: kText, letterSpacing: -1)),
            SizedBox(height: 12 * k),
            // "Press START" blinks only once the player's name is in
            if (ready) Blink(child: startText) else Opacity(opacity: 0.35, child: startText),
            SizedBox(height: 16 * k),
            SizedBox(
              width: 400 * k,
              child: TextField(
                controller: _nameCtrl,
                focusNode: _nameFocus,
                textAlign: TextAlign.center,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.done,
                maxLength: kMaxNameLength,
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9 ._-]'))],
                onChanged: (_) => _sendName(),
                onSubmitted: (_) {
                  _sendName();
                  _nameFocus.unfocus();
                },
                style: TextStyle(fontSize: 20 * k, fontWeight: FontWeight.w800, color: kText),
                decoration: InputDecoration(
                  hintText: 'Enter your name',
                  counterText: '',
                  isDense: true,
                  filled: true,
                  fillColor: Colors.white,
                  contentPadding: EdgeInsets.symmetric(horizontal: 14 * k, vertical: 12 * k),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12 * k),
                    borderSide: const BorderSide(color: kCardBorder, width: 1.5),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12 * k),
                    borderSide: BorderSide(color: kInk['blue']!, width: 2),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _modeView() {
    final k = uiScale(context);
    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (asStr(board.state['player']).isNotEmpty) ...[
              Text('Player: ${asStr(board.state['player'])}',
                  style: TextStyle(fontSize: 20 * k, fontWeight: FontWeight.w800, color: kText)),
              SizedBox(height: 6 * k),
            ],
            Text('Choose a mode on the board',
                style: TextStyle(fontSize: 22 * k, fontWeight: FontWeight.w600, color: kMuted)),
            SizedBox(height: 18 * k),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const ModeCard(color: Color(0xFF1F9E57), button: 'GREEN', name: 'Standard'),
                SizedBox(width: 16 * k),
                const ModeCard(color: Color(0xFFE2483D), button: 'RED', name: 'High-Conflict'),
                SizedBox(width: 16 * k),
                const ModeCard(color: Color(0xFF2F6FE0), button: 'BLUE', name: 'Modifier Lab'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _gameView(Map<String, dynamic> s, Map<String, dynamic>? item) {
    final k = uiScale(context);
    final mode = asStr(s['mode']);
    final modeText = mode == 'hc'
        ? 'HIGH-CONFLICT  ·  LEVEL ${asInt(s['level'], 1)}'
        : (mode == 'lab' ? 'MODIFIER LAB  ·  LEVEL ${asInt(s['level'], 1)}' : 'STANDARD');
    final reverse = item != null && item['rule'] == 'word';
    return Column(
      children: [
        Row(
          children: [
            Expanded(child: StatCard(label: 'Time Left', value: '${asInt(s['time'])}', color: kTimeColor)),
            SizedBox(width: 12 * k),
            Expanded(child: StatCard(label: 'Correct', value: '${asInt(s['ok'])}', color: kOkColor)),
            SizedBox(width: 12 * k),
            Expanded(child: StatCard(label: 'Wrong', value: '${asInt(s['bad'])}', color: kBadColor)),
            SizedBox(width: 96 * k), // room for the leaderboard and settings buttons
          ],
        ),
        SizedBox(height: 6 * k),
        Text(modeText,
            style: TextStyle(
                fontSize: 13 * k, fontWeight: FontWeight.w700, color: kMuted, letterSpacing: 1.2)),
        SizedBox(height: 6 * k),
        // The rule sign "pops" every time the rule changes, so a fast switch is noticed
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 140),
          transitionBuilder: (child, a) => ScaleTransition(scale: a, child: child),
          child: Pill(
            key: ValueKey(reverse),
            text: reverse ? 'READ THE WORD' : 'NAME THE INK COLOR',
            color: reverse ? kReverse : kText,
          ),
        ),
        SizedBox(height: 4 * k),
        Expanded(
          // Clean word area (no frame), the same for both rules. The purple
          // "READ THE WORD" sign above still pops when the rule changes.
          child: Container(
            child: Stack(
              children: [
                if (item != null) Positioned.fill(child: RepaintBoundary(child: WordArea(item: item))),
                if (_flash.isNotEmpty)
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(_flash == 'ok' ? '✓' : '✗',
                        style: TextStyle(
                            fontSize: 64 * k,
                            fontWeight: FontWeight.w900,
                            color: _flash == 'ok' ? kOkColor : kBadColor)),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _resultsView(Map<String, dynamic> s) {
    final k = uiScale(context);
    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text("Time's up!",
                style: TextStyle(fontSize: 44 * k, fontWeight: FontWeight.w900, color: kText)),
            if (asStr(s['player']).isNotEmpty)
              Text(asStr(s['player']),
                  style: TextStyle(fontSize: 22 * k, fontWeight: FontWeight.w800, color: kMuted)),
            SizedBox(height: 16 * k),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                    width: 210 * k,
                    child: StatCard(label: 'Correct', value: '${asInt(s['ok'])}', color: kOkColor, big: true)),
                SizedBox(width: 14 * k),
                SizedBox(
                    width: 210 * k,
                    child: StatCard(label: 'Wrong', value: '${asInt(s['bad'])}', color: kBadColor, big: true)),
                SizedBox(width: 14 * k),
                SizedBox(
                    width: 210 * k,
                    child: StatCard(
                        label: 'Total Questions', value: '${asInt(s['total'])}', color: kTimeColor, big: true)),
              ],
            ),
            SizedBox(height: 16 * k),
            Text('Press START or MENU for the main menu',
                style: TextStyle(fontSize: 18 * k, fontWeight: FontWeight.w600, color: kMuted)),
          ],
        ),
      ),
    );
  }

  // ----- leaderboards -----
  void _openLeaderboards() {
    _nameFocus.unfocus();
    showDialog<void>(context: context, builder: (_) => LeaderboardDialog(leaderboard: leaderboard));
  }

  // ----- settings sheet -----
  void _openSettings() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 640), // stays readable on tablets
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheet) {
            return AnimatedBuilder(
              animation: board,
              builder: (sheetContext, _) {
                final cfg = asMap(board.state['cfg']);
                final on = board.connected;
                final round = asInt(cfg['round'], 60);

                Widget labSwitch(String key, String title, String subtitle) {
                  return SwitchListTile(
                    dense: true,
                    title: Text(title),
                    subtitle: Text(subtitle),
                    value: asBool(cfg[key]),
                    onChanged: on ? (v) => board.send({'cmd': 'cfg', key: v}) : null,
                  );
                }

                return ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: MediaQuery.of(sheetContext).size.height * 0.9),
                  child: ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                    children: [
                      ListTile(
                        title: const Text('Round length'),
                        trailing: SegmentedButton<int>(
                          segments: const [
                            ButtonSegment(value: 60, label: Text('60 s')),
                            ButtonSegment(value: 20, label: Text('20 s')),
                          ],
                          selected: {round == 20 ? 20 : 60},
                          onSelectionChanged: on
                              ? (sel) => board.send({'cmd': 'cfg', 'round': sel.first})
                              : null,
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                        child: Text('MODIFIER LAB (BLUE MODE)',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: kMuted)),
                      ),
                      labSwitch('multi', 'Double / Triple Trouble', 'Answer only the word between the arrows'),
                      labSwitch('reverse', 'Rule switch (Reverse)', 'Sometimes: read the word instead'),
                      labSwitch('prime', 'Negative priming', 'Answer is often the color you just ignored'),
                      labSwitch('motion', 'Moving or disappearing text', 'Scrolls, flashes, or vanishes after 0.7 s'),
                      labSwitch('invert', 'Inverted or rotated text', 'Upside down, vertical, or mirrored'),
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                        child: Text('VOICES (HIGH-CONFLICT AND MODIFIER LAB)',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: kMuted)),
                      ),
                      labSwitch('voice', 'Voice distractors',
                          'Voices call out colors. More voices at higher levels; wilder in the Lab'),
                      const Divider(),
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.admin_panel_settings, color: kBadColor),
                        title: const Text('Clear leaderboards (admin)'),
                        subtitle: const Text('Removes every name and score. Needs the admin password'),
                        onTap: () => showDialog<void>(
                          context: sheetContext,
                          builder: (_) => AdminClearDialog(leaderboard: leaderboard),
                        ),
                      ),
                      SwitchListTile(
                        dense: true,
                        title: const Text('Sounds'),
                        subtitle: const Text('Music, effects and voices on this phone'),
                        value: sfx.enabled,
                        onChanged: (v) {
                          setSheet(() {
                            sfx.enabled = v;
                            voices.enabled = v;
                          });
                          if (!v) voices.stopAll();
                          _updateMusic();
                        },
                      ),
                      SwitchListTile(
                        dense: true,
                        title: const Text('Test buttons on screen'),
                        subtitle: const Text('Play without the arcade buttons'),
                        value: _testPad,
                        onChanged: (v) {
                          setState(() => _testPad = v);
                          setSheet(() {});
                        },
                      ),
                      ListTile(
                        dense: true,
                        leading: Icon(Icons.wifi, color: kInk['blue']),
                        title: const Text('Wi-Fi networks'),
                        subtitle: const Text('Join $kWifiName (password: $kWifiPassword)'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: openWifi,
                      ),
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.bluetooth, color: kTimeColor),
                        title: const Text('Bluetooth'),
                        subtitle: const Text('Pair a Bluetooth speaker for the sounds and voices'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: openBluetooth,
                      ),
                      ListTile(
                        dense: true,
                        leading: Icon(on ? Icons.wifi : Icons.wifi_off, color: on ? kOkColor : kBadColor),
                        title: Text(on ? 'Connected to the board' : 'Not connected'),
                        subtitle: const Text('Wi-Fi "$kWifiName"  ·  $kBoardUrl'),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// The word area: draws the words with their colors, rotation, mirror, warp,
// and motion (scroll, flash, vanish)
// ---------------------------------------------------------------------------
class WordArea extends StatefulWidget {
  const WordArea({super.key, required this.item});
  final Map<String, dynamic> item;

  @override
  State<WordArea> createState() => _WordAreaState();
}

class _WordAreaState extends State<WordArea> with SingleTickerProviderStateMixin {
  late final AnimationController _scroll =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));
  Timer? _timer;
  bool _visible = true;
  int _seq = -1;

  @override
  void initState() {
    super.initState();
    _setup();
  }

  @override
  void didUpdateWidget(covariant WordArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (asInt(widget.item['seq'], -1) != _seq) _setup();
  }

  void _setup() {
    _seq = asInt(widget.item['seq'], -1);
    _timer?.cancel();
    _visible = true;
    _scroll.stop();
    _scroll.value = 0;
    final motion = asStr(widget.item['motion']);
    if (motion == 'scroll') {
      // FIX: start in the middle so the word is readable at once. It used to
      // start half off the left edge, which wasted time on fast levels.
      _scroll.value = 0.5;
      _scroll.repeat();
    } else if (motion == 'flash') {
      _timer = Timer.periodic(const Duration(milliseconds: 160), (_) {
        if (mounted) setState(() => _visible = !_visible);
      });
    } else if (motion == 'vanish') {
      _timer = Timer(const Duration(milliseconds: 700), () {
        if (mounted) setState(() => _visible = false);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Matrix4 _warpMatrix(int style) {
    switch (style) {
      case 1:
        return Matrix4.skewX(-0.38).multiplied(Matrix4.diagonal3Values(1.15, 0.78, 1));
      case 2:
        return Matrix4.skewY(0.17).multiplied(Matrix4.diagonal3Values(0.85, 1.2, 1));
      default:
        return Matrix4.identity()
          ..setEntry(3, 2, 0.002)
          ..rotateY(0.66);
    }
  }

  Widget _word(Map<String, dynamic> w, bool marked, bool multi) {
    final k = uiScale(context);
    final style = TextStyle(
      fontSize: (multi ? 70 : 140) * k,
      fontWeight: FontWeight.w900,
      color: kInk[asStr(w['ink'])] ?? kText,
      height: 1.05,
    );
    final text = asStr(w['text']);
    if (!marked) return Text(text, style: style);
    // Dark arrow icons (not the ▶ ◀ characters, which some phones draw as colored emoji)
    final double size = (multi ? 56 : 90) * k;
    // The text box also holds room for letters that hang below the line (g, y),
    // so CAPITAL words sit a little high in it. Lift the arrows by this much of
    // the font size to meet the middle of the capitals. Raise it if the arrows
    // still look low, lower it (or 0) if they look high.
    const double kArrowLift = 0.04;
    final double lift = style.fontSize! * kArrowLift;
    Widget arrow(IconData icon) =>
        Transform.translate(offset: Offset(0, -lift), child: Icon(icon, size: size, color: kText));
    // A Row centers the arrows on the word's full height. (The old inline arrows
    // were centered on the height of small letters, so next to CAPITAL words
    // they sat too low.)
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        arrow(Icons.arrow_right),
        Text(text, style: style),
        arrow(Icons.arrow_left),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final words = item['words'] is List ? item['words'] as List : const [];
    final target = asInt(item['target']);
    final multi = words.length > 1;

    Widget content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < words.length; i++) _word(asMap(words[i]), multi && i == target, multi),
      ],
    );

    final rot = asInt(item['rot']);
    if (rot == 90) content = RotatedBox(quarterTurns: 1, child: content);
    if (rot == 180) content = RotatedBox(quarterTurns: 2, child: content);
    content = FittedBox(fit: BoxFit.scaleDown, child: content);

    final mirror = asInt(item['mirror']);
    if (mirror == 1) {
      content = Transform(
          alignment: Alignment.center, transform: Matrix4.diagonal3Values(-1, 1, 1), child: content);
    } else if (mirror == 2) {
      content = Transform(
          alignment: Alignment.center, transform: Matrix4.diagonal3Values(1, -1, 1), child: content);
    }

    final warp = asInt(item['warp']);
    if (warp > 0) {
      content = Transform(alignment: Alignment.center, transform: _warpMatrix(warp), child: content);
    }

    content = Visibility(
      visible: _visible,
      maintainSize: true,
      maintainAnimation: true,
      maintainState: true,
      child: content,
    );

    if (asStr(item['motion']) == 'scroll') {
      final inner = content;
      content = LayoutBuilder(
        builder: (context, box) => AnimatedBuilder(
          animation: _scroll,
          child: inner,
          builder: (context, child) => Transform.translate(
            offset: Offset((_scroll.value * 2 - 1) * box.maxWidth * 0.6, 0),
            child: child,
          ),
        ),
      );
    }

    return ClipRect(child: Center(child: content));
  }
}

// ---------------------------------------------------------------------------
// Small widgets
// ---------------------------------------------------------------------------
class StatCard extends StatelessWidget {
  const StatCard({super.key, required this.label, required this.value, required this.color, this.big = false});
  final String label;
  final String value;
  final Color color;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final k = uiScale(context);
    return Container(
      padding: EdgeInsets.symmetric(vertical: (big ? 14 : 6) * k, horizontal: 8 * k),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: kCardBorder),
        borderRadius: BorderRadius.circular(14 * k),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: TextStyle(fontSize: (big ? 16 : 13) * k, color: kMuted)),
          Text(value,
              style: TextStyle(
                  fontSize: (big ? 64 : 26) * k,
                  fontWeight: FontWeight.w800,
                  color: color,
                  fontFeatures: const [FontFeature.tabularFigures()])),
        ],
      ),
    );
  }
}

/// A big round icon button (Wi-Fi and Bluetooth on the connecting screen).
class IconCircleButton extends StatelessWidget {
  const IconCircleButton({
    super.key,
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onTap,
  });
  final IconData icon;
  final Color color;
  final String tooltip; // shown on long-press, read by screen readers
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final k = uiScale(context);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white,
        shape: CircleBorder(side: BorderSide(color: color.withAlpha(90), width: 3 * k)),
        elevation: 2,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 140 * k,
            height: 140 * k,
            child: Icon(icon, color: color, size: 84 * k),
          ),
        ),
      ),
    );
  }
}

class Pill extends StatelessWidget {
  const Pill({super.key, required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final k = uiScale(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 14 * k, vertical: 6 * k),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(99)),
      child: Text(text,
          style: TextStyle(
              fontSize: 13 * k, fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: 1)),
    );
  }
}

class ModeCard extends StatelessWidget {
  const ModeCard({super.key, required this.color, required this.button, required this.name});
  final Color color;
  final String button;
  final String name;

  @override
  Widget build(BuildContext context) {
    final k = uiScale(context);
    return Container(
      width: 200 * k,
      padding: EdgeInsets.symmetric(vertical: 18 * k, horizontal: 12 * k),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(18 * k)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(button,
              style: TextStyle(fontSize: 28 * k, fontWeight: FontWeight.w900, color: Colors.white)),
          SizedBox(height: 4 * k),
          Text(name,
              style: TextStyle(fontSize: 16 * k, fontWeight: FontWeight.w600, color: Colors.white)),
        ],
      ),
    );
  }
}

class Blink extends StatefulWidget {
  const Blink({super.key, required this.child});
  final Widget child;

  @override
  State<Blink> createState() => _BlinkState();
}

class _BlinkState extends State<Blink> {
  bool _on = true;
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(milliseconds: 550), (_) {
      if (mounted) setState(() => _on = !_on);
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Opacity(opacity: _on ? 1 : 0, child: widget.child);
}

/// The leaderboards: three tabs, names and scores, highest first.
class LeaderboardDialog extends StatelessWidget {
  const LeaderboardDialog({super.key, required this.leaderboard});
  final Leaderboard leaderboard;

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 560, maxHeight: height * 0.9),
        child: DefaultTabController(
          length: kBoardModes.length,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 4, 0),
                child: Row(
                  children: [
                    const Expanded(
                        child: Text('LEADERBOARDS',
                            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: kText))),
                    IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              TabBar(
                labelStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                unselectedLabelStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                tabs: [for (final m in kBoardModes) Tab(text: kBoardTitles[m])],
              ),
              Flexible(
                child: AnimatedBuilder(
                  animation: leaderboard,
                  builder: (_, __) => TabBarView(
                    children: [for (final m in kBoardModes) BoardList(entries: leaderboard.sorted(m))],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One leaderboard tab: NAME / SCORE header, then a scrollable list.
/// Places 1-5 get a medal, then plain numbers 6, 7, 8 ...
class BoardList extends StatefulWidget {
  const BoardList({super.key, required this.entries});
  final List<ScoreEntry> entries;

  @override
  State<BoardList> createState() => _BoardListState();
}

class _BoardListState extends State<BoardList> {
  final ScrollController _scroll = ScrollController(); // each tab scrolls on its own

  static const TextStyle _head = TextStyle(fontSize: 13, fontWeight: FontWeight.w900, color: kMuted, letterSpacing: 1.2);
  static const TextStyle _bold = TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: kText);
  static const double _rankWidth = 48;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Widget _row(Widget rank, Widget name, Widget score) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            SizedBox(width: _rankWidth, child: Align(alignment: Alignment.centerLeft, child: rank)),
            Expanded(child: name),
            score,
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final entries = widget.entries;
    return Center(
      // keeps names and scores close together in the middle of the dialog
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Column(
          children: [
            const SizedBox(height: 12),
            _row(const SizedBox(), const Text('NAME', style: _head), const Text('SCORE', style: _head)),
            const SizedBox(height: 8),
            const Divider(height: 1),
            Expanded(
              child: entries.isEmpty
                  ? const Center(
                      child: Text('No scores yet',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: kMuted)))
                  : Scrollbar(
                      controller: _scroll,
                      thumbVisibility: true,
                      child: ListView.separated(
                        controller: _scroll,
                        padding: const EdgeInsets.only(bottom: 12),
                        itemCount: entries.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 9),
                          child: _row(
                            i < 5
                                ? Medal(place: i + 1)
                                : SizedBox(
                                    width: 32,
                                    child: Text('${i + 1}',
                                        textAlign: TextAlign.center,
                                        style: _bold.copyWith(fontSize: 16, color: kMuted))),
                            Text(entries[i].name, style: _bold, overflow: TextOverflow.ellipsis),
                            Text('${entries[i].score}', style: _bold.copyWith(color: kOkColor)),
                          ),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A round medal with the place number: gold, silver, bronze, then blue and green.
class Medal extends StatelessWidget {
  const Medal({super.key, required this.place});
  final int place;

  static const List<List<Color>> _colors = [
    [Color(0xFFFFE07A), Color(0xFFE0A800), Color(0xFFB07F00)], // 1st gold
    [Color(0xFFF1F3F5), Color(0xFFB4BCC4), Color(0xFF7F8993)], // 2nd silver
    [Color(0xFFF2B98A), Color(0xFFCD7F32), Color(0xFF9A5A1E)], // 3rd bronze
    [Color(0xFFA9C4FA), Color(0xFF4F7FE0), Color(0xFF2F5CB8)], // 4th
    [Color(0xFF9EE0BC), Color(0xFF2FA866), Color(0xFF1E7A48)], // 5th
  ];

  @override
  Widget build(BuildContext context) {
    final c = _colors[(place - 1).clamp(0, _colors.length - 1)];
    return Container(
      width: 32,
      height: 32,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [c[0], c[1]]),
        border: Border.all(color: c[2], width: 2),
      ),
      child: Text('$place',
          style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w900,
              color: Colors.white,
              shadows: [Shadow(color: Color(0x66000000), blurRadius: 2)])),
    );
  }
}

/// Settings > Clear leaderboards: asks for the admin password, then clears.
class AdminClearDialog extends StatefulWidget {
  const AdminClearDialog({super.key, required this.leaderboard});
  final Leaderboard leaderboard;

  @override
  State<AdminClearDialog> createState() => _AdminClearDialogState();
}

class _AdminClearDialogState extends State<AdminClearDialog> {
  final TextEditingController _pass = TextEditingController();
  bool _wrong = false;
  bool _done = false;

  @override
  void dispose() {
    _pass.dispose();
    super.dispose();
  }

  Future<void> _tryClear() async {
    if (_pass.text != kAdminPassword) {
      setState(() => _wrong = true);
      return;
    }
    await widget.leaderboard.clearAll();
    if (mounted) setState(() => _done = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_done) {
      return AlertDialog(
        title: const Text('Leaderboards cleared'),
        content: const Text('All names and scores were removed.'),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK'))],
      );
    }
    return AlertDialog(
      title: const Text('Clear leaderboards'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('This removes every name and score in all 3 leaderboards.'),
          const SizedBox(height: 12),
          TextField(
            controller: _pass,
            obscureText: true,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _tryClear(),
            onChanged: (_) {
              if (_wrong) setState(() => _wrong = false);
            },
            decoration: InputDecoration(
              labelText: 'Admin password',
              errorText: _wrong ? 'Wrong password' : null,
              border: const OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: kBadColor),
          onPressed: _tryClear,
          child: const Text('Clear'),
        ),
      ],
    );
  }
}

/// On-screen copies of the board buttons, for testing without the arcade buttons.
///
/// FIX: the old buttons were small (44 px circles) and used onTap, which only
/// fires when the finger is LIFTED, and is cancelled if the finger slides a
/// little. In a fast round that felt like "it doesn't touch", so players
/// pressed again and got a wrong answer. These buttons fire the moment the
/// finger touches (like a real arcade button), are much bigger, and show a
/// press so you know it registered.
class TestPad extends StatelessWidget {
  const TestPad({super.key, required this.onPress});
  final void Function(String button) onPress;

  @override
  Widget build(BuildContext context) {
    final k = uiScale(context);
    final gap = SizedBox(width: 6 * k);
    return SizedBox(
      height: 58 * k,
      child: Row(
        children: [
          SizedBox(
              width: 84 * k,
              child: PadButton(color: const Color(0xFF374151), label: 'START', onDown: () => onPress('start'))),
          gap,
          SizedBox(
              width: 84 * k,
              child: PadButton(color: const Color(0xFF6B7280), label: 'MENU', onDown: () => onPress('restart'))),
          SizedBox(width: 14 * k),
          for (final id in const ['red', 'blue', 'green', 'pink', 'orange', 'purple']) ...[
            Expanded(child: PadButton(color: kInk[id]!, onDown: () => onPress(id))),
            if (id != 'purple') gap,
          ],
        ],
      ),
    );
  }
}

/// A test button that fires on touch-down and shows that it is pressed.
class PadButton extends StatefulWidget {
  const PadButton({super.key, required this.color, required this.onDown, this.label});
  final Color color;
  final String? label;
  final VoidCallback onDown;

  @override
  State<PadButton> createState() => _PadButtonState();
}

class _PadButtonState extends State<PadButton> {
  int _fingers = 0;

  void _down(PointerDownEvent _) {
    _fingers++;
    if (_fingers == 1) setState(() {});
    widget.onDown();
  }

  void _up(PointerEvent _) {
    if (_fingers > 0) _fingers--;
    if (_fingers == 0 && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final k = uiScale(context);
    final pressed = _fingers > 0;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _down,
      onPointerUp: _up,
      onPointerCancel: _up,
      child: AnimatedScale(
        scale: pressed ? 0.9 : 1.0,
        duration: const Duration(milliseconds: 60),
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: pressed ? Color.lerp(widget.color, Colors.black, 0.25) : widget.color,
            borderRadius: BorderRadius.circular(14 * k),
            border: Border.all(color: Colors.white.withAlpha(pressed ? 220 : 90), width: 2 * k),
          ),
          child: widget.label == null
              ? null
              : FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6 * k),
                    child: Text(widget.label!,
                        style: TextStyle(fontSize: 14 * k, fontWeight: FontWeight.w800, color: Colors.white)),
                  ),
                ),
        ),
      ),
    );
  }
}