import 'dart:convert';
import 'dart:io';

import 'package:baocode/kernel/claude_code/claude_cli_transport.dart';
import 'package:baocode/kernel/claude_code/claude_code_transport.dart';
import 'package:baocode/kernel/claude_code/claude_environment.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

String _resolveDartExe() {
  final exeName = Platform.isWindows ? 'dart.exe' : 'dart';
  final direct = p.join(p.dirname(Platform.resolvedExecutable), exeName);
  if (File(direct).existsSync()) return direct;
  if (Platform.environment['FLUTTER_ROOT'] case final root?
      when root.isNotEmpty) {
    final sdkDart = p.join(root, 'bin', 'cache', 'dart-sdk', 'bin', exeName);
    if (File(sdkDart).existsSync()) return sdkDart;
  }
  var cursor = Directory(p.dirname(Platform.resolvedExecutable));
  for (var i = 0; i < 6; i++) {
    final sdkDart = p.join(cursor.path, 'dart-sdk', 'bin', exeName);
    if (File(sdkDart).existsSync()) return sdkDart;
    final binCacheDart = p.join(
      cursor.path,
      'bin',
      'cache',
      'dart-sdk',
      'bin',
      exeName,
    );
    if (File(binCacheDart).existsSync()) return binCacheDart;
    final parent = cursor.parent;
    if (parent.path == cursor.path) break;
    cursor = parent;
  }
  return exeName;
}

bool _isPidAlive(int pid) {
  if (Platform.isWindows) {
    final res = Process.runSync('tasklist', ['/FI', 'PID eq $pid', '/NH']);
    return RegExp('(?:^|\\s)$pid(?:\\s|\$)', multiLine: true)
        .hasMatch('${res.stdout}');
  }
  return Process.killPid(pid, ProcessSignal.sigcont);
}

void _killPidTree(int pid) {
  if (Platform.isWindows) {
    Process.runSync('taskkill', ['/PID', '$pid', '/T', '/F']);
  } else {
    Process.killPid(pid, ProcessSignal.sigkill);
  }
}

