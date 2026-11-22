import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../platform/data_dir.dart';
import 'local_sensevoice.dart';

/// Current stage of the in-app online voice runtime + model installer.
enum VoiceInstallStage {
  idle,
  checkingUv,
  installingRuntime,
  downloadingModel,
  verifying,
  done,
  error,
}

/// Downloads and installs the isolated Python `voice-runtime` (`sherpa-onnx` +
/// `edge-tts`) and the offline `SenseVoiceSmall` (int8 ONNX, ~228 MB) model
/// into `<DataDirectory>/voice/` so any user downloading Ayte from GitHub
/// Releases can enable high-accuracy local voice with a single click.
class VoiceModelInstaller extends ChangeNotifier {
  VoiceModelInstaller._();

  static final VoiceModelInstaller instance = VoiceModelInstaller._();

  static const int expectedModelBytes = 239233841;

  static const _tokensMirrors = <String>[
    'https://hf-mirror.com/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/tokens.txt',
    'https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/tokens.txt',
  ];

  static const _modelMirrors = <String>[
    'https://hf-mirror.com/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/model.int8.onnx',
    'https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/model.int8.onnx',
  ];

  VoiceInstallStage _stage = VoiceInstallStage.idle;
  double _progress = 0.0;
  int _downloadedBytes = 0;
  int _totalBytes = expectedModelBytes;
  double _speedBytesPerSec = 0.0;
  String _statusMessage = '';
  String? _error;
  bool _cancelled = false;
  HttpClient? _activeClient;
  Process? _activeProc;

  VoiceInstallStage get stage => _stage;
  bool get isInstalling =>
      _stage == VoiceInstallStage.checkingUv ||
      _stage == VoiceInstallStage.installingRuntime ||
      _stage == VoiceInstallStage.downloadingModel ||
      _stage == VoiceInstallStage.verifying;
  double get progress => _progress;
  int get downloadedBytes => _downloadedBytes;
  int get totalBytes => _totalBytes;
  double get speedBytesPerSec => _speedBytesPerSec;
  String get statusMessage => _statusMessage;
  String? get error => _error;

  /// Canonical cross-platform install root inside Ayte's user data directory
  /// (survives app updates cleanly).
  static String get managedRoot => p.join(DataDirectory.current.path, 'voice');
  static String get managedRuntimeDir => p.join(managedRoot, 'runtime');
  static String get managedModelDir =>
      p.join(managedRoot, 'models', 'sense-voice');
  static String get managedBinDir => p.join(managedRoot, 'bin');

  /// Whether both the Python runtime (`sherpa-onnx` + `edge-tts`) and the
  /// SenseVoice ONNX model are installed (in either `<dataDir>/voice/` or the
  /// portable `D:\Ayte` directory).
  bool get isInstalled => LocalSenseVoice.isInstalled;

  /// Human-readable install location if present.
  String? get installedLocation => LocalSenseVoice.locateInstallation()?.modelDir;

