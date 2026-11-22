import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'local_sensevoice.dart';
import 'voice_ai_corrector.dart';
import 'voice_settings.dart';
import 'voice_tts_service.dart';
import 'wav_recorder.dart';

/// Current state of Speech-to-Text capture.
enum VoiceSttState { idle, starting, listening, transcribing, correcting }

/// Result delivered when a dictation session completes.
class VoiceSttResult {
  const VoiceSttResult(this.text, {this.error});

  final String text;
  final String? error;

  bool get hasText => text.trim().isNotEmpty;
}

/// Unified Speech-to-Text service supporting:
/// - **System engine** (Windows `System.Speech.Recognition`, free & offline)
/// - **OpenAI-compatible API** (`/audio/transcriptions` multipart WAV upload)
class VoiceSttService extends ChangeNotifier {
  VoiceSttService({VoiceSettingsStore? store, WavRecorder? recorder})
    : _recorder = recorder ?? WavRecorder(),
      // ignore: prefer_initializing_formals
      _store = store;

  static final VoiceSttService instance = VoiceSttService();

  final VoiceSettingsStore? _store;
  final WavRecorder _recorder;

  VoiceSettingsStore get _settings => _store ?? VoiceSettingsStore.instance;

  VoiceSttState _state = VoiceSttState.idle;
  String _partialText = '';
  final List<String> _finalSegments = [];
  String? _lastError;
  DateTime? _startedAt;
  Timer? _elapsedTimer;
  Timer? _streamTimer;
  Duration _elapsed = Duration.zero;
  Process? _systemProcess;
  Completer<VoiceSttResult>? _systemCompleter;
  Object? _activeOwner;
  int _streamSessionId = 0;
  int _lastStreamBytes = 0;
  bool _streamPolling = false;
  bool _metricsPolling = false;
  double _audioLevel = 0.0;
  final List<double> _levelHistory = <double>[0.1, 0.1, 0.1, 0.1, 0.1];
  VoidCallback? _onAutoStop;
  bool _autoStopTriggered = false;
  Completer<void>? _correctCancel;

  VoiceSttState get state => _state;
  bool get isStarting => _state == VoiceSttState.starting;
  bool get isListening => _state == VoiceSttState.listening;
  bool get isTranscribing => _state == VoiceSttState.transcribing;
  bool get isCorrecting => _state == VoiceSttState.correcting;
  bool get isBusy => _state != VoiceSttState.idle;
  double get audioLevel => _audioLevel;
  List<double> get levelHistory => List.unmodifiable(_levelHistory);
  String get partialText => _partialText;
  String get liveTranscript => mergeTranscript(_finalSegments, _partialText);

  /// Appends a finalized [segment] to [segments] while preventing SAPI
  /// consecutive duplicates and cumulative-prefix duplication.
  static void appendSegment(List<String> segments, String segment) {
    final clean = segment.trim();
    if (clean.isEmpty) return;
    if (segments.isNotEmpty) {
      final last = segments.last;
      if (clean == last) return;
      // Cumulative update extending the previous segment: replace rather than append.
      if (clean.startsWith(last)) {
        segments[segments.length - 1] = clean;
        return;
      }
      // Trailing fragment already contained at the end of the previous segment.
      if (last.endsWith(clean)) return;
    }
    segments.add(clean);
  }

  /// Merges finalized [segments] and an optional live [partial] hypothesis
  /// without duplicating text already captured in the last finalized segment.
  static String mergeTranscript(List<String> segments, String partial) {
    final parts = List<String>.from(segments);
    final p = partial.trim();
    if (p.isNotEmpty) {
      if (parts.isEmpty) {
        parts.add(p);
      } else {
        final last = parts.last;
        if (p == last || last.endsWith(p)) {
          // Already included in the latest finalized segment.
        } else if (p.startsWith(last)) {
          parts[parts.length - 1] = p;
        } else {
          parts.add(p);
        }
      }
    }
    return parts.join(parts.any(_hasCjk) ? '' : ' ').trim();
  }

  String? get lastError => _lastError;
  Duration get elapsed => _elapsed;
  Object? get activeOwner => _activeOwner;

  static bool _hasCjk(String s) => RegExp(r'[\u4e00-\u9fff]').hasMatch(s);

