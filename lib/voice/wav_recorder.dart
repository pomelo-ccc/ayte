import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Describes a microphone input device reported by the OS (`waveInGetDevCapsW`).
@immutable
class VoiceInputDevice {
  const VoiceInputDevice({required this.id, required this.name});

  final int id;
  final String name;

  @override
  bool operator ==(Object other) =>
      other is VoiceInputDevice && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}

/// Records 16kHz 16-bit mono PCM WAV audio from the selected microphone.
///
/// On Windows, uses Ayte's native C++ `winmm.dll` `waveIn` method channel
/// (`baocode/voice` — <2ms start/stop, zero subprocess startup lag, adaptive
/// ambient noise floor VAD) with a PowerShell fallback when the native channel
/// is unavailable. On macOS/Linux, falls back to `ffmpeg`, `rec` (SoX), or
/// `arecord`.
class WavRecorder {
  WavRecorder({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('baocode/voice');

  static const _defaultChannel = MethodChannel('baocode/voice');

  final MethodChannel _channel;
  Process? _process;
  String? _outputPath;
  bool _recording = false;
  bool _usingNativeWindows = false;

  bool get isRecording => _recording;
  String? get activeFilePath => _recording ? _outputPath : null;

  /// Lists available microphone input devices on Windows (empty on other OSes).
  static Future<List<VoiceInputDevice>> listInputDevices({
    MethodChannel? channel,
  }) async {
    if (Platform.environment['FLUTTER_TEST'] == 'true' || !Platform.isWindows) {
      return const [];
    }
    try {
      final raw = await (channel ?? _defaultChannel)
          .invokeMethod<List<Object?>>('listInputDevices');
      if (raw == null) return const [];
      final devices = <VoiceInputDevice>[];
      for (final entry in raw) {
        if (entry is Map<Object?, Object?>) {
          final id = (entry['id'] as num?)?.toInt();
          final name = (entry['name'] as String?)?.trim();
          if (id != null && name != null && name.isNotEmpty) {
            devices.add(VoiceInputDevice(id: id, name: name));
          }
        }
      }
      return devices;
    } on Object {
      return const [];
    }
  }

  /// Plays a gentle synthesized UI earcon (`start`, `stop`, `exit`) on Windows.
  static Future<void> playEarcon(String kind, {MethodChannel? channel}) async {
    if (Platform.environment['FLUTTER_TEST'] == 'true' || !Platform.isWindows) {
      return;
    }
    try {
      await (channel ?? _defaultChannel).invokeMethod<bool>('playEarcon', kind);
    } on Object {
      // Earcons are strictly best-effort.
    }
  }

  /// Reads real-time microphone RMS level (0.0..1.0), VAD silence duration,
  /// and total captured duration from Windows native C++ `waveIn` recording.
  Future<({double level, int silenceMs, int totalMs, bool heardSpeech})?>
  readMetrics() async {
    if (!_recording || !_usingNativeWindows) return null;
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'recordingMetrics',
      );
      if (raw == null) return null;
      return (
        level: (raw['level'] as num?)?.toDouble() ?? 0.0,
        silenceMs: (raw['silenceMs'] as num?)?.toInt() ?? 0,
        totalMs: (raw['totalMs'] as num?)?.toInt() ?? 0,
        heardSpeech: raw['heardSpeech'] == true,
      );
    } on Object {
      return null;
    }
  }

  /// Starts recording to a temporary `.wav` file using [deviceId]
  /// (`-1` selects the OS default microphone).
  Future<void> start({int deviceId = -1}) async {
    if (_recording) return;
    final dir = await Directory.systemTemp.createTemp('ayte_voice_');
    final wavPath = p.join(dir.path, 'recording.wav');
    _outputPath = wavPath;
    _usingNativeWindows = false;

    if (Platform.isWindows) {
      final startedNative = await _tryStartWindowsNative(
        wavPath,
        deviceId: deviceId,
      );
      if (startedNative) {
        _usingNativeWindows = true;
      } else {
        await _startWindowsPowerShell(wavPath);
      }
    } else if (Platform.isMacOS) {
      await _startUnix(wavPath, macos: true);
    } else if (Platform.isLinux) {
      await _startUnix(wavPath, macos: false);
    } else {
      throw UnsupportedError('Audio recording is not supported on this OS.');
    }
    _recording = true;
  }

