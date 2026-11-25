import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/widgets/turn_power_tools.dart';
import 'package:baocode/ide/ide_menu.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/antigravity/antigravity_cli.dart';
import 'package:baocode/kernel/claude_code/claude_core_setting.dart';
import 'package:baocode/kernel/codebuddy/codebuddy_cli.dart';
import 'package:baocode/kernel/codex/codex_models.dart';
import 'package:baocode/kernel/kernel_registry.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/models/model_provider.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:baocode/models/provider_health.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _StubModelKernel with KernelEventSource implements AgentKernel, SelectsModel {
  _StubModelKernel(this.descriptor, List<KernelOption> options, String selected)
    : _options = options,
      _selected = selected;

  @override
  final KernelDescriptor descriptor;
  final List<KernelOption> _options;
  String _selected;

  @override
  late final KernelChoiceSource model = _StubChoice(
    () => _options,
    () => _selected,
    (id) => _selected = id,
  );

  @override
  KernelHealth get health => KernelHealth.idle;

  @override
  String? get sessionId => null;

  @override
  Future<void> get stopped => Future.value();

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
  void dispose() => closeEvents();
}

class _StubChoice implements KernelChoiceSource {
  _StubChoice(this._options, this._selected, this._select);

  final List<KernelOption> Function() _options;
  final String? Function() _selected;
  final void Function(String) _select;

  @override
  List<KernelOption> get options => _options();

  @override
  String? get selected => _selected();

  @override
  void select(String id) => _select(id);
}

ChatSession _makeSession({
  required String kernelId,
  required String kernelLabel,
  required List<KernelOption> options,
  required String selected,
}) {
  late KernelDescriptor desc;
  desc = KernelDescriptor(
    id: kernelId,
    label: kernelLabel,
    icon: Icons.smart_toy_outlined,
    description: kernelLabel,
    create: (_) => _StubModelKernel(desc, options, selected),
  );
  return ChatSession(kernel: desc, kernels: [desc], historyCount: 0);
}

