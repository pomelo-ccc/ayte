import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'local_sensevoice.dart';
import 'voice_settings.dart';
import 'voice_text_cleaner.dart';

/// Describes a locally installed OS TTS voice.
@immutable
class SystemVoiceInfo {
  const SystemVoiceInfo({required this.name, required this.locale});

  final String name;
  final String locale;

  String get displayLabel => locale.isEmpty ? name : '$name ($locale)';
}

/// Unified Text-to-Speech controller supporting:
/// - **Edge Neural TTS** (persistent Python `edge-tts` worker + sentence-by-
///   sentence streaming pipeline + native C++ Win32 MCI playback for <0.5s
///   first-word latency and instant Pause/Resume/Stop).
/// - **System engine**: Windows SAPI (`System.Speech`), macOS `/usr/bin/say`,
///   Linux `espeak-ng` / `espeak` / `spd-say`.
/// - **OpenAI-compatible API**: POST `/audio/speech` + native audio playback.
class VoiceTtsService extends ChangeNotifier {
  VoiceTtsService({VoiceSettingsStore? store, MethodChannel? channel})
    // ignore: prefer_initializing_formals
    : _store = store,
      _channel = channel ?? const MethodChannel('baocode/voice');

  static final VoiceTtsService instance = VoiceTtsService();

  static const _edgeIdleTimeout = Duration(minutes: 15);

  static const _edgeWorkerScript = r'''
import asyncio
import json
import sys
import edge_tts

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
if hasattr(sys.stdin, "reconfigure"):
    sys.stdin.reconfigure(encoding="utf-8")


async def synthesize(text: str, voice: str, rate: str, out_path: str):
    comm = edge_tts.Communicate(text, voice, rate=rate)
    await comm.save(out_path)


def main():
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    print(json.dumps({"ready": True}), flush=True)
    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue
        req_id = 0
        try:
            req = json.loads(line)
            req_id = int(req.get("id", 0))
            text = req.get("text", "")
            voice = req.get("voice", "zh-CN-XiaoxiaoNeural")
            rate = req.get("rate", "+0%")
            out_path = req.get("out", "")
            if not text or not out_path:
                raise ValueError("Missing text or output path")
            loop.run_until_complete(synthesize(text, voice, rate, out_path))
            print(json.dumps({"id": req_id, "ok": True}), flush=True)
        except Exception as exc:
            print(
                json.dumps({"id": req_id, "ok": False, "error": str(exc)}, ensure_ascii=False),
                flush=True,
            )


if __name__ == "__main__":
    main()
''';

  final VoiceSettingsStore? _store;
  final MethodChannel _channel;
  VoiceSettingsStore get _settings => _store ?? VoiceSettingsStore.instance;

  bool _speaking = false;
  bool _paused = false;
  bool _usingNativeAudio = false;
  String? _speakingId;
  String _currentSnippet = '';
  String? _lastError;
  Process? _activeProcess;
  final Set<Directory> _activeTempDirs = {};
  int _generation = 0;

  int _nativePlaySeq = 0;
  int _activeNativePlayId = 0;
  Completer<void>? _nativePlayDone;

  // Persistent Edge TTS Python worker state (eliminates ~1.5s process startup).
  Process? _edgeWorker;
  Completer<void>? _edgeReady;
  Future<void>? _edgeStarting;
  Timer? _edgeIdleTimer;
  int _edgeReqSeq = 0;
  final Map<int, Completer<Map<String, Object?>>> _edgePending = {};
  Future<void> _edgeQueue = Future<void>.value();
  String _edgeLastStderr = '';

  /// Fired when an auto-read AI reply finishes playing naturally (not stopped
  /// manually), used by Conversation Mode to automatically re-open the mic.
  VoidCallback? onAutoReadCompleted;

  bool get isSpeaking => _speaking;
  bool get isPaused => _paused;
  bool get canPause => _speaking && _usingNativeAudio;
  String? get speakingId => _speakingId;
  String get currentSnippet => _currentSnippet;
  String? get lastError => _lastError;

  bool isSpeakingId(String id) => _speaking && _speakingId == id;

