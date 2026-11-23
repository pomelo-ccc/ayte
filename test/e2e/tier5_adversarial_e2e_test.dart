import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_link/bao_link.dart';
import 'package:baocode/acp/acp_agent_service.dart';
import 'package:baocode/acp/ayte_ipc_server.dart';
import 'package:baocode/automations/automation_service.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_screen.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/panels/activity_strip.dart';
import 'package:baocode/chat/review/change_review.dart';
import 'package:baocode/chat/review/review_store.dart';
import 'package:baocode/chat/review/review_store_io.dart';
import 'package:baocode/chat/side_panel/file_open.dart';
import 'package:baocode/customize/customization_store.dart';
import 'package:baocode/customize/customizations.dart';
import 'package:baocode/ide/file_service.dart';
import 'package:baocode/ide/ide_agent_edits.dart';
import 'package:baocode/ide/ide_notifications.dart';
import 'package:baocode/ide/ide_workspace.dart';
import 'package:baocode/ide/services/git_changes.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/agent_message_parser.dart';
import 'package:baocode/kernel/antigravity/antigravity_accounts.dart';
import 'package:baocode/kernel/antigravity/antigravity_cli.dart';
import 'package:baocode/kernel/antigravity/antigravity_commands.dart';
import 'package:baocode/kernel/antigravity/antigravity_transport.dart';
import 'package:baocode/kernel/claude_code/claude_cli_transport.dart';
import 'package:baocode/kernel/claude_code/claude_code_transport.dart';
import 'package:baocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:baocode/kernel/claude_code/sdk_mcp_http_bridge.dart';
import 'package:baocode/kernel/codebuddy/codebuddy_account_models.dart';
import 'package:baocode/kernel/codebuddy/codebuddy_accounts.dart';
import 'package:baocode/kernel/codebuddy/codebuddy_cli.dart';
import 'package:baocode/kernel/codebuddy/codebuddy_transport.dart';
import 'package:baocode/kernel/codex/codex_catalog.dart';
import 'package:baocode/kernel/codex/codex_kernel.dart';
import 'package:baocode/kernel/codex/codex_models.dart';
import 'package:baocode/kernel/codex/codex_process_transport.dart';
import 'package:baocode/kernel/codex/codex_transport.dart';
import 'package:baocode/kernel/extension_switches.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_registry.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/link/workspace_bridge.dart';
import 'package:baocode/network/network_proxy_io.dart';
import 'package:baocode/network/proxy_settings.dart';
import 'package:baocode/search/claude_conversation_search.dart';
import 'package:baocode/tasks/task_queue_service.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:baocode/workspace/session_tools.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'helpers/e2e_env.dart';
import 'helpers/e2e_waiters.dart';
import 'helpers/fake_cli_harness.dart';
import 'helpers/mcp_http_probe.dart';

class _Tier5FakeCodexTransport implements CodexTransport {
  final _messages = StreamController<Map<String, Object?>>.broadcast();
  final List<Map<String, Object?>> written = [];

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  @override
  void write(Map<String, Object?> message) {
    written.add(message);
  }

  void push(Map<String, Object?> message) => _messages.add(message);

  @override
  void close() => unawaited(_messages.close());
}

class _Tier5Notifier extends ChangeNotifier {
  void fire() => notifyListeners();
}

class _Tier5StubLinkPeer implements LinkPeer {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Tier5NonQueuingStreamingKernel implements AgentKernel {
  _Tier5NonQueuingStreamingKernel(this.descriptor, {required this.onSend}) {
    scheduleMicrotask(() {
      if (!_events.isClosed) {
        _events.add(const TurnStarted(1, 'busy-initial'));
      }
    });
  }

  @override
  final KernelDescriptor descriptor;
  final void Function(String text) onSend;
  final _events = StreamController<KernelEvent>.broadcast(sync: true);

  @override
  Stream<KernelEvent> get events => _events.stream;

  @override
  KernelHealth get health => KernelHealth.ready;

  @override
  String? get sessionId => null;

  @override
  void send(KernelTurn turn) => onSend(turn.text);

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

const _fakeAgyPermissionsBody = r'''
Future<void> main(List<String> args) async {
  recordEvent({'type': 'launch', 'args': args});
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    stdout.writeln(jsonEncode({
      'event': 'result',
      'result': {'status': 'SUCCESS', 'response': 'ok'},
    }));
    await stdout.flush();
  }
}
''';

const _fakeCodeBuddyRespawnBody = r'''
Future<void> main(List<String> args) async {
  recordEvent({'type': 'launch', 'pid': pid, 'args': args});
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      continue;
    }
    if (decoded is! Map) continue;
    final msg = decoded.cast<String, Object?>();
    if (msg['type'] == 'control_request') {
      final reqId = msg['request_id'] as String? ?? '';
      final req = (msg['request'] as Map?)?.cast<String, Object?>() ?? const {};
      final subtype = req['subtype'] as String? ?? '';
      final payload = switch (subtype) {
        'initialize' => {'commands': const <Object?>[], 'models': const <Object?>[]},
        'get_available_models' => {'models': const <Object?>[]},
        _ => const <String, Object?>{},
      };
      stdout.writeln(jsonEncode({
        'type': 'control_response',
        'response': {
          'subtype': 'success',
          'request_id': reqId,
          'response': payload,
        },
      }));
      await stdout.flush();
    } else if (msg['type'] == 'user') {
      final uuid = msg['uuid'] as String? ?? '';
      final content = ((msg['message'] as Map?)?['content'] ?? '').toString();
      recordEvent({'type': 'user', 'uuid': uuid, 'content': content});
      if (content.contains('SLOW_TURN_1')) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      stdout.writeln(jsonEncode({
        'type': 'assistant',
        'uuid': 'a-$uuid',
        'message': {
          'id': 'm-$uuid',
          'role': 'assistant',
          'model': 'glm-4.7',
          'content': [
            {'type': 'text', 'text': 'ACK:$content'},
          ],
        },
      }));
      stdout.writeln(jsonEncode({
        'type': 'result',
        'subtype': 'success',
        'is_error': false,
        'result': 'ACK:$content',
      }));
      await stdout.flush();
    }
  }
}
''';

class _Tier5PausingCodeBuddyAccounts extends CodeBuddyAccounts {
  _Tier5PausingCodeBuddyAccounts({required super.dataDir});

  String? pauseAccountId;
  Completer<void>? _entered;
  Completer<void>? _release;

  Future<void> waitUntilPaused() => (_entered ??= Completer<void>()).future;

  void resumePause() {
    if (_release != null && !_release!.isCompleted) {
      _release!.complete();
    }
  }

  @override
  Future<CodeBuddyAccount> ensureFreshAccount(CodeBuddyAccount account) async {
    if (account.id == pauseAccountId) {
      pauseAccountId = null;
      _entered ??= Completer<void>();
      if (!_entered!.isCompleted) _entered!.complete();
      _release ??= Completer<void>();
      await _release!.future;
    }
    return account;
  }
}

CodeBuddyAccount _tier5CbAccount(String id, String token) {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return CodeBuddyAccount(
    id: id,
    uid: 'uid-$id',
    nickname: 'User $id',
    region: CodeBuddyRegion.cn,
    endpoint: CodeBuddyRegion.cn.defaultEndpoint,
    auth: CodeBuddyAuthData(
      kind: CodeBuddyAuthKind.apiKey,
      accessToken: token,
      apiKey: token,
    ),
    createdAt: now,
    lastUsed: now,
  );
}

class _Tier5MemReviewStore implements ReviewStore {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _Tier5CaseReview extends ChangeReview {
  _Tier5CaseReview(String root) : super(_Tier5MemReviewStore(), root: root);

  List<FileChange> listed = const [];
  final Map<String, String> bases = {};

  @override
  List<FileChange> get changes => listed;

  @override
  String? baseOf(String path) => bases[path.toLowerCase()];

  @override
  Future<void> before(String path, {String? turn}) async {}

  @override
  Future<void> after(String path, {String? turn}) async {}

  @override
  void report(FileChange change, {FileOriginal? original}) {}

  @override
  Future<void> look() async {}