  /// Stops recording and returns the recorded `.wav` file (or null if empty).
  Future<File?> stop() async {
    if (!_recording) return null;
    _recording = false;
    final native = _usingNativeWindows;
    _usingNativeWindows = false;
    final proc = _process;
    _process = null;
    final path = _outputPath;
    _outputPath = null;

    if (native) {
      try {
        await _channel.invokeMethod<bool>('stopRecording');
      } on PlatformException catch (e) {
        await _cleanupPath(path);
        throw StateError('保存录音失败: ${e.message ?? e.code}');
      }
    } else if (proc != null) {
      try {
        if (Platform.isWindows) {
          proc.stdin.writeln('STOP');
          await proc.stdin.flush();
          await proc.exitCode.timeout(
            const Duration(seconds: 6),
            onTimeout: () {
              proc.kill();
              return -1;
            },
          );
        } else {
          proc.kill(ProcessSignal.sigint);
          await proc.exitCode.timeout(
            const Duration(seconds: 4),
            onTimeout: () {
              proc.kill(ProcessSignal.sigkill);
              return -1;
            },
          );
        }
      } on Object {
        proc.kill();
      }
    }

    if (path == null) return null;
    final file = File(path);
    if (!await file.exists() || await file.length() < 64) {
      await _cleanupPath(path);
      return null;
    }
    return file;
  }

  /// Cancels an active recording and deletes any temporary file.
  Future<void> cancel() async {
    _recording = false;
    final native = _usingNativeWindows;
    _usingNativeWindows = false;
    final proc = _process;
    _process = null;
    final path = _outputPath;
    _outputPath = null;

    if (native) {
      try {
        await _channel.invokeMethod<bool>('cancelRecording');
      } on Object {
        // Ignore cleanup errors.
      }
    } else if (proc != null) {
      try {
        if (Platform.isWindows) {
          proc.stdin.writeln('CANCEL');
          await proc.stdin.flush();
        }
      } on Object {
        // Ignore pipe errors when process already exited.
      }
      proc.kill();
    }
    if (path != null) {
      await _cleanupPath(path);
    }
  }

  static Future<void> cleanupFile(File? file) async {
    if (file == null) return;
    await _cleanupPath(file.path);
  }

  static Future<void> _cleanupPath(String? wavPath) async {
    if (wavPath == null) return;
    try {
      final parent = Directory(p.dirname(wavPath));
      if (await parent.exists() &&
          p.basename(parent.path).startsWith('ayte_voice_')) {
        await parent.delete(recursive: true);
      } else {
        final file = File(wavPath);
        if (await file.exists()) await file.delete();
      }
    } on Object {
      // Best-effort cleanup.
    }
  }

  Future<bool> _tryStartWindowsNative(
    String wavPath, {
    int deviceId = -1,
  }) async {
    try {
      final ok = await _channel.invokeMethod<bool>('startRecording', {
        'path': wavPath,
        'deviceId': deviceId,
      });
      return ok == true;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      await _cleanupPath(wavPath);
      throw StateError('无法启动麦克风录音: ${e.message ?? e.code}');
    }
  }