  /// Called by [VoiceHotkeyService] when Windows native MCI finishes playing
  /// [playId].
  void handleNativePlaybackDone(int playId) {
    if (playId == _activeNativePlayId) {
      final done = _nativePlayDone;
      _nativePlayDone = null;
      _activeNativePlayId = 0;
      if (done != null && !done.isCompleted) {
        done.complete();
      }
    }
  }

  /// Speaks [text] (cleaned for natural speech unless [raw] is true).
  ///
  /// Passing [id] lets UI buttons highlight which specific turn is playing and
  /// toggle playback off on a second click.
  Future<void> speak(
    String text, {
    String? id,
    bool raw = false,
    bool isZh = false,
    bool autoRead = false,
  }) async {
    if (Platform.environment['FLUTTER_TEST'] == 'true') return;

    final cleaned = raw
        ? text.trim()
        : VoiceTextCleaner.cleanForSpeech(text, isZh: isZh);
    if (cleaned.isEmpty) return;

    await stop();
    final gen = ++_generation;
    _speaking = true;
    _paused = false;
    _usingNativeAudio = false;
    _speakingId = id;
    _currentSnippet = _makeSnippet(cleaned);
    _lastError = null;
    notifyListeners();

    final config = _settings.config;
    var completedNaturally = false;
    try {
      if (config.ttsEngine == VoiceTtsEngine.openaiCompatible) {
        final key = await _settings.readTtsApiKey();
        if (key != null && key.isNotEmpty) {
          await _speakViaOpenAi(cleaned, config: config, apiKey: key, gen: gen);
          completedNaturally = gen == _generation;
          return;
        }
        // Gracefully fall back if API key is missing.
      }
      if (config.ttsEngine == VoiceTtsEngine.edgeNeural) {
        try {
          await _speakViaEdgeNeuralStreaming(cleaned, config: config, gen: gen);
          completedNaturally = gen == _generation;
          return;
        } on Object {
          if (gen != _generation) return;
          // Offline or Edge TTS unavailable: fall back seamlessly to OS TTS.
        }
      }
      await _speakViaSystem(cleaned, config: config, gen: gen);
      completedNaturally = gen == _generation;
    } on Object catch (error) {
      if (gen == _generation) {
        _lastError = error.toString();
      }
    } finally {
      if (gen == _generation) {
        _speaking = false;
        _paused = false;
        _usingNativeAudio = false;
        _speakingId = null;
        _currentSnippet = '';
        notifyListeners();
        if (autoRead && completedNaturally) {
          final cb = onAutoReadCompleted;
          if (cb != null) {
            // Brief breath gap so speaker tail never bleeds into the mic.
            Timer(const Duration(milliseconds: 380), cb);
          }
        }
      }
    }
  }

  /// Toggles playback for [id]: stops if [id] is currently playing, otherwise
  /// speaks [text].
  Future<void> toggle(
    String text, {
    required String id,
    bool isZh = false,
  }) async {
    if (isSpeakingId(id)) {
      await stop();
    } else {
      await speak(text, id: id, isZh: isZh);
    }
  }

  /// Pauses ongoing native audio playback (Windows MCI).
  Future<void> pause() async {
    if (!_speaking || !_usingNativeAudio || _paused) return;
    try {
      final ok = await _channel.invokeMethod<bool>('pauseAudio');
      if (ok == true) {
        _paused = true;
        notifyListeners();
      }
    } on Object {
      // Ignore if native channel unavailable.
    }
  }

  /// Resumes paused native audio playback (Windows MCI).
  Future<void> resume() async {
    if (!_speaking || !_usingNativeAudio || !_paused) return;
    try {
      final ok = await _channel.invokeMethod<bool>('resumeAudio');
      if (ok == true) {
        _paused = false;
        notifyListeners();
      }
    } on Object {
      // Ignore if native channel unavailable.
    }
  }

  /// Toggles Pause/Resume when native audio playback is active.
  Future<void> togglePause() async {
    if (_paused) {
      await resume();
    } else {
      await pause();
    }
  }

