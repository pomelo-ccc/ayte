import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baocode/acp/acp_agent_service.dart';
import 'package:baocode/acp/ayte_ipc_server.dart';
import 'package:baocode/automations/automation_service.dart';
import 'package:baocode/chat/chat_models.dart' show UserMessageItem;
import 'package:baocode/chat/chat_session.dart' show ComposerMessage;
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_environment.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/settings/user_settings.dart';
import 'package:baocode/tasks/task_queue_service.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
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

Future<({int statusCode, Map<String, Object?> json})> _callIpc({
  required int port,
  required String path,
  String method = 'GET',
  String? token,
  Map<String, Object?>? body,
}) async {
  final client = HttpClient();
  try {
    final req = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:$port$path'),
    );
    if (token != null) {
      req.headers.set('authorization', 'Bearer $token');
    }
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close();
    final raw = await utf8.decoder.bind(res).join();
    final decoded = jsonDecode(raw) as Map<String, Object?>;
    return (statusCode: res.statusCode, json: decoded);
  } finally {
    client.close(force: true);
  }
}

void main() {
  late Directory tempDir;
  late Directory homeDir;
  late Directory repoDir;
  HttpOverrides? prevHttpOverrides;

  setUp(() async {
    prevHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    tempDir = await Directory.systemTemp.createTemp('ayte-ipc-acp-');
    homeDir = Directory(p.join(tempDir.path, 'home'))..createSync();
    repoDir = Directory(p.join(tempDir.path, 'repo'))..createSync();
    await AyteIpcServer.instance.stop();
    AyteIpcServer.instance
      ..workspace = null
      ..homeOverride = homeDir.path;
    TaskQueueService.instance
      ..resetForTest()
      ..storagePathOverride = p.join(tempDir.path, 'tasks.json');
    AutomationService.instance.storagePathOverride = p.join(
      tempDir.path,
      'automations.json',
    );
    for (final r in [...AutomationService.instance.rules]) {
      AutomationService.instance.deleteRule(r.id);
    }
    AcpAgentService.instance.headlessRunnerOverride = null;
  });

  tearDown(() async {
    HttpOverrides.global = prevHttpOverrides;
    AcpAgentService.instance.headlessRunnerOverride = null;
    ClaudeCodeKernel.modelCache = null;
    await AyteIpcServer.instance.stop();
    await AyteIpcServer.instance.uninstallCli();
    AyteIpcServer.instance
      ..workspace = null
      ..homeOverride = null;
    for (final r in [...AutomationService.instance.rules]) {
      AutomationService.instance.deleteRule(r.id);
    }
    await AutomationService.instance.flushForTest();
    AutomationService.instance.storagePathOverride = null;
    await TaskQueueService.instance.flushForTest();
    TaskQueueService.instance
      ..resetForTest()
      ..storagePathOverride = null;
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('AyteIpcServer endpoints & ayte-cli script', () {
    test('binds in FLUTTER_TEST with homeOverride, validates POST /tasks, and exposes /tasks/:id/* & /sessions*', () async {
      final ipc = AyteIpcServer.instance;
      await ipc.start();
      expect(ipc.running, isTrue);
      final info = jsonDecode(File(ipc.ipcInfoPath).readAsStringSync()) as Map;
      final port = info['port'] as int;
      final token = info['token'] as String;

      // 401 without token
      final unauth = await _callIpc(port: port, path: '/health');
      expect(unauth.statusCode, 401);

      // POST /tasks validation
      final emptyPrompt = await _callIpc(
        port: port,
        path: '/tasks',
        method: 'POST',
        token: token,
        body: {'prompt': '   ', 'cwd': repoDir.path},
      );
      expect(emptyPrompt.statusCode, 400);

      final emptyCwd = await _callIpc(
        port: port,
        path: '/tasks',
        method: 'POST',
        token: token,
        body: {'prompt': 'Fix', 'cwd': ''},
      );
      expect(emptyCwd.statusCode, 400);

      final missingCwd = await _callIpc(
        port: port,
        path: '/tasks',
        method: 'POST',
        token: token,
        body: {'prompt': 'Fix', 'cwd': p.join(tempDir.path, 'missing')},
      );
      expect(missingCwd.statusCode, 400);

      // Valid POST /tasks
      final created = await _callIpc(
        port: port,
        path: '/tasks',
        method: 'POST',
        token: token,
        body: {
          'title': 'IPC Task 1',
          'prompt': 'Check repo',
          'cwd': repoDir.path,
          'agent': 'codex',
          'useWorktree': false,
        },
      );
      expect(created.statusCode, 200);
      final taskId = (created.json['task'] as Map)['id'] as String;

      // GET /tasks/:id
      final got = await _callIpc(
        port: port,
        path: '/tasks/$taskId',
        token: token,
      );
      expect(got.statusCode, 200);
      expect(got.json['ok'], isTrue);
      expect(got.json.containsKey('log'), isTrue);
      expect(got.json.containsKey('diffText'), isTrue);

      final missingTask = await _callIpc(
        port: port,
        path: '/tasks/no-such-task',
        token: token,
      );
      expect(missingTask.statusCode, 404);

      // POST /tasks/:id/merge (in-place task with empty worktreePath merges cleanly)
      final merged = await _callIpc(
        port: port,
        path: '/tasks/$taskId/merge',
        method: 'POST',
        token: token,
        body: const {},
      );
      expect(merged.statusCode, 200);
      expect(merged.json['ok'], isTrue);

      // POST /tasks/:id/cancel & discard
      final t2 = TaskQueueService.instance.enqueue(
        title: 'T2',
        prompt: 'P2',
        repoPath: repoDir.path,
      );
      final cancelled = await _callIpc(
        port: port,
        path: '/tasks/${t2.id}/cancel',
        method: 'POST',
        token: token,
        body: const {},
      );
      expect(cancelled.statusCode, 200);

      final discarded = await _callIpc(
        port: port,
        path: '/tasks/${t2.id}/discard',
        method: 'POST',
        token: token,
        body: const {},
      );
      expect(discarded.statusCode, 200);
      expect(TaskQueueService.instance.byId(t2.id), isNull);

      // /sessions when workspace == null
      final unattachedList = await _callIpc(
        port: port,
        path: '/sessions',
        token: token,
      );
      expect(unattachedList.statusCode, 200);
      expect(unattachedList.json['attached'], isFalse);
      expect(unattachedList.json['sessions'], isEmpty);

      final unattachedPost = await _callIpc(
        port: port,
        path: '/sessions',
        method: 'POST',
        token: token,
        body: {'prompt': 'Hi', 'cwd': repoDir.path},
      );
      expect(unattachedPost.statusCode, 503);

      // Attach Workspace and test /sessions endpoints
      late KernelDescriptor fakeKernel;
      final sentPrompts = <String>[];
      fakeKernel = KernelDescriptor(
        id: 'codex',
        label: 'Codex',
        icon: Icons.bolt_rounded,
        description: '',
        create: (_) => _MockIpcKernel(fakeKernel, onSend: sentPrompts.add),
      );
      final ws = Workspace(
        kernels: [fakeKernel],
        projects: [Project('repo', repoDir.path)],
      );
      addTearDown(ws.dispose);
      ipc.workspace = ws;

      final createSession = await _callIpc(
        port: port,
        path: '/sessions',
        method: 'POST',
        token: token,
        body: {'prompt': 'Hello from IPC', 'cwd': repoDir.path, 'kernel': 'codex'},
      );
      expect(createSession.statusCode, 200);
      final sid = (createSession.json['session'] as Map)['id'] as String;
      expect(sentPrompts, ['Hello from IPC']);

      final listSessions = await _callIpc(
        port: port,
        path: '/sessions',
        token: token,
      );
      expect(listSessions.statusCode, 200);
      expect(listSessions.json['attached'], isTrue);
      expect(listSessions.json['sessions'], isNotEmpty);

      final readSession = await _callIpc(
        port: port,
        path: '/sessions/$sid',
        token: token,
      );
      expect(readSession.statusCode, 200);
      expect(readSession.json['items'], isA<List>());

      final sendSession = await _callIpc(
        port: port,
        path: '/sessions/$sid/send',
        method: 'POST',
        token: token,
        body: {'text': 'Follow up from IPC'},
      );
      expect(sendSession.statusCode, 200);
      expect(sentPrompts, ['Hello from IPC', 'Follow up from IPC']);

      final badSendType = await _callIpc(
        port: port,
        path: '/sessions/$sid/send',
        method: 'POST',
        token: token,
        body: {'text': 123},
      );
      expect(badSendType.statusCode, 400);

      // ayte-cli script checks
      expect(await ipc.installCli(), isTrue);
      final script = File(ipc.cliScriptPath).readAsStringSync();
      expect(script, contains('a.get("protocol", "native")'));
      expect(script, contains('sessions'));
      expect(script, contains('automations'));
      expect(script, contains('"discard"'));
      expect(script, contains('urllib.parse.quote'));
      expect(script, contains('argparse.SUPPRESS'));

      // Execute ayte-cli.py via Python (when installed) to verify pre- & post-subcommand flags and ast.parse.
      String? pyExe;
      List<String> pyPrefix = const [];
      for (final candidate in [
        ('python', const <String>[]),
        if (Platform.isWindows) ('py', const ['-3']),
        if (!Platform.isWindows) ('python3', const <String>[]),
      ]) {
        try {
          final probe = await Process.run(candidate.$1, [
            ...candidate.$2,
            '--version',
          ]);
          if (probe.exitCode == 0) {
            pyExe = candidate.$1;
            pyPrefix = candidate.$2;
            break;
          }
        } on Object {
          // Try next interpreter candidate.
        }
      }
      if (pyExe != null) {
        final cliEnv = <String, String>{
          ...Platform.environment,
          'HOME': homeDir.path,
          'USERPROFILE': homeDir.path,
        };
        Future<ProcessResult> runCli(List<String> cliArgs) => Process.run(
          pyExe!,
          [...pyPrefix, ipc.cliScriptPath, ...cliArgs],
          environment: cliEnv,
        );

        // 1. ast.parse syntax check
        final astRes = await Process.run(pyExe, [
          ...pyPrefix,
          '-c',
          'import ast, pathlib; ast.parse(pathlib.Path(r"${ipc.cliScriptPath}").read_text("utf-8"))',
        ]);
        expect(astRes.exitCode, 0, reason: '${astRes.stderr}');

        // 2. --help on root and subcommands
        expect((await runCli(['--help'])).exitCode, 0);
        expect((await runCli(['task', '--help'])).exitCode, 0);
        expect((await runCli(['sessions', '--help'])).exitCode, 0);

        // 3. Post-subcommand --json on status & sessions list
        final statusRes = await runCli(['status', '--json']);
        expect(statusRes.exitCode, 0, reason: '${statusRes.stderr}');
        expect((jsonDecode('${statusRes.stdout}') as Map)['ok'], isTrue);

        final sessListRes = await runCli(['sessions', 'list', '--json']);
        expect(sessListRes.exitCode, 0, reason: '${sessListRes.stderr}');
        expect((jsonDecode('${sessListRes.stdout}') as Map)['ok'], isTrue);

        // 4. Post-subcommand global flags on task add
        final postAdd = await runCli([
          'task',
          'add',
          '--prompt',
          'Post-flag CLI task',
          '--cwd',
          repoDir.path,
          '-a',
          'codex',
          '-m',
          'gpt-5.4',
          '--effort',
          'high',
          '--in-place',
          '--json',
        ]);
        expect(postAdd.exitCode, 0, reason: '${postAdd.stderr}');
        final postTask = (jsonDecode('${postAdd.stdout}') as Map)['task'] as Map;
        expect(postTask['prompt'], 'Post-flag CLI task');
        expect(postTask['repoPath'], repoDir.path);
        expect(postTask['agentId'], 'codex');
        expect(postTask['model'], 'gpt-5.4');
        expect(postTask['effort'], 'high');

        // 5. Pre-subcommand global flags on task add
        final preAdd = await runCli([
          '--cwd',
          repoDir.path,
          '-a',
          'claude',
          '-m',
          'opus',
          '--effort',
          'medium',
          '--json',
          'task',
          'add',
          '--prompt',
          'Pre-flag CLI task',
          '--in-place',
        ]);
        expect(preAdd.exitCode, 0, reason: '${preAdd.stderr}');
        final preTask = (jsonDecode('${preAdd.stdout}') as Map)['task'] as Map;
        expect(preTask['prompt'], 'Pre-flag CLI task');
        expect(preTask['repoPath'], repoDir.path);
        expect(preTask['agentId'], 'claude');
        expect(preTask['model'], 'opus');
        expect(preTask['effort'], 'medium');

        // 6. Post-subcommand flags on sessions new
        final postSessNew = await runCli([
          'sessions',
          'new',
          '-p',
          'Session via post flags',
          '--cwd',
          repoDir.path,
          '-a',
          'codex',
          '--json',
        ]);
        expect(postSessNew.exitCode, 0, reason: '${postSessNew.stderr}');
        expect(sentPrompts.last, 'Session via post flags');
      }
    });

    test('POST /sessions normalizes CLI agent aliases, rejects unknown kernels with 400, and handles kernelLocked threads', () async {
      final ipc = AyteIpcServer.instance;
      await ipc.start();
      expect(ipc.running, isTrue);
      final info = jsonDecode(File(ipc.ipcInfoPath).readAsStringSync()) as Map;
      final port = info['port'] as int;
      final token = info['token'] as String;

      final dispatched = <(String kernelId, String prompt)>[];
      late KernelDescriptor codexK;
      late KernelDescriptor agyK;
      late KernelDescriptor claudeK;
      late KernelDescriptor cbK;
      codexK = KernelDescriptor(
        id: 'codex',
        label: 'Codex',
        icon: Icons.bolt_rounded,
        description: '',
        create: (_) => _MockIpcKernel(
          codexK,
          onSend: (text) => dispatched.add(('codex', text)),
        ),
      );
      agyK = KernelDescriptor(
        id: 'antigravity-cli',
        label: 'Antigravity',
        icon: Icons.rocket_launch_rounded,
        description: '',
        create: (_) => _MockIpcKernel(
          agyK,
          onSend: (text) => dispatched.add(('antigravity-cli', text)),
        ),
      );
      claudeK = KernelDescriptor(
        id: 'claude-code',
        label: 'Claude Code',
        icon: Icons.terminal_rounded,
        description: '',
        create: (_) => _MockIpcKernel(
          claudeK,
          onSend: (text) => dispatched.add(('claude-code', text)),
        ),
      );
      cbK = KernelDescriptor(
        id: 'codebuddy-cli',
        label: 'CodeBuddy',
        icon: Icons.auto_awesome_rounded,
        description: '',
        create: (_) => _MockIpcKernel(
          cbK,
          onSend: (text) => dispatched.add(('codebuddy-cli', text)),
        ),
      );

      final ws = Workspace(
        kernels: [codexK, agyK, claudeK, cbK],
        projects: [Project('repo', repoDir.path)],
      );
      addTearDown(ws.dispose);
      ipc.workspace = ws;

      for (final (alias, expectedKernel) in const [
        ('agy', 'antigravity-cli'),
        ('antigravity', 'antigravity-cli'),
        ('claude', 'claude-code'),
        ('codebuddy', 'codebuddy-cli'),
        ('cbc', 'codebuddy-cli'),
        ('codex', 'codex'),
      ]) {
        final beforeLen = dispatched.length;
        final res = await _callIpc(
          port: port,
          path: '/sessions',
          method: 'POST',
          token: token,
          body: {
            'prompt': 'Run on $alias',
            'cwd': repoDir.path,
            'kernel': alias,
          },
        );
        expect(res.statusCode, 200, reason: 'alias=$alias body=${res.json}');
        expect((res.json['session'] as Map)['kernel'], expectedKernel);
        expect(dispatched.length, beforeLen + 1);
        expect(dispatched.last, (expectedKernel, 'Run on $alias'));
      }

      // Unknown kernel must return HTTP 400 and never fall back to codex.
      final beforeUnknown = dispatched.length;
      final badKernel = await _callIpc(
        port: port,
        path: '/sessions',
        method: 'POST',
        token: token,
        body: {
          'prompt': 'Should not run',
          'cwd': repoDir.path,
          'kernel': 'nonexistent',
        },
      );
      expect(badKernel.statusCode, 400);
      expect('${badKernel.json['error']}', contains('nonexistent'));
      expect(dispatched.length, beforeUnknown);

      // Locked active thread on codex: requesting claude opens a fresh claude-code thread.
      final lockedWs = _LockedOpenFolderWorkspace(
        kernels: [codexK, agyK, claudeK, cbK],
        projects: [Project('repo', repoDir.path)],
      );
      addTearDown(lockedWs.dispose);
      final lockedThread = lockedWs.create(
        project: lockedWs.projects.single,
      );
      lockedThread.session.send(const ComposerMessage(text: 'Seed lock'));
      expect(lockedThread.session.kernelLocked, isTrue);
      expect(lockedThread.kernel.id, 'codex');
      lockedWs.lockedReturn = lockedThread;
      ipc.workspace = lockedWs;

      final switchedRes = await _callIpc(
        port: port,
        path: '/sessions',
        method: 'POST',
        token: token,
        body: {
          'prompt': 'Fresh claude on locked ws',
          'cwd': repoDir.path,
          'kernel': 'claude',
        },
      );
      expect(switchedRes.statusCode, 200, reason: '${switchedRes.json}');
      expect((switchedRes.json['session'] as Map)['kernel'], 'claude-code');
      expect(dispatched.last, ('claude-code', 'Fresh claude on locked ws'));

      // If startAgent also returns a locked mismatched thread, return 409 Conflict.
      lockedWs.forceLockedStartAgent = true;
      final beforeConflict = dispatched.length;
      final conflictRes = await _callIpc(
        port: port,
        path: '/sessions',
        method: 'POST',
        token: token,
        body: {
          'prompt': 'Must 409',
          'cwd': repoDir.path,
          'kernel': 'agy',
        },
      );
      expect(conflictRes.statusCode, 409);
      expect(dispatched.length, beforeConflict);
    });

    test('POST /prompt and POST /tasks normalize CLI aliases, preserve omitted default agy, and reject unknown agents with 400', () async {
      final ipc = AyteIpcServer.instance;
      await ipc.start();
      expect(ipc.running, isTrue);
      final info = jsonDecode(File(ipc.ipcInfoPath).readAsStringSync()) as Map;
      final port = info['port'] as int;
      final token = info['token'] as String;

      final executed = <(String agentId, String prompt)>[];
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
        executed.add((agentId, prompt));
        return (ok: true, output: 'ran:$agentId', error: null);
      };

      // Omitted/blank agent defaults to 'agy'.
      final defaultPrompt = await _callIpc(
        port: port,
        path: '/prompt',
        method: 'POST',
        token: token,
        body: {'prompt': 'Default prompt', 'cwd': repoDir.path},
      );
      expect(defaultPrompt.statusCode, 200);
      expect(defaultPrompt.json['agent'], 'agy');
      expect(executed.last, ('agy', 'Default prompt'));

      // Alias normalization on POST /prompt.
      for (final (alias, canonical) in const [
        ('claude-code', 'claude'),
        ('ANTIGRAVITY-CLI', 'agy'),
        ('codebuddy-cli', 'codebuddy'),
        ('CBC', 'codebuddy'),
        ('Codex', 'codex'),
      ]) {
        final res = await _callIpc(
          port: port,
          path: '/prompt',
          method: 'POST',
          token: token,
          body: {'prompt': 'Prompt $alias', 'cwd': repoDir.path, 'agent': alias},
        );
        expect(res.statusCode, 200, reason: 'alias=$alias body=${res.json}');
        expect(res.json['agent'], canonical);
        expect(executed.last, (canonical, 'Prompt $alias'));
      }

      // Unknown agent on POST /prompt -> 400 without executing prompt.
      final beforeBadPrompt = executed.length;
      final badPrompt = await _callIpc(
        port: port,
        path: '/prompt',
        method: 'POST',
        token: token,
        body: {
          'prompt': 'Must not execute',
          'cwd': repoDir.path,
          'agent': 'nonexistent',
        },
      );
      expect(badPrompt.statusCode, 400);
      expect('${badPrompt.json['error']}', contains('nonexistent'));
      expect(executed.length, beforeBadPrompt);

      // Alias normalization on POST /tasks (both `agent` and `agentId`).
      final claudeTaskRes = await _callIpc(
        port: port,
        path: '/tasks',
        method: 'POST',
        token: token,
        body: {
          'title': 'Alias task',
          'prompt': 'Run claude-code',
          'cwd': repoDir.path,
          'agent': 'claude-code',
        },
      );
      expect(claudeTaskRes.statusCode, 200);
      expect((claudeTaskRes.json['task'] as Map)['agentId'], 'claude');

      final cbcTaskRes = await _callIpc(
        port: port,
        path: '/tasks',
        method: 'POST',
        token: token,
        body: {
          'title': 'Alias agentId task',
          'prompt': 'Run cbc',
          'cwd': repoDir.path,
          'agentId': 'cbc',
        },
      );
      expect(cbcTaskRes.statusCode, 200);
      expect((cbcTaskRes.json['task'] as Map)['agentId'], 'codebuddy');

      // Unknown agent/agentId on POST /tasks -> 400 without enqueuing.
      final countBeforeBadTask = TaskQueueService.instance.tasks.length;
      for (final body in [
        {'prompt': 'Bad agent', 'cwd': repoDir.path, 'agent': 'nonexistent'},
        {'prompt': 'Bad agentId', 'cwd': repoDir.path, 'agentId': 'nonexistent'},
      ]) {
        final badTask = await _callIpc(
          port: port,
          path: '/tasks',
          method: 'POST',
          token: token,
          body: body,
        );
        expect(badTask.statusCode, 400);
        expect('${badTask.json['error']}', contains('nonexistent'));
      }
      expect(TaskQueueService.instance.tasks.length, countBeforeBadTask);
    });
  });

  group('AcpAgentService Codex exec --json & Claude model filtering', () {
    test('buildCliArgs emits exec --json for codex and parses NDJSON events without polluting output', () async {
      final args = AcpAgentService.buildCliArgs(
        agentId: 'codex',
        prompt: 'Analyze repo',
        model: 'gpt-5.4',
        effort: 'xhigh',
      );
      expect(args, [
        'exec',
        '--json',
        '--full-auto',
        '-m',
        'gpt-5.4',
        '-c',
        'model_reasoning_effort=xhigh',
        'Analyze repo',
      ]);

      // Write a tiny Dart script executed via Platform.resolvedExecutable to simulate `codex exec --json`.
      final binDir = Directory(p.join(tempDir.path, 'fake-bin'))..createSync();
      final scriptFile = File(p.join(binDir.path, 'fake_codex.dart'))
        ..writeAsStringSync('''
import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  final mode = Platform.environment['MODE'] ?? 'ok';
  if (mode == 'err') {
    stdout.writeln('{not valid json');
    stdout.writeln(jsonEncode({'type': 'turn.failed', 'error': {'message': 'Quota exceeded'}}));
    exit(1);
  }
  if (mode == 'turn_failed_zero') {
    stdout.writeln(jsonEncode({'type': 'thread.started', 'thread_id': 'th-2'}));
    stdout.writeln(jsonEncode({'type': 'turn.started'}));
    stdout.writeln(jsonEncode({'type': 'turn.failed', 'error': {'message': 'Silent fail'}}));
    exit(0);
  }
  if (mode == 'fatal_error_zero') {
    stdout.writeln(jsonEncode({'type': 'error', 'message': 'Unrecovered fatal error'}));
    exit(0);
  }
  if (mode == 'transient_error_recovered') {
    stdout.writeln(jsonEncode({'type': 'error', 'message': 'Reconnecting 1/3'}));
    stdout.writeln(jsonEncode({
      'type': 'item.completed',
      'item': {'type': 'agent_message', 'text': 'RECOVERED_ANSWER'}
    }));
    stdout.writeln(jsonEncode({'type': 'turn.completed'}));
    exit(0);
  }
  stdout.writeln(jsonEncode({'type': 'thread.started', 'thread_id': 'th-1'}));
  stdout.writeln(jsonEncode({'type': 'turn.started'}));
  stdout.writeln(jsonEncode({
    'type': 'item.completed',
    'item': {'type': 'command_execution', 'command': 'git status', 'exit_code': 0}
  }));
  stdout.writeln(jsonEncode({
    'type': 'item.completed',
    'item': {'type': 'file_change', 'changes': [{'path': 'lib/a.dart'}]}
  }));
  stdout.writeln(jsonEncode({
    'type': 'item.completed',
    'item': {'type': 'mcp_tool_call', 'server': 'baocode', 'tool': 'session_list'}
  }));
  stdout.writeln(jsonEncode({
    'type': 'item.completed',
    'item': {'type': 'agent_message', 'text': 'CLEAN_CODEX_ANSWER'}
  }));
  stdout.writeln(jsonEncode({'type': 'turn.completed'}));
}
''');
      final dartExe = _resolveDartExe();
      if (Platform.isWindows) {
        File(p.join(binDir.path, 'codex.cmd')).writeAsStringSync(
          '@echo off\r\n"$dartExe" "${scriptFile.path}" %*\r\n',
        );
      } else {
        final sh = File(p.join(binDir.path, 'codex'))
          ..writeAsStringSync(
            '#!/bin/sh\nexec "$dartExe" "${scriptFile.path}" "\$@"\n',
          );
        await Process.run('chmod', ['+x', sh.path]);
      }

      // Exercise runHeadlessPrompt end-to-end via isolated ClaudeEnvironment override.
      final fakeHome = Directory(p.join(tempDir.path, 'fake-cli-home'))
        ..createSync();
      final sysRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
      final testPath = Platform.isWindows
          ? '${binDir.path};$sysRoot\\System32;$sysRoot'
          : '${binDir.path}:/usr/bin:/bin';
      final isolatedEnv = <String, String>{
        for (final entry in Platform.environment.entries)
          if (!const {
            'path',
            'appdata',
            'localappdata',
            'userprofile',
            'home',
            'volta_home',
          }.contains(entry.key.toLowerCase()))
            entry.key: entry.value,
        'HOME': fakeHome.path,
        'USERPROFILE': fakeHome.path,
        'APPDATA': p.join(fakeHome.path, 'AppData', 'Roaming'),
        'LOCALAPPDATA': p.join(fakeHome.path, 'AppData', 'Local'),
        'PATH': testPath,
      };
      ClaudeEnvironment.use(isolatedEnv);
      addTearDown(() => ClaudeEnvironment.use(null));

      final chunks = <String>[];
      final okRes = await AcpAgentService.instance.runHeadlessPrompt(
        agentId: 'codex',
        prompt: 'Analyze repo',
        cwd: repoDir.path,
        model: 'gpt-5.4',
        effort: 'xhigh',
        onChunk: chunks.add,
      );
      expect(okRes.ok, isTrue, reason: okRes.error);
      expect(okRes.output.trim(), 'CLEAN_CODEX_ANSWER');
      expect(okRes.output, isNot(contains('git status')));
      expect(chunks.join(), contains('[命令完成] git status'));
      expect(chunks.join(), contains('[文件变更] lib/a.dart'));
      expect(chunks.join(), contains('[MCP] baocode.session_list'));

      ClaudeEnvironment.use({...isolatedEnv, 'MODE': 'err'});
      final errRes = await AcpAgentService.instance.runHeadlessPrompt(
        agentId: 'codex',
        prompt: 'Trigger error',
        cwd: repoDir.path,
      );
      expect(errRes.ok, isFalse);
      expect('${errRes.error}\n${errRes.output}', contains('Quota exceeded'));

      // turn.failed with exit code 0 must still fail and preserve error message.
      ClaudeEnvironment.use({...isolatedEnv, 'MODE': 'turn_failed_zero'});
      final turnFailedZero = await AcpAgentService.instance.runHeadlessPrompt(
        agentId: 'codex',
        prompt: 'Trigger silent fail',
        cwd: repoDir.path,
      );
      expect(turnFailedZero.ok, isFalse);
      expect(turnFailedZero.error, contains('Silent fail'));

      // Unrecovered error with exit code 0 must fail and preserve error message.
      ClaudeEnvironment.use({...isolatedEnv, 'MODE': 'fatal_error_zero'});
      final fatalZero = await AcpAgentService.instance.runHeadlessPrompt(
        agentId: 'codex',
        prompt: 'Trigger unrecovered error',
        cwd: repoDir.path,
      );
      expect(fatalZero.ok, isFalse);
      expect(fatalZero.error, contains('Unrecovered fatal error'));

      // Transient error followed by agent_message + turn.completed succeeds.
      ClaudeEnvironment.use({
        ...isolatedEnv,
        'MODE': 'transient_error_recovered',
      });
      final recovered = await AcpAgentService.instance.runHeadlessPrompt(
        agentId: 'codex',
        prompt: 'Recover cleanly',
        cwd: repoDir.path,
      );
      expect(recovered.ok, isTrue, reason: recovered.error);
      expect(recovered.output.trim(), 'RECOVERED_ANSWER');
      expect(recovered.error, isNull);
    });

    test('modelsForAgent("claude") filters Antigravity & CodeBuddy models and reads supportedEffortLevels', () async {
      final storage = GlobalStorage(p.join(tempDir.path, 'storage.json'));
      addTearDown(storage.dispose);
      await storage.set(ClaudeCodeKernel.modelCacheKey, [
        {
          'value': 'claude-opus-4-6',
          'displayName': 'Claude Opus 4.6',
          'description': 'Flagship',
          'supportsEffort': true,
          'supportedEffortLevels': ['low', 'medium', 'high'],
        },
        {
          'value': 'claude-haiku-4-5',
          'displayName': 'Claude Haiku 4.5',
          'description': 'Fast',
          'supportsEffort': false,
        },
        {
          'value': 'gemini-4-neon',
          'displayName': 'Gemini 4 Neon',
        },
        {
          'value': 'glm-5.3',
          'displayName': 'GLM-5.3',
        },
      ]);
      ClaudeCodeKernel.modelCache = storage;

      final models = AcpAgentService.instance.modelsForAgent('claude');
      expect(models.map((m) => m.id), ['claude-opus-4-6', 'claude-haiku-4-5']);
      expect(models.first.effortLevels, ['low', 'medium', 'high']);
      expect(models.last.effortLevels, isEmpty);

      ClaudeCodeKernel.modelCache = null;
      final fallback = AcpAgentService.instance.modelsForAgent('claude');
      expect(fallback.map((m) => m.id), ['opus', 'sonnet', 'haiku']);
    });

    test('buildEnrichedPath reads Windows env vars case-insensitively', () {
      if (!Platform.isWindows) return;
      final enriched = AcpAgentService.buildEnrichedPath({
        'path': r'C:\CustomOnly',
        'userprofile': r'C:\Users\LowerDemo',
        'appdata': r'C:\Users\LowerDemo\Roaming',
        'localappdata': r'C:\Users\LowerDemo\Local',
        'volta_home': r'C:\LowerVolta',
        'programfiles': r'C:\LowerPF',
      });
      final parts = enriched.split(';');
      expect(parts.first, r'C:\CustomOnly');
      expect(parts, contains(r'C:\Users\LowerDemo\Roaming\npm'));
      expect(parts, contains(r'C:\Users\LowerDemo\Local\Programs\claude'));
      expect(parts, contains(r'C:\LowerVolta\bin'));
      expect(parts, contains(r'C:\LowerPF\nodejs'));
      expect(parts, contains(r'C:\Users\LowerDemo\.gemini\bin'));
    });

    test('normalizeAgentId, byId, modelsForAgent, buildCliArgs, and runHeadlessPrompt normalize aliases and reject unknown agents', () async {
      expect(AcpAgentService.normalizeAgentId('antigravity'), 'agy');
      expect(AcpAgentService.normalizeAgentId('Antigravity-CLI'), 'agy');
      expect(AcpAgentService.normalizeAgentId('claude-code'), 'claude');
      expect(AcpAgentService.normalizeAgentId('codebuddy-cli'), 'codebuddy');
      expect(AcpAgentService.normalizeAgentId('CBC'), 'codebuddy');
      expect(AcpAgentService.normalizeAgentId('Codex'), 'codex');

      expect(AcpAgentService.instance.byId('claude-code')?.id, 'claude');
      expect(AcpAgentService.instance.byId('antigravity-cli')?.id, 'agy');
      expect(AcpAgentService.instance.byId('cbc')?.id, 'codebuddy');
      expect(AcpAgentService.instance.byId('nonexistent'), isNull);
      expect(AcpAgentService.instance.byId('  '), isNull);

      expect(
        AcpAgentService.instance.modelsForAgent('claude-code').map((m) => m.id),
        ['opus', 'sonnet', 'haiku'],
      );
      expect(
        AcpAgentService.buildCliArgs(agentId: 'codex', prompt: 'hi'),
        containsAllInOrder(['exec', '--json']),
      );
      expect(
        AcpAgentService.buildCliArgs(agentId: 'claude-code', prompt: 'hi'),
        contains('--verbose'),
      );

      var runnerCalls = 0;
      String? runnerAgent;
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
        runnerCalls++;
        runnerAgent = agentId;
        return (ok: true, output: 'ok', error: null);
      };

      final aliasRes = await AcpAgentService.instance.runHeadlessPrompt(
        agentId: 'claude-code',
        prompt: 'hello',
        cwd: repoDir.path,
      );
      expect(aliasRes.ok, isTrue);
      expect(runnerCalls, 1);
      expect(runnerAgent, 'claude');

      final unknownRes = await AcpAgentService.instance.runHeadlessPrompt(
        agentId: 'nonexistent',
        prompt: 'hello',
        cwd: repoDir.path,
      );
      expect(unknownRes.ok, isFalse);
      expect(unknownRes.error, contains('Unknown agent: nonexistent'));
      expect(runnerCalls, 1);

      AcpAgentService.instance.headlessRunnerOverride = null;
      final realUnknownRes = await AcpAgentService.instance.runHeadlessPrompt(
        agentId: 'nonexistent',
        prompt: 'hello',
        cwd: repoDir.path,
      );
      expect(realUnknownRes.ok, isFalse);
      expect(realUnknownRes.error, contains('Unknown agent: nonexistent'));
    });
  });
}