  Future<void> _startWindowsPowerShell(String wavPath) async {
    final escapedPath = wavPath.replaceAll("'", "''");
    final script = '''
\$ProgressPreference = 'SilentlyContinue'
\$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class AyteMci {
  [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
  public static extern uint mciSendStringW(string cmd, StringBuilder ret, int retLen, IntPtr cb);
  [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
  public static extern bool mciGetErrorStringW(uint err, StringBuilder buf, int len);
  public static void Run(string cmd) {
    var sb = new StringBuilder(256);
    uint err = mciSendStringW(cmd, sb, sb.Capacity, IntPtr.Zero);
    if (err != 0) {
      var errBuf = new StringBuilder(256);
      mciGetErrorStringW(err, errBuf, errBuf.Capacity);
      throw new Exception("MCI(" + err + "): " + errBuf.ToString());
    }
  }
}
"@
\$alias = "ayte_rec_" + \$PID
try {
  [AyteMci]::Run("open new type waveaudio alias \$alias")
  try {
    [AyteMci]::Run("set \$alias time format ms bitspersample 16 channels 1 samplespersec 16000 bytespersec 32000 alignment 2")
  } catch {}
  [AyteMci]::Run("record \$alias")
  [Console]::Out.WriteLine("READY")
  [Console]::Out.Flush()
  \$cmd = [Console]::In.ReadLine()
  [AyteMci]::Run("stop \$alias")
  if (\$cmd -ne "CANCEL") {
    [AyteMci]::Run('save ' + \$alias + ' "$escapedPath"')
  }
  [AyteMci]::Run("close \$alias")
} catch {
  try { [AyteMci]::Run("close \$alias") } catch {}
  [Console]::Error.WriteLine(\$_.Exception.Message)
  exit 1
}
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
    _process = proc;

    final ready = Completer<void>();
    final stderrBuf = StringBuffer();
    proc.stderr
        .transform(utf8.decoder)
        .listen((chunk) => stderrBuf.write(chunk));
    proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (line.trim() == 'READY' && !ready.isCompleted) {
              ready.complete();
            }
          },
          onDone: () {
            if (!ready.isCompleted) {
              final err = stderrBuf.toString().trim();
              ready.completeError(
                StateError(
                  err.isEmpty ? '无法打开麦克风录音设备' : '麦克风启动失败: $err',
                ),
              );
            }
          },
        );

    try {
      await ready.future.timeout(const Duration(seconds: 8));
    } on Object {
      proc.kill();
      _process = null;
      await _cleanupPath(wavPath);
      rethrow;
    }
  }

  Future<void> _startUnix(String wavPath, {required bool macos}) async {
    final candidates = macos
        ? <(String, List<String>)>[
            (
              'ffmpeg',
              [
                '-hide_banner',
                '-loglevel',
                'error',
                '-f',
                'avfoundation',
                '-i',
                ':0',
                '-ac',
                '1',
                '-ar',
                '16000',
                '-y',
                wavPath,
              ],
            ),
            ('rec', ['-q', '-c', '1', '-r', '16000', '-b', '16', wavPath]),
          ]
        : <(String, List<String>)>[
            (
              'arecord',
              ['-q', '-f', 'S16_LE', '-r', '16000', '-c', '1', wavPath],
            ),
            (
              'ffmpeg',
              [
                '-hide_banner',
                '-loglevel',
                'error',
                '-f',
                'alsa',
                '-i',
                'default',
                '-ac',
                '1',
                '-ar',
                '16000',
                '-y',
                wavPath,
              ],
            ),
            ('rec', ['-q', '-c', '1', '-r', '16000', '-b', '16', wavPath]),
          ];

    for (final (bin, args) in candidates) {
      if (await _hasExecutable(bin)) {
        _process = await Process.start(bin, args);
        return;
      }
    }
    await _cleanupPath(wavPath);
    throw StateError(
      macos
          ? '未找到录音工具（请安装 ffmpeg 或 sox）'
          : '未找到录音工具（请安装 arecord、ffmpeg 或 sox）',
    );
  }

  static Future<bool> _hasExecutable(String name) async {
    try {
      final result = await Process.run('which', [name]);
      return result.exitCode == 0;
    } on Object {
      return false;
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
