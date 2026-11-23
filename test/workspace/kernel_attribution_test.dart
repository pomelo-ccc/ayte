import 'dart:convert';
import 'dart:io';

import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late String projectDir;

  void writeFile(String path, String content) {
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  setUp(() {
    temp = Directory.systemTemp.createTempSync('kernel_attribution_');
    projectDir = p.join(temp.path, 'proj');
    Directory(projectDir).createSync(recursive: true);
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  KernelDescriptor makeKernel(
    String id,
    SessionCatalog catalog, {
    List<KernelContext>? openedContexts,
  }) {
    late final KernelDescriptor descriptor;
    descriptor = KernelDescriptor(
      id: id,
      label: id,
      icon: Icons.terminal_rounded,
      description: id,
      catalog: catalog,
      create: (context) {
        openedContexts?.add(context);
        return _FakeAgentKernel(descriptor, context);
      },
    );
    return descriptor;
  }

  test(
    'restores exact kernelId from _agentSettings and strips kernelId from KernelContext.settings',
    () async {
      final keptClaude = SessionRecord(
        id: 'sess-claude-1',
        title: 'Claude session',
        updatedAt: DateTime(2026, 11, 20, 12),
        cwd: projectDir,
      );
      final keptCodeBuddy = SessionRecord(
        id: 'sess-cb-1',
        title: 'CodeBuddy session',
        updatedAt: DateTime(2026, 11, 20, 11),
        cwd: projectDir,
      );
      final keptLegacyKernelKey = SessionRecord(
        id: 'sess-legacy-key',
        title: 'Legacy kernel key session',
        updatedAt: DateTime(2026, 11, 20, 10),
        cwd: projectDir,
      );

      final sharedCatalog = _MemoryCatalog([
        ProjectRecord(
          path: projectDir,
          sessions: [keptClaude, keptCodeBuddy, keptLegacyKernelKey],
        ),
      ]);
      final agyCatalog = _MemoryCatalog(const []);

      final contexts = <KernelContext>[];
      final agy = makeKernel(
        'antigravity-cli',
        agyCatalog,
        openedContexts: contexts,
      );
      final cb = makeKernel(
        'codebuddy-cli',
        sharedCatalog,
        openedContexts: contexts,
      );
      final claude = makeKernel(
        'claude-code',
        sharedCatalog,
        openedContexts: contexts,
      );

      final store = MemoryPreferenceStore({
        'agents': {
          keptClaude.id: {
            'kernelId': 'claude-code',
            'mode': 'ask',
            'permission': 'acceptEdits',
          },
          keptCodeBuddy.id: {
            'kernelId': 'codebuddy-cli',
            'mode': 'agent',
          },
          keptLegacyKernelKey.id: {
            'kernel': 'claude-code',
            'mode': 'plan',
          },
        },
      });

      final workspace = Workspace(
        kernels: [agy, cb, claude],
        preferences: store,
      );
      addTearDown(workspace.dispose);
      await workspace.load();

      AgentThread threadOf(String id) =>
          workspace.threads.firstWhere((t) => t.record?.id == id);

      expect(threadOf(keptClaude.id).kernel.id, 'claude-code');
      expect(threadOf(keptCodeBuddy.id).kernel.id, 'codebuddy-cli');
      expect(threadOf(keptLegacyKernelKey.id).kernel.id, 'claude-code');

      // KernelContext.settings must NOT contain 'kernelId' or 'kernel'
      expect(threadOf(keptClaude.id).session.kernelContext.settings, {
        'mode': 'ask',
        'permission': 'acceptEdits',
      });
      expect(threadOf(keptLegacyKernelKey.id).session.kernelContext.settings, {
        'mode': 'plan',
      });
    },
  );

  test(
    'infers legacy kernel from model setting and jsonl header, falling back safely on unknown kernelId',
    () async {
      final agyJsonl = p.join(temp.path, 'agy.jsonl');
      writeFile(
        agyJsonl,
        '${jsonEncode({
          'type': 'user',
          'uuid': 'agy-u-1',
          'message': {'role': 'user', 'content': 'hi'},
        })}\n',
      );
      final cbJsonl = p.join(temp.path, 'cb.jsonl');
      writeFile(
        cbJsonl,
        '${jsonEncode({
          'type': 'assistant',
          'uuid': 'cb-a-1',
          'message': {'role': 'assistant', 'model': 'hy4std', 'content': []},
        })}\n',
      );
      final claudeJsonl = p.join(temp.path, 'claude.jsonl');
      writeFile(
        claudeJsonl,
        '${jsonEncode({
          'type': 'assistant',
          'uuid': 'cl-a-1',
          'message': {
            'role': 'assistant',
            'model': 'claude-sonnet-4-6',
            'content': [],
          },
        })}\n',
      );

      final byModelCb = SessionRecord(
        id: 'model-cb',
        title: 'By model CB',
        updatedAt: DateTime(2026, 11, 20, 12),
        cwd: projectDir,
      );
      final byModelClaude = SessionRecord(
        id: 'model-claude',
        title: 'By model Claude',
        updatedAt: DateTime(2026, 11, 20, 11),
        cwd: projectDir,
      );
      final byModelAgy = SessionRecord(
        id: 'model-agy',
        title: 'By model Agy',
        updatedAt: DateTime(2026, 11, 20, 10),
        cwd: projectDir,
      );
      final byHeaderAgy = SessionRecord(
        id: 'hdr-agy',
        title: 'By header Agy',
        updatedAt: DateTime(2026, 11, 20, 9),
        cwd: projectDir,
        path: agyJsonl,
      );
      final byHeaderCb = SessionRecord(
        id: 'hdr-cb',
        title: 'By header CB',
        updatedAt: DateTime(2026, 11, 20, 8),
        cwd: projectDir,
        path: cbJsonl,
      );
      final byHeaderClaude = SessionRecord(
        id: 'hdr-claude',
        title: 'By header Claude',
        updatedAt: DateTime(2026, 11, 20, 7),
        cwd: projectDir,
        path: claudeJsonl,
      );
      final unknownKernel = SessionRecord(
        id: 'unknown-k',
        title: 'Unknown kernel fallback',
        updatedAt: DateTime(2026, 11, 20, 6),
        cwd: projectDir,
      );

      // Simulate shared ClaudeCatalog visited by antigravity first, then codebuddy, then claudeCode
      final catalog = _MemoryCatalog([
        ProjectRecord(
          path: projectDir,
          sessions: [
            byModelCb,
            byModelClaude,
            byModelAgy,
            byHeaderAgy,
            byHeaderCb,
            byHeaderClaude,
            unknownKernel,
          ],
        ),
      ]);

      final agy = makeKernel('antigravity-cli', catalog);
      final cb = makeKernel('codebuddy-cli', catalog);
      final claude = makeKernel('claude-code', catalog);

      final store = MemoryPreferenceStore({
        'agents': {
          byModelCb.id: {'model': 'hy4std'},
          byModelClaude.id: {'model': 'claude-sonnet-4-6'},
          byModelAgy.id: {'model': 'claude-opus-5-5'},
          unknownKernel.id: {'kernelId': 'deleted-kernel', 'mode': 'plan'},
        },
      });

      final workspace = Workspace(
        kernels: [agy, cb, claude],
        preferences: store,
      );
      addTearDown(workspace.dispose);
      await workspace.load();

      AgentThread threadOf(String id) =>
          workspace.threads.firstWhere((t) => t.record?.id == id);

      expect(threadOf(byModelCb.id).kernel.id, 'codebuddy-cli');
      expect(threadOf(byModelClaude.id).kernel.id, 'claude-code');
      expect(threadOf(byModelAgy.id).kernel.id, 'antigravity-cli');
      expect(threadOf(byHeaderAgy.id).kernel.id, 'antigravity-cli');
      expect(threadOf(byHeaderCb.id).kernel.id, 'codebuddy-cli');
      expect(threadOf(byHeaderClaude.id).kernel.id, 'claude-code');
      // Unknown kernelId does not throw and falls back to catalogKernel ('antigravity-cli')
      expect(threadOf(unknownKernel.id).kernel.id, 'antigravity-cli');
    },
  );

  test(
    '_keepChoices and fork persist kernelId while keeping KernelContext.settings clean',
    () async {
      final sharedCatalog = _MemoryCatalog(const []);
      final agy = makeKernel('antigravity-cli', sharedCatalog);
      final claude = makeKernel('claude-code', sharedCatalog);
      final store = MemoryPreferenceStore();

      final workspace = Workspace(
        kernels: [agy, claude],
        projects: [Project('proj', projectDir)],
        preferences: store,
      );
      addTearDown(workspace.dispose);
      await workspace.load();

      final claudeThread = workspace.startAgent(
        workspace.projects.single,
        kernel: claude,
      );
      claudeThread.session.send(const ComposerMessage(text: 'Hello Claude'));
      await pumpEventQueue();

      final savedAgents = store.preferences['agents'] as Map;
      final sessionId = claudeThread.id!;
      expect((savedAgents[sessionId] as Map)['kernelId'], 'claude-code');

      final forked = await workspace.fork(claudeThread);
      expect(forked, isNotNull);
      expect(forked!.kernel.id, 'claude-code');
      final forkedPrefs = savedAgents[forked.id!] as Map;
      expect(forkedPrefs['kernelId'], 'claude-code');
      expect(
        forked.session.kernelContext.settings.containsKey('kernelId'),
        isFalse,
      );
    },
  );

  test(
    'startAgent with explicit kernel avoids cross-kernel reuse and keeps preferredKernel non-sticky',
    () async {
      final emptyCatalog = _MemoryCatalog(const []);
      final agy = makeKernel('antigravity-cli', emptyCatalog);
      final claude = makeKernel('claude-code', emptyCatalog);
      final cb = makeKernel('codebuddy-cli', emptyCatalog);

      final project = Project('proj', projectDir);
      final workspace = Workspace(
        kernels: [agy, cb, claude],
        projects: [project],
        preferences: MemoryPreferenceStore(),
      );
      addTearDown(workspace.dispose);
      await workspace.load();

      expect(workspace.preferredKernel.id, 'antigravity-cli');

      // Existing untouched thread on antigravity
      final agyThread = workspace.startAgent(project);
      expect(agyThread.kernel.id, 'antigravity-cli');

      // Requesting claudeCode must NOT reuse the untouched antigravity thread
      final claudeThread = workspace.startAgent(project, kernel: claude);
      expect(identical(claudeThread, agyThread), isFalse);
      expect(claudeThread.kernel.id, 'claude-code');
      // Must NOT mutate preferredKernel
      expect(workspace.preferredKernel.id, 'antigravity-cli');

      // Requesting claudeCode again DOES reuse the untouched claudeCode thread
      final claudeReused = workspace.startAgent(project, kernel: claude);
      expect(identical(claudeReused, claudeThread), isTrue);

      // Default startAgent() still reuses untouched antigravity thread
      final agyReused = workspace.startAgent(project);
      expect(identical(agyReused, agyThread), isTrue);
    },
  );

  test(
    'refresh() attributes newly discovered terminal sessions via _resolveKeptKernel',
    () async {
      final sessions = <SessionRecord>[];
      final catalog = _MutableCatalog(projectDir, sessions);
      final agy = makeKernel('antigravity-cli', _MemoryCatalog(const []));
      final claude = makeKernel('claude-code', catalog);

      final claudeJsonl = p.join(temp.path, 'term-claude.jsonl');
      writeFile(
        claudeJsonl,
        '${jsonEncode({
          'type': 'assistant',
          'uuid': 'term-1',
          'message': {
            'role': 'assistant',
            'model': 'claude-opus-4-6',
            'content': [],
          },
        })}\n',
      );

      final cb = makeKernel('codebuddy-cli', catalog);
      final workspace = Workspace(
        kernels: [agy, cb, claude],
        projects: [Project('proj', projectDir)],
        preferences: MemoryPreferenceStore(),
      );
      addTearDown(workspace.dispose);
      await workspace.load();

      sessions.add(
        SessionRecord(
          id: 'term-claude-1',
          title: 'Terminal Claude session',
          updatedAt: DateTime(2026, 11, 21),
          cwd: projectDir,
          path: claudeJsonl,
        ),
      );
      await workspace.refresh();

      final added = workspace.threads.firstWhere(
        (t) => t.record?.id == 'term-claude-1',
      );
      expect(added.kernel.id, 'claude-code');
    },
  );

  test(
    'startAgent explicit kernel overrides agentSetup while default respects agentSetup',
    () async {
      final emptyCatalog = _MemoryCatalog(const []);
      final agy = makeKernel('antigravity-cli', emptyCatalog);
      final claude = makeKernel('claude-code', emptyCatalog);
      final cb = makeKernel('codebuddy-cli', emptyCatalog);
      final botDir = p.join(temp.path, 'bot-folder');
      Directory(botDir).createSync(recursive: true);
      final botProject = Project('bot', botDir);

      final workspace = Workspace(
        kernels: [agy, cb, claude],
        projects: [Project('proj', projectDir)],
        preferences: MemoryPreferenceStore(),
      );
      workspace.agentSetup = (path) => p.equals(path, botDir)
          ? AgentSetup(
              workspace: () => const KernelWorkspace(folders: []),
              kernel: 'codebuddy-cli',
            )
          : null;
      addTearDown(workspace.dispose);
      await workspace.load();

      final defaultBot = workspace.startAgent(botProject);
      expect(defaultBot.kernel.id, 'codebuddy-cli');

      final explicitClaude = workspace.startAgent(botProject, kernel: claude);
      expect(explicitClaude.kernel.id, 'claude-code');
      expect(workspace.preferredKernel.id, 'antigravity-cli');
    },
  );

  test(
    'handles legacy default model, provider-prefixed defaults, and [1m] aliases accurately',
    () async {
      final claudeJsonl = p.join(temp.path, 'default-claude.jsonl');
      writeFile(
        claudeJsonl,
        '${jsonEncode({
          'type': 'assistant',
          'uuid': 'cl-def-1',
          'message': {
            'role': 'assistant',
            'model': 'claude-sonnet-4-6',
            'content': [],
          },
        })}\n',
      );
      final agyJsonl = p.join(temp.path, 'default-agy.jsonl');
      writeFile(
        agyJsonl,
        '${jsonEncode({
          'type': 'user',
          'uuid': 'agy-def-1',
          'message': {'role': 'user', 'content': 'hi'},
        })}\n',
      );
      final cbJsonl = p.join(temp.path, 'default-cb.jsonl');
      writeFile(
        cbJsonl,
        '${jsonEncode({
          'type': 'assistant',
          'uuid': 'cb-def-1',
          'message': {'role': 'assistant', 'model': 'hy4std', 'content': []},
        })}\n',
      );
      final userOnlyJsonl = p.join(temp.path, 'default-user-only.jsonl');
      writeFile(
        userOnlyJsonl,
        '${jsonEncode({
          'type': 'user',
          'uuid': 'plain-u-1',
          'message': {'role': 'user', 'content': 'hi'},
        })}\n',
      );
      final defaultModelJsonl = p.join(temp.path, 'default-literal-model.jsonl');
      writeFile(
        defaultModelJsonl,
        '${jsonEncode({
          'type': 'assistant',
          'uuid': 'plain-a-1',
          'message': {'role': 'assistant', 'model': 'default', 'content': []},
        })}\n',
      );

      final sessions = [
        SessionRecord(
          id: 'def-claude',
          title: 'Legacy default + Claude jsonl',
          updatedAt: DateTime(2026, 11, 20, 12),
          cwd: projectDir,
          path: claudeJsonl,
        ),
        SessionRecord(
          id: 'def-agy',
          title: 'Legacy default + Agy jsonl',
          updatedAt: DateTime(2026, 11, 20, 11),
          cwd: projectDir,
          path: agyJsonl,
        ),
        SessionRecord(
          id: 'def-cb',
          title: 'Legacy default + CB jsonl',
          updatedAt: DateTime(2026, 11, 20, 10),
          cwd: projectDir,
          path: cbJsonl,
        ),
        SessionRecord(
          id: 'def-null-path',
          title: 'Legacy default + null path',
          updatedAt: DateTime(2026, 11, 20, 9),
          cwd: projectDir,
        ),
        SessionRecord(
          id: 'def-user-only',
          title: 'Legacy default + user-only jsonl',
          updatedAt: DateTime(2026, 11, 20, 8),
          cwd: projectDir,
          path: userOnlyJsonl,
        ),
        SessionRecord(
          id: 'def-literal-model',
          title: 'Legacy default + default model jsonl',
          updatedAt: DateTime(2026, 11, 20, 7),
          cwd: projectDir,
          path: defaultModelJsonl,
        ),
        SessionRecord(
          id: 'prefixed-agy',
          title: 'Prefixed Agy default',
          updatedAt: DateTime(2026, 11, 20, 6),
          cwd: projectDir,
        ),
        SessionRecord(
          id: 'prefixed-cb',
          title: 'Prefixed CB default',
          updatedAt: DateTime(2026, 11, 20, 5),
          cwd: projectDir,
        ),
        SessionRecord(
          id: 'alias-opus',
          title: 'Opus alias',
          updatedAt: DateTime(2026, 11, 20, 4),
          cwd: projectDir,
        ),
        SessionRecord(
          id: 'alias-sonnet',
          title: 'Sonnet alias',
          updatedAt: DateTime(2026, 11, 20, 3),
          cwd: projectDir,
        ),
        SessionRecord(
          id: 'alias-haiku',
          title: 'Haiku alias',
          updatedAt: DateTime(2026, 11, 20, 2),
          cwd: projectDir,
        ),
        SessionRecord(
          id: 'alias-opus-1m',
          title: 'Opus 1m alias',
          updatedAt: DateTime(2026, 11, 20, 1),
          cwd: projectDir,
        ),
        SessionRecord(
          id: 'explicit-agy-default',
          title: 'Stored kernelId + default',
          updatedAt: DateTime(2026, 11, 20, 0),
          cwd: projectDir,
          path: claudeJsonl,
        ),
      ];

      final sharedCatalog = _MemoryCatalog([
        ProjectRecord(path: projectDir, sessions: sessions),
      ]);
      final agy = makeKernel('antigravity-cli', sharedCatalog);
      final cb = makeKernel('codebuddy-cli', sharedCatalog);
      final claude = makeKernel('claude-code', sharedCatalog);

      final store = MemoryPreferenceStore({
        'agents': {
          'def-claude': {'model': 'default'},
          'def-agy': {'model': 'default'},
          'def-cb': {'model': 'default'},
          'def-null-path': {'model': 'default'},
          'def-user-only': {'model': 'default'},
          'def-literal-model': {'model': 'default'},
          'prefixed-agy': {'model': '@antigravity-cli/default'},
          'prefixed-cb': {'model': '@codebuddy-cli/default'},
          'alias-opus': {'model': 'opus'},
          'alias-sonnet': {'model': 'sonnet'},
          'alias-haiku': {'model': 'haiku'},
          'alias-opus-1m': {'model': 'opus[1m]'},
          'explicit-agy-default': {
            'kernelId': 'antigravity-cli',
            'model': 'default',
          },
        },
      });

      final workspace = Workspace(
        kernels: [agy, cb, claude],
        preferences: store,
      );
      addTearDown(workspace.dispose);
      await workspace.load();

      AgentThread threadOf(String id) =>
          workspace.threads.firstWhere((t) => t.record?.id == id);

      expect(threadOf('def-claude').kernel.id, 'claude-code');
      expect(threadOf('def-agy').kernel.id, 'antigravity-cli');
      expect(threadOf('def-cb').kernel.id, 'codebuddy-cli');
      expect(threadOf('def-null-path').kernel.id, 'claude-code');
      expect(threadOf('def-user-only').kernel.id, 'claude-code');
      expect(threadOf('def-literal-model').kernel.id, 'claude-code');
      expect(threadOf('prefixed-agy').kernel.id, 'antigravity-cli');
      expect(threadOf('prefixed-cb').kernel.id, 'codebuddy-cli');
      expect(threadOf('alias-opus').kernel.id, 'claude-code');
      expect(threadOf('alias-sonnet').kernel.id, 'claude-code');
      expect(threadOf('alias-haiku').kernel.id, 'claude-code');
      expect(threadOf('alias-opus-1m').kernel.id, 'claude-code');
      expect(threadOf('explicit-agy-default').kernel.id, 'antigravity-cli');
    },
  );
}