  @override
  Future<String> Function()? original(String path) =>
      () async => 'orig:$path';
}

const _fakeCodeBuddyMidspawnBody = r'''
Future<void> main(List<String> args) async {
  final apiKey = Platform.environment['CODEBUDDY_API_KEY'] ?? '';
  recordEvent({'type': 'spawn', 'pid': pid, 'apiKey': apiKey});
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      continue;
    }
    if (decoded is! Map) continue;
    final msg = decoded.cast<String, Object?>();
    recordEvent({
      'type': 'stdin',
      'pid': pid,
      'apiKey': apiKey,
      'msgType': msg['type'],
    });
    if (msg['type'] == 'control_request') {
      final reqId = msg['request_id'];
      stdout.writeln(jsonEncode({
        'type': 'control_response',
        'response': {
          'subtype': 'success',
          'request_id': reqId,
          'response': const <String, Object?>{},
        },
      }));
      await stdout.flush();
    } else if (msg['type'] == 'user') {
      stdout.writeln(jsonEncode({
        'type': 'result',
        'subtype': 'success',
        'is_error': false,
        'result': 'ok-$apiKey',
      }));
      await stdout.flush();
    }
  }
}
''';

void main() {
  late E2eSandbox sandbox;

  setUp(() {
    sandbox = E2eSandbox.create(realHttp: true);
    TaskQueueService.instance
      ..resetForTest()
      ..storagePathOverride = p.join(sandbox.dataDir.path, 'tasks.json');
    AutomationService.instance.storagePathOverride = p.join(
      sandbox.dataDir.path,
      'automations.json',
    );
    AcpAgentService.instance.headlessRunnerOverride = null;

    sandbox.onDispose(() async {
      AyteIpcServer.instance.workspace = null;
      AcpAgentService.instance.headlessRunnerOverride = null;
      AutomationService.instance.storagePathOverride = null;
      for (final rule in [...AutomationService.instance.rules]) {
        AutomationService.instance.deleteRule(rule.id);
      }
      await AyteIpcServer.instance.stop();
      await AyteIpcServer.instance.uninstallCli();
      await TaskQueueService.instance.flushForTest();
      TaskQueueService.instance
        ..resetForTest()
        ..storagePathOverride = null;
    });
  });

  group('Tier 5 — Confirmed Defect Regression & Hardening Probes', () {
    test(
      'T5-01 [F10]: AcpAgentService.buildEnrichedPath preserves explicit PATH ahead of extras and resolveBinary respects PATH directory order',
      () async {
        final sep = Platform.isWindows ? ';' : ':';
        final customDir = Directory(p.join(sandbox.rootDir.path, 'custom_bin'))
          ..createSync(recursive: true);
        final npmDir = Directory(p.join(sandbox.appDataDir.path, 'npm'))
          ..createSync(recursive: true);

        final env = <String, String>{
          'PATH': '${customDir.path}$sep${npmDir.path}',
          'APPDATA': sandbox.appDataDir.path,
          'LOCALAPPDATA': sandbox.localAppDataDir.path,
          'HOME': sandbox.homeDir.path,
          'USERPROFILE': sandbox.homeDir.path,
        };
        final merged = AcpAgentService.buildEnrichedPath(env).split(sep);
        expect(
          merged.first,
          customDir.path,
          reason: 'Existing PATH directories must precede appended extras',
        );

        if (Platform.isWindows) {
          final firstCmd = File(p.join(customDir.path, 'tier5tool.cmd'))
            ..writeAsStringSync('@echo off\r\n');
          File(p.join(npmDir.path, 'tier5tool.exe')).writeAsStringSync('');
          final resolved = await AcpAgentService.instance.resolveBinary(
            'tier5tool',
            environment: env,
          );
          expect(
            resolved,
            firstCmd.path,
            reason: 'Earlier PATH dir .cmd must win over later PATH dir .exe',
          );
        }
      },
    );

    test(
      'T5-02 [F10]: AcpAgentService.unwrapWindowsNpmShim unwraps %~dp0 shims without trailing percent',
      () {
        final binDir = Directory(p.join(sandbox.rootDir.path, 'npm_shim'))
          ..createSync(recursive: true);
        final nodeExe = File(p.join(binDir.path, 'node.exe'))
          ..writeAsStringSync('');
        final jsDir = Directory(
          p.join(binDir.path, 'node_modules', '@openai', 'codex', 'bin'),
        )..createSync(recursive: true);
        final jsFile = File(p.join(jsDir.path, 'codex.js'))
          ..writeAsStringSync('console.log("ok");\n');
        final shim = File(p.join(binDir.path, 'codex.cmd'))
          ..writeAsStringSync(
            '@ECHO off\r\n'
            '"%_prog%"  "%~dp0\\node_modules\\@openai\\codex\\bin\\codex.js" %*\r\n',
          );

        final unwrapped = AcpAgentService.unwrapWindowsNpmShim(
          shim.path,
          {'PATH': binDir.path},
          forceWindows: true,
        );
        expect(unwrapped, isNotNull);
        expect(unwrapped!.executable, nodeExe.path);
        expect(unwrapped.prefixArgs, [jsFile.path]);
      },
    );

    test(
      'T5-03 [F4/F9]: IdeAgentEdit.nextPending ignores case difference on Windows and does not return self',
      () async {
        final repoRoot = p.join(sandbox.projectDir.path, 'case_proj');
        Directory(repoRoot).createSync(recursive: true);
        final fileA = File(p.join(repoRoot, 'Alpha.dart'))
          ..writeAsStringSync('before\n');
        final store = BlobReviewStore.open(
          p.join(sandbox.dataDir.path, 'checkpoints_2a'),
        );
        final review = ChangeReview(store, root: repoRoot, paths: p.windows);
        sandbox.onDispose(review.dispose);
        await review.before(fileA.path);
        fileA.writeAsStringSync('after\n');
        await review.after(fileA.path);

        final transport = _Tier5FakeCodexTransport();
        final descriptor = KernelDescriptor(
          id: 'codex',
          label: 'Codex',
          icon: Icons.code,
          description: 'tier5',
          create: (ctx) => CodexKernel(
            KernelRegistry.codex,
            transport,
            context: ctx,
            catalog: null,
            enableSdkMcpBridge: false,
          ),
        );
        final session = ChatSession(
          kernel: descriptor,
          kernelContext: KernelContext(cwd: repoRoot),
          historyCount: 0,
          openReview: (_, {session}) async => review,
        );
        sandbox.onDispose(session.dispose);
        session.attach();
        await waitUntil(() => session.changeReview != null);

        final lowerEdit = IdeAgentEdit.inSession(
          session,
          fileA.path.toLowerCase(),
        );
        expect(lowerEdit, isNotNull);
        expect(lowerEdit!.nextPending(), isNull);
      },
    );

    test(
      'T5-04 [F3/F4]: WorkspaceBridge keep/undo matches relative unnormalized and case-variant paths',
      () async {
        final repoRoot = p.join(sandbox.projectDir.path, 'bridge_proj');
        Directory(repoRoot).createSync(recursive: true);
        final fileA = File(p.join(repoRoot, 'Alpha.dart'))
          ..writeAsStringSync('old\n');

        final transport = _Tier5FakeCodexTransport();
        final descriptor = KernelDescriptor(
          id: 'codex',
          label: 'Codex',
          icon: Icons.code,
          description: 'tier5',
          create: (ctx) => CodexKernel(
            KernelRegistry.codex,
            transport,
            context: ctx,
            catalog: null,
            enableSdkMcpBridge: false,
          ),
        );
        final ws = Workspace(
          kernels: [descriptor],
          projects: [Project('bridge_proj', repoRoot)],
        );
        sandbox.onDispose(ws.dispose);
        final thread = ws.startAgent(ws.projects.first);
        thread.session.send(const ComposerMessage(text: 'edit alpha'));

        await waitUntil(
          () => transport.written.any((m) => m['method'] == 'initialize'),
        );
        final initMsg = transport.written.firstWhere(
          (m) => m['method'] == 'initialize',
        );
        transport.push({'id': initMsg['id'], 'result': <String, Object?>{}});

        await waitUntil(
          () => transport.written.any((m) => m['method'] == 'thread/start'),
        );
        final startThread = transport.written.firstWhere(
          (m) => m['method'] == 'thread/start',
        );
        transport.push({
          'id': startThread['id'],
          'result': {
            'thread': {'id': 'th-bridge-1'},
          },
        });

        await waitUntil(
          () => transport.written.any((m) => m['method'] == 'turn/start'),
        );
        final startTurn = transport.written.firstWhere(
          (m) => m['method'] == 'turn/start',
        );
        transport.push({
          'id': startTurn['id'],
          'result': {
            'turn': {'id': 'srv-1'},
          },
        });
        transport.push({
          'method': 'item/completed',
          'params': {
            'item': {
              'id': 'fc-1',
              'type': 'fileChange',
              'changes': [
                {
                  'path': fileA.path,
                  'diff': '+new\n-old\n',
                  'kind': {'type': 'modify'},
                },
              ],
            },
          },
        });

        await waitUntil(() => thread.session.fileChanges.length == 1);

        final bridge = WorkspaceBridge(
          workspace: ws,
          peer: _Tier5StubLinkPeer(),
          device: () => throw UnimplementedError(),
        );
        await bridge.handle(LinkMethods.keep, {
          'session': WorkspaceBridge.idOf(thread),
          'paths': ['./Alpha.dart'],
        });
        expect(thread.session.fileChanges, isEmpty);
      },
    );

    test(
      'T5-05 [F4/F9]: ChangeReview ignores empty paths and preserves pending legacy case-duplicate entries on resume',
      () async {
        final repoRoot = p.join(sandbox.projectDir.path, 'review_proj');
        Directory(repoRoot).createSync(recursive: true);
        final store = BlobReviewStore.open(
          p.join(sandbox.dataDir.path, 'checkpoints_2de'),
        );
        final review = ChangeReview(store, root: repoRoot, paths: p.windows);
        sandbox.onDispose(review.dispose);

        await review.before('');
        review.report(const FileChange(path: '', added: 2, removed: 1));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(
          review.changes,
          isEmpty,
          reason: 'Empty path must not resolve to project root',
        );

        final blob = await store.store(
          utf8.encode('hello\nworld\n'),
          mode: '100644',
        );
        final legacyJson = jsonEncode({
          'version': 5,
          'entries': {
            '$repoRoot\\Foo.dart': {
              'base': null,
              'after': blob.toJson(),
              'conflict': false,
            },
            '$repoRoot\\foo.dart': {
              'base': null,
              'after': null,
              'conflict': false,
            },
          },
          'unseen': const <Object?>[],
          'turns': const <Object?>[],
        });
        await store.save('legacy-dup-1', legacyJson, blobs: [blob]);
        final resumed = await ChangeReview.resume(
          store,
          'legacy-dup-1',
          root: repoRoot,
          paths: p.windows,
        );
        sandbox.onDispose(resumed.dispose);
        expect(
          resumed.changes,
          isNotEmpty,
          reason:
              'Pending entry must not be wiped out by duplicate case-variant key',
        );
      },
    );

    test(
      'T5-06 [F3]: SessionTools session_changes skips empty file paths without canonicalizing to cwd',
      () async {
        final repoRoot = p.join(sandbox.projectDir.path, 'sess_empty');
        Directory(repoRoot).createSync(recursive: true);
        final transport = _Tier5FakeCodexTransport();
        final descriptor = KernelDescriptor(
          id: 'codex',
          label: 'Codex',
          icon: Icons.code,
          description: 'tier5',
          create: (ctx) => CodexKernel(
            KernelRegistry.codex,
            transport,
            context: ctx,
            catalog: null,
            enableSdkMcpBridge: false,
          ),
        );
        final callerRoot = p.join(sandbox.projectDir.path, 'sess_empty_caller');
        Directory(callerRoot).createSync(recursive: true);
        final ws = Workspace(
          kernels: [descriptor],
          projects: [
            Project('sess_empty', repoRoot),
            Project('sess_empty_caller', callerRoot),
          ],
        );
        sandbox.onDispose(ws.dispose);
        SessionTools.register(ws);
        sandbox.onDispose(SessionTools.unregister);

        final target = ws.startAgent(ws.projects.first);
        final caller = ws.startAgent(ws.projects.last);
        target.session.send(const ComposerMessage(text: 'touch files'));

        await waitUntil(
          () => transport.written.any((m) => m['method'] == 'initialize'),
        );
        transport.push({
          'id': transport.written
              .firstWhere((m) => m['method'] == 'initialize')['id'],
          'result': <String, Object?>{},
        });
        await waitUntil(
          () => transport.written.any((m) => m['method'] == 'thread/start'),
        );
        transport.push({
          'id': transport.written
              .firstWhere((m) => m['method'] == 'thread/start')['id'],
          'result': {
            'thread': {'id': 'th-empty-1'},
          },
        });
        await waitUntil(
          () => transport.written.any((m) => m['method'] == 'turn/start'),
        );
        transport.push({
          'id': transport.written
              .firstWhere((m) => m['method'] == 'turn/start')['id'],
          'result': {
            'turn': {'id': 'srv-1'},
          },
        });
        transport.push({
          'method': 'item/completed',
          'params': {
            'item': {
              'id': 'fc-1',
              'type': 'fileChange',
              'changes': [
                {'path': '', 'diff': '+x\n', 'kind': {'type': 'modify'}},
              ],
            },
          },
        });
        transport.push({
          'method': 'turn/completed',
          'params': {
            'threadId': 'th-empty-1',
            'turn': {'id': 'srv-1', 'status': 'completed'},
          },
        });
        await settleAgentTurn(target);

        final res = await ClaudeSdkTools.handle(
          {
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'tools/call',
            'params': {
              'name': 'session_changes',
              'arguments': {'session': SessionTools.idOf(target)},
            },
          },
          ClaudeSdkCall(
            cwd: repoRoot,
            sessionId: SessionTools.idOf(caller),
          ),
        );
        final text =
            (((res['result'] as Map)['content'] as List).first as Map)['text']
                as String;
        expect(
          text,
          'It edited no files.',
          reason:
              'Empty file paths must be skipped instead of canonicalizing to Directory.current.path',
        );
      },
    );

    test(
      'T5-07 [F8]: CodexKernel reconciles ExtensionSwitches changed while initialize RPC is in flight',
      () async {
        final notifier = _Tier5Notifier();
        var current = ExtensionSwitches.none;
        ExtensionSwitches.current = () => current;
        ExtensionSwitches.changes = notifier;

        final transport = _Tier5FakeCodexTransport();
        final kernel = CodexKernel(
          KernelRegistry.codex,
          transport,
          context: KernelContext(cwd: sandbox.projectDir.path),
          catalog: null,
          loadLocalCatalog: false,
          enableSdkMcpBridge: true,
        );
        sandbox.onDispose(kernel.dispose);

        kernel.prepare();
        await waitUntil(
          () => transport.written.any((m) => m['method'] == 'initialize'),
        );
        final initMsg = transport.written.firstWhere(
          (m) => m['method'] == 'initialize',
        );

        // Toggle server OFF while initialize is still pending.
        current = const ExtensionSwitches(
          disabledServers: {ClaudeSdkTools.server},
        );
        notifier.fire();

        transport.push({'id': initMsg['id'], 'result': <String, Object?>{}});
        await waitUntil(
          () => transport.written.any(
            (m) =>
                m['method'] == 'config/value/write' &&
                (m['params'] as Map)['keyPath'] ==
                    'mcp_servers.${ClaudeSdkTools.server}.enabled' &&
                (m['params'] as Map)['value'] == false,
          ),
          reason:
              'In-flight ExtensionSwitches change during initialize must be reconciled via config/value/write',
        );
      },
    );

    test(
      'T5-08 [F8]: CodexKernel.setMcpServerEnabled quotes dotted MCP server names with _tomlKeySegment',
      () async {
        final transport = _Tier5FakeCodexTransport();
        final kernel = CodexKernel(
          KernelRegistry.codex,
          transport,
          context: KernelContext(cwd: sandbox.projectDir.path),
          catalog: null,
          loadLocalCatalog: false,
          enableSdkMcpBridge: false,
        );
        sandbox.onDispose(kernel.dispose);

        kernel.setMcpServerEnabled('com.example.mcp', false);
        await waitUntil(
          () => transport.written.any((m) => m['method'] == 'initialize'),
        );
        final initMsg = transport.written.firstWhere(
          (m) => m['method'] == 'initialize',
        );
        transport.push({'id': initMsg['id'], 'result': <String, Object?>{}});

        await waitUntil(
          () => transport.written.any(
            (m) => m['method'] == 'config/value/write',
          ),
        );
        final writeReq = transport.written.firstWhere(
          (m) => m['method'] == 'config/value/write',
        );
        expect(
          (writeReq['params'] as Map)['keyPath'],
          'mcp_servers."com.example.mcp".enabled',
        );
      },
    );

    test(
      'T5-09 [F4/F9]: AntigravityTransport apply_flag_settings permissions update respawns idle process with new deny rules',
      () async {
        final fakeAgy = FakeCliExecutable.create(
          sandbox.rootDir,
          name: 'fake_agy_t5_perms',
          dartBody: _fakeAgyPermissionsBody,
        );
        final tr = AntigravityTransport.forTesting(
          executable: fakeAgy.executablePath,
          environment: sandbox.processEnv,
          launch: ClaudeLaunch(cwd: sandbox.projectDir.path),
        );
        sandbox.onDispose(tr.close);

        final results = <Map<String, Object?>>[];
        final sub = tr.messages.listen((m) {
          if (m['type'] == 'result') results.add(m);
        });
        sandbox.onDispose(() => unawaited(sub.cancel()));

        tr.write({
          'type': 'user',
          'uuid': 'u1',
          'message': {'role': 'user', 'content': 'turn1'},
        });
        await waitUntil(() => results.length == 1);

        tr.write({
          'type': 'control_request',
          'request_id': 'c1',
          'request': {
            'subtype': 'apply_flag_settings',
            'settings': {
              'permissions': {
                'deny': ['mcp__ext_srv'],
              },
            },
          },
        });
        await Future<void>.delayed(const Duration(milliseconds: 50));

        tr.write({
          'type': 'user',
          'uuid': 'u2',
          'message': {'role': 'user', 'content': 'turn2'},
        });
        await waitUntil(() => results.length == 2);

        final launches = fakeAgy
            .readCaptures()
            .where((e) => e['type'] == 'launch')
            .toList();
        expect(launches, hasLength(2));
        final secondArgs = (launches.last['args'] as List).cast<String>();
        expect(
          secondArgs.any(
            (a) => a.startsWith('--settings=') && a.contains('mcp__ext_srv'),
          ),
          isTrue,
        );
      },
    );

    test(
      'T5-10 [F5]: CodeBuddyTransport concurrent writes across account respawn do not drop queued turns',
      () async {
        final fakeCb = FakeCliExecutable.create(
          sandbox.rootDir,
          name: 'fake_cb_t5_respawn',
          dartBody: _fakeCodeBuddyRespawnBody,
        );
        CodeBuddyPathSetting.current = () => fakeCb.executablePath;
        sandbox.useClaudeEnvironment(sandbox.processEnv);
        CodeBuddyAccounts.onActiveAccountSwitched = null;

        final tr = await CodeBuddyTransport.start(
          ClaudeLaunch(cwd: sandbox.projectDir.path, persist: false),
        );
        sandbox.onDispose(() async {
          tr.close();
          await tr.exited.timeout(
            const Duration(seconds: 3),
            onTimeout: () {},
          );
        });

        final results = <String>[];
        final sub = tr.messages.listen((m) {
          if (m['type'] == 'result') {
            results.add('${m['result'] ?? ''}');
          }
        });
        sandbox.onDispose(() => unawaited(sub.cancel()));

        tr.write({
          'type': 'user',
          'uuid': 'u1',
          'message': {'role': 'user', 'content': 'SLOW_TURN_1'},
        });
        await waitUntil(
          () => fakeCb.readCaptures().any(
            (e) => e['type'] == 'user' && e['uuid'] == 'u1',
          ),
        );

        // Trigger account switch while turn 1 is in flight, then send turn 2
        // and turn 3 back-to-back as turn 1 completes and respawn begins.
        unawaited(
          Future<void>.value(CodeBuddyAccounts.onActiveAccountSwitched?.call(null)),
        );
        await waitUntil(() => results.contains('ACK:SLOW_TURN_1'));

        tr.write({
          'type': 'user',
          'uuid': 'u2',
          'message': {'role': 'user', 'content': 'TURN_2'},
        });
        tr.write({
          'type': 'user',
          'uuid': 'u3',
          'message': {'role': 'user', 'content': 'TURN_3'},
        });

        await waitUntil(
          () => results.contains('ACK:TURN_2') && results.contains('ACK:TURN_3'),
          timeout: const Duration(seconds: 8),
        );
      },
    );

    test(
      'T5-11 [F10]: AyteIpcServer validates cwd on POST /prompt, rejects bad field types on POST /tasks with 400, and checks canSend on POST /sessions',
      () async {
        await AyteIpcServer.instance.start();
        final info =
            jsonDecode(File(AyteIpcServer.instance.ipcInfoPath).readAsStringSync())
                as Map;
        final port = info['port'] as int;
        final token = info['token'] as String;

        final client = HttpClient()..findProxy = (_) => 'DIRECT';
        sandbox.onDispose(client.close);

        Future<({int code, Map<String, Object?> json})> post(
          String path,
          Map<String, Object?> payload,
        ) async {
          final req = await client.postUrl(
            Uri.parse('http://127.0.0.1:$port$path'),
          );
          req.headers.set('Authorization', 'Bearer $token');
          req.headers.contentType = ContentType.json;
          req.write(jsonEncode(payload));
          final resp = await req.close();
          final raw = await utf8.decoder.bind(resp).join();
          return (
            code: resp.statusCode,
            json: (jsonDecode(raw) as Map).cast<String, Object?>(),
          );
        }

        final badCwd = await post('/prompt', {
          'prompt': 'hello',
          'cwd': p.join(sandbox.rootDir.path, 'missing_dir'),
        });
        expect(badCwd.code, HttpStatus.badRequest);

        final badBool = await post('/tasks', {
          'prompt': 'hello',
          'cwd': sandbox.projectDir.path,
          'useWorktree': 'not-a-bool',
        });
        expect(badBool.code, HttpStatus.badRequest);

        final sent = <String>[];
        late KernelDescriptor nonQueuingDesc;
        nonQueuingDesc = KernelDescriptor(
          id: 'non-queuing',
          label: 'NonQueuing',
          icon: Icons.bolt,
          description: 'tier5',
          create: (_) =>
              _Tier5NonQueuingStreamingKernel(nonQueuingDesc, onSend: sent.add),
        );
        final ws = Workspace(
          kernels: [nonQueuingDesc],
          projects: [Project('ipc_proj', sandbox.projectDir.path)],
        );
        sandbox.onDispose(ws.dispose);
        AyteIpcServer.instance.workspace = ws;

        final badSessionType = await post('/sessions', {
          'prompt': 123,
          'cwd': sandbox.projectDir.path,
        });
        expect(badSessionType.code, HttpStatus.badRequest);

        final busyRes = await post('/sessions', {
          'prompt': 'should be rejected while streaming',
          'cwd': sandbox.projectDir.path,
        });
        expect(busyRes.code, HttpStatus.conflict);
        expect(sent, isEmpty);
      },
    );

    test(
      'T5-12 [F2]: AyteSdkMcpBridge handles notifications/cancelled, GET/DELETE/404, and malformed JSON-RPC batches cleanly',
      () async {
        final cancelledObserved = Completer<void>();
        final bridge = await AyteSdkMcpBridge.start(
          cwd: sandbox.projectDir.path,
          handler: (msg, call) async {
            if (msg['method'] == 'tools/call') {
              unawaited(
                call.cancelled?.then((_) {
                  if (!cancelledObserved.isCompleted) {
                    cancelledObserved.complete();
                  }
                }),
              );
              await call.cancelled;
              return {
                'jsonrpc': '2.0',
                'id': msg['id'],
                'result': {
                  'content': [
                    {'type': 'text', 'text': 'cancelled'},
                  ],
                  'isError': true,
                },
              };
            }
            return {'jsonrpc': '2.0', 'id': msg['id'], 'result': {}};
          },
        );
        sandbox.onDispose(() => bridge.close(force: true));

        final probe = McpHttpProbe(bridge.endpointUri, bearerToken: bridge.token);
        final getResp = await probe.requestMethod('GET');
        expect(getResp.statusCode, HttpStatus.methodNotAllowed);

        final delResp = await probe.requestMethod('DELETE');
        expect(delResp.statusCode, HttpStatus.ok);

        final wellKnown = McpHttpProbe(
          Uri.parse('http://127.0.0.1:${bridge.port}/.well-known/oauth'),
        );
        expect((await wellKnown.requestMethod('GET')).statusCode, HttpStatus.notFound);

        final emptyBatch = await probe.postRaw('[]');
        expect(emptyBatch.statusCode, HttpStatus.badRequest);

        final callFuture = probe.postJsonRpc({
          'jsonrpc': '2.0',
          'id': 99,
          'method': 'tools/call',
          'params': {'name': 'slow_tool', 'arguments': <String, Object?>{}},
        });
        await Future<void>.delayed(const Duration(milliseconds: 30));

        final cancelResp = await probe.postJsonRpc({
          'jsonrpc': '2.0',
          'method': 'notifications/cancelled',
          'params': {'requestId': 99},
        });
        expect(cancelResp.statusCode, HttpStatus.accepted);
        await cancelledObserved.future.timeout(const Duration(seconds: 3));
        final callResp = await callFuture.timeout(const Duration(seconds: 3));
        expect(callResp.statusCode, HttpStatus.ok);
        expect(bridge.inFlightCancelCountForTesting, 0);
      },
    );

    test(
      'T5-13 [F3]: AgentMessage parser handles XML entities, thread attribute alias, nested blocks, and rejects concatenated blocks',
      () {
        final formatted = formatAgentMessage(
          'Lead "A" & <B>\n',
          'Line 1\n<agent-message from="inner">nested</agent-message>\nLine 2',
          thread: 'th-42',
        );
        final parsed = parseAgentMessage(formatted);
        expect(parsed, isNotNull);
        expect(parsed!.from, 'Lead "A" & <B>\n');
        expect(parsed.session, 'th-42');
        expect(parsed.thread, 'th-42');
        expect(parsed.text, contains('nested'));

        const concatenated =
            '<agent-message from="A">one</agent-message>'
            '<agent-message from="B">two</agent-message>';
        expect(parseAgentMessage(concatenated), isNull);
        expect(parseAgentMessage('<agent-message from=" ">hi</agent-message>'), isNull);
      },
    );

    test(
      'T5-14 [F8]: CodexKernel restart interrupts active turn, serverRequest/resolved clears approval, and unsupported server RPC returns -32601',
      () async {
        final transport = _Tier5FakeCodexTransport();
        final kernel = CodexKernel(
          KernelRegistry.codex,
          transport,
          context: KernelContext(cwd: sandbox.projectDir.path),
          catalog: null,
          loadLocalCatalog: false,
          enableSdkMcpBridge: false,
        );
        sandbox.onDispose(kernel.dispose);

        final events = <KernelEvent>[];
        final sub = kernel.events.listen(events.add);
        sandbox.onDispose(() => unawaited(sub.cancel()));

        kernel.send(const KernelTurn(id: 't-1', text: 'do work'));
        await waitUntil(
          () => transport.written.any((m) => m['method'] == 'initialize'),
        );
        transport.push({
          'id': transport.written
              .firstWhere((m) => m['method'] == 'initialize')['id'],
          'result': <String, Object?>{},
        });
        await waitUntil(
          () => transport.written.any((m) => m['method'] == 'thread/start'),
        );
        transport.push({
          'id': transport.written
              .firstWhere((m) => m['method'] == 'thread/start')['id'],
          'result': {
            'thread': {'id': 'th-r1'},
          },
        });
        await waitUntil(
          () => transport.written.any((m) => m['method'] == 'turn/start'),
        );
        transport.push({
          'id': transport.written
              .firstWhere((m) => m['method'] == 'turn/start')['id'],
          'result': {
            'turn': {'id': 'srv-r1'},
          },
        });

        // Unknown server request -> JSON-RPC -32601 error
        transport.push({
          'id': 701,
          'method': 'unknown/custom/request',
          'params': const <String, Object?>{},
        });
        await waitUntil(
          () => transport.written.any((m) => m['id'] == 701),
        );
        final errReply = transport.written.firstWhere((m) => m['id'] == 701);
        expect((errReply['error'] as Map)['code'], -32601);

        // Approval request dismissed by serverRequest/resolved
        transport.push({
          'id': 702,
          'method': 'item/commandExecution/requestApproval',
          'params': {'command': 'echo ok'},
        });
        await waitUntil(
          () => events.any((e) => e is InteractionRequested),
        );
        transport.push({
          'method': 'serverRequest/resolved',
          'params': {'requestId': 702},
        });
        await waitUntil(
          () => events.any(
            (e) => e is InteractionResolved && e.requestId == 'approval:702',
          ),
        );

        // Restart during active turn ends turn as interrupted
        kernel.restart();
        await waitUntil(
          () => events.any((e) => e is TurnEnded && e.interrupted),
        );
      },
    );

    test(
      'T5-15 [F8/F9]: CodexCatalog extended Windows path normalization & CustomizationStore TOML quoted MCP + path-traversal rejection',
      () async {
        expect(
          CodexCatalog.normalizeWindowsPath(r'\\?\C:\Users\Dev\Repo\'),
          r'C:\Users\Dev\Repo',
        );
        expect(
          CodexCatalog.normalizeWindowsPath(r'\\?\UNC\server\share\proj\'),
          r'\\server\share\proj',
        );
        expect(
          () => CodexCatalog(codexHome: sandbox.homeDir.path).delete('../evil'),
          throwsArgumentError,
        );

        final codexDir = Directory(p.join(sandbox.homeDir.path, '.codex'))
          ..createSync(recursive: true);
        File(p.join(codexDir.path, 'config.toml')).writeAsStringSync(
          '[mcp_servers."my.dotted.srv"]\n'
          'command = "npx"\n'
          'args = [\n'
          '  "-y",\n'
          '  "pkg"\n'
          ']\n'
          'enabled = true\n',
        );
        final store = CustomizationStore(
          configDir: p.join(sandbox.homeDir.path, '.gemini', 'config'),
          homeDir: sandbox.homeDir.path,
          codexHome: codexDir.path,
        );
        final mcps = await store.list(CustomizationKind.mcps);
        expect(mcps.any((m) => m.name == 'my.dotted.srv'), isTrue);
        expect(await store.commandFile('../escape'), isNull);
        expect(await store.commandFile('sub/cmd'), isNull);
      },
    );

    test(
      'T5-16 [F10]: TaskQueueService.approveAndMerge aborts merge conflict cleanly keeping main repo spotless and worktree intact',
      () async {
        final repo = await initTempGitRepo(
          sandbox.rootDir,
          name: 'conflict_repo',
          files: const {'shared.txt': 'base\n'},
        );
        final svc = TaskQueueService.instance;
        final task = svc.enqueue(
          title: 'Conflicting change',
          prompt: 'modify shared.txt',
          repoPath: repo.path,
          agentId: 'agy',
        );

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
          File(p.join(cwd, 'shared.txt')).writeAsStringSync('task-branch\n');
          return (ok: true, output: 'done', error: null);
        };

        await svc.runTask(task.id);
        expect(task.status, WorktreeTaskStatus.review);

        // Advance main branch with a conflicting commit on shared.txt.
        File(p.join(repo.path, 'shared.txt')).writeAsStringSync('main-branch\n');
        await Process.run('git', ['add', 'shared.txt'], workingDirectory: repo.path);
        await Process.run(
          'git',
          ['commit', '-m', 'main conflicting change'],
          workingDirectory: repo.path,
        );

        final mergeRes = await svc.approveAndMerge(task.id);
        expect(mergeRes.ok, isFalse);

        // Main repository must have no leftover MERGE_HEAD or dirty index.
        final statusRes = await Process.run(
          'git',
          ['status', '--porcelain'],
          workingDirectory: repo.path,
        );
        expect('${statusRes.stdout}'.trim(), isEmpty);
        final mergeHeadRes = await Process.run(
          'git',
          ['rev-parse', '-q', '--verify', 'MERGE_HEAD'],
          workingDirectory: repo.path,
        );
        expect(mergeHeadRes.exitCode, isNot(0));
        expect(Directory(task.worktreePath).existsSync(), isTrue);

        await svc.discardTask(task.id);
      },
    );

    test(
      'T5-17 [F5]: CodeBuddyTransport does not clear _needsAccountRespawn when account switches mid-spawn',
      () async {
        final fakeCb = FakeCliExecutable.create(
          sandbox.rootDir,
          name: 'fake_cb_t5_midspawn',
          dartBody: _fakeCodeBuddyMidspawnBody,
        );
        CodeBuddyPathSetting.current = () => fakeCb.executablePath;
        sandbox.useClaudeEnvironment(sandbox.processEnv);
        CodeBuddyAccounts.onActiveAccountSwitched = null;

        final bootTransport = await CodeBuddyTransport.start(
          ClaudeLaunch(cwd: sandbox.projectDir.path, persist: false),
        );
        bootTransport.close();
        await bootTransport.exited.timeout(
          const Duration(seconds: 3),
          onTimeout: () {},
        );

        final accDir = Directory(p.join(sandbox.rootDir.path, 'cb_accounts'))
          ..createSync(recursive: true);
        final accounts = _Tier5PausingCodeBuddyAccounts(dataDir: accDir.path);
        sandbox.onDispose(accounts.dispose);
        await accounts.ensureInitialized();
        await accounts.upsertAccount(
          _tier5CbAccount('acc-1', 'token-1'),
          makeActive: true,
        );

        final cli = CodeBuddyCli(
          executable: fakeCb.executablePath,
          environment: sandbox.processEnv,
          throughShell: false,
        );
        final transport = CodeBuddyTransport.forTesting(
          cli: cli,
          launch: ClaudeLaunch(cwd: sandbox.projectDir.path, persist: false),
          accounts: accounts,
        );
        sandbox.onDispose(() async {
          transport.close();
          await transport.exited.timeout(
            const Duration(seconds: 3),
            onTimeout: () {},
          );
        });

        await transport.spawnForTesting();
        final results = <String>[];
        final sub = transport.messages.listen((m) {
          if (m['type'] == 'result') results.add('${m['result']}');
        });
        sandbox.onDispose(() => unawaited(sub.cancel()));

        // Start recycling to acc-2, pause inside ensureFreshAccount, then switch to acc-3.
        accounts.pauseAccountId = 'acc-2';
        final switchTo2 = accounts.upsertAccount(
          _tier5CbAccount('acc-2', 'token-2'),
          makeActive: true,
        );
        await accounts.waitUntilPaused();

        final switchTo3 = accounts.upsertAccount(
          _tier5CbAccount('acc-3', 'token-3'),
          makeActive: true,
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));

        accounts.resumePause();
        await Future.wait([switchTo2, switchTo3]);

        transport.write({
          'type': 'user',
          'message': {'role': 'user', 'content': 'hello'},
        });
        await waitUntil(() => results.isNotEmpty);

        final events = fakeCb.readCaptures();
        final userEvents = events
            .where((e) => e['type'] == 'stdin' && e['msgType'] == 'user')
            .toList();
        expect(userEvents, hasLength(1));
        expect(userEvents.single['apiKey'], 'token-3');
        expect(results, ['ok-token-3']);
      },
    );

    test(
      'T5-18 [F4/F9]: IdeWorkspace matches Windows case-variant paths across open, openDiff, select, edit, reload, and documentsIn',
      () async {
        final winRoot = p.join(sandbox.projectDir.path, 'ws_win_case');
        final upper = p.windows.join(winRoot, 'Src', 'Alpha.dart');
        final lower = p.windows.join(winRoot.toLowerCase(), 'src', 'alpha.dart');
        File(upper)
          ..createSync(recursive: true)
          ..writeAsStringSync('v1');

        final ws = IdeWorkspace(
          winRoot,
          files: IdeFileService(winRoot),
          paths: p.windows,
        );
        sandbox.onDispose(ws.dispose);

        await ws.open(upper);
        expect(ws.documents, hasLength(1));

        // Case-variant open selects existing tab instead of opening a duplicate.
        await ws.open(lower);
        expect(ws.documents, hasLength(1));

        // Case-variant edit updates the open document instead of no-oping.
        ws.edit(lower, 'v2-via-edit');
        expect(ws.documents.single.text, 'v2-via-edit');

        // Case-variant documentsIn matches the file directly.
        expect(ws.documentsIn(lower), hasLength(1));

        // Case-variant reload reloads clean open document from disk.
        await ws.save(ws.documents.single);
        File(upper).writeAsStringSync('v3-on-disk');
        await ws.reload([lower]);
        expect(ws.documents.single.text, 'v3-on-disk');

        // Case-variant openDiff and select reuse the existing diff/file tabs.
        await ws.openDiff(
          upper,
          label: 'Working Tree',
          original: () async => 'v0',
        );
        expect(ws.documents, hasLength(2));
        await ws.openDiff(
          lower,
          label: 'Working Tree',
          original: () async => 'v0',
        );
        expect(ws.documents, hasLength(2));
        ws.select(lower);
        expect(ws.active?.label, isNull);
        expect(ws.active?.path, p.windows.normalize(upper));
      },
    );

    testWidgets(
      'T5-19 [F4/F9]: GitChangesService, IdeAgentEdit.nextPending, IdeAgentEdits.hunksOf, and ChatScreen._openFile handle Windows case-variant paths',
      (tester) async {
        final winRoot = p.join(sandbox.projectDir.path, 'g2_case_proj');
        final compUpper = p.windows.join(
          winRoot,
          'Lib',
          'Chat',
          'Composer',
          'Composer.dart',
        );
        final compLower = compUpper.toLowerCase();
        final screenUpper = p.windows.join(
          winRoot,
          'Lib',
          'Chat',
          'Chat_Screen.dart',
        );
        File(compUpper)
          ..createSync(recursive: true)
          ..writeAsStringSync('before');

        final ws = IdeWorkspace(
          winRoot,
          files: IdeFileService(winRoot),
          paths: p.windows,
        );
        addTearDown(() async => tester.runAsync(() async => ws.dispose()));

        await tester.runAsync(() => ws.open(compUpper));

        final review = _Tier5CaseReview(winRoot)
          ..listed = [
            FileChange(path: compUpper, added: 3, removed: 1),
            FileChange(path: screenUpper, added: 1, removed: 0),
          ]
          ..bases[compUpper.toLowerCase()] = 'orig-composer'
          ..bases[screenUpper.toLowerCase()] = 'orig-screen';

        final session = ChatSession(
          kernel: MockKernels.claudeCode,
          kernels: [MockKernels.claudeCode],
          kernelContext: KernelContext(cwd: winRoot),
          historyCount: 0,
          openReview: (root, {session}) async => review,
        );
        addTearDown(session.dispose);

        final opened = <FileOpenRequest>[];
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: ChatScreen(
              session: session,
              fileLinks: FileLinkTarget(
                open: opened.add,
                paths: p.windows,
              ),
            ),
          ),
        );
        await tester.pump();

        const promptText = '把输入框改成随内容增高';
        session.send(const ComposerMessage(text: promptText));
        await tester.pump(const Duration(milliseconds: 100));
        for (var i = 0; i < 400 && session.isStreaming; i++) {
          switch (session.pendingInteraction) {
            case QuestionRequest():
              session.answer(const QuestionAnswer([], skipped: true));
            case ApprovalRequest():
              session.answer(const ApprovalAnswer(ApprovalDecision.allowOnce));
            default:
          }
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pump(const Duration(seconds: 5));

        final edits = IdeAgentEdits()..sessions = [session];
        addTearDown(edits.dispose);
        await tester.pump();

        final svc = GitChangesService(
          files: ws.files,
          notifications: IdeNotifications(),
          workspace: ws,
          agentEdits: () => edits,
        );

        await tester.runAsync(() => svc.write(compLower, 'edited-via-git-changes'));
        expect(ws.documents.single.text, 'edited-via-git-changes');
        expect(File(compUpper).readAsStringSync(), 'edited-via-git-changes');

        final marks = svc.agentMarksOf(compLower);
        expect(marks, isNotNull);
        expect(marks!.base, 'orig-composer');
        expect(marks.turns, [promptText]);

        final edit = edits.of(compLower);
        expect(edit, isNotNull);
        expect(edit!.nextPending(), screenUpper);

        // IdeAgentEdits.hunksOf shares the same hunk state across case variants.
        expect(identical(edits.hunksOf(compUpper), edits.hunksOf(compLower)), isTrue);

        // ChatScreen._openFile resolves case-variant FileOpenRequest(diff: true)
        // against _session.fileChanges and populates change + original.
        final scopeCtx = tester.element(find.byType(ActivityStrip));
        FileOpenScope.find(
          scopeCtx,
        )!.onOpen(FileOpenRequest(compLower, diff: true));
        await tester.pump();
        expect(opened, hasLength(1));
        expect(opened.single.change?.path, compUpper);
        expect(opened.single.original, isNotNull);
        expect(await tester.runAsync(() => opened.single.original!()), 'orig:$compUpper');
      },
    );

    test(
      'T5-20 [F2/F4]: AntigravityTransport.close() during mid-flight setup/spawn does not leak a child process',
      () async {
        final pidFile = File(p.join(sandbox.rootDir.path, 'agy_midclose.pid'));
        final fakeAgy = FakeCliExecutable.create(
          sandbox.rootDir,
          name: 'fake_agy_t5_close_race',
          dartBody: '''
Future<void> main(List<String> args) async {
  File(${jsonEncode(pidFile.path)}).writeAsStringSync('\$pid', flush: true);
  await stdin.transform(utf8.decoder).drain<void>();
}
''',
        );

        sandbox.registerSdkTool(
          ClaudeSdkTool(
            name: 't5_close_probe_tool',
            description: 'probe',
            inputSchema: const {'type': 'object', 'properties': <String, Object?>{}},
            run: (_, _) async => 'ok',
          ),
        );

        final tr = AntigravityTransport.forTesting(
          executable: fakeAgy.executablePath,
          environment: sandbox.processEnv,
          launch: ClaudeLaunch(
            cwd: sandbox.projectDir.path,
            persist: false,
            sdkServers: const [ClaudeSdkTools.server],
          ),
        );
        sandbox.onDispose(() async {
          tr.close();
          if (pidFile.existsSync()) {
            final spawnedPid = int.tryParse(pidFile.readAsStringSync().trim());
            if (spawnedPid != null) {
              if (Platform.isWindows) {
                Process.runSync('taskkill', ['/PID', '$spawnedPid', '/T', '/F']);
              } else {
                Process.killPid(spawnedPid, ProcessSignal.sigkill);
              }
            }
          }
        });

        tr.write({
          'type': 'user',
          'uuid': 'u-close-race',
          'message': {'role': 'user', 'content': 'hello'},
        });
        await Future<void>.delayed(Duration.zero);
        tr.close();
        await tr.exited.timeout(const Duration(seconds: 3));
        await Future<void>.delayed(const Duration(milliseconds: 300));

        expect(
          pidFile.existsSync(),
          isFalse,
          reason:
              'AntigravityTransport._ensureProcess must abort on _closed before spawning child process',
        );
      },
    );

    test(
      'T5-21 [F3]: SessionTools matches Windows case-variant project paths in session_new and session_list',
      () async {
        final targetDir = Directory(p.join(sandbox.projectDir.path, 'TargetRepo'))
          ..createSync(recursive: true);
        final callerDir = Directory(p.join(sandbox.projectDir.path, 'CallerRepo'))
          ..createSync(recursive: true);
        final ws = Workspace(
          kernels: [MockKernels.claudeCode],
          projects: [
            Project('TargetRepo', targetDir.path),
            Project('CallerRepo', callerDir.path),
          ],
        );
        sandbox.onDispose(ws.dispose);
        SessionTools.register(ws);
        sandbox.onDispose(SessionTools.unregister);

        final caller = ws.startAgent(ws.projects.last);
        final lowerTarget = Platform.isWindows
            ? targetDir.path.toLowerCase()
            : targetDir.path;

        final newRes = await ClaudeSdkTools.handle(
          {
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'tools/call',
            'params': {
              'name': 'session_new',
              'arguments': {'text': 'hello', 'project': lowerTarget},
            },
          },
          ClaudeSdkCall(
            cwd: callerDir.path,
            sessionId: SessionTools.idOf(caller),
          ),
        );
        expect((newRes['result'] as Map)['isError'], isNot(true));

        final listRes = await ClaudeSdkTools.handle(
          {
            'jsonrpc': '2.0',
            'id': 2,
            'method': 'tools/call',
            'params': {
              'name': 'session_list',
              'arguments': {'project': lowerTarget},
            },
          },
          ClaudeSdkCall(
            cwd: callerDir.path,
            sessionId: SessionTools.idOf(caller),
          ),
        );
        final listText =
            (((listRes['result'] as Map)['content'] as List).first as Map)['text']
                as String;
        expect(listText, contains('TargetRepo'));
      },
    );

    test(
      'T5-22 [F7/F10]: ProcessCodexTransport.enrichedPath and AcpAgentService.buildEnrichedPath read Windows env vars case-insensitively',
      () {
        final fakeLocal = Directory(
          p.join(sandbox.rootDir.path, 'CaseLocal', 'OpenAI', 'Codex', 'bin', 'v1'),
        )..createSync(recursive: true);
        File(p.join(fakeLocal.path, 'codex.exe')).writeAsStringSync('');
        final fakeAppData = Directory(p.join(sandbox.rootDir.path, 'CaseRoaming'))
          ..createSync(recursive: true);

        final env = <String, String>{
          'path': r'C:\CustomEmpty',
          'localappdata': p.join(sandbox.rootDir.path, 'CaseLocal'),
          'appdata': fakeAppData.path,
        };

        final codexEnriched = ProcessCodexTransport.enrichedPath(
          env,
          forceWindows: true,
        );
        expect(codexEnriched['PATH'], contains(fakeLocal.path));
        expect(
          codexEnriched['PATH'],
          contains(p.windows.join(fakeAppData.path, 'npm')),
        );

        if (Platform.isWindows) {
          final acpEnriched = AcpAgentService.buildEnrichedPath(env);
          expect(
            acpEnriched,
            contains(p.join(fakeAppData.path, 'npm')),
          );
          expect(
            acpEnriched,
            contains(p.join(env['localappdata']!, 'Programs', 'claude')),
          );
        }
      },
    );

    test(
      'T5-23 [F5]: CodeBuddyTransport.close() during mid-spawn does not spawn a child process or complete exited prematurely',
      () async {
        final pidFile = File(p.join(sandbox.rootDir.path, 'cb_midclose.pid'));
        final fakeCb = FakeCliExecutable.create(
          sandbox.rootDir,
          name: 'fake_cb_t5_close_race',
          dartBody: '''
Future<void> main(List<String> args) async {
  File(${jsonEncode(pidFile.path)}).writeAsStringSync('\$pid', flush: true);
  await stdin.transform(utf8.decoder).drain<void>();
}
''',
        );
        CodeBuddyPathSetting.current = () => fakeCb.executablePath;
        sandbox.useClaudeEnvironment(sandbox.processEnv);
        CodeBuddyAccounts.onActiveAccountSwitched = null;

        final accDir = Directory(p.join(sandbox.rootDir.path, 'cb_close_accs'))
          ..createSync(recursive: true);
        final accounts = _Tier5PausingCodeBuddyAccounts(dataDir: accDir.path);
        sandbox.onDispose(accounts.dispose);
        await accounts.ensureInitialized();
        await accounts.upsertAccount(
          _tier5CbAccount('acc-1', 'tok-1'),
          makeActive: true,
        );

        final cli = CodeBuddyCli(
          executable: fakeCb.executablePath,
          environment: sandbox.processEnv,
          throughShell: false,
        );
        final transport = CodeBuddyTransport.forTesting(
          cli: cli,
          launch: ClaudeLaunch(cwd: sandbox.projectDir.path, persist: false),
          accounts: accounts,
        );
        sandbox.onDispose(() async {
          transport.close();
          if (pidFile.existsSync()) {
            final spawnedPid = int.tryParse(pidFile.readAsStringSync().trim());
            if (spawnedPid != null) {
              if (Platform.isWindows) {
                Process.runSync('taskkill', ['/PID', '$spawnedPid', '/T', '/F']);
              } else {
                Process.killPid(spawnedPid, ProcessSignal.sigkill);
              }
            }
          }
        });

        accounts.pauseAccountId = 'acc-1';
        final spawnFuture = transport.spawnForTesting();
        await accounts.waitUntilPaused();

        transport.close();
        accounts.resumePause();
        await Future.wait([
          spawnFuture,
          transport.exited.timeout(const Duration(seconds: 3)),
        ]);
        await Future<void>.delayed(const Duration(milliseconds: 250));

        expect(
          pidFile.existsSync(),
          isFalse,
          reason:
              'CodeBuddyTransport._spawnProcess must abort on _closed before calling Process.start',
        );
      },
    );

    test(
      'T5-24 [F10]: TaskQueueService.cancelTask() during async launch kills child process without hanging',
      () async {
        final pidFile = File(p.join(sandbox.rootDir.path, 'task_cancel.pid'));
        final fakeCli = FakeCliExecutable.create(
          sandbox.rootDir,
          name: 'fake_task_t5_cancel',
          dartBody: '''
Future<void> main(List<String> args) async {
  File(${jsonEncode(pidFile.path)}).writeAsStringSync('\$pid', flush: true);
  await Future<void>.delayed(const Duration(seconds: 15));
}
''',
        );
        final svc = TaskQueueService.instance;
        final task = svc.enqueue(
          title: 'cancel-race',
          prompt: 'sleep',
          repoPath: sandbox.projectDir.path,
          useWorktree: false,
        );

        final entering = Completer<void>();
        final proceed = Completer<void>();
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
          final proc = await Process.start(fakeCli.executablePath, const []);
          onProcessStarted?.call(proc);
          final code = await proc.exitCode;
          return (
            ok: code == 0,
            output: '',
            error: code == 0 ? null : 'exit $code',
          );
        };

        sandbox.onDispose(() async {
          if (pidFile.existsSync()) {
            final spawnedPid = int.tryParse(pidFile.readAsStringSync().trim());
            if (spawnedPid != null) {
              if (Platform.isWindows) {
                Process.runSync('taskkill', ['/PID', '$spawnedPid', '/T', '/F']);
              } else {
                Process.killPid(spawnedPid, ProcessSignal.sigkill);
              }
            }
          }
        });

        final runFuture = svc.runTask(task.id);
        await entering.future;

        await svc.cancelTask(task.id);
        proceed.complete();

        await runFuture.timeout(const Duration(seconds: 4));
        expect(task.status, WorktreeTaskStatus.cancelled);
      },
    );

    test(
      'T5-25 [F4/F6/F9]: discoverAntigravityCommands respects leading slash and plugin directory name in disabledSkills',
      () async {
        final home = sandbox.homeDir.path;
        final configDir = p.join(home, '.gemini', 'config');
        final slashSkillDir = Directory(
          p.join(configDir, 'skills', 'slash-skill'),
        )..createSync(recursive: true);
        File(p.join(slashSkillDir.path, 'SKILL.md')).writeAsStringSync(
          '---\nname: slash-skill\n---\nBody\n',
        );

        final pluginDir = Directory(
          p.join(configDir, 'plugins', 'my-plugin-dir'),
        )..createSync(recursive: true);
        File(p.join(pluginDir.path, 'plugin.json')).writeAsStringSync(
          '{"name": "Pretty Plugin Name"}',
        );
        final pluginSkillDir = Directory(
          p.join(pluginDir.path, 'skills', 'plug-skill'),
        )..createSync(recursive: true);
        File(p.join(pluginSkillDir.path, 'SKILL.md')).writeAsStringSync(
          '---\nname: plug-skill\n---\nBody\n',
        );

        const switches = ExtensionSwitches(
          disabledSkills: {'/slash-skill', 'my-plugin-dir:plug-skill'},
        );
        final store = CustomizationStore(configDir: configDir, homeDir: home);
        ExtensionSwitches.current = () => switches;
        expect(await store.commandFile('slash-skill'), isNull);
        expect(await store.commandFile('plug-skill'), isNull);

        final agyCmds = await discoverAntigravityCommands(
          cwd: sandbox.projectDir.path,
          home: home,
          disabledSkills: switches.disabledSkills,
        );
        final names = {for (final c in agyCmds) c['name']};
        expect(names, isNot(contains('slash-skill')));
        expect(names, isNot(contains('plug-skill')));
      },
    );

    test(
      'T5-26 [F5]: CodeBuddyTransport._killProcessForRespawn terminates Windows .cmd child process trees on active account switch',
      () async {
        CodeBuddyAccounts.onActiveAccountSwitched = null;
        final accDir = Directory(p.join(sandbox.rootDir.path, 'cb_t5_26_accs'))
          ..createSync(recursive: true);
        final accounts = CodeBuddyAccounts(dataDir: accDir.path);
        sandbox.onDispose(accounts.dispose);
        await accounts.ensureInitialized();
        await accounts.upsertAccount(
          _tier5CbAccount('acc-1', 'tok-1'),
          makeActive: true,
        );

        final dartExe = resolveDartExecutable();
        final sleeper = File(p.join(sandbox.rootDir.path, 't5_26_sleeper.dart'))
          ..writeAsStringSync('''
import 'dart:io';
Future<void> main() async {
  await Future<void>.delayed(const Duration(seconds: 30));
}
''');
        final gcPidFile = File(p.join(sandbox.rootDir.path, 't5_26_gc.pid'));
        final parentScript = File(
          p.join(sandbox.rootDir.path, 't5_26_cb_parent.dart'),
        )..writeAsStringSync('''
import 'dart:convert';
import 'dart:io';
Future<void> main() async {
  final gcFile = File(${jsonEncode(gcPidFile.path)});
  if (!gcFile.existsSync()) {
    final proc = await Process.start(${jsonEncode(dartExe)}, [${jsonEncode(sleeper.path)}]);
    gcFile.writeAsStringSync('\${proc.pid}', flush: true);
  }
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    final msg = (jsonDecode(line) as Map).cast<String, Object?>();
    if (msg['type'] == 'control_request') {
      final reqId = msg['request_id'];
      stdout.writeln(jsonEncode({
        'type': 'control_response',
        'response': {
          'subtype': 'success',
          'request_id': reqId,
          'response': const <String, Object?>{},
        },
      }));
      await stdout.flush();
    } else if (msg['type'] == 'user') {
      final content = ((msg['message'] as Map?)?['content'] ?? '').toString();
      stdout.writeln(jsonEncode({
        'type': 'result',
        'subtype': 'success',
        'is_error': false,
        'result': 'ok:\$content',
      }));
      await stdout.flush();
    }
  }
}
''');

        final binDir = Directory(p.join(sandbox.rootDir.path, 't5_26_bin'))
          ..createSync(recursive: true);
        final String exePath;
        final bool throughShell;
        if (Platform.isWindows) {
          final cmd = File(p.join(binDir.path, 'fake_cb_respawn.cmd'))
            ..writeAsStringSync(
              '@echo off\r\n"$dartExe" "${parentScript.path}" %*\r\n',
            );
          exePath = cmd.path;
          throughShell = true;
        } else {
          final sh = File(p.join(binDir.path, 'fake_cb_respawn.sh'))
            ..writeAsStringSync(
              '#!/bin/sh\nexec "$dartExe" "${parentScript.path}" "\$@"\n',
            );
          Process.runSync('chmod', ['+x', sh.path]);
          exePath = sh.path;
          throughShell = false;
        }

        final transport = CodeBuddyTransport.forTesting(
          cli: CodeBuddyCli(
            executable: exePath,
            environment: sandbox.processEnv,
            throughShell: throughShell,
          ),
          launch: ClaudeLaunch(cwd: sandbox.projectDir.path, persist: false),
          accounts: accounts,
        );
        sandbox.onDispose(() async {
          transport.close();
          await transport.exited.timeout(
            const Duration(seconds: 3),
            onTimeout: () {},
          );
          if (gcPidFile.existsSync()) {
            final gcPid = int.tryParse(gcPidFile.readAsStringSync().trim());
            if (gcPid != null) _tier5KillPidTree(gcPid);
          }
        });

        final results = <String>[];
        final sub = transport.messages.listen((m) {
          if (m['type'] == 'result') results.add('${m['result']}');
        });
        sandbox.onDispose(() => unawaited(sub.cancel()));

        await transport.spawnForTesting();
        transport.write({
          'type': 'user',
          'uuid': 'u1',
          'message': {'role': 'user', 'content': 'turn-1'},
        });
        await waitUntil(() => results.contains('ok:turn-1'));
        await waitUntil(() => gcPidFile.existsSync());
        final gcPid = int.parse(gcPidFile.readAsStringSync().trim());
        expect(_tier5IsPidAlive(gcPid), isTrue);

        await accounts.upsertAccount(
          _tier5CbAccount('acc-2', 'tok-2'),
          makeActive: true,
        );
        transport.write({
          'type': 'user',
          'uuid': 'u2',
          'message': {'role': 'user', 'content': 'turn-2'},
        });
        await waitUntil(() => results.contains('ok:turn-2'));
        expect(
          _tier5IsPidAlive(gcPid),
          isFalse,
          reason:
              'Pre-respawn grandchild PID $gcPid must be terminated by _killProcessForRespawn',
        );
      },
    );

    test(
      'T5-27 [F7]: ProcessCodexTransport kills Windows .cmd child trees on close()/stopProcess() and defers exited during mid-spawn close()',
      () async {
        final dartExe = resolveDartExecutable();
        final sleeper = File(p.join(sandbox.rootDir.path, 't5_27_sleeper.dart'))
          ..writeAsStringSync('''
import 'dart:io';
Future<void> main() async {
  await Future<void>.delayed(const Duration(seconds: 30));
}
''');
        final gcPidFile = File(p.join(sandbox.rootDir.path, 't5_27_gc.pid'));
        final parentScript = File(
          p.join(sandbox.rootDir.path, 't5_27_codex_parent.dart'),
        )..writeAsStringSync('''
import 'dart:convert';
import 'dart:io';
Future<void> main() async {
  final gcFile = File(${jsonEncode(gcPidFile.path)});
  if (!gcFile.existsSync()) {
    final proc = await Process.start(${jsonEncode(dartExe)}, [${jsonEncode(sleeper.path)}]);
    gcFile.writeAsStringSync('\${proc.pid}', flush: true);
  }
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    final msg = (jsonDecode(line) as Map).cast<String, Object?>();
    if (msg['method'] == 'initialize') {
      stdout.writeln(jsonEncode({'id': msg['id'], 'result': <String, Object?>{}}));
      await stdout.flush();
    }
  }
}
''');

        final binDir = Directory(p.join(sandbox.rootDir.path, 't5_27_bin'))
          ..createSync(recursive: true);
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

        final sep = Platform.isWindows ? ';' : ':';
        sandbox.useClaudeEnvironment({
          ...sandbox.processEnv,
          'PATH': '${binDir.path}$sep${p.dirname(dartExe)}',
        });

        final t1 = ProcessCodexTransport(cwd: sandbox.projectDir.path);
        final received = <Map<String, Object?>>[];
        final sub = t1.messages.listen(received.add);
        sandbox.onDispose(() async {
          await sub.cancel();
          t1.close();
          if (gcPidFile.existsSync()) {
            final gcPid = int.tryParse(gcPidFile.readAsStringSync().trim());
            if (gcPid != null) _tier5KillPidTree(gcPid);
          }
        });

        t1.write({'id': 1, 'method': 'initialize', 'params': const {}});
        await waitUntil(() => received.any((m) => m['id'] == 1));
        await waitUntil(() => gcPidFile.existsSync());
        final gcPid = int.parse(gcPidFile.readAsStringSync().trim());
        expect(_tier5IsPidAlive(gcPid), isTrue);

        t1.close();
        await t1.exited.timeout(const Duration(seconds: 5));
        expect(
          _tier5IsPidAlive(gcPid),
          isFalse,
          reason:
              'Grandchild PID $gcPid must be killed when ProcessCodexTransport.close() stops .cmd wrapper',
        );

        // Mid-spawn close() must defer exited until in-flight _spawn() settles.
        final midPidLog = File(p.join(sandbox.rootDir.path, 't5_27_mid.pids'));
        final midParent = File(
          p.join(sandbox.rootDir.path, 't5_27_mid_parent.dart'),
        )..writeAsStringSync('''
import 'dart:io';
Future<void> main() async {
  File(${jsonEncode(midPidLog.path)}).writeAsStringSync('\$pid\\n', mode: FileMode.append, flush: true);
  await stdin.transform(const SystemEncoding().decoder).drain<void>();
}
''');
        final midBin = Directory(p.join(sandbox.rootDir.path, 't5_27_mid_bin'))
          ..createSync(recursive: true);
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
        sandbox.useClaudeEnvironment({
          ...sandbox.processEnv,
          'PATH': '${midBin.path}$sep${p.dirname(dartExe)}',
        });

        final t2 = ProcessCodexTransport(cwd: sandbox.projectDir.path);
        sandbox.onDispose(() async {
          t2.close();
          if (midPidLog.existsSync()) {
            for (final line in midPidLog.readAsLinesSync()) {
              final pidVal = int.tryParse(line.trim());
              if (pidVal != null) _tier5KillPidTree(pidVal);
            }
          }
        });

        var exitedEarly = false;
        t2.write({'id': 2, 'method': 'initialize', 'params': const {}});
        unawaited(t2.exited.then((_) => exitedEarly = true));
        t2.close();
        expect(
          exitedEarly,
          isFalse,
          reason:
              'ProcessCodexTransport.exited must not complete in 0ms while _spawn() is still running',
        );
        await t2.exited.timeout(const Duration(seconds: 5));
        expect(exitedEarly, isTrue);
        if (midPidLog.existsSync()) {
          for (final line in midPidLog.readAsLinesSync()) {
            final pidVal = int.tryParse(line.trim());
            if (pidVal != null) expect(_tier5IsPidAlive(pidVal), isFalse);
          }
        }
      },
    );

    test(
      'T5-28 [F5/F4]: LocalCodeBuddy and LocalAntigravity resolve Windows mixed-case Path/AppData and prioritize explicit PATH ahead of APPDATA\\npm and fallback dirs',
      () async {
        final emptyHome = Directory(
          p.join(sandbox.rootDir.path, 't5_28_empty_home'),
        )..createSync(recursive: true);
        final explicitBin = Directory(
          p.join(sandbox.rootDir.path, 't5_28_explicit_bin'),
        )..createSync(recursive: true);
        final appDataDir = Directory(
          p.join(sandbox.rootDir.path, 't5_28_appdata'),
        )..createSync(recursive: true);
        final npmBin = Directory(p.join(appDataDir.path, 'npm'))
          ..createSync(recursive: true);

        final dartExe = resolveDartExecutable();
        final hitLog = File(p.join(sandbox.rootDir.path, 't5_28_hits.log'));

        Future<void> writeProbeCli(Directory dir, String tag) async {
          final script = File(p.join(dir.path, 'probe_$tag.dart'))
            ..writeAsStringSync('''
import 'dart:convert';
import 'dart:io';
Future<void> main() async {
  File(${jsonEncode(hitLog.path)}).writeAsStringSync('$tag\\n', mode: FileMode.append, flush: true);
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    final msg = (jsonDecode(line) as Map).cast<String, Object?>();
    if (msg['type'] == 'control_request') {
      stdout.writeln(jsonEncode({
        'type': 'control_response',
        'response': {
          'subtype': 'success',
          'request_id': msg['request_id'],
          'response': const <String, Object?>{},
        },
      }));
      await stdout.flush();
    }
  }
}
''');
          if (Platform.isWindows) {
            File(p.join(dir.path, 'codebuddy.cmd')).writeAsStringSync(
              '@echo off\r\n"$dartExe" "${script.path}" %*\r\n',
            );
          } else {
            final bin = File(p.join(dir.path, 'codebuddy'))
              ..writeAsStringSync(
                '#!/bin/sh\nexec "$dartExe" "${script.path}" "\$@"\n',
              );
            Process.runSync('chmod', ['+x', bin.path]);
          }
        }

        await writeProbeCli(explicitBin, 'explicit');
        await writeProbeCli(npmBin, 'npm');

        CodeBuddyPathSetting.current = () => null;
        CodeBuddyAccounts.onActiveAccountSwitched = null;

        // 1. Mixed-case 'Path' key on Windows must resolve explicitBin\codebuddy.cmd.
        sandbox.useClaudeEnvironment({
          'HOME': emptyHome.path,
          'USERPROFILE': emptyHome.path,
          if (Platform.isWindows) 'Path': explicitBin.path else 'PATH': explicitBin.path,
          'BAOCODE_DATA_DIR': sandbox.dataDir.path,
          'AYTE_DATA_DIR': sandbox.dataDir.path,
          'AYTE_SESSION_DATA_PATH': sandbox.sessionDataDir.path,
        });
        final tr1 = await CodeBuddyTransport.start(
          ClaudeLaunch(cwd: sandbox.projectDir.path, persist: false),
        );
        sandbox.onDispose(() async {
          tr1.close();
          await tr1.exited.timeout(
            const Duration(seconds: 3),
            onTimeout: () {},
          );
        });
        await waitUntil(() => hitLog.existsSync());
        expect(hitLog.readAsLinesSync(), contains('explicit'));
        tr1.close();
        await tr1.exited.timeout(const Duration(seconds: 3));

        // 2. Explicit PATH must beat APPDATA\npm even when both contain codebuddy.
        hitLog.deleteSync();
        sandbox.useClaudeEnvironment({
          'HOME': emptyHome.path,
          'USERPROFILE': emptyHome.path,
          'PATH': explicitBin.path,
          'APPDATA': appDataDir.path,
          'BAOCODE_DATA_DIR': sandbox.dataDir.path,
          'AYTE_DATA_DIR': sandbox.dataDir.path,
          'AYTE_SESSION_DATA_PATH': sandbox.sessionDataDir.path,
        });
        final tr2 = await CodeBuddyTransport.start(
          ClaudeLaunch(cwd: sandbox.projectDir.path, persist: false),
        );
        sandbox.onDispose(() async {
          tr2.close();
          await tr2.exited.timeout(
            const Duration(seconds: 3),
            onTimeout: () {},
          );
        });
        await waitUntil(() => hitLog.existsSync());
        expect(hitLog.readAsLinesSync(), ['explicit']);
        tr2.close();
        await tr2.exited.timeout(const Duration(seconds: 3));

        // 3. Sibling LocalAntigravity: mixed-case 'Path' + explicit PATH ahead of ~/.gemini/bin.
        AntigravityPathSetting.current = () => null;
        final agyExeName = Platform.isWindows ? 'agy.exe' : 'agy';
        final explicitAgy = File(p.join(explicitBin.path, agyExeName))
          ..writeAsStringSync('');
        final homeAgyDir = Directory(p.join(emptyHome.path, '.gemini', 'bin'))
          ..createSync(recursive: true);
        final homeAgy = File(p.join(homeAgyDir.path, agyExeName))
          ..writeAsStringSync('');

        expect(
          LocalAntigravity.findExecutableForTesting({
            'Home': emptyHome.path,
            'UserProfile': emptyHome.path,
            if (Platform.isWindows) 'Path': explicitBin.path else 'PATH': explicitBin.path,
          }),
          explicitAgy.path,
        );
        expect(
          LocalAntigravity.findExecutableForTesting({
            'HOME': emptyHome.path,
            'USERPROFILE': emptyHome.path,
            if (Platform.isWindows) 'Path': '' else 'PATH': '',
          }),
          homeAgy.path,
        );
      },
    );

    test(
      'T5-29 [F6/F9]: CustomizationStore.list excludes MCP servers and rules from disabled plugins',
      () async {
        final agyConfig = p.join(sandbox.homeDir.path, '.gemini', 'config');
        void writeFile(String path, String content) {
          File(path)
            ..parent.createSync(recursive: true)
            ..writeAsStringSync(content);
        }

        writeFile(
          p.join(agyConfig, 'config.json'),
          jsonEncode({
            'disabledPlugins': ['alpha'],
            'plugins': {
              'beta': {'enabled': false},
              'gamma': {'enabled': true},
            },
          }),
        );

        for (final name in const ['alpha', 'beta', 'gamma']) {
          final plugDir = p.join(agyConfig, 'plugins', name);
          writeFile(p.join(plugDir, 'plugin.json'), jsonEncode({'name': name}));
          writeFile(
            p.join(plugDir, 'skills', '$name-skill', 'SKILL.md'),
            '---\nname: $name-skill\n---\n',
          );
          writeFile(
            p.join(plugDir, 'rules', '$name-rule.md'),
            '# Rule $name\n',
          );
          writeFile(
            p.join(plugDir, 'mcp_config.json'),
            jsonEncode({
              'mcpServers': {
                '$name-srv': {'command': 'npx', 'args': [name]},
              },
            }),
          );
        }

        final store = CustomizationStore(
          configDir: agyConfig,
          homeDir: sandbox.homeDir.path,
        );

        final skills = await store.list(CustomizationKind.skills);
        expect(skills.map((s) => s.name).toList(), ['gamma-skill']);

        final mcps = await store.list(CustomizationKind.mcps);
        expect(mcps.map((m) => m.name).toList(), ['gamma-srv']);

        final rules = await store.list(CustomizationKind.rules);
        expect(
          rules.map((r) => r.name).toList(),
          [p.join('gamma', 'rules', 'gamma-rule.md')],
        );
      },
    );

    testWidgets(
      'T5-30 [F4]: AntigravityAccounts.ensureInitialized inside FakeAsync does not deadlock later root-zone callers',
      (tester) async {
        final accDir = Directory(p.join(sandbox.rootDir.path, 't5_30_agy_accs'))
          ..createSync(recursive: true);
        final acc = AntigravityAccounts(dataDir: accDir.path);
        sandbox.onDispose(acc.dispose);

        final fakeZone = Zone.current;
        final fakeInit = acc.ensureInitialized();
        await tester.pump();

        await tester.runAsync(() async {
          expect(identical(Zone.current, fakeZone), isFalse);
          await acc.ensureInitialized().timeout(const Duration(seconds: 3));
          expect(acc.accounts, isEmpty);
        });

        // Drain the unawaited FakeAsync init future so its async File handle
        // closes cleanly before E2eSandbox.dispose deletes sandbox.rootDir.
        for (var i = 0; i < 10; i++) {
          await tester.pump();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        await tester.runAsync(
          () => fakeInit.timeout(const Duration(seconds: 1), onTimeout: () {}),
        );
      },
    );

    test(
      'T5-31 [F4/F5]: AntigravityAccounts and CodeBuddyAccounts resolve mixed-case Windows Home/UserProfile without falling back to host user dir',
      () async {
        final isoHome = Directory(p.join(sandbox.rootDir.path, 't5_31_iso_home'))
          ..createSync(recursive: true);
        sandbox.useClaudeEnvironment({
          'Home': isoHome.path,
          'UserProfile': isoHome.path,
        });

        final agyAcc = AntigravityAccounts();
        final cbAcc = CodeBuddyAccounts();
        sandbox.onDispose(agyAcc.dispose);
        sandbox.onDispose(cbAcc.dispose);

        await agyAcc.ensureInitialized();
        await cbAcc.ensureInitialized();

        expect(
          agyAcc.dataDirectoryPath,
          p.join(isoHome.path, '.ayte', 'antigravity_accounts'),
        );
        expect(
          cbAcc.dataDirectoryPath,
          p.join(isoHome.path, '.cyte', 'codebuddy_accounts'),
        );

        // Explicit blank mixed-case keys must not fall back to host USERPROFILE.
        final blankCwd = Directory(p.join(sandbox.rootDir.path, 't5_31_blank'))
          ..createSync(recursive: true);
        sandbox.useClaudeEnvironment({'Home': '', 'UserProfile': ''});
        final savedCwd = Directory.current;
        Directory.current = blankCwd;
        try {
          final blankAgy = AntigravityAccounts();
          final blankCb = CodeBuddyAccounts();
          sandbox.onDispose(blankAgy.dispose);
          sandbox.onDispose(blankCb.dispose);
          await blankAgy.ensureInitialized();
          await blankCb.ensureInitialized();
          expect(blankAgy.dataDirectoryPath, p.join('.ayte', 'antigravity_accounts'));
          expect(blankCb.dataDirectoryPath, p.join('.cyte', 'codebuddy_accounts'));
        } finally {
          Directory.current = savedCwd;
        }
      },
    );

    test(
      'T5-32 [F7]: ProcessCodexTransport.stopProcess() stays visible to stopAll() until taskkill completes and awaits mid-flight _inFlightSpawns',
      () async {
        final dartExe = resolveDartExecutable();
        final sleeper = File(p.join(sandbox.rootDir.path, 't5_32_sleeper.dart'))
          ..writeAsStringSync('''
import 'dart:io';
Future<void> main() async {
  await Future<void>.delayed(const Duration(seconds: 30));
}
''');
        final gcPidFile = File(p.join(sandbox.rootDir.path, 't5_32_gc.pid'));
        final parentScript = File(
          p.join(sandbox.rootDir.path, 't5_32_codex_parent.dart'),
        )..writeAsStringSync('''
import 'dart:convert';
import 'dart:io';
Future<void> main() async {
  final proc = await Process.start(${jsonEncode(dartExe)}, [${jsonEncode(sleeper.path)}]);
  File(${jsonEncode(gcPidFile.path)}).writeAsStringSync('\${proc.pid}', flush: true);
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    final msg = (jsonDecode(line) as Map).cast<String, Object?>();
    if (msg['method'] == 'initialize') {
      stdout.writeln(jsonEncode({'id': msg['id'], 'result': <String, Object?>{}}));
      await stdout.flush();
    }
  }
}
''');

        final binDir = Directory(p.join(sandbox.rootDir.path, 't5_32_bin'))
          ..createSync(recursive: true);
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

        final sep = Platform.isWindows ? ';' : ':';
        sandbox.useClaudeEnvironment({
          ...sandbox.processEnv,
          'PATH': '${binDir.path}$sep${p.dirname(dartExe)}',
        });

        final t1 = ProcessCodexTransport(cwd: sandbox.projectDir.path);
        final received = <Map<String, Object?>>[];
        final sub = t1.messages.listen(received.add);
        sandbox.onDispose(() async {
          await sub.cancel();
          t1.close();
          await ProcessCodexTransport.stopAll();
          if (gcPidFile.existsSync()) {
            final gcPid = int.tryParse(gcPidFile.readAsStringSync().trim());
            if (gcPid != null) _tier5KillPidTree(gcPid);
          }
        });

        t1.write({'id': 1, 'method': 'initialize', 'params': const {}});
        await waitUntil(() => received.any((m) => m['id'] == 1));
        await waitUntil(() => gcPidFile.existsSync());
        final gcPid = int.parse(gcPidFile.readAsStringSync().trim());
        expect(_tier5IsPidAlive(gcPid), isTrue);

        unawaited(t1.stopProcess());
        await ProcessCodexTransport.stopAll();
        expect(
          _tier5IsPidAlive(gcPid),
          isFalse,
          reason:
              'Grandchild PID $gcPid must already be dead when stopAll() returns after unawaited stopProcess()',
        );

        // Part 2: mid-spawn stopProcess() must await in-flight _spawn() cleanly.
        final midSpawnPidFile = File(
          p.join(sandbox.rootDir.path, 't5_32_mid_spawn.pid'),
        );
        final midParent = File(
          p.join(sandbox.rootDir.path, 't5_32_mid_parent.dart'),
        )..writeAsStringSync('''
import 'dart:io';
Future<void> main() async {
  File(${jsonEncode(midSpawnPidFile.path)}).writeAsStringSync('\$pid', flush: true);
  await stdin.transform(const SystemEncoding().decoder).drain<void>();
}
''');
        final midBin = Directory(p.join(sandbox.rootDir.path, 't5_32_mid_bin'))
          ..createSync(recursive: true);
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
          ...sandbox.processEnv,
          'PATH': '${midBin.path}$sep${p.dirname(dartExe)}',
        };
        sandbox.useClaudeEnvironment(midEnv);

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
        sandbox.onDispose(() {
          if (!spawnGate.isCompleted) spawnGate.complete();
          NetworkProxy.instance = savedProxy;
        });

        final t2 = ProcessCodexTransport(cwd: sandbox.projectDir.path);
        sandbox.onDispose(() async {
          t2.close();
          await t2.exited;
        });

        t2.write({'id': 2, 'method': 'initialize', 'params': const {}});
        await spawnEntered.future;

        var stopDone = false;
        final stopFut = t2.stopProcess().then((_) => stopDone = true);
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(
          stopDone,
          isFalse,
          reason: 'stopProcess() must not complete while _spawn() is still blocked',
        );

        spawnGate.complete();
        await stopFut.timeout(const Duration(seconds: 3));
        expect(stopDone, isTrue);
        expect(midSpawnPidFile.existsSync(), isFalse);
      },
    );

    test(
      'T5-33 [F4/F5]: Concurrent cross-zone AntigravityAccounts and CodeBuddyAccounts ensureInitialized() calls produce zero duplicates',
      () async {
        final agyDir = Directory(p.join(sandbox.rootDir.path, 't5_33_agy'))
          ..createSync(recursive: true);
        final agyAccountsDir = Directory(p.join(agyDir.path, 'accounts'))
          ..createSync(recursive: true);
        File(p.join(agyAccountsDir.path, 'acc-1.json')).writeAsStringSync(
          jsonEncode({
            'id': 'acc-1',
            'email': 'acc1@example.com',
            'name': 'Acc 1',
            'token': {
              'access_token': 'ya29.acc1',
              'refresh_token': '1//0gacc1',
              'expires_in': 3600,
              'expiry_timestamp': 1900000000,
              'token_type': 'Bearer',
            },
            'created_at': 1700000000,
            'last_used': 1700000100,
          }),
        );
        File(p.join(agyDir.path, 'accounts.json')).writeAsStringSync(
          jsonEncode({
            'version': '2.0',
            'accounts': [
              {
                'id': 'acc-1',
                'email': 'acc1@example.com',
                'name': 'Acc 1',
                'disabled': false,
                'created_at': 1700000000,
                'last_used': 1700000100,
              },
            ],
            'current_account_id': 'acc-1',
          }),
        );

        final agyStore = AntigravityAccounts(dataDir: agyDir.path);
        sandbox.onDispose(agyStore.dispose);
        await Future.wait([
          runZoned(() => agyStore.ensureInitialized()),
          runZoned(() => agyStore.ensureInitialized()),
          runZoned(() => agyStore.ensureInitialized()),
        ]);
        expect(agyStore.accounts.map((a) => a.id).toList(), ['acc-1']);
        expect(agyStore.currentAccountId, 'acc-1');
        final agyExported =
            jsonDecode(agyStore.exportAccountsJson()) as Map<String, Object?>;
        expect(agyExported['accounts'], hasLength(1));

        final cbDir = Directory(p.join(sandbox.rootDir.path, 't5_33_cb'))
          ..createSync(recursive: true);
        final cbAccountsDir = Directory(p.join(cbDir.path, 'accounts'))
          ..createSync(recursive: true);
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        File(p.join(cbAccountsDir.path, 'cb-1.json')).writeAsStringSync(
          jsonEncode({
            'id': 'cb-1',
            'uid': 'u-cb-1',
            'nickname': 'CB 1',
            'region': 'cn',
            'endpoint': 'https://copilot.tencent.com',
            'auth': {'kind': 'authToken', 'access_token': 'tok-cb-1'},
            'created_at': now,
            'last_used': now,
          }),
        );
        File(p.join(cbDir.path, 'accounts.json')).writeAsStringSync(
          jsonEncode({
            'current_account_id': 'cb-1',
            'accounts': [
              {'id': 'cb-1', 'uid': 'u-cb-1', 'nickname': 'CB 1', 'region': 'cn'},
            ],
          }),
        );

        final cbStore = CodeBuddyAccounts(dataDir: cbDir.path);
        sandbox.onDispose(cbStore.dispose);
        await Future.wait([
          runZoned(() => cbStore.ensureInitialized()),
          runZoned(() => cbStore.ensureInitialized()),
          runZoned(() => cbStore.ensureInitialized()),
        ]);
        expect(cbStore.accounts.map((a) => a.id).toList(), ['cb-1']);
        expect(cbStore.currentAccountId, 'cb-1');
        final cbExported =
            jsonDecode(cbStore.exportAccountsJson()) as Map<String, Object?>;
        expect(cbExported['accounts'], hasLength(1));
      },
    );

    test(
      'T5-34 [F9]: ClaudeConversationSearch resolves Windows mixed-case env vars and honors explicit blank keys without host fallback',
      () async {
        final isoHome = Directory(p.join(sandbox.rootDir.path, 't5_34_home'))
          ..createSync(recursive: true);
        final customAyte = Directory(p.join(sandbox.rootDir.path, 't5_34_ayte'))
          ..createSync(recursive: true);
        final customClaude = Directory(
          p.join(sandbox.rootDir.path, 't5_34_claude'),
        )..createSync(recursive: true);
        final customCodex = Directory(p.join(sandbox.rootDir.path, 't5_34_codex'))
          ..createSync(recursive: true);
        const token = 't5_34_mixed_case_env_token';

        File(p.join(customAyte.path, 'projects', '-p', 'sess-ayte.jsonl'))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(
            '${jsonEncode({'type': 'user', 'message': {'role': 'user', 'content': '$token ayte'}})}\n',
          );
        File(p.join(customClaude.path, 'projects', '-p', 'sess-claude.jsonl'))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(
            '${jsonEncode({'type': 'user', 'message': {'role': 'user', 'content': '$token claude'}})}\n',
          );
        File(p.join(isoHome.path, '.codebuddy', 'projects', '-p', 'sess-cb.jsonl'))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(
            '${jsonEncode({'type': 'user', 'message': {'role': 'user', 'content': '$token cb'}})}\n',
          );
        File(
          p.join(
            isoHome.path,
            '.gemini',
            'antigravity-cli',
            'brain',
            'sess-agy',
            '.system_generated',
            'logs',
            'transcript.jsonl',
          ),
        )
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(
            '${jsonEncode({'type': 'USER_INPUT', 'content': '<USER_REQUEST>$token agy</USER_REQUEST>'})}\n',
          );
        File(
          p.join(
            customCodex.path,
            'sessions',
            '2026',
            '11',
            '23',
            'rollout-2026-11-23T01-00-00-sess-codex.jsonl',
          ),
        )
          ..parent.createSync(recursive: true)
          ..writeAsStringSync([
            jsonEncode({
              'type': 'session_meta',
              'payload': {'id': 'sess-codex', 'cwd': isoHome.path},
            }),
            jsonEncode({
              'type': 'event_msg',
              'payload': {'type': 'user_message', 'message': '$token codex'},
            }),
          ].join('\n'));

        sandbox.useClaudeEnvironment({
          'Home': isoHome.path,
          'UserProfile': isoHome.path,
          'Ayte_Session_Data_Path': customAyte.path,
          'Claude_Config_Dir': customClaude.path,
          'Codex_Home': customCodex.path,
        });

        final search = ClaudeConversationSearch();
        await search.prepare();
        final hits = await search.search(token);
        expect(
          hits.map((h) => h.sessionId).toSet(),
          containsAll(['sess-ayte', 'sess-claude', 'sess-cb', 'sess-agy', 'sess-codex']),
        );

        sandbox.useClaudeEnvironment({
          'Home': '',
          'UserProfile': '',
          'Ayte_Session_Data_Path': '',
          'Claude_Config_Dir': '',
          'Codex_Home': '',
        });
        final blankSearch = ClaudeConversationSearch();
        await blankSearch.prepare();
        expect(await blankSearch.search(token), isEmpty);
        expect(await blankSearch.search('a'), isEmpty);
      },
    );

    test(
      'T5-35 [F2/F4]: AntigravityTransport.close() and stopAll() kill Windows child/grandchild process trees and defer exited until process and artifact cleanup completes',
      () async {
        final dartExe = resolveDartExecutable();
        final lockedCwd = Directory(
          p.join(sandbox.rootDir.path, 't5_35_locked_cwd'),
        )..createSync(recursive: true);
        final lockFilePath = p.join(lockedCwd.path, 'held.lock');
        final gcPidFile = File(p.join(sandbox.rootDir.path, 't5_35_gc.pid'));
        final sleeper = File(p.join(sandbox.rootDir.path, 't5_35_sleeper.dart'))
          ..writeAsStringSync('''
import 'dart:io';
Future<void> main(List<String> args) async {
  final lockPath = args.first;
  final raf = File(lockPath).openSync(mode: FileMode.write);
  raf.writeStringSync('locked');
  File(${jsonEncode(gcPidFile.path)}).writeAsStringSync('\$pid', flush: true);
  await Future<void>.delayed(const Duration(seconds: 30));
  raf.closeSync();
}
''');

        final parentSrc = File(
          p.join(sandbox.rootDir.path, 't5_35_agy_parent.dart'),
        )..writeAsStringSync('''
import 'dart:convert';
import 'dart:io';
Future<void> main(List<String> args) async {
  final lockPath = Platform.environment['AGY_LOCK_FILE'] ?? '';
  await Process.start(${jsonEncode(dartExe)}, [${jsonEncode(sleeper.path)}, lockPath]);
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    stdout.writeln(jsonEncode({'event': 'init', 'conversation_id': 'conv-t5-35'}));
    stdout.writeln(jsonEncode({
      'event': 'result',
      'result': {'conversation_id': 'conv-t5-35', 'status': 'SUCCESS', 'response': 'ok'},
    }));
    await stdout.flush();
  }
}
''');

        final String agyExePath;
        if (Platform.isWindows) {
          final compiled = p.join(sandbox.rootDir.path, 't5_35_fake_agy.exe');
          final compileRes = Process.runSync(dartExe, [
            'compile',
            'exe',
            parentSrc.path,
            '-o',
            compiled,
          ]);
          expect(compileRes.exitCode, 0, reason: '${compileRes.stderr}');
          agyExePath = compiled;
        } else {
          final sh = File(p.join(sandbox.rootDir.path, 't5_35_fake_agy.sh'))
            ..writeAsStringSync(
              '#!/bin/sh\nexec "$dartExe" "${parentSrc.path}" "\$@"\n',
            );
          Process.runSync('chmod', ['+x', sh.path]);
          agyExePath = sh.path;
        }

        sandbox.onDispose(() async {
          await AntigravityTransport.stopAll();
          if (gcPidFile.existsSync()) {
            final gcPid = int.tryParse(gcPidFile.readAsStringSync().trim());
            if (gcPid != null) _tier5KillPidTree(gcPid);
          }
        });

        // Part 1: close() + await exited kills grandchild tree and unlocks cwd immediately.
        final tr1 = AntigravityTransport.forTesting(
          executable: agyExePath,
          environment: {
            ...sandbox.processEnv,
            'AGY_LOCK_FILE': lockFilePath,
          },
          launch: ClaudeLaunch(
            cwd: lockedCwd.path,
            persist: false,
            instructions: 'T5-35 artifact cleanup test',
          ),
        );
        final results1 = <Map<String, Object?>>[];
        final sub1 = tr1.messages.listen(results1.add);
        sandbox.onDispose(() => unawaited(sub1.cancel()));

        tr1.write({
          'type': 'user',
          'uuid': 'u-t5-35-1',
          'message': {'role': 'user', 'content': 'turn 1'},
        });
        await waitUntil(() => results1.any((m) => m['type'] == 'result'));
        await waitUntil(() => gcPidFile.existsSync());
        final gcPid1 = int.parse(gcPidFile.readAsStringSync().trim());
        expect(_tier5IsPidAlive(gcPid1), isTrue);

        tr1.close();
        await tr1.exited.timeout(const Duration(seconds: 5));
        expect(tr1.sessionConfigDirForTesting, isNull);
        expect(
          _tier5IsPidAlive(gcPid1),
          isFalse,
          reason: 'Grandchild PID $gcPid1 must be dead before exited completes',
        );
        lockedCwd.deleteSync(recursive: true);
        expect(lockedCwd.existsSync(), isFalse);

        // Part 2: stopAll() after unawaited stopProcessForTesting() awaits tree termination.
        gcPidFile.deleteSync();
        final lockedCwd2 = Directory(
          p.join(sandbox.rootDir.path, 't5_35_locked_cwd_2'),
        )..createSync(recursive: true);
        final lockFilePath2 = p.join(lockedCwd2.path, 'held.lock');
        final tr2 = AntigravityTransport.forTesting(
          executable: agyExePath,
          environment: {
            ...sandbox.processEnv,
            'AGY_LOCK_FILE': lockFilePath2,
          },
          launch: ClaudeLaunch(cwd: lockedCwd2.path, persist: false),
        );
        final results2 = <Map<String, Object?>>[];
        final sub2 = tr2.messages.listen(results2.add);
        sandbox.onDispose(() => unawaited(sub2.cancel()));

        tr2.write({
          'type': 'user',
          'uuid': 'u-t5-35-2',
          'message': {'role': 'user', 'content': 'turn 2'},
        });
        await waitUntil(() => results2.any((m) => m['type'] == 'result'));
        await waitUntil(() => gcPidFile.existsSync());
        final gcPid2 = int.parse(gcPidFile.readAsStringSync().trim());
        expect(_tier5IsPidAlive(gcPid2), isTrue);

        unawaited(tr2.stopProcessForTesting());
        await AntigravityTransport.stopAll();
        expect(
          _tier5IsPidAlive(gcPid2),
          isFalse,
          reason:
              'Grandchild PID $gcPid2 must be dead when AntigravityTransport.stopAll() returns',
        );
        lockedCwd2.deleteSync(recursive: true);
        expect(lockedCwd2.existsSync(), isFalse);

        // Part 3: mid-flight setup/Process.start close() defers exited until aborted spawn cleans up.
        final midPidFile = File(p.join(sandbox.rootDir.path, 't5_35_mid.pid'));
        final midAgy = FakeCliExecutable.create(
          sandbox.rootDir,
          name: 't5_35_mid_agy',
          dartBody: '''
Future<void> main(List<String> args) async {
  File(${jsonEncode(midPidFile.path)}).writeAsStringSync('\$pid\\n', mode: FileMode.append, flush: true);
  await stdin.transform(utf8.decoder).drain<void>();
}
''',
        );
        for (final delayMs in const [0, 2, 5, 10]) {
          final trMid = AntigravityTransport.forTesting(
            executable: midAgy.executablePath,
            environment: sandbox.processEnv,
            launch: ClaudeLaunch(
              cwd: sandbox.projectDir.path,
              persist: false,
              sdkServers: const [ClaudeSdkTools.server],
              instructions: 'Mid-spawn close race $delayMs',
            ),
          );
          trMid.write({
            'type': 'user',
            'uuid': 'u-mid-$delayMs',
            'message': {'role': 'user', 'content': 'hello'},
          });
          if (delayMs > 0) {
            await Future<void>.delayed(Duration(milliseconds: delayMs));
          }
          trMid.close();
          await trMid.exited.timeout(const Duration(seconds: 5));
          expect(trMid.sdkBridgeForTesting, isNull);
          expect(trMid.sessionConfigDirForTesting, isNull);
        }
        if (midPidFile.existsSync()) {
          for (final line in midPidFile.readAsLinesSync()) {
            final spawnedPid = int.tryParse(line.trim());
            if (spawnedPid != null) {
              expect(
                _tier5IsPidAlive(spawnedPid),
                isFalse,
                reason: 'Mid-spawn PID $spawnedPid must be dead after exited',
              );
            }
          }
        }
      },
    );

    test(
      'T5-36 [F5]: CodeBuddyAccounts.ensureInitialized() under FLUTTER_TEST loads disk accounts without background HTTP refreshAllQuotas, while explicit refreshAllQuotas() still runs',
      () async {
        final cbDir = Directory(p.join(sandbox.rootDir.path, 't5_36_cb'))
          ..createSync(recursive: true);
        final accountsDir = Directory(p.join(cbDir.path, 'accounts'))
          ..createSync(recursive: true);
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        File(p.join(accountsDir.path, 'cb-quiet.json')).writeAsStringSync(
          jsonEncode({
            'id': 'cb-quiet',
            'uid': 'u-quiet',
            'nickname': 'Quiet CB',
            'region': 'cn',
            'endpoint': 'https://copilot.tencent.com',
            'auth': {'kind': 'authToken', 'access_token': 'tok-quiet'},
            'created_at': now,
            'last_used': now,
          }),
        );
        File(p.join(cbDir.path, 'accounts.json')).writeAsStringSync(
          jsonEncode({
            'current_account_id': 'cb-quiet',
            'accounts': [
              {
                'id': 'cb-quiet',
                'uid': 'u-quiet',
                'nickname': 'Quiet CB',
                'region': 'cn',
              },
            ],
          }),
        );

        var httpOpenCount = 0;
        final savedOverrides = HttpOverrides.current;
        HttpOverrides.global = _Tier5CountingHttpOverrides(
          () => httpOpenCount++,
        );
        sandbox.onDispose(() => HttpOverrides.global = savedOverrides);

        final store = CodeBuddyAccounts(dataDir: cbDir.path);
        sandbox.onDispose(store.dispose);

        await store.ensureInitialized();
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(Platform.environment.containsKey('FLUTTER_TEST'), isTrue);
        expect(store.accounts.map((a) => a.id).toList(), ['cb-quiet']);
        expect(store.isRefreshingAll, isFalse);
        expect(httpOpenCount, 0);
        expect(store.lastRefreshError, isNull);

        await store.refreshAllQuotas();
        expect(httpOpenCount, greaterThan(0));
      },
    );

    test(
      'T5-37 [F10]: AyteIpcServer POST /sessions and ayte-cli.py normalize CLI aliases (agy/claude/codebuddy/codex) and reject unknown kernels with HTTP 400',
      () async {
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
          create: (_) => _Tier5IpcSessionKernel(
            codexK,
            onSend: (text) => dispatched.add(('codex', text)),
          ),
        );
        agyK = KernelDescriptor(
          id: 'antigravity-cli',
          label: 'Antigravity',
          icon: Icons.rocket_launch_rounded,
          description: '',
          create: (_) => _Tier5IpcSessionKernel(
            agyK,
            onSend: (text) => dispatched.add(('antigravity-cli', text)),
          ),
        );
        claudeK = KernelDescriptor(
          id: 'claude-code',
          label: 'Claude Code',
          icon: Icons.terminal_rounded,
          description: '',
          create: (_) => _Tier5IpcSessionKernel(
            claudeK,
            onSend: (text) => dispatched.add(('claude-code', text)),
          ),
        );
        cbK = KernelDescriptor(
          id: 'codebuddy-cli',
          label: 'CodeBuddy',
          icon: Icons.auto_awesome_rounded,
          description: '',
          create: (_) => _Tier5IpcSessionKernel(
            cbK,
            onSend: (text) => dispatched.add(('codebuddy-cli', text)),
          ),
        );

        final ws = Workspace(
          kernels: [codexK, agyK, claudeK, cbK],
          projects: [Project('proj', sandbox.projectDir.path)],
        );
        sandbox.onDispose(ws.dispose);

        final ipc = AyteIpcServer.instance
          ..homeOverride = sandbox.homeDir.path
          ..workspace = ws;
        await ipc.start();
        expect(ipc.running, isTrue);
        expect(await ipc.installCli(), isTrue);
        sandbox.onDispose(() async {
          ipc.workspace = null;
          await ipc.stop();
          await ipc.uninstallCli();
        });

        final info =
            jsonDecode(File(ipc.ipcInfoPath).readAsStringSync()) as Map;
        final port = info['port'] as int;
        final token = info['token'] as String;
        final sessionsUri = Uri.parse('http://127.0.0.1:$port/sessions');

        // Unknown kernel must fail with HTTP 400 and dispatch nothing.
        final badRes = await McpHttpProbe(
          sessionsUri,
          bearerToken: token,
        ).postJsonRpc({
          'prompt': 'Must not dispatch',
          'cwd': sandbox.projectDir.path,
          'kernel': 'nonexistent',
        });
        expect(badRes.statusCode, 400);
        expect('${badRes.json?['error']}', contains('nonexistent'));
        expect(dispatched, isEmpty);

        // HTTP alias check: antigravity -> antigravity-cli.
        final agyRes = await McpHttpProbe(
          sessionsUri,
          bearerToken: token,
        ).postJsonRpc({
          'prompt': 'HTTP antigravity prompt',
          'cwd': sandbox.projectDir.path,
          'kernel': 'antigravity',
        });
        expect(agyRes.statusCode, 200);
        expect((agyRes.json?['session'] as Map)['kernel'], 'antigravity-cli');
        expect(dispatched.last, ('antigravity-cli', 'HTTP antigravity prompt'));

        // Live Python ayte-cli.py verification (default -a agy, -a claude, -a codebuddy, -a codex).
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
            // Try next candidate.
          }
        }
        if (pyExe != null) {
          final cliEnv = <String, String>{
            ...sandbox.processEnv,
            'HOME': sandbox.homeDir.path,
            'USERPROFILE': sandbox.homeDir.path,
          };
          Future<ProcessResult> runCli(List<String> args) => Process.run(
            pyExe!,
            [...pyPrefix, ipc.cliScriptPath, ...args],
            environment: cliEnv,
          );

          final defRes = await runCli([
            'sessions',
            'new',
            '-p',
            'Default agy CLI prompt',
            '--cwd',
            sandbox.projectDir.path,
            '--json',
          ]);
          expect(defRes.exitCode, 0, reason: '${defRes.stderr}');
          final defJson = jsonDecode('${defRes.stdout}') as Map;
          expect((defJson['session'] as Map)['kernel'], 'antigravity-cli');
          expect(dispatched.last, ('antigravity-cli', 'Default agy CLI prompt'));

          for (final (agentFlag, expectedKernel) in const [
            ('claude', 'claude-code'),
            ('codebuddy', 'codebuddy-cli'),
            ('codex', 'codex'),
          ]) {
            final cliRes = await runCli([
              'sessions',
              'new',
              '-a',
              agentFlag,
              '-p',
              'CLI $agentFlag prompt',
              '--cwd',
              sandbox.projectDir.path,
              '--json',
            ]);
            expect(cliRes.exitCode, 0, reason: '${cliRes.stderr}');
            final cliJson = jsonDecode('${cliRes.stdout}') as Map;
            expect((cliJson['session'] as Map)['kernel'], expectedKernel);
            expect(dispatched.last, (expectedKernel, 'CLI $agentFlag prompt'));
          }
        }
      },
    );