  /// Runs the full one-click online installation with live progress updates.
  Future<bool> install({bool isZh = true}) async {
    if (isInstalling) return false;
    _cancelled = false;
    _error = null;
    _progress = 0.0;
    _downloadedBytes = 0;
    _totalBytes = expectedModelBytes;
    _speedBytesPerSec = 0.0;

    try {
      // 1. Ensure Python runtime (uv + Python 3.12 + sherpa-onnx + edge-tts)
      var pythonExe = LocalSenseVoice.locatePythonExe();
      if (pythonExe == null) {
        _setStage(
          VoiceInstallStage.checkingUv,
          isZh ? '正在准备轻量化 Python 运行器 (uv)…' : 'Preparing portable uv runtime…',
          0.05,
        );
        final uvExe = await _ensureUv(isZh: isZh);
        if (_cancelled) return false;

        _setStage(
          VoiceInstallStage.installingRuntime,
          isZh
              ? '正在创建独立语音运行环境 (sherpa-onnx + edge-tts)…'
              : 'Installing isolated voice runtime (sherpa-onnx + edge-tts)…',
          0.14,
        );
        await Directory(managedRoot).create(recursive: true);
        pythonExe = Platform.isWindows
            ? p.join(managedRuntimeDir, 'Scripts', 'python.exe')
            : p.join(managedRuntimeDir, 'bin', 'python');

        if (!await File(pythonExe).exists()) {
          await _runChecked(uvExe, ['venv', '--python', '3.12', managedRuntimeDir]);
        }
        if (_cancelled) return false;
        _setStage(
          VoiceInstallStage.installingRuntime,
          isZh
              ? '正在安装 sherpa-onnx 与 Edge 神经网络语音包…'
              : 'Installing sherpa-onnx and edge-tts packages…',
          0.24,
        );
        await _runChecked(uvExe, [
          'pip',
          'install',
          '--python',
          pythonExe,
          'sherpa-onnx',
          'edge-tts',
        ]);
        if (_cancelled) return false;
      }

      // 2. Download SenseVoiceSmall int8 ONNX model + tokens.txt with resume
      final modelDir = LocalSenseVoice.locateInstallation()?.modelDir ??
          managedModelDir;
      await Directory(modelDir).create(recursive: true);

      final tokensFile = File(p.join(modelDir, 'tokens.txt'));
      if (!await tokensFile.exists() || await tokensFile.length() < 1024) {
        _setStage(
          VoiceInstallStage.downloadingModel,
          isZh ? '正在下载 SenseVoice 词表 (tokens.txt)…' : 'Downloading tokens.txt…',
          0.30,
        );
        await _downloadWithMirrors(
          _tokensMirrors,
          tokensFile,
          trackProgress: false,
        );
        if (_cancelled) return false;
      }

      final modelFile = File(p.join(modelDir, 'model.int8.onnx'));
      if (!await modelFile.exists() ||
          await modelFile.length() != expectedModelBytes) {
        _setStage(
          VoiceInstallStage.downloadingModel,
          isZh
              ? '正在下载 SenseVoiceSmall 离线语音模型 (228 MB)…'
              : 'Downloading SenseVoiceSmall model (228 MB)…',
          0.32,
        );
        await _downloadWithMirrors(
          _modelMirrors,
          modelFile,
          expectedSize: expectedModelBytes,
          trackProgress: true,
        );
        if (_cancelled) return false;
      }

      // 3. Final check & warm-up
      _setStage(
        VoiceInstallStage.verifying,
        isZh ? '正在校验模型并预热语音引擎…' : 'Verifying model and warming up…',
        0.96,
      );
      if (!LocalSenseVoice.isInstalled) {
        throw StateError(isZh ? '安装完成但未检测到完整模型文件' : 'Installed files missing');
      }
      LocalSenseVoice.instance.warmUp();

      _setStage(
        VoiceInstallStage.done,
        isZh ? '本地语音模型与真人音色已全部就绪！' : 'Voice model and neural TTS are ready!',
        1.0,
      );
      return true;
    } on Object catch (err) {
      if (_cancelled) {
        _stage = VoiceInstallStage.idle;
        _statusMessage = '';
        notifyListeners();
        return false;
      }
      _error = err is StateError ? err.message : err.toString();
      _stage = VoiceInstallStage.error;
      notifyListeners();
      return false;
    }
  }

  /// Cancels an active installation cleanly (retains `.part` for resume).
  void cancel() {
    _cancelled = true;
    _activeClient?.close(force: true);
    _activeClient = null;
    _activeProc?.kill();
    _activeProc = null;
    if (isInstalling) {
      _stage = VoiceInstallStage.idle;
      _statusMessage = '';
      notifyListeners();
    }
  }

