import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../chat/chat_models.dart';
import '../agent_kernel.dart';
import '../agent_message_parser.dart';
import '../claude_code/claude_code_transport.dart' show ClaudeLaunch;
import '../claude_code/claude_sdk_tools.dart';
import '../claude_code/sdk_mcp_http_bridge.dart';
import '../extension_switches.dart';
import '../kernel_event.dart';
import '../kernel_types.dart';
import 'codex_catalog.dart';
import 'codex_models.dart';
import 'codex_process_transport.dart';
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
        SelectsPermission,
        ProvidesCommands,
        ReportsContext,
        ReportsUsage,
        SuggestsFiles,
        RewindsConversation,
        ForksConversation,
        RenamesSession,
        QueuesMessages,
        LoadsHistory,
        ManagesMcpServers,
        AcceptsImages {
  CodexKernel(
    this.descriptor,
    this._transport, {
    this.context = const KernelContext(),
    this.catalog = const CodexCatalog(),
    this.loadLocalCatalog = false,
    bool? enableSdkMcpBridge,
  }) : _enableSdkMcpBridge =
           enableSdkMcpBridge ?? (_transport is ProcessCodexTransport) {
    _cwd =
        context.cwd ??
        context.resume?.cwd ??
        (_transport is ProcessCodexTransport ? _transport.cwd : null) ??
        '.';

    if (_transport is ProcessCodexTransport) {
      _transport.extraArgsBuilder ??= _buildProcessArgs;
    }

    _subscription = _transport.messages.listen(_receive);
    if (_enableSdkMcpBridge) {
      _switches = ExtensionSwitches.current();
      ExtensionSwitches.changes?.addListener(_applySwitches);
    }

    if (loadLocalCatalog) {
      final loaded = CodexModels.loadLocalCatalog();
      _applyModelCatalog(
        loaded.models,
        preferredModel: loaded.defaultModel,
        preferredEffort: loaded.defaultEffort,
        notify: false,
      );
    }

    _applyInitialSettings(context.settings);

    if (context.resume case final resume?) {
      _threadId = resume.id;
      _loadingHistory = true;
      unawaited(_loadHistory(resume));
    }
  }

  static const int _historyPageSize = 10;

  @override
  final KernelDescriptor descriptor;
  final CodexTransport _transport;
  final KernelContext context;
  final SessionCatalog? catalog;
  final bool loadLocalCatalog;
  final bool _enableSdkMcpBridge;

  late final String _cwd;
  late final StreamSubscription<Map<String, Object?>> _subscription;

  List<CodexModelInfo> _modelInfos = _defaultModelInfos;
  String _selectedModel = _defaultModelInfos.first.id;
  final Map<String, String> _pickedEfforts = {};
  bool _userPickedModel = false;

  String _selectedPermission = 'on-request';
  KernelHealth _health = KernelHealth.idle;
  bool _releaseWanted = false;

  Future<void>? _initializing;
  bool _initialized = false;
  bool _disposed = false;
  int _initEpoch = 0;

  String? _threadId;
  bool _threadResumed = false;
  String? _pendingTitle;
  final Set<String> _sentTitles = {};

  int _historyEpoch = 0;
  bool _loadingHistory = false;
  bool _hasEarlierHistory = false;
  bool _loadingEarlier = false;
  Future<void>? _loadingEarlierFuture;
  int? _earlierTurnCursor;
  final Map<String, int> _userItemTurnIndex = {};
  int _completedTurnCount = 0;

  AyteSdkMcpBridge? _sdkBridge;
  Completer<void> _sdkTurnCancelled = Completer<void>();
  ExtensionSwitches _switches = ExtensionSwitches.none;
  ExtensionSwitches? _spawnedSwitches;
  int _sdkAskSeq = 0;
  final Map<String, Completer<ApprovalDecision?>> _sdkAsks = {};

  List<McpServer>? _servers;
  static List<RateLimitWindow> _accountLimits = const [];
  Future<void>? _refreshingUsage;

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

  KernelWorkspace? get _workspace => context.workspace?.call();

  void _applyInitialSettings(Map<String, String> settings) {
    if (settings.isEmpty) return;
    if (settings[KernelChoiceKind.mode.name] case final m?
        when _modes.any((opt) => opt.id == m)) {
      mode.select(m);
    }
    if (settings[KernelChoiceKind.permission.name] case final perm?
        when _permissions.any((opt) => opt.id == perm)) {
      _selectedPermission = perm;
    }
    final effortPrefix = '${KernelChoiceKind.effort.name}@';
    for (final MapEntry(:key, :value) in settings.entries) {
      if (key.startsWith(effortPrefix) && value.isNotEmpty) {
        _pickedEfforts[key.substring(effortPrefix.length)] = value;
      }
    }
    if (settings[KernelChoiceKind.model.name] case final m?
        when _infoOf(m) != null) {
      _selectedModel = m;
      _userPickedModel = true;
    }
    if (settings[KernelChoiceKind.effort.name] case final e? when e.isNotEmpty) {
      final info = _infoOf(_selectedModel);
      if (info == null || info.effortLevels.contains(e)) {
        _pickedEfforts.putIfAbsent(_selectedModel, () => e);
      }
    }
  }

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
      final byPreferred = preferredModel == null
          ? null
          : _infoOf(preferredModel);
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
  late final KernelChoiceSource permission = _CodexChoice(
    options: () => _permissions,
    selected: () => _selectedPermission,
    select: (id) {
      if (_selectedPermission == id) return;
      if (!_permissions.any((opt) => opt.id == id)) return;
      _selectedPermission = id;
      emitInfoChanged();
    },
  );

  @override
  KernelHealth get health => _health;

  void _setHealth(KernelHealth next) {
    if (_health.status == next.status &&
        _health.message == next.message &&
        _health.detail == next.detail &&
        _health.missingFolder == next.missingFolder &&
        _health.noModel == next.noModel) {
      return;
    }
    _health = next;
    if (!_disposed) emitInfoChanged();
  }

  @override
  String? get sessionId => _threadId;

  @override
  Future<void> get stopped {
    if (_transport case final ProcessCodexTransport pt) {
      return pt.exited.timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      );
    }
    return Future.value();
  }

  @visibleForTesting
  AyteSdkMcpBridge? get sdkBridgeForTesting => _sdkBridge;

  bool get _busy =>
      _turn != null ||
      _turnQueue.isNotEmpty ||
      _approvals.isNotEmpty ||
      _pendingQuestions.isNotEmpty ||
      _sdkAsks.isNotEmpty ||
      _initializing != null;

  @override
  void prepare() {
    _releaseWanted = false;
    if (_disposed || _health.status == KernelHealthStatus.failed) return;
    if (loadLocalCatalog || _enableSdkMcpBridge) {
      unawaited(
        _ensureInitialized(fetchModels: loadLocalCatalog).catchError((_) {}),
      );
    }
  }

  @override
  void release() {
    if (_busy) {
      _releaseWanted = true;
      return;
    }
    _releaseWanted = false;
    if (!_initialized && _sdkBridge == null) return;
    _teardownProcessState('Codex released', keepThreadId: true);
    _setHealth(KernelHealth.idle);
  }

  @override
  void restart() {
    if (_disposed) return;
    _releaseWanted = false;
    final activeTurn = _turn;
    _teardownProcessState('Codex restarting', keepThreadId: true);
    _setHealth(KernelHealth.idle);
    prepare();
    if (activeTurn != null) {
      _endTurn(activeTurn, interrupted: true);
    }
  }

  void _teardownProcessState(String reason, {required bool keepThreadId}) {
    _initEpoch++;
    _failPendingResponses(reason);
    _initialized = false;
    _initializing = null;
    _spawnedSwitches = null;
    _threadResumed = false;
    _serverTurn = null;
    _compactingTurnClientId = null;
    _pendingCompactStarts.clear();
    _compactBoundClientTurns.clear();
    _pendingCompactThreadId = null;
    _pendingCompactWithoutTurnId = 0;
    _lastCompactClientId = null;
    _inFlightCompactStarts.clear();
    _cancelledCompactHandledInReceive.clear();
    _handledCancelledCompactClients.clear();
    _inFlightTurnStarts.clear();
    _ignoredServerTurns.clear();
    _earlyCompletedServerTurns.clear();
    _completedInFlightServerTurns.clear();
    if (!keepThreadId) {
      _threadId = null;
    }
    _cancelSdkCalls();
    if (_sdkBridge case final bridge?) {
      _sdkBridge = null;
      unawaited(bridge.close(force: true));
    }
    if (_transport case final ProcessCodexTransport pt) {
      unawaited(pt.stopProcess());
    }
  }

  void _failPendingResponses(String message) {
    if (_responses.isEmpty) return;
    final pending = [..._responses.values];
    _responses.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) {
        completer.completeError(StateError(message));
      }
    }
  }

  void _maybeDeferredRelease() {
    if (_releaseWanted && !_busy && !_disposed) {
      release();
    }
  }

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

  static const _permissions = [
    KernelOption(
      'on-request',
      'Ask for approval',
      Icons.front_hand_outlined,
      'Ask before commands and file changes',
    ),
    KernelOption(
      'unless-trusted',
      'Trusted only',
      Icons.verified_user_outlined,
      'Ask before untrusted commands and file changes',
    ),
    KernelOption(
      'never',
      "Don't ask",
      Icons.do_not_disturb_on_outlined,
      'Approve commands and edits automatically in workspace',
    ),
    KernelOption(
      'full-access',
      'Full access',
      Icons.gpp_maybe_outlined,
      'No sandbox or approval checks',
      caution: true,
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

  @override
  bool get loadingHistory => _loadingHistory;

  @override
  bool get hasEarlierHistory => _hasEarlierHistory;

  @override
  bool get loadingEarlier => _loadingEarlier;

  @override
  bool get canFork => _threadId != null && !_disposed;

  @override
  List<McpServer>? get mcpServers => _servers;

  @override
  List<RateLimitWindow> get accountLimits => _accountLimits;

  int _requests = 0;
  final Map<Object, Completer<Map<String, Object?>>> _responses = {};

  /// Ours, and the server's for the same turn once it says.
  String? _turn;
  String? _serverTurn;
  String? _compactingTurnClientId;
  final Map<Object, ({String clientTurnId, String? threadId})>
  _pendingCompactStarts = {};
  final Set<String> _compactBoundClientTurns = {};
  String? _pendingCompactThreadId;
  int _pendingCompactWithoutTurnId = 0;
  String? _lastCompactClientId;
  final Set<String> _inFlightCompactStarts = {};
  final Set<Object> _cancelledCompactHandledInReceive = {};
  final Set<String> _handledCancelledCompactClients = {};

  void _incrementPendingCompactWithoutTurnId(String? threadId) {
    if (threadId == null) return;
    if (_pendingCompactThreadId != threadId) {
      _pendingCompactThreadId = threadId;
      _pendingCompactWithoutTurnId = 0;
    }
    _pendingCompactWithoutTurnId++;
  }
  final Set<String> _inFlightTurnStarts = {};
  final Set<String> _ignoredServerTurns = {};
  final Map<String, bool> _earlyCompletedServerTurns = {};
  final Set<String> _completedInFlightServerTurns = {};

  bool get _hasOrphanedTurnStart =>
      _inFlightTurnStarts.any((id) => id != _turn) ||
      _inFlightCompactStarts.any((id) => id != _turn);

  static String _serverTurnKey(String? threadId, String turnId) =>
      '${threadId ?? ''}\u0000$turnId';

  void _recordIgnoredServerTurn(String? threadId, String turnId) {
    _ignoredServerTurns.add(_serverTurnKey(threadId, turnId));
    while (_ignoredServerTurns.length > 64) {
      _ignoredServerTurns.remove(_ignoredServerTurns.first);
    }
  }

  bool _isIgnoredServerTurn(String? threadId, String turnId) {
    if (threadId != null) {
      return _ignoredServerTurns.contains(_serverTurnKey(threadId, turnId));
    }
    return _ignoredServerTurns.contains(_serverTurnKey(_threadId, turnId)) ||
        _ignoredServerTurns.contains(_serverTurnKey(null, turnId));
  }

  bool _hasIgnoredServerTurnOnAnyThread(String turnId) {
    final suffix = '\u0000$turnId';
    return _ignoredServerTurns.any((k) => k.endsWith(suffix));
  }

  String? _removeIgnoredServerTurnKey(String? threadId, String turnId) {
    if (threadId != null) {
      final key = _serverTurnKey(threadId, turnId);
      return _ignoredServerTurns.remove(key) ? key : null;
    }
    final activeKey = _serverTurnKey(_threadId, turnId);
    if (_ignoredServerTurns.remove(activeKey)) return activeKey;
    final emptyKey = _serverTurnKey(null, turnId);
    if (_ignoredServerTurns.remove(emptyKey)) return emptyKey;
    return null;
  }

  void _recordEarlyCompletedServerTurn(
    String? threadId,
    String turnId, {
    required bool interrupted,
  }) {
    _earlyCompletedServerTurns[_serverTurnKey(threadId, turnId)] = interrupted;
    while (_earlyCompletedServerTurns.length > 64) {
      _earlyCompletedServerTurns.remove(_earlyCompletedServerTurns.keys.first);
    }
  }

  void _recordCompletedInFlightServerTurn(String? threadId, String turnId) =>
      _recordCompletedInFlightServerTurnKey(_serverTurnKey(threadId, turnId));

  void _recordCompletedInFlightServerTurnKey(String key) {
    _completedInFlightServerTurns.add(key);
    while (_completedInFlightServerTurns.length > 64) {
      _completedInFlightServerTurns.remove(_completedInFlightServerTurns.first);
    }
  }

  /// When [_turn] began, to time it.
  DateTime? _turnStarted;
  int? _turnInputTokens;
  int? _turnOutputTokens;
  final Set<String> _sentTurns = {};
  final List<KernelTurn> _turnQueue = [];

  final Map<String, int> _textLength = {};
  final Map<String, StringBuffer> _reasoning = {};
  final Map<String, Stopwatch> _reasoningClock = {};

  /// The part of each summary streaming in.
  final Map<String, int> _reasoningPart = {};
  final Map<String, DateTime> _startedAt = {};

  /// Commands started and not completed yet, as they started.
  final Map<String, Map<String, Object?>> _commands = {};

  /// Active MCP tool calls started and not completed yet.
  final Map<String, Map<String, Object?>> _mcpCalls = {};

  /// Cached fileChange changes keyed by itemId (used to populate DiffPreview
  /// on `item/fileChange/requestApproval`).
  final Map<String, List<Map<String, Object?>>> _pendingItemChanges = {};

  /// Pending approvals: our request id → the server's JSON-RPC id.
  final Map<String, Object?> _approvals = {};

  /// Pending questions: our request id → (rpcId, questionIds).
  final Map<String, ({Object? rpcId, List<String> questionIds})>
  _pendingQuestions = {};

  // --- SDK MCP Bridge & Process CLI Args ------------------------------------

  Future<AyteSdkMcpBridge?> _ensureSdkBridge(int initEpoch) async {
    if (!_enableSdkMcpBridge || _disposed || initEpoch != _initEpoch) {
      return null;
    }
    if (_sdkBridge != null) return _sdkBridge;
    if (ClaudeSdkTools.serversFor(_cwd).isEmpty) return null;
    final bridge = await AyteSdkMcpBridge.start(
      cwd: _cwd,
      sessionIdProvider: () => _threadId,
      turnIdProvider: () => _turn,
      cancelledProvider: () => _sdkTurnCancelled.future,
      ask: ClaudeSdkTools.asksUser(_cwd) && !(_workspace?.approvesAll ?? false)
          ? _askFromSdkTool
          : null,
      includeAntigravityAlwaysLoad: false,
      disabledTools:
          _switches.disabledTools[ClaudeSdkTools.server] ?? const {},
      serverDisabled: !_switches.serverEnabled(ClaudeSdkTools.server),
    );
    if (_disposed || initEpoch != _initEpoch || _sdkBridge != null) {
      unawaited(bridge.close(force: true));
      return null;
    }
    _sdkBridge = bridge;
    bridge.updateDisabled(
      disabledTools:
          _switches.disabledTools[ClaudeSdkTools.server] ?? const {},
      serverDisabled: !_switches.serverEnabled(ClaudeSdkTools.server),
    );
    if (_threadId != null && _threadId!.isNotEmpty) {
      bridge.updateSessionId(_threadId);
    }
    return bridge;
  }

  static final RegExp _bareTomlKeyRegex = RegExp(r'^[A-Za-z0-9_-]+$');

  static String _tomlKeySegment(String key) =>
      _bareTomlKeyRegex.hasMatch(key) ? key : jsonEncode(key);

  List<String> _buildProcessArgs() {
    final bridge = _sdkBridge;
    _spawnedSwitches = _switches;
    final overrides = _switches.codexMcpOverrides;
    if (bridge == null && overrides.isEmpty) return const [];
    return <String>[
      if (bridge != null) ...[
        '-c',
        'mcp_servers.${ClaudeSdkTools.server}.url="http://127.0.0.1:${bridge.port}/mcp/${bridge.token}"',
        '-c',
        'mcp_servers.${ClaudeSdkTools.server}.enabled=${_switches.serverEnabled(ClaudeSdkTools.server)}',
      ],
      for (final MapEntry(:key, :value) in overrides.entries)
        if (key != ClaudeSdkTools.server) ...[
          '-c',
          'mcp_servers.${_tomlKeySegment(key)}.enabled=$value',
        ],
    ];
  }

  void _applySwitches() {
    final next = ExtensionSwitches.current();
    if (next == _switches) return;
    final prev = _switches;
    _switches = next;
    _sdkBridge?.updateDisabled(
      disabledTools: next.disabledTools[ClaudeSdkTools.server] ?? const {},
      serverDisabled: !next.serverEnabled(ClaudeSdkTools.server),
    );
    if (_initialized && !_disposed) {
      _reconcileServerSwitches(prev, next);
    }
  }

  void _reconcileServerSwitches(
    ExtensionSwitches previous,
    ExtensionSwitches next,
  ) {
    final changedServers = <String>{
      for (final server in {...previous.disabledServers, ...next.disabledServers})
        if (previous.serverEnabled(server) != next.serverEnabled(server))
          server,
    };
    _spawnedSwitches = next;
    if (changedServers.isEmpty) return;
    unawaited(
      Future<void>(() async {
            for (final server in changedServers) {
              if (_disposed || !_initialized) return;
              await _request('config/value/write', {
                'keyPath': 'mcp_servers.${_tomlKeySegment(server)}.enabled',
                'value': next.serverEnabled(server),
                'mergeStrategy': 'upsert',
              }).catchError((_) => const <String, Object?>{});
            }
            if (_disposed || !_initialized) return;
            await _request(
              'config/mcpServer/reload',
              const {},
            ).catchError((_) => const <String, Object?>{});
          })
          .catchError((_) {})
          .whenComplete(() {
            if (!_disposed) refreshMcpServers();
          }),
    );
  }

  Future<ApprovalDecision?> _askFromSdkTool(ApprovalRequest request) {
    if (_disposed) return Future.value();
    final id = 'sdk:${++_sdkAskSeq}';
    final completer = Completer<ApprovalDecision?>();
    _sdkAsks[id] = completer;
    emit(
      InteractionRequested(
        nextSeq,
        ApprovalRequest(
          id: id,
          title: request.title,
          toolName: request.toolName,
          reason: request.reason,
          preview: request.preview,
          alwaysAllowLabel: request.alwaysAllowLabel,
        ),
      ),
    );
    return completer.future;
  }

  void _cancelSdkCalls() {
    final cancelled = _sdkTurnCancelled;
    _sdkTurnCancelled = Completer<void>();
    if (!cancelled.isCompleted) cancelled.complete();
    if (_sdkAsks.isNotEmpty) {
      for (final MapEntry(:key, value: completer) in [..._sdkAsks.entries]) {
        _sdkAsks.remove(key);
        emit(InteractionResolved(nextSeq, key));
        if (!completer.isCompleted) completer.complete(null);
      }
    }
  }

  // --- Commands & Turns -----------------------------------------------------

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
    if (_disposed || !_sentTurns.add(turn.id)) return;
    final parsed = parseAgentMessage(turn.text);
    final userItem = UserMessageItem(
      text: parsed?.text ?? turn.text,
      queued: _turn != null,
      images: turn.images,
      sentAt: DateTime.now(),
      fromAgent: parsed?.from,
      fromSession: parsed?.session,
    );

    if (_turn != null) {
      emit(ItemUpserted(nextSeq, turn.id, userItem));
      if (turn.now) {
        _turnQueue.insert(0, turn);
        emit(
          QueueReordered(nextSeq, [for (final queued in _turnQueue) queued.id]),
        );
        cancel();
      } else {
        _turnQueue.add(turn);
      }
      return;
    }

    _turn = turn.id;
    _turnStarted = DateTime.now();
    _turnInputTokens = null;
    _turnOutputTokens = null;
    emit(TurnStarted(nextSeq, turn.id));
    emit(ItemUpserted(nextSeq, turn.id, userItem));
    unawaited(_dispatchTurn(turn));
  }

  @override
  Future<bool> cancelQueued(String turnId) async {
    final index = _turnQueue.indexWhere((t) => t.id == turnId);
    if (index < 0) return false;
    _turnQueue.removeAt(index);
    emit(ItemRemoved(nextSeq, turnId));
    _maybeDeferredRelease();
    return true;
  }

  @override
  void sendQueuedNow(String turnId) {
    final index = _turnQueue.indexWhere((t) => t.id == turnId);
    if (index < 0) return;
    if (index > 0) {
      final target = _turnQueue.removeAt(index);
      _turnQueue.insert(0, target);
      emit(
        QueueReordered(nextSeq, [for (final queued in _turnQueue) queued.id]),
      );
    }
    if (_turn != null) cancel();
  }

  @override
  void moveQueued(String turnId, int index) {
    final currentIndex = _turnQueue.indexWhere((t) => t.id == turnId);
    if (currentIndex < 0) return;
    final target = _turnQueue.removeAt(currentIndex);
    final clamped = index.clamp(0, _turnQueue.length);
    _turnQueue.insert(clamped, target);
    emit(QueueReordered(nextSeq, [for (final queued in _turnQueue) queued.id]));
  }

  Future<void> _dispatchTurn(KernelTurn turn) async {
    final trimmed = turn.text.trim();
    if (trimmed == '/new' || trimmed.startsWith('/new ')) {
      if (_turn == turn.id) {
        _historyEpoch++;
        _loadingHistory = false;
        _loadingEarlier = false;
        _loadingEarlierFuture = null;
        _threadId = null;
        _serverTurn = null;
        _pendingCompactThreadId = null;
        _pendingCompactWithoutTurnId = 0;
        _lastCompactClientId = null;
        _threadResumed = false;
        _pendingTitle = null;
        _earlierTurnCursor = null;
        _hasEarlierHistory = false;
        _userItemTurnIndex.clear();
        _completedTurnCount = 0;
        _sdkBridge?.updateSessionId(null);
        emitInfoChanged();
        emit(
          ItemUpserted(
            nextSeq,
            'new:${turn.id}',
            const NoticeItem(NoticeKind.info, 'Started a new chat'),
          ),
        );
        _endTurn(turn.id, interrupted: false);
      }
      return;
    }

    if (trimmed == '/compact' || trimmed.startsWith('/compact ')) {
      await _compact(turn);
      return;
    }

    await _start(turn);
  }

  Future<void> _compact(KernelTurn turn) async {
    final initEpoch = _initEpoch;
    try {
      if (_threadId == null) {
        if (_turn == turn.id) {
          emit(
            ItemUpserted(
              nextSeq,
              'compact:${turn.id}',
              const NoticeItem(NoticeKind.info, 'Nothing to compact yet.'),
            ),
          );
          _endTurn(turn.id, interrupted: false);
        }
        return;
      }
      emit(
        ActivityReported(
          nextSeq,
          KernelActivity(KernelActivityKind.compacting, DateTime.now()),
        ),
      );
      await _ensureInitialized(fetchModels: loadLocalCatalog);
      if (_disposed || initEpoch != _initEpoch || _turn != turn.id) return;
      await _ensureResumed();
      if (_disposed || initEpoch != _initEpoch || _turn != turn.id) return;
      final compactThreadId = _threadId;
      _inFlightCompactStarts.add(turn.id);
      final compactRpcId = ++_requests;
      final compactCompleter = Completer<Map<String, Object?>>();
      _responses[compactRpcId] = compactCompleter;
      _pendingCompactStarts[compactRpcId] = (
        clientTurnId: turn.id,
        threadId: compactThreadId,
      );
      _transport.write({
        'id': compactRpcId,
        'method': 'thread/compact/start',
        'params': {'threadId': compactThreadId},
      });
      final Map<String, Object?> compactRes;
      final bool handledInReceive;
      try {
        compactRes = await compactCompleter.future;
      } finally {
        if (initEpoch == _initEpoch) {
          _inFlightCompactStarts.remove(turn.id);
          _pendingCompactStarts.remove(compactRpcId);
          _handledCancelledCompactClients.remove(turn.id);
          handledInReceive =
              _cancelledCompactHandledInReceive.remove(compactRpcId);
        } else {
          handledInReceive = false;
        }
      }
      try {
        if (_disposed || initEpoch != _initEpoch || handledInReceive) {
          return;
        }
        final compactTurnId =
            ((compactRes['turn'] as Map?)?['id'] as String?) ??
            (compactRes['turnId'] as String?);
        if (compactTurnId != null && compactTurnId.isNotEmpty) {
          final key = _serverTurnKey(compactThreadId, compactTurnId);
          if (_disposed || _turn != turn.id || _threadId != compactThreadId) {
            final emptyKey = _serverTurnKey(null, compactTurnId);
            final alreadyCompleted =
                _earlyCompletedServerTurns.remove(key) != null ||
                _completedInFlightServerTurns.remove(key) ||
                (compactThreadId != null &&
                    (_earlyCompletedServerTurns.remove(emptyKey) != null ||
                        _completedInFlightServerTurns.remove(emptyKey)));
            if (!alreadyCompleted) {
              _recordIgnoredServerTurn(compactThreadId, compactTurnId);
            }
            return;
          }
          _ignoredServerTurns.remove(key);
          _completedInFlightServerTurns.remove(key);
          if (_earlyCompletedServerTurns.remove(key)
              case final wasInterrupted?) {
            _serverTurn = null;
            _lastCompactClientId = turn.id;
            emit(
              ItemUpserted(
                nextSeq,
                'compact:${turn.id}',
                NoticeItem(
                  wasInterrupted ? NoticeKind.info : NoticeKind.compaction,
                  wasInterrupted
                      ? 'Conversation compaction interrupted'
                      : 'Conversation compacted',
                ),
              ),
            );
            _endTurn(turn.id, interrupted: wasInterrupted);
            return;
          }
          _lastCompactClientId = turn.id;
          _serverTurn = compactTurnId;
          return;
        }

        if (_disposed || _turn != turn.id || _threadId != compactThreadId) {
          return;
        }
        _compactingTurnClientId = turn.id;
        try {
          await Future<void>.delayed(Duration.zero);
        } finally {
          if (initEpoch == _initEpoch && _compactingTurnClientId == turn.id) {
            _compactingTurnClientId = null;
          }
        }
        if (_disposed ||
            initEpoch != _initEpoch ||
            _turn != turn.id ||
            _threadId != compactThreadId) {
          return;
        }
        if (_serverTurn == null) {
          _incrementPendingCompactWithoutTurnId(_threadId);
          _lastCompactClientId = turn.id;
          emit(
            ItemUpserted(
              nextSeq,
              'compact:${turn.id}',
              const NoticeItem(NoticeKind.compaction, 'Conversation compacted'),
            ),
          );
          _endTurn(turn.id, interrupted: false);
        }
      } finally {
        if (initEpoch == _initEpoch) {
          _compactBoundClientTurns.remove(turn.id);
        }
      }
    } on Object catch (error) {
      if (!_disposed && initEpoch == _initEpoch && _turn == turn.id) {
        emit(
          ItemUpserted(
            nextSeq,
            'error:${turn.id}',
            NoticeItem(NoticeKind.error, 'Codex compact failed: $error'),
          ),
        );
        _endTurn(turn.id, interrupted: true);
      }
    }
  }

  Future<void> _ensureInitialized({bool fetchModels = false}) {
    if (_initialized) return Future.value();
    if (_initializing case final existing?) return existing;
    final initEpoch = _initEpoch;
    late final Future<void> future;
    future = () async {
      _setHealth(const KernelHealth(KernelHealthStatus.starting));
      AyteSdkMcpBridge? createdBridge;
      try {
        createdBridge = await _ensureSdkBridge(initEpoch);
        if (_disposed || initEpoch != _initEpoch) {
          if (createdBridge != null) {
            if (identical(_sdkBridge, createdBridge)) {
              _sdkBridge = null;
            }
            unawaited(createdBridge.close(force: true));
          }
          throw StateError('Codex initialization cancelled');
        }
        _spawnedSwitches ??= _switches;
        await _request('initialize', {
          'clientInfo': {'name': 'ayte', 'version': '1.0.0'},
        });
        if (_disposed || initEpoch != _initEpoch) {
          throw StateError('Codex initialization cancelled');
        }
        _initialized = true;
        if (_enableSdkMcpBridge &&
            _spawnedSwitches != null &&
            _spawnedSwitches != _switches) {
          _reconcileServerSwitches(_spawnedSwitches!, _switches);
        } else {
          _spawnedSwitches = _switches;
        }
        _setHealth(KernelHealth.ready);
        if (_threadId != null) {
          _flushPendingTitle();
        }
        if (fetchModels && !_disposed) {
          unawaited(_refreshModelCatalog());
        }
      } on Object catch (error) {
        if (!_disposed && initEpoch == _initEpoch) {
          if (!_initialized && _sdkBridge != null) {
            final bridge = _sdkBridge;
            _sdkBridge = null;
            unawaited(bridge?.close(force: true));
          }
          if (_health.status != KernelHealthStatus.failed) {
            _setHealth(
              KernelHealth(
                KernelHealthStatus.failed,
                message: _friendlyFailureMessage('$error'),
                detail: '$error',
              ),
            );
          }
        } else if (createdBridge != null &&
            !identical(_sdkBridge, createdBridge)) {
          unawaited(createdBridge.close(force: true));
        }
        rethrow;
      }
    }().whenComplete(() {
      if (identical(_initializing, future)) {
        _initializing = null;
      }
      _maybeDeferredRelease();
    });
    _initializing = future;
    return future;
  }

  Future<void> _refreshModelCatalog() async {
    try {
      final listed = await _request('model/list', {
        'includeHidden': false,
      }).timeout(const Duration(seconds: 5));
      final parsed = CodexModels.parseRpcModelList(listed);
      if (parsed.isNotEmpty && !_disposed) {
        _applyModelCatalog(parsed);
      }
    } on Object {
      // Keep locally loaded catalog if live model/list is unsupported.
    }
  }

  ({String approvalPolicy, Map<String, Object?> sandboxPolicy, String sandbox})
  _policy() {
    if (mode.selected == 'ask') {
      return (
        approvalPolicy: 'never',
        sandboxPolicy: const {'type': 'readOnly'},
        sandbox: 'read-only',
      );
    }
    return switch (_selectedPermission) {
      'unless-trusted' => (
        approvalPolicy: 'untrusted',
        sandboxPolicy: const {'type': 'workspaceWrite'},
        sandbox: 'workspace-write',
      ),
      'never' => (
        approvalPolicy: 'never',
        sandboxPolicy: const {'type': 'workspaceWrite'},
        sandbox: 'workspace-write',
      ),
      'full-access' => (
        approvalPolicy: 'never',
        sandboxPolicy: const {'type': 'dangerFullAccess'},
        sandbox: 'danger-full-access',
      ),
      _ => (
        approvalPolicy: 'on-request',
        sandboxPolicy: const {'type': 'workspaceWrite'},
        sandbox: 'workspace-write',
      ),
    };
  }

  ({String? baseInstructions, String? developerInstructions})
  _buildThreadInstructions() {
    final ws = _workspace;
    final sdkInst = _enableSdkMcpBridge
        ? ClaudeSdkTools.instructionsFor(_cwd)?.trim() ?? ''
        : '';
    final wsInst = ws?.instructions.trim() ?? '';
    final extraFolders = ws == null
        ? const <String>[]
        : [
            for (final f in [...ws.folders, ...ws.reaches])
              if (f.isNotEmpty && f != _cwd) f,
          ];
    final folderNote = extraFolders.isEmpty
        ? ''
        : 'Additional workspace folders: ${extraFolders.join(', ')}';

    if (ws?.ownPrompt == true) {
      final parts = <String>[
        if (wsInst.isNotEmpty) wsInst,
        if (sdkInst.isNotEmpty) sdkInst,
        if (folderNote.isNotEmpty) folderNote,
      ];
      return (
        baseInstructions: parts.isEmpty ? '' : parts.join('\n\n'),
        developerInstructions: null,
      );
    }

    if (ws == null && sdkInst.isEmpty) {
      return (baseInstructions: null, developerInstructions: null);
    }

    final devParts = <String>[
      ClaudeLaunch.appendedSystemPrompt,
      if (wsInst.isNotEmpty) wsInst,
      if (sdkInst.isNotEmpty) sdkInst,
      if (folderNote.isNotEmpty) folderNote,
    ];
    return (
      baseInstructions: null,
      developerInstructions: devParts.join('\n\n'),
    );
  }

  Map<String, Object?> _threadParams({String? threadId}) {
    final policy = _policy();
    final instructions = _buildThreadInstructions();
    final hasExplicitContext =
        context.cwd != null ||
        context.resume != null ||
        _workspace != null ||
        _enableSdkMcpBridge;
    return <String, Object?>{
      'threadId': ?threadId,
      'model': model.selected,
      if (hasExplicitContext) 'cwd': _cwd,
      if (hasExplicitContext) 'approvalPolicy': policy.approvalPolicy,
      if (hasExplicitContext) 'sandbox': policy.sandbox,
      'baseInstructions': ?instructions.baseInstructions,
      'developerInstructions': ?instructions.developerInstructions,
    };
  }

  Future<void> _ensureResumed() async {
    if (_threadId == null || _threadResumed) return;
    final initEpoch = _initEpoch;
    await _request('thread/resume', _threadParams(threadId: _threadId));
    if (_disposed || initEpoch != _initEpoch) return;
    _threadResumed = true;
    _sdkBridge?.updateSessionId(_threadId);
    _flushPendingTitle();
  }

  Future<void> _start(KernelTurn turn) async {
    final initEpoch = _initEpoch;
    try {
      await _ensureInitialized(fetchModels: loadLocalCatalog);
      if (_disposed || initEpoch != _initEpoch || _turn != turn.id) return;
      if (_threadId == null) {
        final started = await _request('thread/start', _threadParams());
        if (_disposed || initEpoch != _initEpoch || _turn != turn.id) return;
        final newId = (started['thread'] as Map)['id'] as String;
        _threadId = newId;
        _threadResumed = true;
        _sdkBridge?.updateSessionId(newId);
        if (!_disposed) emitInfoChanged();
        _flushPendingTitle();
      } else if (!_threadResumed) {
        await _ensureResumed();
        if (_disposed || initEpoch != _initEpoch || _turn != turn.id) return;
      }

      _userItemTurnIndex[turn.id] = _completedTurnCount;
      final policy = _policy();
      final chosenEffort = effort.selected;
      final input = <Map<String, Object?>>[
        if (turn.text.isNotEmpty || turn.images.isEmpty)
          {'type': 'text', 'text': turn.text},
        for (final image in turn.images) ...[
          if (image.number case final n?)
            {'type': 'text', 'text': imageReference(n)},
          {
            'type': 'image',
            'url':
                'data:${image.mediaType};base64,${base64Encode(image.bytes)}',
          },
        ],
        for (final note in turn.notes) {'type': 'text', 'text': note},
      ];
      final threadId = _threadId;
      _inFlightTurnStarts.add(turn.id);
      final Map<String, Object?> started;
      try {
        started = await _request('turn/start', {
          'threadId': threadId,
          'input': input,
          'model': model.selected,
          'effort': ?chosenEffort,
          'approvalPolicy': policy.approvalPolicy,
          'sandboxPolicy': policy.sandboxPolicy,
        });
      } finally {
        if (initEpoch == _initEpoch) {
          _inFlightTurnStarts.remove(turn.id);
        }
      }
      if (_disposed || initEpoch != _initEpoch) return;
      final startedTurnId = (started['turn'] as Map)['id'] as String;
      final key = _serverTurnKey(threadId, startedTurnId);
      // Stopped or reset (/new) before the server knew the turn: stop it on
      // the captured threadId and mark it ignored so late notifications cannot
      // hijack a promoted/subsequent turn.
      if (_turn != turn.id || _threadId != threadId) {
        if (_serverTurn == startedTurnId && _threadId == threadId) {
          _serverTurn = null;
        }
        final emptyKey = _serverTurnKey(null, startedTurnId);
        final alreadyCompleted =
            _earlyCompletedServerTurns.remove(key) != null ||
            _completedInFlightServerTurns.remove(key) ||
            (threadId != null &&
                (_earlyCompletedServerTurns.remove(emptyKey) != null ||
                    _completedInFlightServerTurns.remove(emptyKey)));
        if (!alreadyCompleted) {
          _recordIgnoredServerTurn(threadId, startedTurnId);
          _interruptTurn(threadId: threadId, turnId: startedTurnId);
        }
        return;
      }
      _ignoredServerTurns.remove(key);
      _completedInFlightServerTurns.remove(key);
      if (_earlyCompletedServerTurns.remove(key) case final wasInterrupted?) {
        _serverTurn = null;
        _endTurn(turn.id, interrupted: wasInterrupted);
        return;
      }
      _serverTurn = startedTurnId;
    } on Object catch (error) {
      if (!_disposed && initEpoch == _initEpoch && _turn == turn.id) {
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

  void _interrupt() =>
      _interruptTurn(threadId: _threadId, turnId: _serverTurn);

  void _interruptTurn({String? threadId, String? turnId}) {
    if (turnId == null || threadId == null) return;
    unawaited(
      _request('turn/interrupt', {
        'threadId': threadId,
        'turnId': turnId,
      }).catchError((_) => const <String, Object?>{}),
    );
  }

  @override
  void answer(String requestId, InteractionAnswer answer) {
    if (_sdkAsks.remove(requestId) case final sdk?) {
      emit(InteractionResolved(nextSeq, requestId));
      if (!sdk.isCompleted) {
        sdk.complete(switch (answer) {
          ApprovalAnswer(:final decision) => decision,
          QuestionAnswer() => null,
        });
      }
      _maybeDeferredRelease();
      return;
    }

    if (_pendingQuestions.remove(requestId) case final pending?) {
      emit(InteractionResolved(nextSeq, requestId));
      final answersMap = <String, Object?>{
        for (var i = 0; i < pending.questionIds.length; i++)
          pending.questionIds[i]: {
            'answers': switch (answer) {
              QuestionAnswer(:final picks, skipped: false)
                  when i < picks.length =>
                picks[i],
              _ => const <String>[],
            },
          },
      };
      _transport.write({
        'id': pending.rpcId,
        'result': {'answers': answersMap},
      });
      _maybeDeferredRelease();
      return;
    }

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
    _maybeDeferredRelease();
  }

  @override
  void cancel() {
    final turn = _turn;
    if (turn == null) return;
    if (_serverTurn case final activeServerTurn?) {
      _recordIgnoredServerTurn(_threadId, activeServerTurn);
    }
    _cancelSdkCalls();
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
    if (turns > 0) {
      _completedTurnCount = math.max(0, _completedTurnCount - turns);
    }
    if (_threadId case final threadId? when turns > 0) {
      unawaited(
        _request('thread/rollback', {
          'threadId': threadId,
          'numTurns': turns,
        }).catchError((_) => const <String, Object?>{}),
      );
    }
    emit(Rewound(nextSeq, itemId: itemId, index: index));
    return true;
  }

  @override
  Future<SessionRecord?> fork({String? before, required String title}) async {
    if (!canFork) return null;
    final sourceThreadId = _threadId!;
    try {
      await _ensureInitialized(fetchModels: loadLocalCatalog);
      await _ensureResumed();
      final res = await _request(
        'thread/fork',
        _threadParams(threadId: sourceThreadId),
      );
      final thread = (res['thread'] as Map?)?.cast<String, Object?>();
      final newId = thread?['id'] as String?;
      if (newId == null || newId.isEmpty) {
        throw StateError('thread/fork returned no thread id');
      }
      final newPath = thread?['path'] as String?;
      if (before != null) {
        final keepTurns = _userItemTurnIndex[before];
        if (keepTurns != null && _completedTurnCount > keepTurns) {
          final dropTurns = _completedTurnCount - keepTurns;
          await _request('thread/rollback', {
            'threadId': newId,
            'numTurns': dropTurns,
          }).catchError((_) => const <String, Object?>{});
        }
      }
      final trimmedTitle = title.trim();
      if (trimmedTitle.isNotEmpty) {
        await _request('thread/name/set', {
          'threadId': newId,
          'name': trimmedTitle,
        }).catchError((_) => const <String, Object?>{});
        if (catalog case final CodexCatalog localCatalog when newPath != null) {
          unawaited(
            localCatalog.noteSessionTitle(newId, trimmedTitle).catchError((_) {}),
          );
        }
      }
      return SessionRecord(
        id: newId,
        title: trimmedTitle,
        updatedAt: DateTime.now(),
        cwd: _cwd,
        path: newPath,
      );
    } on Object catch (error) {
      if (!_disposed) {
        emit(
          ItemUpserted(
            nextSeq,
            'fork:${before ?? sourceThreadId}',
            NoticeItem(NoticeKind.error, 'Could not fork: $error'),
          ),
        );
      }
      return null;
    }
  }

  @override
  void rename(String title) {
    final trimmed = title.trim();
    if (trimmed.isEmpty || _disposed) return;
    if (_threadId == null || !_initialized) {
      _pendingTitle = trimmed;
      return;
    }
    _sentTitles.add(trimmed);
    unawaited(
      _request('thread/name/set', {
        'threadId': _threadId,
        'name': trimmed,
      }).catchError((_) => const <String, Object?>{}),
    );
  }

  void _flushPendingTitle() {
    final title = _pendingTitle;
    if (title == null || _threadId == null || !_initialized) return;
    _pendingTitle = null;
    _sentTitles.add(title);
    unawaited(
      _request('thread/name/set', {
        'threadId': _threadId,
        'name': title,
      }).catchError((_) => const <String, Object?>{}),
    );
  }

  // --- History --------------------------------------------------------------

  Future<void> _loadHistory(SessionRecord session) async {
    final historyEpoch = _historyEpoch;
    try {
      final path = session.path;
      if (path != null &&
          path.isNotEmpty &&
          !path.toLowerCase().endsWith('.zst') &&
          File(path).existsSync()) {
        final page = await CodexCatalog.readRolloutPage(
          path,
          turns: _historyPageSize,
        );
        if (_disposed || historyEpoch != _historyEpoch) return;
        _applyHistoryModel(page.model, page.effort);
        _earlierTurnCursor = page.earlierBeforeTurn;
        _hasEarlierHistory = page.earlierBeforeTurn != null;
        var turnOffset = page.earlierBeforeTurn ?? 0;
        for (final turn in page.turns) {
          _replayTurnItems(turn.items, turnIndex: turnOffset++);
        }
        _completedTurnCount = turnOffset;
        return;
      }

      await _ensureInitialized(fetchModels: loadLocalCatalog);
      if (_disposed || historyEpoch != _historyEpoch) return;
      final res = await _request(
        'thread/resume',
        _threadParams(threadId: session.id),
      );
      if (_disposed || historyEpoch != _historyEpoch) return;
      _threadResumed = true;
      _sdkBridge?.updateSessionId(session.id);
      final thread = (res['thread'] as Map?)?.cast<String, Object?>();
      final rawTurns = thread?['turns'] as List? ?? const [];
      var turnIdx = 0;
      for (final rawTurn in rawTurns) {
        if (rawTurn is! Map) continue;
        final items = [
          for (final rawItem in rawTurn['items'] as List? ?? const [])
            if (rawItem is Map) rawItem.cast<String, Object?>(),
        ];
        _replayTurnItems(items, turnIndex: turnIdx++);
      }
      _completedTurnCount = turnIdx;
    } on Object catch (error) {
      if (!_disposed && historyEpoch == _historyEpoch) {
        emit(
          ItemUpserted(
            nextSeq,
            'history-error',
            NoticeItem(NoticeKind.error, 'Could not read this session: $error'),
          ),
        );
      }
    } finally {
      if (historyEpoch == _historyEpoch) {
        _loadingHistory = false;
        if (!_disposed) emitInfoChanged();
      }
    }
  }

  void _applyHistoryModel(String? historyModel, String? historyEffort) {
    if (historyModel != null &&
        !context.settings.containsKey(KernelChoiceKind.model.name) &&
        _infoOf(historyModel) != null) {
      _selectedModel = historyModel;
    }
    if (historyEffort != null &&
        historyEffort.isNotEmpty &&
        !context.settings.containsKey(KernelChoiceKind.effort.name)) {
      final info = _infoOf(_selectedModel);
      if (info == null || info.effortLevels.contains(historyEffort)) {
        _pickedEfforts.putIfAbsent(_selectedModel, () => historyEffort);
      }
    }
  }

  void _replayTurnItems(
    List<Map<String, Object?>> items, {
    required int turnIndex,
  }) {
    for (final (id, chatItem) in _translateHistoryItems(
      items,
      turnIndex: turnIndex,
    )) {
      if (chatItem is UserMessageItem) {
        _userItemTurnIndex[id] = turnIndex;
      }
      emit(ItemUpserted(nextSeq, id, chatItem));
    }
  }

  List<(String, ChatItem)> _translateHistoryItems(
    List<Map<String, Object?>> items, {
    required int turnIndex,
  }) {
    final out = <(String, ChatItem)>[];
    var seq = 0;
    for (final item in items) {
      final type = item['type'] as String?;
      final id = (item['id'] as String?) ?? 'hist-$turnIndex-${++seq}';
      switch (type) {
        case 'userMessage':
          final rawText = _extractUserMessageText(item['content']);
          final parsed = parseAgentMessage(rawText);
          out.add((
            id,
            UserMessageItem(
              text: parsed?.text ?? rawText,
              fromAgent: parsed?.from,
              fromSession: parsed?.session,
            ),
          ));
        case 'reasoning':
          final summary = item['summary'];
          final text = summary is List
              ? summary.whereType<String>().join('\n\n')
              : '${summary ?? ''}';
          if (text.isNotEmpty) {
            out.add((
              id,
              ThinkingItem(text: text, tokens: text.length, seconds: 1),
            ));
          }
        case 'agentMessage':
          final text = '${item['text'] ?? ''}';
          if (text.isNotEmpty) {
            out.add((id, AssistantTextItem(text)));
          }
        case 'commandExecution':
          out.add((id, _commandItem(item)));
        case 'mcpToolCall':
          out.add((id, _mcpToolItem(item, done: true)));
        case 'fileChange':
          final changes = item['changes'] as List? ?? const [];
          for (final (index, raw) in changes.indexed) {
            if (raw is! Map) continue;
            final path = '${raw['path'] ?? ''}';
            final diff = '${raw['diff'] ?? ''}';
            final lines = _parseDiffLines(diff).lines;
            final slash = path.lastIndexOf(RegExp(r'[/\\]'));
            out.add((
              '$id:$index',
              CodeDiffItem(
                fileName: path.substring(slash + 1),
                directory: slash < 0 ? '' : path.substring(0, slash),
                lines: lines,
              ),
            ));
          }
        case 'contextCompaction':
          out.add((
            id,
            const NoticeItem(NoticeKind.compaction, 'Conversation compacted'),
          ));
      }
    }
    return out;
  }

  static String _extractUserMessageText(Object? content) {
    if (content is String) return content;
    if (content is! List) return '';
    final parts = <String>[];
    for (final block in content) {
      if (block is Map && block['type'] == 'text') {
        final t = '${block['text'] ?? ''}';
        if (t.isNotEmpty) parts.add(t);
      }
    }
    return parts.join('\n');
  }

  @override
  Future<void> loadEarlier() {
    if (!_hasEarlierHistory || _earlierTurnCursor == null) {
      return Future.value();
    }
    if (_loadingEarlierFuture case final existing?) return existing;
    late final Future<void> future;
    future = _loadEarlierInternal().whenComplete(() {
      if (identical(_loadingEarlierFuture, future)) {
        _loadingEarlierFuture = null;
      }
    });
    _loadingEarlierFuture = future;
    return future;
  }

  Future<void> _loadEarlierInternal() async {
    final historyEpoch = _historyEpoch;
    final path = context.resume?.path;
    final cursor = _earlierTurnCursor;
    if (path == null || cursor == null || _disposed) return;
    _loadingEarlier = true;
    emitInfoChanged();
    try {
      final page = await CodexCatalog.readRolloutPage(
        path,
        turns: _historyPageSize,
        beforeTurn: cursor,
      );
      if (_disposed || historyEpoch != _historyEpoch) return;
      _earlierTurnCursor = page.earlierBeforeTurn;
      _hasEarlierHistory = page.earlierBeforeTurn != null;
      final prepended = <(String, ChatItem)>[];
      var turnIdx = page.earlierBeforeTurn ?? 0;
      for (final turn in page.turns) {
        final items = _translateHistoryItems(turn.items, turnIndex: turnIdx);
        for (final (id, item) in items) {
          if (item is UserMessageItem) {
            _userItemTurnIndex[id] = turnIdx;
          }
          prepended.add((id, item));
        }
        turnIdx++;
      }
      if (prepended.isNotEmpty) {
        emit(HistoryPrepended(nextSeq, prepended));
      }
    } finally {
      if (historyEpoch == _historyEpoch) {
        _loadingEarlier = false;
        if (!_disposed) emitInfoChanged();
      }
    }
  }

  // --- MCP Servers ----------------------------------------------------------

  @override
  void refreshMcpServers() {
    if (_disposed) return;
    unawaited(
      _ensureInitialized(fetchModels: loadLocalCatalog)
          .then((_) => _request('mcpServerStatus/list', const {}))
          .then(_applyMcpServers)
          .catchError((_) {}),
    );
  }

  void _applyMcpServers(Map<String, Object?> response) {
    if (_disposed) return;
    final rawList = response['data'] ?? response['servers'] ?? const <Object?>[];
    if (rawList is! List) return;
    final parsed = <McpServer>[];
    for (final raw in rawList) {
      if (raw is! Map) continue;
      final map = raw.cast<String, Object?>();
      final name = '${map['name'] ?? ''}'.trim();
      if (name.isEmpty) continue;
      final statusStr = '${map['runtimeStatus'] ?? map['status'] ?? ''}';
      final status = switch (statusStr) {
        'connected' || 'ready' => McpServerStatus.connected,
        'authenticationRequired' ||
        'needsAuth' ||
        'needs_auth' ||
        'needs-auth' => McpServerStatus.needsAuth,
        'disabled' => McpServerStatus.disabled,
        'failed' || 'error' || 'cancelled' => McpServerStatus.failed,
        _ => McpServerStatus.pending,
      };
      final tools = <String>[];
      final rawTools = map['tools'];
      if (rawTools is Map) {
        for (final k in rawTools.keys) {
          if (k is String && k.isNotEmpty) tools.add(k);
        }
      } else if (rawTools is List) {
        for (final t in rawTools) {
          if (t is String && t.isNotEmpty) {
            tools.add(t);
          } else if (t is Map && t['name'] is String) {
            tools.add(t['name'] as String);
          }
        }
      }
      parsed.add(
        McpServer(
          name: name,
          status: status,
          error: (map['toolsError'] ?? map['error']) as String?,
          scope: map['scope'] as String?,
          version: map['version'] as String?,
          tools: tools,
        ),
      );
    }
    _servers = parsed;
    emitInfoChanged();
  }

  void _setServerStatus(String name, McpServerStatus status) {
    final current = _servers;
    if (current == null) return;
    _servers = [
      for (final s in current)
        s.name == name
            ? McpServer(
                name: s.name,
                status: status,
                scope: s.scope,
                version: s.version,
                tools: s.tools,
              )
            : s,
    ];
    emitInfoChanged();
  }

  @override
  void setMcpServerEnabled(String name, bool enabled) {
    _setServerStatus(
      name,
      enabled ? McpServerStatus.pending : McpServerStatus.disabled,
    );
    if (name == ClaudeSdkTools.server && _enableSdkMcpBridge) {
      _switches = _switches.withServer(name, enabled);
      _sdkBridge?.updateDisabled(serverDisabled: !enabled);
      if (ExtensionSwitches.save case final save?) {
        unawaited(Future<void>.sync(() => save(_switches)).catchError((_) {}));
      }
    }
    unawaited(
      _ensureInitialized(fetchModels: loadLocalCatalog)
          .then((_) async {
            await _request('config/value/write', {
              'keyPath': 'mcp_servers.${_tomlKeySegment(name)}.enabled',
              'value': enabled,
              'mergeStrategy': 'upsert',
            }).catchError((_) => const <String, Object?>{});
            await _request(
              'config/mcpServer/reload',
              const {},
            ).catchError((_) => const <String, Object?>{});
          })
          .catchError((_) {})
          .whenComplete(refreshMcpServers),
    );
  }

  @override
  void reconnectMcpServer(String name) {
    _setServerStatus(name, McpServerStatus.pending);
    unawaited(
      _ensureInitialized(fetchModels: loadLocalCatalog)
          .then(
            (_) => _request(
              'config/mcpServer/reload',
              const {},
            ).catchError((_) => const <String, Object?>{}),
          )
          .catchError((_) => const <String, Object?>{})
          .whenComplete(refreshMcpServers),
    );
  }

  @override
  Future<Uri?> authenticateMcpServer(String name) async {
    await _ensureInitialized(fetchModels: loadLocalCatalog);
    final res = await _request('mcpServer/oauth/login', {
      'name': name,
      if (_threadId != null) 'threadId': _threadId,
    });
    final rawUrl = (res['authorizationUrl'] ?? res['authUrl']) as String?;
    final uri = rawUrl == null ? null : Uri.tryParse(rawUrl);
    if (uri == null || !uri.hasScheme) {
      refreshMcpServers();
      return null;
    }
    return uri;
  }

  // --- Usage & Rate Limits --------------------------------------------------

  @override
  Future<void> refreshUsage() {
    if (_disposed) return Future.value();
    return _refreshingUsage ??= () async {
      try {
        await _ensureInitialized(fetchModels: loadLocalCatalog);
        final res = await _request('account/rateLimits/read', const {});
        _applyRateLimits(res);
      } on Object {
        if (!_disposed) {
          emit(
            StatsReported(
              nextSeq,
              UsageStats(
                limits: _accountLimits,
                limitsState: LimitsState.unavailable,
              ),
            ),
          );
        }
      }
    }().whenComplete(() => _refreshingUsage = null);
  }

  void _applyRateLimits(Map<String, Object?> payload) {
    if (_disposed) return;
    final rawLimits =
        (payload['rateLimits'] as Map?)?.cast<String, Object?>() ??
        ((payload['rateLimitsByLimitId'] as Map?)?['codex'] as Map?)
            ?.cast<String, Object?>();
    if (rawLimits == null) {
      emit(
        StatsReported(
          nextSeq,
          UsageStats(
            limits: _accountLimits,
            limitsState: _accountLimits.isEmpty
                ? LimitsState.unavailable
                : LimitsState.idle,
          ),
        ),
      );
      return;
    }

    final windows = <RateLimitWindow>[];
    void addWindow(Object? raw, String fallbackLabel) {
      if (raw is! Map) return;
      final used = raw['usedPercent'];
      if (used is! num) return;
      final mins = (raw['windowDurationMins'] as num?)?.toInt();
      final label = mins == null
          ? fallbackLabel
          : mins >= 1440 && mins % 1440 == 0
          ? '${mins ~/ 1440}d'
          : mins >= 60 && mins % 60 == 0
          ? '${mins ~/ 60}h'
          : '${mins}m';
      DateTime? resetsAt;
      final rawReset = raw['resetsAt'];
      if (rawReset is num) {
        final ms = rawReset > 1e12
            ? rawReset.toInt()
            : (rawReset * 1000).round();
        resetsAt = DateTime.fromMillisecondsSinceEpoch(ms);
      } else if (rawReset is String) {
        resetsAt = DateTime.tryParse(rawReset);
      }
      windows.add(
        RateLimitWindow(
          label,
          (used / 100).clamp(0.0, 1.0).toDouble(),
          resetsAt: resetsAt,
        ),
      );
    }

    addWindow(rawLimits['primary'], '5h');
    addWindow(rawLimits['secondary'], '7d');
    if (windows.isNotEmpty) {
      _accountLimits = windows;
    }
    emit(
      StatsReported(
        nextSeq,
        UsageStats(
          limits: _accountLimits,
          limitsState: _accountLimits.isEmpty
              ? LimitsState.unavailable
              : LimitsState.idle,
        ),
      ),
    );
  }

  // --- File Suggestions -----------------------------------------------------

  @override
  Future<List<FileSuggestion>> suggestFiles(String query) async {
    if (_initialized && !_disposed) {
      try {
        final roots = <String>[
          _cwd,
          if (_workspace case final ws?)
            for (final f in ws.folders)
              if (f.isNotEmpty && f != _cwd) f,
        ];
        final res = await _request('fuzzyFileSearch', {
          'query': query,
          'roots': roots,
          'cancellationToken': null,
        }).timeout(const Duration(seconds: 4));
        final rawFiles = res['files'];
        if (rawFiles is List) {
          return [
            for (final item in rawFiles)
              if (item is Map)
                if ((item['path'] ?? item['relativePath']) case final String s
                    when s.isNotEmpty)
                  FileSuggestion(s),
          ];
        }
      } on Object {
        // Fall through to local file walk fallback.
      }
    }
    return _localSuggestFiles(query);
  }

  Future<List<FileSuggestion>> _localSuggestFiles(String query) async {
    final rootDir = Directory(_cwd);
    if (!rootDir.existsSync()) return const [];
    final q = query.trim().toLowerCase();
    final out = <FileSuggestion>[];
    const ignored = {'.git', 'node_modules', '.dart_tool', 'build', '.idea'};
    final queue = <Directory>[rootDir];
    var visited = 0;
    try {
      while (queue.isNotEmpty && out.length < 80 && visited < 2000) {
        final current = queue.removeAt(0);
        await for (final entity in current.list(followLinks: false)) {
          visited++;
          if (out.length >= 80 || visited >= 2000) break;
          final name = p.basename(entity.path);
          if (ignored.contains(name)) continue;
          final rel = p.relative(entity.path, from: _cwd).replaceAll(r'\', '/');
          if (entity is Directory) {
            queue.add(entity);
            final dirPath = '$rel/';
            if (q.isEmpty || dirPath.toLowerCase().contains(q)) {
              out.add(FileSuggestion(dirPath));
            }
          } else if (q.isEmpty || rel.toLowerCase().contains(q)) {
            out.add(FileSuggestion(rel));
          }
        }
      }
    } on Object {
      // Ignore permission or IO issues during directory walk.
    }
    return out;
  }

  @override
  void dispose() {
    _disposed = true;
    _initEpoch++;
    _historyEpoch++;
    _compactingTurnClientId = null;
    _pendingCompactStarts.clear();
    _compactBoundClientTurns.clear();
    _pendingCompactThreadId = null;
    _pendingCompactWithoutTurnId = 0;
    _lastCompactClientId = null;
    _inFlightCompactStarts.clear();
    _cancelledCompactHandledInReceive.clear();
    _handledCancelledCompactClients.clear();
    _inFlightTurnStarts.clear();
    _ignoredServerTurns.clear();
    _earlyCompletedServerTurns.clear();
    _completedInFlightServerTurns.clear();
    ExtensionSwitches.changes?.removeListener(_applySwitches);
    _failPendingResponses('Codex disposed');
    _cancelSdkCalls();
    if (_sdkBridge case final bridge?) {
      _sdkBridge = null;
      unawaited(bridge.close(force: true));
    }
    unawaited(_subscription.cancel());
    _transport.close();
    closeEvents();
  }

  // --- Translation ------------------------------------------------------------

  void _receive(Map<String, Object?> message) {
    final method = message['method'] as String?;
    final params = (message['params'] as Map?)?.cast<String, Object?>();
    if (method == null) {
      final msgId = message['id'];
      final completer = _responses.remove(msgId);
      if (completer == null) return;
      if (msgId != null) {
        final pendingCompact = _pendingCompactStarts.remove(msgId);
        if (pendingCompact != null && message['error'] == null && !_disposed) {
          final resMap = (message['result'] as Map?)?.cast<String, Object?>();
          final compactTurnId =
              ((resMap?['turn'] as Map?)?['id'] as String?) ??
              (resMap?['turnId'] as String?);
          final compactClientTurnId = pendingCompact.clientTurnId;
          final compactThreadId = pendingCompact.threadId;
          if (compactTurnId == null || compactTurnId.isEmpty) {
            if (_turn == compactClientTurnId && _threadId == compactThreadId) {
              _compactingTurnClientId = compactClientTurnId;
            } else if (compactThreadId != null &&
                _threadId == compactThreadId &&
                !_compactBoundClientTurns.remove(compactClientTurnId)) {
              _incrementPendingCompactWithoutTurnId(compactThreadId);
            }
          } else if (_turn != compactClientTurnId ||
              _threadId != compactThreadId) {
            final key = _serverTurnKey(compactThreadId, compactTurnId);
            final emptyKey = _serverTurnKey(null, compactTurnId);
            final alreadyCompleted =
                _earlyCompletedServerTurns.remove(key) != null ||
                _completedInFlightServerTurns.remove(key) ||
                (compactThreadId != null &&
                    (_earlyCompletedServerTurns.remove(emptyKey) != null ||
                        _completedInFlightServerTurns.remove(emptyKey)));
            if (!alreadyCompleted) {
              _recordIgnoredServerTurn(compactThreadId, compactTurnId);
            }
            _cancelledCompactHandledInReceive.add(msgId);
            _handledCancelledCompactClients.add(compactClientTurnId);
          }
        }
      }
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
      case ProcessCodexTransport.transportExitMethod:
        _onTransportExit(params ?? const {});
      case 'turn/started':
        final turnMap = params!['turn'] as Map;
        final tid = turnMap['id'] as String?;
        if (tid == null || _turn == null) return;
        final notifThreadId =
            (params['threadId'] as String?) ??
            (turnMap['threadId'] as String?);
        if (notifThreadId != null && notifThreadId != _threadId) {
          return;
        }
        if (_isIgnoredServerTurn(notifThreadId, tid)) {
          return;
        }
        if (_serverTurn != null) {
          return;
        }
        if (_hasOrphanedTurnStart && _compactingTurnClientId != _turn) {
          return;
        }
        if (notifThreadId == null && _hasIgnoredServerTurnOnAnyThread(tid)) {
          return;
        }
        if (_pendingCompactWithoutTurnId > 0 &&
            _pendingCompactThreadId == _threadId &&
            _compactingTurnClientId != _turn) {
          return;
        }
        _serverTurn = tid;
        if (_turn case final ours?
            when _inFlightCompactStarts.contains(ours) ||
                _compactingTurnClientId == ours) {
          _compactBoundClientTurns.add(ours);
        }
      case 'turn/completed':
        final turn = params!['turn'] as Map;
        final tid = turn['id'] as String?;
        if (tid == null) return;
        final notifThreadId =
            (params['threadId'] as String?) ?? (turn['threadId'] as String?);
        final isDifferentThread =
            notifThreadId != null && notifThreadId != _threadId;
        if (isDifferentThread || tid != _serverTurn) {
          final removedKey = _removeIgnoredServerTurnKey(notifThreadId, tid);
          if (removedKey != null) {
            if (_inFlightTurnStarts.isNotEmpty ||
                _inFlightCompactStarts.any(
                  (id) => !_handledCancelledCompactClients.contains(id),
                )) {
              _recordCompletedInFlightServerTurnKey(removedKey);
            }
          } else if (_inFlightTurnStarts.isNotEmpty ||
              _inFlightCompactStarts.any(
                (id) => !_handledCancelledCompactClients.contains(id),
              )) {
            _recordEarlyCompletedServerTurn(
              notifThreadId ?? _threadId,
              tid,
              interrupted: turn['status'] == 'interrupted',
            );
          } else if (_pendingCompactWithoutTurnId > 0 &&
              (notifThreadId == null ||
                  notifThreadId == _pendingCompactThreadId)) {
            _pendingCompactWithoutTurnId--;
            if (_pendingCompactWithoutTurnId == 0) {
              _pendingCompactThreadId = null;
            }
          }
          return;
        }
        _serverTurn = null;
        if (_turn case final ours?) {
          if (_inFlightTurnStarts.contains(ours) ||
              _inFlightCompactStarts.contains(ours)) {
            _recordCompletedInFlightServerTurn(notifThreadId ?? _threadId, tid);
          }
          _endTurn(ours, interrupted: turn['status'] == 'interrupted');
        }
      case 'item/started':
        _itemStarted((params!['item'] as Map).cast<String, Object?>());
      case 'item/completed':
        _itemCompleted((params!['item'] as Map).cast<String, Object?>());
      case 'item/fileChange/patchUpdated':
        if (params != null) {
          final itemId = params['itemId'] as String?;
          final changes = params['changes'];
          if (itemId != null && changes is List) {
            _pendingItemChanges[itemId] = [
              for (final c in changes)
                if (c is Map) c.cast<String, Object?>(),
            ];
          }
        }
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
        final last = (usage['last'] as Map?)?.cast<String, Object?>();
        if (last != null) {
          final inTok = (last['inputTokens'] as num?)?.toInt();
          final outTok = (last['outputTokens'] as num?)?.toInt();
          if (inTok != null) _turnInputTokens = inTok;
          if (outTok != null) _turnOutputTokens = outTok;
        }
        emit(
          UsageReported(
            nextSeq,
            ContextUsage(
              window: usage['modelContextWindow'] as int? ?? contextWindow,
              // The last request's, which is what the context holds; the
              // total adds up every request, and never drops on compacting.
              used: (last?['totalTokens'] as int?) ?? 0,
            ),
          ),
        );
      case 'thread/name/updated':
        if (params != null && params['threadId'] == _threadId) {
          final name = (params['threadName'] ?? params['name']) as String?;
          if (name != null &&
              name.isNotEmpty &&
              !_sentTitles.remove(name) &&
              !_disposed) {
            emit(SessionRenamed(nextSeq, name));
          }
        }
      case 'account/rateLimits/updated':
        if (params != null) {
          _applyRateLimits(params);
        }
      case 'mcpServer/oauthLogin/completed':
        refreshMcpServers();
      case 'serverRequest/resolved':
        if (params != null) {
          final rid = params['requestId'];
          if (rid != null) {
            final approvalKey = 'approval:$rid';
            if (_approvals.remove(approvalKey) != null) {
              emit(InteractionResolved(nextSeq, approvalKey));
            }
            final questionKey = 'question:$rid';
            if (_pendingQuestions.remove(questionKey) != null) {
              emit(InteractionResolved(nextSeq, questionKey));
            }
            _maybeDeferredRelease();
          }
        }
    }
  }

  void _onTransportExit(Map<String, Object?> params) {
    final code = params['code'] as int? ?? -1;
    final stderr = params['stderr'] as String? ?? '';
    final executable = params['executable'] as String?;
    final error = params['error'] as String?;
    final missingBinary = params['missingBinary'] == true;

    _initEpoch++;
    _initialized = false;
    _initializing = null;
    _spawnedSwitches = null;
    _threadResumed = false;
    _serverTurn = null;
    _compactingTurnClientId = null;
    _pendingCompactStarts.clear();
    _compactBoundClientTurns.clear();
    _pendingCompactThreadId = null;
    _pendingCompactWithoutTurnId = 0;
    _lastCompactClientId = null;
    _inFlightCompactStarts.clear();
    _cancelledCompactHandledInReceive.clear();
    _handledCancelledCompactClients.clear();
    _inFlightTurnStarts.clear();
    _ignoredServerTurns.clear();
    _earlyCompletedServerTurns.clear();
    _completedInFlightServerTurns.clear();
    _failPendingResponses(error ?? 'Codex stopped (exit code $code)');

    final friendly = _friendlyFailureMessage(
      stderr.isNotEmpty ? stderr : (error ?? ''),
      code: code,
      missingBinary: missingBinary,
    );
    final detail = _formatFailureDetail(
      stderr,
      executable: executable,
      error: error,
    );

    for (final queued in _turnQueue) {
      emit(ItemRemoved(nextSeq, queued.id));
    }
    _turnQueue.clear();

    if (_turn case final activeTurn?) {
      emit(
        ItemUpserted(
          nextSeq,
          'exit:$activeTurn',
          NoticeItem(NoticeKind.error, friendly),
        ),
      );
      _endTurn(activeTurn, interrupted: true);
    }

    if (!_disposed) {
      _setHealth(
        KernelHealth(
          KernelHealthStatus.failed,
          message: friendly,
          detail: detail,
        ),
      );
    }
  }

  static String _friendlyFailureMessage(
    String raw, {
    int code = -1,
    bool missingBinary = false,
  }) {
    final lower = raw.toLowerCase();
    if (missingBinary ||
        lower.contains('未检测到 codex cli') ||
        lower.contains('was not found')) {
      return 'Codex CLI (codex) was not found. Install Codex and ensure it is on PATH.';
    }
    if (lower.contains('missing optional dependency @openai/codex-win32')) {
      return 'Codex npm installation is missing its Windows native binary (@openai/codex-win32-x64). Reinstall @openai/codex or install the Codex desktop app.';
    }
    if (lower.contains('not logged in') ||
        lower.contains('login') ||
        lower.contains('unauthorized') ||
        lower.contains('api key') ||
        lower.contains('authenticat')) {
      return 'Codex is not logged in. Run `codex login` in a terminal and try again.';
    }
    return code >= 0
        ? 'Codex stopped unexpectedly (exit code $code)'
        : 'Codex failed to start';
  }

  static String? _formatFailureDetail(
    String stderr, {
    String? executable,
    String? error,
  }) {
    final lines = stderr
        .trim()
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .toList();
    final tail = lines.skip(lines.length > 12 ? lines.length - 12 : 0).join('\n');
    final base = tail.isNotEmpty ? tail : (error?.trim() ?? '');
    if (base.isEmpty && executable == null) return null;
    if (executable != null && base.isNotEmpty) {
      return '$base\n\nExecutable: $executable';
    }
    return base.isNotEmpty ? base : 'Executable: $executable';
  }

  void _serverRequest(
    Object? rpcId,
    String method,
    Map<String, Object?> params,
  ) {
    if (method == 'item/tool/requestUserInput') {
      final rawQuestions = params['questions'] as List? ?? const [];
      if (_workspace?.approvesAll == true) {
        _transport.write({
          'id': rpcId,
          'result': {'answers': const <String, Object?>{}},
        });
        return;
      }
      final questionIds = <String>[];
      final mapped = <Question>[];
      for (final raw in rawQuestions) {
        if (raw is! Map) continue;
        final q = raw.cast<String, Object?>();
        final qid = '${q['id'] ?? 'q_${questionIds.length}'}';
        questionIds.add(qid);
        mapped.add(
          Question(
            prompt: '${q['question'] ?? ''}',
            header: '${q['header'] ?? ''}',
            allowMultiple:
                q['isMultiSelect'] == true || q['multiSelect'] == true,
            allowOther: q['isOther'] != false,
            options: [
              for (final opt in q['options'] as List? ?? const [])
                if (opt is Map)
                  QuestionOption(
                    '${opt['label'] ?? ''}',
                    description: '${opt['description'] ?? ''}',
                  ),
            ],
          ),
        );
      }
      final id = 'question:$rpcId';
      _pendingQuestions[id] = (rpcId: rpcId, questionIds: questionIds);
      emit(
        InteractionRequested(
          nextSeq,
          QuestionRequest(
            id: id,
            title: 'Codex has a question',
            questions: mapped,
          ),
        ),
      );
      return;
    }

    if (method != 'item/commandExecution/requestApproval' &&
        method != 'item/fileChange/requestApproval') {
      _transport.write({
        'id': rpcId,
        'error': {
          'code': -32601,
          'message': 'Unsupported server request: $method',
        },
      });
      return;
    }

    if (_workspace?.approvesAll == true) {
      _transport.write({
        'id': rpcId,
        'result': {'decision': 'acceptForSession'},
      });
      return;
    }

    final (title, preview) = switch (method) {
      'item/commandExecution/requestApproval' => (
        'Run command',
        CommandPreview('${params['command'] ?? ''}') as ApprovalPreview?,
      ),
      'item/fileChange/requestApproval' => (
        'Apply changes',
        _fileApprovalPreview(params),
      ),
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

  ApprovalPreview? _fileApprovalPreview(Map<String, Object?> params) {
    final itemId = params['itemId'] as String?;
    final changes =
        (params['changes'] as List?) ??
        ((params['fileChange'] as Map?)?['changes'] as List?) ??
        (itemId == null ? null : _pendingItemChanges[itemId]);

    if (changes != null) {
      for (final raw in changes) {
        if (raw is! Map) continue;
        final path = '${raw['path'] ?? ''}';
        final diff = '${raw['diff'] ?? ''}';
        if (path.isNotEmpty || diff.isNotEmpty) {
          return DiffPreview(path, _parseDiffLines(diff).lines);
        }
      }
    }

    final path = params['path'] as String?;
    final diff = params['diff'] as String?;
    if (path != null || diff != null) {
      return DiffPreview(path ?? '', _parseDiffLines(diff ?? '').lines);
    }

    final grantRoot = params['grantRoot'] as String?;
    final reason = params['reason'] as String?;
    if (grantRoot != null && grantRoot.isNotEmpty) {
      return TextPreview('Grant write access to $grantRoot');
    }
    if (reason != null && reason.isNotEmpty) {
      return TextPreview(reason);
    }
    return null;
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
      case 'mcpToolCall':
        _mcpCalls[id] = item;
        emit(ItemUpserted(nextSeq, id, _mcpToolItem(item, done: false)));
      case 'fileChange':
        if (item['changes'] case final List rawChanges) {
          _pendingItemChanges[id] = [
            for (final c in rawChanges)
              if (c is Map) c.cast<String, Object?>(),
          ];
        }
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
      case 'mcpToolCall':
        _mcpCalls.remove(id);
        emit(ItemUpserted(nextSeq, id, _mcpToolItem(item, done: true)));
      case 'fileChange':
        _pendingItemChanges.remove(id);
        final changes = item['changes'] as List? ?? const [];
        for (final (index, raw) in changes.indexed) {
          if (raw is! Map) continue;
          _fileChange(
            '$id:$index',
            '${raw['path'] ?? ''}',
            '${raw['diff'] ?? ''}',
            kind: (raw['kind'] as Map?)?['type'] as String?,
          );
        }
      case 'contextCompaction':
        emit(ActivityReported(nextSeq, null));
        emit(
          ItemUpserted(
            nextSeq,
            id,
            const NoticeItem(NoticeKind.compaction, 'Conversation compacted'),
          ),
        );
    }
  }

  ToolCallItem _mcpToolItem(Map<String, Object?> item, {required bool done}) {
    final server = item['server'] as String? ?? '';
    final tool = item['tool'] as String? ?? '';
    final canonical = server.isEmpty ? tool : 'mcp__${server}__$tool';
    final sdk = ClaudeSdkTools.called(canonical);
    final args =
        (item['arguments'] as Map?)?.cast<String, Object?>() ??
        const <String, Object?>{};
    final output = _extractMcpOutput(item);
    final statusStr = item['status'] as String?;
    final status = switch (statusStr) {
      'completed' => ToolStatus.succeeded,
      'failed' => ToolStatus.failed,
      _ => done ? ToolStatus.succeeded : ToolStatus.running,
    };
    return ToolCallItem(
      kind: sdk?.kind ?? ToolKind.mcp,
      target: sdk?.summary?.call(args, output) ?? (tool.isNotEmpty ? tool : canonical),
      label: sdk == null ? (server.isNotEmpty ? '$server: $tool' : tool) : null,
      tool: tool,
      callId: item['id'] as String?,
      input: args,
      output: output,
      status: status,
    );
  }

  static String? _extractMcpOutput(Map<String, Object?> item) {
    if (item['error'] case final err?) {
      if (err is Map && err['message'] is String) return err['message'] as String;
      return '$err';
    }
    final result = item['result'];
    if (result is Map) {
      final content = result['content'];
      if (content is List) {
        final texts = <String>[
          for (final block in content)
            if (block is Map && block['type'] == 'text' && block['text'] is String)
              block['text'] as String,
        ];
        if (texts.isNotEmpty) return texts.join('\n');
      }
      if (result['text'] is String) return result['text'] as String;
    }
    return null;
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

  static ({List<DiffLine> lines, int added, int removed}) _parseDiffLines(
    String diff,
  ) {
    final lines = <DiffLine>[];
    var added = 0;
    var removed = 0;
    var oldLine = 1;
    var newLine = 1;
    final hunk = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@');
    for (final line in diff.split('\n')) {
      if (hunk.firstMatch(line) case final match?) {
        oldLine = int.tryParse(match.group(1)!) ?? oldLine;
        newLine = int.tryParse(match.group(2)!) ?? newLine;
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
    return (lines: lines, added: added, removed: removed);
  }

  /// A unified diff as a diff card and a pending change. A file added or
  /// deleted ([kind]) has its whole text for a diff.
  void _fileChange(
    String id,
    String path,
    String diff, {
    String? kind,
    bool emitPendingEdit = true,
  }) {
    final parsed = _parseDiffLines(diff);
    final slash = path.lastIndexOf(RegExp(r'[/\\]'));
    emit(
      ItemUpserted(
        nextSeq,
        id,
        CodeDiffItem(
          fileName: path.substring(slash + 1),
          directory: slash < 0 ? '' : path.substring(0, slash),
          lines: parsed.lines,
        ),
      ),
    );
    if (emitPendingEdit) {
      emit(
        FileEdited(
          nextSeq,
          FileChange(path: path, added: parsed.added, removed: parsed.removed),
          original: switch (kind) {
            'add' => const OriginalText(null),
            'delete' => OriginalText(diff),
            _ => OriginalByPatch(diff),
          },
        ),
      );
    }
  }

  void _endTurn(String turn, {required bool interrupted}) {
    _turn = null;
    _serverTurn = null;
    final wasCompacting = _compactingTurnClientId == turn;
    if (wasCompacting) {
      _compactingTurnClientId = null;
    }
    if (interrupted &&
        wasCompacting &&
        !_compactBoundClientTurns.remove(turn) &&
        _threadId != null) {
      _incrementPendingCompactWithoutTurnId(_threadId);
    }
    if (!interrupted &&
        turn != _lastCompactClientId &&
        _pendingCompactWithoutTurnId > 0 &&
        _pendingCompactThreadId == _threadId &&
        _inFlightTurnStarts.isEmpty) {
      _pendingCompactWithoutTurnId = 0;
      _pendingCompactThreadId = null;
    }
    if (_lastCompactClientId == turn) {
      _lastCompactClientId = null;
    }
    if (!interrupted) {
      _completedTurnCount++;
    }
    emit(ActivityReported(nextSeq, null));
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
    for (final item in [..._mcpCalls.values]) {
      _itemCompleted({...item, 'status': 'failed'});
    }
    for (final id in _approvals.keys) {
      emit(InteractionResolved(nextSeq, id));
    }
    _approvals.clear();
    for (final id in _pendingQuestions.keys) {
      emit(InteractionResolved(nextSeq, id));
    }
    _pendingQuestions.clear();
    _pendingItemChanges.clear();

    final usage = (_turnInputTokens != null || _turnOutputTokens != null)
        ? TurnUsage(
            inputTokens: _turnInputTokens,
            outputTokens: _turnOutputTokens,
          )
        : null;
    _turnInputTokens = null;
    _turnOutputTokens = null;

    emit(
      TurnEnded(
        nextSeq,
        turn,
        interrupted: interrupted,
        worked: switch (_turnStarted) {
          final started? => DateTime.now().difference(started),
          null => null,
        },
        usage: usage,
      ),
    );

    if (_turnQueue.isNotEmpty && !_disposed) {
      final next = _turnQueue.removeAt(0);
      final parsed = parseAgentMessage(next.text);
      _turn = next.id;
      _turnStarted = DateTime.now();
      emit(
        ItemUpserted(
          nextSeq,
          next.id,
          UserMessageItem(
            text: parsed?.text ?? next.text,
            queued: false,
            images: next.images,
            sentAt: DateTime.now(),
            fromAgent: parsed?.from,
            fromSession: parsed?.session,
          ),
        ),
      );
      emit(TurnStarted(nextSeq, next.id));
      unawaited(_dispatchTurn(next));
      return;
    }

    _maybeDeferredRelease();
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
