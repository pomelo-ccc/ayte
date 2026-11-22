import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../platform/data_dir.dart';

/// Persistent local SenseVoiceSmall (ONNX via `sherpa-onnx`) recognizer.
///
/// Supports both:
/// - **Real-time streaming decode** (`transcribeLive`) from a live growing
///   16kHz 16-bit mono WAV/PCM file with automatic pause-based sentence
///   committing so long dictations stay ~0.1s per update.
/// - **Final decode** (`transcribe`) once recording finishes.
class LocalSenseVoice {
  LocalSenseVoice._();

  static final LocalSenseVoice instance = LocalSenseVoice._();

  Process? _worker;
  Completer<void>? _ready;
  Completer<Map<String, Object?>>? _pending;
  Future<void>? _starting;
  Timer? _idleTimer;
  String _lastStderr = '';

  /// Releases the background Python worker after 15 minutes of inactivity so
  /// ~350 MB RAM is reclaimed automatically when voice isn't being used.
  static const idleTimeout = Duration(minutes: 15);

  static const _workerScript = r'''
import array
import json
import math
import os
import re
import sys
import wave

import sherpa_onnx

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
if hasattr(sys.stdin, "reconfigure"):
    sys.stdin.reconfigure(encoding="utf-8")

model_dir = sys.argv[1]
initial_lang = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else "auto"
model_path = os.path.join(model_dir, "model.int8.onnx")
if not os.path.exists(model_path):
    model_path = os.path.join(model_dir, "model.onnx")
tokens_path = os.path.join(model_dir, "tokens.txt")

threads = max(2, min(6, (os.cpu_count() or 4) // 2))
VALID_LANGS = {"auto", "zh", "en", "ja", "ko", "yue"}
current_lang = initial_lang if initial_lang in VALID_LANGS else "auto"


def build_recognizer(lang):
    return sherpa_onnx.OfflineRecognizer.from_sense_voice(
        model=model_path,
        tokens=tokens_path,
        num_threads=threads,
        use_itn=True,
        language=lang,
    )


recognizer = build_recognizer(current_lang)

TAG_RE = re.compile(r"<\|[^|]+\|>")
CJK_RE = re.compile(r"[\u4e00-\u9fff]")

# Streaming session state (commit completed sentences at pauses so long speech
# never slows down live decoding).
session_id = None
commit_sample = 0
committed_text = ""


def read_live_pcm16(path, start_sample=0):
    """Reads 16kHz 16-bit mono PCM samples past the 44-byte WAV header safely
    even while the file is still actively being written."""
    size = os.path.getsize(path)
    header_bytes = 44
    if size <= header_bytes:
        return [], 0
    total_samples = (size - header_bytes) // 2
    if start_sample >= total_samples:
        return [], total_samples
    byte_offset = header_bytes + start_sample * 2
    byte_count = (total_samples - start_sample) * 2
    with open(path, "rb") as f:
        f.seek(byte_offset)
        raw = f.read(byte_count)
    usable = (len(raw) // 2) * 2
    if usable <= 0:
        return [], start_sample
    data = array.array("h")
    data.frombytes(raw[:usable])
    return [v / 32768.0 for v in data], start_sample + len(data)


def load_wav_mono_float(path):
    with wave.open(path, "rb") as wf:
        channels = wf.getnchannels()
        sampwidth = wf.getsampwidth()
        framerate = wf.getframerate()
        nframes = wf.getnframes()
        raw = wf.readframes(nframes)

    if nframes == 0 or not raw:
        return [], framerate

    if sampwidth == 2:
        data = array.array("h")
        data.frombytes(raw)
        scale = 32768.0
    elif sampwidth == 1:
        data = array.array("B")
        data.frombytes(raw)
        data = [v - 128 for v in data]
        scale = 128.0
    elif sampwidth == 4:
        data = array.array("i")
        data.frombytes(raw)
        scale = 2147483648.0
    else:
        raise ValueError(f"Unsupported WAV sample width: {sampwidth}")

    if channels > 1:
        mono = []
        for i in range(0, len(data) - channels + 1, channels):
            s = 0.0
            for c in range(channels):
                s += data[i + c]
            mono.append((s / channels) / scale)
        return mono, framerate

    return [v / scale for v in data], framerate


def clean_text(raw):
    return TAG_RE.sub("", raw or "").strip()


def join_parts(a, b):
    a = (a or "").strip()
    b = (b or "").strip()
    if not a:
        return b
    if not b:
        return a
    if CJK_RE.search(a[-1]) or CJK_RE.search(b[0]) or a[-1] in "，。！？、；：":
        return a + b
    return a + " " + b


def ends_with_silence(samples, sr, sec=0.70, threshold=0.012):
    win = int(sr * sec)
    if len(samples) < win:
        return False
    tail = samples[-win:]
    rms = math.sqrt(sum(x * x for x in tail) / len(tail))
    return rms < threshold


def decode_samples(samples, sr):
    if len(samples) < int(sr * 0.16):
        return ""
    peak = max(abs(x) for x in samples)
    if peak < 0.003:
        return ""
    stream = recognizer.create_stream()
    stream.accept_waveform(sr, samples)
    recognizer.decode_stream(stream)
    return clean_text(stream.result.text)


print(json.dumps({"ready": True}, ensure_ascii=False), flush=True)

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        req = json.loads(line)
        wav_path = req.get("wav", "")
        partial = bool(req.get("partial", False))
        sid = req.get("session")
        sr = int(req.get("sr", 16000))
        req_lang = req.get("lang") or "auto"
        if req_lang not in VALID_LANGS:
            req_lang = "auto"
        if req_lang != current_lang:
            recognizer = build_recognizer(req_lang)
            current_lang = req_lang

        if not wav_path or not os.path.exists(wav_path):
            print(json.dumps({"text": "", "error": "录音文件不存在"}, ensure_ascii=False), flush=True)
            continue

        if sid is not None and sid != session_id:
            session_id = sid
            commit_sample = 0
            committed_text = ""

        if partial:
            samples, total_samples = read_live_pcm16(wav_path, commit_sample)
            tail_text = decode_samples(samples, sr)
            # Commit completed clause after a natural silence pause once tail >= 3.5s
            if tail_text and len(samples) >= int(sr * 3.5) and ends_with_silence(samples, sr):
                committed_text = join_parts(committed_text, tail_text)
                commit_sample = total_samples
                tail_text = ""
            combined = join_parts(committed_text, tail_text)
            print(json.dumps({"text": combined}, ensure_ascii=False), flush=True)
            continue

        # Final decode: decode any uncommitted tail (or whole WAV for non-streaming).
        if sid is not None and sid == session_id and commit_sample > 0:
            samples, _ = read_live_pcm16(wav_path, commit_sample)
            tail_text = decode_samples(samples, sr)
            final_text = join_parts(committed_text, tail_text)
        else:
            samples, wav_sr = load_wav_mono_float(wav_path)
            final_text = decode_samples(samples, wav_sr)

        session_id = None
        commit_sample = 0
        committed_text = ""
        print(json.dumps({"text": final_text}, ensure_ascii=False), flush=True)
    except Exception as exc:
        print(json.dumps({"text": "", "error": str(exc)}, ensure_ascii=False), flush=True)
''';

