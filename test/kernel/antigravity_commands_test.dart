import 'dart:convert';
import 'dart:io';

import 'package:bao_markdown/bao_markdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/composer/composer.dart';
import 'package:baocode/chat/composer/composer_controller.dart';
import 'package:baocode/chat/composer/composer_embeds.dart';
import 'package:baocode/chat/composer/composer_mock_data.dart';
import 'package:baocode/chat/composer/suggestion_menu.dart';
import 'package:baocode/customize/customization_store.dart';
import 'package:baocode/customize/customizations.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/antigravity/antigravity_cli.dart';
import 'package:baocode/kernel/antigravity/antigravity_commands.dart';
import 'package:baocode/kernel/antigravity/antigravity_transport.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_transport.dart';
import 'package:baocode/kernel/claude_code/claude_core_setting.dart';
import 'package:baocode/kernel/extension_switches.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:baocode/theme/app_theme.dart';

void main() {
  void writeFile(String path, String content) {
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  group('discoverAntigravityCommands', () {
    late Directory tmp;
    late String home;
    late String repo;
    late String subdir;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('ayte_agy_cmds_');
      home = p.join(tmp.path, 'home');
      repo = p.join(tmp.path, 'repo');
      subdir = p.join(repo, 'packages', 'app');
      Directory(p.join(repo, '.git')).createSync(recursive: true);
      Directory(subdir).createSync(recursive: true);
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    test(
      'discovers built-ins, project commands/workflows/skills, user globals, and enabled plugins with precedence',
      () async {
        // Project-level (in repo root, discovered via git ancestor walk from subdir)
        writeFile(
          p.join(repo, '.agents', 'commands', 'release.md'),
          '---\ndescription: Cut a release build\nargument-hint: <version>\n---\n',
        );
        writeFile(
          p.join(repo, '.agents', 'workflows', 'deploy.md'),
          '---\ndescription: Deploy staging environment\n---\n',
        );
        writeFile(
          p.join(repo, '.agents', 'skills', 'code-review', 'SKILL.md'),
          '---\nname: code-review\ndescription: Project review override\n---\n',
        );

        // User-level global
        writeFile(
          p.join(home, '.gemini', 'config', 'commands', 'daily.md'),
          '# Daily\n\nGenerate daily standup summary.\n',
        );
        writeFile(
          p.join(home, '.gemini', 'antigravity', 'global_workflows', 'sync.md'),
          '---\ndescription: Sync local dotfiles\n---\n',
        );
        writeFile(
          p.join(home, '.gemini', 'config', 'skills', 'code-review', 'SKILL.md'),
          '---\nname: code-review\ndescription: User review (should be shadowed by project)\n---\n',
        );
        writeFile(
          p.join(home, '.gemini', 'config', 'skills', 'notes', 'SKILL.md'),
          '---\nname: notes\ndescription: Capture engineering notes\n---\n',
        );

        // Enabled plugin + disabled plugin (via both plugins.<name>.enabled=false and disabledPlugins)
        writeFile(
          p.join(home, '.gemini', 'config', 'config.json'),
          jsonEncode({
            'disabledPlugins': ['legacy-off'],
            'plugins': {
              'agy-context': {'enabled': true},
              'muted-plugin': {'enabled': false},
            },
          }),
        );
        writeFile(
          p.join(home, '.gemini', 'config', 'plugins', 'agy-context', 'plugin.json'),
          jsonEncode({'name': 'agy-context'}),
        );
        writeFile(
          p.join(
            home,
            '.gemini',
            'config',
            'plugins',
            'agy-context',
            'skills',
            'context',
            'SKILL.md',
          ),
          '---\nname: context\ndescription: Inspect token usage and context window\n---\n',
        );
        writeFile(
          p.join(
            home,
            '.gemini',
            'config',
            'plugins',
            'muted-plugin',
            'skills',
            'hidden-skill',
            'SKILL.md',
          ),
          '---\nname: hidden-skill\ndescription: Should not appear\n---\n',
        );
        writeFile(
          p.join(
            home,
            '.gemini',
            'config',
            'plugins',
            'legacy-off',
            'skills',
            'legacy-skill',
            'SKILL.md',
          ),
          '---\nname: legacy-skill\ndescription: Should not appear either\n---\n',
        );

        final commands = await discoverAntigravityCommands(
          cwd: subdir,
          home: home,
          disabledSkills: const {'notes'},
        );

        final byName = {for (final c in commands) c['name'] as String: c};

        // Built-in agy slash commands are present first
        expect(commands.first['name'], 'compact');
        for (final builtin in const [
          'compact',
          'clear',
          'plan',
          'goal',
          'teamwork',
          'swarm',
          'boost',
          'grill-me',
          'schedule',
          'browser',
          'learn',
        ]) {
          expect(byName[builtin]?['builtin'], isTrue);
          expect(byName[builtin]?['category'], 'builtin');
        }

        // Project items discovered from ancestor git root
        expect(byName['release']?['category'], 'project');
        expect(byName['release']?['argumentHint'], '<version>');
        expect(byName['deploy']?['category'], 'project');
        expect(byName['code-review']?['category'], 'project');
        expect(byName['code-review']?['description'], 'Project review override');

        // User globals discovered & disabledSkills respected
        expect(byName['daily']?['category'], 'user');
        expect(byName['sync']?['category'], 'user');
        expect(byName.containsKey('notes'), isFalse);

        // Enabled plugin included, disabled plugins excluded
        expect(byName['context']?['category'], 'plugin');
        expect(byName['context']?['source'], 'agy-context');
        expect(byName.containsKey('hidden-skill'), isFalse);
        expect(byName.containsKey('legacy-skill'), isFalse);
      },
    );

    test(
      'normalizes leading slashes and matches plugin directory name, manifest name, and folder name in disabledSkills',
      () async {
        writeFile(
          p.join(home, '.gemini', 'config', 'skills', 'user-slash', 'SKILL.md'),
          '---\nname: user-slash\ndescription: User slash skill\n---\n',
        );
        writeFile(
          p.join(home, '.gemini', 'config', 'plugins', 'dir-slug', 'plugin.json'),
          jsonEncode({'name': 'Display Plugin Name'}),
        );
        writeFile(
          p.join(
            home,
            '.gemini',
            'config',
            'plugins',
            'dir-slug',
            'skills',
            'folder-alias',
            'SKILL.md',
          ),
          '---\nname: display-skill\ndescription: Hidden by dir-slug:folder\n---\n',
        );
        writeFile(
          p.join(
            home,
            '.gemini',
            'config',
            'plugins',
            'dir-slug',
            'skills',
            'kept-skill',
            'SKILL.md',
          ),
          '---\nname: kept-skill\ndescription: Remains enabled\n---\n',
        );

        final commands = await discoverAntigravityCommands(
          cwd: subdir,
          home: home,
          disabledSkills: const {
            '/user-slash',
            '/dir-slug:folder-alias',
          },
        );
        final names = {for (final c in commands) c['name']};
        expect(names, isNot(contains('user-slash')));
        expect(names, isNot(contains('display-skill')));
        expect(names, contains('kept-skill'));
      },
    );

    test(
      'AntigravityTransport returns discovered commands on initialize and updates on skillOverrides',
      () async {
        writeFile(
          p.join(home, '.gemini', 'config', 'skills', 'alpha', 'SKILL.md'),
          '---\nname: alpha\ndescription: Alpha helper\n---\n',
        );
        writeFile(
          p.join(home, '.gemini', 'config', 'skills', 'beta', 'SKILL.md'),
          '---\nname: beta\ndescription: Beta helper\n---\n',
        );

        final transport = AntigravityTransport.forTesting(
          executable: 'agy',
          environment: {'HOME': home, 'USERPROFILE': home},
          launch: ClaudeLaunch(
            cwd: repo,
            model: '@antigravity-cli/gemini-4-neon',
            persist: false,
            switches: const ExtensionSwitches(disabledSkills: {'beta'}),
          ),
        );
        addTearDown(transport.close);

        final initFuture = transport.messages.firstWhere(
          (m) => m['type'] == 'control_response',
        );
        transport.write({
          'type': 'control_request',
          'request_id': 'req-1',
          'request': {'subtype': 'initialize'},
        });
        final initMsg = await initFuture;
        final initPayload =
            ((initMsg['response'] as Map)['response'] as Map);
        final initNames = [
          for (final c in initPayload['commands'] as List)
            (c as Map)['name'] as String,
        ];
        expect(initNames, containsAll(['compact', 'teamwork', 'swarm', 'alpha']));
        expect(initNames, isNot(contains('beta')));

        // Flip skillOverrides: re-enable beta, disable alpha.
        final changedFuture = transport.messages.firstWhere(
          (m) =>
              m['type'] == 'system' && m['subtype'] == 'commands_changed',
        );
        transport.write({
          'type': 'control_request',
          'request_id': 'req-2',
          'request': {
            'subtype': 'apply_flag_settings',
            'settings': {
              'skillOverrides': {'alpha': 'off'},
            },
          },
        });
        final changed = await changedFuture;
        final updatedNames = [
          for (final c in changed['commands'] as List)
            (c as Map)['name'] as String,
        ];
        expect(updatedNames, contains('beta'));
        expect(updatedNames, isNot(contains('alpha')));
      },
    );

    test(
      'ClaudeCodeKernel exposes Antigravity built-in commands immediately before launch',
      () {
        final previousCore = ClaudeCore.current;
        ClaudeCore.current = () => ClaudeCore.antigravity;
        addTearDown(() => ClaudeCore.current = previousCore);

        final kernel = ClaudeCodeKernel(
          KernelDescriptor(
            id: antigravityBuiltinProviderId,
            label: 'Antigravity',
            icon: Icons.rocket_launch_rounded,
            description: 'Antigravity CLI',
            create: (_) => throw UnimplementedError(),
          ),
          KernelContext(cwd: repo),
          providers: ModelProviders.memory(),
          start: (_) async => throw UnimplementedError(),
        );
        addTearDown(kernel.dispose);

        final names = kernel.commands.map((c) => c.name).toList();
        expect(
          names,
          containsAll(['compact', 'clear', 'plan', 'teamwork', 'swarm', 'goal']),
        );
      },
    );

    test(
      'CustomizationStore resolves workflow files and plugin enabled=false',
      () async {
        final configDir = p.join(home, '.gemini', 'config');
        final workflow = p.join(repo, '.agents', 'workflows', 'ship.md');
        writeFile(workflow, '---\ndescription: Ship workflow\n---\n');
        writeFile(
          p.join(configDir, 'config.json'),
          jsonEncode({
            'plugins': {
              'p-off': {'enabled': false},
              'p-on': {'enabled': true},
            },
          }),
        );
        writeFile(
          p.join(configDir, 'plugins', 'p-off', 'plugin.json'),
          jsonEncode({'name': 'p-off', 'description': 'Off plugin'}),
        );
        writeFile(
          p.join(configDir, 'plugins', 'p-on', 'plugin.json'),
          jsonEncode({'name': 'p-on', 'description': 'On plugin'}),
        );

        final store = CustomizationStore(configDir: configDir, homeDir: home);
        expect(await store.commandFile('ship', project: repo), workflow);
        final plugins = await store.list(
          CustomizationKind.plugins,
          project: repo,
        );
        final enabledByName = {for (final pl in plugins) pl.name: pl.enabled};
        expect(enabledByName['p-off'], isFalse);
        expect(enabledByName['p-on'], isTrue);
      },
    );
  });

  group('Suggestion ranking, menu overflow, and composer `/` UX', () {
    test(
      'rankSuggestions prioritizes label matches and falls back to command descriptions',
      () {
        const items = [
          Suggestion(
            kind: SuggestionKind.command,
            label: 'compact',
            detail: 'Compact conversation context 压缩上下文',
            group: '内置命令',
          ),
          Suggestion(
            kind: SuggestionKind.command,
            label: 'plan',
            detail: 'Step-by-step planning',
            group: '内置命令',
          ),
          Suggestion(
            kind: SuggestionKind.command,
            label: 'context',
            detail: 'Inspect token usage',
            group: '插件技能',
          ),
        ];

        // Label match ranks above description match.
        final byLabel = rankSuggestions(items, 'con');
        expect(byLabel.first.suggestion.label, 'context');

        // Description fallback finds Chinese keyword.
        final byDesc = rankSuggestions(items, '压缩');
        expect(byDesc.map((m) => m.suggestion.label), ['compact']);
        expect(byDesc.first.matched, isEmpty);

        // Grouped ranking preserves contiguous sections.
        final grouped = rankGroupedSuggestions(items, '');
        expect(grouped.map((m) => m.suggestion.group).toList(), [
          '内置命令',
          '内置命令',
          '插件技能',
        ]);
      },
    );

    testWidgets(
      'SuggestionMenu renders grouped commands and very long skill names without overflow',
      (tester) async {
        const matches = [
          SuggestionMatch(
            Suggestion(
              kind: SuggestionKind.command,
              label: 'teamwork',
              detail: 'Launch a team of autonomous agents',
              icon: Icons.keyboard_command_key_rounded,
              group: '内置命令',
            ),
            [],
          ),
          SuggestionMatch(
            Suggestion(
              kind: SuggestionKind.command,
              label: 'alphagenome-single-variant-analysis-extremely-long-skill-name',
              detail:
                  'Analyzes genetic variant effects on gene expression and chromatin accessibility',
              icon: Icons.extension_outlined,
              group: '插件技能',
            ),
            [],
          ),
        ];

        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            localizationsDelegates: const [AppLocalizations.delegate],
            home: Scaffold(
              body: Center(
                child: SuggestionMenu(
                  title: '命令',
                  matches: matches,
                  highlighted: 1,
                  onHighlight: (_) {},
                  onSelect: (_) {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('内置命令'), findsOneWidget);
        expect(find.text('插件技能'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'ChatComposer triggers `/` after Chinese punctuation and live-refreshes when commands update',
      (tester) async {
        final session = ChatSession(historyCount: 0);
        addTearDown(session.dispose);

        final commandsNotifier = ValueNotifier<List<Suggestion>>(const [
          Suggestion(
            kind: SuggestionKind.command,
            label: 'compact',
            detail: 'Compact context',
            group: '内置命令',
          ),
        ]);
        addTearDown(commandsNotifier.dispose);

        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            localizationsDelegates: const [AppLocalizations.delegate],
            home: Scaffold(
              body: ValueListenableBuilder<List<Suggestion>>(
                valueListenable: commandsNotifier,
                builder: (context, cmds, child) => ComposerVocabulary(
                  commands: cmds,
                  child: child!,
                ),
                child: ChatComposer(session: session, draft: session.draft),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final editor =
            tester.widget<MarkdownEditor>(find.byType(MarkdownEditor));
        final controller = editor.controller as ComposerController;

        // 1. Typing `/` right after Chinese comma opens the menu.
        controller.replace(
          0,
          0,
          '好的，/',
          selection: const TextSelection.collapsed(offset: 4),
        );
        await tester.pumpAndSettle();
        expect(find.byType(SuggestionMenu), findsOneWidget);
        expect(find.text('/compact'), findsOneWidget);
        expect(find.text('/teamwork'), findsNothing);

        // 2. Commands arrive asynchronously -> open menu refreshes immediately.
        commandsNotifier.value = const [
          Suggestion(
            kind: SuggestionKind.command,
            label: 'compact',
            detail: 'Compact context',
            group: '内置命令',
          ),
          Suggestion(
            kind: SuggestionKind.command,
            label: 'teamwork',
            detail: 'Launch autonomous agent team',
            group: '内置命令',
          ),
        ];
        await tester.pumpAndSettle();
        expect(find.text('/teamwork'), findsOneWidget);

        // 3. Paths like `lib/` must NOT trigger the menu.
        controller.replace(
          0,
          controller.length,
          'lib/',
          selection: const TextSelection.collapsed(offset: 4),
        );
        await tester.pumpAndSettle();
        expect(find.byType(SuggestionMenu), findsNothing);
      },
    );
  });
}
