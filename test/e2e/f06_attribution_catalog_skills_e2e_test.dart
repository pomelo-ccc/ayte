import 'dart:convert';
import 'dart:io';

import 'package:bao_agent/bao_agent.dart' show AgentPaths;
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/customize/customization_store.dart';
import 'package:baocode/customize/customizations.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/antigravity/antigravity_catalog.dart';
import 'package:baocode/kernel/antigravity/antigravity_cli.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_storage_io.dart';
import 'package:baocode/kernel/codebuddy/codebuddy_cli.dart';
import 'package:baocode/kernel/kernel_registry.dart';
import 'package:baocode/remote/remote_claude.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'helpers/e2e_env.dart';
import 'helpers/e2e_waiters.dart';
import 'helpers/fake_cli_harness.dart';

void _writeClaudeJsonl({
  required AgentPaths paths,
  required String cwd,
  required String sessionId,
  required String model,
  String? uuid,
  String prompt = 'Hello kernel',
}) {
  final file = File(paths.sessionFile(cwd, sessionId));
  file.parent.createSync(recursive: true);
  final now = DateTime.now().toUtc().toIso8601String();
  final lines = [
    jsonEncode({
      'type': 'user',
      'uuid': ?uuid,
      'timestamp': now,
      'cwd': cwd,
      'sessionId': sessionId,
      'message': {'role': 'user', 'content': prompt},
    }),
    jsonEncode({
      'type': 'assistant',
      if (uuid != null) 'uuid': '$uuid-a',
      'timestamp': now,
      'cwd': cwd,
      'sessionId': sessionId,
      'message': {
        'id': 'msg-$sessionId',
        'role': 'assistant',
        'model': model,
        'content': [
          {'type': 'text', 'text': 'Done'},
        ],
      },
    }),
  ];
  file.writeAsStringSync('${lines.join('\n')}\n');
}