  static final _stopPhrasePunct = RegExp(r'''[\s，。！？,.!?、；;：:~～"'“”‘’]+''');
  static const _stopConversationPhrases = <String>{
    '结束对话',
    '停止对话',
    '退出对话',
    '关闭对话',
    '结束语音',
    '停止语音',
    '退出语音',
    '关闭语音',
    '结束语音对话',
    '停止语音对话',
    '退出语音对话',
    '结束吧',
    '好了结束吧',
    '就到这里吧',
    'stopconversation',
    'endconversation',
    'exitconversation',
    'stopvoice',
  };

  /// Returns true when a short dictated utterance is purely a command to exit
  /// hands-free Voice Conversation Mode (so it exits cleanly instead of being
  /// sent as a chat prompt).
  static bool isStopConversationCommand(String text) {
    final normalized = text
        .trim()
        .toLowerCase()
        .replaceAll(_stopPhrasePunct, '');
    if (normalized.isEmpty || normalized.length > 20) return false;
    return _stopConversationPhrases.contains(normalized);
  }

  /// Starts capturing voice input for [owner].
  /// Optionally passes [onAutoStop] to trigger automatic stop when VAD detects
  /// a silence pause after speech.
  /// Returns true if listening started successfully.
  Future<bool> start({Object? owner, VoidCallback? onAutoStop}) async {
    if (_state == VoiceSttState.starting ||
        _state == VoiceSttState.transcribing ||
        _state == VoiceSttState.correcting) {
      return false;
    }
    if (_state != VoiceSttState.idle) {
      await cancel();
    }
    // Echo prevention: immediately stop any ongoing TTS playback before opening mic.
    unawaited(VoiceTtsService.instance.stop());

    _lastError = null;
    _partialText = '';
    _finalSegments.clear();
    _activeOwner = owner;
    _onAutoStop = onAutoStop;
    _autoStopTriggered = false;
    _audioLevel = 0.0;
    _levelHistory.fillRange(0, _levelHistory.length, 0.1);
    _state = VoiceSttState.starting;
    notifyListeners();

    final config = _settings.config;
    try {
      if (config.sttEngine == VoiceSttEngine.localAi) {
        if (!LocalSenseVoice.isInstalled) {
          throw StateError(
            '未检测到本地 SenseVoice 模型（D:\\Ayte\\voice-models\\sense-voice），请在「设置 → 语音」切换引擎。',
          );
        }
        // Pre-warm the ONNX model in background while recording so live
        // streaming and final stopping produce results in ~0.1s.
        LocalSenseVoice.instance.warmUp();
        await _recorder.start();
      } else if (config.sttEngine == VoiceSttEngine.system) {
        await _startSystemStt(config);
      } else {
        await _startApiRecording(config);
      }
      if (_state != VoiceSttState.starting || !identical(_activeOwner, owner)) {
        return false;
      }
      _state = VoiceSttState.listening;
      _startedAt = DateTime.now();
      _elapsed = Duration.zero;
      _elapsedTimer?.cancel();
      _elapsedTimer = Timer.periodic(const Duration(milliseconds: 110), (_) {
        if (_startedAt != null && _state == VoiceSttState.listening) {
          _elapsed = DateTime.now().difference(_startedAt!);
          if (!_metricsPolling) {
            unawaited(_pollAudioMetrics());
          }
          notifyListeners();
        }
      });
      if (config.sttEngine == VoiceSttEngine.localAi && config.sttStreaming) {
        _startLocalAiStreaming();
      }
      notifyListeners();
      return true;
    } on Object catch (error) {
      _lastError = _friendlyError(error);
      _state = VoiceSttState.idle;
      _activeOwner = null;
      _onAutoStop = null;
      notifyListeners();
      return false;
    }
  }

  Future<void> _pollAudioMetrics() async {
    _metricsPolling = true;
    try {
      final metrics = await _recorder.readMetrics();
      if (metrics == null || _state != VoiceSttState.listening) return;
      final smoothed = (_audioLevel * 0.45) + (metrics.level * 0.55);
      _audioLevel = smoothed.clamp(0.0, 1.0);
      _levelHistory.removeAt(0);
      _levelHistory.add(_audioLevel.clamp(0.08, 1.0));

      final cfg = _settings.config;
      if (cfg.effectiveVadAutoStop &&
          !_autoStopTriggered &&
          metrics.heardSpeech &&
          _elapsed.inMilliseconds >= 1100 &&
          metrics.silenceMs >= cfg.sttVadSilenceMs) {
        _autoStopTriggered = true;
        final cb = _onAutoStop;
        if (cb != null) {
          scheduleMicrotask(cb);
        }
      }
    } finally {
      _metricsPolling = false;
    }
  }