  /// Updates the persisted speech rate (takes effect immediately for upcoming
  /// streamed chunks and future replies).
  Future<void> setRate(double rate) async {
    final clamped = rate.clamp(0.5, 2.0);
    await _settings.save(_settings.config.copyWith(ttsRate: clamped));
    notifyListeners();
  }

  /// Immediately stops any ongoing speech playback.
  Future<void> stop() async {
    _generation++;
    final proc = _activeProcess;
    _activeProcess = null;
    if (proc != null) {
      try {
        proc.kill();
      } on Object {
        // Ignore already-exited process.
      }
    }
    if (Platform.isWindows && (_usingNativeAudio || _nativePlayDone != null)) {
      try {
        await _channel.invokeMethod<bool>('stopAudio');
      } on Object {
        // Ignore if native channel unavailable.
      }
    }
    final done = _nativePlayDone;
    _nativePlayDone = null;
    _activeNativePlayId = 0;
    if (done != null && !done.isCompleted) {
      done.complete();
    }
    final dirs = List<Directory>.from(_activeTempDirs);
    _activeTempDirs.clear();
    for (final dir in dirs) {
      unawaited(_cleanupTempDir(dir));
    }
    if (_speaking || _paused || _speakingId != null || _currentSnippet.isNotEmpty) {
      _speaking = false;
      _paused = false;
      _usingNativeAudio = false;
      _speakingId = null;
      _currentSnippet = '';
      notifyListeners();
    }
  }

  /// Releases the background persistent Edge TTS worker immediately.
  void disposeEdgeWorker() {
    _edgeIdleTimer?.cancel();
    _edgeIdleTimer = null;
    final proc = _edgeWorker;
    _edgeWorker = null;
    _edgeReady = null;
    for (final pending in _edgePending.values) {
      if (!pending.isCompleted) {
        pending.completeError(StateError('Edge TTS worker stopped'));
      }
    }
    _edgePending.clear();
    proc?.kill();
  }

  /// Splits cleaned speech text into natural sentence chunks for streaming TTS:
  /// keeps the very first chunk concise (~<= 65 chars) so playback begins in
  /// <0.5s, and merges tiny trailing fragments so prosody stays smooth.
  static List<String> splitIntoSpeechSentences(String text) {
    final normalized = text
        .replaceAll('\r\n', '\n')
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .trim();
    if (normalized.isEmpty) return const [];

    // Split on paragraph breaks and sentence-ending punctuation (keeping
    // decimals like 3.14 and filenames like main.dart intact).
    final rawSegments = <String>[];
    final buf = StringBuffer();
    final runes = normalized.runes.toList();
    for (var i = 0; i < runes.length; i++) {
      final ch = String.fromCharCode(runes[i]);
      if (ch == '\n') {
        final s = buf.toString().trim();
        if (s.isNotEmpty) rawSegments.add(s);
        buf.clear();
        continue;
      }
      buf.write(ch);
      final isCjkEnd = ch == '。' || ch == '！' || ch == '？';
      final isAsciiEnd =
          (ch == '.' || ch == '!' || ch == '?') &&
          (i + 1 >= runes.length ||
              String.fromCharCode(runes[i + 1]) == ' ' ||
              String.fromCharCode(runes[i + 1]) == '\n');
      if (isCjkEnd || isAsciiEnd) {
        final s = buf.toString().trim();
        if (s.isNotEmpty) rawSegments.add(s);
        buf.clear();
      }
    }
    final tail = buf.toString().trim();
    if (tail.isNotEmpty) rawSegments.add(tail);
    if (rawSegments.isEmpty) return const [];

    // If the very first sentence is long (> 60 chars), split it at the first
    // clause comma/semicolon after ~18 chars for ultra-low first-word latency.
    if (rawSegments.first.length > 60) {
      final first = rawSegments.first;
      final splitAt = _findClauseBreak(first, minPos: 18, maxPos: 58);
      if (splitAt > 0 && splitAt < first.length - 8) {
        rawSegments[0] = first.substring(0, splitAt).trim();
        rawSegments.insert(1, first.substring(splitAt).trim());
      }
    }

    // Group chunks: keep chunk 0 concise (<= 75 chars), merge tiny subsequent
    // segments (< 30 chars) up to ~190 chars per chunk.
    final chunks = <String>[];
    for (final seg in rawSegments) {
      if (seg.isEmpty) continue;
      if (chunks.isEmpty) {
        chunks.add(seg);
        continue;
      }
      final isFirst = chunks.length == 1;
      final maxLen = isFirst ? 65 : 190;
      final joiner = VoiceTextCleaner.containsCjk(chunks.last) ? '' : ' ';
      if (!isFirst &&
          (chunks.last.length < 36 || seg.length < 24) &&
          chunks.last.length + seg.length + joiner.length <= maxLen) {
        chunks[chunks.length - 1] = '${chunks.last}$joiner$seg';
      } else {
        chunks.add(seg);
      }
    }
    return chunks;
  }