class _MockIpcKernel implements AgentKernel {
  _MockIpcKernel(this.descriptor, {required this.onSend});

  @override
  final KernelDescriptor descriptor;
  final void Function(String text) onSend;
  final _events = StreamController<KernelEvent>.broadcast(sync: true);
  int _seq = 0;

  @override
  Stream<KernelEvent> get events => _events.stream;

  @override
  KernelHealth get health => const KernelHealth(KernelHealthStatus.ready);

  @override
  String? get sessionId => null;

  @override
  void send(KernelTurn turn) {
    onSend(turn.text);
    _events.add(TurnStarted(++_seq, turn.id));
    _events.add(ItemUpserted(++_seq, turn.id, UserMessageItem(text: turn.text)));
    _events.add(TurnEnded(++_seq, turn.id));
  }

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

class _LockedOpenFolderWorkspace extends Workspace {
  _LockedOpenFolderWorkspace({super.kernels, super.projects});

  AgentThread? lockedReturn;
  bool forceLockedStartAgent = false;

  @override
  Future<AgentThread> openFolder(String path) async =>
      lockedReturn ?? await super.openFolder(path);

  @override
  AgentThread startAgent(Project project, {KernelDescriptor? kernel}) {
    if (forceLockedStartAgent && lockedReturn != null) {
      return lockedReturn!;
    }
    return super.startAgent(project, kernel: kernel);
  }
}
