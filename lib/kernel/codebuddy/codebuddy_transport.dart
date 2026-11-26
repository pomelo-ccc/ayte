import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_agent/bao_agent.dart' show AgentPaths, Shell;
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../bash_exe/bao_bash.dart';
import '../../models/launch_environment.dart';
import '../../network/network_proxy_io.dart';
import '../../network/tls.dart';
import '../../platform/child_process_registry.dart';
import '../../platform/data_dir.dart';
import '../claude_code/claude_code_transport.dart';
import '../claude_code/claude_environment.dart';
import '../claude_code/claude_settings_file.dart';
import 'codebuddy_account_models.dart';
import 'codebuddy_accounts.dart';
import 'codebuddy_catalog.dart';
import 'codebuddy_cli.dart';

/// Starts a session on the CodeBuddy CLI (`codebuddy` / `cbc`).
Future<ClaudeCodeTransport> startCodeBuddy(ClaudeLaunch launch) =>
    CodeBuddyTransport.start(launch);

/// Whether [launch] targets a CodeBuddy CLI model.
bool isCodeBuddyLaunch(ClaudeLaunch launch) =>
    CodeBuddyModels.isCodeBuddyModel(launch.model);

/// Persistent `stream-json` child-process transport for Tencent CodeBuddy Code
/// CLI (`codebuddy -p --input-format stream-json --output-format stream-json`).
class CodeBuddyTransport implements ClaudeCodeTransport {
  CodeBuddyTransport._({
    required this.cli,
    required this.launch,
    CodeBuddyAccounts? accounts,
  }) : _accounts = accounts ?? CodeBuddyAccounts.instance,
       _sessionId = (launch.resume != null && launch.resume!.isNotEmpty)
           ? launch.resume
           : null,
       _model = CodeBuddyModels.cliModelIdOf(launch.model),
       _permissionMode = launch.permissionMode ?? 'default',
       _effort = _resolveInitialEffort(launch.model, launch.effort),
       _maxContextTokens = _resolveInitialContextTokens(
         launch.model,
         launch.autocompact,
       ),
       _paths = AgentPaths.from(cli.environment) {
    _live.add(this);
  }

  /// Creates a [CodeBuddyTransport] directly for unit tests with injectable
  /// [cli] and [accounts] store.
  @visibleForTesting
  factory CodeBuddyTransport.forTesting({
    required CodeBuddyCli cli,
    required ClaudeLaunch launch,
    CodeBuddyAccounts? accounts,
  }) {
    CodeBuddyAccounts.onActiveAccountSwitched ??= _handleActiveAccountSwitched;
    return CodeBuddyTransport._(
      cli: cli,
      launch: launch,
      accounts: accounts,
    );
  }

  @visibleForTesting
  Future<void> spawnForTesting() => _spawnProcess();

  @visibleForTesting
  void simulateProcessExitForTesting(Process proc, int code) =>
      _onProcessExit(proc, code);

  @visibleForTesting
  static Duration? forwardedControlFallbackTimeoutOverride;

  static Duration _fallbackTimeoutFor(String subtype) {
    if (forwardedControlFallbackTimeoutOverride case final override?) {
      return override;
    }
    return switch (subtype) {
      'file_suggestions' => const Duration(seconds: 4),
      'get_hooks_listing' ||
      'stop_task' ||
      'background_tasks' => const Duration(seconds: 6),
      'mcp_status' ||
      'mcp_toggle' ||
      'mcp_reconnect' ||
      'reconnect_mcp' => const Duration(seconds: 12),
      'mcp_authenticate' => const Duration(seconds: 25),
      _ => const Duration(seconds: 8),
    };
  }

  static int _resolveInitialContextTokens(
    String? rawModel,
    int? launchAutocompact,
  ) {
    final info = CodeBuddyModels.of(rawModel);
    if (info != null) {
      return info.resolveContextWindow(launchAutocompact);
    }
    if (launchAutocompact != null && launchAutocompact > 0) {
      return launchAutocompact;
    }
    return 200000;
  }

  static String? _resolveInitialEffort(String? rawModel, String? launchEffort) {
    final info = CodeBuddyModels.of(rawModel);
    if (info == null) return launchEffort;
    if (info.effortLevels.isEmpty) return null;
    if (launchEffort != null && info.effortLevels.contains(launchEffort)) {
      return launchEffort;
    }
    return info.initialEffort;
  }

  @visibleForTesting
  static CodeBuddyProcessRegistry registry = CodeBuddyProcessRegistry(
    file: File(DataDirectory.current.processRegistryFile('codebuddy')),
  );

  static final Set<CodeBuddyTransport> _live = {};
  static final Set<Future<void>> _pendingStops = {};