  void _startLocalAiStreaming() {
    _streamTimer?.cancel();
    _streamSessionId++;
    _lastStreamBytes = 44;
    _streamPolling = false;
    final sid = _streamSessionId;
    _streamTimer = Timer.periodic(const Duration(milliseconds: 450), (_) {
      if (_state != VoiceSttState.listening || _streamPolling) return;
      final path = _recorder.activeFilePath;
      if (path == null) return;
      unawaited(_pollLocalAiFrame(path, sid));
    });
  }

  Future<void> _pollLocalAiFrame(String path, int sid) async {
    _streamPolling = true;
    try {
      final file = File(path);
      if (!await file.exists()) return;
      final length = await file.length();
      // Require at least ~0.25s (8000 bytes) of new PCM before re-decoding.
      if (length - _lastStreamBytes < 6000) return;
      final text = await LocalSenseVoice.instance.transcribeLive(
        path,
        sessionId: sid,
      );
      if (_state != VoiceSttState.listening || sid != _streamSessionId) return;
      if (text != null) {
        _lastStreamBytes = length;
        if (text.isNotEmpty && text != _partialText) {
          _partialText = text;
          notifyListeners();
        }
      }
    } on Object {
      // Best-effort live preview; final decode will capture everything cleanly.
    } finally {
      _streamPolling = false;
    }
  }

  /// Runs AI post-correction on [rawText] while exposing [VoiceSttState.correcting]
  /// so the composer voice bar displays a subtle progress badge with a Skip button.
  Future<String> correctWithAi(
    String rawText, {
    required Object owner,
    String? lastReply,
    String? model,
    String? location,
  }) async {
    final trimmed = rawText.trim();
    if (trimmed.isEmpty) return trimmed;
    final cancel = Completer<void>();
    _correctCancel = cancel;
    _activeOwner = owner;
    _state = VoiceSttState.correcting;
    notifyListeners();
    try {
      return await VoiceAiCorrector.correct(
        trimmed,
        lastReply: lastReply,
        glossary: _settings.config.sttGlossary,
        model: model,
        location: location,
        cancel: cancel.future,
      );
    } finally {
      if (identical(_correctCancel, cancel)) {
        _correctCancel = null;
      }
      if (_state == VoiceSttState.correcting &&
          identical(_activeOwner, owner)) {
        _state = VoiceSttState.idle;
        _activeOwner = null;
        notifyListeners();
      }
    }
  }

  /// Immediately skips an in-progress AI post-correction and keeps the raw
  /// voice transcript.
  void skipAiCorrection() {
    final cancel = _correctCancel;
    _correctCancel = null;
    if (cancel != null && !cancel.isCompleted) {
      cancel.complete();
    }
    if (_state == VoiceSttState.correcting) {
      _state = VoiceSttState.idle;
      _activeOwner = null;
      notifyListeners();
    }
  }

  /// Stops listening and returns the recognized transcript.
  Future<VoiceSttResult> stop() async {
    if (_state != VoiceSttState.listening) {
      return const VoiceSttResult('');
    }
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
    _streamTimer?.cancel();
    _streamTimer = null;
    final config = _settings.config;

    if (config.sttEngine == VoiceSttEngine.localAi) {
      return _stopLocalAiRecordingAndTranscribe();
    }
    if (config.sttEngine == VoiceSttEngine.system) {
      return _stopSystemStt();
    }
    return _stopApiRecordingAndTranscribe(config);
  }

  /// Cancels any active listening or transcription without returning text.
  Future<void> cancel() async {
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
    _streamTimer?.cancel();
    _streamTimer = null;
    _streamPolling = false;
    _startedAt = null;
    _elapsed = Duration.zero;
    _partialText = '';
    _finalSegments.clear();
    _activeOwner = null;

    final proc = _systemProcess;
    _systemProcess = null;
    if (proc != null) {
      try {
        proc.stdin.writeln('CANCEL');
        await proc.stdin.flush();
      } on Object {
        // Ignore broken pipe.
      }
      proc.kill();
    }
    final completer = _systemCompleter;
    _systemCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(const VoiceSttResult(''));
    }

    if (_recorder.isRecording) {
      await _recorder.cancel();
    }

