import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../chat/chat_models.dart';
import '../agent_kernel.dart';
import '../kernel_event.dart';
import '../kernel_types.dart';
import 'codex_models.dart';
import 'codex_transport.dart';

/// Adapts `codex app-server` to [AgentKernel]. Codex keeps no background
/// commands and cannot put files back, so it does not declare
/// [RunsBackgroundTasks] or [RevertsChanges]: those parts of the UI are not
/// shown for it.
class CodexKernel
    with KernelEventSource
    implements
        AgentKernel,
        SelectsModel,
        SelectsMode,
        SelectsEffort,
        ProvidesCommands,
        ReportsContext,
        RewindsConversation,
        AcceptsImages {
  CodexKernel(
    this.descriptor,
    this._transport, {
    this.loadLocalCatalog = false,
  }) {
    _subscription = _transport.messages.listen(_receive);
    if (loadLocalCatalog) {
      final loaded = CodexModels.loadLocalCatalog();
      _applyModelCatalog(
        loaded.models,
        preferredModel: loaded.defaultModel,
        preferredEffort: loaded.defaultEffort,
        notify: false,
      );
    }
  }

  @override
  final KernelDescriptor descriptor;
  final CodexTransport _transport;
  final bool loadLocalCatalog;
  late final StreamSubscription<Map<String, Object?>> _subscription;

  List<CodexModelInfo> _modelInfos = _defaultModelInfos;
  String _selectedModel = _defaultModelInfos.first.id;
  final Map<String, String> _pickedEfforts = {};
  bool _userPickedModel = false;
  Future<void>? _initializing;
  bool _disposed = false;

  static const List<CodexModelInfo> _defaultModelInfos = [
    CodexModelInfo(
      id: 'gpt-5.5-codex',
      label: 'GPT-5.5 Codex',
      description: 'Tuned for coding',
      isDefault: true,
      effortLevels: ['low', 'medium', 'high', 'xhigh'],
      defaultEffort: 'medium',
    ),
    CodexModelInfo(
      id: 'gpt-5.5',
      label: 'GPT-5.5',
      description: 'General purpose',
      effortLevels: ['low', 'medium', 'high'],
      defaultEffort: 'medium',
    ),
    CodexModelInfo(
      id: 'gpt-5.5-mini',
      label: 'GPT-5.5 mini',
      description: 'Fastest',
      effortLevels: ['low', 'medium', 'high'],
      defaultEffort: 'medium',
    ),
  ];

  CodexModelInfo? _infoOf(String id) {
    for (final m in _modelInfos) {
      if (m.id == id) return m;
    }
    return null;
  }

  void _applyModelCatalog(
    List<CodexModelInfo> models, {
    String? preferredModel,
    String? preferredEffort,
    bool notify = true,
  }) {
    if (models.isEmpty) return;
    _modelInfos = models;
    if (!_userPickedModel || _infoOf(_selectedModel) == null) {
      final byPreferred = preferredModel == null ? null : _infoOf(preferredModel);
      final byDefault = models.where((m) => m.isDefault).firstOrNull;
      _selectedModel = (byPreferred ?? byDefault ?? models.first).id;
    }
    if (preferredEffort != null && preferredEffort.isNotEmpty) {
      final info = _infoOf(_selectedModel);
      if (info != null && info.effortLevels.contains(preferredEffort)) {
        _pickedEfforts.putIfAbsent(_selectedModel, () => preferredEffort);
      }
    }
    if (notify && !_disposed) emitInfoChanged();
  }

  @override
  late final KernelChoiceSource model = _CodexChoice(
    options: () => [
      for (final info in _modelInfos) info.toOption(CodexModels.group),
    ],
    selected: () => _selectedModel,
    select: (id) {
      if (_selectedModel == id) return;
      _selectedModel = id;
      _userPickedModel = true;
      emitInfoChanged();
    },
  );

  @override
  late final ModelSetting effort = _CodexEffortSetting(this);

  @override
  late final KernelChoiceSource mode = LocalChoice(
    _modes,
    onChanged: (_) => emitInfoChanged(),
  );

  @override
  KernelHealth get health => KernelHealth.ready;

  @override
  String? get sessionId => null;

  @override
  Future<void> get stopped => Future.value();

  @override
  void prepare() {
    if (loadLocalCatalog) {
      unawaited(_ensureInitialized(fetchModels: true).catchError((_) {}));
    }
  }

  @override
  void release() {}

  @override
  void restart() {}

  /// Modes are its approval and sandbox policies.
  static const _modes = [
    KernelOption(
      'agent',
      'Agent',
      Icons.all_inclusive_rounded,
      'Edit the workspace, ask before commands',
    ),
    KernelOption(
      'ask',
      'Ask',
      Icons.chat_bubble_outline_rounded,
      'Read-only: answer questions',
    ),
  ];

  @override
  final List<KernelCommand> commands = const [
    KernelCommand(
      'review',
      'Review uncommitted changes',
      Icons.rate_review_outlined,
    ),
    KernelCommand(
      'compact',
      'Summarize the conversation',
      Icons.compress_rounded,
    ),
    KernelCommand(
      'init',
      'Write an AGENTS.md for this project',
      Icons.description_outlined,
    ),
    KernelCommand('diff', 'Show the git diff', Icons.difference_outlined),
    KernelCommand('new', 'Start a new chat', Icons.add_comment_outlined),
  ];

  @override
  int get contextWindow => 272000;

  int _requests = 0;
  final Map<Object, Completer<Map<String, Object?>>> _responses = {};
  bool _initialized = false;
  String? _threadId;

  /// Ours, and the server's for the same turn once it says.
  String? _turn;
  String? _serverTurn;

  /// When [_turn] began, to time it.
  DateTime? _turnStarted;
  final Set<String> _sentTurns = {};

  final Map<String, int> _textLength = {};
  final Map<String, StringBuffer> _reasoning = {};
  final Map<String, Stopwatch> _reasoningClock = {};

  /// The part of each summary streaming in.
  final Map<String, int> _reasoningPart = {};
  final Map<String, DateTime> _startedAt = {};

  /// Commands started and not completed yet, as they started.
  final Map<String, Map<String, Object?>> _commands = {};

  /// Pending approvals: our request id → the server's JSON-RPC id.
  final Map<String, Object?> _approvals = {};

  // --- Commands -------------------------------------------------------------

  Future<Map<String, Object?>> _request(
    String method,
    Map<String, Object?> params,
  ) {
    final id = ++_requests;
    final response = Completer<Map<String, Object?>>();
    _responses[id] = response;
    _transport.write({'id': id, 'method': method, 'params': params});
    return response.future;
  }

  @override
  void send(KernelTurn turn) {
    if (!_sentTurns.add(turn.id)) return;
    _turn = turn.id;
    _turnStarted = DateTime.now();
    emit(TurnStarted(nextSeq, turn.id));
    emit(
      ItemUpserted(
        nextSeq,
        turn.id,
        UserMessageItem(
          text: turn.text,
          images: turn.images,
          sentAt: DateTime.now(),
        ),
      ),
    );
    unawaited(_start(turn));
  }

  Future<void> _ensureInitialized({bool fetchModels = false}) {
    if (_initialized) return Future.value();
    return _initializing ??= () async {
      await _request('initialize', {
        'clientInfo': {'name': 'ayte', 'version': '1.0.0'},
      });
      _initialized = true;
      if (fetchModels && !_disposed) {
        try {
          final listed = await _request('model/list', {'includeHidden': false});
          final parsed = CodexModels.parseRpcModelList(listed);
          if (parsed.isNotEmpty) {
            _applyModelCatalog(parsed);
          }
        } on Object {
          // Keep locally loaded catalog if live model/list is unsupported.
        }
      }
    }().whenComplete(() => _initializing = null);
  }

  Future<void> _start(KernelTurn turn) async {
    try {
      await _ensureInitialized(fetchModels: loadLocalCatalog);
      if (_threadId == null) {
        final started = await _request('thread/start', {
          'model': model.selected,
        });
        _threadId = (started['thread'] as Map)['id'] as String;
      }
      final readOnly = mode.selected == 'ask';
      final chosenEffort = effort.selected;
      final started = await _request('turn/start', {
        'threadId': _threadId,
        'input': [
          {'type': 'text', 'text': turn.text},
          for (final note in turn.notes) {'type': 'text', 'text': note},
        ],
        'model': model.selected,
        'effort': ?chosenEffort,
        'approvalPolicy': readOnly ? 'never' : 'on-request',
        'sandboxPolicy': {'type': readOnly ? 'readOnly' : 'workspaceWrite'},
      });
      _serverTurn ??= (started['turn'] as Map)['id'] as String;
      // Stopped before the server knew the turn: stop it there too.
      if (_turn != turn.id) _interrupt();
    } on Object catch (error) {
      if (_turn == turn.id) {
        emit(
          ItemUpserted(
            nextSeq,
            'error:${turn.id}',
            NoticeItem(NoticeKind.error, 'Codex 错误: $error'),
          ),
        );
        _endTurn(turn.id, interrupted: true);
      }
    }
  }

  void _interrupt() {
    final serverTurn = _serverTurn;
    if (serverTurn == null || _threadId == null) return;
    unawaited(
      _request('turn/interrupt', {'threadId': _threadId, 'turnId': serverTurn}),
    );
  }

  @override
  void answer(String requestId, InteractionAnswer answer) {
    if (!_approvals.containsKey(requestId)) return;
    final rpcId = _approvals.remove(requestId);
    emit(InteractionResolved(nextSeq, requestId));
    final decision = switch (answer) {
      ApprovalAnswer(decision: ApprovalDecision.allowOnce) => 'accept',
      ApprovalAnswer(decision: ApprovalDecision.allowAlways) =>
        'acceptForSession',
      _ => 'decline',
    };
    _transport.write({
      'id': rpcId,
      'result': {'decision': decision},
    });
  }

  @override
  void cancel() {
    final turn = _turn;
    if (turn == null) return;
    _interrupt();
    _endTurn(turn, interrupted: true);
  }

  @override
  Future<bool> rewind({
    required String itemId,
    required int index,
    required int turns,
    String? lastSeen,
  }) async {
    if (_threadId case final threadId? when turns > 0) {
      unawaited(
        _request('thread/rollback', {'threadId': threadId, 'numTurns': turns}),
      );
    }
    emit(Rewound(nextSeq, itemId: itemId, index: index));
    return true;
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_subscription.cancel());
    _transport.close();
    closeEvents();
  }

  // --- Translation ------------------------------------------------------------

  void _receive(Map<String, Object?> message) {
    final method = message['method'] as String?;
    final params = (message['params'] as Map?)?.cast<String, Object?>();
    if (method == null) {
      final completer = _responses.remove(message['id']);
      if (completer == null) return;
      if (message['error'] case final Map err) {
        completer.completeError(
          StateError('${err['message'] ?? err}'),
        );
        return;
      }
      final result = (message['result'] as Map?)?.cast<String, Object?>();
      completer.complete(result ?? const {});
      return;
    }
    if (message.containsKey('id')) {
      _serverRequest(message['id'], method, params ?? const {});
      return;
    }
    switch (method) {
      case 'turn/started':
        _serverTurn = (params!['turn'] as Map)['id'] as String;
      case 'turn/completed':
        final turn = params!['turn'] as Map;
        if (turn['id'] != _serverTurn) return;
        _serverTurn = null;
        if (_turn case final ours?) {
          _endTurn(ours, interrupted: turn['status'] == 'interrupted');
        }
      case 'item/started':
        _itemStarted((params!['item'] as Map).cast<String, Object?>());
      case 'item/completed':
        _itemCompleted((params!['item'] as Map).cast<String, Object?>());
      case 'item/reasoning/summaryTextDelta':
        final id = params!['itemId'] as String;
        final buffer = _reasoning[id];
        if (buffer == null) return;
        // Each part of the summary (its own bold title and text) apart from
        // the one before.
        final part = params['summaryIndex'] as int?;
        final separate =
            part != null && buffer.isNotEmpty && part != _reasoningPart[id];
        if (part != null) _reasoningPart[id] = part;
        final delta = '${separate ? '\n\n' : ''}${params['delta'] as String}';
        final offset = buffer.length;
        buffer.write(delta);
        emit(TextDelta(nextSeq, id, offset, delta, tokens: buffer.length));
      case 'item/agentMessage/delta':
        final id = params!['itemId'] as String;
        final offset = _textLength[id];
        if (offset == null) return;
        final delta = params['delta'] as String;
        _textLength[id] = offset + delta.length;
        emit(TextDelta(nextSeq, id, offset, delta));
      case 'thread/tokenUsage/updated':
        final usage = params!['tokenUsage'] as Map;
        emit(
          UsageReported(
            nextSeq,
            ContextUsage(
              window: usage['modelContextWindow'] as int? ?? contextWindow,
              // The last request's, which is what the context holds; the
              // total adds up every request, and never drops on compacting.
              used: (usage['last'] as Map)['totalTokens'] as int,
            ),
          ),
        );
    }
  }

  void _serverRequest(
    Object? rpcId,
    String method,
    Map<String, Object?> params,
  ) {
    final (title, preview) = switch (method) {
      'item/commandExecution/requestApproval' => (
        'Run command',
        CommandPreview('${params['command']}') as ApprovalPreview?,
      ),
      'item/fileChange/requestApproval' => ('Apply changes', null),
      _ => (null, null),
    };
    if (title == null) return;
    final id = 'approval:$rpcId';
    _approvals[id] = rpcId;
    emit(
      InteractionRequested(
        nextSeq,
        ApprovalRequest(
          id: id,
          title: title,
          toolName: method.split('/')[1],
          reason: params['reason'] as String?,
          preview: preview,
          alwaysAllowLabel: 'Approve for this session',
        ),
      ),
    );
  }

  void _itemStarted(Map<String, Object?> item) {
    final id = item['id'] as String;
    switch (item['type']) {
      case 'reasoning':
        _reasoning[id] = StringBuffer();
        _reasoningClock[id] = Stopwatch()..start();
        emit(
          ItemUpserted(
            nextSeq,
            id,
            ThinkingItem(text: '', tokens: 0, startedAt: DateTime.now()),
            streaming: true,
          ),
        );
      case 'agentMessage':
        _textLength[id] = 0;
        emit(
          ItemUpserted(
            nextSeq,
            id,
            const AssistantTextItem(''),
            streaming: true,
          ),
        );
      case 'commandExecution':
        _startedAt[id] = DateTime.now();
        _commands[id] = item;
        emit(ItemUpserted(nextSeq, id, _commandItem(item)));
    }
  }

  void _itemCompleted(Map<String, Object?> item) {
    final id = item['id'] as String;
    switch (item['type']) {
      case 'reasoning':
        final buffer = _reasoning.remove(id);
        final clock = _reasoningClock.remove(id)?..stop();
        _reasoningPart.remove(id);
        final text =
            buffer?.toString() ??
            (item['summary'] as List<Object?>? ?? const []).join('\n\n');
        emit(
          ItemCompleted(
            nextSeq,
            id,
            item: ThinkingItem(
              text: text,
              tokens: text.length,
              seconds: math.max(
                1,
                ((clock?.elapsedMilliseconds ?? 0) / 1000).round(),
              ),
            ),
          ),
        );
      case 'agentMessage':
        _textLength.remove(id);
        emit(
          ItemCompleted(
            nextSeq,
            id,
            item: AssistantTextItem(item['text'] as String),
          ),
        );
      case 'commandExecution':
        emit(ItemUpserted(nextSeq, id, _commandItem(item)));
        _startedAt.remove(id);
        _commands.remove(id);
      case 'fileChange':
        final changes = item['changes'] as List<Object?>;
        for (final (index, raw) in changes.indexed) {
          final change = raw as Map;
          _fileChange(
            '$id:$index',
            change['path'] as String,
            change['diff'] as String,
            kind: (change['kind'] as Map?)?['type'] as String?,
          );
        }
    }
  }

  /// A command as the history shows it: reads and searches as tool rows,
  /// anything else as a terminal.
  ChatItem _commandItem(Map<String, Object?> item) {
    final actions = [
      for (final action in item['commandActions'] as List<Object?>? ?? const [])
        (action as Map).cast<String, Object?>(),
    ];
    final output = item['aggregatedOutput'] as String?;
    final done = item['status'] == 'completed' || item['status'] == 'failed';
    if (actions.isNotEmpty && actions.every((a) => a['type'] == 'read')) {
      final path = actions.first['path'] as String;
      return ToolCallItem(
        kind: ToolKind.read,
        target: path.split(RegExp(r'[/\\]')).last,
        path: path,
      );
    }
    if (actions.isNotEmpty && actions.every((a) => a['type'] == 'search')) {
      final matches = [
        for (final line in (output ?? '').split('\n'))
          if (line.isNotEmpty) line.split(':').take(2).join(':'),
      ];
      return ToolCallItem(
        kind: ToolKind.grep,
        target: actions.first['query'] as String,
        detail: done ? '${matches.length} results' : null,
        results: matches,
      );
    }
    return TerminalItem(
      command: item['command'] as String,
      output: output ?? '',
      status: !done
          ? CommandStatus.running
          : item['exitCode'] == 0
          ? CommandStatus.succeeded
          : CommandStatus.failed,
      startedAt: _startedAt[item['id']],
    );
  }

  /// A unified diff as a diff card and a pending change. A file added or
  /// deleted ([kind]) has its whole text for a diff.
  void _fileChange(String id, String path, String diff, {String? kind}) {
    final lines = <DiffLine>[];
    var added = 0;
    var removed = 0;
    var oldLine = 1;
    var newLine = 1;
    final hunk = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@');
    for (final line in diff.split('\n')) {
      if (hunk.firstMatch(line) case final match?) {
        oldLine = int.parse(match.group(1)!);
        newLine = int.parse(match.group(2)!);
        continue;
      }
      if (line.isEmpty) continue;
      final text = line.substring(1);
      switch (line[0]) {
        case '+':
          lines.add(DiffLine(DiffLineType.added, newLine++, text));
          added++;
        case '-':
          lines.add(DiffLine(DiffLineType.removed, oldLine++, text));
          removed++;
        default:
          lines.add(DiffLine(DiffLineType.context, newLine++, text));
          oldLine++;
      }
    }
    final slash = path.lastIndexOf(RegExp(r'[/\\]'));
    emit(
      ItemUpserted(
        nextSeq,
        id,
        CodeDiffItem(
          fileName: path.substring(slash + 1),
          directory: slash < 0 ? '' : path.substring(0, slash),
          lines: lines,
        ),
      ),
    );
    emit(
      FileEdited(
        nextSeq,
        FileChange(path: path, added: added, removed: removed),
        original: switch (kind) {
          'add' => const OriginalText(null),
          'delete' => OriginalText(diff),
          _ => OriginalByPatch(diff),
        },
      ),
    );
  }

  void _endTurn(String turn, {required bool interrupted}) {
    _turn = null;
    for (final id in [..._reasoning.keys]) {
      _itemCompleted({'type': 'reasoning', 'id': id});
    }
    for (final id in [..._textLength.keys]) {
      _textLength.remove(id);
      emit(ItemCompleted(nextSeq, id));
    }
    // A command stopped with its turn: it will not report its end.
    for (final item in [..._commands.values]) {
      _itemCompleted({...item, 'status': 'failed'});
    }
    for (final id in _approvals.keys) {
      emit(InteractionResolved(nextSeq, id));
    }
    _approvals.clear();
    emit(
      TurnEnded(
        nextSeq,
        turn,
        interrupted: interrupted,
        worked: switch (_turnStarted) {
          final started? => DateTime.now().difference(started),
          null => null,
        },
      ),
    );
  }
}

