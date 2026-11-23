import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/files.dart' show IdeFileExistsException;
import 'package:baocode/customize/customization_store.dart';
import 'package:baocode/customize/customizations.dart';
import 'package:baocode/debug/common/debug_storage.dart';
import 'package:baocode/debug/common/debug_types.dart';
import 'package:baocode/debug/common/repl_model.dart';
import 'package:baocode/debug/service/debug_configuration_manager.dart';
import 'package:baocode/debug/service/debug_host.dart';
import 'package:baocode/debug/service/debug_service.dart';
import 'package:baocode/debug/service/debugger.dart';
import 'package:baocode/debug/session/debug_adapter.dart';
import 'package:baocode/debug/session/debug_session.dart';
import 'package:baocode/kernel/extension_switches.dart';
import 'package:baocode/search/claude_conversation_search.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'helpers/e2e_env.dart';
import 'helpers/e2e_waiters.dart';

class _ScriptedDapTransport extends EmitterDebugAdapterTransport {
  _ScriptedDapTransport({this.failEvaluate = false});

  final bool failEvaluate;
  final List<Json> requests = [];
  int _seq = 1;
  bool stopped = false;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {
    stopped = true;
    fireExit(0);
  }

  void _emit(Json msg) =>
      scheduleMicrotask(() => acceptMessage({'seq': _seq++, ...msg}));

  void _respond(
    Json req, {
    Json? body,
    bool success = true,
    String? message,
  }) => _emit({
    'type': 'response',
    'request_seq': req['seq'],
    'command': req['command'],
    'success': success,
    'message': ?message,
    'body': ?body,
  });

  @override
  void send(Json message) {
    requests.add(message);
    final cmd = message['command'] as String?;
    switch (cmd) {
      case 'initialize':
        _respond(message, body: const {'supportsConfigurationDoneRequest': true});
        _emit({'type': 'event', 'event': 'initialized'});
      case 'launch':
        _respond(message);
      case 'configurationDone':
        _respond(message);
        _emit({
          'type': 'event',
          'event': 'stopped',
          'body': {
            'reason': 'entry',
            'threadId': 1,
            'allThreadsStopped': true,
          },
        });
      case 'disconnect':
      case 'terminate':
        _respond(message);
      case 'threads':
        _respond(message, body: {
          'threads': [
            {'id': 1, 'name': 'main'},
          ],
        });
      case 'stackTrace':
        _respond(message, body: {
          'stackFrames': [
            {
              'id': 10,
              'name': 'main',
              'source': {'name': 'main.js', 'path': '/work/app/main.js'},
              'line': 1,
              'column': 1,
            },
          ],
          'totalFrames': 1,
        });
      case 'scopes':
        _respond(message, body: {'scopes': const []});
      case 'evaluate':
        final expr = (message['arguments'] as Map?)?['expression'] as String?;
        if (failEvaluate || expr == 'boom') {
          _respond(
            message,
            success: false,
            message: 'ReferenceError: boom',
          );
        } else {
          _respond(
            message,
            body: {
              'result': '<lazy>',
              'variablesReference': 77,
              'presentationHint': {'lazy': true},
            },
          );
        }
      case 'variables':
        final ref = (message['arguments'] as Map?)?['variablesReference'];
        if (ref == 77) {
          _respond(
            message,
            body: {
              'variables': [
                {
                  'name': '',
                  'value': '42 (lazy-loaded)',
                  'variablesReference': 0,
                  'presentationHint': <String, Object?>{},
                },
              ],
            },
          );
        } else {
          _respond(message, body: {'variables': const []});
        }
      default:
        _respond(message, body: const {});
    }
  }
}

class _ScriptedDapFactory implements DebugAdapterFactory {
  _ScriptedDapFactory({this.failEvaluate = false});

  final bool failEvaluate;
  _ScriptedDapTransport? lastTransport;

  @override
  DebugAdapterTransport createDebugAdapter(DebugSession session) =>
      lastTransport = _ScriptedDapTransport(failEvaluate: failEvaluate);

  @override
  Future<Json> substituteVariables(DebugWorkspaceFolder? folder, Json config) async =>
      config;

  @override
  Future<int?> runInTerminal(Json args, String sessionId) async => null;
}