void main() {
  late E2eSandbox sandbox;
  late String claudeConfigDir;
  late AgentPaths sandboxPaths;
  late ClaudeCatalog sandboxClaudeCatalog;
  late AntigravityCatalog sandboxAgyCatalog;

  setUp(() {
    sandbox = E2eSandbox.create();
    claudeConfigDir = sandbox.processEnv['CLAUDE_CONFIG_DIR']!;
    sandboxPaths = AgentPaths(
      home: sandbox.homeDir.path,
      configDir: claudeConfigDir,
    );
    sandboxClaudeCatalog = ClaudeCatalog(
      local: ClaudeStorage(
        configDir: claudeConfigDir,
        cacheFile: p.join(sandbox.dataDir.path, 'claude-sessions.json'),
      ),
    );
    sandboxAgyCatalog = AntigravityCatalog(
      homeDir: sandbox.homeDir.path,
      paths: sandboxPaths,
      claude: sandboxClaudeCatalog,
    );
  });

  List<KernelDescriptor> makeScriptedKernels(
    Map<String, String> nextSessionIds,
  ) {
    late KernelDescriptor agy;
    late KernelDescriptor cb;
    late KernelDescriptor cc;

    agy = KernelDescriptor(
      id: antigravityBuiltinProviderId,
      label: 'Antigravity',
      icon: Icons.rocket_launch_rounded,
      description: 'Antigravity',
      catalog: sandboxAgyCatalog,
      create: (ctx) => ClaudeCodeKernel(
        agy,
        ctx,
        start: (launch) async {
          final sid =
              launch.resume ?? nextSessionIds[agy.id] ?? 'agy-sess-default';
          return ScriptedClaudeTransport(
            launch: launch,
            sessionId: sid,
            onUserTurn: (tr, _) => tr.emitSimpleReply('AGY_OK', model: 'gemini-3.8-flash-high'),
          );
        },
      ),
    );
    cb = KernelDescriptor(
      id: codebuddyBuiltinProviderId,
      label: 'CodeBuddy',
      icon: Icons.auto_awesome_rounded,
      description: 'CodeBuddy',
      catalog: sandboxClaudeCatalog,
      create: (ctx) => ClaudeCodeKernel(
        cb,
        ctx,
        start: (launch) async {
          final sid =
              launch.resume ?? nextSessionIds[cb.id] ?? 'cb-sess-default';
          return ScriptedClaudeTransport(
            launch: launch,
            sessionId: sid,
            onUserTurn: (tr, _) => tr.emitSimpleReply('CB_OK', model: 'glm-5.0-turbo'),
          );
        },
      ),
    );
    cc = KernelDescriptor(
      id: claudeCodeKernelId,
      label: 'Claude Code',
      icon: Icons.terminal_rounded,
      description: 'Claude Code',
      catalog: sandboxClaudeCatalog,
      create: (ctx) => ClaudeCodeKernel(
        cc,
        ctx,
        start: (launch) async {
          final sid =
              launch.resume ?? nextSessionIds[cc.id] ?? 'cc-sess-default';
          return ScriptedClaudeTransport(
            launch: launch,
            sessionId: sid,
            onUserTurn: (tr, _) => tr.emitSimpleReply('CC_OK', model: 'claude-sonnet-4-6'),
          );
        },
      ),
    );
    return [agy, cb, cc];
  }

  group('F6 Tier 1 — Attribution, Native agy Catalog & Plugin Skill Lookup', () {
    test(
      'F6-T1-01: session kernelId attribution persists across Workspace reload',
      () async {
        final prefs = MemoryPreferenceStore();
        final kernels1 = makeScriptedKernels({
          codebuddyBuiltinProviderId: 'cb-sess-1',
          antigravityBuiltinProviderId: 'agy-sess-1',
        });
        final ws1 = Workspace(
          kernels: kernels1,
          preferences: prefs,
          projects: [Project('proj', sandbox.projectDir.path)],
        );
        sandbox.onDispose(ws1.dispose);
        await ws1.load();

        final proj1 = ws1.projects.first;
        final cbThread = ws1.startAgent(proj1, kernel: kernels1[1]);
        cbThread.session.send(const ComposerMessage(text: 'Run in CodeBuddy'));
        await settleAgentTurn(cbThread);
        final cbPerms = cbThread.session.permissions;
        expect(cbPerms, isNotNull);
        final chosenCbPerm = cbPerms!.options.firstWhere(
          (o) => o.id == 'acceptEdits',
          orElse: () => cbPerms.options.last,
        );
        cbPerms.onSelected(chosenCbPerm);

        final agyThread = ws1.startAgent(proj1, kernel: kernels1[0]);
        agyThread.session.send(const ComposerMessage(text: 'Run in Agy'));
        await settleAgentTurn(agyThread);
        final agyModes = agyThread.session.modes;
        expect(agyModes, isNotNull);
        final chosenAgyMode = agyModes!.options.firstWhere(
          (o) => o.id == 'plan',
          orElse: () => agyModes.options.last,
        );
        agyModes.onSelected(chosenAgyMode);

        // Mirror both sessions to sandbox CLAUDE_CONFIG_DIR so Workspace #2 discovers them.
        _writeClaudeJsonl(
          paths: sandboxPaths,
          cwd: sandbox.projectDir.path,
          sessionId: 'cb-sess-1',
          model: 'claude-sonnet-4-6', // Deliberately ambiguous to prove kernelId wins.
          prompt: 'Run in CodeBuddy',
        );
        _writeClaudeJsonl(
          paths: sandboxPaths,
          cwd: sandbox.projectDir.path,
          sessionId: 'agy-sess-1',
          model: 'claude-sonnet-4-6',
          prompt: 'Run in Agy',
        );

        await waitUntil(() {
          final agents = prefs.preferences['agents'];
          if (agents is! Map) return false;
          final cbSaved = agents['cb-sess-1'];
          final agySaved = agents['agy-sess-1'];
          return cbSaved is Map &&
              agySaved is Map &&
              cbSaved['permission'] == chosenCbPerm.id &&
              agySaved['mode'] == chosenAgyMode.id;
        }, reason: 'PreferenceStore should persist kernelId and choices for both sessions');

        ws1.dispose();

        final kernels2 = makeScriptedKernels(const {});
        final ws2 = Workspace(
          kernels: kernels2,
          preferences: prefs,
        );
        sandbox.onDispose(ws2.dispose);
        await ws2.load();

        final reloadedCb = ws2.threads.firstWhere(
          (t) => t.record?.id == 'cb-sess-1',
        );
        final reloadedAgy = ws2.threads.firstWhere(
          (t) => t.record?.id == 'agy-sess-1',
        );
        expect(reloadedCb.kernel.id, codebuddyBuiltinProviderId);
        expect(reloadedAgy.kernel.id, antigravityBuiltinProviderId);
        expect(
          ws2.keptChoice(reloadedCb, KernelChoiceKind.permission),
          chosenCbPerm.id,
        );
        expect(
          ws2.keptChoice(reloadedAgy, KernelChoiceKind.mode),
          chosenAgyMode.id,
        );
      },
    );

    test(
      'F6-T1-02: header/model inference fallback restores exact kernels without PreferenceStore kernelId',
      () async {
        final prefs = MemoryPreferenceStore();
        _writeClaudeJsonl(
          paths: sandboxPaths,
          cwd: sandbox.projectDir.path,
          sessionId: 'infer-agy-1',
          uuid: 'agy-1',
          model: 'gemini-3.8-flash-high',
          prompt: 'Agy prompt',
        );
        _writeClaudeJsonl(
          paths: sandboxPaths,
          cwd: sandbox.projectDir.path,
          sessionId: 'infer-cb-1',
          model: 'glm-5.3',
          prompt: 'CodeBuddy prompt',
        );
        _writeClaudeJsonl(
          paths: sandboxPaths,
          cwd: sandbox.projectDir.path,
          sessionId: 'infer-cc-1',
          model: 'claude-sonnet-4-6',
          prompt: 'Claude prompt',
        );

        final kernels = makeScriptedKernels(const {});
        final ws = Workspace(kernels: kernels, preferences: prefs);
        sandbox.onDispose(ws.dispose);
        await ws.load();

        final byId = {
          for (final t in ws.threads)
            if (t.record != null) t.record!.id: t,
        };
        expect(byId['infer-agy-1']?.kernel.id, antigravityBuiltinProviderId);
        expect(byId['infer-cb-1']?.kernel.id, codebuddyBuiltinProviderId);
        expect(byId['infer-cc-1']?.kernel.id, claudeCodeKernelId);
      },
    );

    test(
      'F6-T1-03: AntigravityCatalog discovers native brain transcript, strips XML wrappers, and excludes Claude sessions',
      () async {
        expect(KernelRegistry.antigravity.catalog, isNotNull);

        const brainId = '11111111-2222-3333-4444-555555555555';
        final brainDir = Directory(
          p.join(sandbox.homeDir.path, '.gemini', 'antigravity-cli', 'brain', brainId),
        );
        File(p.join(brainDir.path, 'metadata.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync(jsonEncode({'cwd': sandbox.projectDir.path}));
        File(p.join(brainDir.path, '.system_generated', 'logs', 'transcript.jsonl'))
          ..createSync(recursive: true)
          ..writeAsStringSync(
            '${jsonEncode({
              'type': 'USER_INPUT',
              'created_at': '2026-11-22T09:00:00Z',
              'content': '<system-reminder>x</system-reminder><CONVERSATION_CONTEXT>y</CONVERSATION_CONTEXT><USER_REQUEST>\nRefactor kernel registry\n</USER_REQUEST>',
            })}\n',
          );

        _writeClaudeJsonl(
          paths: sandboxPaths,
          cwd: sandbox.projectDir.path,
          sessionId: 'pure-claude-1',
          model: 'claude-sonnet-4-6',
          prompt: 'Pure Claude session',
        );

        final projects = await sandboxAgyCatalog.projects();
        expect(projects, hasLength(1));
        final sessions = await sandboxAgyCatalog.sessionsIn(sandbox.projectDir.path);
        expect(sessions.map((s) => s.id), [brainId]);
        expect(sessions.single.title, 'Refactor kernel registry');
        expect(sessions.single.path, isNull);
        expect(p.equals(sessions.single.cwd, sandbox.projectDir.path), isTrue);
      },
    );

    test(
      'F6-T1-04: lazy transcript sync materializes .jsonl for unsynced native agy session on read/readPage',
      () async {
        const sessionId = 'e2e-agy-sync-1';
        final transcriptFile = File(
          p.join(
            sandbox.homeDir.path,
            '.gemini',
            'antigravity-cli',
            'brain',
            sessionId,
            '.system_generated',
            'logs',
            'transcript.jsonl',
          ),
        )..createSync(recursive: true);
        File(
          p.join(
            sandbox.homeDir.path,
            '.gemini',
            'antigravity-cli',
            'brain',
            sessionId,
            'metadata.json',
          ),
        )
          ..createSync(recursive: true)
          ..writeAsStringSync(jsonEncode({'cwd': sandbox.projectDir.path}));

        transcriptFile.writeAsStringSync([
          jsonEncode({
            'type': 'USER_INPUT',
            'created_at': '2026-11-22T09:00:00Z',
            'content': '<USER_REQUEST>\nExplain sync pipeline\n</USER_REQUEST>',
          }),
          jsonEncode({
            'type': 'PLANNER_RESPONSE',
            'created_at': '2026-11-22T09:00:02Z',
            'content': 'The sync pipeline converts brain logs to jsonl.',
            'input_tokens': 120,
            'output_tokens': 45,
            'tool_calls': [
              {
                'name': 'read_file',
                'args': {'Path': p.join(sandbox.projectDir.path, 'README.md')},
              },
            ],
          }),
          jsonEncode({
            'type': 'GENERIC',
            'created_at': '2026-11-22T09:00:03Z',
            'status': 'SUCCESS',
            'content': 'README contents',
          }),
        ].join('\n'));

        final unsynced = SessionRecord(
          id: sessionId,
          title: 'Sync me',
          updatedAt: DateTime.utc(2026, 11, 22, 9),
          cwd: sandbox.projectDir.path,
          path: null,
        );

        final syncedPath = sandboxAgyCatalog.ensureSynced(unsynced);
        expect(syncedPath, isNotNull);
        expect(File(syncedPath!).existsSync(), isTrue);
        expect(p.isWithin(sandbox.homeDir.path, syncedPath), isTrue);

        final syncedRecord = SessionRecord(
          id: sessionId,
          title: unsynced.title,
          updatedAt: unsynced.updatedAt,
          cwd: unsynced.cwd,
          path: syncedPath,
        );
        final entries = await ClaudeStorage.read(syncedRecord);
        final page = await ClaudeStorage.readPage(syncedRecord, turns: 5);
        final serialized = jsonEncode(entries);
        expect(serialized, contains('Explain sync pipeline'));
        expect(
          serialized,
          contains('The sync pipeline converts brain logs to jsonl.'),
        );
        expect(page.entries, isNotEmpty);
      },
    );

    test(
      'F6-T1-05: CustomizationStore.commandFile resolves enabled plugin skills by bare name, frontmatter name, and plugin:skill',
      () async {
        final configDir = p.join(sandbox.homeDir.path, '.gemini', 'config');
        final pluginDir = p.join(configDir, 'plugins', 'my-tools');
        File(p.join(pluginDir, 'plugin.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync(jsonEncode({'name': 'devtools'}));
        final skillFile = File(
          p.join(pluginDir, 'skills', 'pdf-helper', 'SKILL.md'),
        )
          ..createSync(recursive: true)
          ..writeAsStringSync(
            '---\nname: pdf\ndescription: PDF tools\n---\n# Body\n',
          );
        final cmdFile = File(p.join(pluginDir, 'commands', 'deploy.md'))
          ..createSync(recursive: true)
          ..writeAsStringSync('# Deploy command\n');

        final store = CustomizationStore(
          configDir: configDir,
          homeDir: sandbox.homeDir.path,
        );

        expect(await store.commandFile('pdf'), skillFile.path);
        expect(await store.commandFile('pdf-helper'), skillFile.path);
        expect(await store.commandFile('devtools:pdf'), skillFile.path);
        expect(await store.commandFile('/deploy'), cmdFile.path);

        final skills = await store.list(CustomizationKind.skills);
        final found = skills.where((s) => s.name == 'pdf').toList();
        expect(found, hasLength(1));
        expect(found.single.scope, CustomizationScope.plugin);
        expect(found.single.editable, isFalse);
      },
    );

    test(
      'F6-T1-06: CustomizationStore.commandFile honors project > user > plugin precedence',
      () async {
        final configDir = p.join(sandbox.homeDir.path, '.gemini', 'config');
        final pluginSkill = File(
          p.join(configDir, 'plugins', 'p1', 'skills', 'review', 'SKILL.md'),
        )
          ..createSync(recursive: true)
          ..writeAsStringSync('---\nname: review\n---\nPlugin\n');
        final userSkill = File(p.join(configDir, 'skills', 'review', 'SKILL.md'))
          ..createSync(recursive: true)
          ..writeAsStringSync('---\nname: review\n---\nUser\n');
        final projectSkill = File(
          p.join(sandbox.projectDir.path, '.agents', 'skills', 'review', 'SKILL.md'),
        )
          ..createSync(recursive: true)
          ..writeAsStringSync('---\nname: review\n---\nProject\n');

        final store = CustomizationStore(
          configDir: configDir,
          homeDir: sandbox.homeDir.path,
        );

        expect(
          await store.commandFile('review', project: sandbox.projectDir.path),
          projectSkill.path,
        );
        expect(await store.commandFile('review'), userSkill.path);
        expect(await store.commandFile('p1:review'), pluginSkill.path);
      },
    );
  });

  group('F6 Tier 2 — Boundaries, Disabled Plugins, Security & Corrupt Data', () {
    test(
      'F6-T2-01: disabledPlugins list and plugins.<name>.enabled=false exclude plugin skills & commands',
      () async {
        final configDir = p.join(sandbox.homeDir.path, '.gemini', 'config');
        File(p.join(configDir, 'config.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync(
            jsonEncode({
              'disabledPlugins': ['alpha'],
              'plugins': {
                'beta': {'enabled': false},
              },
            }),
          );
        for (final name in const ['alpha', 'beta']) {
          File(p.join(configDir, 'plugins', name, 'plugin.json'))
            ..createSync(recursive: true)
            ..writeAsStringSync(jsonEncode({'name': name}));
          File(p.join(configDir, 'plugins', name, 'skills', 'secret', 'SKILL.md'))
            ..createSync(recursive: true)
            ..writeAsStringSync('---\nname: secret\n---\nHidden\n');
          File(p.join(configDir, 'plugins', name, 'commands', 'cmd.md'))
            ..createSync(recursive: true)
            ..writeAsStringSync('# Hidden\n');
        }

        final store = CustomizationStore(
          configDir: configDir,
          homeDir: sandbox.homeDir.path,
        );

        expect(await store.commandFile('secret'), isNull);
        expect(await store.commandFile('alpha:secret'), isNull);
        expect(await store.commandFile('beta:cmd'), isNull);
        expect(await store.list(CustomizationKind.skills), isEmpty);

        final plugins = await store.list(CustomizationKind.plugins);
        expect(plugins.map((e) => e.name), containsAll(['alpha', 'beta']));
        expect(plugins.every((e) => e.enabled == false), isTrue);
      },
    );

    test(
      'F6-T2-02: path traversal, null bytes, and invalid names rejected in commandFile & Catalog.delete',
      () async {
        final configDir = p.join(sandbox.homeDir.path, '.gemini', 'config');
        final store = CustomizationStore(
          configDir: configDir,
          homeDir: sandbox.homeDir.path,
        );

        for (final bad in const [
          '',
          '   ',
          '///',
          '../etc/passwd',
          'a/b',
          r'a\b',
          'foo\x00bar',
          ':skill',
          'plugin:../x',
        ]) {
          expect(await store.commandFile(bad), isNull, reason: 'input="$bad"');
        }

        final registryCatalog = KernelRegistry.antigravity.catalog!;
        await expectLater(
          () => registryCatalog.delete('../escape'),
          throwsArgumentError,
        );
        await expectLater(
          () => registryCatalog.delete(''),
          throwsArgumentError,
        );
      },
    );

    test(
      'F6-T2-03: AntigravityCatalog ignores missing-cwd and subagent-only brain dirs and tolerates corrupt .pb',
      () async {
        final agyRoot = p.join(
          sandbox.homeDir.path,
          '.gemini',
          'antigravity-cli',
        );
        File(p.join(agyRoot, 'jetbox_summaries_proto.pb'))
          ..createSync(recursive: true)
          ..writeAsBytesSync([0xff, 0x00, 0xfe, 0x99, 0x12, 0x01]);

        // 1. Deleted/nonexistent cwd
        final goneBrain = p.join(agyRoot, 'brain', 'gone-cwd-1');
        File(p.join(goneBrain, 'metadata.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync(
            jsonEncode({'cwd': p.join(sandbox.rootDir.path, 'nonexistent_dir')}),
          );
        File(p.join(goneBrain, '.system_generated', 'logs', 'transcript.jsonl'))
          ..createSync(recursive: true)
          ..writeAsStringSync(
            '${jsonEncode({'type': 'USER_INPUT', 'content': 'Ghost'})}\n',
          );

        // 2. Subagent-only (no USER_INPUT and no summary)
        final subBrain = p.join(agyRoot, 'brain', 'subagent-only-1');
        File(p.join(subBrain, 'metadata.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync(jsonEncode({'cwd': sandbox.projectDir.path}));
        File(p.join(subBrain, '.system_generated', 'logs', 'transcript.jsonl'))
          ..createSync(recursive: true)
          ..writeAsStringSync(
            '${jsonEncode({'type': 'PLANNER_RESPONSE', 'content': 'Subagent work'})}\n',
          );

        // 3. Valid brain dir
        const validId = 'valid-brain-1';
        final validBrain = p.join(agyRoot, 'brain', validId);
        File(p.join(validBrain, 'metadata.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync(jsonEncode({'cwd': sandbox.projectDir.path}));
        File(p.join(validBrain, '.system_generated', 'logs', 'transcript.jsonl'))
          ..createSync(recursive: true)
          ..writeAsStringSync(
            '${jsonEncode({'type': 'USER_INPUT', 'content': '<USER_REQUEST>Valid task</USER_REQUEST>'})}\n',
          );

        final sessions = await sandboxAgyCatalog.sessionsIn(sandbox.projectDir.path);
        expect(sessions.map((s) => s.id), [validId]);
      },
    );

    test(
      'F6-T2-04: large >256KB agy transcript truncates UTF-16 surrogate pairs cleanly and reads tail timestamp',
      () async {
        const id = 'large-brain-1';
        final brainDir = p.join(
          sandbox.homeDir.path,
          '.gemini',
          'antigravity-cli',
          'brain',
          id,
        );
        File(p.join(brainDir, 'metadata.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync(jsonEncode({'cwd': sandbox.projectDir.path}));

        final prefix = 'a' * 118;
        final longPrompt = '$prefix😀${'b' * 30}';
        final buf = StringBuffer()
          ..writeln(
            jsonEncode({
              'type': 'USER_INPUT',
              'created_at': '2026-11-22T01:00:00Z',
              'content': '<USER_REQUEST>$longPrompt</USER_REQUEST>',
            }),
          );
        final filler = 'x' * 4096;
        for (var i = 0; i < 80; i++) {
          buf.writeln(
            jsonEncode({
              'type': 'PLANNER_RESPONSE',
              'created_at': '2026-11-22T02:00:00Z',
              'content': filler,
            }),
          );
        }
        buf.writeln(
          jsonEncode({
            'type': 'PLANNER_RESPONSE',
            'created_at': '2026-11-22T10:30:00Z',
            'content': 'Final tail response',
          }),
        );

        final transcript = File(
          p.join(brainDir, '.system_generated', 'logs', 'transcript.jsonl'),
        )..createSync(recursive: true);
        transcript.writeAsStringSync(buf.toString());
        expect(transcript.lengthSync(), greaterThan(256 * 1024));

        final sessions = await sandboxAgyCatalog.sessionsIn(sandbox.projectDir.path);
        expect(sessions, hasLength(1));
        final title = sessions.single.title;
        expect(title, endsWith('…'));
        expect(title.length, lessThanOrEqualTo(121));
        expect(title.contains('\uFFFD'), isFalse);
        // Verify valid UTF-16 (no unpaired high/low surrogates).
        for (final unit in title.codeUnits) {
          // If surrogate appears, verify runes decode cleanly without replacement.
          if (unit >= 0xD800 && unit <= 0xDFFF) {
            expect(() => utf8.encode(title), returnsNormally);
          }
        }
        expect(
          sessions.single.updatedAt.toUtc(),
          DateTime.utc(2026, 11, 22, 10, 30),
        );
      },
    );

    test(
      'F6-T2-05: unrecognized persisted kernelId falls back safely to catalogKernel and opens ChatSession',
      () async {
        final prefs = MemoryPreferenceStore({
          'agents': {
            'sess-x': {
              'kernelId': 'removed-kernel',
              'model': 'unknown-model',
            },
          },
        });
        _writeClaudeJsonl(
          paths: sandboxPaths,
          cwd: sandbox.projectDir.path,
          sessionId: 'sess-x',
          model: 'claude-sonnet-4-6',
          prompt: 'Fallback session',
        );

        final kernels = makeScriptedKernels(const {});
        final ws = Workspace(kernels: kernels, preferences: prefs);
        sandbox.onDispose(ws.dispose);
        await ws.load();

        final thread = ws.threads.firstWhere((t) => t.record?.id == 'sess-x');
        expect(thread.kernel.id, claudeCodeKernelId);
        ws.select(thread);
        expect(thread.session.kernel.id, claudeCodeKernelId);
        expect(thread.isOpen, isTrue);
      },
    );

    test(
      'F6-T2-06: AntigravityCatalog.delete removes brain & conversations artifacts and is idempotent',
      () async {
        const id = 'e2e-agy-del-1';
        final agyRoot = p.join(
          sandbox.homeDir.path,
          '.gemini',
          'antigravity-cli',
        );
        final brainDir = Directory(p.join(agyRoot, 'brain', id));
        File(p.join(brainDir.path, '.system_generated', 'logs', 'transcript.jsonl'))
          ..createSync(recursive: true)
          ..writeAsStringSync(
            '${jsonEncode({'type': 'USER_INPUT', 'content': 'Delete me'})}\n',
          );
        final dbFile = File(p.join(agyRoot, 'conversations', '$id.db'))
          ..createSync(recursive: true)
          ..writeAsStringSync('db');
        final pbFile = File(p.join(agyRoot, 'conversations', '$id.pb'))
          ..createSync(recursive: true)
          ..writeAsStringSync('pb');
        _writeClaudeJsonl(
          paths: sandboxPaths,
          cwd: sandbox.projectDir.path,
          sessionId: id,
          model: 'gemini-3.8-flash-high',
          uuid: 'agy-del',
        );

        await sandboxAgyCatalog.delete(id);
        expect(brainDir.existsSync(), isFalse);
        expect(dbFile.existsSync(), isFalse);
        expect(pbFile.existsSync(), isFalse);
        expect(File(sandboxPaths.sessionFile(sandbox.projectDir.path, id)).existsSync(), isFalse);

        // Idempotent repeat + nonexistent delete do not throw.
        await sandboxAgyCatalog.delete(id);
        await sandboxAgyCatalog.delete('e2e-agy-nonexistent-99999');
      },
    );
  });
}
