import 'dart:async';
import 'dart:convert';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/session_links.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/antigravity/antigravity_cli.dart';
import 'package:baocode/kernel/antigravity/antigravity_transport.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_translator.dart';
import 'package:baocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:baocode/kernel/codebuddy/codebuddy_cli.dart';
import 'package:baocode/kernel/codex/codex_kernel.dart';
import 'package:baocode/kernel/codex/codex_transport.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_registry.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/workspace/session_tools.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/e2e_env.dart';
import 'helpers/e2e_waiters.dart';
import 'helpers/fake_cli_harness.dart';

/// In-process [CodexTransport] for deterministic cross-kernel `SessionTools`
/// and `<agent-message>` E2E tests.
class _ScriptedCodexTransport implements CodexTransport {
  _ScriptedCodexTransport({this.replyText = 'CODEX_OK'});

  final String replyText;
  final StreamController<Map<String, Object?>> _messages =
      StreamController<Map<String, Object?>>.broadcast();
  final List<Map<String, Object?>> written = [];
  bool closed = false;
  int _turnSeq = 0;

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  @override
  void write(Map<String, Object?> message) {
    written.add(message);
    final id = message['id'];
    switch (message['method']) {
      case 'initialize':
        _emit({'id': id, 'result': const <String, Object?>{}});
      case 'model/list':
        _emit({
          'id': id,
          'result': {
            'data': [
              {
                'id': 'gpt-5.5-codex',
                'displayName': 'GPT-5.5 Codex',
                'description': 'Tuned for coding',
                'isDefault': true,
                'supportedReasoningEfforts': [
                  {'reasoningEffort': 'medium'},
                  {'reasoningEffort': 'high'},
                ],
                'defaultReasoningEffort': 'medium',
              },
            ],
          },
        });
      case 'thread/start':
        _emit({
          'id': id,
          'result': {
            'thread': {'id': 'codex-thread-1'},
          },
        });
      case 'turn/start':
        final turnId = 'codex-turn-${++_turnSeq}';
        _emit({
          'id': id,
          'result': {
            'turn': {'id': turnId},
          },
        });
        scheduleMicrotask(() {
          _emit({
            'method': 'turn/started',
            'params': {
              'turn': {'id': turnId},
            },
          });
          _emit({
            'method': 'item/completed',
            'params': {
              'item': {
                'id': 'msg-$turnId',
                'type': 'agentMessage',
                'text': replyText,
              },
            },
          });
          _emit({
            'method': 'turn/completed',
            'params': {
              'turn': {'id': turnId, 'status': 'completed'},
            },
          });
        });
    }
  }

  void _emit(Map<String, Object?> msg) {
    if (!closed && !_messages.isClosed) {
      _messages.add(msg);
    }
  }

  @override
  void close() {
    if (closed) return;
    closed = true;
    unawaited(_messages.close());
  }
}

