import 'dart:async';
import 'dart:io';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/review/change_review.dart';
import 'package:baocode/chat/review/review_store.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/agent_message_parser.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_transport.dart';
import 'package:baocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:baocode/kernel/claude_code/mock_claude_code_transport.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/remote/remote_location.dart';
import 'package:baocode/workspace/session_tools.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final launches = <ClaudeLaunch>[];
  late KernelDescriptor kernel;
  kernel = KernelDescriptor(
    id: 'claude-code',
    label: 'Claude Code',
    icon: Icons.auto_awesome_rounded,
    description: '',
    create: (context) => ClaudeCodeKernel(
      kernel,
      context,
      start: (launch) async {
        launches.add(launch);
        return _OwnSession(
          await MockClaudeCodeTransport.start(launch),
          launch.resume ?? 'session-${launches.length}',
        );
      },
    ),
  );
  late Workspace workspace;
  late String app;
  var on = true;

  setUp(() {
    launches.clear();
    on = true;
    SessionToolsSetting.current = () => on;
    // As Git spells it (macOS's temp folder is a link).
    app = Directory.systemTemp
        .createTempSync('session-tools')
        .resolveSymbolicLinksSync();
    workspace = Workspace(kernels: [kernel], projects: [Project('app', app)]);
    SessionTools.register(workspace);
  });

  tearDown(() {
    SessionTools.unregister();
    SessionToolsSetting.current = () => false;
    workspace.dispose();
    Directory(app).deleteSync(recursive: true);
  });

  Future<List<String>> offered(String cwd) async {
    final answer = await ClaudeSdkTools.handle({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/list',
    }, ClaudeSdkCall(cwd: cwd));
    return [
      for (final tool
          in ((answer['result'] as Map)['tools'] as List).cast<Map>())
        tool['name'] as String,
    ];
  }

  Future<String> call(
    String tool,
    Map<String, Object?> arguments, {
    String? from,
  }) async {
    final answer = await ClaudeSdkTools.handle({
      'jsonrpc': '2.0',
      'id': 2,
      'method': 'tools/call',
      'params': {'name': tool, 'arguments': arguments},
    }, ClaudeSdkCall(cwd: app, sessionId: from));
    final result = answer['result'] as Map;
    return ((result['content'] as List).single as Map)['text'] as String;
  }

  /// [thread] started (its session known) and its turn stopped: the
  /// mock's own runs long.
  Future<void> settle(AgentThread thread) async {
    for (var i = 0; i < 500 && thread.session.sessionId == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    thread.session.stop();
    for (var i = 0; i < 500 && thread.session.isStreaming; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test(
    'only with the setting on, and not to the app\'s own agents (#934)',
    () async {
      expect(await offered(app), containsAll(SessionTools.names));
      workspace.appFolderRoot = p.join(app, 'bots');
      expect(
        await offered(p.join(app, 'bots', 'mia')),
        isNot(contains('session_list')),
      );
      on = false;
      expect(await offered(app), isNot(contains('session_list')));
      // On unless turned off.
      expect(SessionToolsSetting.enabled(null), isTrue);
      expect(SessionToolsSetting.enabled(SessionToolsSetting.off), isFalse);
    },
  );

  test('an agent lists and reads the others, not itself; hands one work '
      'once, said so', () async {
    final lead = workspace.startAgent(workspace.projectAt(app));
    lead.session.send(const ComposerMessage(text: 'coordinate'));
    await settle(lead);
    final tests = workspace.startAgent(workspace.projectAt(app));
    workspace.rename(tests, 'Tests');
    tests.session.send(const ComposerMessage(text: 'run the tests'));
    await settle(tests);
    final leadId = lead.id!;
    final testsId = SessionTools.idOf(tests);

    final listed = await call('session_list', {}, from: leadId);
    expect(listed, contains('$testsId | app | Tests | idle'));
    expect(listed, isNot(contains(SessionTools.idOf(lead))));

    final started = launches.length;
    final read = await call('session_read', {'session': testsId}, from: leadId);
    expect(read, startsWith('"Tests" in app'));
    expect(read, contains('User: run the tests'));
    // Read, not woken.
    expect(launches, hasLength(started));

    expect(
      await call('session_send', {
        'session': testsId,
        'text': 'and lint',
      }, from: leadId),
      startsWith('Sent: it is on it'),
    );
    await settle(tests);
    final sent = [
      for (var i = 0; i < tests.session.itemCount; i++)
        if (tests.session.itemAt(i) case UserMessageItem(:final text)) text,
    ];
    expect(sent, contains('and lint'));
    expect(
      await call('session_send', {
        'session': testsId,
        'text': 'and lint',
      }, from: leadId),
      startsWith('Not delivered: the same message'),
    );
    expect(
      await call('session_send', {
        'session': SessionTools.idOf(lead),
        'text': 'x',
      }, from: leadId),
      endsWith('That is this conversation.'),
    );

    expect(
      await call('session_wait', {
        'session': testsId,
        'seconds': 10,
      }, from: leadId),
      startsWith('$testsId ("Tests") is done.'),
    );

    // At work: queued behind its turn, not cutting it short.
    tests.session.send(const ComposerMessage(text: 'and the docs'));
    for (var i = 0; i < 500 && !tests.session.isStreaming; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(
      await call('session_send', {
        'session': testsId,
        'text': 'then the changelog',
      }, from: leadId),
      startsWith('Queued'),
    );
    expect(tests.session.isStreaming, isTrue);
    expect(
      [for (final (_, message) in tests.session.queued) message.text],
      ['then the changelog'],
    );
    tests.session.stop();
  });

  /// [test] true, in time.
  Future<void> until(bool Function() test, {int seconds = 15}) async {
    for (var i = 0; i < seconds * 50 && !test(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(test(), isTrue);
  }

  /// The messages another agent sent [thread], by who sent them.
  List<(String, String)> fromAgents(AgentThread thread) => [
    for (var i = 0; i < thread.session.itemCount; i++)
      if (thread.session.itemAt(i) case UserMessageItem(
        :final text,
        fromAgent: final from?,
      ))
        (from, text),
  ];

  /// A lead agent, started and stopped: its approvals [permission].
  Future<AgentThread> lead({String permission = 'dontAsk'}) async {
    final lead = workspace.startAgent(workspace.projectAt(app));
    workspace.rename(lead, 'Lead');
    final permissions = lead.session.permissions!;
    permissions.onSelected(
      permissions.options.firstWhere((option) => option.id == permission),
    );
    lead.session.send(const ComposerMessage(text: 'coordinate'));
    await settle(lead);
    return lead;
  }

  AgentThread started(String answer) {
    final id = RegExp(r'Started: (\S+) in').firstMatch(answer)![1];
    return SessionTools.threadOf(workspace, id!)!;
  }

  test('a conversation started reports back by itself, its reply whole, '
      'as its card: once', () async {
    final boss = await lead();
    final answer = await call('session_new', {
      'text': 'look at the tests (quick)',
      'title': 'Tests',
    }, from: boss.id);
    expect(answer, startsWith('Started: '));
    final tests = started(answer);
    expect(tests.title, 'Tests');
    // As the lead's, its approvals; as its card, the message.
    expect(tests.session.selected(KernelChoiceKind.permission), 'dontAsk');
    await until(() => fromAgents(tests).isNotEmpty);
    expect(fromAgents(tests).single, ('Lead', 'look at the tests (quick)'));
    expect(
      await call('session_list', {'mine': true}, from: boss.id),
      allOf(contains('| Tests |'), endsWith('| yours')),
    );

    // Done: told the lead, with all it said.
    await until(() => fromAgents(boss).isNotEmpty);
    final (from, report) = fromAgents(boss).single;
    expect(from, 'Tests');
    // As the user reads it: what it said, whole.
    expect(report, _quickReply);
    // Each card names the conversation it came from; the lead's steps and
    // cards, the one it handed work to.
    UserMessageItem card(AgentThread thread) => [
      for (var i = 0; i < thread.session.itemCount; i++)
        if (thread.session.itemAt(i) case final UserMessageItem item
            when item.fromAgent != null)
          item,
    ].first;
    expect(card(tests).fromSession, boss.id);
    expect(card(boss).fromSession, tests.id);
    expect(SessionTools.handedFrom(boss.session, workspace), [tests]);
    await settle(boss);

    // Waited on: said by the wait, not told again.
    expect(
      await call('session_send', {
        'session': SessionTools.idOf(tests),
        'text': 'and the docs (quick)',
      }, from: boss.id),
      startsWith('Sent'),
    );
    final waited = await call('session_wait', {
      'sessions': [SessionTools.idOf(tests)],
      'seconds': 10,
    }, from: boss.id);
    expect(
      waited,
      '${SessionTools.idOf(tests)} ("Tests") is done.\nIts reply:\n\n'
      '$_quickReply',
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(fromAgents(boss), hasLength(1));

    expect(
      await call('session_changes', {
        'session': SessionTools.idOf(tests),
      }, from: boss.id),
      'It edited no files.',
    );
  });

  test('one waiting on the user says what for; not written to then; '
      'stopped by the lead, not reported', () async {
    final boss = await lead(permission: 'default');
    final tests = started(
      await call('session_new', {
        'text': 'fix the input (ask)',
        'title': 'Input',
      }, from: boss.id),
    );
    // It asks the user: told the lead.
    await until(() => fromAgents(boss).isNotEmpty);
    final (_, report) = fromAgents(boss).single;
    expect(report, 'Which one?\n- This\n- That');
    await settle(boss);
    // Answering it is the user's.
    expect(tests.session.pendingInteraction, isNotNull);
    expect(
      await call('session_send', {
        'session': SessionTools.idOf(tests),
        'text': 'pick the first',
      }, from: boss.id),
      startsWith('Not delivered: it waits on the user. It asks them'),
    );
    final read = await call('session_read', {
      'session': SessionTools.idOf(tests),
      'full': true,
    }, from: boss.id);
    expect(read, contains('Only the user can answer it.'));
    expect(read, contains('From "Lead": fix the input (ask)'));
    expect(
      await call('session_read', {
        'session': SessionTools.idOf(tests),
        'skip': 1,
      }, from: boss.id),
      endsWith('From "Lead": fix the input (ask)'),
    );

    expect(
      await call('session_stop', {
        'session': SessionTools.idOf(tests),
      }, from: boss.id),
      'Stopped.',
    );
    await until(() => !tests.session.isStreaming);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(fromAgents(boss), hasLength(1));
  });

  test('a model picked by its id, another refused with those there are; '
      'a worktree on a branch of its own', () async {
    final boss = await lead();
    expect(
      await call('session_new', {'text': 'x', 'model': 'gpt-0'}, from: boss.id),
      allOf(contains('No model "gpt-0"'), contains('sonnet')),
    );
    final quick = started(
      await call('session_new', {
        'text': 'a look (quick)',
        'model': 'sonnet',
      }, from: boss.id),
    );
    expect(quick.session.selected(KernelChoiceKind.model), 'sonnet');
    // Those there are, as the user picks them; it says which it is on.
    expect(
      await call('session_models', const {}, from: boss.id),
      allOf(contains('sonnet | Sonnet 5'), contains('haiku | Haiku 4.5')),
    );
    expect(
      await call('session_list', const {}, from: boss.id),
      contains('Sonnet 5 (sonnet)'),
    );
    // Moved to another with what it is sent.
    await until(() => fromAgents(boss).isNotEmpty);
    await settle(quick);
    expect(
      await call('session_send', {
        'session': SessionTools.idOf(quick),
        'text': 'another look (quick)',
        'model': 'haiku',
      }, from: boss.id),
      startsWith('Sent'),
    );
    expect(quick.session.selected(KernelChoiceKind.model), 'haiku');

    Future<void> git(List<String> arguments) async {
      final result = await Process.run('git', arguments, workingDirectory: app);
      expect(result.exitCode, 0, reason: '${result.stderr}');
    }

    await git(['init', '-q']);
    await git([
      '-c',
      'user.name=t',
      '-c',
      'user.email=t@t',
      'commit',
      '-q',
      '--allow-empty',
      '-m',
      'first',
    ]);
    final worktree = '$app-fix-login';
    addTearDown(() {
      if (Directory(worktree).existsSync()) {
        Directory(worktree).deleteSync(recursive: true);
      }
    });
    final answer = await call('session_new', {
      'text': 'fix the login (quick)',
      'worktree': 'fix/login',
    }, from: boss.id);
    expect(
      answer,
      contains('It works in $worktree, on the new branch fix/login.'),
    );
    expect(Directory(worktree).existsSync(), isTrue);
    final fixing = started(answer);
    await until(() => fromAgents(fixing).isNotEmpty);
    expect(
      fromAgents(fixing).single.$2,
      startsWith('Work in $worktree (branch fix/login'),
    );
  });

  test('turned off, an agent at work can no longer act on the others, '
      'and those it handed work report nothing', () async {
    final boss = await lead();
    final tests = started(
      await call('session_new', {'text': 'fix the input'}, from: boss.id),
    );
    await until(() => tests.session.isStreaming);
    on = false;
    expect(
      await call('session_list', const {}, from: boss.id),
      'No tool session_list.',
    );
    // Its turn over: not told.
    await settle(tests);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(fromAgents(boss), isEmpty);
  });

  group('F3 cross-kernel bridge & Turn-1 caller correlation', () {
    late KernelDescriptor agyKernel;
    late KernelDescriptor codebuddyKernel;
    late KernelDescriptor codexMockKernel;
    late Workspace multiWorkspace;

    setUp(() {
      agyKernel = KernelDescriptor(
        id: 'antigravity-cli',
        label: 'Antigravity',
        icon: Icons.rocket_launch_rounded,
        description: '',
        create: (context) => ClaudeCodeKernel(
          agyKernel,
          context,
          start: (launch) async => _OwnSession(
            await MockClaudeCodeTransport.start(launch),
            launch.resume ?? 'agy-sess-${launches.length + 1}',
          ),
        ),
      );
      codebuddyKernel = KernelDescriptor(
        id: 'codebuddy-cli',
        label: 'CodeBuddy',
        icon: Icons.smart_toy_rounded,
        description: '',
        create: (context) => ClaudeCodeKernel(
          codebuddyKernel,
          context,
          start: (launch) async => _OwnSession(
            await MockClaudeCodeTransport.start(launch),
            launch.resume ?? 'cb-sess-${launches.length + 1}',
          ),
        ),
      );
      codexMockKernel = KernelDescriptor(
        id: 'codex',
        label: 'Codex',
        icon: Icons.code_rounded,
        description: '',
        create: (context) => _FakeCodexKernel(codexMockKernel),
      );

      multiWorkspace = Workspace(
        kernels: [kernel, agyKernel, codebuddyKernel, codexMockKernel],
        projects: [Project('app', app)],
      );
      SessionTools.register(multiWorkspace);
    });

    tearDown(() {
      SessionTools.register(workspace);
      multiWorkspace.dispose();
    });

    Future<String> callMulti(
      String tool,
      Map<String, Object?> arguments, {
      String? from,
      String? turnId,
    }) async {
      final answer = await ClaudeSdkTools.handle(
        {
          'jsonrpc': '2.0',
          'id': 99,
          'method': 'tools/call',
          'params': {'name': tool, 'arguments': arguments},
        },
        ClaudeSdkCall(cwd: app, sessionId: from, turnId: turnId),
      );
      final result = answer['result'] as Map;
      return ((result['content'] as List).single as Map)['text'] as String;
    }

    test('wraps <agent-message> for antigravity-cli and codebuddy-cli workers, and guards codex reports', () async {
      final leadThread = multiWorkspace.startAgent(multiWorkspace.projectAt(app));
      multiWorkspace.rename(leadThread, 'Coordinator');
      leadThread.session.send(const ComposerMessage(text: 'start'));
      await settle(leadThread);

      final agyAnswer = await callMulti('session_new', {
        'text': 'check build (quick)',
        'title': 'AgyWorker',
        'kernel': 'antigravity-cli',
      }, from: leadThread.id);
      expect(agyAnswer, startsWith('Started: '));
      final agyId = RegExp(r'Started: (\S+) in').firstMatch(agyAnswer)![1]!;
      final agyWorker = SessionTools.threadOf(multiWorkspace, agyId)!;
      expect(agyWorker.kernel.id, 'antigravity-cli');
      await until(() => fromAgents(agyWorker).isNotEmpty);
      expect(fromAgents(agyWorker).single, ('Coordinator', 'check build (quick)'));
      await until(() => fromAgents(leadThread).isNotEmpty);
      expect(fromAgents(leadThread).single.$1, 'AgyWorker');

      final cbAnswer = await callMulti('session_new', {
        'text': 'lint code (quick)',
        'title': 'CbWorker',
        'kernel': 'codebuddy-cli',
      }, from: leadThread.id);
      final cbId = RegExp(r'Started: (\S+) in').firstMatch(cbAnswer)![1]!;
      final cbWorker = SessionTools.threadOf(multiWorkspace, cbId)!;
      expect(cbWorker.kernel.id, 'codebuddy-cli');
      await until(() => fromAgents(cbWorker).isNotEmpty);
      expect(fromAgents(cbWorker).single, ('Coordinator', 'lint code (quick)'));

      // Codex recipient parses <agent-message> into structured fromAgent/fromSession fields.
      final codexLead = multiWorkspace.startAgent(multiWorkspace.projectAt(app));
      codexLead.session.setKernel(codexMockKernel);
      multiWorkspace.rename(codexLead, 'CodexLead');
      codexLead.session.send(const ComposerMessage(text: 'coordinate'));
      await until(() => codexLead.id != null);

      final workerForCodex = RegExp(r'Started: (\S+) in').firstMatch(
        await callMulti('session_new', {
          'text': 'run quick task (quick)',
          'title': 'QuickWorker',
          'kernel': 'claude-code',
        }, from: codexLead.id),
      )![1]!;
      final workerThread = SessionTools.threadOf(multiWorkspace, workerForCodex);
      expect(workerThread, isNotNull);
      await until(() {
        final fakeKernel = codexLead.session.models;
        expect(fakeKernel, isNotNull);
        for (var i = 0; i < codexLead.session.itemCount; i++) {
          if (codexLead.session.itemAt(i)
              case UserMessageItem(
                :final text,
                :final fromAgent,
                :final fromSession,
              )
              when fromAgent == 'QuickWorker' &&
                  fromSession == SessionTools.idOf(workerThread!) &&
                  text.contains('All looked at.')) {
            expect(text, isNot(contains('<agent-message')));
            return true;
          }
        }
        return false;
      });
    });

    test('correlates Turn-1 caller via turnIdProvider before conversation_id binds and delivers report after bind', () async {
      final deferredCtrl = _DeferredInitTransport();
      var deferredStarts = 0;
      late KernelDescriptor deferredKernel;
      deferredKernel = KernelDescriptor(
        id: 'antigravity-cli',
        label: 'Antigravity',
        icon: Icons.rocket_launch_rounded,
        description: '',
        create: (context) => ClaudeCodeKernel(
          deferredKernel,
          context,
          start: (launch) async {
            if (deferredStarts++ == 0) {
              return deferredCtrl;
            }
            return _OwnSession(
              await MockClaudeCodeTransport.start(launch),
              'worker-bound-1',
            );
          },
        ),
      );

      final w = Workspace(
        kernels: [deferredKernel],
        projects: [Project('app', app)],
      );
      SessionTools.register(w);
      addTearDown(() {
        SessionTools.register(workspace);
        w.dispose();
      });

      final leadThread = w.startAgent(w.projectAt(app));
      w.rename(leadThread, 'Turn1Lead');
      final perms = leadThread.session.permissions!;
      perms.onSelected(
        perms.options.firstWhere((o) => o.id == 'dontAsk'),
      );
      // Send Turn 1; _DeferredInitTransport has NOT emitted system:init yet!
      leadThread.session.send(const ComposerMessage(text: 'delegate work'));
      await until(() => leadThread.session.isStreaming && deferredCtrl.lastTurnUuid != null);
      expect(leadThread.id, isNull);
      final turnUuid = deferredCtrl.lastTurnUuid!;

      // session_list excludes leadThread even while leadThread.id == null.
      final listed = await ClaudeSdkTools.handle(
        {'id': 1, 'method': 'tools/call', 'params': {'name': 'session_list', 'arguments': const <String, Object?>{}}},
        ClaudeSdkCall(cwd: app, turnId: turnUuid),
      );
      expect(
        (((listed['result'] as Map)['content'] as List).single as Map)['text'],
        'None.',
      );

      // session_new with turnId (no sessionId) correlates caller, inherits permission, and tracks mine.
      final startedRes = await ClaudeSdkTools.handle(
        {
          'id': 2,
          'method': 'tools/call',
          'params': {
            'name': 'session_new',
            'arguments': {'text': 'subtask (quick)', 'title': 'SubWorker'},
          },
        },
        ClaudeSdkCall(cwd: app, turnId: turnUuid),
      );
      final startedText =
          (((startedRes['result'] as Map)['content'] as List).single as Map)['text'] as String;
      final workerId = RegExp(r'Started: (\S+) in').firstMatch(startedText)![1]!;
      final worker = SessionTools.threadOf(w, workerId)!;
      expect(worker.session.selected(KernelChoiceKind.permission), 'dontAsk');
      await until(() => fromAgents(worker).isNotEmpty);
      expect(fromAgents(worker).single.$1, 'Turn1Lead');

      // Now leadThread receives its conversation_id and finishes Turn 1.
      deferredCtrl.bindAndFinishTurn('conv-lead-bound');
      await until(() => leadThread.id == 'conv-lead-bound' && !leadThread.session.isStreaming);

      // session_list(mine: true) still sees worker after thread.id bound!
      final mineList = await ClaudeSdkTools.handle(
        {'id': 3, 'method': 'tools/call', 'params': {'name': 'session_list', 'arguments': {'mine': true}}},
        ClaudeSdkCall(cwd: app, sessionId: 'conv-lead-bound'),
      );
      expect(
        (((mineList['result'] as Map)['content'] as List).single as Map)['text'],
        contains('| SubWorker |'),
      );

      // Worker completes and auto-report delivers to leadThread under bound ID!
      await until(() => fromAgents(leadThread).isNotEmpty);
      expect(fromAgents(leadThread).single.$1, 'SubWorker');
    });

    test('session_models lists multi-kernel options and session_new resolves cross-kernel models', () async {
      final leadThread = multiWorkspace.startAgent(multiWorkspace.projectAt(app));
      leadThread.session.send(const ComposerMessage(text: 'hi'));
      await settle(leadThread);

      final allModels = await callMulti('session_models', const {}, from: leadThread.id);
      expect(allModels, contains('Kernel: claude-code (Claude Code)'));
      expect(allModels, contains('Kernel: antigravity-cli (Antigravity)'));
      expect(allModels, contains('Kernel: codex (Codex)'));
      expect(allModels, contains('gpt-5.4 | GPT-5.4'));

      final codexOnly = await callMulti('session_models', {'kernel': 'codex'}, from: leadThread.id);
      expect(codexOnly, contains('gpt-5.4 | GPT-5.4'));
      expect(codexOnly, isNot(contains('claude-code')));

      // Infer codex kernel from model without explicit kernel parameter.
      final inferredCodex = await callMulti('session_new', {
        'text': 'analyze',
        'model': 'gpt-5.4',
      }, from: leadThread.id);
      final inferredId = RegExp(r'Started: (\S+) in').firstMatch(inferredCodex)![1]!;
      final inferredThread = SessionTools.threadOf(multiWorkspace, inferredId)!;
      expect(inferredThread.kernel.id, 'codex');
      expect(inferredThread.session.selected(KernelChoiceKind.model), 'gpt-5.4');

      // Unknown kernel throws ArgumentError.
      final badKernel = await callMulti('session_new', {
        'text': 'x',
        'kernel': 'nonexistent-kernel',
      }, from: leadThread.id);
      expect(badKernel, contains('No kernel "nonexistent-kernel"'));
    });
  });

  group('session_changes path resolution and deduplication', () {
    test('deduplicates relative, unnormalized, and case-variant edit paths while preserving stats and keep behavior', () async {
      late KernelDescriptor scriptedDesc;
      scriptedDesc = KernelDescriptor(
        id: 'scripted-changes',
        label: 'Scripted',
        icon: Icons.edit_rounded,
        description: '',
        create: (ctx) => _ScriptedEventKernel(scriptedDesc, ctx),
      );

      final w = Workspace(
        kernels: [scriptedDesc],
        projects: [Project('app', app)],
      );
      SessionTools.register(w);
      addTearDown(() {
        SessionTools.register(workspace);
        w.dispose();
      });

      final lead = w.startAgent(w.projectAt(app));
      w.rename(lead, 'Lead');
      lead.session.send(const ComposerMessage(text: 'hi'));
      final leadKernel = _ScriptedEventKernel.instances.last;
      leadKernel.bindSession('lead-changes-1');
      final worker = w.startAgent(w.projectAt(app));
      w.rename(worker, 'Worker');
      worker.session.send(const ComposerMessage(text: 'work'));
      final workerKernel = worker.session;
      await until(() => lead.id == 'lead-changes-1');

      final expectedFeat = RemoteLocation.pathsOf(app).normalize(
        RemoteLocation.pathsOf(app).joinAll([app, 'lib', 'feat.dart']),
      );
      final forwardSlashFeat = expectedFeat.replaceAll('\\', '/');
      final caseVariantFeat = Platform.isWindows && expectedFeat.length > 2
          ? '${expectedFeat[0].toLowerCase()}${expectedFeat.substring(1)}'
          : forwardSlashFeat;

      final wk = _ScriptedEventKernel.instances.last;
      wk.bindSession('worker-changes-1');
      wk.emitTurnStarted('t1');
      wk.emitItem(
        'e1',
        const ToolCallItem(
          kind: ToolKind.edit,
          target: 'feat.dart',
          path: 'lib/feat.dart',
        ),
      );
      wk.emitItem(
        'e2',
        ToolCallItem(
          kind: ToolKind.edit,
          target: 'feat.dart',
          path: forwardSlashFeat,
        ),
      );
      wk.emitItem(
        'e3',
        const ToolCallItem(
          kind: ToolKind.edit,
          target: 'feat.dart',
          path: './lib/../lib/feat.dart',
        ),
      );
      wk.emitItem(
        'e4',
        ToolCallItem(
          kind: ToolKind.edit,
          target: 'feat.dart',
          path: caseVariantFeat,
        ),
      );
      wk.emitFileEdited(
        const FileChange(path: 'lib/feat.dart', added: 2, removed: 1),
        turnId: 't1',
      );
      wk.emitItem(
        'e5',
        ToolCallItem(
          kind: ToolKind.read,
          target: 'sub.dart',
          path: '${app.replaceAll('\\', '/')}/lib/sub.dart',
        ),
      );
      wk.emitTurnEnded('t1');
      await until(
        () =>
            !workerKernel.isStreaming &&
            workerKernel.fileChanges.isNotEmpty &&
            worker.id == 'worker-changes-1',
      );

      Future<String> callChanges() async {
        final ans = await ClaudeSdkTools.handle(
          {
            'jsonrpc': '2.0',
            'id': 9,
            'method': 'tools/call',
            'params': {
              'name': 'session_changes',
              'arguments': {'session': SessionTools.idOf(worker)},
            },
          },
          ClaudeSdkCall(cwd: app, sessionId: lead.id),
        );
        return (((ans['result'] as Map)['content'] as List).single
            as Map)['text'] as String;
      }

      final beforeKeep = await callChanges();
      expect(
        beforeKeep,
        'The files it edited:\n$expectedFeat +2 -1',
      );
      expect(beforeKeep, isNot(contains('It last worked at')));

      // keepChanges with relative unnormalized path clears pending stats while
      // leaving the ToolCallItem edit listed once without stats.
      workerKernel.keepChanges([
        const FileChange(path: 'lib/feat.dart', added: 2, removed: 1),
      ]);
      expect(workerKernel.fileChanges, isEmpty);
      expect(await callChanges(), 'The files it edited:\n$expectedFeat');

      // Also verify keepAllChanges leaves ToolCallItem-only edit listed once.
      wk.emitTurnStarted('t2');
      wk.emitFileEdited(
        const FileChange(path: './lib/../lib/feat.dart', added: 1, removed: 0),
        turnId: 't2',
      );
      wk.emitTurnEnded('t2');
      await until(() => workerKernel.fileChanges.isNotEmpty);
      workerKernel.keepAllChanges();
      expect(await callChanges(), 'The files it edited:\n$expectedFeat');
    });

    test('ChatSession.resolvePath matches ChangeReview._key with realRoot remapping', () async {
      final linkRoot = p.join(app, 'link_root');
      final realRoot = p.join(app, 'real_root');
      final review = ChangeReview(
        _NoopReviewStore(),
        root: linkRoot,
        paths: RemoteLocation.pathsOf(linkRoot),
        realRoot: realRoot,
      );
      review.report(
        const FileChange(path: 'lib/feat.dart', added: 3, removed: 1),
      );

      late _ScriptedEventKernel kernel;
      late KernelDescriptor desc;
      desc = KernelDescriptor(
        id: 'review-align',
        label: 'ReviewAlign',
        icon: Icons.compare_rounded,
        description: '',
        create: (ctx) => kernel = _ScriptedEventKernel(desc, ctx),
      );
      final session = ChatSession(
        kernel: desc,
        kernelContext: KernelContext(cwd: linkRoot),
        historyCount: 0,
        openReview: (root, {session}) async => review,
      );
      addTearDown(session.dispose);
      session.attach();
      await until(() => session.fileChanges.isNotEmpty);

      final expected = review.changes.single.path;
      expect(session.resolvePath('lib/feat.dart'), expected);
      expect(
        session.resolvePath(p.join(realRoot, 'lib', 'feat.dart')),
        expected,
      );
      expect(session.fileChanges.single.path, expected);

      kernel.emitTurnStarted('t1');
      kernel.emitItem(
        'e1',
        const ToolCallItem(
          kind: ToolKind.edit,
          target: 'feat.dart',
          path: 'lib/feat.dart',
        ),
      );
      kernel.emitTurnEnded('t1');
      await until(() => session.filesSeen.contains(expected));
      expect(session.filesSeen, [expected]);
    });

    test('session_changes handles remote ssh:// POSIX and Windows host paths accurately', () async {
      for (final (remoteLoc, expectedFeat, caseVariantInput) in [
        (
          'ssh://dev/home/me/app',
          '/home/me/app/lib/feat.dart',
          '/home/me/app/./lib/../lib/feat.dart',
        ),
        (
          'ssh://win/C:/Users/me/app',
          r'C:\Users\me\app\lib\feat.dart',
          r'c:/Users/me/app/lib/feat.dart',
        ),
      ]) {
        late KernelDescriptor desc;
        desc = KernelDescriptor(
          id: 'remote-changes',
          label: 'RemoteChanges',
          icon: Icons.cloud_rounded,
          description: '',
          create: (ctx) => _ScriptedEventKernel(desc, ctx),
        );
        final project = Project.at(remoteLoc);
        final w = Workspace(kernels: [desc], projects: [project]);
        SessionTools.register(w);
        try {
          final lead = w.startAgent(project);
          w.rename(lead, 'RemoteLead');
          lead.session.send(const ComposerMessage(text: 'hi'));
          final leadK = _ScriptedEventKernel.instances.last;
          final worker = w.startAgent(project);
          w.rename(worker, 'RemoteWorker');
          worker.session.send(const ComposerMessage(text: 'work'));
          final workerK = _ScriptedEventKernel.instances.last;
          expect(identical(leadK, workerK), isFalse);
          leadK.bindSession('remote-lead-${project.name}');
          workerK.bindSession('remote-worker-${project.name}');

          workerK.emitTurnStarted('t1');
          workerK.emitItem(
            'e1',
            const ToolCallItem(
              kind: ToolKind.edit,
              target: 'feat.dart',
              path: 'lib/feat.dart',
            ),
          );
          workerK.emitItem(
            'e2',
            ToolCallItem(
              kind: ToolKind.edit,
              target: 'feat.dart',
              path: caseVariantInput,
            ),
          );
          workerK.emitFileEdited(
            const FileChange(path: 'lib/feat.dart', added: 4, removed: 2),
            turnId: 't1',
          );
          workerK.emitTurnEnded('t1');
          await until(
            () =>
                !worker.session.isStreaming &&
                worker.session.fileChanges.isNotEmpty &&
                worker.id != null,
          );

          final ans = await ClaudeSdkTools.handle(
            {
              'jsonrpc': '2.0',
              'id': 1,
              'method': 'tools/call',
              'params': {
                'name': 'session_changes',
                'arguments': {'session': SessionTools.idOf(worker)},
              },
            },
            ClaudeSdkCall(cwd: remoteLoc, sessionId: lead.id),
          );
          final text = (((ans['result'] as Map)['content'] as List).single
              as Map)['text'] as String;
          expect(text, 'The files it edited:\n$expectedFeat +4 -2');
        } finally {
          SessionTools.register(workspace);
          w.dispose();
        }
      }
    });

    test('ChatSession.fileChanges, filesSeen, and keepChanges deduplicate Windows case-variant paths while preserving first-seen display path', () async {
      final cwds = <String>[
        if (Platform.isWindows) p.join(app, 'Repo'),
        'ssh://win/C:/Temp/Repo',
      ];
      for (final cwd in cwds) {
        final root = RemoteLocation.pathOf(cwd);
        final hostPaths = RemoteLocation.pathsOf(cwd);
        final expectedFeat = hostPaths.normalize(
          hostPaths.joinAll([root, 'lib', 'feat.dart']),
        );
        final lowerSlashFeat =
            '${expectedFeat[0].toLowerCase()}${expectedFeat.substring(1)}'
                .replaceAll('\\', '/');
        final lowerBackFeat = lowerSlashFeat.replaceAll('/', '\\');

        late _ScriptedEventKernel kernel;
        late KernelDescriptor desc;
        desc = KernelDescriptor(
          id: 'probe4a-win',
          label: 'Probe4A',
          icon: Icons.edit_rounded,
          description: '',
          create: (ctx) => kernel = _ScriptedEventKernel(desc, ctx),
        );
        final session = ChatSession(
          kernel: desc,
          kernelContext: KernelContext(cwd: cwd),
          historyCount: 0,
          openReview: null,
        );
        addTearDown(session.dispose);

        kernel.emitTurnStarted('t1');
        kernel.emitItem(
          'e1',
          const ToolCallItem(
            kind: ToolKind.edit,
            target: 'feat.dart',
            path: 'lib/feat.dart',
          ),
        );
        kernel.emitFileEdited(
          const FileChange(path: 'lib/feat.dart', added: 2, removed: 1),
          turnId: 't1',
        );
        kernel.emitItem(
          'e2',
          ToolCallItem(
            kind: ToolKind.edit,
            target: 'feat.dart',
            path: lowerSlashFeat,
          ),
        );
        kernel.emitFileEdited(
          FileChange(path: lowerSlashFeat, added: 3, removed: 0),
          turnId: 't1',
        );
        kernel.emitTurnEnded('t1');
        await until(
          () => !session.isStreaming && session.fileChanges.isNotEmpty,
        );

        expect(session.fileChanges, hasLength(1));
        expect(session.fileChanges.single.path, expectedFeat);
        expect(session.fileChanges.single.added, 5);
        expect(session.fileChanges.single.removed, 1);
        expect(session.filesSeen, [expectedFeat]);

        // Case-variant keepChanges must clear all pending edits for the same file.
        session.keepChanges([
          FileChange(path: lowerBackFeat, added: 5, removed: 1),
        ]);
        expect(session.fileChanges, isEmpty);

        // Reverse order: lowercase first preserves lowercase display path and
        // uppercase keepChanges still clears it.
        kernel.emitTurnStarted('t2');
        final lowerOther =
            '${expectedFeat[0].toLowerCase()}${hostPaths.joinAll([root, 'lib', 'other.dart']).substring(1)}'
                .replaceAll('\\', '/');
        final upperOther =
            '${expectedFeat[0].toUpperCase()}${hostPaths.joinAll([root, 'lib', 'other.dart']).substring(1)}';
        kernel.emitFileEdited(
          FileChange(path: lowerOther, added: 1, removed: 0),
          turnId: 't2',
        );
        kernel.emitFileEdited(
          const FileChange(path: 'lib/other.dart', added: 2, removed: 1),
          turnId: 't2',
        );
        kernel.emitTurnEnded('t2');
        await until(
          () => !session.isStreaming && session.fileChanges.isNotEmpty,
        );

        expect(session.fileChanges, hasLength(1));
        expect(
          session.fileChanges.single.path,
          lowerOther.replaceAll('/', '\\'),
        );
        expect(session.fileChanges.single.added, 3);
        expect(session.fileChanges.single.removed, 1);
        session.keepChanges([
          FileChange(path: upperOther, added: 3, removed: 1),
        ]);
        expect(session.fileChanges, isEmpty);
      }

      // POSIX paths remain case-sensitive.
      late _ScriptedEventKernel posixKernel;
      late KernelDescriptor posixDesc;
      posixDesc = KernelDescriptor(
        id: 'probe4a-posix',
        label: 'Probe4APosix',
        icon: Icons.edit_rounded,
        description: '',
        create: (ctx) => posixKernel = _ScriptedEventKernel(posixDesc, ctx),
      );
      final posixSession = ChatSession(
        kernel: posixDesc,
        kernelContext: const KernelContext(cwd: 'ssh://dev/home/me/Repo'),
        historyCount: 0,
        openReview: null,
      );
      addTearDown(posixSession.dispose);

      posixKernel.emitTurnStarted('t1');
      posixKernel.emitFileEdited(
        const FileChange(path: 'lib/Feat.dart', added: 1, removed: 0),
        turnId: 't1',
      );
      posixKernel.emitFileEdited(
        const FileChange(path: 'lib/feat.dart', added: 2, removed: 0),
        turnId: 't1',
      );
      posixKernel.emitTurnEnded('t1');
      await until(
        () => !posixSession.isStreaming && posixSession.fileChanges.isNotEmpty,
      );

      expect(posixSession.fileChanges, hasLength(2));
      expect(posixSession.filesSeen, [
        '/home/me/Repo/lib/Feat.dart',
        '/home/me/Repo/lib/feat.dart',
      ]);
    });

    test('ChangeReview deduplicates Windows case-variant paths directly and through ChatSession.keepChanges', () async {
      const linkRoot = r'C:\Temp\probe4b_link_root';
      const realRoot = r'C:\Temp\probe4b_real_root';
      final review = ChangeReview(
        _NoopReviewStore(),
        root: linkRoot,
        paths: p.windows,
        realRoot: realRoot,
      );

      review.report(
        const FileChange(
          path: r'c:\Temp\probe4b_real_root\lib\feat.dart',
          added: 3,
          removed: 1,
        ),
      );
      review.report(
        const FileChange(
          path: r'C:\Temp\probe4b_link_root\lib\other2.dart',
          added: 1,
          removed: 0,
        ),
      );
      review.report(
        const FileChange(
          path: r'c:/Temp/probe4b_link_root/lib/other2.dart',
          added: 2,
          removed: 1,
        ),
      );
      await review.keep(const []);

      expect(review.changes, hasLength(2));
      final byPath = {for (final c in review.changes) c.path: c};
      expect(
        byPath.keys,
        unorderedEquals([
          r'C:\Temp\probe4b_link_root\lib\feat.dart',
          r'C:\Temp\probe4b_link_root\lib\other2.dart',
        ]),
      );
      expect(byPath[r'C:\Temp\probe4b_link_root\lib\other2.dart']!.added, 3);
      expect(byPath[r'C:\Temp\probe4b_link_root\lib\other2.dart']!.removed, 1);

      late KernelDescriptor desc;
      desc = KernelDescriptor(
        id: 'probe4b-review',
        label: 'Probe4BReview',
        icon: Icons.compare_rounded,
        description: '',
        create: (ctx) => _ScriptedEventKernel(desc, ctx),
      );
      final session = ChatSession(
        kernel: desc,
        kernelContext: const KernelContext(cwd: 'ssh://win/C:/Temp/probe4b_link_root'),
        historyCount: 0,
        openReview: (root, {session}) async => review,
      );
      addTearDown(session.dispose);
      session.attach();
      await until(() => session.fileChanges.length == 2);

      // Keeping via lowercase path clears the uppercase-first ChangeReview entry.
      session.keepChanges([
        const FileChange(
          path: r'c:\Temp\probe4b_link_root\lib\other2.dart',
          added: 3,
          removed: 1,
        ),
      ]);
      await until(() => session.fileChanges.length == 1);
      expect(
        session.fileChanges.single.path,
        r'C:\Temp\probe4b_link_root\lib\feat.dart',
      );
    });

    test('matches case-variant project paths and cwd in projectNamed, session_list, and Turn-1 _callerOf', () async {
      final projDir = Directory(p.join(app, 'MixedCaseProj'))
        ..createSync(recursive: true);
      final otherDir = Directory(p.join(app, 'OtherCaseProj'))
        ..createSync(recursive: true);
      final w = Workspace(
        kernels: [kernel],
        projects: [
          Project('MixedCaseProj', projDir.path),
          Project('OtherCaseProj', otherDir.path),
        ],
      );
      SessionTools.register(w);
      addTearDown(() {
        SessionTools.register(workspace);
        w.dispose();
      });

      final lead = w.startAgent(w.projects.first);
      w.rename(lead, 'CaseLead');
      lead.session.send(const ComposerMessage(text: 'hi'));

      final variantOther = Platform.isWindows
          ? '${otherDir.path.toLowerCase().replaceAll('\\', '/')}/'
          : '${otherDir.path}/';
      final variantProj = Platform.isWindows
          ? projDir.path.toLowerCase()
          : projDir.path;

      // Turn-1 _callerOf fallback with null sessionId & null turnId matches case-variant cwd.
      final newRes = await ClaudeSdkTools.handle(
        {
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'tools/call',
          'params': {
            'name': 'session_new',
            'arguments': {'text': 'hello (quick)', 'project': variantOther},
          },
        },
        ClaudeSdkCall(cwd: variantProj),
      );
      expect((newRes['result'] as Map)['isError'], isNot(true));

      final listRes = await ClaudeSdkTools.handle(
        {
          'jsonrpc': '2.0',
          'id': 2,
          'method': 'tools/call',
          'params': {
            'name': 'session_list',
            'arguments': {'project': variantOther},
          },
        },
        ClaudeSdkCall(cwd: variantProj, sessionId: SessionTools.idOf(lead)),
      );
      final listText =
          (((listRes['result'] as Map)['content'] as List).single as Map)['text']
              as String;
      expect(listText, contains('OtherCaseProj'));

      // Empty/whitespace project does not spuriously match projects via canonicalize('').
      final emptyListRes = await ClaudeSdkTools.handle(
        {
          'jsonrpc': '2.0',
          'id': 3,
          'method': 'tools/call',
          'params': {
            'name': 'session_list',
            'arguments': {'project': '   '},
          },
        },
        ClaudeSdkCall(cwd: variantProj, sessionId: SessionTools.idOf(lead)),
      );
      final emptyText =
          (((emptyListRes['result'] as Map)['content'] as List).single
                  as Map)['text']
              as String;
      expect(emptyText, 'None.');
    });
  });
}

/// The mock's, each launch under a session id of its own. A message with
/// "(quick)" in it is answered at once, [_quickReply]; one with "(ask)",
/// with a question for the user at once: not the mock's long run.
class _OwnSession implements ClaudeCodeTransport {
  _OwnSession(this._inner, this._id) {
    _inner.messages.listen(_out.add, onDone: _out.close);
  }

  final ClaudeCodeTransport _inner;
  final String _id;
  final _out = StreamController<Map<String, Object?>>.broadcast();

  /// A quick turn under way.
  bool _running = false;
  int _count = 0;

  @override
  Stream<Map<String, Object?>> get messages => _out.stream.map(
    (message) => message.containsKey('session_id')
        ? {...message, 'session_id': _id}
        : message,
  );

  void _emit(Map<String, Object?> message) {
    if (!_out.isClosed) _out.add({...message, 'session_id': _id});
  }

  @override
  void write(Map<String, Object?> message) {
    final text = switch (message) {
      {'type': 'user', 'message': {'content': final List<Object?> content}} =>
        content.whereType<Map<Object?, Object?>>().map((b) => b['text']).join(),
      _ => '',
    };
    if (text.contains('(quick)') || text.contains('(ask)')) {
      final uuid = message['uuid'] as String;
      _running = true;
      _emit({'type': 'system', 'subtype': 'init', 'model': 'claude-opus-5-5'});
      _emit({...message, 'isReplay': true});
      _emit({
        'type': 'command_lifecycle',
        'command_uuid': uuid,
        'state': 'started',
      });
      if (text.contains('(ask)')) {
        final id = 'toolu_q${++_count}';
        final input = {
          'questions': [
            {
              'question': 'Which one?',
              'header': 'Pick',
              'options': [
                {'label': 'This', 'description': ''},
                {'label': 'That', 'description': ''},
              ],
              'multiSelect': false,
            },
          ],
        };
        _emit({
          'type': 'assistant',
          'message': {
            'id': 'msg_q$_count',
            'role': 'assistant',
            'content': [
              {
                'type': 'tool_use',
                'id': id,
                'name': 'AskUserQuestion',
                'input': input,
              },
            ],
          },
          'parent_tool_use_id': null,
        });
        _emit({
          'type': 'control_request',
          'request_id': 'perm_q$_count',
          'request': {
            'subtype': 'can_use_tool',
            'tool_name': 'AskUserQuestion',
            'input': input,
            'tool_use_id': id,
            'requires_user_interaction': true,
          },
        });
        return;
      }
      Timer(const Duration(milliseconds: 100), () {
        if (!_running) return;
        _running = false;
        _emit({
          'type': 'assistant',
          'message': {
            'id': 'msg_q${++_count}',
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': _quickReply},
            ],
          },
          'parent_tool_use_id': null,
        });
        _result();
      });
      return;
    }
    if (message
        case {
          'type': 'control_request',
          'request_id': final String id,
          'request': {'subtype': 'interrupt'},
        }
        when _running) {
      _running = false;
      _emit({
        'type': 'control_response',
        'response': {'subtype': 'success', 'request_id': id, 'response': {}},
      });
      _result(error: true);
      return;
    }
    _inner.write(message);
  }

  void _result({bool error = false}) => _emit({
    'type': 'result',
    'subtype': error ? 'error_during_execution' : 'success',
    'is_error': false,
    'total_cost_usd': 0.01,
    'usage': {'input_tokens': 10, 'output_tokens': 10},
  });

  @override
  void close() => _inner.close();

  @override
  Future<void> get exited => _inner.exited;
}

const _quickReply = 'All looked at.\n\nThe tests pass, and the docs are fine.';

class _DeferredInitTransport implements ClaudeCodeTransport {
  final _out = StreamController<Map<String, Object?>>.broadcast();
  final _exited = Completer<void>();
  String? lastTurnUuid;

  @override
  Stream<Map<String, Object?>> get messages => _out.stream;

  @override
  Future<void> get exited => _exited.future;

  @override
  void write(Map<String, Object?> message) {
    if (_out.isClosed) return;
    if (message['type'] == 'control_request') {
      final id = message['request_id'];
      final sub = (message['request'] as Map?)?['subtype'];
      _out.add({
        'type': 'control_response',
        'response': {
          'subtype': 'success',
          'request_id': id,
          'response': sub == 'initialize'
              ? {
                  'models': [
                    {
                      'value': 'gemini-4-neon',
                      'displayName': 'Gemini 4 Neon',
                      'description': '',
                      'supportsEffort': false,
                      'supportedEffortLevels': <String>[],
                    },
                  ],
                  'commands': const <Object?>[],
                }
              : const <String, Object?>{},
        },
      });
    } else if (message['type'] == 'user') {
      lastTurnUuid = message['uuid'] as String?;
    }
  }

  void bindAndFinishTurn(String sessionId) {
    _out.add({
      'type': 'system',
      'subtype': 'init',
      'session_id': sessionId,
      'model': 'gemini-4-neon',
    });
    _out.add({
      'type': 'result',
      'subtype': 'success',
      'is_error': false,
      'result': 'done',
      'session_id': sessionId,
    });
  }

  @override
  void close() {
    if (!_out.isClosed) _out.close();
    if (!_exited.isCompleted) _exited.complete();
  }
}

class _FakeCodexKernel implements AgentKernel, SelectsModel {
  _FakeCodexKernel(this.descriptor);

  @override
  final KernelDescriptor descriptor;

  final _events = StreamController<KernelEvent>.broadcast();
  final _stopped = Completer<void>();
  int _seq = 0;
  String? _sessionId;
  String _selectedModel = 'gpt-5.4';

  @override
  Stream<KernelEvent> get events => _events.stream;

  @override
  KernelHealth get health => KernelHealth.ready;

  @override
  String? get sessionId => _sessionId;

  @override
  late final KernelChoiceSource model = _FakeChoice(
    options: const [
      KernelOption('gpt-5.4', 'GPT-5.4', Icons.code_rounded, ''),
      KernelOption('gpt-5.4-mini', 'GPT-5.4 Mini', Icons.bolt_rounded, ''),
    ],
    selected: () => _selectedModel,
    onSelected: (id) => _selectedModel = id,
  );

  @override
  void send(KernelTurn turn) {
    _sessionId ??= 'codex-fake-1';
    final parsed = parseAgentMessage(turn.text);
    _events.add(TurnStarted(++_seq, turn.id));
    _events.add(
      ItemUpserted(
        ++_seq,
        turn.id,
        UserMessageItem(
          text: parsed?.text ?? turn.text,
          fromAgent: parsed?.from,
          fromSession: parsed?.session,
        ),
      ),
    );
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
  void dispose() {
    if (!_events.isClosed) _events.close();
    if (!_stopped.isCompleted) _stopped.complete();
  }

  @override
  Future<void> get stopped => _stopped.future;
}

class _FakeChoice implements KernelChoiceSource {
  _FakeChoice({
    required this.options,
    required this._selected,
    required this._onSelected,
  });

  @override
  final List<KernelOption> options;
  final String Function() _selected;
  final void Function(String id) _onSelected;

  @override
  String? get selected => _selected();

  @override
  void select(String id) => _onSelected(id);
}

class _ScriptedEventKernel implements AgentKernel {
  _ScriptedEventKernel(this.descriptor, this.context) {
    instances.add(this);
  }

  static final List<_ScriptedEventKernel> instances = [];

  @override
  final KernelDescriptor descriptor;
  final KernelContext context;
  final _events = StreamController<KernelEvent>.broadcast();
  final _stopped = Completer<void>();
  String? _sessionId;
  int _seq = 0;

  @override
  Stream<KernelEvent> get events => _events.stream;

  @override
  KernelHealth get health => KernelHealth.ready;

  @override
  String? get sessionId => _sessionId;

  void bindSession(String id) {
    _sessionId = id;
    emit(KernelInfoChanged(++_seq));
  }

  void emitTurnStarted(String turnId) => emit(TurnStarted(++_seq, turnId));

  void emitItem(String id, ChatItem item) =>
      emit(ItemUpserted(++_seq, id, item));

  void emitFileEdited(FileChange change, {String? turnId}) =>
      emit(FileEdited(++_seq, change, turnId: turnId));

  void emitTurnEnded(String turnId) => emit(TurnEnded(++_seq, turnId));

  void emit(KernelEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

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
  void dispose() {
    instances.remove(this);
    if (!_events.isClosed) _events.close();
    if (!_stopped.isCompleted) _stopped.complete();
  }

  @override
  Future<void> get stopped => _stopped.future;
}

class _NoopReviewStore implements ReviewStore {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
