import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baocode/acp/acp_agent_service.dart';
import 'package:baocode/acp/ayte_ipc_server.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/tasks/task_diff_parser.dart';
import 'package:baocode/tasks/task_queue_service.dart';
import 'package:baocode/tasks/task_queue_view.dart';
import 'package:baocode/workbench.dart' show applyTaskHandoffToSession;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Future<Directory> _initTempGitRepo(String prefix) async {
  final dir = await Directory.systemTemp.createTemp(prefix);
  Future<void> git(List<String> args) async {
    final res = await Process.run('git', args, workingDirectory: dir.path);
    if (res.exitCode != 0) {
      throw StateError('git ${args.join(' ')} failed: ${res.stderr}');
    }
  }

  await git(['init']);
  await git(['config', 'user.name', 'Ayte Test']);
  await git(['config', 'user.email', 'test@ayte.local']);
  await File(p.join(dir.path, 'app.dart')).writeAsString(
    'void main() {\n  print("hello");\n}\n',
  );
  await git(['add', '-A']);
  await git(['commit', '-m', 'Initial commit']);
  return dir;
}

String _resolveDartExe() {
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

void main() {
  group('TaskDiffParser', () {
    test('parses modified, added, deleted, renamed, and binary diffs with line numbers', () {
      const diff = '''
diff --git a/lib/foo.dart b/lib/foo.dart
index 1111111..2222222 100644
--- a/lib/foo.dart
+++ b/lib/foo.dart
@@ -1,3 +1,4 @@
 void main() {
-  print("old");
+  print("new");
+  print("extra");
 }
diff --git a/lib/brand_new.dart b/lib/brand_new.dart
new file mode 100644
index 0000000..3333333
--- /dev/null
+++ b/lib/brand_new.dart
@@ -0,0 +1,2 @@
+final x = 1;
+final y = 2;
diff --git a/lib/old.dart b/lib/old.dart
deleted file mode 100644
index 4444444..0000000
--- a/lib/old.dart
+++ /dev/null
@@ -1,1 +0,0 @@
-final gone = true;
diff --git a/assets/logo.png b/assets/logo.png
Binary files a/assets/logo.png and b/assets/logo.png differ
''';
      final files = TaskDiffParser.parse(diff);
      expect(files.length, 4);

      expect(files[0].path, 'lib/foo.dart');
      expect(files[0].status, TaskDiffFileStatus.modified);
      expect(files[0].added, 2);
      expect(files[0].removed, 1);
      final splitRows = files[0].hunks.first.toSplitRows();
      expect(splitRows.length, 4);
      expect(splitRows[1].left?.kind, TaskDiffLineKind.removed);
      expect(splitRows[1].right?.kind, TaskDiffLineKind.added);
      expect(splitRows[2].left, isNull);
      expect(splitRows[2].right?.text, '  print("extra");');

      expect(files[1].path, 'lib/brand_new.dart');
      expect(files[1].status, TaskDiffFileStatus.added);
      expect(files[1].added, 2);

      expect(files[2].path, 'lib/old.dart');
      expect(files[2].status, TaskDiffFileStatus.deleted);
      expect(files[2].removed, 1);

      expect(files[3].isBinary, isTrue);

      final summary = TaskDiffParser.summarize(files);
      expect(summary.files, 4);
      expect(summary.added, 4);
      expect(summary.removed, 2);
    });
  });

  group('AcpAgentService & AyteIpcServer cross-platform fixes', () {
    test('buildEnrichedPath honors USERPROFILE and APPDATA on Windows', () {
      final env = {
        'USERPROFILE': r'C:\Users\Demo',
        'APPDATA': r'C:\Users\Demo\AppData\Roaming',
        'LOCALAPPDATA': r'C:\Users\Demo\AppData\Local',
        'Path': r'C:\Windows\System32',
      };
      final path = AcpAgentService.buildEnrichedPath(env);
      if (Platform.isWindows) {
        expect(path, contains(r'C:\Users\Demo\AppData\Roaming\npm'));
        expect(path, contains(r'C:\Users\Demo\.gemini\bin'));
        expect(path, contains(r'C:\Windows\System32'));
      } else {
        expect(path, isNotEmpty);
      }
    });

    test('unwrapWindowsNpmShim extracts node.exe and target js script', () async {
      final dir = await Directory.systemTemp.createTemp('ayte-shim-test');
      addTearDown(() => dir.delete(recursive: true));

      final nodeExe = File(p.join(dir.path, 'node.exe'))..writeAsStringSync('');
      final jsFile = File(
        p.join(dir.path, 'node_modules', '@openai', 'codex', 'bin', 'codex.js'),
      )..createSync(recursive: true)
        ..writeAsStringSync('console.log("ok");');
      final cmdFile = File(p.join(dir.path, 'codex.cmd'))
        ..writeAsStringSync(
          '@ECHO off\r\n'
          '"%_prog%"  "%dp0%\\node_modules\\@openai\\codex\\bin\\codex.js" %*\r\n',
        );

      final unwrapped = AcpAgentService.unwrapWindowsNpmShim(
        cmdFile.path,
        {'PATH': dir.path},
        forceWindows: true,
      );
      expect(unwrapped, isNotNull);
      expect(p.equals(unwrapped!.executable, nodeExe.path), isTrue);
      expect(p.equals(unwrapped.prefixArgs.single, jsFile.path), isTrue);
    });

    test('resolveBinary prefers .exe over .cmd on Windows', () async {
      if (!Platform.isWindows) return;
      final dir = await Directory.systemTemp.createTemp('ayte-bin-test');
      addTearDown(() => dir.delete(recursive: true));
      final cmdFile = File(p.join(dir.path, 'mykernel.cmd'))
        ..writeAsStringSync('@echo hi\r\n');
      final exeFile = File(p.join(dir.path, 'mykernel.exe'))
        ..writeAsStringSync('');

      final hit = await AcpAgentService.instance.resolveBinary(
        'mykernel',
        environment: {'PATH': dir.path},
      );
      expect(hit, exeFile.path);

      exeFile.deleteSync();
      final fallback = await AcpAgentService.instance.resolveBinary(
        'mykernel',
        environment: {'PATH': dir.path},
      );
      expect(fallback, cmdFile.path);
    });

    test('buildCliArgs omits default placeholder models cleanly', () {
      expect(
        AcpAgentService.buildCliArgs(
          agentId: 'codebuddy',
          prompt: 'hi',
          model: 'default-model',
        ),
        isNot(contains('--model')),
      );
      expect(
        AcpAgentService.buildCliArgs(
          agentId: 'codex',
          prompt: 'hi',
          model: 'default',
          effort: 'high',
        ),
        isNot(contains('-m')),
      );
    });

    test('AyteIpcServer installs & uninstalls cross-platform CLI and avoids KeyError', () async {
      final homeDir = await Directory.systemTemp.createTemp('ayte-ipc-home');
      addTearDown(() async {
        AyteIpcServer.instance.homeOverride = null;
        await homeDir.delete(recursive: true);
      });

      final ipc = AyteIpcServer.instance..homeOverride = homeDir.path;
      expect(ipc.ipcInfoPath, p.join(homeDir.path, '.ayte', 'ipc.json'));

      final ok = await ipc.installCli();
      expect(ok, isTrue);
      expect(ipc.isCliInstalled, isTrue);
      expect(File(ipc.cliInstallPath).existsSync(), isTrue);
      expect(File(ipc.cliScriptPath).existsSync(), isTrue);

      final script = File(ipc.cliScriptPath).readAsStringSync();
      // Must NOT use bare a['protocol'] which raised KeyError on `ayte-cli agents`.
      expect(script, isNot(contains("a['protocol']")));
      expect(script, contains('a.get("protocol"'));

      await ipc.uninstallCli();
      expect(ipc.isCliInstalled, isFalse);
      expect(File(ipc.cliInstallPath).existsSync(), isFalse);
      expect(File(ipc.cliScriptPath).existsSync(), isFalse);
    });
  });

  group('TaskQueueService full lifecycle & bug fixes', () {
    late Directory storageDir;
    late Directory repoDir;

    setUp(() async {
      storageDir = await Directory.systemTemp.createTemp('ayte-tq-store');
      repoDir = await _initTempGitRepo('ayte-tq-repo');
      TaskQueueService.instance
        ..resetForTest()
        ..storagePathOverride = p.join(storageDir.path, 'tasks.json');
      AcpAgentService.instance.headlessRunnerOverride = null;
    });

    tearDown(() async {
      AcpAgentService.instance.headlessRunnerOverride = null;
      await TaskQueueService.instance.flushForTest();
      TaskQueueService.instance
        ..resetForTest()
        ..storagePathOverride = null;
      if (storageDir.existsSync()) await storageDir.delete(recursive: true);
      if (repoDir.existsSync()) await repoDir.delete(recursive: true);
    });

    test('Bug #1: rapid same-ms batch enqueue creates strictly unique IDs', () async {
      final svc = TaskQueueService.instance;
      final ids = <String>{};
      for (var i = 0; i < 20; i++) {
        final t = svc.enqueue(
          title: 'BUG-$i',
          prompt: 'Fix BUG-$i',
          repoPath: repoDir.path,
          model: 'gemini-4-neon',
          effort: 'high',
        );
        expect(ids.add(t.id), isTrue, reason: 'Duplicate ID generated: ${t.id}');
        expect(t.model, 'gemini-4-neon');
        expect(t.effort, 'high');
      }
      expect(svc.tasks.length, 20);
      await svc.flushForTest();
    });

    test('Bug #2 & #3 & #4: captures tracked+untracked+committed diff, retries cleanly, externalizes blobs, and merges safely', () async {
      final svc = TaskQueueService.instance;
      var attempt = 0;
      String? seenModel;
      String? seenEffort;

      AcpAgentService.instance.headlessRunnerOverride = ({
        required String agentId,
        required String prompt,
        required String cwd,
        String? model,
        String? effort,
        void Function(String chunk)? onChunk,
        void Function(Process proc)? onProcessStarted,
        Duration timeout = const Duration(minutes: 15),
      }) async {
        attempt++;
        seenModel = model;
        seenEffort = effort;
        onChunk?.call('Attempt #$attempt running in $cwd\n');
        if (attempt == 1) {
          // Simulate failure after creating partial file.
          await File(p.join(cwd, 'partial.txt')).writeAsString('wip\n');
          return (ok: false, output: '', error: 'Simulated transient error');
        }
        // Attempt 2: modify tracked file AND create brand-new untracked file AND commit another file.
        await File(p.join(cwd, 'committed.dart')).writeAsString('const c = 1;\n');
        await Process.run('git', ['add', 'committed.dart'], workingDirectory: cwd);
        await Process.run(
          'git',
          ['commit', '-m', 'Agent intermediate commit'],
          workingDirectory: cwd,
        );
        await File(p.join(cwd, 'app.dart')).writeAsString(
          'void main() {\n  print("updated by task");\n}\n',
        );
        await File(p.join(cwd, 'new_feature.dart')).writeAsString(
          'String greet() => "hi";\n',
        );
        onChunk?.call('Finished editing files.\n');
        return (ok: true, output: 'Done', error: null);
      };

      final task = svc.enqueue(
        title: 'Add greet feature',
        prompt: 'Update app.dart and add new_feature.dart',
        repoPath: repoDir.path,
        agentId: 'codex',
        model: 'gpt-5.4',
        effort: 'xhigh',
      );

      // First run fails cleanly and leaves worktree behind.
      await svc.runTask(task.id);
      expect(task.status, WorktreeTaskStatus.failed);
      expect(seenModel, 'gpt-5.4');
      expect(seenEffort, 'xhigh');
      expect(task.worktreePath, isNotEmpty);

      // Bug #2 check: retrying the failed task cleans old worktree/branch and succeeds!
      await svc.runTask(task.id);
      expect(task.status, WorktreeTaskStatus.review);
      expect(task.error, isNull);

      // Bug #3 check: diff captures modified tracked file, committed file, AND new untracked file!
      expect(task.diffText, contains('app.dart'));
      expect(task.diffText, contains('new_feature.dart'));
      expect(task.diffText, contains('committed.dart'));
      expect(task.filesChanged, 3);
      expect(task.linesAdded, greaterThanOrEqualTo(3));

      // Bug #4 check: log & diff externalized to tasks/<id>.log & .diff, NOT bloated in tasks.json!
      final indexJson = File(p.join(storageDir.path, 'tasks.json')).readAsStringSync();
      final decoded = jsonDecode(indexJson) as Map<String, Object?>;
      final savedTaskMap = (decoded['tasks'] as List).first as Map;
      expect(savedTaskMap.containsKey('log'), isFalse);
      expect(savedTaskMap.containsKey('diffText'), isFalse);
      expect(savedTaskMap['filesChanged'], 3);
      expect(File(svc.logFilePathFor(task.id)).existsSync(), isTrue);
      expect(File(svc.diffFilePathFor(task.id)).existsSync(), isTrue);

      // Handoff to chat points directly at the live worktree and codex kernel.
      final handoff = await svc.buildChatHandoff(task.id, isZh: true);
      expect(handoff, isNotNull);
      expect(handoff!.directory, task.worktreePath);
      expect(handoff.kernelId, 'codex');
      expect(handoff.draftPrompt, contains('Add greet feature'));

      // Approve & merge commits uncommitted changes, merges into main, cleans up worktree.
      final wtPath = task.worktreePath;
      final mergeRes = await svc.approveAndMerge(task.id);
      expect(mergeRes.ok, isTrue, reason: mergeRes.message);
      expect(task.status, WorktreeTaskStatus.merged);
      expect(Directory(wtPath).existsSync(), isFalse);
      expect(
        File(p.join(repoDir.path, 'new_feature.dart')).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(repoDir.path, 'app.dart')).readAsStringSync(),
        contains('updated by task'),
      );

      // Reload from disk and verify lazy hydration of external log/diff!
      svc.resetForTest();
      await svc.load();
      final reloaded = svc.byId(task.id)!;
      expect(reloaded.log, isEmpty);
      expect(reloaded.diffText, isEmpty);
      expect(reloaded.filesChanged, 3);
      await svc.ensureTaskDetailsLoaded(task.id);
      expect(reloaded.log, contains('Finished editing files.'));
      expect(reloaded.diffText, contains('new_feature.dart'));

      // clearFinishedTasks removes merged tasks and their external blobs.
      final cleared = await svc.clearFinishedTasks();
      expect(cleared, 1);
      expect(svc.tasks, isEmpty);
      expect(File(svc.logFilePathFor(task.id)).existsSync(), isFalse);
      expect(File(svc.diffFilePathFor(task.id)).existsSync(), isFalse);
    });

    test('approveAndMerge safely aborts conflicted merge and preserves task worktree', () async {
      final svc = TaskQueueService.instance;
      AcpAgentService.instance.headlessRunnerOverride = ({
        required String agentId,
        required String prompt,
        required String cwd,
        String? model,
        String? effort,
        void Function(String chunk)? onChunk,
        void Function(Process proc)? onProcessStarted,
        Duration timeout = const Duration(minutes: 15),
      }) async {
        await File(p.join(cwd, 'app.dart')).writeAsString(
          'void main() {\n  print("from worktree branch");\n}\n',
        );
        return (ok: true, output: 'ok', error: null);
      };

      final task = svc.enqueue(
        title: 'Conflicting edit',
        prompt: 'Edit app.dart',
        repoPath: repoDir.path,
      );
      await svc.runTask(task.id);
      expect(task.status, WorktreeTaskStatus.review);

      // Create a conflicting commit on main while task waits in review.
      await File(p.join(repoDir.path, 'app.dart')).writeAsString(
        'void main() {\n  print("from main branch");\n}\n',
      );
      await Process.run('git', ['add', 'app.dart'], workingDirectory: repoDir.path);
      await Process.run(
        'git',
        ['commit', '-m', 'Main conflicting change'],
        workingDirectory: repoDir.path,
      );

      final mergeRes = await svc.approveAndMerge(task.id);
      expect(mergeRes.ok, isFalse);
      expect(task.status, WorktreeTaskStatus.review);
      // Task worktree is preserved for user inspection/handoff.
      expect(Directory(task.worktreePath).existsSync(), isTrue);
      // Main repo is NOT left stuck in MERGE_HEAD state.
      final mergeHead = await Process.run(
        'git',
        ['rev-parse', '-q', '--verify', 'MERGE_HEAD'],
        workingDirectory: repoDir.path,
      );
      expect(mergeHead.exitCode, isNot(0));
      expect(
        File(p.join(repoDir.path, 'app.dart')).readAsStringSync(),
        contains('from main branch'),
      );

      await svc.discardTask(task.id);
    });

    test('migrates legacy inline log/diff tasks.json to external blobs and cancels cleanly with autoDispatch', () async {
      final svc = TaskQueueService.instance;
      // Write a legacy tasks.json containing inline log & diffText.
      final legacyFile = File(p.join(storageDir.path, 'tasks.json'));
      await legacyFile.writeAsString(
        jsonEncode({
          'maxConcurrency': 1,
          'autoDispatch': false,
          'tasks': [
            {
              'id': 'legacy-1',
              'title': 'Legacy task',
              'prompt': 'Old prompt',
              'repoPath': repoDir.path,
              'status': 'review',
              'log': 'legacy log output',
              'diffText':
                  'diff --git a/a.dart b/a.dart\n--- a/a.dart\n+++ b/a.dart\n@@ -1 +1 @@\n-old\n+new\n',
            },
          ],
        }),
      );

      svc.resetForTest();
      await svc.load();
      await svc.flushForTest();

      final migrated = svc.byId('legacy-1')!;
      expect(migrated.filesChanged, 1);
      expect(migrated.linesAdded, 1);
      expect(migrated.linesRemoved, 1);
      expect(File(svc.logFilePathFor('legacy-1')).readAsStringSync(), 'legacy log output');
      expect(File(svc.diffFilePathFor('legacy-1')).readAsStringSync(), contains('+new'));
      final rewritten = jsonDecode(legacyFile.readAsStringSync()) as Map;
      final savedFirst = (rewritten['tasks'] as List).first as Map;
      expect(savedFirst.containsKey('log'), isFalse);
      expect(savedFirst.containsKey('diffText'), isFalse);

      // Verify cancelTask frees concurrency slot so autoDispatch starts next queued task.
      final blockFirst = Completer<void>();
      final secondRan = Completer<void>();
      AcpAgentService.instance.headlessRunnerOverride = ({
        required String agentId,
        required String prompt,
        required String cwd,
        String? model,
        String? effort,
        void Function(String chunk)? onChunk,
        void Function(Process proc)? onProcessStarted,
        Duration timeout = const Duration(minutes: 15),
      }) async {
        if (prompt == 'first') {
          await blockFirst.future;
          return (ok: true, output: '', error: null);
        }
        secondRan.complete();
        return (ok: true, output: 'second done', error: null);
      };

      svc.setMaxConcurrency(1);
      final t1 = svc.enqueue(
        title: 'First',
        prompt: 'first',
        repoPath: repoDir.path,
        useWorktree: false,
      );
      final t2 = svc.enqueue(
        title: 'Second',
        prompt: 'second',
        repoPath: repoDir.path,
        useWorktree: false,
      );
      svc.setAutoDispatch(true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(t1.status, WorktreeTaskStatus.running);
      expect(t2.status, WorktreeTaskStatus.queued);

      await svc.cancelTask(t1.id);
      blockFirst.complete();
      await secondRan.future.timeout(const Duration(seconds: 5));
      await svc.runTask(t2.id);
      expect(t1.status, WorktreeTaskStatus.cancelled);
      expect(t2.status, WorktreeTaskStatus.review);
    });

    test('discardTask during async launch setup kills late-starting process and cleans worktree', () async {
      final svc = TaskQueueService.instance;
      final dartExe = _resolveDartExe();
      final script = File(p.join(storageDir.path, 'sleep_task.dart'))
        ..writeAsStringSync('''
import 'dart:io';
Future<void> main() async {
  await Future<void>.delayed(const Duration(seconds: 15));
}
''');
      final entering = Completer<void>();
      final proceed = Completer<void>();
      Process? startedProc;
      addTearDown(() {
        if (startedProc != null) {
          if (Platform.isWindows) {
            Process.runSync('taskkill', ['/PID', '${startedProc!.pid}', '/T', '/F']);
          } else {
            startedProc!.kill(ProcessSignal.sigkill);
          }
        }
      });

      AcpAgentService.instance.headlessRunnerOverride = ({
        required String agentId,
        required String prompt,
        required String cwd,
        String? model,
        String? effort,
        void Function(String chunk)? onChunk,
        void Function(Process proc)? onProcessStarted,
        Duration timeout = const Duration(minutes: 15),
      }) async {
        if (!entering.isCompleted) entering.complete();
        await proceed.future;
        final proc = await Process.start(dartExe, [script.path]);
        startedProc = proc;
        onProcessStarted?.call(proc);
        final code = await proc.exitCode;
        return (ok: code == 0, output: '', error: 'exit $code');
      };

      final task = svc.enqueue(
        title: 'Discard race',
        prompt: 'sleep',
        repoPath: repoDir.path,
        useWorktree: true,
      );
      final runFuture = svc.runTask(task.id);
      await entering.future;

      final discardFuture = svc.discardTask(task.id);
      proceed.complete();

      await Future.wait([
        runFuture.timeout(const Duration(seconds: 4)),
        discardFuture.timeout(const Duration(seconds: 4)),
      ]);
      expect(svc.byId(task.id), isNull);
      expect(Directory(task.worktreePath).existsSync(), isFalse);
    });
  });

  group('TaskQueueView widget', () {
    testWidgets('shows clear feedback banner when enqueueing with no repo selected', (tester) async {
      addTearDown(() {
        TaskQueueService.instance
          ..resetForTest()
          ..storagePathOverride = null;
      });

      TaskQueueService.instance
        ..resetForTest()
        ..storagePathOverride = null;

      await tester.binding.setSurfaceSize(const Size(1000, 760));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('zh'),
          supportedLocales: [Locale('zh'), Locale('en')],
          localizationsDelegates: [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Scaffold(body: TaskQueueView()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('加入队列'));
      await tester.pumpAndSettle();
      expect(find.textContaining('请先选择目标代码仓库目录'), findsOneWidget);
    });

    testWidgets('supports repo selection, model picker, diff review dialog, and chat handoff', (tester) async {
      final repoDir = Directory.systemTemp.createTempSync('ayte-tqv-test');
      addTearDown(() {
        TaskQueueService.instance
          ..resetForTest()
          ..storagePathOverride = null;
        if (repoDir.existsSync()) repoDir.deleteSync(recursive: true);
      });

      final svc = TaskQueueService.instance
        ..resetForTest()
        ..storagePathOverride = null;

      final task = svc.enqueue(
        title: 'Refactor parser',
        prompt: 'Clean up parser',
        repoPath: repoDir.path,
        agentId: 'codex',
        model: 'gpt-5.4',
      );
      task.status = WorktreeTaskStatus.review;
      task.branchName = 'ayte/task-${task.id}';
      task.diffText = '''
diff --git a/lib/parser.dart b/lib/parser.dart
index 1111111..2222222 100644
--- a/lib/parser.dart
+++ b/lib/parser.dart
@@ -1,2 +1,2 @@
-final v = 1;
+final v = 2;
''';
      task.filesChanged = 1;
      task.linesAdded = 1;
      task.linesRemoved = 1;
      task.hasDiff = true;

      WorktreeTask? handedOff;

      await tester.binding.setSurfaceSize(const Size(1280, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: const [Locale('zh'), Locale('en')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Scaffold(
            body: TaskQueueView(
              defaultRepoPath: repoDir.path,
              availableRepos: [repoDir.path],
              onHandOffTask: (t) async => handedOff = t,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Refactor parser'), findsOneWidget);
      expect(find.text('1 文件'), findsOneWidget);
      expect(find.text('审阅 Diff'), findsOneWidget);
      expect(find.text('接管到对话'), findsOneWidget);

      // Open full Diff Review dialog and toggle Split view.
      await tester.tap(find.text('审阅 Diff'));
      await tester.pumpAndSettle();
      expect(find.text('lib/parser.dart'), findsOneWidget);
      expect(find.text('统一视图'), findsOneWidget);

      await tester.tap(find.text('统一视图'));
      await tester.pumpAndSettle();
      expect(find.text('并排对比'), findsOneWidget);

      // Trigger handoff directly from the Diff Review dialog.
      await tester.tap(find.text('接管到对话').last);
      await tester.pumpAndSettle();
      expect(handedOff?.id, task.id);
    });

    test('approveAndMerge rejects dirty main repo without touching worktree or main repo edits', () async {
      final storageDir = await Directory.systemTemp.createTemp('ayte-tq-dirty-store');
      final repoDir = await _initTempGitRepo('ayte-tq-dirty-repo');
      addTearDown(() async {
        AcpAgentService.instance.headlessRunnerOverride = null;
        await TaskQueueService.instance.flushForTest();
        TaskQueueService.instance
          ..resetForTest()
          ..storagePathOverride = null;
        if (storageDir.existsSync()) await storageDir.delete(recursive: true);
        if (repoDir.existsSync()) await repoDir.delete(recursive: true);
      });
      final svc = TaskQueueService.instance
        ..resetForTest()
        ..storagePathOverride = p.join(storageDir.path, 'tasks.json');
      AcpAgentService.instance.headlessRunnerOverride = ({
        required String agentId,
        required String prompt,
        required String cwd,
        String? model,
        String? effort,
        void Function(String chunk)? onChunk,
        void Function(Process proc)? onProcessStarted,
        Duration timeout = const Duration(minutes: 15),
      }) async {
        await File(p.join(cwd, 'wt_change.dart')).writeAsString('final x = 1;\n');
        return (ok: true, output: 'ok', error: null);
      };

      final task = svc.enqueue(
        title: 'Dirty guard check',
        prompt: 'Add wt_change.dart',
        repoPath: repoDir.path,
      );
      await svc.runTask(task.id);
      expect(task.status, WorktreeTaskStatus.review);

      final mainFile = File(p.join(repoDir.path, 'app.dart'));
      const dirtyText = 'void main() {\n  print("dirty local");\n}\n';
      await mainFile.writeAsString(dirtyText);

      final res = await svc.approveAndMerge(task.id);
      expect(res.ok, isFalse);
      expect(res.message, contains('app.dart'));
      expect(task.status, WorktreeTaskStatus.review);
      expect(Directory(task.worktreePath).existsSync(), isTrue);
      expect(mainFile.readAsStringSync(), dirtyText);
    });

    test('_captureDiffForTask uses cache dir git-index instead of systemTemp and cleans up lock/index', () async {
      final storageDir = await Directory.systemTemp.createTemp('ayte-tq-cache-store');
      final repoDir = await _initTempGitRepo('ayte-tq-cache-repo');
      addTearDown(() async {
        AcpAgentService.instance.headlessRunnerOverride = null;
        await TaskQueueService.instance.flushForTest();
        TaskQueueService.instance
          ..resetForTest()
          ..storagePathOverride = null;
        if (storageDir.existsSync()) await storageDir.delete(recursive: true);
        if (repoDir.existsSync()) await repoDir.delete(recursive: true);
      });
      final svc = TaskQueueService.instance
        ..resetForTest()
        ..storagePathOverride = p.join(storageDir.path, 'tasks.json');
      final beforeTemp = Directory.systemTemp
          .listSync()
          .whereType<File>()
          .map((f) => p.basename(f.path))
          .where((n) => n.startsWith('ayte-task-idx-'))
          .toSet();

      AcpAgentService.instance.headlessRunnerOverride = ({
        required String agentId,
        required String prompt,
        required String cwd,
        String? model,
        String? effort,
        void Function(String chunk)? onChunk,
        void Function(Process proc)? onProcessStarted,
        Duration timeout = const Duration(minutes: 15),
      }) async {
        await File(p.join(cwd, 'cache_check.dart')).writeAsString('final c = 1;\n');
        return (ok: true, output: 'ok', error: null);
      };

      final task = svc.enqueue(
        title: 'Cache dir index check',
        prompt: 'Create cache_check.dart',
        repoPath: repoDir.path,
      );
      await svc.runTask(task.id);
      expect(task.status, WorktreeTaskStatus.review);
      expect(task.hasDiff, isTrue);

      final afterTemp = Directory.systemTemp
          .listSync()
          .whereType<File>()
          .map((f) => p.basename(f.path))
          .where((n) => n.startsWith('ayte-task-idx-'))
          .toSet();
      expect(afterTemp.difference(beforeTemp), isEmpty);

      final cacheIndexDir = Directory(p.join(storageDir.path, 'cache', 'git-index'));
      expect(cacheIndexDir.existsSync(), isTrue);
      expect(cacheIndexDir.listSync(), isEmpty);
    });

    test('clearFinishedTasks preserves failed by default and clears when includeFailed is true', () async {
      final storageDir = await Directory.systemTemp.createTemp('ayte-tq-clear-store');
      final repoDir = await _initTempGitRepo('ayte-tq-clear-repo');
      addTearDown(() async {
        await TaskQueueService.instance.flushForTest();
        TaskQueueService.instance
          ..resetForTest()
          ..storagePathOverride = null;
        if (storageDir.existsSync()) await storageDir.delete(recursive: true);
        if (repoDir.existsSync()) await repoDir.delete(recursive: true);
      });
      final svc = TaskQueueService.instance
        ..resetForTest()
        ..storagePathOverride = p.join(storageDir.path, 'tasks.json');
      final failedTask = svc.enqueue(
        title: 'Failed task',
        prompt: 'Fail',
        repoPath: repoDir.path,
      )..status = WorktreeTaskStatus.failed;
      final mergedTask = svc.enqueue(
        title: 'Merged task',
        prompt: 'Merged',
        repoPath: repoDir.path,
      )..status = WorktreeTaskStatus.merged;

      final defaultCleared = await svc.clearFinishedTasks();
      expect(defaultCleared, 1);
      expect(svc.byId(mergedTask.id), isNull);
      expect(svc.byId(failedTask.id), isNotNull);

      final failedCleared = await svc.clearFinishedTasks(includeFailed: true);
      expect(failedCleared, 1);
      expect(svc.byId(failedTask.id), isNull);
    });

    test('buildChatHandoff and applyTaskHandoffToSession apply kernel, @provider/id model, effort, and draft', () async {
      final storageDir = await Directory.systemTemp.createTemp('ayte-tq-handoff-store');
      final repoDir = await _initTempGitRepo('ayte-tq-handoff-repo');
      addTearDown(() async {
        await TaskQueueService.instance.flushForTest();
        TaskQueueService.instance
          ..resetForTest()
          ..storagePathOverride = null;
        if (storageDir.existsSync()) await storageDir.delete(recursive: true);
        if (repoDir.existsSync()) await repoDir.delete(recursive: true);
      });
      final svc = TaskQueueService.instance
        ..resetForTest()
        ..storagePathOverride = p.join(storageDir.path, 'tasks.json');
      final task = svc.enqueue(
        title: 'Model handoff',
        prompt: 'Fix model wiring',
        repoPath: repoDir.path,
        agentId: 'agy',
        model: 'gemini-4-neon',
        effort: 'high',
      );
      final handoff = await svc.buildChatHandoff(task.id, isZh: false);
      expect(handoff, isNotNull);
      expect(handoff!.kernelId, 'antigravity-cli');
      expect(handoff.model, 'gemini-4-neon');
      expect(handoff.effort, 'high');

      late KernelDescriptor agyDesc;
      late KernelDescriptor codexDesc;
      agyDesc = KernelDescriptor(
        id: 'antigravity-cli',
        label: 'Antigravity',
        icon: Icons.rocket_launch_rounded,
        description: '',
        create: (_) => _FakeHandoffKernel(
          agyDesc,
          models: const [
            KernelOption('@antigravity-cli/default', 'Default', Icons.rocket_launch_rounded, ''),
            KernelOption('@antigravity-cli/gemini-4-neon', 'Gemini 4 Neon', Icons.rocket_launch_rounded, ''),
          ],
          efforts: const [
            KernelOption('low', 'Low', Icons.tune, ''),
            KernelOption('high', 'High', Icons.tune, ''),
          ],
        ),
      );
      codexDesc = KernelDescriptor(
        id: 'codex',
        label: 'Codex',
        icon: Icons.bolt_rounded,
        description: '',
        create: (_) => _FakeHandoffKernel(
          codexDesc,
          models: const [
            KernelOption('gpt-5.4', 'GPT-5.4', Icons.bolt_rounded, ''),
          ],
          efforts: const [
            KernelOption('medium', 'Medium', Icons.tune, ''),
            KernelOption('xhigh', 'XHigh', Icons.tune, ''),
          ],
        ),
      );

      final session = ChatSession(
        kernel: codexDesc,
        kernels: [codexDesc, agyDesc],
        historyCount: 0,
      );
      addTearDown(session.dispose);

      applyTaskHandoffToSession(
        session,
        kernelId: handoff.kernelId,
        model: handoff.model,
        effort: handoff.effort,
        draftPrompt: handoff.draftPrompt,
      );

      expect(session.kernel.id, 'antigravity-cli');
      expect(session.models?.selected.id, '@antigravity-cli/gemini-4-neon');
      final effortChoice = session
          .modelSettings('@antigravity-cli/gemini-4-neon')
          .where((s) => s.kind == KernelChoiceKind.effort)
          .single;
      expect(effortChoice.selected?.id, 'high');
      expect(session.draft.pendingMessage?.text, handoff.draftPrompt);

      // Verify label match, effort label match, and kernelLocked preservation.
      final lockedSession = ChatSession(
        kernel: agyDesc,
        kernels: [codexDesc, agyDesc],
        historyCount: 1,
      );
      addTearDown(lockedSession.dispose);
      expect(lockedSession.kernelLocked, isTrue);
      applyTaskHandoffToSession(
        lockedSession,
        kernelId: 'codex',
        model: 'Default',
        effort: 'Low',
        draftPrompt: 'Locked draft',
      );
      expect(lockedSession.kernel.id, 'antigravity-cli');
      expect(lockedSession.models?.selected.id, '@antigravity-cli/default');
      final lockedEffort = lockedSession
          .modelSettings('@antigravity-cli/default')
          .where((s) => s.kind == KernelChoiceKind.effort)
          .single;
      expect(lockedEffort.selected?.id, 'low');
      expect(lockedSession.draft.pendingMessage?.text, 'Locked draft');
    });

    test('enqueue and buildChatHandoff normalize CLI agent aliases to canonical kernel IDs', () async {
      final storageDir = await Directory.systemTemp.createTemp('ayte-tq-alias-store');
      final repoDir = await _initTempGitRepo('ayte-tq-alias-repo');
      addTearDown(() async {
        await TaskQueueService.instance.flushForTest();
        TaskQueueService.instance
          ..resetForTest()
          ..storagePathOverride = null;
        if (storageDir.existsSync()) await storageDir.delete(recursive: true);
        if (repoDir.existsSync()) await repoDir.delete(recursive: true);
      });
      final svc = TaskQueueService.instance
        ..resetForTest()
        ..storagePathOverride = p.join(storageDir.path, 'tasks.json');

      for (final (alias, canonicalAgent, expectedKernelId) in const [
        ('claude-code', 'claude', 'claude-code'),
        ('antigravity-cli', 'agy', 'antigravity-cli'),
        ('cbc', 'codebuddy', 'codebuddy-cli'),
      ]) {
        final t = svc.enqueue(
          title: 'Alias $alias',
          prompt: 'Do $alias',
          repoPath: repoDir.path,
          agentId: alias,
        );
        expect(t.agentId, canonicalAgent);
        final handoff = await svc.buildChatHandoff(t.id, isZh: false);
        expect(handoff, isNotNull);
        expect(handoff!.kernelId, expectedKernelId);
      }
    });

    testWidgets('TaskQueueView confirms and clears failed tasks with worktree diffs', (tester) async {
      final storageDir = Directory.systemTemp.createTempSync('ayte-tqv-fail-store');
      final repoDir = Directory.systemTemp.createTempSync('ayte-tqv-fail-repo');
      addTearDown(() {
        TaskQueueService.instance
          ..resetForTest()
          ..storagePathOverride = null;
        if (storageDir.existsSync()) storageDir.deleteSync(recursive: true);
        if (repoDir.existsSync()) repoDir.deleteSync(recursive: true);
      });
      final svc = TaskQueueService.instance
        ..resetForTest()
        ..storagePathOverride = null;
      final failed = svc.enqueue(
        title: 'Broken task',
        prompt: 'Do broken stuff',
        repoPath: repoDir.path,
      );
      failed
        ..status = WorktreeTaskStatus.failed
        ..worktreePath = p.join(storageDir.path, 'fake-wt')
        ..branchName = 'ayte/task-${failed.id}'
        ..hasDiff = true
        ..filesChanged = 1;

      await tester.binding.setSurfaceSize(const Size(1280, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: const [Locale('en'), Locale('zh')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Scaffold(
            body: TaskQueueView(
              defaultRepoPath: repoDir.path,
              availableRepos: [repoDir.path],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Clear Failed (1)'), findsOneWidget);
      await tester.tap(find.text('Clear Failed (1)'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('uncommitted/unmerged changes'), findsOneWidget);

      await tester.tap(find.text('Clear Failed'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      for (var i = 0; i < 40 && svc.tasks.isNotEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(svc.tasks, isEmpty);
    });
  });
}

class _FakeHandoffKernel implements AgentKernel, SelectsModel, SelectsEffort {
  _FakeHandoffKernel(
    this.descriptor, {
    required this.models,
    required this.efforts,
  });

  @override
  final KernelDescriptor descriptor;
  final List<KernelOption> models;
  final List<KernelOption> efforts;
  final _events = StreamController<KernelEvent>.broadcast();

  @override
  Stream<KernelEvent> get events => _events.stream;

  @override
  KernelHealth get health => const KernelHealth(KernelHealthStatus.ready);

  @override
  String? get sessionId => null;

  @override
  late final KernelChoiceSource model = _ChoiceSource(models);

  @override
  late final ModelSetting effort = _EffortSetting(efforts);

  @override
  void send(KernelTurn turn) {}

  @override
  void answer(String requestId, InteractionAnswer answer) {}

  @override
  void cancel() {}

  @override
  void restart() {}

  @override
  void prepare() {}

  @override
  void release() {}

  @override
  void dispose() => unawaited(_events.close());

  @override
  Future<void> get stopped async {}
}

class _ChoiceSource implements KernelChoiceSource {
  _ChoiceSource(this.options) : _selected = options.first.id;

  @override
  final List<KernelOption> options;
  String _selected;

  @override
  String get selected => _selected;

  @override
  void select(String id) => _selected = id;
}

class _EffortSetting implements ModelSetting {
  _EffortSetting(this.options);

  final List<KernelOption> options;
  String? _selected;

  @override
  String? get selected => _selected;

  @override
  bool get toggle => false;

  @override
  List<KernelOption> optionsFor(String model) => options;

  @override
  String? selectedFor(String model) => _selected;

  @override
  void select(String model, String id) => _selected = id;
}