  static int _findClauseBreak(
    String s, {
    required int minPos,
    required int maxPos,
  }) {
    final limit = maxPos < s.length ? maxPos : s.length;
    for (var i = minPos; i < limit; i++) {
      final c = s[i];
      if (c == '，' || c == '；' || c == '：' || c == ',' || c == ';') {
        return i + 1;
      }
    }
    return -1;
  }

  static String _makeSnippet(String text) {
    final single = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (single.length <= 52) return single;
    return '${single.substring(0, 51)}…';
  }

  /// Lists available OS voices for the Settings dropdown.
  Future<List<SystemVoiceInfo>> listSystemVoices() async {
    if (Platform.environment['FLUTTER_TEST'] == 'true') return const [];
    try {
      if (Platform.isWindows) {
        final script = r'''
$ProgressPreference = 'SilentlyContinue'
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Speech
$s = New-Object System.Speech.Synthesis.SpeechSynthesizer
foreach ($v in $s.GetInstalledVoices()) {
  if ($v.Enabled) {
    Write-Output ($v.VoiceInfo.Name + "`t" + $v.VoiceInfo.Culture.Name)
  }
}
$s.Dispose()
''';
        final encoded = base64Encode(_utf16LeBytes(script));
        final result = await Process.run(
          'powershell.exe',
          [
            '-NoProfile',
            '-NonInteractive',
            '-WindowStyle',
            'Hidden',
            '-EncodedCommand',
            encoded,
          ],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        ).timeout(const Duration(seconds: 6));
        if (result.exitCode != 0) return const [];
        final out = result.stdout is String
            ? result.stdout as String
            : utf8.decode(result.stdout as List<int>);
        return [
          for (final line in const LineSplitter().convert(out))
            if (line.trim().isNotEmpty)
              (() {
                final parts = line.split('\t');
                return SystemVoiceInfo(
                  name: parts.first.trim(),
                  locale: parts.length > 1 ? parts[1].trim() : '',
                );
              })(),
        ];
      }
      if (Platform.isMacOS) {
        final result = await Process.run('/usr/bin/say', ['-v', '?'])
            .timeout(const Duration(seconds: 6));
        if (result.exitCode != 0) return const [];
        final out = result.stdout.toString();
        final pattern = RegExp(r'^(.+?)\s+([a-z]{2}_[A-Z]{2})\s+#');
        return [
          for (final line in const LineSplitter().convert(out))
            if (pattern.firstMatch(line) case final m?)
              SystemVoiceInfo(
                name: m.group(1)!.trim(),
                locale: m.group(2)!.replaceAll('_', '-'),
              ),
        ];
      }
    } on Object {
      // Ignore listing errors.
    }
    return const [];
  }

  Future<void> _speakViaSystem(
    String text, {
    required VoiceConfig config,
    required int gen,
  }) async {
    if (Platform.isWindows) {
      await _speakWindowsSapi(text, config: config, gen: gen);
      return;
    }
    if (Platform.isMacOS) {
      final wpm = (190 * config.ttsRate).round().clamp(90, 420);
      final args = <String>[
        '-r',
        '$wpm',
        if (config.ttsVoice.isNotEmpty) ...['-v', config.ttsVoice],
        text,
      ];
      await _runProcess('/usr/bin/say', args, gen: gen);
      return;
    }
    if (Platform.isLinux) {
      final wpm = (175 * config.ttsRate).round().clamp(80, 380);
      for (final (bin, args) in <(String, List<String>)>[
        (
          'espeak-ng',
          [
            '-s',
            '$wpm',
            if (config.ttsVoice.isNotEmpty) ...['-v', config.ttsVoice],
            text,
          ],
        ),
        ('espeak', ['-s', '$wpm', text]),
        ('spd-say', ['-w', text]),
      ]) {
        try {
          await _runProcess(bin, args, gen: gen);
          return;
        } on ProcessException {
          continue;
        }
      }
    }
  }