class _CodexChoice implements KernelChoiceSource {
  const _CodexChoice({
    required this._options,
    required this._selected,
    required this._select,
  });

  final List<KernelOption> Function() _options;
  final String Function() _selected;
  final void Function(String id) _select;

  @override
  List<KernelOption> get options => _options();

  @override
  String get selected => _selected();

  @override
  void select(String id) => _select(id);
}

class _CodexEffortSetting implements ModelSetting {
  const _CodexEffortSetting(this._kernel);

  final CodexKernel _kernel;

  static String _labelFor(String level) => switch (level) {
    'none' => 'Off',
    'minimal' => 'Minimal',
    'low' => 'Low',
    'medium' => 'Medium',
    'high' => 'High',
    'xhigh' => 'XHigh',
    'max' => 'Max',
    'ultra' => 'Ultra',
    _ => level,
  };

  @override
  bool get toggle => false;

  @override
  List<KernelOption> optionsFor(String model) {
    final info = _kernel._infoOf(model);
    if (info == null || info.effortLevels.length <= 1) return const [];
    return [
      for (final level in info.effortLevels)
        KernelOption(level, _labelFor(level), Icons.psychology_outlined, ''),
    ];
  }

  @override
  String? get selected => selectedFor(_kernel._selectedModel);

  @override
  String? selectedFor(String model) {
    final info = _kernel._infoOf(model);
    if (info == null || info.effortLevels.isEmpty) return null;
    final picked = _kernel._pickedEfforts[model];
    if (picked != null && info.effortLevels.contains(picked)) return picked;
    if (info.defaultEffort != null &&
        info.effortLevels.contains(info.defaultEffort)) {
      return info.defaultEffort;
    }
    return info.effortLevels.first;
  }

  @override
  void select(String model, String id) {
    _kernel._pickedEfforts[model] = id;
    if (_kernel._selectedModel != model) {
      _kernel.model.select(model);
    } else {
      _kernel.emitInfoChanged();
    }
  }
}