Future<({DebugService service, DebugSession session, _ScriptedDapFactory factory})>
_startScriptedDebugSession({bool failEvaluate = false}) async {
  final factory = _ScriptedDapFactory(failEvaluate: failEvaluate);
  final service = DebugService(
    host: DebugServiceHost(),
    storage: MemoryDebugStorageBackend(),
    fileStore: MemoryLaunchFileStore(),
  );
  service.registry.setExtensions([
    const DebuggerExtension(
      id: 'test.e2e-dap',
      debuggers: [
        {'type': 'fake', 'label': 'Fake'},
      ],
    ),
  ]);
  service.registry.registerDebugAdapterFactory(['fake'], factory);
  await service.configurationManager.initialize();
  final ok = await service.startDebugging(null, {
    'type': 'fake',
    'request': 'launch',
    'name': 'Run',
  });
  expect(ok, isTrue);
  await waitUntil(
    () => service.viewModel.focusedStackFrame != null,
    reason: 'Debug session should stop on entry and focus stack frame',
  );
  return (
    service: service,
    session: service.model.getSessions().single,
    factory: factory,
  );
}

void main() {
  late E2eSandbox sandbox;

  setUp(() {
    sandbox = E2eSandbox.create();
    sandbox.useClaudeEnvironment(sandbox.processEnv);
  });

  group('F9 Tier 1 — Multi-Kernel Search, Customization Store & Debug REPL Lazy Eval', () {
    test(
      'F9-T1-01: ConversationSearch indexes Claude, Antigravity brain, CodeBuddy & Codex sessions',
      () async {
        // 1. Claude Code
        File(p.join(sandbox.homeDir.path, '.claude', 'projects', '-proj', 'c1.jsonl'))
          ..createSync(recursive: true)
          ..writeAsStringSync(
            '${jsonEncode({'type': 'user', 'message': {'role': 'user', 'content': 'claude rotation token'}})}\n',
          );

        // 2. Antigravity native brain
        File(
          p.join(
            sandbox.homeDir.path,
            '.gemini',
            'antigravity-cli',
            'brain',
            'agy-s1',
            '.system_generated',
            'logs',
            'transcript.jsonl',
          ),
        )
          ..createSync(recursive: true)
          ..writeAsStringSync([
            jsonEncode({
              'type': 'USER_INPUT',
              'content': '<USER_REQUEST>agy rotation token</USER_REQUEST>',
            }),
            jsonEncode({
              'type': 'PLANNER_RESPONSE',
              'content': 'Acknowledged agy token',
            }),
          ].join('\n'));

        // 3. CodeBuddy
        File(
          p.join(
            sandbox.homeDir.path,
            '.codebuddy',
            'projects',
            '-proj',
            'cb1.jsonl',
          ),
        )
          ..createSync(recursive: true)
          ..writeAsStringSync(
            '${jsonEncode({'type': 'user', 'message': {'role': 'user', 'content': 'codebuddy rotation token'}})}\n',
          );

        // 4. Codex rollout
        File(
          p.join(
            sandbox.homeDir.path,
            '.codex',
            'sessions',
            '2026',
            '11',
            '22',
            'rollout-2026-11-22T10-00-00-cdx1.jsonl',
          ),
        )
          ..createSync(recursive: true)
          ..writeAsStringSync([
            jsonEncode({
              'type': 'session_meta',
              'payload': {'id': 'cdx1', 'cwd': sandbox.projectDir.path},
            }),
            jsonEncode({
              'type': 'event_msg',
              'payload': {'type': 'user_message', 'message': 'codex rotation token'},
            }),
          ].join('\n'));

        final search = ClaudeConversationSearch();
        final hits = await search.search('ROTATION TOKEN');
        final hitIds = hits.map((h) => h.sessionId).toSet();

        expect(hitIds, containsAll(['c1', 'agy-s1', 'cb1', 'cdx1']));
        for (final h in hits) {
          final slice = h.snippet.substring(
            h.matchStart,
            h.matchStart + h.matchLength,
          );
          expect(slice.toLowerCase(), 'rotation token');
        }
      },
    );

    test(
      'F9-T1-02: ConversationSearch incremental re-index on update & eviction on delete across kernels',
      () async {
        final claudeFile = File(
          p.join(sandbox.homeDir.path, '.claude', 'projects', '-proj', 'c-inc.jsonl'),
        )
          ..createSync(recursive: true)
          ..writeAsStringSync(
            '${jsonEncode({'type': 'user', 'message': {'role': 'user', 'content': 'alpha claude'}})}\n',
          );
        final codexFile = File(
          p.join(
            sandbox.homeDir.path,
            '.codex',
            'sessions',
            '2026',
            '11',
            '22',
            'rollout-2026-11-22T10-00-00-cdx-inc.jsonl',
          ),
        )
          ..createSync(recursive: true)
          ..writeAsStringSync([
            jsonEncode({
              'type': 'session_meta',
              'payload': {'id': 'cdx-inc', 'cwd': sandbox.projectDir.path},
            }),
            jsonEncode({
              'type': 'event_msg',
              'payload': {'type': 'user_message', 'message': 'alpha codex'},
            }),
          ].join('\n'));

        final search = ClaudeConversationSearch(
          configDir: sandbox.processEnv['CLAUDE_CONFIG_DIR'],
          homeDir: sandbox.homeDir.path,
        );
        final initialAlpha = await search.search('alpha');
        expect(
          initialAlpha.map((h) => h.sessionId),
          containsAll(['c-inc', 'cdx-inc']),
        );

        claudeFile.deleteSync();
        codexFile.writeAsStringSync([
          jsonEncode({
            'type': 'session_meta',
            'payload': {'id': 'cdx-inc', 'cwd': sandbox.projectDir.path},
          }),
          jsonEncode({
            'type': 'event_msg',
            'payload': {'type': 'user_message', 'message': 'omega codex updated'},
          }),
        ].join('\n'));
        codexFile.setLastModifiedSync(
          DateTime.now().add(const Duration(seconds: 2)),
        );

        expect(await search.search('alpha'), isEmpty);
        final omega = await search.search('omega');
        expect(omega.map((h) => h.sessionId), ['cdx-inc']);
      },
    );

    test(
      'F9-T1-03: CustomizationStore discovers customizations across ~/.claude, ~/.codebuddy, ~/.codex & project',
      () async {
        final agyConfig = p.join(sandbox.homeDir.path, '.gemini', 'config');
        File(p.join(agyConfig, 'skills', 'agy-skill', 'SKILL.md'))
          ..createSync(recursive: true)
          ..writeAsStringSync('---\nname: agy-skill\n---\nAgy\n');
        File(p.join(sandbox.homeDir.path, '.claude', 'skills', 'claude-skill', 'SKILL.md'))
          ..createSync(recursive: true)
          ..writeAsStringSync('---\nname: claude-skill\n---\nClaude\n');
        File(p.join(sandbox.homeDir.path, '.codebuddy', 'skills', 'cb-skill', 'SKILL.md'))
          ..createSync(recursive: true)
          ..writeAsStringSync('---\nname: cb-skill\n---\nCB\n');
        File(p.join(sandbox.homeDir.path, '.codex', 'skills', 'codex-skill', 'SKILL.md'))
          ..createSync(recursive: true)
          ..writeAsStringSync('---\nname: codex-skill\n---\nCodex\n');
        File(p.join(sandbox.projectDir.path, '.agents', 'skills', 'proj-skill', 'SKILL.md'))
          ..createSync(recursive: true)
          ..writeAsStringSync('---\nname: proj-skill\n---\nProject\n');

        final store = CustomizationStore(
          configDir: agyConfig,
          homeDir: sandbox.homeDir.path,
        );
        final skills = await store.list(
          CustomizationKind.skills,
          project: sandbox.projectDir.path,
        );
        final names = skills.map((s) => s.name).toSet();
        expect(
          names,
          containsAll([
            'agy-skill',
            'claude-skill',
            'cb-skill',
            'codex-skill',
            'proj-skill',
          ]),
        );
        expect(
          skills.firstWhere((s) => s.name == 'proj-skill').scope,
          CustomizationScope.project,
        );
        expect(
          skills.firstWhere((s) => s.name == 'claude-skill').scope,
          CustomizationScope.user,
        );
      },
    );

    test(
      'F9-T1-04: CustomizationStore enforces ExtensionSwitches (disabledSkills & disabledServers)',
      () async {
        final agyConfig = p.join(sandbox.homeDir.path, '.gemini', 'config');
        File(p.join(agyConfig, 'skills', 'blocked-skill', 'SKILL.md'))
          ..createSync(recursive: true)
          ..writeAsStringSync('---\nname: blocked-skill\n---\nBlocked\n');
        File(p.join(agyConfig, 'skills', 'active-skill', 'SKILL.md'))
          ..createSync(recursive: true)
          ..writeAsStringSync('---\nname: active-skill\n---\nActive\n');
        File(p.join(agyConfig, 'mcp_config.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync(
            jsonEncode({
              'mcpServers': {
                'blocked-mcp': {'command': 'echo', 'args': ['1']},
                'active-mcp': {'command': 'echo', 'args': ['2']},
              },
            }),
          );

        ExtensionSwitches.current = () => const ExtensionSwitches(
          disabledSkills: {'blocked-skill'},
          disabledServers: {'blocked-mcp'},
        );

        final store = CustomizationStore(
          configDir: agyConfig,
          homeDir: sandbox.homeDir.path,
        );
        final skills = await store.list(CustomizationKind.skills);
        final mcps = await store.list(CustomizationKind.mcps);

        final blockedSkill = skills.firstWhere((s) => s.name == 'blocked-skill');
        final activeSkill = skills.firstWhere((s) => s.name == 'active-skill');
        expect(blockedSkill.enabled, isFalse);
        expect(activeSkill.enabled, isNot(false));

        final blockedMcp = mcps.firstWhere((m) => m.name == 'blocked-mcp');
        final activeMcp = mcps.firstWhere((m) => m.name == 'active-mcp');
        expect(blockedMcp.enabled, isFalse);
        expect(activeMcp.enabled, isNot(false));
      },
    );

    test(
      'F9-T1-05: RawObjectReplElement.evaluateLazy() & ReplEvaluationResult keepLazyVars=true lazy DAP eval',
      () async {
        final raw = RawObjectReplElement('raw-1', 'obj', const {'a': 1});
        await expectLater(raw.evaluateLazy(), completes);

        final dbg = await _startScriptedDebugSession();
        sandbox.onDispose(() async {
          await dbg.service.stopSession(null);
          dbg.service.dispose();
        });

        final frame = dbg.service.viewModel.focusedStackFrame!;
        final result = ReplEvaluationResult('lazyExpr');
        final ok = await result.evaluateExpression(
          'lazyExpr',
          dbg.session,
          frame,
          'repl',
          keepLazyVars: true,
        );
        expect(ok, isTrue);
        // With keepLazyVars: true, DAP variables should NOT be fetched eagerly.
        expect(
          dbg.factory.lastTransport!.requests
              .where((r) => r['command'] == 'variables'),
          isEmpty,
        );
        expect(result.value, '<lazy>');
        expect(result.presentationHint?['lazy'], isTrue);

        await result.evaluateLazy();
        expect(
          dbg.factory.lastTransport!.requests
              .where((r) => r['command'] == 'variables'),
          hasLength(1),
        );
        expect(result.value, '42 (lazy-loaded)');
      },
    );

    test(
      'F9-T1-06: ReplModel collapses identical lines, nests ReplGroup & clears on ANSI 2J',
      () async {
        final dbg = await _startScriptedDebugSession();
        sandbox.onDispose(() async {
          await dbg.service.stopSession(null);
          dbg.service.dispose();
        });

        final repl = ReplModel(
          () => const ReplSettings(collapseIdenticalLines: true, maximumLines: 50),
        );
        sandbox.onDispose(repl.dispose);

        for (var i = 0; i < 3; i++) {
          repl.appendToRepl(
            dbg.session,
            const NewReplElementData(output: 'tick\n', sev: ReplSeverity.info),
          );
        }
        expect(repl.getReplElements(), hasLength(1));
        final first = repl.getReplElements().single as ReplOutputElement;
        expect(first.count, 3);

        repl.startGroup(dbg.session, 'MyGroup', true);
        repl.appendToRepl(
          dbg.session,
          const NewReplElementData(output: 'inside\n', sev: ReplSeverity.info),
        );
        repl.endGroup();
        expect(repl.getReplElements(), hasLength(2));
        final grp = repl.getReplElements().last as ReplGroup;
        expect(grp.children, hasLength(1));

        repl.appendToRepl(
          dbg.session,
          const NewReplElementData(
            output: '\u001b[2Jafter clear\n',
            sev: ReplSeverity.info,
          ),
        );
        final after = repl.getReplElements();
        expect(after.map((e) => e.toString()).join('\n'), contains('Console was cleared'));
        expect(after.map((e) => e.toString()).join('\n'), contains('after clear'));
        expect(after.any((e) => e is ReplGroup), isFalse);
      },
    );
  });

  group('F9 Tier 2 — Search Exclusions, Corrupt Files & REPL Boundaries', () {
    test(
      'F9-T2-01: ConversationSearch excludes thinking, tool_use, tool_result, isMeta, isSidechain & XML wrappers',
      () async {
        File(
          p.join(
            sandbox.homeDir.path,
            '.claude',
            'projects',
            '-proj',
            'hidden.jsonl',
          ),
        )
          ..createSync(recursive: true)
          ..writeAsStringSync([
            jsonEncode({
              'type': 'user',
              'isMeta': true,
              'message': {'role': 'user', 'content': 'SECRET_NEEDLE'},
            }),
            jsonEncode({
              'type': 'user',
              'isSidechain': true,
              'message': {'role': 'user', 'content': 'SECRET_NEEDLE'},
            }),
            jsonEncode({
              'type': 'user',
              'message': {
                'role': 'user',
                'content': '<system-reminder>SECRET_NEEDLE</system-reminder>',
              },
            }),
            jsonEncode({
              'type': 'assistant',
              'message': {
                'role': 'assistant',
                'content': [
                  {'type': 'thinking', 'thinking': 'SECRET_NEEDLE'},
                  {
                    'type': 'tool_use',
                    'id': 't1',
                    'name': 'Bash',
                    'input': {'command': 'echo SECRET_NEEDLE'},
                  },
                ],
              },
            }),
            jsonEncode({
              'type': 'user',
              'message': {
                'role': 'user',
                'content': [
                  {
                    'type': 'tool_result',
                    'tool_use_id': 't1',
                    'content': 'SECRET_NEEDLE',
                  },
                ],
              },
            }),
            jsonEncode({
              'type': 'assistant',
              'message': {
                'role': 'assistant',
                'content': [
                  {'type': 'text', 'text': 'VISIBLE_NEEDLE'},
                ],
              },
            }),
          ].join('\n'));

        final search = ClaudeConversationSearch(
          configDir: sandbox.processEnv['CLAUDE_CONFIG_DIR'],
        );
        expect(await search.search('SECRET_NEEDLE'), isEmpty);
        final visibleHits = await search.search('VISIBLE_NEEDLE');
        expect(visibleHits, hasLength(1));
        expect(visibleHits.single.sessionId, 'hidden');
      },
    );

    test(
      'F9-T2-02: ConversationSearch handles empty query, limit=1 newest-first, zero-byte & corrupt UTF-8/JSONL',
      () async {
        final projDir = Directory(
          p.join(sandbox.homeDir.path, '.claude', 'projects', '-proj'),
        )..createSync(recursive: true);

        File(p.join(projDir.path, 'empty.jsonl')).writeAsStringSync('');
        File(p.join(projDir.path, 'corrupt.jsonl')).writeAsBytesSync([
          0xff,
          0xfe,
          ...utf8.encode('\n{not-json\n'),
        ]);

        final oldFile = File(p.join(projDir.path, 'old.jsonl'))
          ..writeAsStringSync(
            '${jsonEncode({'type': 'user', 'message': {'role': 'user', 'content': 'match token old'}})}\n',
          )
          ..setLastModifiedSync(DateTime.utc(2026, 1, 1));
        final newFile = File(p.join(projDir.path, 'new.jsonl'))
          ..writeAsStringSync(
            '${jsonEncode({'type': 'user', 'message': {'role': 'user', 'content': 'match token new'}})}\n',
          )
          ..setLastModifiedSync(DateTime.utc(2026, 11, 22));
        expect(oldFile.existsSync() && newFile.existsSync(), isTrue);

        final search = ClaudeConversationSearch(
          configDir: sandbox.processEnv['CLAUDE_CONFIG_DIR'],
        );
        expect(await search.search(''), isEmpty);
        expect(await search.search('   '), isEmpty);

        final limited = await search.search('match token', limit: 1);
        expect(limited, hasLength(1));
        expect(limited.single.sessionId, 'new');
      },
    );

    test(
      'F9-T2-03: CustomizationStore tolerates malformed JSON in mcp_config.json, hooks.json & config.json',
      () async {
        final agyConfig = p.join(sandbox.homeDir.path, '.gemini', 'config');
        File(p.join(agyConfig, 'mcp_config.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync('{broken');
        File(p.join(agyConfig, 'hooks.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync('{broken');
        File(p.join(agyConfig, 'config.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync('{broken');
        File(p.join(sandbox.projectDir.path, '.agents', 'mcp_config.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync('{broken');

        final store = CustomizationStore(
          configDir: agyConfig,
          homeDir: sandbox.homeDir.path,
        );
        for (final kind in CustomizationKind.values) {
          await expectLater(
            store.list(kind, project: sandbox.projectDir.path),
            completes,
          );
        }
      },
    );

    test(
      'F9-T2-04: CustomizationStore.create & delete enforce name validation & duplicate checks',
      () async {
        final agyConfig = p.join(sandbox.homeDir.path, '.gemini', 'config');
        final store = CustomizationStore(
          configDir: agyConfig,
          homeDir: sandbox.homeDir.path,
        );

        await expectLater(
          () => store.create(
            CustomizationKind.skills,
            CustomizationScope.user,
            'bad/name',
          ),
          throwsArgumentError,
        );

        final createdPath = await store.create(
          CustomizationKind.skills,
          CustomizationScope.user,
          'my-skill',
        );
        expect(File(createdPath).existsSync(), isTrue);

        await expectLater(
          () => store.create(
            CustomizationKind.skills,
            CustomizationScope.user,
            'my-skill',
          ),
          throwsA(isA<IdeFileExistsException>()),
        );

        final skills = await store.list(CustomizationKind.skills);
        final mySkill = skills.firstWhere((s) => s.name == 'my-skill');
        await store.delete(mySkill);
        expect(File(createdPath).existsSync(), isFalse);
      },
    );

    test(
      'F9-T2-05: ReplEvaluationResult without session, failed DAP evaluate & null-reference evaluateLazy',
      () async {
        final noSessionResult = ReplEvaluationResult('x');
        final noSessionOk = await noSessionResult.evaluateExpression(
          'x',
          null,
          null,
          'repl',
        );
        expect(noSessionOk, isFalse);
        expect(
          noSessionResult.value,
          'Please start a debug session to evaluate expressions',
        );
        await expectLater(noSessionResult.evaluateLazy(), completes);

        final dbg = await _startScriptedDebugSession(failEvaluate: true);
        sandbox.onDispose(() async {
          await dbg.service.stopSession(null);
          dbg.service.dispose();
        });

        final frame = dbg.service.viewModel.focusedStackFrame!;
        final repl = ReplModel();
        sandbox.onDispose(repl.dispose);

        await repl.addReplExpression(dbg.session, frame, 'boom');
        final elements = repl.getReplElements();
        final evalResult = elements.whereType<ReplEvaluationResult>().single;
        expect(evalResult.available, isFalse);
        expect(evalResult.value, contains('ReferenceError: boom'));
        await expectLater(evalResult.evaluateLazy(), completes);
      },
    );

    test(
      'F9-T2-06: ReplModel maximumLines eviction & RawObjectReplElement >1000 children cap',
      () async {
        final dbg = await _startScriptedDebugSession();
        sandbox.onDispose(() async {
          await dbg.service.stopSession(null);
          dbg.service.dispose();
        });

        final repl = ReplModel(
          () => const ReplSettings(collapseIdenticalLines: false, maximumLines: 5),
        );
        sandbox.onDispose(repl.dispose);

        for (var i = 1; i <= 12; i++) {
          repl.appendToRepl(
            dbg.session,
            NewReplElementData(output: 'line-$i\n', sev: ReplSeverity.info),
          );
        }
        final kept = repl.getReplElements();
        expect(kept, hasLength(5));
        expect(kept.first.toString(), 'line-8\n');
        expect(kept.last.toString(), 'line-12\n');

        final raw = RawObjectReplElement(
          'big-1',
          'bigList',
          List<int>.generate(1200, (i) => i),
        );
        final children = await raw.getChildren();
        expect(children, hasLength(1000));
        await expectLater(raw.evaluateLazy(), completes);
      },
    );
  });
}