  static void _trackStop(Future<void> future) {
    if (!_pendingStops.add(future)) return;
    unawaited(
      future.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
        _pendingStops.remove(future);
      }),
    );
  }

  static Future<void> stopAll({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final live = [..._live];
    final pending = <Future<void>>[
      for (final transport in live) transport._stop(timeout),
      for (final stop in [..._pendingStops])
        stop.timeout(timeout, onTimeout: () {}),
    ];
    if (pending.isEmpty && registry.isIdle) return;
    if (pending.isNotEmpty) {
      await Future.wait(pending);
    }
    await registry.flush();
  }

  static Future<void> reapLeftovers() => registry.reaped;

  static Future<void> _handleActiveAccountSwitched(CodeBuddyAccount? _) async {
    for (final transport in [..._live]) {
      transport._markAccountSwitchNeeded();
      if (!transport._turnInFlight) {
        await transport._recycleProcess();
      }
    }
  }

  static Future<ClaudeCodeTransport> start(ClaudeLaunch launch) async {
    await registry.reaped;
    if (!Directory(launch.cwd).existsSync()) {
      throw ClaudeFolderGone(launch.cwd);
    }
    await CodeBuddyAccounts.instance.ensureInitialized();
    CodeBuddyAccounts.onActiveAccountSwitched ??= _handleActiveAccountSwitched;
    final cli = await LocalCodeBuddy.locate();
    final transport = CodeBuddyTransport._(cli: cli, launch: launch);
    await transport._startInitialProcess();
    return transport;
  }

  final CodeBuddyCli cli;
  final ClaudeLaunch launch;
  final CodeBuddyAccounts _accounts;
  final AgentPaths _paths;

  final StreamController<Map<String, Object?>> _messages =
      StreamController.broadcast();
  final Completer<void> _exited = Completer<void>();

  Process? _process;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  String? _settingsFilePath;

  String? _sessionId;
  String _model;
  String? _cliDefaultModel;
  String _permissionMode;
  String? _pendingPermissionMode;
  String? _effort;
  String? _pendingThoughtLevel;
  final Set<String> _sessionApprovedTools = {};
  int _maxContextTokens;
  int _lastContextTokens = 0;
  double _turnCreditsReported = 0.0;
  int _turnTokensReported = 0;
  bool _turnInFlight = false;
  bool _hasSentTurnOnProcess = false;
  bool _suppressingResumeReplay = false;
  bool _needsAccountRespawn = false;
  int _accountSwitchEpoch = 0;
  bool _closed = false;
  bool _recycling = false;
  Future<void>? _initialSpawnFuture;
  Future<void>? _recyclingFuture;
  Future<void>? _spawningFuture;
  Future<void>? _closeCleanupFuture;
  final Set<Future<void>> _pendingCleanupFutures = {};
  final List<Map<String, Object?>> _queuedWritesDuringRecycle = [];
  String? _pendingCustomTitle;
  Map<String, Object?>? _lastInitializeRequest;

  final List<String> _stderr = [];
  static const int _maxStderrLines = 30;
  final Set<String> _initializeRequestIds = {};
  final Set<String> _internalControlIds = {};
  final List<String> _pendingClientUserUuids = [];
  final Map<String, String> _clientToCliUserUuid = {};
  final Map<
    String,
    ({
      String origReqId,
      Map<String, Object?> origMessage,
      Timer fallbackTimer,
    })
  > _pendingModelFetches = {};
  final Map<String, ({String subtype, Timer fallbackTimer})>
  _pendingControlRequests = {};
  int _internalSeq = 0;

  @visibleForTesting
  int get pendingControlRequestCountForTesting => _pendingControlRequests.length;

  @visibleForTesting
  String? get settingsFilePathForTesting => _settingsFilePath;

  void _cancelPendingModelFetches() {
    for (final entry in _pendingModelFetches.values) {
      entry.fallbackTimer.cancel();
    }
    _pendingModelFetches.clear();
  }

  void _cancelPendingControlRequests() {
    for (final entry in _pendingControlRequests.values) {
      entry.fallbackTimer.cancel();
    }
    _pendingControlRequests.clear();
  }

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  @override
  Future<void> get exited => _exited.future;

  static const _cliEffortTiers = {
    'minimal',
    'low',
    'medium',
    'high',
    'xhigh',
    'max',
  };

  /// Maps Cyte's effort value (`none`, `enabled`, `low`..`max`) to WorkBuddy's
  /// `thoughtLevel` (`disabled`, `enabled`, `low`..`max`).
  static String _toThoughtLevel(String effort) => switch (effort) {
    'none' || 'disabled' => 'disabled',
    'enabled' => 'enabled',
    'minimal' => 'low',
    _ => effort,
  };

  /// Builds CLI arguments compatible with `@tencent-ai/codebuddy-code` (`cbc`).
  @visibleForTesting
  static List<String> buildArguments({
    required ClaudeLaunch launch,
    required String model,
    required String permissionMode,
    required String? effort,
    required int maxContextTokens,
    required String? resumeSessionId,
    required String? settingsFilePath,
    required Map<String, Object?> inlineSettings,
  }) {
    final clampedAutocompact = maxContextTokens.clamp(100000, 1000000);
    final bash = BaoBash.cliEnvironment(Platform.environment);
    final told = BaoBash.givesBaoBash(bash) && !launch.ownPrompt
        ? [
            Shell.baoBashNote,
            if (launch.instructions case final own? when own.isNotEmpty) own,
          ].join('\n\n')
        : launch.instructions;

    final cliEffort =
        (effort != null && _cliEffortTiers.contains(effort)) ? effort : null;

    return [
      '-p',
      '--input-format',
      'stream-json',
      '--output-format',
      'stream-json',
      '--verbose',
      '--include-partial-messages',
      '--replay-user-messages',
      if (permissionMode == 'bypassPermissions') '-y',
      '--permission-mode',
      permissionMode,
      if (!CodeBuddyModels.isPlaceholderModel(model)) ...['--model', model],
      if (cliEffort != null) ...['--effort', cliEffort],
      '--autocompact',
      '$clampedAutocompact',
      if (resumeSessionId != null && resumeSessionId.isNotEmpty) ...[
        '--resume',
        resumeSessionId,
      ],
      for (final directory in launch.directories) ...['--add-dir', directory],
      if (settingsFilePath != null) ...[
        '--settings',
        settingsFilePath,
      ] else if (inlineSettings.isNotEmpty) ...[
        '--settings',
        jsonEncode(inlineSettings),
      ],
      if (!launch.persist) '--no-session-persistence',
      if (launch.tools case final tools?) ...[
        '--tools',
        tools.join(','),
        if (!launch.userServers) '--strict-mcp-config',
      ],
      if (launch.sdkServers.isNotEmpty) ...[
        '--mcp-config',
        jsonEncode({
          'mcpServers': {
            for (final name in launch.sdkServers)
              name: {'type': 'sdk', 'name': name},
          },
        }),
        '--allowedTools',
        launch.sdkServers.map((name) => 'mcp__$name').join(','),
      ],
      if (launch.ownPrompt) ...[
        '--system-prompt',
        told ?? '',
      ] else ...[
        '--append-system-prompt',
        switch (told) {
          final text? when text.isNotEmpty =>
            '${ClaudeLaunch.appendedSystemPrompt}\n\n$text',
          _ => ClaudeLaunch.appendedSystemPrompt,
        },
      ],
    ];
  }

  void _markAccountSwitchNeeded() {
    _needsAccountRespawn = true;
    _accountSwitchEpoch++;
  }

  Future<void> _startInitialProcess() {
    final completer = Completer<void>();
    final initial = completer.future;
    _initialSpawnFuture = initial;
    return () async {
      try {
        await _spawnProcess();
        while (!_closed && _needsAccountRespawn) {
          _recycling = true;
          try {
            await _killProcessForRespawn();
          } finally {
            _recycling = false;
          }
          if (_closed) break;
          await _spawnProcess();
        }
      } finally {
        if (identical(_initialSpawnFuture, initial)) {
          _initialSpawnFuture = null;
        }
        if (!completer.isCompleted) {
          completer.complete();
        }
      }
    }();
  }

  Future<void> _trackCleanup(Future<void> future) {
    _pendingCleanupFutures.add(future);
    return future.whenComplete(() {
      _pendingCleanupFutures.remove(future);
    });
  }

  Future<void> _spawnProcess() {
    if (_closed) return Future.value();
    final future = _spawnProcessImpl();
    _spawningFuture = future;
    return future.whenComplete(() {
      if (identical(_spawningFuture, future)) {
        _spawningFuture = null;
      }
    });
  }

  Future<void> _spawnProcessImpl() async {
    if (_closed) return;
    final spawnEpoch = _accountSwitchEpoch;
    var activeAccount = _accounts.currentAccount;
    final spawnAccountId = activeAccount?.id;
    if (activeAccount != null) {
      activeAccount = await _accounts.ensureFreshAccount(
        activeAccount,
      );
      if (_closed) return;
    }

    final accountEnv = activeAccount?.processEnvironment() ?? const {};
    final settingsMap = <String, Object?>{
      ...launch.settings,
      if (_effort == 'none' || _effort == 'disabled')
        'alwaysThinkingEnabled': false,
      if (activeAccount != null &&
          (activeAccount.region == CodeBuddyRegion.cloudhosted ||
              activeAccount.region == CodeBuddyRegion.selfhosted))
        'endpoint': activeAccount.endpoint,
    };
    if (_effort != null && (_sessionId == null || _sessionId!.isEmpty)) {
      _pendingThoughtLevel = _toThoughtLevel(_effort!);
    }
    final hasSecrets =
        launch.hasSecrets ||
        accountEnv.containsKey('CODEBUDDY_AUTH_TOKEN') ||
        accountEnv.containsKey('CODEBUDDY_API_KEY');

    String? settingsFile;
    if (hasSecrets) {
      if (_closed) return;
      final filePayload = <String, Object?>{
        ...settingsMap,
        'env': <String, Object?>{
          if (settingsMap['env'] case final Map existing)
            ...existing.cast<String, Object?>(),
          ...accountEnv,
        },
      };
      settingsFile = await ClaudeSettingsFile.write(filePayload);
      if (_closed) {
        await ClaudeSettingsFile.delete(settingsFile);
        return;
      }
      _settingsFilePath = settingsFile;
    }

    Future<void> cleanupAbortedSettings() async {
      if (settingsFile != null) {
        await ClaudeSettingsFile.delete(settingsFile);
        if (_settingsFilePath == settingsFile) {
          _settingsFilePath = null;
        }
      }
    }

    final proxy = await NetworkProxy.instance.environment();
    if (_closed) {
      await cleanupAbortedSettings();
      return;
    }
    final certificates = await nodeCertificatesEnvironment(cli.environment);
    if (_closed) {
      await cleanupAbortedSettings();
      return;
    }
    final bash = BaoBash.cliEnvironment({
      ...Platform.environment,
      ...cli.environment,
    });

    final args = buildArguments(
      launch: launch,
      model: _model,
      permissionMode: _permissionMode,
      effort: _effort,
      maxContextTokens: _maxContextTokens,
      resumeSessionId: _sessionId,
      settingsFilePath: settingsFile,
      inlineSettings: settingsMap,
    );

    if (_closed) {
      await cleanupAbortedSettings();
      return;
    }

    try {
      final proc = await Process.start(
        cli.executable,
        args,
        workingDirectory: launch.cwd,
        environment: {
          ...cli.environment,
          ...proxy,
          ...certificates,
          ...bash,
          if (launch.env != null)
            for (final name in ClaudeModelVariables.inherited) name: '',
          // Enables session-level `thoughtLevel` & `contextWindow` in `set_config`,
          // matching WorkBuddy's ConversationEngine subprocess environment.
          'CBC_SESSION_CONFIG_SYNC': '1',
          ...accountEnv,
          ...ClaudeEnvironment.stateDirectory(cli.environment),
        },
        includeParentEnvironment: Platform.isWindows,
        runInShell: cli.throughShell,
      );
      if (_closed) {
        unawaited(proc.stdin.close().catchError((Object _) {}));
        if (Platform.isWindows) {
          await _trackCleanup(_endTree(proc));
        } else {
          proc.kill();
          await proc.exitCode
              .timeout(
                const Duration(seconds: 1),
                onTimeout: () {
                  proc.kill(ProcessSignal.sigkill);
                  return -1;
                },
              )
              .catchError((Object _) => -1);
        }
        await cleanupAbortedSettings();
        return;
      }
      _process = proc;
      _hasSentTurnOnProcess = false;
      _suppressingResumeReplay = false;
      if (_accountSwitchEpoch == spawnEpoch &&
          _accounts.currentAccount?.id == spawnAccountId) {
        _needsAccountRespawn = false;
      }
      unawaited(registry.add(proc.pid));

      _stdoutSub = proc.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(
            _onStdoutLine,
            onError: (Object e) => _onStderrLine('$e'),
          );
      _stderrSub = proc.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(
            _onStderrLine,
            onError: (Object e) => _onStderrLine('$e'),
          );
      unawaited(proc.exitCode.then((code) => _onProcessExit(proc, code)));
    } on ProcessException catch (error) {
      if (settingsFile != null) {
        await ClaudeSettingsFile.delete(settingsFile);
        _settingsFilePath = null;
      }
      throw ClaudeUnavailable(
        'CodeBuddy CLI 启动失败',
        detail: '${cli.executable}\n${error.message}',
      );
    }
  }

  Future<void> _killProcessForRespawn() async {
    _cancelPendingModelFetches();
    _cancelPendingControlRequests();
    _internalControlIds.clear();
    final old = _process;
    _process = null;
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
    if (_settingsFilePath case final path?) {
      _settingsFilePath = null;
      unawaited(_trackCleanup(ClaudeSettingsFile.delete(path)));
    }
    if (old != null) {
      unawaited(registry.remove(old.pid));
      await _trackCleanup(_endTree(old, immediate: true));
      unawaited(old.stdin.close().catchError((Object _) {}));
      await old.exitCode.timeout(
        const Duration(seconds: 2),
        onTimeout: () {
          old.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    }
  }

  Future<void> _recycleProcess() {
    if (_closed) return Future.value();
    if (_initialSpawnFuture case final initial?) return initial;
    if (_recyclingFuture case final active?) return active;
    _recycling = true;
    late final Future<void> future;
    future = () async {
      var failed = false;
      try {
        do {
          await _killProcessForRespawn();
          if (_closed) return;
          await _spawnProcess();
          if (_closed) return;
        } while (_needsAccountRespawn);
        if (_lastInitializeRequest case final prevInit?) {
          final reinitId = '_cyte_reinit_${++_internalSeq}';
          _internalControlIds.add(reinitId);
          _writeRaw({
            'type': 'control_request',
            'request_id': reinitId,
            'request': {
              'subtype': 'initialize',
              'hasPrompt': true,
              if (prevInit['sdkMcpServers'] != null)
                'sdkMcpServers': prevInit['sdkMcpServers'],
              if (prevInit['capabilities'] != null)
                'capabilities': prevInit['capabilities'],
            },
          });
        }
      } on Object catch (error) {
        failed = true;
        _failQueuedWritesAfterRecycleError(error);
      } finally {
        _recycling = false;
        if (identical(_recyclingFuture, future)) {
          _recyclingFuture = null;
        }
      }
      if (!failed) {
        _drainQueuedWritesAfterRecycle();
      }
    }();
    _recyclingFuture = future;
    return future;
  }

  void _failQueuedWritesAfterRecycleError(Object error) {
    _turnInFlight = false;
    final queued = [..._queuedWritesDuringRecycle];
    _queuedWritesDuringRecycle.clear();
    if (_closed || _messages.isClosed) return;
    for (final msg in queued) {
      if (msg['type'] == 'user') {
        _messages.add({
          'type': 'result',
          'subtype': 'error',
          'is_error': true,
          'result': 'CodeBuddy 进程重启失败：$error',
        });
      }
    }
  }

  void _drainQueuedWritesAfterRecycle() {
    while (!_closed && _queuedWritesDuringRecycle.isNotEmpty) {
      if (_recyclingFuture != null) return;
      final next = _queuedWritesDuringRecycle.first;
      if (next['type'] == 'user' && _needsAccountRespawn) {
        unawaited(_recycleProcess());
        return;
      }
      _queuedWritesDuringRecycle.removeAt(0);
      _dispatchWrite(next);
    }
  }

  void _flushPendingSessionThoughtLevel(String sid) {
    final pending = _pendingThoughtLevel;
    if (pending == null || pending.isEmpty) return;
    final info = CodeBuddyModels.of(_model);
    if (pending == 'disabled' && (info?.onlyReasoning ?? false)) {
      _pendingThoughtLevel = null;
      return;
    }
    _pendingThoughtLevel = null;
    final internalId = '_cyte_thought_${++_internalSeq}';
    _internalControlIds.add(internalId);
    _writeRaw({
      'type': 'control_request',
      'request_id': internalId,
      'request': {
        'subtype': 'set_config',
        'session_id': sid,
        'config': {'thoughtLevel': pending},
      },
    });
  }

  void _flushPendingSessionPermissionMode(String sid) {
    final pending = _pendingPermissionMode;
    if (pending == null || pending.isEmpty) return;
    _pendingPermissionMode = null;
    final internalId = '_cyte_perm_mode_${++_internalSeq}';
    _internalControlIds.add(internalId);
    _writeRaw({
      'type': 'control_request',
      'request_id': internalId,
      'request': {
        'subtype': 'set_permission_mode',
        'session_id': sid,
        'mode': pending,
      },
    });
  }

  void _onStdoutLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;
    Map<String, Object?> decoded;
    try {
      final raw = jsonDecode(trimmed);
      if (raw is! Map) {
        _onStderrLine(line);
        return;
      }
      decoded = raw.cast<String, Object?>();
    } on FormatException {
      _onStderrLine(line);
      return;
    }

    if (decoded['session_id'] case final String sid when sid.isNotEmpty) {
      final wasEmpty = _sessionId == null || _sessionId!.isEmpty;
      _sessionId = sid;
      if (wasEmpty || _pendingThoughtLevel != null) {
        _flushPendingSessionThoughtLevel(sid);
      }
      if (wasEmpty || _pendingPermissionMode != null) {
        _flushPendingSessionPermissionMode(sid);
      }
      if (_pendingCustomTitle case final title?) {
        _pendingCustomTitle = null;
        _appendCustomTitleToTranscript(sid, title);
      }
    }

    final type = decoded['type'] as String?;
    if (type == 'control_response') {
      final handled = _handleControlResponse(decoded);
      if (handled == null) return;
      decoded = handled;
      if (!_closed && !_messages.isClosed) {
        _messages.add(decoded);
      }
      return;
    }
    if (type == 'control_request') {
      final normalized = _normalizeIncomingControlRequest(decoded);
      if (normalized != null && !_closed && !_messages.isClosed) {
        _messages.add(normalized);
      }
      return;
    }

    // Defense-in-depth: suppress any startup `renderHistory()` burst emitted by
    // `codebuddy --resume` before a live user turn is sent on this process.
    if (_suppressingResumeReplay) {
      if (type == 'result') {
        _suppressingResumeReplay = false;
      }
      return;
    }
    if (type == 'system' &&
        decoded['subtype'] == 'init' &&
        decoded['model'] == 'unknown' &&
        (decoded['tools'] as List?)?.isEmpty == true) {
      _suppressingResumeReplay = true;
      return;
    }
    if (!_hasSentTurnOnProcess &&
        _sessionId != null &&
        _sessionId!.isNotEmpty &&
        (type == 'user' ||
            type == 'assistant' ||
            type == 'stream_event' ||
            type == 'file-history-snapshot' ||
            type == 'ai-title' ||
            type == 'topic' ||
            type == 'result' ||
            (type == 'system' && decoded['subtype'] == 'usage_update'))) {
      return;
    }

    if (type == 'user') {
      final reconciled = _reconcileUserEcho(decoded);
      if (reconciled == null) return;
      decoded = reconciled;
    } else if (type == 'assistant') {
      _observeAssistantUsage(decoded);
    } else if (type == 'system' && decoded['subtype'] == 'usage_update') {
      _observeTurnUsageUpdate(decoded);
    } else if (type == 'result') {
      decoded = _onTurnResult(decoded);
    }

    if (!_closed && !_messages.isClosed) {
      _messages.add(decoded);
    }
  }

  Map<String, Object?>? _handleControlResponse(Map<String, Object?> message) {
    final resp = (message['response'] as Map?)?.cast<String, Object?>();
    if (resp == null) return message;
    final reqId = resp['request_id'] as String?;
    if (reqId == null) return message;

    // 1. Swallow responses to internal fire-and-forget control requests.
    if (_internalControlIds.remove(reqId)) {
      return null;
    }

    // 2. Complete deferred `initialize` once `get_available_models` returns `rawModels`.
    if (_pendingModelFetches.remove(reqId) case final pending?) {
      pending.fallbackTimer.cancel();
      if (resp['subtype'] == 'success') {
        final modelsPayload =
            (resp['response'] as Map?)?.cast<String, Object?>() ?? const {};
        final rawList = modelsPayload['rawModels'] ?? modelsPayload['models'];
        if (rawList is List) {
          final maps = [
            for (final m in rawList)
              if (m is Map) m.cast<String, Object?>(),
          ];
          CodeBuddyModels.updateFromCliModels(maps);
        }
      }
      return _buildNormalizedInitResponse(pending.origMessage);
    }

    // 3. Intercept `initialize`: parse stub models & CLI account, then query
    // `get_available_models` so `rawModels` (`reasoning.supportedEfforts`,
    // `onlyReasoning`, `credits`) are populated before kernel finishes init!
    if (_initializeRequestIds.remove(reqId)) {
      if (resp['subtype'] != 'success') return message;
      final payload =
          (resp['response'] as Map?)?.cast<String, Object?>() ?? const {};
      if (payload['currentModelId'] case final String cur
          when !CodeBuddyModels.isPlaceholderModel(cur)) {
        _cliDefaultModel = cur;
      }
      if (payload['account'] case final Map rawAcc) {
        unawaited(
          _accounts.syncFromCliInitializeAccount(
            rawAcc.cast<String, Object?>(),
          ),
        );
      }
      if (payload['models'] case final List rawModels) {
        final maps = [
          for (final m in rawModels)
            if (m is Map) m.cast<String, Object?>(),
        ];
        CodeBuddyModels.updateFromCliModels(maps);
      }

      final fetchId = '_cyte_models_${++_internalSeq}';
      final timer = Timer(const Duration(milliseconds: 350), () {
        if (_pendingModelFetches.remove(fetchId) case final timedOut?) {
          if (!_closed && !_messages.isClosed) {
            _messages.add(_buildNormalizedInitResponse(timedOut.origMessage));
          }
        }
      });
      _pendingModelFetches[fetchId] = (
        origReqId: reqId,
        origMessage: message,
        fallbackTimer: timer,
      );
      _writeRaw({
        'type': 'control_request',
        'request_id': fetchId,
        'request': const {'subtype': 'get_available_models'},
      });
      return null;
    }

    // 4. Cancel any timeout fallback timer for forwarded client control requests
    // and pass both `success` and `error` responses through untouched.
    _pendingControlRequests.remove(reqId)?.fallbackTimer.cancel();
    return message;
  }

  Map<String, Object?> _buildNormalizedInitResponse(
    Map<String, Object?> origMessage,
  ) {
    final resp =
        (origMessage['response'] as Map?)?.cast<String, Object?>() ?? const {};
    final payload =
        (resp['response'] as Map?)?.cast<String, Object?>() ?? const {};
    final activeAccount = _accounts.currentAccount;
    final rawCommands = payload['commands'];
    final hasCommands = rawCommands is List && rawCommands.isNotEmpty;
    final normalizedPayload = <String, Object?>{
      ...payload,
      if (!hasCommands) 'commands': codebuddyBuiltinCommands,
      'account': {
        'subscriptionType': activeAccount != null
            ? 'CodeBuddy (${activeAccount.region.shortBadge} · ${activeAccount.edition.label})'
            : 'CodeBuddy CLI',
      },
      'models': [
        for (final m in CodeBuddyModels.current)
          {
            'value': m.id,
            'displayName': m.label,
            'description': m.description,
            'supportsEffort': m.effortLevels.isNotEmpty,
            'supportedEffortLevels': m.effortLevels,
            'supportsAutoMode': true,
          },
      ],
    };
    return {
      ...origMessage,
      'response': {
        ...resp,
        'response': normalizedPayload,
      },
    };
  }

  /// Reconciles echoed user messages (`--replay-user-messages`) emitted by
  /// `codebuddy` (`isReplay: true`, carrying a newly generated UUIDv7) back to
  /// the client's original `turn.id` UUID, preventing duplicate user bubbles in
  /// `ChatSession` while keeping tool_result and subagent messages untouched.
  Map<String, Object?>? _reconcileUserEcho(Map<String, Object?> decoded) {
    if (decoded['parent_tool_use_id'] != null ||
        decoded['isMeta'] == true ||
        decoded['isSynthetic'] == true ||
        decoded['isCompactSummary'] == true ||
        decoded['isVisibleInTranscriptOnly'] == true) {
      return decoded;
    }

    final body = decoded['message'];
    var hasVisiblePrompt = false;
    if (body is Map) {
      final content = body['content'];
      if (content is List) {
        final hasToolResult = content.any(
          (b) => b is Map && b['type'] == 'tool_result',
        );
        if (hasToolResult) return decoded;
        final visibleTexts = <String>[];
        var hasImage = false;
        for (final b in content) {
          if (b is! Map) continue;
          final bType = b['type'];
          if (bType == 'image') {
            hasImage = true;
          } else if (bType == 'text' && b['text'] is String) {
            final t = (b['text'] as String).trimLeft();
            if (t.isEmpty ||
                t.startsWith('<system-reminder>') ||
                t.startsWith('<local-command-caveat>')) {
              continue;
            }
            visibleTexts.add(t);
          }
        }
        final textJoined = visibleTexts.join('\n');
        if (textJoined.startsWith('<task-notification>') ||
            textJoined.startsWith('[Request interrupted')) {
          return decoded;
        }
        hasVisiblePrompt = visibleTexts.isNotEmpty || hasImage;
      } else if (content is String) {
        final trimmed = content.trimLeft();
        if (trimmed.startsWith('<task-notification>') ||
            trimmed.startsWith('[Request interrupted')) {
          return decoded;
        }
        hasVisiblePrompt =
            trimmed.isNotEmpty &&
            !trimmed.startsWith('<system-reminder>') &&
            !trimmed.startsWith('<local-command-caveat>');
      }
    }

    if (!hasVisiblePrompt) {
      return decoded;
    }

    final cliUuid = decoded['uuid'] as String?;
    if (cliUuid != null && _pendingClientUserUuids.remove(cliUuid)) {
      if (!_closed && !_messages.isClosed) {
        _messages.add({
          'type': 'command_lifecycle',
          'command_uuid': cliUuid,
          'state': 'started',
        });
      }
      return decoded;
    }

    if (_pendingClientUserUuids.isNotEmpty) {
      final clientUuid = _pendingClientUserUuids.removeAt(0);
      if (cliUuid != null && cliUuid.isNotEmpty) {
        _clientToCliUserUuid[clientUuid] = cliUuid;
      }
      if (!_closed && !_messages.isClosed) {
        _messages.add({
          'type': 'command_lifecycle',
          'command_uuid': clientUuid,
          'state': 'started',
        });
      }
      return {...decoded, 'uuid': clientUuid};
    }

    if (decoded['isReplay'] == true) {
      return null;
    }

    return decoded;
  }

  void _observeAssistantUsage(Map<String, Object?> decoded) {
    final msg = decoded['message'];
    if (msg is! Map) return;
    final usage = msg['usage'];
    if (usage is! Map) return;
    final input = (usage['input_tokens'] as num?)?.toInt() ?? 0;
    final cacheRead = (usage['cache_read_input_tokens'] as num?)?.toInt() ?? 0;
    final cacheCreate =
        (usage['cache_creation_input_tokens'] as num?)?.toInt() ?? 0;
    final output = (usage['output_tokens'] as num?)?.toInt() ?? 0;
    final total = input + cacheRead + cacheCreate + output;
    if (total > 0) {
      _lastContextTokens = total;
    }
  }

  void _observeTurnUsageUpdate(Map<String, Object?> decoded) {
    final meta = decoded['_meta'];
    if (meta is! Map) return;
    final snapshot = meta['codebuddy.ai/turnUsage'];
    if (snapshot is! Map) return;
    final total = snapshot['total'];
    if (total is! Map) return;
    final rawCredits = total['credits'];
    final parsedCredits = switch (rawCredits) {
      final num c => c.toDouble(),
      final String s => double.tryParse(s.trim()),
      _ => null,
    };
    if (parsedCredits != null && parsedCredits > 0) {
      _turnCreditsReported = parsedCredits;
    }
    if (total['usage'] case final Map u) {
      final inp =
          ((u['inputTokens'] ?? u['input_tokens']) as num?)?.toInt() ?? 0;
      final out =
          ((u['outputTokens'] ?? u['output_tokens']) as num?)?.toInt() ?? 0;
      final cr =
          ((u['cacheReadInputTokens'] ?? u['cache_read_input_tokens']) as num?)
              ?.toInt() ??
          0;
      final cc =
          ((u['cacheCreationInputTokens'] ?? u['cache_creation_input_tokens'])
                  as num?)
              ?.toInt() ??
          0;
      _turnTokensReported = inp + out + cr + cc;
      if (_turnTokensReported > 0) {
        _lastContextTokens = _turnTokensReported;
      }
    }
  }

  Map<String, Object?> _onTurnResult(Map<String, Object?> decoded) {
    _turnInFlight = false;
    final isError = decoded['is_error'] == true;
    final resultText = '${decoded['result'] ?? ''}'.toLowerCase();
    final quotaExhausted =
        isError &&
        (resultText.contains('insufficient_quota') ||
            resultText.contains('quota exceeded') ||
            resultText.contains('quota exhausted') ||
            resultText.contains('credit balance is too low') ||
            resultText.contains('余额不足') ||
            resultText.contains('已欠费') ||
            resultText.contains('6005') ||
            resultText.contains('14018'));

    var resultTokens = 0;
    if (decoded['usage'] case final Map u) {
      final inp =
          ((u['input_tokens'] ?? u['inputTokens']) as num?)?.toInt() ?? 0;
      final out =
          ((u['output_tokens'] ?? u['outputTokens']) as num?)?.toInt() ?? 0;
      final cr =
          ((u['cache_read_input_tokens'] ?? u['cacheReadInputTokens']) as num?)
              ?.toInt() ??
          0;
      final cc =
          ((u['cache_creation_input_tokens'] ?? u['cacheCreationInputTokens'])
                  as num?)
              ?.toInt() ??
          0;
      resultTokens = inp + out + cr + cc;
      if (resultTokens > 0 && _turnTokensReported <= 0) {
        _lastContextTokens = resultTokens;
      }
    }
    final tokens = _turnTokensReported > 0 ? _turnTokensReported : resultTokens;
    final turnCredits = _turnCreditsReported;

    unawaited(
      _accounts.recordTurnUsage(
        credits: turnCredits,
        tokens: tokens,
        quotaExhausted: quotaExhausted,
      ),
    );
    _turnCreditsReported = 0.0;
    _turnTokensReported = 0;

    if (_needsAccountRespawn && !_closed) {
      unawaited(_recycleProcess());
    }

    if (turnCredits > 0) {
      return {...decoded, 'credits': turnCredits};
    }
    return decoded;
  }

  void _onStderrLine(String line) {
    _stderr.add(line);
    if (_stderr.length > _maxStderrLines) {
      _stderr.removeAt(0);
    }
  }

  void _onProcessExit(Process proc, int code) {
    unawaited(registry.remove(proc.pid));
    if ((_recycling && !_closed) || _process != proc) return;
    _process = null;
    _cancelPendingModelFetches();
    _cancelPendingControlRequests();
    _internalControlIds.clear();
    if (_settingsFilePath case final path?) {
      _settingsFilePath = null;
      unawaited(_trackCleanup(ClaudeSettingsFile.delete(path)));
    }
    _live.remove(this);
    if (!_messages.isClosed) {
      _messages
        ..add(
          ClaudeExit.message(
            code,
            _stderr.join('\n'),
            executable: cli.executable,
          ),
        )
        ..close();
    }
    if (_closeCleanupFuture == null && !_exited.isCompleted) {
      _exited.complete();
    }
  }

  /// Normalizes incoming CLI `control_request`s (`can_use_tool` &
  /// `elicitation_create`) to match `ClaudeCodeKernel`'s interaction protocol,
  /// and auto-approves tools the user marked "Always allow" for this session.
  Map<String, Object?>? _normalizeIncomingControlRequest(
    Map<String, Object?> decoded,
  ) {
    final reqId = decoded['request_id'] as String?;
    final req = (decoded['request'] as Map?)?.cast<String, Object?>();
    if (reqId == null || req == null) return decoded;
    final subtype = req['subtype'] as String?;

    if (subtype == 'elicitation_create') {
      return {
        ...decoded,
        'request': {
          ...req,
          'subtype': 'elicitation',
        },
      };
    }

    if (subtype == 'can_use_tool') {
      final toolName = req['tool_name'] as String?;
      final input = (req['input'] as Map?)?.cast<String, Object?>() ?? const {};
      if (toolName != null &&
          toolName != 'AskUserQuestion' &&
          toolName != 'ExitPlanMode' &&
          _sessionApprovedTools.contains(toolName)) {
        _writeRaw({
          'type': 'control_response',
          'response': {
            'subtype': 'success',
            'request_id': reqId,
            'response': {
              'allowed': true,
              'behavior': 'allow',
              'updatedInput': input,
            },
          },
        });
        return null;
      }

      if (toolName != null &&
          toolName != 'AskUserQuestion' &&
          toolName != 'ExitPlanMode' &&
          (req['permission_suggestions'] as List? ?? const []).isEmpty) {
        return {
          ...decoded,
          'request': {
            ...req,
            'permission_suggestions': [
              {
                'type': 'addRules',
                'behavior': 'allow',
                'destination': 'session',
                'rules': [
                  {'toolName': toolName},
                ],
              },
            ],
          },
        };
      }
    }

    return decoded;
  }

  /// Translates `ClaudeCodeKernel`'s `can_use_tool` response (`behavior:
  /// 'allow' | 'deny'`, `message`) into `@tencent-ai/codebuddy-code`'s
  /// `SdkPermissionClient` schema (`allowed: true | false`, `reason`), and
  /// records session-level "Always allow" rules (`updatedPermissions`).
  Map<String, Object?> _translateOutgoingControlResponse(
    Map<String, Object?> message,
  ) {
    final resp = (message['response'] as Map?)?.cast<String, Object?>();
    if (resp == null || resp['subtype'] != 'success') return message;
    final inner = (resp['response'] as Map?)?.cast<String, Object?>();
    if (inner == null) return message;
    final behavior = inner['behavior'] as String?;
    if (behavior == null) return message;

    if (behavior == 'allow') {
      if (inner['updatedPermissions'] case final List perms) {
        for (final entry in perms) {
          if (entry is! Map) continue;
          if (entry['type'] == 'setMode' &&
              entry['mode'] == 'bypassPermissions') {
            _permissionMode = 'bypassPermissions';
          }
          if (entry['rules'] case final List rules) {
            for (final r in rules) {
              if (r is Map && r['toolName'] is String) {
                final name = (r['toolName'] as String).trim();
                if (name.isNotEmpty) _sessionApprovedTools.add(name);
              }
            }
          }
        }
      }
      return {
        ...message,
        'response': {
          ...resp,
          'response': {
            ...inner,
            'allowed': true,
          },
        },
      };
    }

    if (behavior == 'deny') {
      final reason =
          (inner['reason'] as String?) ??
          (inner['message'] as String?) ??
          'Permission denied by user';
      return {
        ...message,
        'response': {
          ...resp,
          'response': {
            ...inner,
            'allowed': false,
            'reason': reason,
          },
        },
      };
    }

    return message;
  }

  @override
  void write(Map<String, Object?> message) {
    if (_closed) return;
    final type = message['type'] as String?;
    if (_recyclingFuture != null || (type == 'user' && _needsAccountRespawn)) {
      _queuedWritesDuringRecycle.add(message);
      if (_recyclingFuture == null) {
        unawaited(_recycleProcess());
      }
      return;
    }
    _dispatchWrite(message);
  }

  void _dispatchWrite(Map<String, Object?> message) {
    if (_closed) return;
    final type = message['type'] as String?;
    if (type == 'control_request') {
      _handleControlRequest(message);
      return;
    }
    if (type == 'control_response') {
      _writeRaw(_translateOutgoingControlResponse(message));
      return;
    }
    if (type == 'user') {
      if (message['uuid'] case final String clientUuid
          when clientUuid.isNotEmpty) {
        _pendingClientUserUuids.add(clientUuid);
      }
      _turnInFlight = true;
      _turnCreditsReported = 0.0;
      _turnTokensReported = 0;
      _hasSentTurnOnProcess = true;
    }
    _writeRaw(message);
  }

  void _handleControlRequest(Map<String, Object?> message) {
    final requestId = message['request_id'] as String?;
    final request = (message['request'] as Map?)?.cast<String, Object?>();
    if (requestId == null || request == null) return;
    final subtype = request['subtype'] as String? ?? '';

    void respondSuccess([Map<String, Object?> payload = const {}]) {
      if (_closed || _messages.isClosed) return;
      _messages.add({
        'type': 'control_response',
        'response': {
          'subtype': 'success',
          'request_id': requestId,
          'response': payload,
        },
      });
    }

    switch (subtype) {
      case 'initialize':
        _lastInitializeRequest = request;
        _initializeRequestIds.add(requestId);
        _writeRaw({
          'type': 'control_request',
          'request_id': requestId,
          'request': {
            'subtype': 'initialize',
            'hasPrompt': true,
            if (request['sdkMcpServers'] != null)
              'sdkMcpServers': request['sdkMcpServers'],
            if (request['capabilities'] != null)
              'capabilities': request['capabilities'],
          },
        });
      case 'set_permission_mode':
        if (request['mode'] case final String mode when mode.isNotEmpty) {
          _permissionMode = mode;
          if (_sessionId case final sid? when sid.isNotEmpty) {
            _pendingPermissionMode = null;
            _writeRaw({
              'type': 'control_request',
              'request_id': requestId,
              'request': {
                'subtype': 'set_permission_mode',
                'session_id': sid,
                'mode': mode,
              },
            });
          } else {
            _pendingPermissionMode = mode;
            respondSuccess({'mode': mode});
          }
          return;
        }
        respondSuccess();
      case 'set_model':
        if (request['model'] case final String rawModel) {
          final previousModel = _model;
          _model = CodeBuddyModels.cliModelIdOf(rawModel);
          final info = CodeBuddyModels.of(rawModel);
          if (info != null) {
            _maxContextTokens = info.resolveContextWindow(_maxContextTokens);
            if (info.effortLevels.isEmpty) {
              _effort = null;
              _pendingThoughtLevel = null;
            } else if (_effort == null ||
                !info.effortLevels.contains(_effort)) {
              _effort = info.initialEffort;
            }
          }
          // Before the first turn, codebuddy has no active session yet and
          // rejects `set_model` without a `session_id` ("Session not found:
          // current"). Recycle the idle pre-warmed process with the new
          // `--model` instead so the very first turn uses the selected model.
          if (_sessionId == null || _sessionId!.isEmpty) {
            if (_process != null &&
                !_hasSentTurnOnProcess &&
                _model != previousModel) {
              unawaited(_recycleProcess());
            }
            respondSuccess({'model': _model});
            return;
          }
          final effectiveModel = CodeBuddyModels.isPlaceholderModel(_model)
              ? (_cliDefaultModel ?? CodeBuddyModels.firstConcreteCliModel())
              : _model;
          if (effectiveModel == null ||
              CodeBuddyModels.isPlaceholderModel(effectiveModel)) {
            respondSuccess({'model': _model});
            return;
          }
          _writeRaw({
            'type': 'control_request',
            'request_id': requestId,
            'request': {
              'subtype': 'set_model',
              'session_id': _sessionId,
              'model': effectiveModel,
            },
          });
          return;
        }
        respondSuccess();
      case 'apply_flag_settings':
        if (request['settings'] case final Map settings) {
          final configUpdates = <String, Object?>{};
          final info = CodeBuddyModels.of(_model);
          final hasSession = _sessionId != null && _sessionId!.isNotEmpty;

          if (settings['effortLevel'] case final String rawEffort
              when rawEffort.isNotEmpty) {
            _effort = rawEffort;
            final thoughtLevel = _toThoughtLevel(rawEffort);
            final disallowedDisable =
                thoughtLevel == 'disabled' && (info?.onlyReasoning ?? false);
            if (!disallowedDisable) {
              if (thoughtLevel == 'disabled') {
                configUpdates['alwaysThinkingEnabled'] = false;
              } else {
                configUpdates['alwaysThinkingEnabled'] = true;
                if (_cliEffortTiers.contains(thoughtLevel)) {
                  configUpdates['reasoningEffort'] = thoughtLevel;
                }
              }
              if (hasSession) {
                configUpdates['thoughtLevel'] = thoughtLevel;
                _pendingThoughtLevel = null;
              } else {
                _pendingThoughtLevel = thoughtLevel;
              }
            }
          }

          if (settings['contextWindow'] case final num tokens
              when tokens.toInt() > 0) {
            _maxContextTokens = tokens.toInt();
            // With CBC_SESSION_CONFIG_SYNC=1, `set_config.contextWindow` is only
            // valid for models advertising >= 2 supported context lengths.
            if (info == null || info.contextOptions.length >= 2) {
              configUpdates['contextWindow'] = _maxContextTokens;
            }
          }

          if (configUpdates.isNotEmpty) {
            _writeRaw({
              'type': 'control_request',
              'request_id': requestId,
              'request': {
                'subtype': 'set_config',
                if (hasSession) 'session_id': _sessionId,
                'config': configUpdates,
              },
            });
            return;
          }
        }
        respondSuccess();
      case 'rewind':
      case 'rewind_conversation':
        final mappedTarget = switch (request['target_message_uuid']) {
          final String id => _clientToCliUserUuid[id] ?? id,
          _ => null,
        };
        _writeRaw({
          ...message,
          'request': {
            ...request,
            'target_message_uuid': ?mappedTarget,
          },
        });
      case 'rewind_files':
        final mappedUserMsg = switch (request['user_message_id']) {
          final String id => _clientToCliUserUuid[id] ?? id,
          _ => null,
        };
        _writeRaw({
          ...message,
          'request': {
            ...request,
            'user_message_id': ?mappedUserMsg,
          },
        });
      case 'interrupt':
      case 'mcp_message':
      case 'steer':
        _writeRaw(message);
      case 'mcp_status':
        _forwardWithFallback(
          message,
          requestId,
          subtype,
          const {'mcpServers': <Object?>[]},
        );
      case 'mcp_toggle':
      case 'mcp_reconnect':
      case 'reconnect_mcp':
      case 'mcp_authenticate':
      case 'stop_task':
      case 'background_tasks':
        _forwardWithFallback(
          message,
          requestId,
          subtype,
          const <String, Object?>{},
        );
      case 'file_suggestions':
        _forwardWithFallback(
          message,
          requestId,
          subtype,
          const {'suggestions': <Object?>[]},
        );
      case 'get_hooks_listing':
        _forwardWithFallback(
          message,
          requestId,
          subtype,
          const {'hooks': <Object?>[]},
        );
      case 'get_settings':
        respondSuccess({
          'applied': {
            'model': CodeBuddyModels.bareModelId(_model),
            if (_effort != null) 'effort': _effort,
            'contextWindow': _maxContextTokens,
          },
        });
      case 'get_context_usage':
        respondSuccess({
          'maxTokens': _maxContextTokens,
          'rawMaxTokens': _maxContextTokens,
          'totalTokens': _lastContextTokens,
          'categories': [
            {
              'name': 'Messages & Tools',
              'tokens': _lastContextTokens,
              'color': 'blue',
            },
          ],
        });
      case 'rename_session':
        if (request['title'] case final String title
            when title.trim().isNotEmpty) {
          final trimmed = title.trim();
          if (_sessionId case final sid? when sid.isNotEmpty) {
            _appendCustomTitleToTranscript(sid, trimmed);
          } else {
            _pendingCustomTitle = trimmed;
          }
        }
        respondSuccess();
      case 'cancel_async_message':
        if (request['message_uuid'] case final String u) {
          _pendingClientUserUuids.remove(u);
        }
        respondSuccess(const {'cancelled': true});
      case 'get_usage':
        unawaited(_handleGetUsage(requestId));
      default:
        respondSuccess();
    }
  }

  void _forwardWithFallback(
    Map<String, Object?> message,
    String requestId,
    String subtype,
    Map<String, Object?> fallbackPayload,
  ) {
    _pendingControlRequests.remove(requestId)?.fallbackTimer.cancel();
    final timer = Timer(_fallbackTimeoutFor(subtype), () {
      final removed = _pendingControlRequests.remove(requestId);
      if (removed == null || _closed || _messages.isClosed) return;
      _messages.add({
        'type': 'control_response',
        'response': {
          'subtype': 'success',
          'request_id': requestId,
          'response': fallbackPayload,
        },
      });
    });
    _pendingControlRequests[requestId] = (
      subtype: subtype,
      fallbackTimer: timer,
    );
    _writeRaw(message);
  }

  Future<void> _handleGetUsage(String requestId) async {
    try {
      await _accounts.ensureInitialized();
    } on Object {
      // Fall back to whatever accounts are already loaded in memory.
    }
    if (_closed || _messages.isClosed) return;
    final payload = buildUsagePayload(_accounts.currentAccount);
    _messages.add({
      'type': 'control_response',
      'response': {
        'subtype': 'success',
        'request_id': requestId,
        'response': payload,
      },
    });
  }

  @visibleForTesting
  static Map<String, Object?> buildUsagePayload(CodeBuddyAccount? account) {
    final quota = account?.quota;
    if (account == null || quota == null) {
      return const {'rate_limits_available': false};
    }
    final activePackages = [
      for (final pkg in quota.packages)
        if (pkg.total > 0) pkg,
    ];
    final hasCreditTotals =
        quota.totalCredits != null && quota.totalCredits! > 0;
    if (activePackages.isEmpty &&
        !hasCreditTotals &&
        !quota.unlimited &&
        !quota.quotaExhausted) {
      return const {'rate_limits_available': false};
    }

    final windows = <Map<String, Object?>>[];
    if (activePackages.isNotEmpty) {
      for (final pkg in activePackages) {
        final remainFraction = (pkg.remain / pkg.total).clamp(0.0, 1.0);
        final usedPct = ((1.0 - remainFraction) * 100.0).clamp(0.0, 100.0);
        final resetsAt = _normalizeResetIso(pkg.expireTime ?? quota.resetTime);
        windows.add({
          'label': pkg.displayTitle,
          'utilization': usedPct,
          'resets_at': ?resetsAt,
        });
      }
    } else {
      final usedPct = quota.unlimited
          ? 0.0
          : quota.quotaExhausted
          ? 100.0
          : ((1.0 - quota.remainingFraction) * 100.0).clamp(0.0, 100.0);
      final pkgName = quota.subscriptionPackageName?.trim();
      final label = (pkgName != null && pkgName.isNotEmpty)
          ? pkgName
          : 'CodeBuddy ${account.edition.label}';
      final resetsAt = _normalizeResetIso(quota.resetTime);
      windows.add({
        'label': label,
        'utilization': usedPct,
        'resets_at': ?resetsAt,
      });
    }

    return {
      'rate_limits_available': true,
      'subscription_type':
          'CodeBuddy (${account.region.shortBadge} · ${account.edition.label})',
      'rate_limits': {'windows': windows},
    };
  }

  static String? _normalizeResetIso(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    var parsed = DateTime.tryParse(trimmed);
    if (parsed == null) {
      final normalized = trimmed.replaceFirst(' ', 'T');
      parsed = DateTime.tryParse(normalized);
    }
    return parsed?.toUtc().toIso8601String();
  }

  void _appendCustomTitleToTranscript(String sessionId, String title) {
    if (!launch.persist) return;
    try {
      final nativeFile = CodeBuddyCatalog.findNativeSessionFile(
        sessionId,
        paths: _paths,
      );
      final targetPath = nativeFile?.path ?? _paths.findSession(sessionId);
      if (targetPath == null) return;
      final file = File(targetPath);
      if (!file.parent.existsSync()) {
        file.parent.createSync(recursive: true);
      }
      file.writeAsStringSync(
        '${jsonEncode({'type': 'custom-title', 'customTitle': title, 'sessionId': sessionId})}\n',
        mode: FileMode.append,
      );
    } on Object {
      // Best-effort custom title append.
    }
  }

  void _writeRaw(Map<String, Object?> message) {
    final proc = _process;
    if (proc == null || _closed) return;
    try {
      proc.stdin.writeln(jsonEncode(message));
    } on Object {
      // Closed under us; exit event follows.
    }
  }

  Future<void> _stop(Duration timeout) async {
    close();
    try {
      await exited.timeout(timeout);
    } on TimeoutException {
      _process?.kill(ProcessSignal.sigkill);
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _queuedWritesDuringRecycle.clear();
    _live.remove(this);
    _cancelPendingModelFetches();
    _cancelPendingControlRequests();
    _internalControlIds.clear();
    final proc = _process;
    final hasPendingWork =
        proc != null ||
        _spawningFuture != null ||
        _initialSpawnFuture != null ||
        _recyclingFuture != null ||
        _pendingCleanupFutures.isNotEmpty ||
        _settingsFilePath != null;
    if (!hasPendingWork) {
      if (!_messages.isClosed) {
        unawaited(_messages.close());
      }
      if (!_exited.isCompleted) {
        _exited.complete();
      }
      return;
    }
    if (proc != null) {
      unawaited(_trackCleanup(_endTree(proc, immediate: true)));
      unawaited(proc.stdin.close().catchError((Object _) {}));
    }
    final closeFuture = _closeCleanupFuture ??= _finalizeClose();
    _trackStop(closeFuture);
  }

  Future<void> _finalizeClose() async {
    try {
      while (true) {
        final pending = <Future<void>>[
          ?_spawningFuture,
          ?_initialSpawnFuture,
          ?_recyclingFuture,
          ..._pendingCleanupFutures,
        ];
        if (pending.isEmpty) break;
        for (final f in pending) {
          try {
            await f;
          } on Object {
            // Ignore spawn/cleanup failures during close; finalization completes.
          }
        }
      }

      final proc = _process;
      if (proc != null) {
        try {
          await proc.exitCode.timeout(
            const Duration(seconds: 2),
            onTimeout: () {
              proc.kill(ProcessSignal.sigkill);
              return -1;
            },
          );
        } on Object {
          // Proceed to cleanup if exitCode fails.
        }
        if (identical(_process, proc)) {
          _process = null;
        }
      }

      await _stdoutSub?.cancel();
      await _stderrSub?.cancel();
      _stdoutSub = null;
      _stderrSub = null;

      while (_pendingCleanupFutures.isNotEmpty) {
        for (final f in [..._pendingCleanupFutures]) {
          try {
            await f;
          } on Object {
            // Best-effort drain for cleanup futures triggered on process exit.
          }
        }
      }

      if (_settingsFilePath case final path?) {
        _settingsFilePath = null;
        await ClaudeSettingsFile.delete(path);
      }
    } finally {
      _live.remove(this);
      if (!_messages.isClosed) {
        await _messages.close();
      }
      if (!_exited.isCompleted) {
        _exited.complete();
      }
    }
  }

  Future<void> _endTree(Process proc, {bool immediate = false}) async {
    if (!immediate) {
      final ended = await proc.exitCode
          .timeout(const Duration(seconds: 1))
          .then((_) => true, onError: (Object _) => false);
      if (ended) return;
    }
    if (Platform.isWindows) {
      try {
        await Process.run('taskkill', ['/pid', '${proc.pid}', '/T', '/F']);
      } on ProcessException {
        proc.kill();
      }
      return;
    }
    final descendants = await _posixDescendantPids(proc.pid);
    for (final childPid in descendants.reversed) {
      Process.killPid(childPid);
    }
    proc.kill();
    final deadline = DateTime.now().add(const Duration(milliseconds: 500));
    while (DateTime.now().isBefore(deadline)) {
      if (!Process.killPid(proc.pid, ProcessSignal.sigcont) &&
          !descendants.any((p) => Process.killPid(p, ProcessSignal.sigcont))) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    for (final childPid in descendants.reversed) {
      Process.killPid(childPid, ProcessSignal.sigkill);
    }
    proc.kill(ProcessSignal.sigkill);
  }

  static Future<List<int>> _posixDescendantPids(int rootPid) async {
    final result = <int>[];
    final visited = <int>{rootPid};
    final queue = <int>[rootPid];
    while (queue.isNotEmpty) {
      final parent = queue.removeAt(0);
      try {
        final out = await Process.run('pgrep', ['-P', '$parent']);
        if (out.exitCode != 0) continue;
        for (final line in LineSplitter.split('${out.stdout}')) {
          final child = int.tryParse(line.trim());
          if (child != null && visited.add(child)) {
            result.add(child);
            queue.add(child);
          }
        }
      } on ProcessException {
        return result;
      }
    }
    return result;
  }
}

class CodeBuddyProcessRegistry extends ChildProcessRegistry {
  CodeBuddyProcessRegistry({
    required super.file,
    super.ownPid,
    super.lookup,
    super.signal,
  }) : super(recognizes: _isCodeBuddy);

  static bool _isCodeBuddy(String command) =>
      (command.contains('codebuddy') || command.contains('cbc')) &&
      command.contains('stream-json');
}