  /// Formats bytes into MB string (`112.4 MB`).
  static String formatMb(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  void _setStage(VoiceInstallStage stage, String message, double progress) {
    _stage = stage;
    _statusMessage = message;
    _progress = progress.clamp(0.0, 1.0);
    notifyListeners();
  }

  Future<String> _ensureUv({required bool isZh}) async {
    // 1. Check already-downloaded portable uv
    final binName = Platform.isWindows ? 'uv.exe' : 'uv';
    final managedUv = p.join(managedBinDir, binName);
    if (await File(managedUv).exists()) return managedUv;

    // 2. Check PATH or ~/.local/bin
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '';
    final candidates = <String>[
      if (home.isNotEmpty) p.join(home, '.local', 'bin', binName),
      if (home.isNotEmpty) p.join(home, '.cargo', 'bin', binName),
      binName,
    ];
    for (final c in candidates) {
      try {
        final res = await Process.run(c, ['--version']);
        if (res.exitCode == 0) return c;
      } on Object {
        // Not found at this candidate.
      }
    }

    // 3. Download portable uv directly from GitHub Releases
    await Directory(managedBinDir).create(recursive: true);
    final archiveName = _uvArchiveName();
    final url =
        'https://github.com/astral-sh/uv/releases/latest/download/$archiveName';
    final archiveFile = File(p.join(managedBinDir, archiveName));
    await _downloadWithMirrors([url], archiveFile, trackProgress: false);
    if (_cancelled) throw StateError('已取消');

    if (archiveName.endsWith('.zip')) {
      await _runChecked('tar.exe', ['-xf', archiveFile.path, '-C', managedBinDir]);
    } else {
      await _runChecked('tar', ['-xzf', archiveFile.path, '-C', managedBinDir]);
    }
    try {
      await archiveFile.delete();
    } on Object {
      // Ignore cleanup failure.
    }

    // Locate extracted uv binary (may be nested in a subfolder on Unix)
    await for (final entity in Directory(managedBinDir).list(recursive: true)) {
      if (entity is File && p.basename(entity.path) == binName) {
        if (entity.path != managedUv) {
          await entity.copy(managedUv);
        }
        return managedUv;
      }
    }
    throw StateError(isZh ? '下载便携版 uv 失败，请检查网络连接' : 'Failed to extract portable uv');
  }

  static String _uvArchiveName() {
    if (Platform.isWindows) return 'uv-x86_64-pc-windows-msvc.zip';
    if (Platform.isMacOS) {
      return Platform.version.toLowerCase().contains('arm64')
          ? 'uv-aarch64-apple-darwin.tar.gz'
          : 'uv-x86_64-apple-darwin.tar.gz';
    }
    return 'uv-x86_64-unknown-linux-gnu.tar.gz';
  }

  Future<void> _runChecked(String exe, List<String> args) async {
    final proc = await Process.start(exe, args);
    _activeProc = proc;
    final stderrBuf = StringBuffer();
    unawaited(proc.stdout.drain<void>());
    proc.stderr.listen((chunk) => stderrBuf.write(String.fromCharCodes(chunk)));
    final code = await proc.exitCode;
    if (identical(_activeProc, proc)) _activeProc = null;
    if (_cancelled) return;
    if (code != 0) {
      final err = stderrBuf.toString().trim();
      throw StateError(
        '命令执行失败 ($exe, code=$code)${err.isEmpty ? '' : ': $err'}',
      );
    }
  }

  Future<void> _downloadWithMirrors(
    List<String> urls,
    File target, {
    int? expectedSize,
    required bool trackProgress,
  }) async {
    Object? lastError;
    final partFile = File('${target.path}.part');

    for (final url in urls) {
      if (_cancelled) return;
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 20);
      _activeClient = client;
      try {
        var existing = await partFile.exists() ? await partFile.length() : 0;
        if (expectedSize != null && existing > expectedSize) {
          await partFile.delete();
          existing = 0;
        }

        final req = await client.getUrl(Uri.parse(url));
        req.followRedirects = true;
        req.maxRedirects = 8;
        if (existing > 0) {
          req.headers.set(HttpHeaders.rangeHeader, 'bytes=$existing-');
        }
        final res = await req.close().timeout(const Duration(seconds: 30));

        if (res.statusCode != 200 && res.statusCode != 206) {
          throw HttpException('HTTP ${res.statusCode} ($url)');
        }

        final isResume = res.statusCode == 206 && existing > 0;
        final sink = partFile.openWrite(
          mode: isResume ? FileMode.append : FileMode.writeOnly,
        );
        var received = isResume ? existing : 0;
        final total = expectedSize ??
            (res.contentLength > 0 ? received + res.contentLength : 0);
        final startTime = DateTime.now();
        var lastNotify = startTime;
        var bytesSinceStart = 0;

        try {
          await for (final chunk in res) {
            if (_cancelled) {
              await sink.close();
              return;
            }
            sink.add(chunk);
            received += chunk.length;
            bytesSinceStart += chunk.length;

            if (trackProgress) {
              final now = DateTime.now();
              if (now.difference(lastNotify).inMilliseconds >= 200) {
                lastNotify = now;
                final secs =
                    now.difference(startTime).inMilliseconds / 1000.0;
                _downloadedBytes = received;
                _totalBytes = total > 0 ? total : expectedModelBytes;
                _speedBytesPerSec = secs > 0.1 ? bytesSinceStart / secs : 0;
                final ratio = _totalBytes > 0
                    ? (received / _totalBytes).clamp(0.0, 1.0)
                    : 0.0;
                // Map model download progress across 32%..95% of overall bar.
                _progress = 0.32 + ratio * 0.63;
                notifyListeners();
              }
            }
          }
          await sink.flush();
        } finally {
          await sink.close();
        }

        final finalLen = await partFile.length();
        if (expectedSize != null && finalLen != expectedSize) {
          throw StateError('文件大小校验不匹配 ($finalLen != $expectedSize)');
        }
        if (await target.exists()) await target.delete();
        await partFile.rename(target.path);
        return;
      } on Object catch (err) {
        lastError = err;
      } finally {
        if (identical(_activeClient, client)) _activeClient = null;
        client.close(force: true);
      }
    }
    throw StateError('下载失败: $lastError');
  }
}
