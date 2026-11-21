import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Status of the open-source `cua-driver` binary (https://github.com/trycua/cua).
enum CuaDriverState { unknown, notInstalled, installing, installed, error }

/// Manages detection, installation, removal, daemon lifecycle, and CLI
/// invocation of `cua-driver`.
class CuaDriverService extends ChangeNotifier {
  CuaDriverService._();
  static final instance = CuaDriverService._();

  CuaDriverState _state = CuaDriverState.unknown;
  String? _binaryPath;
  String? _version;
  String? _lastError;
  String _installLog = '';
  bool _daemonRunning = false;
  bool? _driverAccessibility;
  bool? _driverScreenRecording;
  Future<bool>? _startingDaemon;

  CuaDriverState get state => _state;
  String? get binaryPath => _binaryPath;
  String? get version => _version;
  String? get lastError => _lastError;
  String get installLog => _installLog;
  bool get daemonRunning => _daemonRunning;
  bool? get driverAccessibility => _driverAccessibility;
  bool? get driverScreenRecording => _driverScreenRecording;
  bool get isInstalled =>
      _state == CuaDriverState.installed && _binaryPath != null;

  static String get _home =>
      Platform.environment['HOME'] ?? Directory.systemTemp.path;

  List<String> _candidatePaths() => [
    p.join(_home, '.local', 'bin', 'cua-driver'),
    '/Applications/CuaDriver.app/Contents/MacOS/cua-driver',
    '/opt/homebrew/bin/cua-driver',
    '/usr/local/bin/cua-driver',
  ];

  Future<void> refresh() async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    _lastError = null;
    String? found;
    for (final candidate in _candidatePaths()) {
      if (File(candidate).existsSync()) {
        found = candidate;
        break;
      }
    }
    if (found == null) {
      try {
        final which = await Process.run('which', ['cua-driver']);
        if (which.exitCode == 0) {
          final out = (which.stdout as String).trim();
          if (out.isNotEmpty) found = out;
        }
      } on Object {
        // Ignore lookup error.
      }
    }
    if (found == null) {
      _binaryPath = null;
      _version = null;
      _daemonRunning = false;
      _driverAccessibility = null;
      _driverScreenRecording = null;
      _state = CuaDriverState.notInstalled;
      notifyListeners();
      return;
    }

    _binaryPath = found;
    try {
      final res = await Process.run(found, ['--version']);
      final out = '${res.stdout}\n${res.stderr}'.trim();
      _version = out.isEmpty ? 'installed' : out.split('\n').first.trim();
      _state = CuaDriverState.installed;
      await refreshDaemonAndPermissions();
    } on Object catch (e) {
      _version = null;
      _lastError = '$e';
      _state = CuaDriverState.error;
    }
    notifyListeners();
  }

  /// Checks whether the cua-driver daemon is running and reads its TCC grants.
  Future<void> refreshDaemonAndPermissions() async {
    final bin = _binaryPath;
    if (bin == null || Platform.environment.containsKey('FLUTTER_TEST')) return;
    try {
      final statusRes = await Process.run(
        bin,
        ['status'],
      ).timeout(const Duration(seconds: 5));
      final out = '${statusRes.stdout}\n${statusRes.stderr}'.toLowerCase();
      _daemonRunning =
          statusRes.exitCode == 0 && !out.contains('not running');
    } on Object {
      _daemonRunning = false;
    }

    if (Platform.isMacOS) {
      try {
        final permRes = await Process.run(
          bin,
          ['permissions', 'status', '--json'],
        ).timeout(const Duration(seconds: 6));
        if (permRes.exitCode == 0) {
          final decoded = jsonDecode('${permRes.stdout}');
          if (decoded is Map) {
            _driverAccessibility = decoded['accessibility'] == true;
            _driverScreenRecording = decoded['screen_recording'] == true;
            if (decoded['daemon_running'] == true) _daemonRunning = true;
          }
        }
      } on Object {
        // Ignore transient probe failures.
      }
    }
    notifyListeners();
  }

  /// Ensures the `cua-driver serve` daemon is running using `CuaDriver.app`'s
  /// own signed macOS TCC identity (so rebuilding Ayte never resets grants).
  Future<bool> ensureDaemonRunning() async {
    if (_startingDaemon != null) return _startingDaemon!;
    final future = _ensureDaemonRunningImpl();
    _startingDaemon = future;
    try {
      return await future;
    } finally {
      _startingDaemon = null;
    }
  }

  Future<bool> _ensureDaemonRunningImpl() async {
    final bin = _binaryPath;
    if (bin == null) return false;
    await refreshDaemonAndPermissions();
    if (_daemonRunning) return true;

    try {
      await Process.start(
        bin,
        ['serve', '--no-permissions-gate'],
        mode: ProcessStartMode.detached,
      );
    } on Object catch (e) {
      _lastError = 'Failed to start cua-driver daemon: $e';
      notifyListeners();
      return false;
    }

    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      try {
        final res = await Process.run(
          bin,
          ['status'],
        ).timeout(const Duration(seconds: 3));
        final out = '${res.stdout}\n${res.stderr}'.toLowerCase();
        if (res.exitCode == 0 && !out.contains('not running')) {
          _daemonRunning = true;
          notifyListeners();
          return true;
        }
      } on Object {
        // Keep waiting.
      }
    }
    return false;
  }

  Future<void> stopDaemon() async {
    final bin = _binaryPath;
    if (bin == null) return;
    try {
      await Process.run(bin, ['stop']).timeout(const Duration(seconds: 5));
    } on Object {
      // Ignore.
    }
    _daemonRunning = false;
    notifyListeners();
  }

  /// Installs the open-source `cua-driver` via its official installer script
  /// with `--no-connect --no-test --no-modify-path` so it stays scoped cleanly.
  Future<bool> install() async {
    if (_state == CuaDriverState.installing) return false;
    _state = CuaDriverState.installing;
    _lastError = null;
    _installLog = '';
    notifyListeners();

    try {
      final binDir = p.join(_home, '.local', 'bin');
      Directory(binDir).createSync(recursive: true);
      final proc = await Process.start(
        '/bin/bash',
        [
          '-c',
          'curl -fsSL https://cua.ai/driver/install.sh | /bin/bash -s -- '
              '--bin-dir "$binDir" --no-connect --no-test --no-modify-path',
        ],
        environment: {
          ...Platform.environment,
          'CUA_DRIVER_NO_CONNECT': '1',
          'CUA_DRIVER_NO_TEST': '1',
          'CUA_DRIVER_NO_MODIFY_PATH': '1',
        },
      );

      final subOut = proc.stdout.transform(utf8.decoder).listen((chunk) {
        _installLog += chunk;
        notifyListeners();
      });
      final subErr = proc.stderr.transform(utf8.decoder).listen((chunk) {
        _installLog += chunk;
        notifyListeners();
      });

      final code = await proc.exitCode;
      await subOut.cancel();
      await subErr.cancel();

      if (code != 0) {
        _state = CuaDriverState.error;
        _lastError = 'Installer exited with code $code';
        notifyListeners();
        return false;
      }
      await refresh();
      return isInstalled;
    } on Object catch (e) {
      _state = CuaDriverState.error;
      _lastError = '$e';
      notifyListeners();
      return false;
    }
  }

  Future<bool> uninstall() async {
    await stopDaemon();
    try {
      final res = await Process.run('/bin/bash', [
        '-c',
        'curl -fsSL https://cua.ai/driver/uninstall.sh | /bin/bash',
      ]);
      if (res.exitCode != 0 && _binaryPath != null) {
        final f = File(_binaryPath!);
        if (f.existsSync()) f.deleteSync();
      }
    } on Object {
      if (_binaryPath != null) {
        final f = File(_binaryPath!);
        if (f.existsSync()) f.deleteSync();
      }
    }
    await refresh();
    return !isInstalled;
  }

  /// Invokes `cua-driver call <tool> <jsonArgs>`, auto-starting the daemon if
  /// needed. Optionally writes the first screenshot block to [screenshotOutFile].
  Future<({bool ok, String stdout, String stderr})> callTool(
    String tool,
    Map<String, Object?> args, {
    String? screenshotOutFile,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    if (_binaryPath == null) {
      await refresh();
    }
    final bin = _binaryPath;
    if (bin == null) {
      return (
        ok: false,
        stdout: '',
        stderr:
            'cua-driver is not installed. Install it in Settings → Computer Use.',
      );
    }
    final ready = await ensureDaemonRunning();
    if (!ready) {
      return (
        ok: false,
        stdout: '',
        stderr:
            'Failed to start cua-driver daemon. Try starting it in Settings → Computer Use.',
      );
    }
    try {
      final cmdArgs = <String>[
        'call',
        if (screenshotOutFile != null) ...[
          '--screenshot-out-file',
          screenshotOutFile,
        ],
        tool,
        jsonEncode(args),
      ];
      final res = await Process.run(bin, cmdArgs).timeout(timeout);
      return (
        ok: res.exitCode == 0,
        stdout: '${res.stdout}'.trim(),
        stderr: '${res.stderr}'.trim(),
      );
    } on TimeoutException {
      return (
        ok: false,
        stdout: '',
        stderr: 'cua-driver call $tool timed out.',
      );
    } on Object catch (e) {
      return (ok: false, stdout: '', stderr: '$e');
    }
  }
}