void main() {
  late E2eSandbox sandbox;
  late Workspace workspace;
  late int agySeq;
  late int cbSeq;
  late int claudeSeq;
  late Map<String, ScriptedClaudeTransport> transportsBySessionId;
  late List<_ScriptedCodexTransport> codexTransports;
  UserTurnHandler? cbOnUserTurn;
  late KernelDescriptor agyKernel;
  late KernelDescriptor cbKernel;
  late KernelDescriptor claudeKernel;
  late KernelDescriptor codexKernel;

  setUp(() {
    sandbox = E2eSandbox.create();
    SessionToolsSetting.current = () => true;
    agySeq = 0;
    cbSeq = 0;
    claudeSeq = 0;
    transportsBySessionId = {};
    codexTransports = [];
    cbOnUserTurn = null;

    agyKernel = KernelDescriptor(
      id: antigravityBuiltinProviderId,
      label: 'Antigravity',
      icon: Icons.rocket_launch_rounded,
      description: 'Antigravity',
      create: (ctx) => ClaudeCodeKernel(
        agyKernel,
        ctx,
        start: (launch) async {
          final sid = launch.resume ?? 'agy-${++agySeq}';
          final t = ScriptedClaudeTransport(
            launch: launch,
            sessionId: sid,
            onUserTurn: (tr, msg) => tr.emitSimpleReply('AGY_OK'),
          );
          transportsBySessionId[sid] = t;
          return t;
        },
      ),
    );
    cbKernel = KernelDescriptor(
      id: codebuddyBuiltinProviderId,
      label: 'CodeBuddy',
      icon: Icons.auto_awesome_rounded,
      description: 'CodeBuddy',
      create: (ctx) => ClaudeCodeKernel(
        cbKernel,
        ctx,
        start: (launch) async {
          final sid = launch.resume ?? 'cb-${++cbSeq}';
          final t = ScriptedClaudeTransport(
            launch: launch,
            sessionId: sid,
            onUserTurn: (tr, msg) {
              if (cbOnUserTurn case final custom?) {
                custom(tr, msg);
              } else {
                tr.emitSimpleReply('CB_OK');
              }
            },
          );
          transportsBySessionId[sid] = t;
          return t;
        },
      ),
    );
    claudeKernel = KernelDescriptor(
      id: claudeCodeKernelId,
      label: 'Claude Code',
      icon: Icons.terminal_rounded,
      description: 'Claude Code',
      create: (ctx) => ClaudeCodeKernel(
        claudeKernel,
        ctx,
        start: (launch) async {
          final sid = launch.resume ?? 'cc-${++claudeSeq}';
          final t = ScriptedClaudeTransport(
            launch: launch,
            sessionId: sid,
            onUserTurn: (tr, msg) => tr.emitSimpleReply('CC_OK'),
          );
          transportsBySessionId[sid] = t;
          return t;
        },
      ),
    );
    codexKernel = KernelDescriptor(
      id: codexKernelId,
      label: 'Codex',
      icon: Icons.bolt_rounded,
      description: 'Codex',
      create: (ctx) {
        final t = _ScriptedCodexTransport(replyText: 'TASK_RESULT_OK');
        codexTransports.add(t);
        return CodexKernel(codexKernel, t);
      },
    );

    workspace = Workspace(
      kernels: [agyKernel, cbKernel, claudeKernel, codexKernel],
      projects: [Project('app', sandbox.projectDir.path)],
    );
    SessionTools.register(workspace);
    sandbox.onDispose(() {
      SessionTools.unregister();
      workspace.dispose();
    });
  });

  Future<Map<String, Object?>> callToolRaw(
    String tool,
    Map<String, Object?> arguments, {
    String? from,
  }) async {
    final answer = await ClaudeSdkTools.handle({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/call',
      'params': {'name': tool, 'arguments': arguments},
    }, ClaudeSdkCall(cwd: sandbox.projectDir.path, sessionId: from));
    return answer['result'] as Map<String, Object?>;
  }

  Future<String> callTool(
    String tool,
    Map<String, Object?> arguments, {
    String? from,
  }) async {
    final result = await callToolRaw(tool, arguments, from: from);
    expect(
      result['isError'],
      isNot(true),
      reason: 'Tool $tool failed: ${jsonEncode(result)}',
    );
    return ((result['content'] as List).single as Map)['text'] as String;
  }

  group('F3 Tier 1 — SessionTools Cross-Kernel Bridge & mapTool', () {
    test(
      'F3-T1-01: AntigravityTransport.mapTool normalizes baocode MCP tool names for ClaudeTranslator and SessionLinks',
      () {
        const variants = [
          'mcp__baocode__session_new',
          'baocode:session_new',
          'mcp_baocode_session_new',
          'session_new',
        ];
        for (final raw in variants) {
          final mapped = AntigravityTransport.mapTool(
            raw,
            {'text': jsonEncode('work'), 'project': jsonEncode('app')},
            'Started: worker-1 in app.',
            defaultCwd: sandbox.projectDir.path,
          );
          expect(
            mapped.name,
            'mcp__baocode__session_new',
            reason: 'Expected $raw to normalize to mcp__baocode__session_new',
          );
          expect(ClaudeSdkTools.called(mapped.name), isNotNull);

          final events = <KernelEvent>[];
          final translator = ClaudeTranslator(
            emit: events.add,
            nextSeq: () => events.length + 1,
          )..turnId = 't1';
          translator.translate({
            'type': 'assistant',
            'uuid': 'a1',
            'message': {
              'id': 'm1',
              'role': 'assistant',
              'content': [
                {
                  'type': 'tool_use',
                  'id': 'call-1',
                  'name': mapped.name,
                  'input': mapped.input,
                },
              ],
            },
          });
          translator.translate({
            'type': 'user',
            'uuid': 'u1',
            'message': {
              'role': 'user',
              'content': [
                {
                  'type': 'tool_result',
                  'tool_use_id': 'call-1',
                  'content': 'Started: worker-1 in app.',
                  'is_error': false,
                },
              ],
            },
          });
          final item = events
              .whereType<ItemUpserted>()
              .map((e) => e.item)
              .whereType<ToolCallItem>()
              .last;
          expect(isSessionTool(item.tool), isTrue);
          expect(sessionIdsOf(item), ['worker-1']);
        }
      },
    );

    test(
      'F3-T1-02: SessionTools._hand wraps <agent-message> for antigravity-cli and codebuddy-cli workers',
      () async {
        final lead = workspace.startAgent(workspace.projectAt(sandbox.projectDir.path));
        workspace.rename(lead, 'Lead');
        lead.session.send(const ComposerMessage(text: 'boot'));
        await settleAgentTurn(lead);
        final leadId = SessionTools.idOf(lead);

        final agyWorker = workspace.startAgent(
          workspace.projectAt(sandbox.projectDir.path),
        );
        agyWorker.session.setKernel(agyKernel);
        agyWorker.session.send(const ComposerMessage(text: 'init agy'));
        await settleAgentTurn(agyWorker);

        final cbWorker = workspace.startAgent(
          workspace.projectAt(sandbox.projectDir.path),
        );
        cbWorker.session.setKernel(cbKernel);
        cbWorker.session.send(const ComposerMessage(text: 'init cb'));
        await settleAgentTurn(cbWorker);

        await callTool(
          'session_send',
          {'session': SessionTools.idOf(agyWorker), 'text': 'do agy work'},
          from: leadId,
        );
        await settleAgentTurn(agyWorker);
        final agyMsgs = [
          for (var i = 0; i < agyWorker.session.itemCount; i++)
            if (agyWorker.session.itemAt(i) case UserMessageItem item) item,
        ];
        expect(
          agyMsgs.any(
            (m) =>
                m.fromAgent == 'Lead' &&
                m.fromSession == leadId &&
                m.text == 'do agy work',
          ),
          isTrue,
          reason:
              'Antigravity worker must receive structured fromAgent/fromSession UserMessageItem',
        );

        await callTool(
          'session_send',
          {'session': SessionTools.idOf(cbWorker), 'text': 'do cb work'},
          from: leadId,
        );
        await settleAgentTurn(cbWorker);
        final cbMsgs = [
          for (var i = 0; i < cbWorker.session.itemCount; i++)
            if (cbWorker.session.itemAt(i) case UserMessageItem item) item,
        ];
        expect(
          cbMsgs.any(
            (m) =>
                m.fromAgent == 'Lead' &&
                m.fromSession == leadId &&
                m.text == 'do cb work',
          ),
          isTrue,
          reason:
              'CodeBuddy worker must receive structured fromAgent/fromSession UserMessageItem',
        );
      },
    );

    test(
      'F3-T1-03: auto-report delivery renders <agent-message> cleanly on CodexKernel recipient',
      () async {
        final codexLead = workspace.startAgent(
          workspace.projectAt(sandbox.projectDir.path),
        );
        codexLead.session.setKernel(codexKernel);
        workspace.rename(codexLead, 'CodexLead');
        codexLead.session.send(const ComposerMessage(text: 'boot codex'));
        await waitUntil(() => !codexLead.session.isStreaming);
        final leadId = SessionTools.idOf(codexLead);

        final worker = workspace.startAgent(
          workspace.projectAt(sandbox.projectDir.path),
        );
        worker.session.setKernel(agyKernel);
        workspace.rename(worker, 'AgyWorker');
        await callTool(
          'session_send',
          {'session': SessionTools.idOf(worker), 'text': 'run check'},
          from: leadId,
        );

        await waitUntil(() {
          for (var i = 0; i < codexLead.session.itemCount; i++) {
            final item = codexLead.session.itemAt(i);
            if (item is UserMessageItem && item.fromAgent == 'AgyWorker') {
              return true;
            }
          }
          return false;
        }, reason: 'CodexLead did not receive parsed report from AgyWorker');

        final report = [
          for (var i = 0; i < codexLead.session.itemCount; i++)
            if (codexLead.session.itemAt(i) case UserMessageItem item
                when item.fromAgent == 'AgyWorker')
              item,
        ].single;
        expect(report.text, isNot(contains('<agent-message')));
        expect(report.text, contains('AGY_OK'));
      },
    );

    test(
      'F3-T1-04: session_models lists kernels and session_new accepts explicit kernel and model',
      () async {
        final lead = workspace.startAgent(workspace.projectAt(sandbox.projectDir.path));
        lead.session.send(const ComposerMessage(text: 'boot'));
        await settleAgentTurn(lead);
        final leadId = SessionTools.idOf(lead);

        final modelsOutput = await callTool('session_models', {}, from: leadId);
        expect(
          modelsOutput,
          contains(codexKernelId),
          reason: 'session_models must list available kernels including codex',
        );

        final started = await callTool(
          'session_new',
          {
            'text': 'implement codex task',
            'kernel': codexKernelId,
            'model': 'gpt-5.5-codex',
          },
          from: leadId,
        );
        expect(started, startsWith('Started: '));
        final workerId = RegExp(r'^Started: (\S+)').firstMatch(started)![1]!;
        final worker = SessionTools.threadOf(workspace, workerId);
        expect(worker, isNotNull);
        expect(worker!.kernel.id, codexKernelId);
        expect(SessionTools.modelOf(worker)?.id, 'gpt-5.5-codex');
      },
    );

    test(
      'F3-T1-05: SessionTools.handedFrom tracks agy step_update for session_new',
      () async {
        late KernelDescriptor agyExecKernel;
        late String targetWorkerId;
        final fakeAgy = FakeCliExecutable.create(
          sandbox.rootDir,
          name: 'fake_agy_f3_05',
          dartBody: r'''
Future<void> main(List<String> args) async {
  final workerId = Platform.environment['E2E_TARGET_WORKER_ID'] ?? 'missing';
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    stdout.writeln(jsonEncode({'event': 'init', 'conversation_id': 'agy-lead-conv'}));
    stdout.writeln(jsonEncode({
      'event': 'step_update',
      'step_update': {
        'step_index': 1,
        'step_type': 'tool',
        'state': 'DONE',
        'tool_info': {
          'name': 'baocode:session_new',
          'parameters': {'text': jsonEncode('work'), 'project': jsonEncode('app')},
          'output': 'Started: $workerId in app.',
        },
      },
    }));
    stdout.writeln(jsonEncode({
      'event': 'result',
      'result': {'conversation_id': 'agy-lead-conv', 'status': 'SUCCESS', 'response': 'done'},
    }));
    await stdout.flush();
  }
}
''',
        );

        var nextId = 0;
        agyExecKernel = KernelDescriptor(
          id: antigravityBuiltinProviderId,
          label: 'Antigravity',
          icon: Icons.rocket_launch_rounded,
          description: 'Antigravity',
          create: (ctx) => ClaudeCodeKernel(
            agyExecKernel,
            ctx,
            start: (launch) async {
              if (++nextId == 1) {
                return ScriptedClaudeTransport(
                  launch: launch,
                  sessionId: 'worker-scripted-1',
                  onUserTurn: (tr, msg) => tr.emitSimpleReply('W_OK'),
                );
              }
              return AntigravityTransport.forTesting(
                executable: fakeAgy.executablePath,
                environment: {
                  ...sandbox.processEnv,
                  'E2E_TARGET_WORKER_ID': targetWorkerId,
                },
                launch: launch,
              );
            },
          ),
        );

        final ws = Workspace(
          kernels: [agyExecKernel],
          projects: [Project('app', sandbox.projectDir.path)],
        );
        sandbox.onDispose(ws.dispose);

        final worker = ws.startAgent(ws.projectAt(sandbox.projectDir.path));
        worker.session.send(const ComposerMessage(text: 'worker boot'));
        await settleAgentTurn(worker);
        targetWorkerId = SessionTools.idOf(worker);

        final lead = ws.startAgent(ws.projectAt(sandbox.projectDir.path));
        lead.session.send(const ComposerMessage(text: 'delegate'));
        await settleAgentTurn(lead);

        final toolItems = [
          for (var i = 0; i < lead.session.itemCount; i++)
            if (lead.session.itemAt(i) case ToolCallItem item) item,
        ];
        expect(
          toolItems.any((t) => t.tool == 'session_new' && isSessionTool(t.tool)),
          isTrue,
          reason:
              'baocode:session_new step_update must normalize to ToolCallItem(tool: session_new)',
        );
        expect(
          SessionTools.handedFrom(lead.session, ws),
          contains(worker),
        );
      },
    );
  });

  group('F3 Tier 2 — Pre-Init Correlation, Validation & Edge Cases', () {
    test(
      'F3-T2-01: caller matching works before agy emits conversation_id (thread.id == null)',
      () async {
        // Lead has NOT sent a turn yet -> thread.id is null.
        final lead = workspace.startAgent(workspace.projectAt(sandbox.projectDir.path));
        workspace.rename(lead, 'PreInitLead');
        expect(lead.id, isNull);
        final callerKey = SessionTools.idOf(lead);

        final other = workspace.startAgent(
          workspace.projectAt(sandbox.projectDir.path),
        );
        workspace.rename(other, 'WorkerB');

        final listed = await callTool('session_list', {}, from: callerKey);
        expect(listed, contains('WorkerB'));
        expect(
          listed,
          isNot(contains('PreInitLead')),
          reason:
              'session_list must exclude the caller even when caller thread.id is null',
        );

        final selfSend = await callToolRaw(
          'session_send',
          {'session': callerKey, 'text': 'echo self'},
          from: callerKey,
        );
        expect(selfSend['isError'], isTrue);
        expect(
          ((selfSend['content'] as List).single as Map)['text'],
          contains('That is this conversation.'),
        );
      },
    );

    test(
      'F3-T2-02: invalid kernel or invalid cross-kernel model in session_new returns isError without orphan thread',
      () async {
        final lead = workspace.startAgent(workspace.projectAt(sandbox.projectDir.path));
        lead.session.send(const ComposerMessage(text: 'boot'));
        await settleAgentTurn(lead);
        final leadId = SessionTools.idOf(lead);
        final countBefore = workspace.threads.length;

        final badKernel = await callToolRaw(
          'session_new',
          {'text': 'x', 'kernel': 'nonexistent-kernel'},
          from: leadId,
        );
        expect(badKernel['isError'], isTrue);
        expect(workspace.threads, hasLength(countBefore));

        final badModel = await callToolRaw(
          'session_new',
          {'text': 'x', 'kernel': codexKernelId, 'model': 'invalid-model-xyz'},
          from: leadId,
        );
        expect(badModel['isError'], isTrue);
        expect(workspace.threads, hasLength(countBefore));
      },
    );

    test(
      'F3-T2-03: CodexKernel handles malformed and partial <agent-message> tags safely',
      () async {
        final t = _ScriptedCodexTransport();
        final kernel = CodexKernel(codexKernel, t);
        sandbox.onDispose(kernel.dispose);

        final items = <ChatItem>[];
        final sub = kernel.events.listen((e) {
          if (e is ItemUpserted) items.add(e.item);
        });
        sandbox.onDispose(() => unawaited(sub.cancel()));

        kernel.send(
          const KernelTurn(id: 't-malformed', text: '<agent-message from="A">unclosed'),
        );
        kernel.send(
          const KernelTurn(
            id: 't-empty-attrs',
            text: '<agent-message from="" session="">empty</agent-message>',
          ),
        );
        kernel.send(const KernelTurn(id: 't-normal', text: 'plain text'));
        await waitUntil(() => items.whereType<UserMessageItem>().length >= 3);

        final users = items.whereType<UserMessageItem>().toList();
        expect(users[0].text, '<agent-message from="A">unclosed');
        expect(users[0].fromAgent, isNull);
        expect(users[1].text, '<agent-message from="" session="">empty</agent-message>');
        expect(users[1].fromAgent, isNull);
        expect(users[1].fromSession, isNull);
        expect(users[2].text, 'plain text');
      },
    );

    test(
      'F3-T2-04: duplicate session_send debounce and session_stop unfollow across kernels',
      () async {
        final lead = workspace.startAgent(workspace.projectAt(sandbox.projectDir.path));
        lead.session.send(const ComposerMessage(text: 'boot'));
        await settleAgentTurn(lead);
        final leadId = SessionTools.idOf(lead);

        final worker = workspace.startAgent(
          workspace.projectAt(sandbox.projectDir.path),
        );
        worker.session.setKernel(cbKernel);
        worker.session.send(const ComposerMessage(text: 'init'));
        await settleAgentTurn(worker);
        final workerId = SessionTools.idOf(worker);

        final first = await callTool(
          'session_send',
          {'session': workerId, 'text': 'repeated task'},
          from: leadId,
        );
        expect(first, startsWith('Sent:'));
        await settleAgentTurn(worker);

        final dup = await callTool(
          'session_send',
          {'session': workerId, 'text': 'repeated task'},
          from: leadId,
        );
        expect(dup, startsWith('Not delivered: the same message'));

        // Hold a running turn on a CodeBuddy worker so session_stop stops an active turn.
        final heldTurn = Completer<void>();
        cbOnUserTurn = (tr, msg) {
          unawaited(heldTurn.future.then((_) => tr.emitSimpleReply('DONE')));
        };
        final workerWithHold = workspace.startAgent(
          workspace.projectAt(sandbox.projectDir.path),
        );
        workerWithHold.session.setKernel(cbKernel);
        workerWithHold.session.send(const ComposerMessage(text: 'long work'));
        await waitUntil(
          () =>
              workerWithHold.session.sessionId != null &&
              workerWithHold.session.isStreaming,
          reason:
              'workerWithHold never became streaming with sessionId '
              '(sessionId=${workerWithHold.session.sessionId}, '
              'isStreaming=${workerWithHold.session.isStreaming}, '
              'health=${workerWithHold.session.health.status})',
        );
        sandbox.onDispose(() {
          if (!heldTurn.isCompleted) heldTurn.complete();
        });

        final stopped = await callTool(
          'session_stop',
          {'session': SessionTools.idOf(workerWithHold)},
          from: leadId,
        );
        expect(stopped, contains('Stopped'));
        await waitUntil(
          () => !workerWithHold.session.isStreaming,
          reason: 'workerWithHold stayed streaming after session_stop',
        );
      },
    );

    test(
      'F3-T2-05: flipping SessionToolsSetting.current to false disables session_* mid-run',
      () async {
        final lead = workspace.startAgent(workspace.projectAt(sandbox.projectDir.path));
        lead.session.send(const ComposerMessage(text: 'boot'));
        await settleAgentTurn(lead);
        final leadId = SessionTools.idOf(lead);

        SessionToolsSetting.current = () => false;
        final res = await callToolRaw('session_list', {}, from: leadId);
        expect(res['isError'], isTrue);
      },
    );
  });
}