  /// Maps a BCP-47 language tag (e.g. `zh-CN`, `en-US`, `ja-JP`, `auto`) to
  /// SenseVoice's language code (`zh`, `en`, `ja`, `ko`, `yue`, `auto`).
  static String mapSenseVoiceLanguage(String? bcp47) {
    final norm = (bcp47 ?? '').trim().toLowerCase();
    if (norm.isEmpty || norm == 'auto') return 'auto';
    if (norm == 'yue' || norm == 'zh-hk') return 'yue';
    if (norm.startsWith('zh')) return 'zh';
    if (norm.startsWith('en')) return 'en';
    if (norm.startsWith('ja')) return 'ja';
    if (norm.startsWith('ko')) return 'ko';
    return 'auto';
  }

  /// Locates the isolated Python runtime (`voice-runtime`) shared by
  /// SenseVoice STT and Edge Neural TTS.
  static String? locatePythonExe() {
    final managed = Platform.isWindows
        ? p.join(DataDirectory.current.path, 'voice', 'runtime', 'Scripts', 'python.exe')
        : p.join(DataDirectory.current.path, 'voice', 'runtime', 'bin', 'python');
    if (File(managed).existsSync()) return managed;

    final exeDir = p.dirname(Platform.resolvedExecutable);
    final candidates = <String>{
      exeDir,
      if (Platform.isWindows) r'D:\Ayte',
      p.dirname(exeDir),
    };
    for (final base in candidates) {
      final py = Platform.isWindows
          ? p.join(base, 'voice-runtime', 'Scripts', 'python.exe')
          : p.join(base, 'voice-runtime', 'bin', 'python');
      if (File(py).existsSync()) return py;
    }
    return null;
  }

