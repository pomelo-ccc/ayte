import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
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
/// - **System engine**: Windows SAPI (`System.Speech`), macOS `/usr/bin/say`,
///   Linux `espeak-ng` / `espeak` / `spd-say`.
/// - **OpenAI-compatible API**: POST `/audio/speech` + native audio playback.
class VoiceTtsService extends ChangeNotifier {
  // ignore: prefer_initializing_formals
  VoiceTtsService({VoiceSettingsStore? store}) : _store = store;

  static final VoiceTtsService instance = VoiceTtsService();

  final VoiceSettingsStore? _store;
  VoiceSettingsStore get _settings => _store ?? VoiceSettingsStore.instance;

  bool _speaking = false;
  String? _speakingId;
  String? _lastError;
  Process? _activeProcess;
  File? _activeTempFile;
  int _generation = 0;

  /// Fired when an auto-read AI reply finishes playing naturally (not stopped
  /// manually), used by Conversation Mode to automatically re-open the mic.
  VoidCallback? onAutoReadCompleted;

  bool get isSpeaking => _speaking;
  String? get speakingId => _speakingId;
  String? get lastError => _lastError;

  bool isSpeakingId(String id) => _speaking && _speakingId == id;

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
    _speakingId = id;
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
          await _speakViaEdgeNeural(cleaned, config: config, gen: gen);
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
        _speakingId = null;
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
    final temp = _activeTempFile;
    _activeTempFile = null;
    if (temp != null) {
      unawaited(_cleanupTempFile(temp));
    }
    if (_speaking || _speakingId != null) {
      _speaking = false;
      _speakingId = null;
      notifyListeners();
    }
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

  Future<void> _speakViaEdgeNeural(
    String text, {
    required VoiceConfig config,
    required int gen,
  }) async {
    final pythonExe = LocalSenseVoice.locatePythonExe();
    if (pythonExe == null) {
      throw StateError('Edge TTS Python runtime not installed');
    }

    final voice = pickEdgeVoice(config.ttsEdgeVoice, text);
    final rate = formatEdgeRate(config.ttsRate);
    final dir = await Directory.systemTemp.createTemp('ayte_tts_');
    final file = File(p.join(dir.path, 'edge_speech.mp3'));
    _activeTempFile = file;

    const pyCode =
        'import asyncio, base64, sys, edge_tts\n'
        'async def main():\n'
        '    text = base64.b64decode(sys.stdin.read().strip()).decode("utf-8")\n'
        '    comm = edge_tts.Communicate(text, sys.argv[1], rate=sys.argv[2])\n'
        '    await comm.save(sys.argv[3])\n'
        'asyncio.run(main())\n';

    try {
      final textB64 = base64Encode(utf8.encode(text));
      final proc = await Process.start(
        pythonExe,
        ['-c', pyCode, voice, rate, file.path],
        environment: const {'PYTHONIOENCODING': 'utf-8'},
      );
      if (gen != _generation) {
        proc.kill();
        return;
      }
      _activeProcess = proc;
      unawaited(proc.stdout.drain<void>());
      final stderrFuture = utf8.decodeStream(proc.stderr);
      try {
        proc.stdin.write(textB64);
        await proc.stdin.close();
      } on Object {
        // Ignore if cancelled early.
      }
      final code = await proc.exitCode.timeout(
        const Duration(seconds: 25),
        onTimeout: () {
          proc.kill();
          return -1;
        },
      );
      if (identical(_activeProcess, proc)) _activeProcess = null;
      if (gen != _generation) return;
      if (code != 0 || !await file.exists() || await file.length() < 128) {
        final err = (await stderrFuture).trim();
        throw StateError(err.isEmpty ? 'Edge TTS synthesis failed' : err);
      }
      await _playAudioFile(file.path, gen: gen);
    } finally {
      if (identical(_activeTempFile, file)) {
        _activeTempFile = null;
      }
      await _cleanupTempFile(file);
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
    final file = File(p.join(dir.path, 'speech.mp3'));
    await file.writeAsBytes(audioBytes, flush: true);
    _activeTempFile = file;

    try {
      await _playAudioFile(file.path, gen: gen);
    } finally {
      if (identical(_activeTempFile, file)) {
        _activeTempFile = null;
      }
      await _cleanupTempFile(file);
    }
  }

  Future<void> _playAudioFile(String filePath, {required int gen}) async {
    if (Platform.isWindows) {
      final escaped = filePath.replaceAll('"', '');
      // Use winmm.dll MCI mpegvideo: plays MP3 and WAV reliably on headless
      // console threads without needing a WPF Dispatcher loop.
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

  static Future<void> _cleanupTempFile(File file) async {
    try {
      final parent = Directory(p.dirname(file.path));
      if (await parent.exists() &&
          p.basename(parent.path).startsWith('ayte_tts_')) {
        await parent.delete(recursive: true);
      } else if (await file.exists()) {
        await file.delete();
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