    test(
      'T5-38 [F7/F8]: CodexCatalog.resolveHome() and CodexModels.loadLocalCatalog() fall back empty CODEX_HOME="" to <HOME>/.codex instead of CWD',
      () async {
        final isolatedHome = Directory(
          p.join(sandbox.rootDir.path, 't5_38_home'),
        )..createSync(recursive: true);
        final dotCodex = Directory(p.join(isolatedHome.path, '.codex'))
          ..createSync(recursive: true);

        File(p.join(dotCodex.path, 'models_cache.json')).writeAsStringSync(
          jsonEncode({
            'models': [
              {
                'slug': 'gpt-5.4-t538',
                'display_name': 'GPT-5.4 T5-38',
                'description': 'Loaded from <HOME>/.codex',
              },
            ],
          }),
        );
        final rollout = File(
          p.join(
            dotCodex.path,
            'sessions',
            '2026',
            '11',
            '23',
            'rollout-2026-11-23T02-00-00-t538-sess.jsonl',
          ),
        )..parent.createSync(recursive: true);
        rollout.writeAsStringSync(
          '${jsonEncode({
            'timestamp': '2026-11-23T02:00:00Z',
            'type': 'session_meta',
            'payload': {
              'id': 't538-sess',
              'cwd': sandbox.projectDir.path,
            },
          })}\n'
          '${jsonEncode({
            'timestamp': '2026-11-23T02:00:01Z',
            'type': 'event_msg',
            'payload': {
              'type': 'user_message',
              'message': 'Fallback from empty CODEX_HOME',
            },
          })}\n',
        );

        // Explicit blank codexHome + blank CODEX_HOME must fall back to <HOME>/.codex.
        final cat = CodexCatalog(
          codexHome: '',
          environment: {'CODEX_HOME': '', 'HOME': isolatedHome.path},
        );
        expect(cat.resolveHome(), dotCodex.path);
        final sessions = await cat.sessionsIn(sandbox.projectDir.path);
        expect(sessions.map((s) => s.id).toList(), ['t538-sess']);

        // Windows mixed-case Codex_Home="" + Home resolves <Home>\.codex.
        expect(
          CodexCatalog.resolveHomeFromEnv(
            {'Codex_Home': '', 'Home': r'C:\Users\T538'},
            codexHome: '',
            forceWindows: true,
          ),
          r'C:\Users\T538\.codex',
        );

        // Explicit blank HOME & USERPROFILE returns '' rather than CWD-relative '.codex'.
        expect(
          CodexCatalog.resolveHomeFromEnv(
            {'CODEX_HOME': '', 'HOME': '', 'USERPROFILE': ''},
          ),
          '',
        );

        // CodexModels.loadLocalCatalog('') with CODEX_HOME='' loads from <HOME>/.codex.
        final modelsRes = CodexModels.loadLocalCatalog(
          codexHome: '',
          environment: {'CODEX_HOME': '', 'HOME': isolatedHome.path},
        );
        expect(modelsRes.models.map((m) => m.id).toList(), ['gpt-5.4-t538']);

        // Also ensure default constructor with empty codexHome never returns ''.
        if ((Platform.environment['HOME'] ??
                    Platform.environment['USERPROFILE'] ??
                    '')
                .trim()
                .isNotEmpty) {
          expect(const CodexCatalog(codexHome: '').resolveHome(), isNotEmpty);
        }
      },
    );

    test(
      'T5-39 [F5/Claude]: ClaudeCliTransport honors mixed-case Windows Path/UserProfile, kills grandchild trees on close()/stopAll(), and deletes temp settings after exit',
      () async {
        final dartExe = resolveDartExecutable();
        final fakeBin = Directory(p.join(sandbox.rootDir.path, 't5_39_bin'))
          ..createSync(recursive: true);
        final fakeHome = Directory(p.join(sandbox.rootDir.path, 't5_39_home'))
          ..createSync(recursive: true);
        final gcPidFile = File(p.join(sandbox.rootDir.path, 't5_39_gc.pid'));
        final launchLog = File(
          p.join(sandbox.rootDir.path, 't5_39_launch.json'),
        );

        final sleeper = File(p.join(sandbox.rootDir.path, 't5_39_sleeper.dart'))
          ..writeAsStringSync('''
import 'dart:io';
Future<void> main() async {
  File(${jsonEncode(gcPidFile.path)}).writeAsStringSync('\$pid', flush: true);
  await Future<void>.delayed(const Duration(seconds: 30));
}
''');

        final parentScript = File(
          p.join(sandbox.rootDir.path, 't5_39_claude.dart'),
        )..writeAsStringSync('''
import 'dart:convert';
import 'dart:io';
Future<void> main(List<String> args) async {
  File(${jsonEncode(launchLog.path)}).writeAsStringSync(
    jsonEncode({'args': args, 'envPath': Platform.environment['PATH']}),
    flush: true,
  );
  await Process.start(${jsonEncode(dartExe)}, [${jsonEncode(sleeper.path)}]);
  stdout.writeln(jsonEncode({'type': 'system', 'subtype': 'init', 'session_id': 'c-t539'}));
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

        sandbox.useClaudeEnvironment({
          if (Platform.isWindows) 'Path': fakeBin.path else 'PATH': fakeBin.path,
          if (Platform.isWindows)
            'UserProfile': fakeHome.path
          else
            'HOME': fakeHome.path,
          if (Platform.isWindows && Platform.environment['SystemRoot'] != null)
            'SystemRoot': Platform.environment['SystemRoot']!,
        });

        final tr = (await ClaudeCliTransport.start(
          ClaudeLaunch(
            cwd: sandbox.projectDir.path,
            persist: false,
            env: const {'ANTHROPIC_API_KEY': 'sk-t539-test'},
          ),
        )) as ClaudeCliTransport;
        sandbox.onDispose(() async {
          tr.close();
          await ClaudeCliTransport.stopAll();
          if (gcPidFile.existsSync()) {
            final pidVal = int.tryParse(gcPidFile.readAsStringSync().trim());
            if (pidVal != null) _tier5KillPidTree(pidVal);
          }
        });

        final settingsPath = tr.settingsFilePathForTesting;
        expect(settingsPath, isNotNull);
        expect(File(settingsPath!).existsSync(), isTrue);

        await waitUntil(
          () => gcPidFile.existsSync() && launchLog.existsSync(),
          reason: 'Fake claude and grandchild sleeper should start',
        );
        final gcPid = int.parse(gcPidFile.readAsStringSync().trim());
        expect(_tier5IsPidAlive(gcPid), isTrue);

        final captured = jsonDecode(launchLog.readAsStringSync()) as Map;
        expect(captured['envPath'], fakeBin.path);

        tr.close();
        await ClaudeCliTransport.stopAll();
        await tr.exited.timeout(const Duration(seconds: 5));

        expect(
          _tier5IsPidAlive(gcPid),
          isFalse,
          reason: 'Grandchild PID $gcPid must be dead after close()+stopAll()',
        );
        expect(File(settingsPath).existsSync(), isFalse);
      },
    );

    test(
      'T5-40 [F5]: CodeBuddyTransport.close() followed immediately by stopAll() kills Windows parent/grandchild trees, deletes API-key settings file, and completes exited before stopAll() returns',
      () async {
        final dartExe = resolveDartExecutable();
        final accDir = Directory(p.join(sandbox.rootDir.path, 't5_40_cb_acc'))
          ..createSync(recursive: true);
        final accounts = CodeBuddyAccounts(dataDir: accDir.path);
        await accounts.ensureInitialized();
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        await accounts.upsertAccount(
          CodeBuddyAccount(
            id: 't5-40-apikey',
            uid: 'uid-t5-40',
            nickname: 'T5-40 API Key',
            region: CodeBuddyRegion.cn,
            endpoint: CodeBuddyRegion.cn.defaultEndpoint,
            auth: const CodeBuddyAuthData(
              kind: CodeBuddyAuthKind.apiKey,
              apiKey: 'cb-secret-t5-40',
            ),
            createdAt: now,
            lastUsed: now,
          ),
          makeActive: true,
        );

        final parentPidFile = File(
          p.join(sandbox.rootDir.path, 't5_40_parent.pid'),
        );
        final gcPidFile = File(p.join(sandbox.rootDir.path, 't5_40_gc.pid'));
        final sleeper = File(p.join(sandbox.rootDir.path, 't5_40_sleeper.dart'))
          ..writeAsStringSync('''
import 'dart:io';
Future<void> main() async {
  File(${jsonEncode(gcPidFile.path)}).writeAsStringSync('\$pid', flush: true);
  await Future<void>.delayed(const Duration(seconds: 30));
}
''');

        final parentScript = File(
          p.join(sandbox.rootDir.path, 't5_40_cb_parent.dart'),
        )..writeAsStringSync('''
import 'dart:convert';
import 'dart:io';
Future<void> main(List<String> args) async {
  File(${jsonEncode(parentPidFile.path)}).writeAsStringSync('\$pid', flush: true);
  await Process.start(${jsonEncode(dartExe)}, [${jsonEncode(sleeper.path)}]);
  stdout.writeln(jsonEncode({'type': 'system', 'subtype': 'init', 'session_id': 'cb-t5-40'}));
  await stdout.flush();
  await stdin.transform(utf8.decoder).drain<void>();
}
''');

        final fakeBin = Directory(p.join(sandbox.rootDir.path, 't5_40_bin'))
          ..createSync(recursive: true);
        final String cbExe;
        final bool throughShell;
        if (Platform.isWindows) {
          final cmd = File(p.join(fakeBin.path, 'codebuddy.cmd'))
            ..writeAsStringSync(
              '@echo off\r\n"$dartExe" "${parentScript.path}" %*\r\n',
            );
          cbExe = cmd.path;
          throughShell = true;
        } else {
          final sh = File(p.join(fakeBin.path, 'codebuddy'))
            ..writeAsStringSync(
              '#!/bin/sh\nexec "$dartExe" "${parentScript.path}" "\$@"\n',
            );
          Process.runSync('chmod', ['+x', sh.path]);
          cbExe = sh.path;
          throughShell = false;
        }

        final transport = CodeBuddyTransport.forTesting(
          cli: CodeBuddyCli(
            executable: cbExe,
            environment: sandbox.processEnv,
            throughShell: throughShell,
          ),
          launch: ClaudeLaunch(cwd: sandbox.projectDir.path, persist: false),
          accounts: accounts,
        );
        sandbox.onDispose(() async {
          transport.close();
          await CodeBuddyTransport.stopAll();
          accounts.dispose();
          for (final pf in [parentPidFile, gcPidFile]) {
            if (pf.existsSync()) {
              final pidVal = int.tryParse(pf.readAsStringSync().trim());
              if (pidVal != null) _tier5KillPidTree(pidVal);
            }
          }
        });

        var exitedDone = false;
        unawaited(transport.exited.then((_) => exitedDone = true));

        await transport.spawnForTesting();
        final settingsPath = transport.settingsFilePathForTesting;
        expect(settingsPath, isNotNull);
        expect(
          p.basename(p.dirname(settingsPath!)),
          startsWith('baocode-settings-'),
        );
        expect(p.basename(settingsPath), startsWith('settings-'));
        expect(File(settingsPath).existsSync(), isTrue);

        await waitUntil(
          () => parentPidFile.existsSync() && gcPidFile.existsSync(),
          reason: 'Fake CodeBuddy parent and grandchild sleeper should start',
        );
        final parentPid = int.parse(parentPidFile.readAsStringSync().trim());
        final gcPid = int.parse(gcPidFile.readAsStringSync().trim());
        expect(_tier5IsPidAlive(parentPid), isTrue);
        expect(_tier5IsPidAlive(gcPid), isTrue);

        transport.close();
        await CodeBuddyTransport.stopAll();

        expect(
          exitedDone,
          isTrue,
          reason: 'transport.exited must be completed when stopAll() returns',
        );
        expect(
          _tier5IsPidAlive(parentPid),
          isFalse,
          reason: 'Parent PID $parentPid must be dead when stopAll() returns',
        );
        expect(
          _tier5IsPidAlive(gcPid),
          isFalse,
          reason: 'Grandchild PID $gcPid must be dead when stopAll() returns',
        );
        expect(
          File(settingsPath).existsSync(),
          isFalse,
          reason:
              'Temp API-key settings file $settingsPath must be deleted when stopAll() returns',
        );
      },
    );

    test(
      'T5-41 [F10]: AyteIpcServer POST /prompt and POST /tasks normalize aliases to canonical IDs and reject unknown agents with HTTP 400',
      () async {
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

        final ipc = AyteIpcServer.instance..homeOverride = sandbox.homeDir.path;
        await ipc.start();
        expect(ipc.running, isTrue);
        sandbox.onDispose(() async {
          await ipc.stop();
          ipc.homeOverride = null;
        });

        final info =
            jsonDecode(File(ipc.ipcInfoPath).readAsStringSync()) as Map;
        final port = info['port'] as int;
        final token = info['token'] as String;
        final baseUri = Uri.parse('http://127.0.0.1:$port');

        // 1. POST /prompt with 'claude-code' normalizes to 'claude'.
        final promptAlias = await McpHttpProbe(
          baseUri.replace(path: '/prompt'),
          bearerToken: token,
        ).postJsonRpc({
          'agent': 'claude-code',
          'prompt': 'Run claude alias',
          'cwd': sandbox.projectDir.path,
        });
        expect(promptAlias.statusCode, 200);
        expect(promptAlias.json?['ok'], isTrue);
        expect(promptAlias.json?['agent'], 'claude');
        expect(promptAlias.json?['output'], 'ran:claude');
        expect(executed.last, ('claude', 'Run claude alias'));

        // 2. POST /prompt with 'nonexistent' returns HTTP 400 and executes nothing.
        final execCountBeforeBadPrompt = executed.length;
        final promptUnknown = await McpHttpProbe(
          baseUri.replace(path: '/prompt'),
          bearerToken: token,
        ).postJsonRpc({
          'agent': 'nonexistent',
          'prompt': 'Must not execute',
          'cwd': sandbox.projectDir.path,
        });
        expect(promptUnknown.statusCode, 400);
        expect('${promptUnknown.json?['error']}', contains('nonexistent'));
        expect(executed.length, execCountBeforeBadPrompt);

        // 3. POST /tasks with {agent: 'claude-code'} and {agentId: 'claude-code'} normalize to 'claude' and run as 'claude'.
        for (final body in [
          {
            'title': 'Claude alias via agent',
            'prompt': 'Task via agent',
            'cwd': sandbox.projectDir.path,
            'agent': 'claude-code',
            'useWorktree': false,
          },
          {
            'title': 'Claude alias via agentId',
            'prompt': 'Task via agentId',
            'cwd': sandbox.projectDir.path,
            'agentId': 'claude-code',
            'useWorktree': false,
          },
        ]) {
          final taskRes = await McpHttpProbe(
            baseUri.replace(path: '/tasks'),
            bearerToken: token,
          ).postJsonRpc(body);
          expect(taskRes.statusCode, 200);
          final taskJson = taskRes.json?['task'] as Map;
          expect(taskJson['agentId'], 'claude');
          final taskId = taskJson['id'] as String;
          await TaskQueueService.instance.runTask(taskId);
          expect(executed.last.$1, 'claude');
          final handoff = await TaskQueueService.instance.buildChatHandoff(
            taskId,
            isZh: false,
          );
          expect(handoff?.kernelId, 'claude-code');
        }

        // 4. POST /tasks with {agent: 'nonexistent'} and {agentId: 'nonexistent'} return HTTP 400 and enqueue nothing.
        final taskCountBefore = TaskQueueService.instance.tasks.length;
        for (final body in [
          {
            'prompt': 'Must not enqueue agent',
            'cwd': sandbox.projectDir.path,
            'agent': 'nonexistent',
          },
          {
            'prompt': 'Must not enqueue agentId',
            'cwd': sandbox.projectDir.path,
            'agentId': 'nonexistent',
          },
        ]) {
          final badTask = await McpHttpProbe(
            baseUri.replace(path: '/tasks'),
            bearerToken: token,
          ).postJsonRpc(body);
          expect(badTask.statusCode, 400);
          expect('${badTask.json?['error']}', contains('nonexistent'));
        }
        expect(TaskQueueService.instance.tasks.length, taskCountBefore);
      },
    );
  });
}

class _Tier5IpcSessionKernel implements AgentKernel {
  _Tier5IpcSessionKernel(this.descriptor, {required this.onSend});

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

class _Tier5CountingHttpOverrides extends HttpOverrides {
  _Tier5CountingHttpOverrides(this.onRequest);

  final void Function() onRequest;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return _Tier5CountingHttpClient(onRequest);
  }
}

class _Tier5CountingHttpClient implements HttpClient {
  _Tier5CountingHttpClient(this.onRequest);

  final void Function() onRequest;

  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    onRequest();
    return Future<HttpClientRequest>.error(
      const SocketException('blocked in T5-36'),
    );
  }

  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('POST', url);

  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

bool _tier5IsPidAlive(int pid) {
  if (Platform.isWindows) {
    final res = Process.runSync('tasklist', ['/FI', 'PID eq $pid', '/NH']);
    return RegExp('(?:^|\\s)$pid(?:\\s|\$)', multiLine: true)
        .hasMatch('${res.stdout}');
  }
  return Process.killPid(pid, ProcessSignal.sigcont);
}

void _tier5KillPidTree(int pid) {
  if (Platform.isWindows) {
    Process.runSync('taskkill', ['/PID', '$pid', '/T', '/F']);
  } else {
    Process.killPid(pid, ProcessSignal.sigkill);
  }
}