  /// Locates the local SenseVoice model directory and Python `sherpa-onnx`
  /// runtime inside Ayte's managed data directory, relative to the executable,
  /// or `D:\Ayte`.
  static ({String pythonExe, String modelDir})? locateInstallation() {
    final pythonExe = locatePythonExe();
    if (pythonExe == null) return null;

    final managedModelDir = p.join(
      DataDirectory.current.path,
      'voice',
      'models',
      'sense-voice',
    );
    final exeDir = p.dirname(Platform.resolvedExecutable);
    final modelDirs = <String>{
      managedModelDir,
      p.join(exeDir, 'voice-models', 'sense-voice'),
      if (Platform.isWindows) p.join(r'D:\Ayte', 'voice-models', 'sense-voice'),
      p.join(p.dirname(exeDir), 'voice-models', 'sense-voice'),
    };

    for (final dir in modelDirs) {
      final hasModel =
          File(p.join(dir, 'model.int8.onnx')).existsSync() ||
          File(p.join(dir, 'model.onnx')).existsSync();
      if (hasModel && File(p.join(dir, 'tokens.txt')).existsSync()) {
        return (pythonExe: pythonExe, modelDir: dir);
      }
    }
    return null;
  }

  static bool get isInstalled => locateInstallation() != null;

  bool get isReady => _worker != null && _ready != null && _ready!.isCompleted;

  bool get isBusy => _pending != null;

