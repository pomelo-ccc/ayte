import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baocode/kernel/claude_code/claude_environment.dart';
import 'package:baocode/kernel/codex/codex_process_transport.dart';
import 'package:baocode/network/network_proxy_io.dart';
import 'package:baocode/network/proxy_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('codex_transport_test_');
  });

  tearDown(() async {
    ClaudeEnvironment.use(null);
    await ProcessCodexTransport.stopAll();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('ProcessCodexTransport PATH & binary discovery', () {
    test('readPathVar and withPath handle Windows Path case-insensitively', () {
      final env = {'Path': r'C:\Tools;C:\Node', 'FOO': 'bar'};
      expect(
        ProcessCodexTransport.readPathVar(env, forceWindows: true),
        r'C:\Tools;C:\Node',
      );
      final updated = ProcessCodexTransport.withPath(
        env,
        r'C:\New',
        forceWindows: true,
      );
      expect(updated.containsKey('Path'), isFalse);
      expect(updated['PATH'], r'C:\New');
      expect(updated['FOO'], 'bar');
    });

    test('enrichedPath includes Windows npm, Volta, nodejs, and Codex app bin dirs', () {
      final appData = p.join(tempDir.path, 'Roaming');
      final localAppData = p.join(tempDir.path, 'Local');
      final programFiles = p.join(tempDir.path, 'ProgramFiles');
      final home = p.join(tempDir.path, 'Home');
      final codexHashDir = Directory(
        p.join(localAppData, 'OpenAI', 'Codex', 'bin', '9e1da79431da526b'),
      )..createSync(recursive: true);
      File(p.join(codexHashDir.path, 'codex.exe')).writeAsStringSync('');

      final enriched = ProcessCodexTransport.enrichedPath({
        'Path': r'C:\Existing;c:\existing',
        'APPDATA': appData,
        'LOCALAPPDATA': localAppData,
        'ProgramFiles': programFiles,
        'USERPROFILE': home,
      }, forceWindows: true);

      final parts = enriched['PATH']!.split(';');
      expect(parts.where((d) => d.toLowerCase() == r'c:\existing'), hasLength(1));
      expect(parts, contains(p.windows.join(appData, 'npm')));
      expect(parts, contains(p.windows.join(localAppData, 'Volta', 'bin')));
      expect(parts, contains(p.windows.join(programFiles, 'nodejs')));
      expect(parts, contains(p.windows.join(home, '.bun', 'bin')));
      expect(parts, contains(codexHashDir.path));
    });

    test('enrichedPath reads Windows env vars case-insensitively and avoids host fallback when key is explicitly blank', () {
      final appData = p.join(tempDir.path, 'LowerRoaming');
      final localAppData = p.join(tempDir.path, 'LowerLocal');
      final programFiles = p.join(tempDir.path, 'LowerProgramFiles');
      final voltaHome = p.join(tempDir.path, 'LowerVolta');
      final home = p.join(tempDir.path, 'LowerHome');
      final codexHashDir = Directory(
        p.join(localAppData, 'OpenAI', 'Codex', 'bin', 'case123'),
      )..createSync(recursive: true);
      File(p.join(codexHashDir.path, 'codex.exe')).writeAsStringSync('');

      final enriched = ProcessCodexTransport.enrichedPath({
        'path': r'C:\OnlyThis',
        'appdata': appData,
        'localappdata': localAppData,
        'volta_home': voltaHome,
        'programfiles': programFiles,
        'userprofile': home,
      }, forceWindows: true);

      final parts = enriched['PATH']!.split(';');
      expect(parts, contains(p.windows.join(appData, 'npm')));
      expect(parts, contains(p.windows.join(localAppData, 'Volta', 'bin')));
      expect(parts, contains(p.windows.join(voltaHome, 'bin')));
      expect(parts, contains(p.windows.join(programFiles, 'nodejs')));
      expect(parts, contains(p.windows.join(home, '.bun', 'bin')));
      expect(parts, contains(codexHashDir.path));

      // Explicitly blanked keys must not fall back to host Platform.environment.
      final isolated = ProcessCodexTransport.enrichedPath({
        'path': r'C:\Isolated',
        'appdata': '',
        'localappdata': '',
        'volta_home': '',
        'programfiles': '',
        'home': '',
        'userprofile': '',
      }, forceWindows: true);
      expect(isolated['PATH'], r'C:\Isolated');
    });

    test('locateCodex respects PATH directory order and prefers .exe over shims within a directory', () {
      // (a) Per-directory preference: .exe > .cmd > .bat > .ps1.
      final sameDir = Directory(p.join(tempDir.path, 'same'))..createSync();
      final sameCmd = File(p.join(sameDir.path, 'codex.cmd'))
        ..writeAsStringSync('@echo off');
      final sameExe = File(p.join(sameDir.path, 'codex.exe'))
        ..writeAsStringSync('');
      expect(
        ProcessCodexTransport.locateCodex({
          'PATH': sameDir.path,
        }, forceWindows: true),
        sameExe.path,
      );
      sameExe.deleteSync();
      expect(
        ProcessCodexTransport.locateCodex({
          'PATH': sameDir.path,
        }, forceWindows: true),
        sameCmd.path,
      );
      sameCmd.deleteSync();
      final samePs1 = File(p.join(sameDir.path, 'codex.ps1'))
        ..writeAsStringSync('# ps1');
      expect(
        ProcessCodexTransport.locateCodex({
          'PATH': sameDir.path,
        }, forceWindows: true),
        samePs1.path,
      );

      // (b) PATH directory precedence: dir1\codex.cmd beats dir2\codex.exe and
      // LOCALAPPDATA\OpenAI\Codex\bin\*\codex.exe.
      final dir1 = Directory(p.join(tempDir.path, 'dir1'))..createSync();
      final dir2 = Directory(p.join(tempDir.path, 'dir2'))..createSync();
      final appDir = Directory(
        p.join(tempDir.path, 'Local', 'OpenAI', 'Codex', 'bin', 'abc123'),
      )..createSync(recursive: true);
      final dir1Cmd = File(p.join(dir1.path, 'codex.cmd'))
        ..writeAsStringSync('@echo off');
      File(p.join(dir2.path, 'codex.exe')).writeAsStringSync('');
      final appExe = File(p.join(appDir.path, 'codex.exe'))
        ..writeAsStringSync('');

      final env = {
        'PATH': '${dir1.path};${dir2.path}',
        'LOCALAPPDATA': p.join(tempDir.path, 'Local'),
      };
      expect(
        ProcessCodexTransport.locateCodex(env, forceWindows: true),
        dir1Cmd.path,
      );

      // (c) Falls back to LOCALAPPDATA\OpenAI\Codex\bin when PATH dirs have no codex.
      final emptyDir = Directory(p.join(tempDir.path, 'empty'))..createSync();
      expect(
        ProcessCodexTransport.locateCodex({
          'PATH': emptyDir.path,
          'LOCALAPPDATA': p.join(tempDir.path, 'Local'),
        }, forceWindows: true),
        appExe.path,
      );
      expect(
        ProcessCodexTransport.locateCodex({
          'PATH': emptyDir.path,
          'localappdata': p.join(tempDir.path, 'Local'),
        }, forceWindows: true),
        appExe.path,
      );
    });

    test('locateCodex with enrichedPath lets earlier PATH codex.cmd beat VOLTA_HOME codex.exe', () {
      final firstDir = Directory(p.join(tempDir.path, 'first_bin'))
        ..createSync();
      final voltaDir = Directory(p.join(tempDir.path, 'volta'))..createSync();
      final voltaBin = Directory(p.join(voltaDir.path, 'bin'))
        ..createSync(recursive: true);
      final firstCmd = File(p.join(firstDir.path, 'codex.cmd'))
        ..writeAsStringSync('@echo off');
      File(p.join(voltaBin.path, 'codex.exe')).writeAsStringSync('');

      final enriched = ProcessCodexTransport.enrichedPath({
        'PATH': firstDir.path,
        'VOLTA_HOME': voltaDir.path,
        'LOCALAPPDATA': p.join(tempDir.path, 'missing_local'),
        'APPDATA': p.join(tempDir.path, 'missing_roaming'),
        'USERPROFILE': p.join(tempDir.path, 'missing_home'),
      }, forceWindows: true);

      expect(
        ProcessCodexTransport.locateCodex(enriched, forceWindows: true),
        firstCmd.path,
      );
    });
  });

  group('ProcessCodexTransport Windows shim unwrapping', () {
    test('unwraps npm .cmd shim to node.exe + script with runInShell: false', () {
      final binDir = Directory(p.join(tempDir.path, 'npm'))..createSync();
      final nodeDir = Directory(p.join(tempDir.path, 'nodejs'))..createSync();
      final nodeExe = File(p.join(nodeDir.path, 'node.exe'))
        ..writeAsStringSync('');
      final scriptDir = Directory(
        p.join(binDir.path, 'node_modules', '@openai', 'codex', 'bin'),
      )..createSync(recursive: true);
      final scriptFile = File(p.join(scriptDir.path, 'codex.js'))
        ..writeAsStringSync('// codex');
      final shimFile = File(p.join(binDir.path, 'codex.cmd'))
        ..writeAsStringSync(
          '@ECHO off\r\n"%dp0%\\node_modules\\@openai\\codex\\bin\\codex.js" %*\r\n',
        );

      final spec = ProcessCodexTransport.resolveLaunch(
        shimFile.path,
        {'PATH': nodeDir.path},
        appServerArgs: const ['app-server', '-c', 'mcp_servers.baocode.url="http://127.0.0.1:9/mcp/tok"'],
        forceWindows: true,
      );
      expect(spec.executable, nodeExe.path);
      expect(spec.runInShell, isFalse);
      expect(spec.arguments, [
        p.normalize(scriptFile.path),
        'app-server',
        '-c',
        'mcp_servers.baocode.url="http://127.0.0.1:9/mcp/tok"',
      ]);
      expect(spec.resolvedBinary, shimFile.path);
    });

    test('unwraps Windows %~dp0\\... and %~dp0... .cmd shims to node.exe', () {
      final binDir = Directory(p.join(tempDir.path, 'npm_tilde'))..createSync();
      final nodeDir = Directory(p.join(tempDir.path, 'nodejs_tilde'))..createSync();
      final nodeExe = File(p.join(nodeDir.path, 'node.exe'))
        ..writeAsStringSync('');
      final scriptDir = Directory(
        p.join(binDir.path, 'node_modules', 'pkg'),
      )..createSync(recursive: true);
      final scriptFile = File(p.join(scriptDir.path, 'codex.js'))
        ..writeAsStringSync('// codex');

      final shimSlash = File(p.join(binDir.path, 'codex_slash.cmd'))
        ..writeAsStringSync(
          '@ECHO off\r\n"%~dp0\\node_modules\\pkg\\codex.js" %*\r\n',
        );
      final shimNoSlash = File(p.join(binDir.path, 'codex_noslash.cmd'))
        ..writeAsStringSync(
          '@ECHO off\r\n"%~dp0node_modules\\pkg\\codex.js" %*\r\n',
        );

      for (final shim in [shimSlash, shimNoSlash]) {
        final spec = ProcessCodexTransport.resolveLaunch(
          shim.path,
          {'PATH': nodeDir.path},
          forceWindows: true,
        );
        expect(spec.executable, nodeExe.path);
        expect(spec.runInShell, isFalse);
        expect(spec.arguments, [p.normalize(scriptFile.path), 'app-server']);
        expect(spec.resolvedBinary, shim.path);
      }
    });

    test('unwraps npm .ps1 shim to node.exe + script', () {
      final binDir = Directory(p.join(tempDir.path, 'npm'))..createSync();
      final localNode = File(p.join(binDir.path, 'node.exe'))
        ..writeAsStringSync('');
      final scriptDir = Directory(
        p.join(binDir.path, 'node_modules', '@openai', 'codex', 'bin'),
      )..createSync(recursive: true);
      final scriptFile = File(p.join(scriptDir.path, 'codex.js'))
        ..writeAsStringSync('// codex');
      final ps1File = File(p.join(binDir.path, 'codex.ps1'))
        ..writeAsStringSync(
          '& "\$basedir/node_modules/@openai/codex/bin/codex.js" \$args\n',
        );

      final spec = ProcessCodexTransport.resolveLaunch(
        ps1File.path,
        const {},
        forceWindows: true,
      );
      expect(spec.executable, localNode.path);
      expect(spec.runInShell, isFalse);
      expect(spec.arguments, [p.normalize(scriptFile.path), 'app-server']);
    });

    test('falls back cleanly for non-JS .cmd and .ps1 shims', () {
      final binDir = Directory(p.join(tempDir.path, 'bin'))..createSync();
      final customCmd = File(p.join(binDir.path, 'codex.cmd'))
        ..writeAsStringSync('@echo off\r\ncodex-real.exe %*\r\n');
      final customPs1 = File(p.join(binDir.path, 'codex.ps1'))
        ..writeAsStringSync('Write-Host "custom"\n');

      final cmdSpec = ProcessCodexTransport.resolveLaunch(
        customCmd.path,
        const {},
        forceWindows: true,
      );
      expect(cmdSpec.executable, customCmd.path);
      expect(cmdSpec.runInShell, isTrue);

      final ps1Spec = ProcessCodexTransport.resolveLaunch(
        customPs1.path,
        const {},
        forceWindows: true,
      );
      expect(ps1Spec.executable, 'powershell.exe');
      expect(ps1Spec.runInShell, isFalse);
      expect(ps1Spec.arguments, containsAll(['-File', customPs1.path, 'app-server']));
    });
  });

  group('ProcessCodexTransport lifecycle, stderr tail, and respawn', () {
    test('fails pending writes and emits transportExit when binary is missing', () async {
      final emptyBin = Directory(p.join(tempDir.path, 'empty_bin'))..createSync();
      ClaudeEnvironment.use({
        'PATH': emptyBin.path,
        'APPDATA': emptyBin.path,
        'LOCALAPPDATA': emptyBin.path,
        'USERPROFILE': emptyBin.path,
        'HOME': emptyBin.path,
      });

      final transport = ProcessCodexTransport(cwd: tempDir.path);
      final received = <Map<String, Object?>>[];
      final sub = transport.messages.listen(received.add);
      addTearDown(() async {
        await sub.cancel();
        transport.close();
        await transport.exited;
      });

      transport.write({'id': 1, 'method': 'initialize', 'params': const {}});
      await transport.exited;
      await pumpEventQueue();

      expect(
        received.any(
          (m) =>
              m['id'] == 1 &&
              m['error'] is Map &&
              (m['error'] as Map)['code'] == -32000,
        ),
        isTrue,
      );
      final exitMsg = received.firstWhere(
        (m) => m['method'] == ProcessCodexTransport.transportExitMethod,
      );
      expect((exitMsg['params'] as Map)['missingBinary'], isTrue);
    });

    test('unwraps npm .cmd shim, captures bounded stderr tail, and respawns after exit', () async {
      if (!Platform.isWindows) return;
      final nodeExe = await _findWindowsNode();
      if (nodeExe == null) return;

      final npmDir = Directory(p.join(tempDir.path, 'npm'))..createSync();
      final pkgDir = Directory(
        p.join(npmDir.path, 'node_modules', '@openai', 'codex', 'bin'),
      )..createSync(recursive: true);
      final scriptFile = File(p.join(pkgDir.path, 'codex.js'));
      // Write a tiny Node script that:
      // - fails on run 1 (flag file absent) with 60 stderr lines + exit code 1
      // - succeeds on run 2, echoing JSON-RPC initialize & dynamic -c arg
      final markerFile = File(p.join(tempDir.path, 'run_count.txt'));
      scriptFile.writeAsStringSync('''
const fs = require('fs');
const readline = require('readline');
const marker = ${jsonEncode(markerFile.path)};
const count = fs.existsSync(marker) ? parseInt(fs.readFileSync(marker, 'utf8'), 10) + 1 : 1;
fs.writeFileSync(marker, String(count));
if (count === 1) {
  for (let i = 1; i <= 60; i++) {
    fs.writeSync(2, 'stderr line ' + i + '\\n');
  }
  fs.writeSync(2, 'Error: Missing optional dependency @openai/codex-win32-x64\\n');
  process.exit(1);
}
const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on('line', (line) => {
  if (!line.trim()) return;
  const msg = JSON.parse(line);
  if (msg.method === 'initialize') {
    process.stdout.write(JSON.stringify({ id: msg.id, result: { argv: process.argv.slice(2) } }) + '\\n');
  }
});
''');
      File(p.join(npmDir.path, 'codex.cmd')).writeAsStringSync(
        '@ECHO off\r\n"%dp0%\\node_modules\\@openai\\codex\\bin\\codex.js" %*\r\n',
      );

      ClaudeEnvironment.use({
        'PATH': '${npmDir.path};${p.dirname(nodeExe)}',
        'APPDATA': npmDir.path,
        'LOCALAPPDATA': npmDir.path,
        'USERPROFILE': tempDir.path,
        'SystemRoot': ?Platform.environment['SystemRoot'],
      });

      final transport = ProcessCodexTransport(
        cwd: tempDir.path,
        extraArgsBuilder: () => const ['-c', 'mcp_servers.baocode.enabled=true'],
      );
      final received = <Map<String, Object?>>[];
      final sub = transport.messages.listen(received.add);
      addTearDown(() async {
        await sub.cancel();
        transport.close();
        await transport.exited;
      });

      // Run 1: crashes with >50 stderr lines
      transport.write({'id': 1, 'method': 'initialize', 'params': const {}});
      await _waitUntil(
        () => received.any(
          (m) => m['method'] == ProcessCodexTransport.transportExitMethod,
        ),
      );
      expect(
        transport.stderrTail.length,
        50,
        reason: 'Got ${transport.stderrTail.length} lines: ${transport.stderrTail}',
      );
      expect(
        transport.stderrTail.last,
        contains('Missing optional dependency @openai/codex-win32-x64'),
      );
      final exitParams =
          received
                  .firstWhere(
                    (m) =>
                        m['method'] ==
                        ProcessCodexTransport.transportExitMethod,
                  )['params']
              as Map;
      expect(exitParams['code'], 1);
      expect(
        exitParams['stderr'],
        contains('Missing optional dependency @openai/codex-win32-x64'),
      );

      // Run 2: respawns cleanly on next write() and receives dynamic -c args
      transport.write({'id': 2, 'method': 'initialize', 'params': const {}});
      await _waitUntil(() => received.any((m) => m['id'] == 2));
      final initResp = received.firstWhere((m) => m['id'] == 2);
      final argv = ((initResp['result'] as Map)['argv'] as List).cast<String>();
      expect(argv, [
        'app-server',
        '-c',
        'mcp_servers.baocode.enabled=true',
      ]);

      await transport.stopProcess();
    });

    test('overlapping unawaited stopProcess() + immediate write() spawns fresh process cleanly', () async {
      if (!Platform.isWindows) return;
      final nodeExe = await _findWindowsNode();
      if (nodeExe == null) return;

      final npmDir = Directory(p.join(tempDir.path, 'npm_overlap'))..createSync();
      final pkgDir = Directory(
        p.join(npmDir.path, 'node_modules', '@openai', 'codex', 'bin'),
      )..createSync(recursive: true);
      final scriptFile = File(p.join(pkgDir.path, 'codex.js'));
      // Process delays exit slightly on stdin end/SIGTERM so old process exits
      // while new process is already running.
      scriptFile.writeAsStringSync('''
const readline = require('readline');
process.on('SIGTERM', () => {
  setTimeout(() => process.exit(0), 120);
});
const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on('line', (line) => {
  if (!line.trim()) return;
  const msg = JSON.parse(line);
  if (msg.method === 'initialize') {
    process.stdout.write(JSON.stringify({ id: msg.id, result: { pid: process.pid } }) + '\\n');
  }
});
rl.on('close', () => {
  process.stderr.write('stale proc closing\\n');
  setTimeout(() => process.exit(0), 120);
});
''');
      File(p.join(npmDir.path, 'codex.cmd')).writeAsStringSync(
        '@ECHO off\r\n"%~dp0\\node_modules\\@openai\\codex\\bin\\codex.js" %*\r\n',
      );

      ClaudeEnvironment.use({
        'PATH': '${npmDir.path};${p.dirname(nodeExe)}',
        'APPDATA': npmDir.path,
        'LOCALAPPDATA': npmDir.path,
        'USERPROFILE': tempDir.path,
        'SystemRoot': ?Platform.environment['SystemRoot'],
      });

      final transport = ProcessCodexTransport(cwd: tempDir.path);
      final received = <Map<String, Object?>>[];
      final sub = transport.messages.listen(received.add);
      addTearDown(() async {
        await sub.cancel();
        transport.close();
        await transport.exited;
      });

      transport.write({'id': 1, 'method': 'initialize', 'params': const {}});
      await _waitUntil(() => received.any((m) => m['id'] == 1));
      final pid1 = ((received.firstWhere((m) => m['id'] == 1))['result'] as Map)['pid'];

      // Immediately stopProcess() without awaiting, then write() to spawn proc 2.
      unawaited(transport.stopProcess());
      transport.write({'id': 2, 'method': 'initialize', 'params': const {}});
      await _waitUntil(() => received.any((m) => m['id'] == 2));

      // Wait past proc 1's 120ms exit delay and verify proc 2 stays alive (no transportExit).
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final pid2 = ((received.firstWhere((m) => m['id'] == 2))['result'] as Map)['pid'];
      expect(pid2, isNot(pid1));
      expect(
        received.any((m) => m['method'] == ProcessCodexTransport.transportExitMethod),
        isFalse,
      );
      expect(transport.stderrTail, isEmpty);

      await transport.stopProcess();
    });

    test('close() and stopProcess() terminate Windows .cmd child trees and close() defers exited during mid-spawn', () async {
      final dartExe = _resolveDartExecutableForCodexTest();
      final sleeper = File(p.join(tempDir.path, 'sleeper.dart'))
        ..writeAsStringSync('''
import 'dart:io';
Future<void> main() async {
  await Future<void>.delayed(const Duration(seconds: 30));
}
''');
      final gcPidFile = File(p.join(tempDir.path, 'codex_gc.pid'));
      final parentScript = File(p.join(tempDir.path, 'fake_codex_parent.dart'))
        ..writeAsStringSync('''
import 'dart:convert';
import 'dart:io';
Future<void> main() async {
  final proc = await Process.start(${jsonEncode(dartExe)}, [${jsonEncode(sleeper.path)}]);
  File(${jsonEncode(gcPidFile.path)}).writeAsStringSync('\${proc.pid}', flush: true);
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    final msg = jsonDecode(line) as Map;
    if (msg['method'] == 'initialize') {
      stdout.writeln(jsonEncode({'id': msg['id'], 'result': <String, Object?>{}}));
      await stdout.flush();
    }
  }
}
''');

      final binDir = Directory(p.join(tempDir.path, 'bin_tree'))..createSync();
      if (Platform.isWindows) {
        File(p.join(binDir.path, 'codex.cmd')).writeAsStringSync(
          '@echo off\r\n"$dartExe" "${parentScript.path}" %*\r\n',
        );
      } else {
        final sh = File(p.join(binDir.path, 'codex'))
          ..writeAsStringSync(
            '#!/bin/sh\nexec "$dartExe" "${parentScript.path}" "\$@"\n',
          );
        Process.runSync('chmod', ['+x', sh.path]);
      }

      ClaudeEnvironment.use({
        'PATH': '${binDir.path}${Platform.isWindows ? ';' : ':'}${p.dirname(dartExe)}',
        'APPDATA': binDir.path,
        'LOCALAPPDATA': binDir.path,
        'USERPROFILE': tempDir.path,
        'HOME': tempDir.path,
        'SystemRoot': ?Platform.environment['SystemRoot'],
      });

      final transport = ProcessCodexTransport(cwd: tempDir.path);
      final received = <Map<String, Object?>>[];
      final sub = transport.messages.listen(received.add);
      addTearDown(() async {
        await sub.cancel();
        transport.close();
        await transport.exited;
        if (gcPidFile.existsSync()) {
          final gcPid = int.tryParse(gcPidFile.readAsStringSync().trim());
          if (gcPid != null) {
            if (Platform.isWindows) {
              Process.runSync('taskkill', ['/PID', '$gcPid', '/T', '/F']);
            } else {
              Process.killPid(gcPid, ProcessSignal.sigkill);
            }
          }
        }
      });

      transport.write({'id': 1, 'method': 'initialize', 'params': const {}});
      await _waitUntil(() => received.any((m) => m['id'] == 1));
      await _waitUntil(() => gcPidFile.existsSync());
      final gcPid1 = int.parse(gcPidFile.readAsStringSync().trim());
      expect(_isPidAliveCodex(gcPid1), isTrue);

      await transport.stopProcess();
      expect(
        _isPidAliveCodex(gcPid1),
        isFalse,
        reason: 'Grandchild PID $gcPid1 must be killed when transport.stopProcess() terminates .cmd wrapper',
      );

      // Respawn after stopProcess() and verify close() also terminates the new child tree.
      gcPidFile.deleteSync();
      transport.write({'id': 2, 'method': 'initialize', 'params': const {}});
      await _waitUntil(() => received.any((m) => m['id'] == 2));
      await _waitUntil(() => gcPidFile.existsSync());
      final gcPid2 = int.parse(gcPidFile.readAsStringSync().trim());
      expect(gcPid2, isNot(gcPid1));
      expect(_isPidAliveCodex(gcPid2), isTrue);

      transport.close();
      await transport.exited.timeout(const Duration(seconds: 5));
      expect(
        _isPidAliveCodex(gcPid2),
        isFalse,
        reason: 'Grandchild PID $gcPid2 must be killed when transport.close() terminates .cmd wrapper',
      );

      // Mid-spawn close() must NOT complete exited synchronously before _spawn() settles.
      final midTransport = ProcessCodexTransport(cwd: tempDir.path);
      addTearDown(() async {
        midTransport.close();
        await midTransport.exited;
      });
      var exitedEarly = false;
      midTransport.write({'id': 3, 'method': 'initialize', 'params': const {}});
      unawaited(midTransport.exited.then((_) => exitedEarly = true));
      midTransport.close();
      expect(exitedEarly, isFalse);
      await midTransport.exited.timeout(const Duration(seconds: 5));
      expect(exitedEarly, isTrue);
    });

    test('ProcessCodexTransport.stopAll() closes live transports and awaits exited', () async {
      final dartExe = _resolveDartExecutableForCodexTest();
      final sleeper = File(p.join(tempDir.path, 'sleeper_stop_all.dart'))
        ..writeAsStringSync('''
import 'dart:io';
Future<void> main() async {
  await Future<void>.delayed(const Duration(seconds: 30));
}
''');
      final gcPidFile = File(p.join(tempDir.path, 'stop_all_gc.pid'));
      final parentScript = File(p.join(tempDir.path, 'fake_codex_stop_all.dart'))
        ..writeAsStringSync('''
import 'dart:convert';
import 'dart:io';
Future<void> main() async {
  final proc = await Process.start(${jsonEncode(dartExe)}, [${jsonEncode(sleeper.path)}]);
  File(${jsonEncode(gcPidFile.path)}).writeAsStringSync('\${proc.pid}', flush: true);
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    final msg = jsonDecode(line) as Map;
    if (msg['method'] == 'initialize') {
      stdout.writeln(jsonEncode({'id': msg['id'], 'result': <String, Object?>{}}));
      await stdout.flush();
    }
  }
}
''');

      final binDir = Directory(p.join(tempDir.path, 'bin_stop_all'))..createSync();
      if (Platform.isWindows) {
        File(p.join(binDir.path, 'codex.cmd')).writeAsStringSync(
          '@echo off\r\n"$dartExe" "${parentScript.path}" %*\r\n',
        );
      } else {
        final sh = File(p.join(binDir.path, 'codex'))
          ..writeAsStringSync(
            '#!/bin/sh\nexec "$dartExe" "${parentScript.path}" "\$@"\n',
          );
        Process.runSync('chmod', ['+x', sh.path]);
      }

      ClaudeEnvironment.use({
        'PATH': '${binDir.path}${Platform.isWindows ? ';' : ':'}${p.dirname(dartExe)}',
        'APPDATA': binDir.path,
        'LOCALAPPDATA': binDir.path,
        'USERPROFILE': tempDir.path,
        'HOME': tempDir.path,
        'SystemRoot': ?Platform.environment['SystemRoot'],
      });

      final transport = ProcessCodexTransport(cwd: tempDir.path);
      final received = <Map<String, Object?>>[];
      final sub = transport.messages.listen(received.add);
      addTearDown(() async {
        await sub.cancel();
        transport.close();
        await transport.exited;
        if (gcPidFile.existsSync()) {
          final gcPid = int.tryParse(gcPidFile.readAsStringSync().trim());
          if (gcPid != null) {
            if (Platform.isWindows) {
              Process.runSync('taskkill', ['/PID', '$gcPid', '/T', '/F']);
            } else {
              Process.killPid(gcPid, ProcessSignal.sigkill);
            }
          }
        }
      });

      transport.write({'id': 1, 'method': 'initialize', 'params': const {}});
      await _waitUntil(() => received.any((m) => m['id'] == 1));
      await _waitUntil(() => gcPidFile.existsSync());
      final gcPid = int.parse(gcPidFile.readAsStringSync().trim());
      expect(_isPidAliveCodex(gcPid), isTrue);

      var exitedDone = false;
      unawaited(transport.exited.then((_) => exitedDone = true));

      await ProcessCodexTransport.stopAll();
      await pumpEventQueue();
      expect(exitedDone, isTrue);
      expect(
        _isPidAliveCodex(gcPid),
        isFalse,
        reason: 'Grandchild PID $gcPid must be dead by the time stopAll() returns',
      );
    });

    test('unawaited stopProcess() stays observable to stopAll() and mid-spawn stopProcess() awaits _inFlightSpawns', () async {
      final dartExe = _resolveDartExecutableForCodexTest();
      final sleeper = File(p.join(tempDir.path, 'sleeper_stop_race.dart'))
        ..writeAsStringSync('''
import 'dart:io';
Future<void> main() async {
  await Future<void>.delayed(const Duration(seconds: 30));
}
''');
      final gcPidFile = File(p.join(tempDir.path, 'stop_race_gc.pid'));
      final parentScript = File(p.join(tempDir.path, 'fake_codex_stop_race.dart'))
        ..writeAsStringSync('''
import 'dart:convert';
import 'dart:io';
Future<void> main() async {
  final proc = await Process.start(${jsonEncode(dartExe)}, [${jsonEncode(sleeper.path)}]);
  File(${jsonEncode(gcPidFile.path)}).writeAsStringSync('\${proc.pid}', flush: true);
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    final msg = jsonDecode(line) as Map;
    if (msg['method'] == 'initialize') {
      stdout.writeln(jsonEncode({'id': msg['id'], 'result': <String, Object?>{}}));
      await stdout.flush();
    }
  }
}
''');

      final binDir = Directory(p.join(tempDir.path, 'bin_stop_race'))..createSync();
      if (Platform.isWindows) {
        File(p.join(binDir.path, 'codex.cmd')).writeAsStringSync(
          '@echo off\r\n"$dartExe" "${parentScript.path}" %*\r\n',
        );
      } else {
        final sh = File(p.join(binDir.path, 'codex'))
          ..writeAsStringSync(
            '#!/bin/sh\nexec "$dartExe" "${parentScript.path}" "\$@"\n',
          );
        Process.runSync('chmod', ['+x', sh.path]);
      }

      ClaudeEnvironment.use({
        'PATH': '${binDir.path}${Platform.isWindows ? ';' : ':'}${p.dirname(dartExe)}',
        'APPDATA': binDir.path,
        'LOCALAPPDATA': binDir.path,
        'USERPROFILE': tempDir.path,
        'HOME': tempDir.path,
        'SystemRoot': ?Platform.environment['SystemRoot'],
      });

      final transport = ProcessCodexTransport(cwd: tempDir.path);
      final received = <Map<String, Object?>>[];
      final sub = transport.messages.listen(received.add);
      addTearDown(() async {
        await sub.cancel();
        transport.close();
        await transport.exited;
        if (gcPidFile.existsSync()) {
          final gcPid = int.tryParse(gcPidFile.readAsStringSync().trim());
          if (gcPid != null) {
            if (Platform.isWindows) {
              Process.runSync('taskkill', ['/PID', '$gcPid', '/T', '/F']);
            } else {
              Process.killPid(gcPid, ProcessSignal.sigkill);
            }
          }
        }
      });

      transport.write({'id': 1, 'method': 'initialize', 'params': const {}});
      await _waitUntil(() => received.any((m) => m['id'] == 1));
      await _waitUntil(() => gcPidFile.existsSync());
      final gcPid = int.parse(gcPidFile.readAsStringSync().trim());
      expect(_isPidAliveCodex(gcPid), isTrue);

      unawaited(transport.stopProcess());
      await ProcessCodexTransport.stopAll();
      expect(
        _isPidAliveCodex(gcPid),
        isFalse,
        reason: 'Grandchild PID $gcPid must already be dead when stopAll() returns after unawaited stopProcess()',
      );

      // Part 2: mid-spawn stopProcess() must await in-flight _spawn() before completing.
      final midSpawnPidFile = File(p.join(tempDir.path, 'mid_spawn_stop.pid'));
      final midParent = File(p.join(tempDir.path, 'fake_codex_mid_stop.dart'))
        ..writeAsStringSync('''
import 'dart:io';
Future<void> main() async {
  File(${jsonEncode(midSpawnPidFile.path)}).writeAsStringSync('\$pid', flush: true);
  await stdin.transform(const SystemEncoding().decoder).drain<void>();
}
''');
      final midBin = Directory(p.join(tempDir.path, 'bin_mid_stop'))..createSync();
      if (Platform.isWindows) {
        File(p.join(midBin.path, 'codex.cmd')).writeAsStringSync(
          '@echo off\r\n"$dartExe" "${midParent.path}" %*\r\n',
        );
      } else {
        final sh = File(p.join(midBin.path, 'codex'))
          ..writeAsStringSync(
            '#!/bin/sh\nexec "$dartExe" "${midParent.path}" "\$@"\n',
          );
        Process.runSync('chmod', ['+x', sh.path]);
      }

      final midEnv = {
        'PATH': '${midBin.path}${Platform.isWindows ? ';' : ':'}${p.dirname(dartExe)}',
        'APPDATA': midBin.path,
        'LOCALAPPDATA': midBin.path,
        'USERPROFILE': tempDir.path,
        'HOME': tempDir.path,
        'SystemRoot': ?Platform.environment['SystemRoot'],
      };
      ClaudeEnvironment.use(midEnv);

      final savedProxy = NetworkProxy.instance;
      final spawnEntered = Completer<void>();
      final spawnGate = Completer<void>();
      NetworkProxy.instance = NetworkProxy(
        system: () async {
          if (!spawnEntered.isCompleted) spawnEntered.complete();
          await spawnGate.future;
          return const ProxyRoute.direct();
        },
        environment: () async => midEnv,
      );
      addTearDown(() {
        if (!spawnGate.isCompleted) spawnGate.complete();
        NetworkProxy.instance = savedProxy;
      });

      final midTransport = ProcessCodexTransport(cwd: tempDir.path);
      addTearDown(() async {
        midTransport.close();
        await midTransport.exited;
      });

      midTransport.write({'id': 2, 'method': 'initialize', 'params': const {}});
      await spawnEntered.future;

      var stopDone = false;
      final stopFut = midTransport.stopProcess().then((_) => stopDone = true);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(
        stopDone,
        isFalse,
        reason: 'stopProcess() must not return while _spawn() is still in flight',
      );

      spawnGate.complete();
      await stopFut.timeout(const Duration(seconds: 3));
      expect(stopDone, isTrue);
      expect(midSpawnPidFile.existsSync(), isFalse);
    });
  });
}

String _resolveDartExecutableForCodexTest() {
  final exeName = Platform.isWindows ? 'dart.exe' : 'dart';
  final direct = p.join(p.dirname(Platform.resolvedExecutable), exeName);
  if (File(direct).existsSync()) return direct;
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

bool _isPidAliveCodex(int pid) {
  if (Platform.isWindows) {
    final res = Process.runSync('tasklist', ['/FI', 'PID eq $pid', '/NH']);
    return RegExp('(?:^|\\s)$pid(?:\\s|\$)', multiLine: true)
        .hasMatch('${res.stdout}');
  }
  return Process.killPid(pid, ProcessSignal.sigcont);
}

Future<String?> _findWindowsNode() async {
  try {
    final res = await Process.run('where', ['node.exe']);
    if (res.exitCode != 0) return null;
    for (final line in '${res.stdout}'.split(RegExp(r'\r?\n'))) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty && File(trimmed).existsSync()) return trimmed;
    }
  } on Object {
    // Ignore.
  }
  return null;
}

Future<void> _waitUntil(bool Function() cond) async {
  for (var i = 0; i < 200 && !cond(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  expect(cond(), isTrue);
}