  Future<void> _speakWindowsSapi(
    String text, {
    required VoiceConfig config,
    required int gen,
  }) async {
    // Map rate 0.5..2.0 to SAPI -6..+6 (0 is normal 1.0x).
    final sapiRate = ((config.ttsRate - 1.0) * 6).round().clamp(-10, 10);
    final preferZh = VoiceTextCleaner.containsCjk(text);
    final escapedVoice = config.ttsVoice.replaceAll("'", "''");
    final textB64 = base64Encode(utf8.encode(text));

    // Read base64-encoded UTF-8 text from stdin so arbitrarily long replies
    // never hit Windows' 32 KB command-line length limit.
    final script = '''
Add-Type -AssemblyName System.Speech
\$synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
try {
  \$synth.Rate = $sapiRate
  \$voiceName = '$escapedVoice'
  if (\$voiceName) {
    try { \$synth.SelectVoice(\$voiceName) } catch {}
  } else {
    \$prefer = '${preferZh ? 'zh' : 'en'}'
    \$match = \$synth.GetInstalledVoices() | Where-Object { \$_.Enabled -and \$_.VoiceInfo.Culture.TwoLetterISOLanguageName -ieq \$prefer } | Select-Object -First 1
    if (\$match) { \$synth.SelectVoice(\$match.VoiceInfo.Name) }
  }
  \$b64 = [Console]::In.ReadToEnd().Trim()
  if (\$b64) {
    \$bytes = [Convert]::FromBase64String(\$b64)
    \$msg = [System.Text.Encoding]::UTF8.GetString(\$bytes)
    \$synth.Speak(\$msg)
  }
} finally {
  \$synth.Dispose()
}
''';

    final encoded = base64Encode(_utf16LeBytes(script));
    await _runProcess(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle',
        'Hidden',
        '-EncodedCommand',
        encoded,
      ],
      gen: gen,
      stdinText: textB64,
    );
  }

  /// Formats speech rate multiplier (0.5..2.0) as an Edge TTS percentage
  /// string (`+0%`, `+25%`, `-15%`).
  static String formatEdgeRate(double rate) {
    final pct = ((rate.clamp(0.5, 2.0) - 1.0) * 100).round();
    return pct >= 0 ? '+$pct%' : '$pct%';
  }

  /// Picks the appropriate Edge Neural voice: automatically switches a Chinese
  /// voice to `en-US-AriaNeural` when reading purely English text.
  static String pickEdgeVoice(String configuredVoice, String text) {
    final voice = configuredVoice.trim().isEmpty
        ? VoiceConfig.defaultEdgeVoice
        : configuredVoice.trim();
    if (voice.startsWith('zh-') && !VoiceTextCleaner.containsCjk(text)) {
      return 'en-US-AriaNeural';
    }
    return voice;
  }

  void _touchEdgeIdleTimer() {
    _edgeIdleTimer?.cancel();
    _edgeIdleTimer = Timer(_edgeIdleTimeout, () {
      if (_edgePending.isEmpty && !_speaking) {
        disposeEdgeWorker();
      }
    });
  }

  Future<void> _ensureEdgeWorkerStarted() {
    if (_edgeWorker != null && _edgeReady != null && _edgeReady!.isCompleted) {
      return Future.value();
    }
    if (_edgeStarting != null) return _edgeStarting!;
    final future = _startEdgeWorker();
    _edgeStarting = future;
    future.whenComplete(() {
      if (identical(_edgeStarting, future)) _edgeStarting = null;
    });
    return future;
  }

  Future<void> _startEdgeWorker() async {
    final pythonExe = LocalSenseVoice.locatePythonExe();
    if (pythonExe == null) {
      throw StateError('Edge TTS Python runtime not installed');
    }
    final scriptFile = File(
      p.join(Directory.systemTemp.path, 'ayte_edge_tts_worker.py'),
    );
    if (!await scriptFile.exists() ||
        await scriptFile.readAsString() != _edgeWorkerScript) {
      await scriptFile.writeAsString(_edgeWorkerScript, flush: true);
    }

    _edgeLastStderr = '';
    final ready = Completer<void>();
    _edgeReady = ready;

    final proc = await Process.start(
      pythonExe,
      ['-u', scriptFile.path],
      environment: const {'PYTHONIOENCODING': 'utf-8'},
    );
    _edgeWorker = proc;
    proc.stderr.transform(utf8.decoder).listen((chunk) {
      _edgeLastStderr += chunk;
    });
    proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            final trimmed = line.trim();
            if (trimmed.isEmpty) return;
            try {
              final decoded = jsonDecode(trimmed);
              if (decoded is Map<String, Object?>) {
                if (decoded['ready'] == true) {
                  if (!ready.isCompleted) ready.complete();
                  return;
                }
                final id = (decoded['id'] as num?)?.toInt();
                if (id != null) {
                  final completer = _edgePending.remove(id);
                  if (completer != null && !completer.isCompleted) {
                    completer.complete(decoded);
                  }
                }
              }
            } on Object {
              // Ignore non-JSON log lines.
            }
          },
          onDone: () {
            if (identical(_edgeWorker, proc)) {
              _edgeWorker = null;
            }
            final err = _edgeLastStderr.trim();
            if (!ready.isCompleted) {
              ready.completeError(
                StateError(err.isEmpty ? 'Edge TTS worker failed' : err),
              );
            }
            for (final completer in _edgePending.values) {
              if (!completer.isCompleted) {
                completer.completeError(
                  StateError(err.isEmpty ? 'Edge TTS worker exited' : err),
                );
              }
            }
            _edgePending.clear();
          },
        );

    try {
      await ready.future.timeout(const Duration(seconds: 12));
    } on Object {
      disposeEdgeWorker();
      rethrow;
    }
  }

  Future<File> _synthesizeEdgeChunk({
    required String text,
    required String voice,
    required String rate,
    required File outFile,
  }) {
    final completer = Completer<File>();
    _edgeQueue = _edgeQueue.then((_) async {
      try {
        await _ensureEdgeWorkerStarted();
        _touchEdgeIdleTimer();
        final proc = _edgeWorker;
        if (proc == null) {
          throw StateError('Edge TTS worker not running');
        }
        final reqId = ++_edgeReqSeq;
        final respCompleter = Completer<Map<String, Object?>>();
        _edgePending[reqId] = respCompleter;
        proc.stdin.writeln(
          jsonEncode({
            'id': reqId,
            'text': text,
            'voice': voice,
            'rate': rate,
            'out': outFile.path,
          }),
        );
        await proc.stdin.flush();
        final resp = await respCompleter.future.timeout(
          const Duration(seconds: 22),
          onTimeout: () {
            _edgePending.remove(reqId);
            disposeEdgeWorker();
            throw StateError('Edge TTS synthesis timeout');
          },
        );
        if (resp['ok'] != true ||
            !await outFile.exists() ||
            await outFile.length() < 128) {
          throw StateError(
            (resp['error'] as String?) ?? 'Edge TTS synthesis failed',
          );
        }
        completer.complete(outFile);
      } on Object catch (err, st) {
        if (!completer.isCompleted) {
          completer.completeError(err, st);
        }
      }
    });
    return completer.future;
  }

  Future<void> _speakViaEdgeNeuralStreaming(
    String text, {
    required VoiceConfig config,
    required int gen,
  }) async {
    final chunks = splitIntoSpeechSentences(text);
    if (chunks.isEmpty) return;

    final dir = await Directory.systemTemp.createTemp('ayte_tts_');
    _activeTempDirs.add(dir);

    Future<File> queueChunk(int index) {
      final chunkText = chunks[index];
      // Read live rate from settings so mid-speech speed toggles apply to next sentence!
      final liveConfig = _settings.config;
      final voice = pickEdgeVoice(liveConfig.ttsEdgeVoice, chunkText);
      final rate = formatEdgeRate(liveConfig.ttsRate);
      final outFile = File(p.join(dir.path, 'chunk_$index.mp3'));
      return _synthesizeEdgeChunk(
        text: chunkText,
        voice: voice,
        rate: rate,
        outFile: outFile,
      );
    }

    try {
      Future<File>? pendingFile = queueChunk(0);
      for (var i = 0; i < chunks.length; i++) {
        if (gen != _generation) return;
        final audioFile = await pendingFile!;
        if (gen != _generation) return;

        // Pre-synthesize the next sentence concurrently while playing current.
        if (i + 1 < chunks.length) {
          pendingFile = queueChunk(i + 1);
          unawaited(pendingFile.catchError((Object _) => audioFile));
        } else {
          pendingFile = null;
        }

        _currentSnippet = _makeSnippet(chunks[i]);
        notifyListeners();
        await _playAudioFile(audioFile.path, gen: gen);
      }
    } finally {
      _activeTempDirs.remove(dir);
      unawaited(_cleanupTempDir(dir));
    }
  }

  Future<void> _speakViaOpenAi(
    String text, {
    required VoiceConfig config,
    required String apiKey,
    required int gen,
  }) async {
    final audioBytes = await synthesizeViaOpenAi(
      text: text,
      baseUrl: config.ttsApiBaseUrl,
      apiKey: apiKey,
      model: config.ttsModel,
      voice: config.ttsApiVoice,
      speed: config.ttsRate,
    );
    if (gen != _generation) return;

    final dir = await Directory.systemTemp.createTemp('ayte_tts_');
    _activeTempDirs.add(dir);
    final file = File(p.join(dir.path, 'speech.mp3'));
    await file.writeAsBytes(audioBytes, flush: true);

    try {
      await _playAudioFile(file.path, gen: gen);
    } finally {
      _activeTempDirs.remove(dir);
      unawaited(_cleanupTempDir(dir));
    }
  }

  Future<void> _playAudioFile(String filePath, {required int gen}) async {
    if (Platform.isWindows) {
      final playedNative = await _tryPlayWindowsNative(filePath, gen: gen);
      if (playedNative) return;
      if (gen != _generation) return;
      await _playWindowsPowerShellFallback(filePath, gen: gen);
      return;
    }
    if (Platform.isMacOS) {
      await _runProcess('/usr/bin/afplay', [filePath], gen: gen);
      return;
    }
    if (Platform.isLinux) {
      for (final (bin, args) in <(String, List<String>)>[
        ('ffplay', ['-nodisp', '-autoexit', '-loglevel', 'quiet', filePath]),
        ('mpg123', ['-q', filePath]),
        ('paplay', [filePath]),
      ]) {
        try {
          await _runProcess(bin, args, gen: gen);
          return;
        } on ProcessException {
          continue;
        }
      }
    }
  }

  Future<bool> _tryPlayWindowsNative(
    String filePath, {
    required int gen,
  }) async {
    final playId = ++_nativePlaySeq;
    final done = Completer<void>();
    _activeNativePlayId = playId;
    _nativePlayDone = done;
    try {
      final ok = await _channel.invokeMethod<bool>('playAudio', {
        'path': filePath,
        'id': playId,
      });
      if (ok != true) {
        if (identical(_nativePlayDone, done)) {
          _nativePlayDone = null;
          _activeNativePlayId = 0;
        }
        return false;
      }
      if (gen != _generation) {
        unawaited(_channel.invokeMethod<bool>('stopAudio').catchError((_) => null));
        return true;
      }
      if (!_usingNativeAudio) {
        _usingNativeAudio = true;
        notifyListeners();
      }
      await done.future;
      return true;
    } on MissingPluginException {
      if (identical(_nativePlayDone, done)) {
        _nativePlayDone = null;
        _activeNativePlayId = 0;
      }
      return false;
    } on PlatformException {
      if (identical(_nativePlayDone, done)) {
        _nativePlayDone = null;
        _activeNativePlayId = 0;
      }
      return false;
    }
  }

  Future<void> _playWindowsPowerShellFallback(
    String filePath, {
    required int gen,
  }) async {
    final escaped = filePath.replaceAll('"', '');
    final script = '''
\$ProgressPreference = 'SilentlyContinue'
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class AyteMciPlay {
  [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
  public static extern uint mciSendStringW(string cmd, StringBuilder ret, int retLen, IntPtr cb);
}
"@
\$alias = "ayte_tts_" + \$PID
\$sb = New-Object System.Text.StringBuilder 256
try {
  [void][AyteMciPlay]::mciSendStringW('open "$escaped" type mpegvideo alias ' + \$alias, \$sb, 256, [IntPtr]::Zero)
  [void][AyteMciPlay]::mciSendStringW('play ' + \$alias + ' wait', \$sb, 256, [IntPtr]::Zero)
} finally {
  [void][AyteMciPlay]::mciSendStringW('close ' + \$alias, \$sb, 256, [IntPtr]::Zero)
}
''';
    final encoded = base64Encode(_utf16LeBytes(script));
    await _runProcess('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-WindowStyle',
      'Hidden',
      '-EncodedCommand',
      encoded,
    ], gen: gen);
  }

  Future<void> _runProcess(
    String executable,
    List<String> args, {
    required int gen,
    String? stdinText,
  }) async {
    final proc = await Process.start(executable, args);
    if (gen != _generation) {
      proc.kill();
      return;
    }
    _activeProcess = proc;
    // Drain streams so the child process cannot block on full pipes.
    unawaited(proc.stdout.drain<void>());
    unawaited(proc.stderr.drain<void>());
    if (stdinText != null) {
      try {
        proc.stdin.write(stdinText);
        await proc.stdin.close();
      } on Object {
        // Process may already have been stopped.
      }
    }
    try {
      await proc.exitCode;
    } finally {
      if (identical(_activeProcess, proc)) {
        _activeProcess = null;
      }
    }
  }

  /// Calls an OpenAI-compatible `/audio/speech` endpoint and returns MP3 bytes.
  static Future<List<int>> synthesizeViaOpenAi({
    required String text,
    required String baseUrl,
    required String apiKey,
    required String model,
    required String voice,
    double speed = 1.0,
    HttpClient? client,
  }) async {
    final ownClient = client == null;
    final http = client ?? HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final uri = buildSpeechUri(baseUrl);
      final payload = jsonEncode({
        'model': model,
        'input': text,
        'voice': voice,
        'speed': speed.clamp(0.25, 4.0),
        'response_format': 'mp3',
      });
      final req = await http.postUrl(uri);
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      req.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/json; charset=utf-8',
      );
      req.add(utf8.encode(payload));

      final res = await req.close().timeout(const Duration(seconds: 60));
      final bytes = await consolidateHttpClientResponseBytes(res);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        final msg = utf8.decode(bytes, allowMalformed: true);
        throw HttpException('HTTP ${res.statusCode}: $msg');
      }
      return bytes;
    } finally {
      if (ownClient) http.close();
    }
  }

  static Uri buildSpeechUri(String baseUrl) {
    final trimmed = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (trimmed.endsWith('/audio/speech')) {
      return Uri.parse(trimmed);
    }
    return Uri.parse('$trimmed/audio/speech');
  }

  static Future<void> _cleanupTempDir(Directory dir) async {
    try {
      if (await dir.exists() && p.basename(dir.path).startsWith('ayte_tts_')) {
        await dir.delete(recursive: true);
      }
    } on Object {
      // Best-effort cleanup.
    }
  }

  static List<int> _utf16LeBytes(String text) {
    final units = text.codeUnits;
    final bytes = List<int>.filled(units.length * 2, 0);
    for (var i = 0; i < units.length; i++) {
      bytes[i * 2] = units[i] & 0xFF;
      bytes[i * 2 + 1] = (units[i] >> 8) & 0xFF;
    }
    return bytes;
  }
}