void main() {
  test(
    'Antigravity offered without custom providers lists all Antigravity models '
    'instead of falling back to Claude Haiku',
    () {
      final previousCore = ClaudeCore.current;
      ClaudeCore.current = () => ClaudeCore.antigravity;
      addTearDown(() => ClaudeCore.current = previousCore);

      ({String providerName, String modelId, String modelLabel})? picked;
      final entries = ModelPkButton.buildPickerEntries(
        onPickChallenger: (c) => picked = c,
        providers: ModelProviders.memory(),
        pingOf: (_) => const ProviderPing(),
        antigravityModels: AntigravityModels.defaults,
        codebuddyInstalled: false,
        claudeCliInstalled: false,
        codexInstalled: false,
      );

      final actions = entries.whereType<IdeMenuAction>().toList();
      expect(actions.any((a) => a.label.contains('默认对照')), isFalse);
      expect(actions.first.label, 'Antigravity CLI');
      expect(actions.first.enabled, isFalse);

      final selectable = actions.where((a) => a.enabled).toList();
      expect(selectable.length, AntigravityModels.defaults.length);

      final opus = selectable.firstWhere((a) => a.label == 'Claude Opus 5.5');
      opus.onSelected!();
      expect(picked, (
        providerName: 'Antigravity CLI',
        modelId: '@antigravity-cli/claude-opus-5-5',
        modelLabel: 'Claude Opus 5.5',
      ));
    },
  );

  test(
    'current session models appear flat with active model checked, and other '
    'installed native CLIs appear as submenus',
    () {
      const agyGroup = KernelOptionGroup(
        antigravityBuiltinProviderId,
        'Antigravity CLI',
      );
      final session = _makeSession(
        kernelId: antigravityBuiltinProviderId,
        kernelLabel: 'Antigravity',
        options: const [
          KernelOption(
            '@antigravity-cli/gemini-4-neon',
            'Gemini 4 Neon',
            Icons.rocket_launch_rounded,
            '',
            group: agyGroup,
          ),
          KernelOption(
            '@antigravity-cli/claude-sonnet-5-5',
            'Claude Sonnet 5.5',
            Icons.rocket_launch_rounded,
            '',
            group: agyGroup,
          ),
        ],
        selected: '@antigravity-cli/gemini-4-neon',
      );
      addTearDown(session.dispose);

      ({String providerName, String modelId, String modelLabel})? picked;
      final entries = ModelPkButton.buildPickerEntries(
        session: session,
        onPickChallenger: (c) => picked = c,
        providers: ModelProviders.memory(),
        pingOf: (_) => const ProviderPing(),
        antigravityInstalled: true,
        codebuddyInstalled: true,
        codebuddyModels: const [
          CodeBuddyModel(id: 'glm-5.3', label: 'GLM-5.3'),
        ],
        claudeCliInstalled: true,
        codexInstalled: true,
        codexModels: () => const [
          CodexModelInfo(id: 'gpt-5.4', label: 'GPT-5.4'),
        ],
      );

      final actions = entries.whereType<IdeMenuAction>().toList();
      final neon = actions.firstWhere((a) => a.label == 'Gemini 4 Neon');
      expect(neon.checked, isTrue);

      final cbSub = actions.firstWhere((a) => a.label == 'CodeBuddy CLI');
      expect(cbSub.submenu, isNotNull);
      final glm = cbSub.submenu!.whereType<IdeMenuAction>().single;
      glm.onSelected!();
      expect(picked?.modelId, '@codebuddy-cli/glm-5.3');

      final claudeSub = actions.firstWhere((a) => a.label == 'Claude Code CLI');
      final sonnet = claudeSub.submenu!
          .whereType<IdeMenuAction>()
          .firstWhere((a) => a.label == 'Claude Sonnet');
      sonnet.onSelected!();
      expect(picked?.modelId, '@claude-code/sonnet');

      final codexSub = actions.firstWhere((a) => a.label == 'Codex CLI');
      final gpt = codexSub.submenu!.whereType<IdeMenuAction>().single;
      gpt.onSelected!();
      expect(picked?.modelId, '@codex/gpt-5.4');
    },
  );

  test('Codex and Claude Code sessions prefix their bare option IDs', () {
    const codexGroup = KernelOptionGroup(codexKernelId, 'Codex CLI');
    final codexSession = _makeSession(
      kernelId: codexKernelId,
      kernelLabel: 'Codex',
      options: const [
        KernelOption(
          'gpt-5.4',
          'GPT-5.4',
          Icons.bolt_rounded,
          '',
          group: codexGroup,
        ),
        KernelOption(
          'gpt-5.4-mini',
          'GPT-5.4 mini',
          Icons.bolt_rounded,
          '',
          group: codexGroup,
        ),
      ],
      selected: 'gpt-5.4',
    );
    addTearDown(codexSession.dispose);

    ({String providerName, String modelId, String modelLabel})? picked;
    final entries = ModelPkButton.buildPickerEntries(
      session: codexSession,
      onPickChallenger: (c) => picked = c,
      providers: ModelProviders.memory(),
      pingOf: (_) => const ProviderPing(),
      antigravityInstalled: false,
      codebuddyInstalled: false,
      claudeCliInstalled: false,
      codexInstalled: true,
    );

    final mini = entries
        .whereType<IdeMenuAction>()
        .firstWhere((a) => a.label == 'GPT-5.4 mini');
    mini.onSelected!();
    expect(picked, (
      providerName: 'Codex CLI',
      modelId: '@codex/gpt-5.4-mini',
      modelLabel: 'GPT-5.4 mini',
    ));
  });

  test(
    'custom providers list all enabled chat models without 4-item cap and '
    'skip disabled or image models',
    () {
      final previousCore = ClaudeCore.current;
      ClaudeCore.current = () => ClaudeCore.builtin;
      addTearDown(() => ClaudeCore.current = previousCore);

      final store = ModelProviders.memory(
        providers: [
          ModelProvider(
            id: 'custom',
            name: 'My API',
            baseUrl: 'https://api.example.com',
            auth: ProviderAuth.apiKey,
            models: const [
              ProviderModel(id: 'm1', label: 'Model 1'),
              ProviderModel(id: 'm2', label: 'Model 2'),
              ProviderModel(id: 'm3', label: 'Model 3'),
              ProviderModel(id: 'm4', label: 'Model 4'),
              ProviderModel(id: 'm5', label: 'Model 5'),
              ProviderModel(id: 'm6', label: 'Model 6', enabled: false),
              ProviderModel(
                id: 'img1',
                label: 'Image Model',
                kind: ModelKind.image,
              ),
            ],
          ),
        ],
      );

      ({String providerName, String modelId, String modelLabel})? picked;
      final entries = ModelPkButton.buildPickerEntries(
        onPickChallenger: (c) => picked = c,
        providers: store,
        pingOf: (_) => const ProviderPing(
          status: ProviderPingStatus.healthy,
          latencyMs: 85,
        ),
        antigravityInstalled: false,
        codebuddyInstalled: false,
        claudeCliInstalled: false,
        codexInstalled: false,
      );

      final actions = entries.whereType<IdeMenuAction>().toList();
      expect(actions.first.label, 'My API  85ms');
      expect(actions.first.enabled, isFalse);

      final selectable = actions.where((a) => a.enabled).toList();
      expect(selectable.map((a) => a.label).toList(), [
        'Model 1',
        'Model 2',
        'Model 3',
        'Model 4',
        'Model 5',
      ]);

      selectable.last.onSelected!();
      expect(picked, (
        providerName: 'My API',
        modelId: '@custom/m5',
        modelLabel: 'Model 5',
      ));
    },
  );

  test('when no CLI or custom provider is available shows disabled hint', () {
    final previousCore = ClaudeCore.current;
    ClaudeCore.current = () => ClaudeCore.builtin;
    addTearDown(() => ClaudeCore.current = previousCore);

    final entries = ModelPkButton.buildPickerEntries(
      onPickChallenger: (_) {},
      providers: ModelProviders.memory(),
      pingOf: (_) => const ProviderPing(),
      antigravityInstalled: false,
      codebuddyInstalled: false,
      claudeCliInstalled: false,
      codexInstalled: false,
    );

    final action = entries.whereType<IdeMenuAction>().single;
    expect(action.enabled, isFalse);
    expect(action.label, contains('暂无可用对照模型'));
  });

  testWidgets('tapping ModelPkButton opens picker with session models', (
    tester,
  ) async {
    const agyGroup = KernelOptionGroup(
      antigravityBuiltinProviderId,
      'Antigravity CLI',
    );
    final session = _makeSession(
      kernelId: antigravityBuiltinProviderId,
      kernelLabel: 'Antigravity',
      options: const [
        KernelOption(
          '@antigravity-cli/gemini-4-neon',
          'Gemini 4 Neon',
          Icons.rocket_launch_rounded,
          '',
          group: agyGroup,
        ),
        KernelOption(
          '@antigravity-cli/claude-opus-5-5',
          'Claude Opus 5.5',
          Icons.rocket_launch_rounded,
          '',
          group: agyGroup,
        ),
      ],
      selected: '@antigravity-cli/gemini-4-neon',
    );
    addTearDown(session.dispose);

    final previousProviders = ModelProviders.current;
    ModelProviders.current = ModelProviders.memory();
    addTearDown(() => ModelProviders.current = previousProviders);

    ({String providerName, String modelId, String modelLabel})? picked;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            child: ModelPkButton(
              session: session,
              onPickChallenger: (c) => picked = c,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(ModelPkButton));
    await tester.pumpAndSettle();

    expect(find.text('Gemini 4 Neon'), findsOneWidget);
    expect(find.text('Claude Opus 5.5'), findsOneWidget);
    expect(find.text('Claude Haiku (默认对照)'), findsNothing);

    await tester.tap(find.text('Claude Opus 5.5'));
    await tester.pumpAndSettle();

    expect(picked, (
      providerName: 'Antigravity CLI',
      modelId: '@antigravity-cli/claude-opus-5-5',
      modelLabel: 'Claude Opus 5.5',
    ));
  });
}