  void _touchIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(idleTimeout, () {
      if (_pending == null) {
        dispose();
      }
    });
  }

  /// Pre-warms the worker in the background (e.g. shortly after app launch or
  /// as soon as recording starts) so live streaming & stopping take ~0.1s.
  void warmUp({String language = 'auto'}) {
    if (Platform.environment['FLUTTER_TEST'] == 'true') return;
    if (_worker != null || _starting != null) {
      _touchIdleTimer();
      return;
    }
    if (!isInstalled) return;
    _touchIdleTimer();
    unawaited(
      _ensureStarted(initialLanguage: language).catchError((Object _) {}),
    );
  }

  /// Runs a fast non-blocking live decode on an actively growing WAV file.
  /// Returns null if the worker is not ready yet or already decoding a frame.
  Future<String?> transcribeLive(
    String wavPath, {
    required int sessionId,
    String language = 'auto',
  }) async {
    if (!isReady || _pending != null) return null;
    final proc = _worker;
    if (proc == null) return null;
    _touchIdleTimer();

    final req = Completer<Map<String, Object?>>();
    _pending = req;
    try {
      proc.stdin.writeln(
        jsonEncode({
          'wav': wavPath,
          'partial': true,
          'session': sessionId,
          'sr': 16000,
          'lang': mapSenseVoiceLanguage(language),
        }),
      );
      await proc.stdin.flush();
      final resp = await req.future.timeout(const Duration(seconds: 6));
      final err = resp['error'];
      if (err is String && err.isNotEmpty) return null;
      return (resp['text'] as String? ?? '').trim();
    } on Object {
      if (identical(_pending, req)) _pending = null;
      return null;
    }
  }

  /// Transcribes [wavFile] using the local SenseVoice ONNX recognizer.
  Future<String> transcribe(
    File wavFile, {
    int? sessionId,
    String language = 'auto',
  }) async {
    await _ensureStarted(initialLanguage: language);
    _touchIdleTimer();
    // Wait briefly if a live partial decode is currently finishing.
    final inflight = _pending;
    if (inflight != null) {
      try {
        await inflight.future.timeout(const Duration(seconds: 4));
      } on Object {
        if (identical(_pending, inflight)) _pending = null;
      }
    }
    final proc = _worker;
    if (proc == null) {
      throw StateError('本地语音识别引擎未就绪');
    }

    final req = Completer<Map<String, Object?>>();
    _pending = req;
    proc.stdin.writeln(
      jsonEncode({
        'wav': wavFile.path,
        'partial': false,
        'session': ?sessionId,
        'sr': 16000,
        'lang': mapSenseVoiceLanguage(language),
      }),
    );
    await proc.stdin.flush();

    final resp = await req.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        dispose();
        throw StateError('本地语音识别超时');
      },
    );
    final err = resp['error'];
    if (err is String && err.isNotEmpty) {
      throw StateError('本地语音识别失败: $err');
    }
    return (resp['text'] as String? ?? '').trim();
  }

  Future<void> _ensureStarted({String initialLanguage = 'auto'}) {
    if (_worker != null && _ready != null && _ready!.isCompleted) {
      return Future.value();
    }
    if (_starting != null) return _starting!;
    final future = _startInternal(initialLanguage: initialLanguage);
    _starting = future;
    future.whenComplete(() {
      if (identical(_starting, future)) _starting = null;
    });
    return future;
  }

  Future<void> _startInternal({String initialLanguage = 'auto'}) async {
    final install = locateInstallation();
    if (install == null) {
      throw StateError(
        '尚未安装本地 SenseVoice 语音组件，请在「设置 → 语音」点击一键在线下载安装，或切换为自定义 API。',
      );
    }

    final workerFile = File(p.join(install.modelDir, 'sensevoice_worker.py'));
    if (!await workerFile.exists() ||
        await workerFile.readAsString() != _workerScript) {
      await workerFile.writeAsString(_workerScript, flush: true);
    }

    _lastStderr = '';
    final ready = Completer<void>();
    _ready = ready;

    final proc = await Process.start(
      install.pythonExe,
      [
        '-u',
        workerFile.path,
        install.modelDir,
        mapSenseVoiceLanguage(initialLanguage),
      ],
      environment: const {'PYTHONIOENCODING': 'utf-8'},
    );
    _worker = proc;

    proc.stderr.transform(utf8.decoder).listen((chunk) {
      _lastStderr += chunk;
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
                final pending = _pending;
                _pending = null;
                if (pending != null && !pending.isCompleted) {
                  pending.complete(decoded);
                }
              }
            } on Object {
              // Ignore non-JSON log lines from ONNX runtime.
            }
          },
          onDone: () {
            if (identical(_worker, proc)) {
              _worker = null;
            }
            final err = _lastStderr.trim();
            if (!ready.isCompleted) {
              ready.completeError(
                StateError(err.isEmpty ? '本地 SenseVoice 引擎启动失败' : err),
              );
            }
            final pending = _pending;
            _pending = null;
            if (pending != null && !pending.isCompleted) {
              pending.completeError(
                StateError(err.isEmpty ? '本地 SenseVoice 进程异常退出' : err),
              );
            }
          },
        );

    try {
      await ready.future.timeout(const Duration(seconds: 20));
    } on Object {
      dispose();
      rethrow;
    }
  }

  /// Strips SenseVoice metadata tags like `<|zh|><|NEUTRAL|><|Speech|>`.
  static String stripSenseVoiceTags(String raw) =>
      raw.replaceAll(RegExp(r'<\|[^|]+\|>'), '').trim();

  void dispose() {
    _idleTimer?.cancel();
    _idleTimer = null;
    final proc = _worker;
    _worker = null;
    _ready = null;
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(StateError('本地语音识别已取消'));
    }
    proc?.kill();
  }
}