void main() {
  group('ClaudeCliTransport Windows env, process-tree kill & stopAll()', () {
    test('enrichEnvironmentForTesting & locateClaudeForTesting handle Windows mixed-case keys and explicit blank values without host fallback', () {
      final enriched = ClaudeCliTransport.enrichEnvironmentForTesting({
        'Path': r'C:\FakeBin',
        'Home': r'C:\Users\Mixed',
        'UserProfile': r'C:\Users\Mixed',
      }, forceWindows: true);
      expect(enriched.containsKey('Path'), isFalse);
      expect(enriched['PATH'], r'C:\FakeBin');

      final blank = ClaudeCliTransport.enrichEnvironmentForTesting({
        'Path': '',
        'Home': '',
        'UserProfile': '',
      }, forceWindows: true);
      expect(blank['PATH'], '');

      final tmp = Directory.systemTemp.createTempSync('claude_loc_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final fakeCmd = File(p.join(tmp.path, 'claude.cmd'))
        ..writeAsStringSync('@echo off\r\n');
      expect(
        ClaudeCliTransport.locateClaudeForTesting(
          {'Path': tmp.path},
          forceWindows: true,
        ),
        fakeCmd.path,
      );
      expect(
        ClaudeCliTransport.locateClaudeForTesting(
          {'Path': ''},
          forceWindows: true,
        ),
        isNull,
      );
    });

    test('start(), close(), and stopAll() isolate mixed-case env, kill Windows grandchild trees, and defer exited until settings file cleanup completes', () async {
      final tmp = Directory.systemTemp.createTempSync('claude_cli_tr_');
      addTearDown(() async {
        await ClaudeCliTransport.stopAll();
        ClaudeEnvironment.use(null);
        for (var i = 0; i < 10; i++) {
          if (!tmp.existsSync()) break;
          try {
            tmp.deleteSync(recursive: true);
            break;
          } on FileSystemException {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }
      });

      final fakeBin = Directory(p.join(tmp.path, 'bin'))..createSync();
      final fakeHome = Directory(p.join(tmp.path, 'home'))..createSync();
      final workDir = Directory(p.join(tmp.path, 'cwd'))..createSync();
      final gcPidFile = File(p.join(tmp.path, 'gc.pid'));
      final launchLog = File(p.join(tmp.path, 'launch.json'));
      final dartExe = _resolveDartExe();

      final sleeper = File(p.join(tmp.path, 'sleeper.dart'))
        ..writeAsStringSync('''
import 'dart:io';
Future<void> main() async {
  File(${jsonEncode(gcPidFile.path)}).writeAsStringSync('\$pid', flush: true);
  await Future<void>.delayed(const Duration(seconds: 30));
}
''');

      final parentScript = File(p.join(tmp.path, 'fake_claude.dart'))
        ..writeAsStringSync('''
import 'dart:convert';
import 'dart:io';
Future<void> main(List<String> args) async {
  File(${jsonEncode(launchLog.path)}).writeAsStringSync(
    jsonEncode({'args': args, 'envPath': Platform.environment['PATH']}),
    flush: true,
  );
  await Process.start(${jsonEncode(dartExe)}, [${jsonEncode(sleeper.path)}]);
  stdout.writeln(jsonEncode({'type': 'system', 'subtype': 'init', 'session_id': 'c-1'}));
  await stdout.flush();
  await stdin.transform(utf8.decoder).drain<void>();
}
''');

      if (Platform.isWindows) {
        File(p.join(fakeBin.path, 'claude.cmd')).writeAsStringSync(
          '@echo off\r\n"$dartExe" "${parentScript.path}" %*\r\n',
        );
      } else {
        final sh = File(p.join(fakeBin.path, 'claude'))
          ..writeAsStringSync(
            '#!/bin/sh\nexec "$dartExe" "${parentScript.path}" "\$@"\n',
          );
        Process.runSync('chmod', ['+x', sh.path]);
      }

      ClaudeEnvironment.use({
        if (Platform.isWindows) 'Path': fakeBin.path else 'PATH': fakeBin.path,
        if (Platform.isWindows) 'UserProfile': fakeHome.path else 'HOME': fakeHome.path,
        if (Platform.isWindows && Platform.environment['SystemRoot'] != null)
          'SystemRoot': Platform.environment['SystemRoot']!,
      });

      final tr = (await ClaudeCliTransport.start(
        ClaudeLaunch(
          cwd: workDir.path,
          persist: false,
          env: const {'ANTHROPIC_API_KEY': 'sk-test-secret'},
        ),
      )) as ClaudeCliTransport;
      addTearDown(() async {
        tr.close();
        await ClaudeCliTransport.stopAll();
        if (gcPidFile.existsSync()) {
          final pidVal = int.tryParse(gcPidFile.readAsStringSync().trim());
          if (pidVal != null) _killPidTree(pidVal);
        }
      });

      final settingsPath = tr.settingsFilePathForTesting;
      expect(settingsPath, isNotNull);
      expect(File(settingsPath!).existsSync(), isTrue);

      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while ((!gcPidFile.existsSync() || !launchLog.existsSync()) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(gcPidFile.existsSync(), isTrue);
      expect(launchLog.existsSync(), isTrue);
      final gcPid = int.parse(gcPidFile.readAsStringSync().trim());
      expect(_isPidAlive(gcPid), isTrue);

      final captured = jsonDecode(launchLog.readAsStringSync()) as Map;
      expect(captured['envPath'], fakeBin.path);

      tr.close();
      await ClaudeCliTransport.stopAll();
      await tr.exited.timeout(const Duration(seconds: 5));

      expect(_isPidAlive(gcPid), isFalse);
      expect(File(settingsPath).existsSync(), isFalse);
    });

    testWidgets('stopAll() when idle completes inside FakeAsync without pending timers', (tester) async {
      await ClaudeCliTransport.stopAll();
      await tester.pump();
    });
  });
}