class _MemoryCatalog implements SessionCatalog {
  const _MemoryCatalog(this._projects);
  final List<ProjectRecord> _projects;

  @override
  Future<List<ProjectRecord>> projects() async => _projects;

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async => [
    for (final proj in _projects)
      if (p.equals(proj.path, cwd)) ...proj.sessions,
  ];

  @override
  Future<void> delete(String id) async {}
}

class _MutableCatalog implements SessionCatalog {
  _MutableCatalog(this.cwd, this.sessions);
  final String cwd;
  final List<SessionRecord> sessions;

  @override
  Future<List<ProjectRecord>> projects() async =>
      sessions.isEmpty ? const [] : [ProjectRecord(path: cwd, sessions: [...sessions])];

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async =>
      p.equals(this.cwd, cwd) ? [...sessions] : const [];

  @override
  Future<void> delete(String id) async {}
}

class _FakeAgentKernel
    with KernelEventSource
    implements
        AgentKernel,
        SelectsMode,
        SelectsPermission,
        SelectsModel,
        ForksConversation {
  _FakeAgentKernel(this.descriptor, this.context)
    : _sessionId = context.resume?.id {
    mode = LocalChoice(const [
      KernelOption('agent', 'Agent', Icons.smart_toy, ''),
      KernelOption('ask', 'Ask', Icons.help_outline, ''),
      KernelOption('plan', 'Plan', Icons.list_alt, ''),
    ])..reported = context.settings[KernelChoiceKind.mode.name];
    permission = LocalChoice(const [
      KernelOption('default', 'Default', Icons.shield, ''),
      KernelOption('acceptEdits', 'Accept Edits', Icons.edit, ''),
    ])..reported = context.settings[KernelChoiceKind.permission.name];
    model = LocalChoice(const [
      KernelOption('default', 'Default', Icons.memory, ''),
      KernelOption('claude-sonnet-4-6', 'Sonnet', Icons.memory, ''),
    ])..reported = context.settings[KernelChoiceKind.model.name];
  }

  @override
  final KernelDescriptor descriptor;
  final KernelContext context;
  String? _sessionId;
  int _forkSeq = 0;

  @override
  late final KernelChoiceSource mode;

  @override
  late final KernelChoiceSource permission;

  @override
  late final KernelChoiceSource model;

  @override
  KernelHealth get health => const KernelHealth(KernelHealthStatus.ready);

  @override
  String? get sessionId => _sessionId;

  @override
  bool get canFork => _sessionId != null;

  @override
  Future<SessionRecord?> fork({String? before, required String title}) async {
    if (_sessionId == null) return null;
    return SessionRecord(
      id: '${_sessionId!}-fork-${++_forkSeq}',
      title: title,
      updatedAt: DateTime(2026, 11, 22),
      cwd: context.cwd ?? '',
    );
  }

  @override
  void send(KernelTurn turn) {
    _sessionId ??= 'started-${descriptor.id}-${turn.id}';
    emit(TurnStarted(nextSeq, turn.id));
    emit(TurnEnded(nextSeq, turn.id));
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
  void dispose() => closeEvents();

  @override
  Future<void> get stopped async {}
}