    if (_state != VoiceSttState.idle) {
      _state = VoiceSttState.idle;
      notifyListeners();
    }
  }

  Future<void> _startSystemStt(VoiceConfig config) async {
    if (!Platform.isWindows) {
      throw StateError(
        '系统内置离线语音识别当前仅支持 Windows；macOS/Linux 请在「设置 → 语音」切换为自定义 OpenAI 兼容语音 API（Whisper）。',
      );
    }

    final preferredCulture = config.sttLanguage == 'auto'
        ? 'zh-CN'
        : config.sttLanguage;
    final escapedCulture = preferredCulture.replaceAll('"', '');
    // Use an inline C# class so SpeechHypothesized / SpeechRecognized events
    // fire immediately on SAPI's callback thread while the main thread blocks
    // on Console.In.ReadLine() waiting for STOP / CANCEL.
    final script = '''
\$ProgressPreference = 'SilentlyContinue'
\$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -ReferencedAssemblies System.Speech -TypeDefinition @"
using System;
using System.Speech.Recognition;
using System.Text;
using System.Threading;

public static class AyteSpeechHost {
  private static readonly object OutLock = new object();

  private static void Emit(string prefix, string text) {
    if (string.IsNullOrWhiteSpace(text)) return;
    string b64 = Convert.ToBase64String(Encoding.UTF8.GetBytes(text));
    lock (OutLock) {
      Console.Out.WriteLine(prefix + b64);
      Console.Out.Flush();
    }
  }

  public static int Run(string preferred) {
    var installed = SpeechRecognitionEngine.InstalledRecognizers();
    if (installed.Count == 0) {
      Console.Error.WriteLine("NO_RECOGNIZER");
      return 2;
    }
    RecognizerInfo chosen = null;
    foreach (var info in installed) {
      if (string.Equals(info.Culture.Name, preferred, StringComparison.OrdinalIgnoreCase)) {
        chosen = info;
        break;
      }
    }
    if (chosen == null) {
      string prefix = preferred.Split('-')[0];
      foreach (var info in installed) {
        if (string.Equals(info.Culture.TwoLetterISOLanguageName, prefix, StringComparison.OrdinalIgnoreCase)) {
          chosen = info;
          break;
        }
      }
    }
    if (chosen == null) chosen = installed[0];

    using (var engine = new SpeechRecognitionEngine(chosen)) {
      engine.LoadGrammar(new DictationGrammar());
      engine.SetInputToDefaultAudioDevice();
      engine.BabbleTimeout = TimeSpan.Zero;
      engine.InitialSilenceTimeout = TimeSpan.Zero;
      engine.EndSilenceTimeout = TimeSpan.FromMilliseconds(900);
      engine.EndSilenceTimeoutAmbiguous = TimeSpan.FromMilliseconds(1200);

      long lastAudioPosTicks = -1;
      string lastFinalText = "";
      long lastFinalTickMs = 0;

      engine.SpeechHypothesized += (s, e) => {
        if (e.Result != null && e.Result.Confidence >= 0.30f) {
          Emit("PARTIAL:", e.Result.Text);
        }
      };
      engine.SpeechRecognized += (s, e) => {
        if (e.Result == null) return;
        string txt = (e.Result.Text ?? "").Trim();
        if (txt.Length == 0) return;
        // Filter low-confidence noise/echo hallucinations from SAPI.
        if (e.Result.Confidence < 0.25f) return;
        long posTicks = e.Result.Audio != null ? e.Result.Audio.AudioPosition.Ticks : -1;
        if (posTicks >= 0 && posTicks == lastAudioPosTicks) return;
        long nowMs = Environment.TickCount;
        if (txt == lastFinalText && Math.Abs(nowMs - lastFinalTickMs) < 2500) return;
        lastAudioPosTicks = posTicks;
        lastFinalText = txt;
        lastFinalTickMs = nowMs;
        Emit("FINAL:", txt);
      };

      engine.RecognizeAsync(RecognizeMode.Multiple);
      lock (OutLock) {
        Console.Out.WriteLine("READY:" + chosen.Culture.Name);
        Console.Out.Flush();
      }
      while (true) {
        string line = Console.In.ReadLine();
        if (line == null || line == "STOP" || line == "CANCEL") break;
      }
      engine.RecognizeAsyncStop();
      Thread.Sleep(200);
    }
    return 0;
  }
}
"@
exit ([AyteSpeechHost]::Run("$escapedCulture"))
''';

    final encoded = base64Encode(_utf16LeBytes(script));
    final proc = await Process.start('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-WindowStyle',
      'Hidden',
      '-EncodedCommand',
      encoded,
    ]);
    _systemProcess = proc;

    final ready = Completer<void>();
    final done = Completer<VoiceSttResult>();
    _systemCompleter = done;
    final stderrBuf = StringBuffer();

    proc.stderr
        .transform(utf8.decoder)
        .listen((chunk) => stderrBuf.write(chunk));
    proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (line.startsWith('READY:')) {
              if (!ready.isCompleted) ready.complete();
            } else if (line.startsWith('PARTIAL:')) {
              final decoded = _decodeB64(line.substring(8));
              if (decoded != null) {
                _partialText = decoded;
                notifyListeners();
              }
            } else if (line.startsWith('FINAL:')) {
              final decoded = _decodeB64(line.substring(6));
              if (decoded != null && decoded.trim().isNotEmpty) {
                appendSegment(_finalSegments, decoded);
                _partialText = '';
                notifyListeners();
              }
            }
          },
          onDone: () {
            final err = stderrBuf.toString().trim();
            if (!ready.isCompleted) {
              if (err.contains('NO_RECOGNIZER')) {
                ready.completeError(
                  StateError(
                    '当前 Windows 未安装语音识别语言包，请在系统「设置 → 时间和语言 → 语音」安装，或在 Ayte「设置 → 语音」切换为自定义 API。',
                  ),
                );
              } else {
                ready.completeError(
                  StateError(err.isEmpty ? '无法启动 Windows 语音识别引擎' : err),
                );
              }
            }
            if (!done.isCompleted) {
              done.complete(
                VoiceSttResult(
                  liveTranscript,
                  error: err.isEmpty ? null : err,
                ),
              );
            }
          },
        );

    try {
      await ready.future.timeout(const Duration(seconds: 8));
    } on Object {
      proc.kill();
      _systemProcess = null;
      _systemCompleter = null;
      rethrow;
    }
  }

  Future<VoiceSttResult> _stopSystemStt() async {
    _state = VoiceSttState.transcribing;
    notifyListeners();

    final proc = _systemProcess;
    final completer = _systemCompleter;
    _systemProcess = null;
    _systemCompleter = null;

    if (proc != null) {
      try {
        proc.stdin.writeln('STOP');
        await proc.stdin.flush();
      } on Object {
        // Ignore broken pipe.
      }
    }

    VoiceSttResult result;
    if (completer != null) {
      result = await completer.future.timeout(
        const Duration(seconds: 4),
        onTimeout: () {
          proc?.kill();
          return VoiceSttResult(liveTranscript);
        },
      );
    } else {
      result = VoiceSttResult(liveTranscript);
    }

    _state = VoiceSttState.idle;
    _activeOwner = null;
    _partialText = '';
    _finalSegments.clear();
    _startedAt = null;
    _elapsed = Duration.zero;
    notifyListeners();
    return result;
  }

  Future<VoiceSttResult> _stopLocalAiRecordingAndTranscribe() async {
    _state = VoiceSttState.transcribing;
    notifyListeners();

    File? wavFile;
    try {
      wavFile = await _recorder.stop();
      if (wavFile == null) {
        return const VoiceSttResult('', error: '未录制到有效音频，请检查系统默认麦克风');
      }
      final text = await LocalSenseVoice.instance.transcribe(
        wavFile,
        sessionId: _settings.config.sttStreaming ? _streamSessionId : null,
      );
      return VoiceSttResult(text);
    } on Object catch (error) {
      final message = _friendlyError(error);
      _lastError = message;
      return VoiceSttResult('', error: message);
    } finally {
      await WavRecorder.cleanupFile(wavFile);
      _state = VoiceSttState.idle;
      _activeOwner = null;
      _partialText = '';
      _finalSegments.clear();
      _startedAt = null;
      _elapsed = Duration.zero;
      notifyListeners();
    }
  }

  Future<void> _startApiRecording(VoiceConfig config) async {
    final key = await _settings.readSttApiKey();
    if (key == null || key.isEmpty) {
      throw StateError('尚未配置语音识别 API Key，请前往「设置 → 语音」填写，或切换回系统内置免费引擎。');
    }
    await _recorder.start();
  }

  Future<VoiceSttResult> _stopApiRecordingAndTranscribe(
    VoiceConfig config,
  ) async {
    _state = VoiceSttState.transcribing;
    notifyListeners();

    File? wavFile;
    try {
      wavFile = await _recorder.stop();
      if (wavFile == null) {
        return const VoiceSttResult('', error: '未录制到有效音频');
      }
      final apiKey = await _settings.readSttApiKey();
      if (apiKey == null || apiKey.isEmpty) {
        return const VoiceSttResult('', error: '未配置语音识别 API Key');
      }
      final text = await transcribeWavViaOpenAi(
        wavFile: wavFile,
        baseUrl: config.sttApiBaseUrl,
        apiKey: apiKey,
        model: config.sttModel,
        language: config.sttLanguage,
      );
      return VoiceSttResult(text);
    } on Object catch (error) {
      final message = _friendlyError(error);
      _lastError = message;
      return VoiceSttResult('', error: message);
    } finally {
      await WavRecorder.cleanupFile(wavFile);
      _state = VoiceSttState.idle;
      _activeOwner = null;
      _partialText = '';
      _finalSegments.clear();
      _startedAt = null;
      _elapsed = Duration.zero;
      notifyListeners();
    }
  }

  /// Sends [wavFile] to an OpenAI-compatible `/audio/transcriptions` endpoint.
  static Future<String> transcribeWavViaOpenAi({
    required File wavFile,
    required String baseUrl,
    required String apiKey,
    required String model,
    String? language,
    HttpClient? client,
  }) async {
    final ownClient = client == null;
    final http = client ?? HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final uri = buildTranscriptionsUri(baseUrl);
      final boundary =
          '----AyteVoice${DateTime.now().millisecondsSinceEpoch}${Random().nextInt(99999)}';
      final body = <int>[];

      void addField(String name, String value) {
        body.addAll(
          utf8.encode(
            '--$boundary\r\n'
            'Content-Disposition: form-data; name="$name"\r\n\r\n'
            '$value\r\n',
          ),
        );
      }

      addField('model', model);
      addField('response_format', 'json');
      final isoLang = toIso639Language(language);
      if (isoLang != null) {
        addField('language', isoLang);
      }

      final fileBytes = await wavFile.readAsBytes();
      final filename = p.basename(wavFile.path);
      body.addAll(
        utf8.encode(
          '--$boundary\r\n'
          'Content-Disposition: form-data; name="file"; filename="$filename"\r\n'
          'Content-Type: audio/wav\r\n\r\n',
        ),
      );
      body.addAll(fileBytes);
      body.addAll(utf8.encode('\r\n--$boundary--\r\n'));

      final req = await http.postUrl(uri);
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      req.headers.set(
        HttpHeaders.contentTypeHeader,
        'multipart/form-data; boundary=$boundary',
      );
      req.contentLength = body.length;
      req.add(body);

      final res = await req.close().timeout(const Duration(seconds: 60));
      final raw = await utf8.decodeStream(res);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw HttpException('HTTP ${res.statusCode}: ${_extractApiError(raw)}');
      }
      return parseTranscriptionResponse(raw);
    } finally {
      if (ownClient) http.close();
    }
  }

  static Uri buildTranscriptionsUri(String baseUrl) {
    final trimmed = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (trimmed.endsWith('/audio/transcriptions')) {
      return Uri.parse(trimmed);
    }
    return Uri.parse('$trimmed/audio/transcriptions');
  }

  /// Extracts ISO-639-1 language code (`zh`, `en`, `ja`) from BCP-47 tag.
  static String? toIso639Language(String? tag) {
    if (tag == null) return null;
    final normalized = tag.trim().toLowerCase();
    if (normalized.isEmpty || normalized == 'auto') return null;
    final dash = normalized.indexOf('-');
    return dash == -1 ? normalized : normalized.substring(0, dash);
  }

  static String parseTranscriptionResponse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, Object?> && decoded['text'] is String) {
        return (decoded['text'] as String).trim();
      }
    } on FormatException {
      // Plain-text response_format fallback.
    }
    return trimmed;
  }

  static String _extractApiError(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        final err = decoded['error'];
        if (err is Map<String, Object?> && err['message'] is String) {
          return err['message'] as String;
        }
        if (err is String) return err;
      }
    } on Object {
      // Fallback to raw snippet.
    }
    return raw.length > 180 ? '${raw.substring(0, 180)}…' : raw;
  }

  static String? _decodeB64(String raw) {
    try {
      return utf8.decode(base64Decode(raw.trim()));
    } on Object {
      return null;
    }
  }

  static String _friendlyError(Object error) {
    if (error is StateError) return error.message;
    if (error is HttpException) return error.message;
    return error.toString();
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
