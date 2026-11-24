import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:bao_agent/bao_agent.dart' show AgentPaths, agentVersion;
import 'package:bao_remote/local.dart'
    show ideIndexExcludedDirectories, walkUnignored;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import '../../customize/customization_store.dart';
import '../../customize/customizations.dart';
import '../../customize/mcp_probe.dart';
import '../../customize/mcp_probe_io.dart' show probeMcpServer;
import '../../ide/ide_fuzzy.dart' show ideFuzzyMatch;
import '../../network/network_proxy_io.dart';
import '../../platform/data_dir.dart';
import '../claude_code/claude_code_translator.dart' show ClaudeTranslator;
import '../claude_code/claude_code_transport.dart';
import '../claude_code/claude_sdk_tools.dart';
import '../claude_code/sdk_mcp_http_bridge.dart';
import '../commit_attribution.dart';
import '../extension_switches.dart';
import '../kernel_types.dart'
    show
        ApprovalDecision,
        ApprovalRequest,
        CommandPreview,
        DiffPreview,
        TextPreview;
import 'antigravity_account_models.dart';
import 'antigravity_accounts.dart';
import 'antigravity_cli.dart';
import 'antigravity_commands.dart';

/// Starts a session on the Antigravity CLI (`agy`).
Future<ClaudeCodeTransport> startAntigravity(ClaudeLaunch launch) =>
    AntigravityTransport.start(launch);

/// Whether [launch] explicitly targets an Antigravity CLI model.
bool isAntigravityLaunch(ClaudeLaunch launch) =>
    AntigravityModels.isAntigravityModel(launch.model);

/// Adapts the Antigravity CLI (`agy --input-format stream-json
/// --output-format stream-json`) to [ClaudeCodeTransport].
///
/// Key design points:
/// 1. **Persistent Multi-Turn Process**: Keeps a single `agy` process alive
///    across turns (`stdin` stays open, one NDJSON user message per line),
///    preserving background tasks (`IsDaemon: true`), subagents, and avoiding
///    the 4–7s silent-auth cold start on subsequent turns.
/// 2. **Permission Mode Mapping**: Maps `permissionMode` to `--mode`
///    (`accept-edits`, `auto`, `plan`) and passes `--dangerously-skip-permissions`
///    when `bypassPermissions` is selected or when `plan` mode runs with
///    `autoApproveInPlan` (`useAutoModeDuringPlan`), while bridging interactive
///    SDK tool confirmations (`can_use_tool`) and edit hooks over the control
///    stream.
/// 3. **JSON Parameter Unquoting**: Unwraps JSON-encoded string values in
///    `tool_info.parameters` (`"\"/path\""` → `"/path"`, `"100"` → `100`).
/// 4. **Session Persistence**: Mirrors every user/assistant/tool message to
///    `~/.claude/projects/<project>/<sessionId>.jsonl` so Antigravity CLI
///    sessions appear in the sidebar, support Session Replay, and reload
///    their full transcript across app restarts.
class AntigravityTransport implements ClaudeCodeTransport {
  AntigravityTransport._({
    required this.executable,
    required this.environment,
    required this.launch,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       _sessionId = (launch.resume != null && launch.resume!.isNotEmpty)
           ? launch.resume
           : null,
       _model = AntigravityModels.cliModelIdOf(launch.model),
       _permissionMode = launch.permissionMode ?? 'default',
       _autoModeDuringPlan =
           launch.autoModeDuringPlan ??
           (launch.permissionMode == 'bypassPermissions' ||
               launch.permissionMode == 'auto'),
       _effort = _resolveInitialEffort(launch.model, launch.effort),
       _maxContextTokens = _resolveInitialContextTokens(
         launch.model,
         launch.autocompact,
       ),
       _disabledSkills = {...launch.switches.disabledSkills},
       _switches = launch.switches,
       _paths = AgentPaths.from(environment) {
    _live.add(this);
    _initSessionState();
  }

  /// Creates an [AntigravityTransport] directly for unit tests with a custom
  /// [executable] and injectable clock [now].
  @visibleForTesting
  factory AntigravityTransport.forTesting({
    required String executable,
    Map<String, String> environment = const {},
    required ClaudeLaunch launch,
    DateTime Function()? now,
  }) => AntigravityTransport._(
    executable: executable,
    environment: environment,
    launch: launch,
    now: now,
  );

  static int _resolveInitialContextTokens(
    String? rawModel,
    int? launchAutocompact,
  ) {
    final info = AntigravityModels.of(rawModel);
    if (info != null) {
      return info.resolveContextWindow(launchAutocompact);
    }
    if (launchAutocompact != null && launchAutocompact > 0) {
      return launchAutocompact;
    }
    return 256000;
  }

  static String? _resolveInitialEffort(String? rawModel, String? launchEffort) {
    final parsed = AntigravityModels.parseVariant(rawModel);
    if (parsed == null) return launchEffort;
    final info = parsed.model;
    if (info.effortLevels.isEmpty) return null;
    if (launchEffort != null && info.effortLevels.contains(launchEffort)) {
      return launchEffort;
    }
    return parsed.effort ?? info.defaultEffort;
  }

  static final Set<AntigravityTransport> _live = {};
  static final Set<Future<void>> _pendingStops = {};

  static Future<void> stopAll() async {
    final live = [..._live];
    for (final transport in live) {
      transport.close();
    }
    final pendingStops = [..._pendingStops];
    final pending = <Future<void>>[
      for (final t in live)
        if (!t._exited.isCompleted)
          t.exited.timeout(const Duration(seconds: 5), onTimeout: () {}),
      for (final stop in pendingStops)
        stop.timeout(const Duration(seconds: 5), onTimeout: () {}),
    ];
    if (pending.isEmpty) return;
    await Future.wait(pending);
  }

  static Future<ClaudeCodeTransport> start(ClaudeLaunch launch) async {
    if (!Directory(launch.cwd).existsSync()) {
      throw ClaudeFolderGone(launch.cwd);
    }
    unawaited(AntigravityAccounts.instance.ensureInitialized());
    AntigravityAccounts.onActiveAccountSwitched ??= (_) async {
      for (final transport in [..._live]) {
        transport._needsAccountRespawn = true;
        if (transport._activeTurn == null) {
          await transport._stopProcess(notifyActiveTurn: false);
        }
      }
    };
    final cli = await LocalAntigravity.locate();
    final proxy = await NetworkProxy.instance.environment();
    return AntigravityTransport._(
      executable: cli.executable,
      environment: {...cli.environment, ...proxy},
      launch: launch,
    );
  }

  final String executable;
  final Map<String, String> environment;
  final ClaudeLaunch launch;
  final AgentPaths _paths;
  final DateTime Function() _now;

  /// Elapsed wall-clock milliseconds for a single Q&A turn started at [startedAt].
  int _elapsedTurnMs(DateTime startedAt) =>
      math.max(0, _now().difference(startedAt).inMilliseconds);

  final StreamController<Map<String, Object?>> _messages =
      StreamController.broadcast();
  final Completer<void> _exited = Completer<void>();

  /// The session ID known to Ayte / `.claude/projects`.
  String? _sessionId;

  /// The conversation ID known to `agy` (`~/.gemini/antigravity-cli/conversations`).
  String? _agyConversationId;

  _AntigravitySessionLog? _sessionLog;
  String? _pendingCustomTitle;
  bool _needsHistorySeed = false;

  String _model;
  String _permissionMode;
  bool _autoModeDuringPlan;
  String? _effort;
  int _maxContextTokens;
  Set<String> _disabledSkills;
  ExtensionSwitches _switches;
  bool _closed = false;

  /// Loopback Streamable-HTTP MCP bridge for `ClaudeSdkTools` (`baocode`).
  AyteSdkMcpBridge? _sdkBridge;

  /// Per-session isolated `--add-dir` holding `.agents/mcp_config.json` and `AGENTS.md`.
  Directory? _sessionConfigDir;

  /// Completed whenever the active turn is interrupted or closed.
  Completer<void> _sdkTurnCancelled = Completer<void>();

  /// Current Ayte turn UUID (`userMessage['uuid']`) for Turn-1 caller correlation.
  String? _activeTurnUuid;

  int _askSeq = 0;
  final Map<String, Completer<ApprovalDecision?>> _pendingAsks = {};
  int _hookSeq = 0;
  final Map<String, Completer<void>> _pendingHookCallbacks = {};
  final Map<String, List<({RegExp? matcher, List<String> callbackIds})>>
  _registeredHooks = {};
  final Map<String, McpProbeResult> _mcpProbeCache = {};
  Directory? _tempImageRootDir;
  Directory? _tempImageDir;
  final Map<String, Directory> _tempImageDirs = {};
  final Set<Future<void>> _inFlightImageWrites = {};
  final Set<Directory> _pendingSessionConfigDirs = {};
  final Set<Future<void>> _inFlightSpawns = {};
  final Set<Future<void>> _pendingCleanups = {};
  Future<void>? _closeCleanupFuture;
  static int _imgDirSeq = 0;
  int _imgSeq = 0;
  ({DateTime cachedAt, List<String> entries})? _fileIndexCache;
  Future<List<String>>? _fileIndexInFlight;
  static int _configSeq = 0;

  @visibleForTesting
  Directory? get sessionConfigDirForTesting => _sessionConfigDir;

  @visibleForTesting
  AyteSdkMcpBridge? get sdkBridgeForTesting => _sdkBridge;

  @visibleForTesting
  Future<void> prepareSessionArtifactsForTesting() => _ensureBridgeAndConfig();

  @visibleForTesting
  Future<void> stopProcessForTesting({bool notifyActiveTurn = false}) =>
      _stopProcess(notifyActiveTurn: notifyActiveTurn);

  /// Persistent `agy` process kept alive across turns.
  Process? _process;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  String? _spawnedModel;
  String? _spawnedModeFlag;
  String? _spawnedEffort;
  int? _spawnedContextTokens;
  String? _spawnedSettingsJson;
  _ActiveTurn? _activeTurn;
  final Set<int> _completedToolSteps = {};

  bool _interrupted = false;
  bool _needsAccountRespawn = false;
  int _turnCounter = 0;
  int _lastContextTokens = 0;

  /// FIFO queue of user turns waiting to execute sequentially.
  final List<({String? uuid, Map<String, Object?> message})> _pendingTurns = [];
  bool _drainingTurns = false;

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  @override
  Future<void> get exited => _exited.future;

  void _initSessionState() {
    final id = _sessionId;
    if (id == null || id.isEmpty) return;

    final hasAgyConv = _hasAntigravityConversation(id);
    if (hasAgyConv) {
      _agyConversationId = id;
      if (launch.persist) {
        syncAntigravityTranscriptIfNeeded(
          cwd: launch.cwd,
          sessionId: id,
          paths: _paths,
          model: _model,
        );
      }
    } else {
      // Switching an existing Claude Code session to Antigravity CLI:
      // keep Ayte's `_sessionId` intact and seed prior context on turn 1.
      _agyConversationId = null;
      _needsHistorySeed = true;
    }

    if (launch.persist) {
      _sessionLog = _AntigravitySessionLog(
        paths: _paths,
        cwd: launch.cwd,
        sessionId: id,
        persist: launch.persist,
      );
    }

    final seeded =
        readBrainContextTokens(id, home: _paths.home)?.contextTokens ??
        _sessionLog?.readLastContextTokens();
    if (seeded != null && seeded > 0) {
      _lastContextTokens = seeded;
    }
  }

  bool _hasAntigravityConversation(String id) {
    final home = _paths.home;
    final convDir = p.join(home, '.gemini', 'antigravity-cli', 'conversations');
    if (File(p.join(convDir, '$id.db')).existsSync() ||
        File(p.join(convDir, '$id.pb')).existsSync()) {
      return true;
    }
    final brainTranscript = p.join(
      home,
      '.gemini',
      'antigravity-cli',
      'brain',
      id,
      '.system_generated',
      'logs',
      'transcript.jsonl',
    );
    return File(brainTranscript).existsSync();
  }

  void _bindConversationId(String convId) {
    if (convId.isEmpty) return;
    _agyConversationId = convId;
    if (_sessionId == null || _sessionId!.isEmpty) {
      _sessionId = convId;
      _emit({
        'type': 'system',
        'subtype': 'init',
        'session_id': convId,
        'model': _model,
        if (_effort != null) 'effort': _effort,
      });
    }
    _sdkBridge?.updateSessionId(_sessionId);
    if (_sessionLog == null && launch.persist && _sessionId != null) {
      _sessionLog = _AntigravitySessionLog(
        paths: _paths,
        cwd: launch.cwd,
        sessionId: _sessionId!,
        persist: launch.persist,
      );
      if (_pendingCustomTitle case final title?) {
        _pendingCustomTitle = null;
        _sessionLog!.noteTitle(title);
      }
    }
  }

  void _emit(Map<String, Object?> message) {
    if (!_closed && !_messages.isClosed) {
      _messages.add(message);
    }
  }

  @override
  void write(Map<String, Object?> message) {
    if (_closed) return;
    switch (message['type']) {
      case 'control_request':
        _handleControlRequest(message);
      case 'control_response':
        _handleControlResponse(message);
      case 'user':
        final uuid = switch (message['uuid']) {
          final String id when id.isNotEmpty => id,
          _ => null,
        };
        _pendingTurns.add((uuid: uuid, message: message));
        if (!_drainingTurns) {
          unawaited(_drainTurnQueue());
        }
    }
  }

  void _handleControlResponse(Map<String, Object?> message) {
    final response = message['response'];
    if (response is! Map) return;
    final reqId = response['request_id'] as String?;
    if (reqId == null) return;
    final hookCompleter = _pendingHookCallbacks.remove(reqId);
    if (hookCompleter != null) {
      if (!hookCompleter.isCompleted) {
        hookCompleter.complete();
      }
      return;
    }
    final completer = _pendingAsks.remove(reqId);
    if (completer == null || completer.isCompleted) return;
    if (response['subtype'] != 'success') {
      completer.complete(null);
      return;
    }
    final payload = response['response'];
    if (payload is! Map) {
      completer.complete(ApprovalDecision.deny);
      return;
    }
    if (payload['behavior'] == 'allow') {
      final updated = payload['updatedPermissions'];
      completer.complete(
        updated is List && updated.isNotEmpty
            ? ApprovalDecision.allowAlways
            : ApprovalDecision.allowOnce,
      );
    } else {
      completer.complete(ApprovalDecision.deny);
    }
  }

  Future<ApprovalDecision?> _askViaControlChannel(ApprovalRequest request) {
    if (_closed) return Future.value();
    final reqId = 'agy-ask-${++_askSeq}';
    final completer = Completer<ApprovalDecision?>();
    _pendingAsks[reqId] = completer;

    final sdkTool = ClaudeSdkTools.called(request.toolName);
    final toolName = (sdkTool?.asksItself ?? false)
        ? (request.preview is CommandPreview
              ? 'Bash'
              : request.toolName.replaceFirst(
                  'mcp__${ClaudeSdkTools.server}__',
                  '',
                ))
        : request.toolName;

    final input = switch (request.preview) {
      CommandPreview(:final command, :final description) => <String, Object?>{
        'command': command,
        'description': ?description,
      },
      DiffPreview(:final path) => <String, Object?>{'file_path': path},
      TextPreview(:final text) => <String, Object?>{'text': text},
      null => const <String, Object?>{},
    };

    _emit({
      'type': 'control_request',
      'request_id': reqId,
      'request': {
        'subtype': 'can_use_tool',
        'tool_name': toolName,
        'display_name': request.title,
        if (request.preview case CommandPreview(:final description?))
          'description': description,
        'decision_reason': ?request.reason,
        'requires_user_interaction': true,
        'input': input,
        if (request.alwaysAllowLabel case final label?)
          'permission_suggestions': [
            {
              'type': 'addRules',
              'rules': [
                {'toolName': request.toolName, 'ruleContent': label},
              ],
            },
          ],
      },
    });

    return completer.future;
  }

  void _cancelSdkCalls() {
    if (!_sdkTurnCancelled.isCompleted) {
      _sdkTurnCancelled.complete();
    }
    _sdkTurnCancelled = Completer<void>();
    if (_pendingAsks.isNotEmpty) {
      for (final MapEntry(key: reqId, value: completer)
          in [..._pendingAsks.entries]) {
        _pendingAsks.remove(reqId);
        if (!completer.isCompleted) {
          completer.complete(null);
        }
        _emit({
          'type': 'control_cancel_request',
          'request_id': reqId,
        });
      }
    }
  }

  void _cancelHookCallbacks() {
    _activeTurn?.cancelHooks();
    if (_pendingHookCallbacks.isEmpty) return;
    for (final MapEntry(key: reqId, value: completer)
        in [..._pendingHookCallbacks.entries]) {
      _pendingHookCallbacks.remove(reqId);
      if (!completer.isCompleted) {
        completer.complete();
      }
    }
  }

  void _parseInitializeHooks(Object? rawHooks) {
    _registeredHooks.clear();
    if (rawHooks is! Map) return;
    for (final MapEntry(:key, :value) in rawHooks.entries) {
      if (key is! String || key.isEmpty || value is! List) continue;
      final rules = <({RegExp? matcher, List<String> callbackIds})>[];
      for (final rawRule in value) {
        if (rawRule is! Map) continue;
        final rawIds = rawRule['hookCallbackIds'];
        if (rawIds is! List) continue;
        final callbackIds = [
          for (final id in rawIds)
            if (id is String && id.isNotEmpty) id,
        ];
        if (callbackIds.isEmpty) continue;
        RegExp? regex;
        if (rawRule['matcher'] case final String pattern
            when pattern.trim().isNotEmpty) {
          try {
            regex = RegExp('^(?:$pattern)\$');
          } on FormatException {
            regex = null;
          }
        }
        rules.add((matcher: regex, callbackIds: callbackIds));
      }
      if (rules.isNotEmpty) {
        _registeredHooks[key] = rules;
      }
    }
  }

  List<String> _matchingHookCallbackIds(String hookEvent, String toolName) {
    final rules = _registeredHooks[hookEvent];
    if (rules == null || rules.isEmpty) return const [];
    final ids = <String>[];
    for (final rule in rules) {
      if (rule.matcher == null || rule.matcher!.hasMatch(toolName)) {
        ids.addAll(rule.callbackIds);
      }
    }
    return ids;
  }

  Future<void> _dispatchEditHooks(
    String hookEvent, {
    required String toolName,
    required Map<String, Object?> toolInput,
    String? toolUseId,
    bool Function()? isCancelled,
  }) async {
    if (_closed || _interrupted || (isCancelled?.call() ?? false)) return;
    final callbackIds = _matchingHookCallbackIds(hookEvent, toolName);
    if (callbackIds.isEmpty) return;
    for (final callbackId in callbackIds) {
      if (_closed || _interrupted || (isCancelled?.call() ?? false)) return;
      final reqId = 'agy-hook-${++_hookSeq}';
      final completer = Completer<void>();
      _pendingHookCallbacks[reqId] = completer;
      _emit({
        'type': 'control_request',
        'request_id': reqId,
        'request': {
          'subtype': 'hook_callback',
          'callback_id': callbackId,
          'input': {
            'hook_event_name': hookEvent,
            'tool_name': toolName,
            'tool_input': toolInput,
            'tool_use_id': ?toolUseId,
          },
        },
      });
      await completer.future.timeout(
        const Duration(seconds: 12),
        onTimeout: () {
          _pendingHookCallbacks.remove(reqId);
        },
      );
      if (_closed || _interrupted || (isCancelled?.call() ?? false)) return;
    }
  }

  static const Set<String> _validPermissionModes = {
    'default',
    'acceptEdits',
    'auto',
    'dontAsk',
    'plan',
    'bypassPermissions',
  };

  void _handleControlRequest(Map<String, Object?> message) {
    final requestId = message['request_id'] as String?;
    final request = (message['request'] as Map?)?.cast<String, Object?>();
    if (requestId == null || request == null) return;
    final subtype = request['subtype'] as String? ?? '';

    void respondSuccess([Map<String, Object?> payload = const {}]) {
      _emit({
        'type': 'control_response',
        'response': {
          'subtype': 'success',
          'request_id': requestId,
          'response': payload,
        },
      });
    }

    void respondError(String error) {
      _emit({
        'type': 'control_response',
        'response': {
          'subtype': 'error',
          'request_id': requestId,
          'error': error,
        },
      });
    }

    switch (subtype) {
      case 'initialize':
        unawaited(_handleInitialize(requestId, request));
      case 'set_permission_mode':
        final rawMode = request['mode'];
        final mode = rawMode is String ? rawMode.trim() : '';
        if (!_validPermissionModes.contains(mode)) {
          respondError('Unsupported permission mode: $rawMode');
          return;
        }
        _permissionMode = mode;
        if (mode != 'plan') {
          _autoModeDuringPlan = mode == 'bypassPermissions' || mode == 'auto';
        }
        if (_activeTurn == null &&
            _process != null &&
            _spawnedModeFlag != _effectiveModeFlag) {
          unawaited(_stopProcess(notifyActiveTurn: false));
        }
        respondSuccess({'mode': _permissionMode});
        _emit({
          'type': 'system',
          'subtype': 'status',
          'permissionMode': _permissionMode,
        });
      case 'set_model':
        if (request['model'] case final String model) {
          final parsed = AntigravityModels.parseVariant(model);
          _model = parsed?.model.effectiveCliModel ??
              AntigravityModels.cliModelIdOf(model);
          if (parsed != null) {
            if (parsed.model.effortLevels.isEmpty) {
              _effort = null;
            } else if (_effort == null ||
                !parsed.model.effortLevels.contains(_effort)) {
              _effort = parsed.effort ?? parsed.model.defaultEffort;
            }
            _maxContextTokens = parsed.model.resolveContextWindow(
              _maxContextTokens,
            );
          }
          if (_activeTurn == null &&
              (_spawnedModel != _model ||
                  _spawnedEffort != _effort ||
                  _spawnedContextTokens != _maxContextTokens)) {
            unawaited(_stopProcess(notifyActiveTurn: false));
          }
        }
        respondSuccess();
      case 'apply_flag_settings':
        var skillsChanged = false;
        if (request['settings'] case final Map settings) {
          final info = AntigravityModels.of(_model);
          if (settings['effortLevel'] case final String effort) {
            if (info == null || info.effortLevels.contains(effort)) {
              _effort = effort;
            } else if (info.effortLevels.isEmpty) {
              _effort = null;
            }
          }
          if (settings['contextWindow'] case final num tokens
              when tokens.toInt() > 0) {
            final requested = tokens.toInt();
            _maxContextTokens = info != null
                ? info.resolveContextWindow(requested)
                : requested;
          }
          if (settings['useAutoModeDuringPlan'] case final bool useAuto) {
            _autoModeDuringPlan = useAuto;
          }
          if (settings.containsKey('skillOverrides')) {
            final nextDisabled = <String>{};
            if (settings['skillOverrides'] case final Map overrides) {
              for (final MapEntry(:key, :value) in overrides.entries) {
                if (key is String && value == 'off') {
                  nextDisabled.add(key);
                }
              }
            }
            if (nextDisabled.length != _disabledSkills.length ||
                !nextDisabled.containsAll(_disabledSkills)) {
              _disabledSkills = nextDisabled;
              skillsChanged = true;
            }
          }
          if (settings.containsKey('permissions')) {
            final perms = settings['permissions'];
            final deny = perms is Map
                ? (perms['deny'] as List?)?.whereType<String>().toList() ??
                      const <String>[]
                : const <String>[];
            _switches = _switchesFromDenyRules(
              deny,
              previous: _switches,
            );
            _sdkBridge?.updateDisabled(
              disabledTools:
                  _switches.disabledTools[ClaudeSdkTools.server] ?? const {},
              serverDisabled: !_switches.serverEnabled(ClaudeSdkTools.server),
            );
            _writeMcpConfig();
          }
          final currentSettingsJson = jsonEncode(
            buildSessionSettings(launch, switches: _switches),
          );
          if (_activeTurn == null &&
              _process != null &&
              (_spawnedEffort != _effort ||
                  _spawnedContextTokens != _maxContextTokens ||
                  _spawnedModeFlag != _effectiveModeFlag ||
                  (_spawnedSettingsJson != null &&
                      _spawnedSettingsJson != currentSettingsJson))) {
            unawaited(_stopProcess(notifyActiveTurn: false));
          }
        }
        respondSuccess();
        if (skillsChanged) {
          unawaited(_emitCommandsChanged());
        }
      case 'get_settings':
        respondSuccess({
          'applied': {
            'model': AntigravityModels.bareModelId(_model),
            if (_effort != null) 'effort': _effort,
            'contextWindow': _maxContextTokens,
          },
        });
      case 'rename_session':
        if (request['title'] case final String title
            when title.trim().isNotEmpty) {
          final trimmed = title.trim();
          if (_sessionLog != null) {
            _sessionLog!.noteTitle(trimmed);
          } else {
            _pendingCustomTitle = trimmed;
          }
        }
        respondSuccess();
      case 'get_context_usage':
        final maxTokens = _maxContextTokens;
        if (_lastContextTokens <= 0) {
          final convId = _agyConversationId ?? _sessionId;
          if (convId != null && convId.isNotEmpty) {
            final seeded =
                readBrainContextTokens(
                  convId,
                  home: _paths.home,
                )?.contextTokens ??
                _sessionLog?.readLastContextTokens();
            if (seeded != null && seeded > 0) {
              _lastContextTokens = seeded;
            }
          }
        }
        final used = _lastContextTokens;
        respondSuccess({
          'maxTokens': maxTokens,
          'rawMaxTokens': maxTokens,
          'totalTokens': used,
          'categories': buildContextCategories(used, maxTokens),
        });
      case 'interrupt':
        _interrupted = true;
        _cancelSdkCalls();
        _cancelHookCallbacks();
        unawaited(_stopProcess(notifyActiveTurn: true));
        respondSuccess();
      case 'cancel_async_message':
        final targetUuid = request['message_uuid'] as String?;
        var cancelled = false;
        if (targetUuid != null && targetUuid.isNotEmpty) {
          final idx = _pendingTurns.indexWhere((t) => t.uuid == targetUuid);
          if (idx >= 0) {
            _pendingTurns.removeAt(idx);
            cancelled = true;
            _emit({
              'type': 'command_lifecycle',
              'command_uuid': targetUuid,
              'state': 'cancelled',
            });
          }
        }
        respondSuccess({'cancelled': cancelled});
      case 'get_usage':
        unawaited(_handleGetUsage(requestId));
      case 'file_suggestions':
        unawaited(_handleFileSuggestions(requestId, request));
      case 'mcp_status':
        unawaited(_handleMcpStatus(requestId));
      case 'mcp_toggle':
        unawaited(_handleMcpToggle(requestId, request));
      case 'mcp_reconnect':
      case 'reconnect_mcp':
        unawaited(_handleMcpReconnect(requestId, request));
      case 'mcp_authenticate':
        unawaited(_handleMcpAuthenticate(requestId, request));
      case 'rewind_conversation':
        respondSuccess(const {
          'rewound': false,
          'error': 'Antigravity CLI does not support conversation rewind.',
          'reason': 'unsupported',
        });
      case 'rewind_files':
        respondSuccess(const {
          'canRewind': false,
          'error': 'Antigravity CLI does not support file checkpoint rewind.',
        });
      case 'stop_task':
        respondError(
          'Antigravity CLI does not support stopping individual background tasks.',
        );
      case 'background_tasks':
        respondError(
          'Antigravity CLI does not support moving foreground tools to background.',
        );
      case 'get_hooks_listing':
        unawaited(_handleGetHooksListing(requestId));
      default:
        respondSuccess();
    }
  }

  Future<List<Map<String, Object?>>> _loadCommands() async {
    try {
      return await discoverAntigravityCommands(
        cwd: launch.cwd,
        home: _paths.home,
        disabledSkills: _disabledSkills,
      );
    } on Object {
      return antigravityBuiltinCommands;
    }
  }

  Future<void> _handleInitialize(
    String requestId,
    Map<String, Object?> request,
  ) async {
    _parseInitializeHooks(request['hooks']);
    final commands = await _loadCommands();
    if (_closed) return;
    final models = AntigravityModels.current;
    _emit({
      'type': 'control_response',
      'response': {
        'subtype': 'success',
        'request_id': requestId,
        'response': {
          'account': const {'subscriptionType': 'Antigravity CLI'},
          'models': [
            for (final m in models)
              {
                'value': m.id,
                'displayName': m.label,
                'description': m.description,
                'supportsEffort': m.effortLevels.isNotEmpty,
                'supportedEffortLevels': m.effortLevels,
                'supportsAutoMode': true,
              },
          ],
          'commands': commands,
        },
      },
    });
    _emit({
      'type': 'system',
      'subtype': 'init',
      if (_sessionId case final id? when id.isNotEmpty) 'session_id': id,
      'model': _model,
      'permissionMode': _permissionMode,
      if (_effort != null) 'effort': _effort,
    });
  }

  void _respondControlSuccess(
    String requestId, [
    Map<String, Object?> payload = const {},
  ]) {
    if (_closed || _messages.isClosed) return;
    _emit({
      'type': 'control_response',
      'response': {
        'subtype': 'success',
        'request_id': requestId,
        'response': payload,
      },
    });
  }

  Future<List<String>> _getWorkspaceFileIndex({bool forceRefresh = false}) async {
    final now = _now();
    final cached = _fileIndexCache;
    if (!forceRefresh &&
        cached != null &&
        now.difference(cached.cachedAt) < const Duration(seconds: 4)) {
      return cached.entries;
    }
    if (!forceRefresh && _fileIndexInFlight != null) {
      return _fileIndexInFlight!;
    }
    final cwd = launch.cwd;
    final future = Isolate.run<List<String>>(() {
      if (cwd.isEmpty || !Directory(cwd).existsSync()) {
        return const <String>[];
      }
      final dirs = <String>{};
      final files = <String>[];
      for (final entry in walkUnignored(
        cwd,
        skipDirectory: (_, name) => ideIndexExcludedDirectories.contains(name),
      )) {
        final rel = entry.relative;
        files.add(rel);
        var slash = rel.indexOf('/');
        while (slash > 0) {
          dirs.add(rel.substring(0, slash + 1));
          slash = rel.indexOf('/', slash + 1);
        }
        if (files.length >= 10000) break;
      }
      final sortedDirs = dirs.toList()..sort();
      return <String>[...sortedDirs, ...files];
    });
    _fileIndexInFlight = future;
    try {
      final entries = await future;
      _fileIndexCache = (cachedAt: _now(), entries: entries);
      return entries;
    } on Object {
      return cached?.entries ?? const <String>[];
    } finally {
      if (identical(_fileIndexInFlight, future)) {
        _fileIndexInFlight = null;
      }
    }
  }

  Future<void> _handleFileSuggestions(
    String requestId,
    Map<String, Object?> request,
  ) async {
    final query = (request['query'] as String? ?? '').trim();
    final limit = (request['limit'] as num?)?.toInt().clamp(1, 200) ?? 50;
    final cachedAge = _fileIndexCache == null
        ? null
        : _now().difference(_fileIndexCache!.cachedAt);
    var entries = await _getWorkspaceFileIndex();
    if (_closed) return;
    if (query.isNotEmpty &&
        cachedAge != null &&
        cachedAge > const Duration(milliseconds: 250)) {
      final hasAny = _rankFileSuggestions(entries, query, limit: 1).isNotEmpty;
      if (!hasAny) {
        entries = await _getWorkspaceFileIndex(forceRefresh: true);
        if (_closed) return;
      }
    }
    final matches = _rankFileSuggestions(entries, query, limit: limit);
    _respondControlSuccess(requestId, {
      'suggestions': [
        for (final path in matches) {'path': path},
      ],
      'cwd': launch.cwd,
    });
  }

  static List<String> _rankFileSuggestions(
    List<String> entries,
    String query, {
    int limit = 50,
  }) {
    if (entries.isEmpty) return const [];
    final normQuery = query.replaceAll('\\', '/').trim();
    if (normQuery.isEmpty) {
      final files = [for (final e in entries) if (!e.endsWith('/')) e];
      if (files.length >= limit) return files.take(limit).toList();
      final dirs = [for (final e in entries) if (e.endsWith('/')) e];
      return [...files, ...dirs].take(limit).toList();
    }
    final qLower = normQuery.toLowerCase();
    final scored = <({String path, int score})>[];
    for (final path in entries) {
      final match = ideFuzzyMatch(normQuery, path);
      if (match == null) continue;
      final trimmed = path.endsWith('/')
          ? path.substring(0, path.length - 1)
          : path;
      final base = p.posix.basename(trimmed).toLowerCase();
      var score = match.score;
      if (base == qLower) {
        score += 40;
      } else if (base.startsWith(qLower)) {
        score += 25;
      } else if (base.contains(qLower)) {
        score += 15;
      } else if (path.toLowerCase().contains(qLower)) {
        score += 8;
      }
      if (path.endsWith('/')) score -= 2;
      scored.add((path: path, score: score));
    }
    scored.sort((a, b) {
      final cmp = b.score.compareTo(a.score);
      if (cmp != 0) return cmp;
      final lenCmp = a.path.length.compareTo(b.path.length);
      if (lenCmp != 0) return lenCmp;
      return a.path.compareTo(b.path);
    });
    return [for (final item in scored.take(limit)) item.path];
  }

  bool _isMcpServerEnabled(Customization item) {
    if (item.enabled == false) return false;
    final norm = ExtensionSwitches.normalize(item.name);
    return _switches.serverEnabled(item.name) && _switches.serverEnabled(norm);
  }

  Future<Map<String, Customization>> _loadExternalMcpServers() async {
    final home = _paths.home;
    final store = home.isNotEmpty
        ? CustomizationStore(
            configDir: p.join(home, '.gemini', 'config'),
            homeDir: home,
          )
        : CustomizationStore();
    final listed = await store.list(
      CustomizationKind.mcps,
      project: launch.cwd.isNotEmpty ? launch.cwd : null,
    );
    final byName = <String, Customization>{};
    for (final item in listed) {
      if (item.name.isEmpty) continue;
      byName[item.name] = item;
    }
    return byName;
  }

  static String _mcpStatusString(McpProbeStatus status) => switch (status) {
    McpProbeStatus.connected => 'connected',
    McpProbeStatus.needsAuth => 'needs-auth',
    McpProbeStatus.disabled => 'disabled',
    McpProbeStatus.checking => 'pending',
    McpProbeStatus.failed => 'failed',
  };

  Future<McpProbeResult> _probeExternalServer(
    Customization item, {
    bool forceRefresh = false,
  }) async {
    if (!_isMcpServerEnabled(item)) {
      return McpProbeResult.disabled;
    }
    if (!forceRefresh) {
      final cached = _mcpProbeCache[item.name];
      if (cached != null && cached.status != McpProbeStatus.disabled) {
        return cached;
      }
    }
    final cfg = item.server;
    if (cfg == null) {
      return const McpProbeResult(
        McpProbeStatus.failed,
        message: 'Invalid MCP server configuration.',
      );
    }
    final result = await probeMcpServer(
      cfg,
      cwd: launch.cwd.isNotEmpty ? launch.cwd : null,
      timeout: const Duration(seconds: 3),
    );
    _mcpProbeCache[item.name] = result;
    return result;
  }

  Future<void> _handleMcpStatus(String requestId) async {
    final servers = <Map<String, Object?>>[];
    if (launch.sdkServers.contains(ClaudeSdkTools.server)) {
      final sdkEnabled = _switches.serverEnabled(ClaudeSdkTools.server);
      final rpc = await ClaudeSdkTools.handle(
        const {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'},
        ClaudeSdkCall(cwd: launch.cwd),
      );
      final rawTools = switch (rpc['result']) {
        {'tools': final List list} => list,
        _ => const <Object?>[],
      };
      servers.add({
        'name': ClaudeSdkTools.server,
        'status': sdkEnabled ? 'connected' : 'disabled',
        'scope': 'sdk',
        'serverInfo': const {
          'name': ClaudeSdkTools.server,
          'version': '1.0.0',
        },
        'tools': [
          for (final tool in rawTools)
            if (tool is Map && tool['name'] is String)
              if (_switches.toolEnabled(
                    ClaudeSdkTools.server,
                    tool['name'] as String,
                  ) &&
                  _switches.toolEnabled(
                    ClaudeSdkTools.server,
                    ExtensionSwitches.normalize(tool['name'] as String),
                  ))
                {'name': tool['name']},
        ],
      });
    }
    final external = await _loadExternalMcpServers();
    if (_closed) return;
    final probed = await Future.wait([
      for (final item in external.values)
        _probeExternalServer(item).then((res) => (item: item, result: res)),
    ]);
    if (_closed) return;
    for (final (:item, :result) in probed) {
      final disabled = !_isMcpServerEnabled(item);
      final effective = disabled ? McpProbeResult.disabled : result;
      servers.add({
        'name': item.name,
        'status': _mcpStatusString(effective.status),
        'scope': item.scope.name,
        if (effective.message case final msg? when msg.trim().isNotEmpty)
          'error': msg.trim(),
        if (effective.server case final info? when info.trim().isNotEmpty)
          'serverInfo': {'name': item.name, 'version': info.trim()},
        if (effective.tools case final tools?)
          'tools': [
            for (final tool in tools) {'name': tool.name},
          ],
      });
    }
    _respondControlSuccess(requestId, {'mcpServers': servers});
  }

  Future<void> _handleMcpToggle(
    String requestId,
    Map<String, Object?> request,
  ) async {
    final name = (request['serverName'] as String? ?? '').trim();
    final enabled = request['enabled'] == true;
    if (name.isNotEmpty) {
      _switches = _switches.withServer(name, enabled);
      final norm = ExtensionSwitches.normalize(name);
      if (norm != name) {
        _switches = _switches.withServer(norm, enabled);
      }
      if (ExtensionSwitches.save case final save?) {
        unawaited(
          Future<void>.sync(() => save(_switches)).catchError((Object _) {}),
        );
      }
      if (name == ClaudeSdkTools.server) {
        _sdkBridge?.updateDisabled(
          disabledTools:
              _switches.disabledTools[ClaudeSdkTools.server] ?? const {},
          serverDisabled: !enabled,
        );
        _writeMcpConfig();
      } else if (!enabled) {
        _mcpProbeCache[name] = McpProbeResult.disabled;
      } else {
        _mcpProbeCache.remove(name);
      }
      if (_activeTurn == null && _process != null) {
        await _stopProcess(notifyActiveTurn: false);
        if (_closed) return;
      }
    }
    _respondControlSuccess(requestId);
  }

  Future<void> _handleMcpReconnect(
    String requestId,
    Map<String, Object?> request,
  ) async {
    final name = (request['serverName'] as String? ?? '').trim();
    if (name == ClaudeSdkTools.server) {
      await _ensureBridgeAndConfig();
    } else if (name.isNotEmpty) {
      _mcpProbeCache.remove(name);
      final external = await _loadExternalMcpServers();
      if (_closed) return;
      if (external[name] case final item?) {
        await _probeExternalServer(item, forceRefresh: true);
      }
    }
    _respondControlSuccess(requestId);
  }

  Future<void> _handleMcpAuthenticate(
    String requestId,
    Map<String, Object?> request,
  ) async {
    final name = (request['serverName'] as String? ?? '').trim();
    if (name.isNotEmpty && name != ClaudeSdkTools.server) {
      _mcpProbeCache.remove(name);
      final external = await _loadExternalMcpServers();
      if (_closed) return;
      if (external[name] case final item?) {
        await _probeExternalServer(item, forceRefresh: true);
      }
    }
    _respondControlSuccess(requestId);
  }

  Future<void> _handleGetUsage(String requestId) async {
    final scopedHome = _paths.home;
    AntigravityAccount? account;
    AntigravityAccounts? tempAccounts;
    try {
      await AntigravityAccounts.instance.ensureInitialized();
      final instanceDir = AntigravityAccounts.instance.dataDirectoryPath;
      final expectedDir = scopedHome.isNotEmpty
          ? p.join(scopedHome, '.ayte', 'antigravity_accounts')
          : '';
      if (expectedDir.isNotEmpty && !p.equals(instanceDir, expectedDir)) {
        tempAccounts = AntigravityAccounts(dataDir: expectedDir);
        await tempAccounts.ensureInitialized();
        account = tempAccounts.currentAccount;
      } else {
        account = AntigravityAccounts.instance.currentAccount;
      }
    } on Object {
      account = AntigravityAccounts.instance.currentAccount;
    } finally {
      tempAccounts?.dispose();
    }
    if (_closed) return;
    _respondControlSuccess(requestId, buildUsagePayload(account));
  }

  @visibleForTesting
  static Map<String, Object?> buildUsagePayload(AntigravityAccount? account) {
    final quota = account?.quota;
    if (account == null || quota == null) {
      return const {'rate_limits_available': false};
    }
    final groups = quota.resolvedUsageGroups;
    final windows = <Map<String, Object?>>[
      for (final g in groups)
        for (final b in g.buckets)
          {
            'label': (g.displayName.isNotEmpty && b.window.isNotEmpty)
                ? '${g.displayName} (${b.window})'
                : (b.displayName.isNotEmpty
                      ? b.displayName
                      : (b.bucketId.isNotEmpty ? b.bucketId : g.displayName)),
            'utilization': ((1.0 - b.remainingFraction.clamp(0.0, 1.0)) * 100.0)
                .clamp(0.0, 100.0),
            'remaining_fraction': b.remainingFraction.clamp(0.0, 1.0),
            if (b.resetAt case final dt?)
              'resets_at': dt.toUtc().toIso8601String(),
          },
    ];
    if (windows.isEmpty) {
      return const {'rate_limits_available': false};
    }
    final tierBadge = quota.tier == AntigravityTier.unknown
        ? 'Antigravity'
        : 'Antigravity ${quota.tier.badge}';
    return {
      'rate_limits_available': true,
      'subscription_type': tierBadge,
      'rate_limits': {'windows': windows},
    };
  }

  Future<void> _handleGetHooksListing(String requestId) async {
    final home = _paths.home;
    final cwd = launch.cwd;
    final sources = <(String source, String path)>[
      if (home.isNotEmpty)
        ('user', p.join(home, '.gemini', 'config', 'hooks.json')),
      if (cwd.isNotEmpty) ...[
        ('project', p.join(cwd, '.agents', 'hooks.json')),
        ('local', p.join(cwd, '.agents', 'hooks.local.json')),
      ],
    ];
    final hooks = <Map<String, Object?>>[];
    for (final (source, path) in sources) {
      final file = File(path);
      if (!file.existsSync()) continue;
      try {
        final raw = const Utf8Decoder(allowMalformed: true).convert(
          await file.readAsBytes(),
        );
        final decoded = jsonDecode(raw);
        if (decoded is! Map) continue;
        final events = decoded['hooks'];
        if (events is! Map) continue;
        for (final MapEntry(:key, :value) in events.entries) {
          if (key is! String || value is! List) continue;
          for (final group in value) {
            if (group is! Map) continue;
            final matcher = '${group['matcher'] ?? ''}';
            final groupHooks = group['hooks'];
            if (groupHooks is! List) continue;
            for (final hook in groupHooks) {
              if (hook is! Map) continue;
              hooks.add({
                'event': key,
                'matcher': matcher,
                'source': source,
                'type': '${hook['type'] ?? 'command'}',
                'commandText': '${hook['command'] ?? hook['prompt'] ?? ''}',
              });
            }
          }
        }
      } on Object {
        // Skip unreadable or malformed hooks file.
      }
    }
    if (_closed) return;
    _respondControlSuccess(requestId, {'hooks': hooks});
  }

  Future<void> _emitCommandsChanged() async {
    final commands = await _loadCommands();
    if (_closed) return;
    _emit({
      'type': 'system',
      'subtype': 'commands_changed',
      'commands': commands,
    });
  }

  /// Builds `get_context_usage` category segments matching
  /// `ContextUsagePanel.partOf` (`System prompt`, `System tools`, `Messages`).
  static List<Map<String, Object?>> buildContextCategories(
    int used,
    int maxTokens,
  ) {
    final safeUsed = math.max(0, used);
    final sys = safeUsed > 0 ? math.min(6200, (safeUsed * 0.22).round()) : 0;
    final tools = safeUsed > 0 ? math.min(21600, (safeUsed * 0.72).round()) : 0;
    final messages = math.max(0, safeUsed - sys - tools);
    final free = math.max(0, maxTokens - safeUsed);
    return [
      {'name': 'System prompt', 'tokens': sys, 'kind': 'used'},
      {'name': 'System tools', 'tokens': tools, 'kind': 'used'},
      {'name': 'Messages', 'tokens': messages, 'kind': 'used'},
      {'name': 'Free space', 'tokens': free, 'kind': 'free'},
    ];
  }

  Future<String> _extractPrompt(Map<String, Object?> userMessage) async {
    final msg = userMessage['message'];
    if (msg is! Map) return '';
    final content = msg['content'];
    if (content is String) return content;
    if (content is! List) return '';

    final parts = <String>[];
    var imageIndex = 0;
    for (final raw in content) {
      if (raw is! Map) continue;
      switch (raw['type']) {
        case 'text':
          final text = '${raw['text'] ?? ''}'.trim();
          if (text.isNotEmpty) parts.add(text);
        case 'image':
          final source = raw['source'];
          if (source is Map && source['type'] == 'base64') {
            final data = source['data'] as String?;
            final mediaType = source['media_type'] as String? ?? 'image/png';
            if (data != null && data.isNotEmpty) {
              final op = Completer<void>();
              _inFlightImageWrites.add(op.future);
              try {
                final bytes = base64Decode(data);
                if (_closed) return '';
                final ext = mediaType.contains('jpeg') ||
                        mediaType.contains('jpg')
                    ? 'jpg'
                    : mediaType.contains('webp')
                    ? 'webp'
                    : 'png';
                var imgDir = _tempImageDir;
                if (imgDir == null) {
                  final dir = Directory(
                    p.join(
                      DataDirectory.current.cacheDir,
                      'agy-img',
                      '$pid-${++_imgDirSeq}',
                    ),
                  );
                  _tempImageDirs[dir.path] = dir;
                  await dir.create(recursive: true);
                  if (_closed) {
                    await _deleteTempDirWithRetry(dir);
                    return '';
                  }
                  imgDir = _tempImageDir = dir;
                }
                imageIndex++;
                final tempFile = File(
                  p.join(imgDir.path, 'img_${++_imgSeq}.$ext'),
                );
                await tempFile.writeAsBytes(bytes);
                if (_closed) {
                  await _deleteTempDirWithRetry(imgDir);
                  return '';
                }
                parts.add(
                  '[Attached image #$imageIndex saved at ${tempFile.path} — use read_file to inspect it]',
                );
              } on Object {
                if (_closed) {
                  await _cleanupTempImages();
                  return '';
                }
                // Ignore malformed base64 image or disk error.
              } finally {
                if (!op.isCompleted) op.complete();
                _inFlightImageWrites.remove(op.future);
              }
            }
          }
      }
    }
    return parts.join('\n\n');
  }

  Future<bool> _deleteDirWithRetry(Directory dir) async {
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        if (!dir.existsSync()) return true;
        dir.deleteSync(recursive: true);
        return true;
      } on FileSystemException {
        if (attempt == 19) return false;
        await Future<void>.delayed(const Duration(milliseconds: 25));
      } on Object {
        return false;
      }
    }
    return !dir.existsSync();
  }

  Future<void> _deleteTempDirWithRetry(Directory dir) async {
    if (await _deleteDirWithRetry(dir)) {
      _tempImageDirs.remove(dir.path);
    }
  }

  void _cleanupTempImagesSync() {
    _tempImageDir = null;
    for (final dir in [..._tempImageDirs.values]) {
      try {
        if (!dir.existsSync()) {
          _tempImageDirs.remove(dir.path);
        } else {
          dir.deleteSync(recursive: true);
          _tempImageDirs.remove(dir.path);
        }
      } on Object {
        // Keep in _tempImageDirs for async retry cleanup once handles close.
      }
    }
  }

  Future<void> _cleanupTempImages() async {
    _tempImageDir = null;
    final dirs = [..._tempImageDirs.values];
    if (dirs.isEmpty) return;
    await Future.wait([
      for (final dir in dirs) _deleteTempDirWithRetry(dir),
    ]);
  }

  Future<void> _cleanupSessionConfigDirs() async {
    final dirs = [..._pendingSessionConfigDirs];
    if (dirs.isEmpty) return;
    await Future.wait([
      for (final dir in dirs)
        _deleteDirWithRetry(dir).then((deleted) {
          if (deleted) _pendingSessionConfigDirs.remove(dir);
        }),
    ]);
  }

  Future<void> _finalizeClose() async {
    try {
      while (true) {
        final pending = <Future<void>>[
          ..._inFlightSpawns,
          ..._pendingCleanups,
          ..._inFlightImageWrites,
        ];
        if (pending.isEmpty) break;
        for (final f in pending) {
          try {
            await f;
          } on Object {
            // Best-effort drain during close.
          }
        }
      }
      await _cleanupSessionArtifactsOnClose();
      await _cleanupSessionConfigDirs();
      await _cleanupTempImages();
    } finally {
      _live.remove(this);
      if (!_messages.isClosed) {
        _messages
          ..add(ClaudeExit.message(0, '', executable: executable))
          ..close();
      }
      if (!_exited.isCompleted) {
        _exited.complete();
      }
    }
  }

  static String _modeFlagFor(
    String permissionMode, {
    bool autoApproveInPlan = false,
  }) => switch (permissionMode) {
    'plan' =>
      autoApproveInPlan
          ? '--mode=plan --dangerously-skip-permissions'
          : '--mode=plan',
    'acceptEdits' => '--mode=accept-edits',
    'auto' => '--mode=auto',
    'bypassPermissions' => '--dangerously-skip-permissions',
    _ => 'default',
  };

  String get _effectiveModeFlag =>
      _modeFlagFor(_permissionMode, autoApproveInPlan: _autoModeDuringPlan);

  static ExtensionSwitches _switchesFromDenyRules(
    List<String> deny, {
    required ExtensionSwitches previous,
  }) {
    final disabledServers = <String>{};
    final disabledTools = <String, Set<String>>{};
    final prevServersByNorm = <String, String>{
      for (final s in previous.disabledTools.keys)
        ExtensionSwitches.normalize(s): s,
      for (final s in previous.disabledServers)
        ExtensionSwitches.normalize(s): s,
    };
    final prevToolsByServer = <String, Map<String, List<String>>>{};
    for (final MapEntry(key: server, value: tools)
        in previous.disabledTools.entries) {
      final byNorm = <String, List<String>>{};
      for (final tool in tools) {
        (byNorm[ExtensionSwitches.normalize(tool)] ??= <String>[]).add(tool);
      }
      prevToolsByServer[server] = byNorm;
    }
    for (final rule in deny) {
      if (!rule.startsWith('mcp__')) continue;
      final rest = rule.substring(5);
      if (rest.isEmpty) continue;
      final sep = rest.indexOf('__');
      if (sep < 0) {
        disabledServers.add(prevServersByNorm[rest] ?? rest);
      } else {
        final serverKey = rest.substring(0, sep);
        final server = prevServersByNorm[serverKey] ?? serverKey;
        final normTool = rest.substring(sep + 2);
        if (server.isNotEmpty && normTool.isNotEmpty) {
          final target = disabledTools[server] ??= <String>{};
          final originals = prevToolsByServer[server]?[normTool];
          if (originals != null && originals.isNotEmpty) {
            target.addAll(originals);
          } else {
            target.add(normTool);
          }
        }
      }
    }
    return ExtensionSwitches(
      disabledServers: disabledServers,
      disabledTools: disabledTools,
      disabledSkills: previous.disabledSkills,
    );
  }

  /// Builds the per-session `AGENTS.md` content injected via `--add-dir`,
  /// combining [ClaudeLaunch.appendedSystemPrompt] (unless `ownPrompt` is
  /// true), `launch.instructions`, `ClaudeSdkTools` gated feature
  /// instructions, commit/PR attribution directives, and `launch.tools` /
  /// `launch.userServers` constraints.
  static String? buildSessionInstructions({
    required ClaudeLaunch launch,
    String? sdkInstructions,
  }) {
    final sections = <String>[];
    final custom = launch.instructions?.trim() ?? '';
    final sdk = sdkInstructions?.trim() ?? '';

    if (launch.ownPrompt) {
      sections.add(
        '# Custom System Instructions (Override)\n'
        'Follow these session instructions as your primary persona and '
        'behavioral rules; ignore default coding-assistant boilerplate unless '
        'explicitly required by the task.',
      );
      if (custom.isNotEmpty) sections.add(custom);
    } else {
      sections.add(ClaudeLaunch.appendedSystemPrompt);
      if (custom.isNotEmpty) sections.add(custom);
    }

    if (sdk.isNotEmpty) {
      sections.add(sdk);
    }

    switch (launch.attribution) {
      case CommitAttribution.baocode:
        sections.add(
          '# Commit & Pull Request Attribution\n'
          'When creating git commits, include the exact trailer:\n'
          '${CommitAttribution.baoCodeCommit}\n'
          'When creating pull requests, include:\n'
          '${CommitAttribution.baoCodePullRequest}',
        );
      case CommitAttribution.none:
        sections.add(
          '# Commit & Pull Request Attribution\n'
          'Do NOT add any Co-Authored-By trailers or AI/agent attribution '
          'lines to git commits or pull requests.',
        );
      case CommitAttribution.agent:
        break;
    }

    if (launch.tools case final allowedTools?) {
      final toolList = allowedTools.isEmpty
          ? '(none — no built-in tools allowed)'
          : allowedTools.join(', ');
      sections.add(
        '# Tool Restrictions\n'
        'Restrict built-in tools to: $toolList.'
        '${launch.userServers ? '' : ' Do not invoke user-configured MCP servers outside `${ClaudeSdkTools.server}`.'}',
      );
    }

    final joined = sections.where((s) => s.trim().isNotEmpty).join('\n\n');
    return joined.isEmpty ? null : joined;
  }

  /// Translates [ClaudeLaunch] (`allowed`, `switches`, `tools`) into
  /// `agy --settings` `permissions` entries, returning an empty map when no
  /// permission rules apply.
  ///
  /// Note: [ClaudeLaunch.readable] folders are exposed via `--add-dir` in
  /// [buildCliArguments] rather than Claude Code's `Read(...)` grant syntax:
  /// `agy` rejects `"Read(...)"` (`unknown action "Read"`) and passing a
  /// non-empty `permissions.allow` via `--settings` replaces the user's
  /// `~/.gemini/antigravity-cli/settings.json` allowlist.
  static Map<String, Object?> buildSessionSettings(
    ClaudeLaunch launch, {
    ExtensionSwitches? switches,
  }) {
    final activeSwitches = switches ?? launch.switches;
    final allow = <String>[];
    final seenAllow = <String>{};
    for (final rule in launch.allowed) {
      if (rule.isEmpty) continue;
      if (seenAllow.add(rule)) allow.add(rule);
    }
    final deny = <String>[];
    final seenDeny = <String>{};
    for (final rule in activeSwitches.denyRules) {
      if (seenDeny.add(rule)) deny.add(rule);
    }

    if (launch.tools case final allowedTools?) {
      final normalizedAllowed = {
        for (final t in allowedTools) t.trim().toLowerCase(),
      };
      const toolCategories = <List<String>>[
        ['bash', 'run_command', 'execute_command'],
        ['read', 'read_file', 'view_file'],
        [
          'edit',
          'edit_file',
          'replace_file_content',
          'multi_replace_file_content',
        ],
        ['write', 'write_file', 'write_to_file'],
        ['grep', 'grep_search'],
        ['glob', 'find_by_name', 'list_dir'],
        ['websearch', 'search_web'],
        ['webfetch', 'read_url_content'],
      ];
      for (final category in toolCategories) {
        if (!category.any(normalizedAllowed.contains)) {
          for (final agyTool in category.skip(1)) {
            if (!deny.contains(agyTool)) deny.add(agyTool);
          }
        }
      }
    }

    if (allow.isEmpty && deny.isEmpty) return const {};
    return {
      'permissions': {
        if (allow.isNotEmpty) 'allow': allow,
        if (deny.isNotEmpty) 'deny': deny,
      },
    };
  }

  /// Builds `agy` CLI flags, passing `--settings={"contextWindow": ...}` for
  /// models in `ContextWindowSelectable` (`supportsPresetContextWindow`) or
  /// when the user explicitly forces an extended window above the default,
  /// merged with any [extraSettings] (such as `permissions`).
  static List<String> buildCliArguments({
    required String model,
    required String? effort,
    required String permissionMode,
    required int maxContextTokens,
    String? conversationId,
    List<String> directories = const [],
    List<String> readable = const [],
    String? sessionConfigDir,
    String? tempImageRootDir,
    bool autoApproveInPlan = false,
    Map<String, Object?>? extraSettings,
  }) {
    final info = AntigravityModels.of(model);
    final defaultTokens = info?.defaultContext ?? 256000;
    final passWindow =
        (info?.supportsPresetContextWindow ?? false) ||
        maxContextTokens > defaultTokens;
    final presetWindow = passWindow
        ? AntigravityModels.presetContextWindowName(maxContextTokens)
        : null;

    final mergedSettings = <String, Object?>{
      ...?extraSettings,
      'contextWindow': ?presetWindow,
    };

    final addDirs = <String>[];
    final seenDirs = <String>{};
    void addDir(String dir) {
      if (dir.isEmpty) return;
      final normalized = p.normalize(dir);
      final key = Platform.isWindows ? normalized.toLowerCase() : normalized;
      if (seenDirs.add(key)) addDirs.add(dir);
    }

    for (final dir in directories) {
      addDir(dir);
    }
    for (final dir in readable) {
      if (Directory(dir).existsSync()) addDir(dir);
    }
    if (sessionConfigDir != null && sessionConfigDir.isNotEmpty) {
      addDir(sessionConfigDir);
    }
    if (tempImageRootDir != null &&
        tempImageRootDir.isNotEmpty &&
        Directory(tempImageRootDir).existsSync()) {
      addDir(tempImageRootDir);
    }

    return <String>[
      '--input-format=stream-json',
      '--output-format=stream-json',
      if (conversationId != null && conversationId.isNotEmpty)
        '--conversation=$conversationId',
      if (model.isNotEmpty && model != 'default') '--model=$model',
      if (effort != null &&
          const {'low', 'medium', 'high', 'xhigh', 'max'}.contains(effort))
        '--effort=$effort',
      if (mergedSettings.isNotEmpty)
        '--settings=${jsonEncode(mergedSettings)}',
      if (permissionMode == 'acceptEdits') '--mode=accept-edits',
      if (permissionMode == 'auto') '--mode=auto',
      if (permissionMode == 'plan') '--mode=plan',
      if (permissionMode == 'bypassPermissions' ||
          (permissionMode == 'plan' && autoApproveInPlan))
        '--dangerously-skip-permissions',
      for (final dir in addDirs) '--add-dir=$dir',
      '-p=',
    ];
  }

  /// Builds child process environment for `agy`.
  ///
  /// In `agy` v1.5.10, `store.(*Store).ContextWindow()` gates on
  /// `backend.ContextWindowSelectable` (`["Gemini 4 Argon"]`), and its
  /// `featureProvider` check before `ContextWindowChoice()` (`--settings`) is
  /// dead-code eliminated in CLI mode, whereas `AGY_CLI_AUTO_COMPACT_OVERRIDE`
  /// runs right before it and sets `CheckpointConfig.MaxTokenLimit` (`512000`
  /// or `900000`) directly on Cortex — matching Antigravity IDE's `GRa` map
  /// (`{"256K": undefined, "512K": 512000, "900K": 900000}`).
  static Map<String, String> buildProcessEnvironment({
    required Map<String, String> baseEnvironment,
    required String model,
    required int maxContextTokens,
  }) {
    final env = <String, String>{...baseEnvironment}
      ..remove('AGY_CLI_AUTO_COMPACT_OVERRIDE');
    final info = AntigravityModels.of(model);
    final defaultTokens = info?.defaultContext ?? 256000;
    if (maxContextTokens > defaultTokens) {
      env['AGY_CLI_AUTO_COMPACT_OVERRIDE'] = '$maxContextTokens';
    }
    return env;
  }

  List<String> _buildArguments() => buildCliArguments(
    model: _model,
    effort: _effort,
    permissionMode: _permissionMode,
    autoApproveInPlan: _autoModeDuringPlan,
    maxContextTokens: _maxContextTokens,
    conversationId: _agyConversationId,
    directories: launch.directories,
    readable: launch.readable,
    sessionConfigDir: _sessionConfigDir?.path,
    tempImageRootDir: _tempImageRootDir?.path,
    extraSettings: buildSessionSettings(launch, switches: _switches),
  );

  Future<T> _trackSpawn<T>(Future<T> future) {
    _inFlightSpawns.add(future);
    unawaited(
      future.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
        _inFlightSpawns.remove(future);
      }),
    );
    return future;
  }

  Future<void> _trackCleanup(Future<void> future) {
    _pendingCleanups.add(future);
    unawaited(
      future.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
        _pendingCleanups.remove(future);
      }),
    );
    return future;
  }

  Future<void> _ensureBridgeAndConfig() =>
      _trackSpawn(_ensureBridgeAndConfigImpl());

  Future<void> _ensureBridgeAndConfigImpl() async {
    if (_closed) return;
    if (launch.sdkServers.contains(ClaudeSdkTools.server) &&
        _sdkBridge == null) {
      final bridge = await AyteSdkMcpBridge.start(
        cwd: launch.cwd,
        sessionIdProvider: () => _sessionId ?? _agyConversationId,
        turnIdProvider: () => _activeTurnUuid,
        cancelledProvider: () => _sdkTurnCancelled.future,
        ask: ClaudeSdkTools.asksUser(launch.cwd) ? _askViaControlChannel : null,
        includeAntigravityAlwaysLoad: true,
        disabledTools:
            _switches.disabledTools[ClaudeSdkTools.server] ?? const {},
        serverDisabled: !_switches.serverEnabled(ClaudeSdkTools.server),
        onConversationIdObserved: _bindConversationId,
      );
      if (_closed) {
        await bridge.close(force: true);
        return;
      }
      _sdkBridge = bridge;
      bridge.updateDisabled(
        disabledTools:
            _switches.disabledTools[ClaudeSdkTools.server] ?? const {},
        serverDisabled: !_switches.serverEnabled(ClaudeSdkTools.server),
      );
      if (_sessionId != null && _sessionId!.isNotEmpty) {
        _sdkBridge!.updateSessionId(_sessionId);
      }
    }
    if (_closed) return;

    final instructions = buildSessionInstructions(
      launch: launch,
      sdkInstructions: ClaudeSdkTools.instructionsFor(launch.cwd),
    );
    if (_sdkBridge == null && instructions == null) return;

    if (_sessionConfigDir == null) {
      final dir = Directory(
        p.join(
          DataDirectory.current.cacheDir,
          'agy-mcp',
          '$pid-${++_configSeq}',
        ),
      );
      await dir.create(recursive: true);
      _pendingSessionConfigDirs.add(dir);
      if (_closed) {
        if (await _deleteDirWithRetry(dir)) {
          _pendingSessionConfigDirs.remove(dir);
        }
        return;
      }
      _sessionConfigDir = dir;
    }

    final configDir = _sessionConfigDir;
    if (_closed || configDir == null) {
      if (_closed && configDir != null) {
        if (identical(_sessionConfigDir, configDir)) {
          _sessionConfigDir = null;
        }
        if (await _deleteDirWithRetry(configDir)) {
          _pendingSessionConfigDirs.remove(configDir);
        }
      }
      return;
    }
    _writeMcpConfig(configDir);
    if (_closed) {
      if (identical(_sessionConfigDir, configDir)) {
        _sessionConfigDir = null;
      }
      if (await _deleteDirWithRetry(configDir)) {
        _pendingSessionConfigDirs.remove(configDir);
      }
      return;
    }
    if (instructions != null) {
      final agentsFile = File(p.join(configDir.path, 'AGENTS.md'));
      try {
        await agentsFile.writeAsString(instructions);
      } on Object {
        if (!_closed) rethrow;
      } finally {
        if (_closed) {
          if (identical(_sessionConfigDir, configDir)) {
            _sessionConfigDir = null;
          }
          if (await _deleteDirWithRetry(configDir)) {
            _pendingSessionConfigDirs.remove(configDir);
          }
        }
      }
    }
  }

  void _writeMcpConfig([Directory? targetDir]) {
    final configDir = targetDir ?? _sessionConfigDir;
    if (configDir == null || _closed) return;
    final mcpFile = File(p.join(configDir.path, '.agents', 'mcp_config.json'));
    try {
      if (_sdkBridge != null && _switches.serverEnabled(ClaudeSdkTools.server)) {
        mcpFile.parent.createSync(recursive: true);
        mcpFile.writeAsStringSync(
          jsonEncode({
            'mcpServers': {
              ClaudeSdkTools.server: _sdkBridge!.mcpServerConfig(),
            },
          }),
        );
      } else if (mcpFile.existsSync()) {
        mcpFile.writeAsStringSync(jsonEncode({'mcpServers': const {}}));
      }
    } on Object {
      // Best-effort config write.
    }
  }

  Future<void> _cleanupSessionArtifactsOnClose() async {
    final bridge = _sdkBridge;
    _sdkBridge = null;
    final configDir = _sessionConfigDir;
    _sessionConfigDir = null;
    if (configDir != null) {
      _pendingSessionConfigDirs.add(configDir);
      try {
        if (!configDir.existsSync()) {
          _pendingSessionConfigDirs.remove(configDir);
        } else {
          configDir.deleteSync(recursive: true);
          _pendingSessionConfigDirs.remove(configDir);
        }
      } on Object {
        // Keep in _pendingSessionConfigDirs for async retry after process exit.
      }
    }
    if (bridge != null) {
      try {
        await bridge.close(force: true);
      } on Object {
        // Best-effort shutdown of SDK bridge.
      }
    }
    if (configDir != null && _pendingSessionConfigDirs.contains(configDir)) {
      if (await _deleteDirWithRetry(configDir)) {
        _pendingSessionConfigDirs.remove(configDir);
      }
    }
  }

  Future<void> _terminateProcessTree(Process proc) async {
    if (Platform.isWindows) {
      try {
        await Process.run('taskkill', ['/pid', '${proc.pid}', '/T', '/F']);
      } on Object {
        try {
          proc.kill();
        } on Object {
          // Ignore if already exited.
        }
      }
      try {
        unawaited(proc.stdin.close().catchError((Object _) {}));
      } on Object {
        // Ignore.
      }
    } else {
      try {
        unawaited(proc.stdin.close().catchError((Object _) {}));
      } on Object {
        // Ignore.
      }
      try {
        proc.kill(ProcessSignal.sigterm);
      } on Object {
        // Ignore if already exited.
      }
    }
  }

  Future<void> _awaitProcessExitBounded(
    Process proc, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    try {
      await proc.exitCode.timeout(
        timeout,
        onTimeout: () {
          try {
            proc.kill(ProcessSignal.sigkill);
          } on Object {
            // Ignore.
          }
          return -1;
        },
      );
    } on Object {
      // Ignore if exitCode fails.
    }
  }

  Future<({Process process, bool reused})?> _ensureProcess() =>
      _trackSpawn(_ensureProcessImpl());

  Future<({Process process, bool reused})?> _ensureProcessImpl() async {
    if (_closed) return null;
    final currentSettingsJson = jsonEncode(
      buildSessionSettings(launch, switches: _switches),
    );
    if (_process != null &&
        !_needsAccountRespawn &&
        _spawnedModel == _model &&
        _spawnedModeFlag == _effectiveModeFlag &&
        _spawnedEffort == _effort &&
        _spawnedContextTokens == _maxContextTokens &&
        _spawnedSettingsJson == currentSettingsJson) {
      return (process: _process!, reused: true);
    }
    _needsAccountRespawn = false;
    await _stopProcess(notifyActiveTurn: false);
    if (_closed) return null;
    await _ensureBridgeAndConfig();
    if (_closed) {
      await _cleanupSessionArtifactsOnClose();
      return null;
    }

    // Ensure the shared `agy-img` cache root exists and is passed via
    // `--add-dir` so images attached on later turns can be read by `read_file`
    // without triggering non-workspace permission denials.
    final imgRoot = Directory(
      p.join(DataDirectory.current.cacheDir, 'agy-img'),
    );
    try {
      if (!imgRoot.existsSync()) {
        await imgRoot.create(recursive: true);
      }
      if (imgRoot.existsSync()) {
        _tempImageRootDir = imgRoot;
      }
    } on Object {
      // Best-effort temp image root creation.
    }
    if (_closed) {
      await _cleanupSessionArtifactsOnClose();
      return null;
    }

    final latestSettingsJson = jsonEncode(
      buildSessionSettings(launch, switches: _switches),
    );
    final args = _buildArguments();
    final procEnv = buildProcessEnvironment(
      baseEnvironment: environment,
      model: _model,
      maxContextTokens: _maxContextTokens,
    );
    final process = await Process.start(
      executable,
      args,
      workingDirectory: launch.cwd,
      environment: procEnv,
    );
    if (_closed) {
      await _terminateProcessTree(process);
      await _awaitProcessExitBounded(process);
      await _cleanupSessionArtifactsOnClose();
      return null;
    }
    _process = process;
    _completedToolSteps.clear();
    _spawnedModel = _model;
    _spawnedModeFlag = _effectiveModeFlag;
    _spawnedEffort = _effort;
    _spawnedContextTokens = _maxContextTokens;
    _spawnedSettingsJson = latestSettingsJson;

    _stdoutSub = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          (line) => _activeTurn?.handleLine(line),
          onError: (Object e) => _activeTurn?.handleStderr('$e'),
        );
    _stderrSub = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          (line) => _activeTurn?.handleStderr(line),
          onError: (Object e) => _activeTurn?.handleStderr('$e'),
        );

    unawaited(
      process.exitCode.then((code) {
        if (identical(_process, process)) {
          _process = null;
          unawaited(_stdoutSub?.cancel());
          unawaited(_stderrSub?.cancel());
          _stdoutSub = null;
          _stderrSub = null;
          _activeTurn?.handleProcessExit(code);
        }
      }),
    );

    return (process: process, reused: false);
  }

  Future<void> _stopProcess({bool notifyActiveTurn = false}) {
    final proc = _process;
    _process = null;
    final outSub = _stdoutSub;
    final errSub = _stderrSub;
    _stdoutSub = null;
    _stderrSub = null;
    if (proc == null && outSub == null && errSub == null) {
      if (notifyActiveTurn) {
        _activeTurn?.handleProcessExit(-1);
      }
      return Future.value();
    }
    final future = _trackCleanup(
      _runStopProcess(
        proc: proc,
        outSub: outSub,
        errSub: errSub,
        notifyActiveTurn: notifyActiveTurn,
      ),
    );
    _pendingStops.add(future);
    unawaited(
      future.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
        _pendingStops.remove(future);
      }),
    );
    return future;
  }

  Future<void> _runStopProcess({
    required Process? proc,
    required StreamSubscription<String>? outSub,
    required StreamSubscription<String>? errSub,
    required bool notifyActiveTurn,
  }) async {
    if (proc != null) {
      await _terminateProcessTree(proc);
      await _awaitProcessExitBounded(proc);
    }
    await outSub?.cancel();
    await errSub?.cancel();
    if (notifyActiveTurn) {
      _activeTurn?.handleProcessExit(-1);
    }
  }

  Future<void> _drainTurnQueue() async {
    if (_drainingTurns) return;
    _drainingTurns = true;
    try {
      while (!_closed && _pendingTurns.isNotEmpty) {
        final next = _pendingTurns.removeAt(0);
        _activeTurnUuid = next.uuid;
        try {
          await _runUserTurn(next.message);
        } on Object {
          // _runUserTurn emits error events; continue draining queued turns.
        } finally {
          _activeTurnUuid = null;
        }
      }
    } finally {
      _drainingTurns = false;
    }
  }

  Future<void> _runUserTurn(Map<String, Object?> userMessage) async {
    if (_closed) return;
    var prompt = await _extractPrompt(userMessage);
    if (_closed || prompt.trim().isEmpty) return;

    if (userMessage['uuid'] case final String commandUuid
        when commandUuid.isNotEmpty) {
      _emit({
        'type': 'command_lifecycle',
        'command_uuid': commandUuid,
        'state': 'started',
      });
    }

    if (prompt.trim() == '/clear') {
      _cancelSdkCalls();
      _cancelHookCallbacks();
      await _stopProcess();
      _agyConversationId = null;
      _sessionId = null;
      _sessionLog = null;
      _pendingCustomTitle = null;
      _needsHistorySeed = false;
      _completedToolSteps.clear();
      _activeTurn = null;
      _lastContextTokens = 0;
      _fileIndexCache = null;
      await _cleanupTempImages();
      _sdkBridge?.updateSessionId(null);
      _emit({
        'type': 'result',
        'subtype': 'success',
        'is_error': false,
        'result': '',
        'duration_ms': 0,
      });
      _emit({
        'type': 'system',
        'subtype': 'session_state_changed',
        'state': 'idle',
      });
      return;
    }

    final isManualCompact =
        prompt.trim() == '/compact' || prompt.trim().startsWith('/compact ');
    final preTurnContextTokens = _lastContextTokens;

    if (_needsHistorySeed && _sessionLog != null) {
      _needsHistorySeed = false;
      final priorSummary = _sessionLog!.buildRecentContextSummary();
      if (priorSummary.isNotEmpty) {
        prompt =
            '<CONVERSATION_CONTEXT>\n'
            'Previous turns in this session before switching to Antigravity CLI:\n'
            '$priorSummary\n'
            '</CONVERSATION_CONTEXT>\n\n'
            '$prompt';
      }
    }

    final turnId = ++_turnCounter;
    final turnStartedAt = _now();
    _interrupted = false;
    _activeTurnUuid = switch (userMessage['uuid']) {
      final String id when id.isNotEmpty => id,
      _ => null,
    };

    Map<String, Object?>? pendingUserRecord = {
      'type': 'user',
      'message': userMessage['message'],
      'timestamp': turnStartedAt.toUtc().toIso8601String(),
      if (userMessage['uuid'] case final String id when id.isNotEmpty)
        'uuid': id,
    };
    if (_sessionLog != null) {
      _sessionLog!.append(pendingUserRecord);
      pendingUserRecord = null;
    }

    _emit({
      'type': 'system',
      'subtype': 'session_state_changed',
      'state': 'working',
    });

    final turn = _ActiveTurn(
      transport: this,
      turnId: turnId,
      startedAt: turnStartedAt,
      onConversationBound: (convId) {
        _bindConversationId(convId);
        if (pendingUserRecord != null && _sessionLog != null) {
          _sessionLog!.append(pendingUserRecord!);
          pendingUserRecord = null;
        }
      },
    );
    _activeTurn = turn;

    final payload = jsonEncode({
      'event': 'user',
      'message': {'role': 'user', 'content': prompt},
    });

    Future<bool> runOnce(_ActiveTurn active) async {
      if (_closed) return false;
      _activeTurn = active;
      final ensured = await _ensureProcess();
      if (ensured == null || _closed) {
        if (identical(_activeTurn, active)) _activeTurn = null;
        return false;
      }
      var (:process, :reused) = ensured;
      active.reusedProcess = reused;
      try {
        process.stdin.writeln(payload);
        await process.stdin.flush();
      } on Object {
        if (_closed) {
          if (identical(_activeTurn, active)) _activeTurn = null;
          return false;
        }
        // Stale or closed stdin pipe on reused process; respawn once.
        await _stopProcess(notifyActiveTurn: false);
        if (_closed) {
          if (identical(_activeTurn, active)) _activeTurn = null;
          return false;
        }
        active.reusedProcess = false;
        _activeTurn = active;
        final respawned = await _ensureProcess();
        if (respawned == null || _closed) {
          if (identical(_activeTurn, active)) _activeTurn = null;
          return false;
        }
        (:process, :reused) = respawned;
        process.stdin.writeln(payload);
        await process.stdin.flush();
      }
      if (_closed) {
        if (identical(_activeTurn, active)) _activeTurn = null;
        return false;
      }
      await active.done.future;
      if (_closed) return false;
      return active.needsFreshRetry;
    }

    try {
      var active = turn;
      final retry = await runOnce(active);
      if (_closed) return;
      if (retry && !_interrupted && !_closed) {
        active = _ActiveTurn(
          transport: this,
          turnId: turnId,
          startedAt: turnStartedAt,
          onConversationBound: turn.onConversationBound,
        );
        await runOnce(active);
        if (_closed) return;
      }
      if (active.hitQuotaLimit && !_interrupted && !_closed) {
        final switched = await AntigravityAccounts.instance.tryAutoFailover(
          modelId: _model,
        );
        if (_closed) return;
        if (switched != null) {
          await _stopProcess(notifyActiveTurn: false);
          if (_closed) return;
          _emit({
            'type': 'assistant',
            'uuid': 'agy-failover-$turnId',
            'message': {
              'id': 'agy-failover-$turnId',
              'model': _model,
              'role': 'assistant',
              'content': [
                {
                  'type': 'text',
                  'text':
                      '> ⚡ 当前账号触发配额上限，已自动切换至备用账号 **${switched.email}** 继续执行。\n',
                },
              ],
            },
          });
          final failoverTurn = _ActiveTurn(
            transport: this,
            turnId: turnId,
            startedAt: turnStartedAt,
            allowAutoFailover: false,
            onConversationBound: turn.onConversationBound,
          );
          await runOnce(failoverTurn);
          if (_closed) return;
        } else {
          _emit({
            'type': 'result',
            'subtype': 'error',
            'is_error': true,
            'result': active.deferredQuotaError ?? 'Antigravity CLI 配额已达上限',
            'duration_ms': _elapsedTurnMs(turnStartedAt),
          });
        }
      }
    } on ProcessException catch (error) {
      _activeTurn = null;
      if (_closed) return;
      _emit({
        'type': 'result',
        'subtype': 'error',
        'is_error': true,
        'result': 'Antigravity CLI 启动失败：${error.message}',
        'duration_ms': _elapsedTurnMs(turnStartedAt),
      });
      _emit({
        'type': 'system',
        'subtype': 'session_state_changed',
        'state': 'idle',
      });
      return;
    } on Object catch (error) {
      _activeTurn = null;
      if (_closed) return;
      _emit({
        'type': 'result',
        'subtype': 'error',
        'is_error': true,
        'result': 'Antigravity CLI 发送消息失败：$error',
        'duration_ms': _elapsedTurnMs(turnStartedAt),
      });
      _emit({
        'type': 'system',
        'subtype': 'session_state_changed',
        'state': 'idle',
      });
      return;
    } finally {
      _activeTurnUuid = null;
      _cancelSdkCalls();
    }

    _activeTurn = null;
    if (_closed) return;

    // Refresh ground-truth context occupancy from agy's brain transcript when
    // manual /compact ran or when the turn noticeably shrunk the context.
    final convId = _agyConversationId ?? _sessionId;
    if (convId != null && convId.isNotEmpty) {
      final brain = readBrainContextTokens(convId, home: _paths.home);
      if (brain != null && brain.contextTokens > 0) {
        if (isManualCompact ||
            (preTurnContextTokens > 60000 &&
                brain.contextTokens < (preTurnContextTokens * 0.55).round())) {
          _lastContextTokens = brain.contextTokens;
          _emit({
            'type': 'system',
            'subtype': 'compact_boundary',
            'compact_metadata': {
              'trigger': isManualCompact ? 'manual' : 'auto',
              if (preTurnContextTokens > 0) 'pre_tokens': preTurnContextTokens,
              'post_tokens': _lastContextTokens,
            },
          });
        } else if (!turn.hadStepUsage) {
          _lastContextTokens = brain.contextTokens;
        }
      }
    }

    AntigravityAccounts.instance.scheduleActiveQuotaRefresh();

    _emit({
      'type': 'system',
      'subtype': 'session_state_changed',
      'state': 'idle',
    });
  }

  /// Converts an `agy` `usage` payload (`input_tokens` ALREADY includes
  /// `cache_read_tokens`) into Anthropic/Claude-compatible `usage` where
  /// `input_tokens` is uncached input and `contextTokens` is the single-step
  /// total context occupancy (`input_tokens + output_tokens`).
  static ({Map<String, Object?> usage, int contextTokens})? convertAgyUsage(
    Object? rawUsage,
  ) {
    if (rawUsage is! Map) return null;
    final inputTokens = (rawUsage['input_tokens'] as num?)?.round() ?? 0;
    final outputTokens = (rawUsage['output_tokens'] as num?)?.round() ?? 0;
    final cacheRead = (rawUsage['cache_read_tokens'] as num?)?.round() ?? 0;
    final thinkingTokens = (rawUsage['thinking_tokens'] as num?)?.round();
    final totalTokens = (rawUsage['total_tokens'] as num?)?.round() ?? 0;

    final uncachedInput = math.max(0, inputTokens - cacheRead);
    final contextTokens = totalTokens > 0
        ? totalTokens
        : (inputTokens + outputTokens);
    if (contextTokens <= 0 && cacheRead <= 0) return null;

    return (
      usage: {
        'input_tokens': uncachedInput,
        'output_tokens': outputTokens,
        if (cacheRead > 0) 'cache_read_input_tokens': cacheRead,
        if (thinkingTokens != null)
          'output_tokens_details': {'thinking_tokens': thinkingTokens},
      },
      contextTokens: contextTokens,
    );
  }

  Map<String, Object?>? _recordStepUsage(Object? rawUsage) {
    final converted = convertAgyUsage(rawUsage);
    if (converted == null) return null;
    if (converted.contextTokens > 0) {
      _lastContextTokens = converted.contextTokens;
    }
    return converted.usage;
  }

  Map<String, Object?>? _recordResultUsage(
    Object? rawUsage, {
    required bool hadStepUsage,
  }) {
    final converted = convertAgyUsage(rawUsage);
    if (converted == null) return null;
    // `result.usage` is cumulative across all tool steps in a multi-step turn;
    // only use it as context occupancy when no single-step `step.usage` arrived.
    if (!hadStepUsage && converted.contextTokens > 0) {
      _lastContextTokens = converted.contextTokens;
    }
    return converted.usage;
  }

  /// Reads the latest single-step context window occupancy from `agy`'s native
  /// `~/.gemini/antigravity-cli/brain/<sessionId>/.system_generated/logs/transcript.jsonl`.
  static ({
    int inputTokens,
    int outputTokens,
    int cacheReadTokens,
    int contextTokens,
    bool fromCompaction,
  })?
  readBrainContextTokens(String sessionId, {String? home}) {
    if (sessionId.isEmpty) return null;
    final resolvedHome =
        home ??
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    if (resolvedHome.isEmpty) return null;
    final file = File(
      p.join(
        resolvedHome,
        '.gemini',
        'antigravity-cli',
        'brain',
        sessionId,
        '.system_generated',
        'logs',
        'transcript.jsonl',
      ),
    );
    if (!file.existsSync()) return null;
    try {
      final length = file.lengthSync();
      if (length <= 0) return null;
      const maxTailBytes = 256 * 1024;
      final String content;
      if (length <= maxTailBytes) {
        content = const Utf8Decoder(allowMalformed: true).convert(
          file.readAsBytesSync(),
        );
      } else {
        final raf = file.openSync();
        try {
          raf.setPositionSync(length - maxTailBytes);
          final bytes = raf.readSync(maxTailBytes);
          content = const Utf8Decoder(allowMalformed: true).convert(bytes);
        } finally {
          raf.closeSync();
        }
      }
      final lines = const LineSplitter().convert(content);
      final startIdx = length > maxTailBytes && lines.length > 1 ? 1 : 0;
      for (var i = lines.length - 1; i >= startIdx; i--) {
        final trimmed = lines[i].trim();
        if (trimmed.isEmpty) continue;
        try {
          final decoded = jsonDecode(trimmed);
          if (decoded is! Map) continue;
          final type = decoded['type'];
          if (type is! String) continue;
          if (type == 'PLANNER_RESPONSE') {
            final inputTokens = (decoded['input_tokens'] as num?)?.round() ?? 0;
            final outputTokens = (decoded['output_tokens'] as num?)?.round() ?? 0;
            final cacheRead =
                (decoded['cache_read_tokens'] as num?)?.round() ?? 0;
            final contextTokens = inputTokens + outputTokens;
            if (contextTokens > 0) {
              return (
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheRead,
                contextTokens: contextTokens,
                fromCompaction: false,
              );
            }
          } else if (type == 'CHECKPOINT') {
            final summaryText = '${decoded['content'] ?? ''}';
            final summaryTokens = (summaryText.length / 3.8).round() + 27800;
            return (
              inputTokens: summaryTokens,
              outputTokens: 0,
              cacheReadTokens: 0,
              contextTokens: summaryTokens,
              fromCompaction: true,
            );
          }
        } on Object {
          continue;
        }
      }
    } on Object {
      // Ignore transient file read errors.
    }
    return null;
  }

  /// Normalizes `tool_info.parameters` where `agy` serializes each map value
  /// as a JSON-encoded string (e.g. `"\"/path/to/file\""` or `"100"`).
  static Map<String, Object?> normalizeToolParams(
    Map<String, Object?> rawParams,
  ) {
    final out = <String, Object?>{};
    for (final MapEntry(:key, :value) in rawParams.entries) {
      out[key] = _decodeParamValue(value);
    }
    return out;
  }

  static Object? _decodeParamValue(Object? value) {
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isNotEmpty) {
        try {
          return jsonDecode(trimmed);
        } on FormatException {
          return value;
        }
      }
    }
    return value;
  }

  /// Strips verbose `Created At:` / `Completed At:` headers from `agy` tool
  /// outputs so tool cards in Ayte look clean.
  static String cleanToolOutput(String rawName, String output) {
    var cleaned = output.replaceAll('\r\n', '\n');
    cleaned = cleaned.replaceFirst(
      RegExp(r'^Created At: [^\n]+\n(?:Completed At: [^\n]+\n)?'),
      '',
    );
    if (rawName == 'run_command' || rawName == 'execute_command') {
      cleaned = cleaned.replaceFirst(
        RegExp(r'^Command exited with code 0\.\n+(?:Command output:\n)?'),
        '',
      );
    }
    return cleaned.trim();
  }

  /// Normalizes MCP tool names from `agy` (`mcp_baocode_<tool>`,
  /// `baocode:<tool>`, `baocode.<tool>`, `baocode/<tool>`, `baocode__<tool>`,
  /// `mcp__baocode__<tool>`, or a bare registered [ClaudeSdkTools] name) to
  /// canonical `mcp__baocode__<tool>` for [ClaudeTranslator] and [ClaudeSdkTools.called].
  static String normalizeMcpToolName(
    String rawName, {
    String? serverName,
  }) {
    final trimmed = rawName.trim();
    if (trimmed.isEmpty) return trimmed;
    const canonicalPrefix = 'mcp__${ClaudeSdkTools.server}__';
    if (trimmed.startsWith(canonicalPrefix)) return trimmed;

    const agyEagerPrefix = 'mcp_${ClaudeSdkTools.server}_';
    if (trimmed.startsWith(agyEagerPrefix)) {
      final tool = trimmed.substring(agyEagerPrefix.length);
      if (tool.isNotEmpty) return '$canonicalPrefix$tool';
    }

    for (final sep in const [':', '__', '.', '/']) {
      final prefix = '${ClaudeSdkTools.server}$sep';
      if (trimmed.startsWith(prefix)) {
        final tool = trimmed.substring(prefix.length);
        if (tool.isNotEmpty) return '$canonicalPrefix$tool';
      }
    }

    if (serverName == ClaudeSdkTools.server && !trimmed.startsWith('mcp__')) {
      return '$canonicalPrefix$trimmed';
    }

    if (ClaudeSdkTools.hasTool(trimmed)) {
      return '$canonicalPrefix$trimmed';
    }
    return trimmed;
  }

  /// Maps an Antigravity CLI tool call (`read_file`, `edit_file`, `write_file`,
  /// `run_command`, `grep_search`, `find_by_name`, `call_mcp_tool`, etc.) to
  /// Claude Code's tool schema so `ClaudeTranslator` renders rich native cards
  /// and diffs.
  static ({
    String name,
    Map<String, Object?> input,
    Map<String, Object?>? structuredResult,
  })
  mapTool(
    String rawName,
    Map<String, Object?> rawParams,
    String output, {
    String defaultCwd = '',
    String? serverName,
  }) {
    final params = normalizeToolParams(rawParams);

    String? str(String key) => switch (params[key]) {
      final String s when s.isNotEmpty => s,
      _ => null,
    };

    int? numInt(String key) => switch (params[key]) {
      final num n => n.round(),
      final String s => int.tryParse(s.trim()),
      _ => null,
    };

    final trimmedName = rawName.trim();
    if (trimmedName == 'call_mcp_tool') {
      final srv =
          (str('ServerName') ??
                  str('serverName') ??
                  str('server_name') ??
                  serverName ??
                  '')
              .trim();
      final tool =
          (str('ToolName') ?? str('toolName') ?? str('tool_name') ?? '').trim();
      final rawArgs =
          params['Arguments'] ?? params['arguments'] ?? params['args'];
      final Map<String, Object?> unwrappedArgs;
      if (rawArgs is Map) {
        unwrappedArgs = rawArgs.cast<String, Object?>();
      } else if (rawArgs is String && rawArgs.trim().isNotEmpty) {
        Object? decoded;
        try {
          decoded = jsonDecode(rawArgs.trim());
        } on FormatException {
          decoded = null;
        }
        unwrappedArgs = decoded is Map
            ? decoded.cast<String, Object?>()
            : <String, Object?>{};
      } else {
        unwrappedArgs = <String, Object?>{};
      }

      if (tool.isNotEmpty) {
        if (srv == ClaudeSdkTools.server ||
            (srv.isEmpty && ClaudeSdkTools.hasTool(tool))) {
          return (
            name: normalizeMcpToolName(tool, serverName: ClaudeSdkTools.server),
            input: unwrappedArgs,
            structuredResult: null,
          );
        }
        final canonicalName = srv.isNotEmpty ? 'mcp__${srv}__$tool' : tool;
        return (
          name: canonicalName,
          input: unwrappedArgs,
          structuredResult: null,
        );
      }
    }

    final normalizedMcp = normalizeMcpToolName(
      trimmedName,
      serverName: serverName,
    );
    if (normalizedMcp != trimmedName || normalizedMcp.startsWith('mcp__')) {
      return (
        name: normalizedMcp,
        input: params,
        structuredResult: null,
      );
    }

    switch (trimmedName) {
      case 'read_file' || 'view_file' || 'view_file_outline' || 'view_code_item':
        final filePath =
            str('Path') ??
            str('AbsolutePath') ??
            str('FilePath') ??
            str('path') ??
            '';
        final start = numInt('StartLine');
        final end = numInt('EndLine');
        return (
          name: 'Read',
          input: {
            'file_path': filePath,
            if (start != null && end != null && end >= start) ...{
              'offset': start,
              'limit': end - start + 1,
            },
          },
          structuredResult: null,
        );

      case 'write_file' || 'write_to_file' || 'create_file':
        final filePath =
            str('Path') ??
            str('TargetFile') ??
            str('FilePath') ??
            str('path') ??
            '';
        final content =
            str('Content') ?? str('CodeContent') ?? str('content') ?? '';
        return (
          name: 'Write',
          input: {'file_path': filePath, 'content': content},
          structuredResult: filePath.isNotEmpty && content.isNotEmpty
              ? {
                  'type': 'create',
                  'filePath': filePath,
                  'content': content,
                }
              : null,
        );

      case 'edit_file' || 'replace_file_content':
        final filePath =
            str('Path') ??
            str('TargetFile') ??
            str('FilePath') ??
            str('path') ??
            '';
        final oldStr = str('Target') ?? str('TargetContent') ?? '';
        final newStr = str('Replacement') ?? str('ReplacementContent') ?? '';
        return (
          name: 'Edit',
          input: {
            'file_path': filePath,
            'old_string': oldStr,
            'new_string': newStr,
          },
          structuredResult: filePath.isNotEmpty &&
                  (oldStr.isNotEmpty || newStr.isNotEmpty)
              ? {
                  'filePath': filePath,
                  'structuredPatch': [
                    _buildHunk(oldStr, newStr),
                  ],
                }
              : null,
        );

      case 'multi_replace_file_content':
        final filePath =
            str('Path') ??
            str('TargetFile') ??
            str('FilePath') ??
            str('path') ??
            '';
        final chunks = params['ReplacementChunks'];
        final edits = <Map<String, Object?>>[];
        final hunks = <Map<String, Object?>>[];
        if (chunks is List) {
          for (final rawChunk in chunks) {
            if (rawChunk is Map) {
              final oldStr = '${rawChunk['TargetContent'] ?? ''}';
              final newStr = '${rawChunk['ReplacementContent'] ?? ''}';
              final startLine = switch (rawChunk['StartLine']) {
                final num n => n.round(),
                final String s => int.tryParse(s.trim()) ?? 1,
                _ => 1,
              };
              edits.add({'old_string': oldStr, 'new_string': newStr});
              hunks.add(_buildHunk(oldStr, newStr, startLine: startLine));
            }
          }
        }
        return (
          name: 'MultiEdit',
          input: {'file_path': filePath, 'edits': edits},
          structuredResult: filePath.isNotEmpty && hunks.isNotEmpty
              ? {'filePath': filePath, 'structuredPatch': hunks}
              : null,
        );

      case 'run_command' || 'execute_command':
        final cmd =
            str('CommandLine') ?? str('Command') ?? str('command') ?? '';
        final desc = str('toolSummary') ?? str('Description');
        return (
          name: 'Bash',
          input: {
            'command': cmd,
            'description': ?desc,
          },
          structuredResult: {'stdout': output, 'stderr': ''},
        );

      case 'manage_task' || 'command_status':
        final action = str('Action') ?? 'status';
        final taskId = str('TaskId') ?? str('CommandId') ?? '';
        final cmdDesc = taskId.isNotEmpty
            ? 'manage_task $action ($taskId)'
            : 'manage_task $action';
        return (
          name: 'Bash',
          input: {
            'command': cmdDesc,
            'description': 'Manage background task ($action)',
          },
          structuredResult: {'stdout': output, 'stderr': ''},
        );

      case 'grep_search' || 'ripgrep':
        final pattern =
            str('Query') ?? str('Pattern') ?? str('pattern') ?? '';
        return (
          name: 'Grep',
          input: {'pattern': pattern},
          structuredResult: null,
        );

      case 'find_by_name':
        final pattern =
            str('Pattern') ?? str('Query') ?? str('pattern') ?? '*';
        return (
          name: 'Glob',
          input: {'pattern': pattern},
          structuredResult: null,
        );

      case 'list_dir' || 'list_directory' || 'list_files':
        final dirPath =
            str('DirectoryPath') ??
            str('Path') ??
            str('path') ??
            defaultCwd;
        return (
          name: 'LS',
          input: {'path': dirPath},
          structuredResult: null,
        );

      case 'search_web':
        final query = str('query') ?? str('Query') ?? '';
        return (
          name: 'WebSearch',
          input: {'query': query},
          structuredResult: null,
        );

      case 'read_url_content':
        final url = str('Url') ?? str('url') ?? '';
        return (
          name: 'WebFetch',
          input: {'url': url},
          structuredResult: null,
        );

      case 'exit_plan_mode' || 'ExitPlanMode':
        final planFile =
            str('planFilePath') ??
            str('PlanFilePath') ??
            str('file_path') ??
            str('Path') ??
            str('FilePath') ??
            str('path');
        final planText =
            str('plan') ?? str('Plan') ?? str('Content') ?? str('content');
        return (
          name: 'ExitPlanMode',
          input: {
            'planFilePath': ?planFile,
            'plan': ?planText,
          },
          structuredResult: null,
        );

      case 'enter_plan_mode' || 'EnterPlanMode':
        return (
          name: 'EnterPlanMode',
          input: params,
          structuredResult: null,
        );

      case 'invoke_subagent' || 'browser_subagent':
        final desc = str('Role') ?? str('TaskName') ?? rawName;
        final subType = str('TypeName') ?? rawName;
        final prompt = str('Prompt') ?? str('Task') ?? '';
        return (
          name: 'Agent',
          input: {
            'description': desc,
            'subagent_type': subType,
            'prompt': prompt,
          },
          structuredResult: null,
        );

      default:
        return (name: rawName, input: params, structuredResult: null);
    }
  }

  static Map<String, Object?> _buildHunk(
    String oldStr,
    String newStr, {
    int startLine = 1,
  }) {
    final oldLines = oldStr.isEmpty ? const <String>[] : oldStr.split('\n');
    final newLines = newStr.isEmpty ? const <String>[] : newStr.split('\n');
    return {
      'oldStart': startLine,
      'oldLines': oldLines.length,
      'newStart': startLine,
      'newLines': newLines.length,
      'lines': [
        for (final l in oldLines) '-$l',
        for (final l in newLines) '+$l',
      ],
    };
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _interrupted = true;
    _pendingTurns.clear();
    _cancelSdkCalls();
    _cancelHookCallbacks();
    _cleanupTempImagesSync();

    final hasArtifacts =
        _sdkBridge != null ||
        _sessionConfigDir != null ||
        _pendingSessionConfigDirs.isNotEmpty;
    if (_sdkBridge != null || _sessionConfigDir != null) {
      unawaited(_trackCleanup(_cleanupSessionArtifactsOnClose()));
    }

    final hasProcessWork =
        _process != null || _stdoutSub != null || _stderrSub != null;
    if (hasProcessWork) {
      unawaited(_stopProcess(notifyActiveTurn: true));
    } else {
      _activeTurn?.handleProcessExit(-1);
    }

    final hasPendingWork =
        hasArtifacts ||
        hasProcessWork ||
        _inFlightSpawns.isNotEmpty ||
        _pendingCleanups.isNotEmpty ||
        _inFlightImageWrites.isNotEmpty ||
        _tempImageDirs.isNotEmpty;

    if (!hasPendingWork) {
      _live.remove(this);
      if (!_messages.isClosed) {
        _messages
          ..add(ClaudeExit.message(0, '', executable: executable))
          ..close();
      }
      if (!_exited.isCompleted) {
        _exited.complete();
      }
      return;
    }

    _closeCleanupFuture ??= _finalizeClose();
  }
}

/// Manages streaming events for a single user turn on [AntigravityTransport]'s
/// persistent `agy` process.
class _ActiveTurn {
  _ActiveTurn({
    required this.transport,
    required this.turnId,
    required this.startedAt,
    required this.onConversationBound,
    this.allowAutoFailover = true,
  });

  final AntigravityTransport transport;
  final int turnId;
  final DateTime startedAt;
  final void Function(String convId) onConversationBound;
  final bool allowAutoFailover;
  final Completer<void> done = Completer<void>();

  final List<String> stderrLines = [];
  bool gotResult = false;
  bool gotError = false;
  bool _finalizingResult = false;
  bool hitQuotaLimit = false;
  String? deferredQuotaError;
  bool receivedAnyEvent = false;
  bool reusedProcess = false;
  bool needsFreshRetry = false;
  bool streamedAnyResponse = false;
  bool hadStepUsage = false;
  Map<String, Object?>? pendingSilentStepUsage;
  String? lastToolError;
  String? unansweredPermissionError;
  bool sawExitPlanMode = false;
  String? lastPlanPath;
  String? lastPlanContent;

  final Map<int, bool> _stepPreHookSent = {};
  final Map<int, bool> _stepPostHookSent = {};
  Future<void> _hookChain = Future<void>.value();
  int _pendingHooks = 0;
  bool _hooksCancelled = false;

  void cancelHooks() {
    _hooksCancelled = true;
  }

  void _enqueueHook(Future<void> Function() action) {
    if (_hooksCancelled || transport._closed || transport._interrupted) {
      return;
    }
    _pendingHooks++;
    _hookChain = _hookChain
        .then((_) {
          if (_hooksCancelled ||
              transport._closed ||
              transport._interrupted) {
            return Future<void>.value();
          }
          return action();
        })
        .catchError((Object _) {})
        .whenComplete(() {
          _pendingHooks--;
        });
  }

  static bool _isEditHookTool(String mappedName) => const {
    'Edit',
    'Write',
    'MultiEdit',
    'NotebookEdit',
  }.contains(mappedName);

  static String? _editTargetPath(Map<String, Object?> input) {
    final raw = input['file_path'] ?? input['notebook_path'];
    return raw is String && raw.isNotEmpty ? raw : null;
  }

  bool _isPlanFilePath(String path) =>
      ClaudeTranslator.isPlanPath(path) ||
      (transport._permissionMode == 'plan' &&
          p.basename(path).toLowerCase() == 'implementation_plan.md');

  final Map<int, bool> stepThinkingStarted = {};
  final Map<int, bool> stepThinkingStopped = {};
  final Map<int, bool> stepTextStarted = {};
  final Map<int, bool> stepTextStopped = {};
  final Map<int, bool> stepMessageStarted = {};
  final Map<int, bool> stepMessageStopped = {};
  final Map<int, StringBuffer> stepThinkingBuffer = {};
  final Map<int, StringBuffer> stepTextBuffer = {};
  final Map<int, Map<String, Object?>> stepUsage = {};
  final Map<int, bool> toolEmittedActive = {};
  final Map<int, bool> toolEmittedDone = {};
  final Map<
    int,
    ({
      String toolId,
      String rawName,
      String mappedName,
      Map<String, Object?> input,
      String output,
      Map<String, Object?>? structuredResult,
      bool isError,
    })
  >
  toolLatest = {};

  void _emitAndLog(Map<String, Object?> message, {bool persist = false}) {
    transport._emit(message);
    if (persist) {
      transport._sessionLog?.append(message);
    }
  }

  void ensureMessageStarted(int stepIndex) {
    if (stepMessageStarted[stepIndex] == true) return;
    stepMessageStarted[stepIndex] = true;
    transport._emit({
      'type': 'stream_event',
      'event': {
        'type': 'message_start',
        'message': {
          'id': 'agy-$turnId-$stepIndex',
          'model': transport._model,
          'usage': const <String, Object?>{},
        },
      },
    });
  }

  void finishStepMessage(int stepIndex) {
    if (stepMessageStarted[stepIndex] != true ||
        stepMessageStopped[stepIndex] == true) {
      return;
    }
    stepMessageStopped[stepIndex] = true;
    if (stepThinkingStarted[stepIndex] == true &&
        stepThinkingStopped[stepIndex] != true) {
      stepThinkingStopped[stepIndex] = true;
      transport._emit({
        'type': 'stream_event',
        'event': {'type': 'content_block_stop', 'index': 0},
      });
    }
    if (stepTextStarted[stepIndex] == true &&
        stepTextStopped[stepIndex] != true) {
      stepTextStopped[stepIndex] = true;
      transport._emit({
        'type': 'stream_event',
        'event': {'type': 'content_block_stop', 'index': 1},
      });
    }
    transport._emit({
      'type': 'stream_event',
      'event': {'type': 'message_stop'},
    });

    final fullThinking = stepThinkingBuffer[stepIndex]?.toString() ?? '';
    final fullText = stepTextBuffer[stepIndex]?.toString() ?? '';
    final usage = stepUsage[stepIndex];
    if (identical(pendingSilentStepUsage, usage)) {
      pendingSilentStepUsage = null;
    }
    _emitAndLog({
      'type': 'assistant',
      'uuid': 'agy-msg-$turnId-$stepIndex',
      'message': {
        'id': 'agy-$turnId-$stepIndex',
        'model': transport._model,
        'role': 'assistant',
        'content': [
          if (fullThinking.isNotEmpty)
            {'type': 'thinking', 'thinking': fullThinking},
          if (fullText.isNotEmpty) {'type': 'text', 'text': fullText},
        ],
        'usage': ?usage,
      },
    }, persist: true);
  }

  void completeToolStep(int stepIndex) {
    if (toolEmittedDone[stepIndex] == true) return;
    final info = toolLatest[stepIndex];
    if (info == null) return;
    toolEmittedDone[stepIndex] = true;
    transport._completedToolSteps.add(stepIndex);

    final isPlanExitInPlanMode =
        info.mappedName == 'ExitPlanMode' &&
        transport._permissionMode == 'plan';
    if (info.mappedName == 'ExitPlanMode') {
      sawExitPlanMode = true;
    }

    if (_isEditHookTool(info.mappedName)) {
      final path = _editTargetPath(info.input);
      if (path != null && _isPlanFilePath(path)) {
        if (!info.isError) {
          lastPlanPath = path;
          if (info.mappedName == 'Write') {
            if (info.input['content'] case final String text
                when text.isNotEmpty) {
              lastPlanContent = text;
            }
          } else {
            lastPlanContent = null;
          }
        }
      } else if (path != null && _stepPostHookSent[stepIndex] != true) {
        _stepPostHookSent[stepIndex] = true;
        final postEvent = info.isError ? 'PostToolUseFailure' : 'PostToolUse';
        final hasPre =
            _stepPreHookSent[stepIndex] != true &&
            transport
                ._matchingHookCallbackIds('PreToolUse', info.mappedName)
                .isNotEmpty;
        final hasPost = transport
            ._matchingHookCallbackIds(postEvent, info.mappedName)
            .isNotEmpty;
        if (hasPre) {
          _stepPreHookSent[stepIndex] = true;
          _enqueueHook(
            () => transport._dispatchEditHooks(
              'PreToolUse',
              toolName: info.mappedName,
              toolInput: info.input,
              toolUseId: info.toolId,
              isCancelled: () => _hooksCancelled,
            ),
          );
        }
        if (hasPost) {
          _enqueueHook(
            () => transport._dispatchEditHooks(
              postEvent,
              toolName: info.mappedName,
              toolInput: info.input,
              toolUseId: info.toolId,
              isCancelled: () => _hooksCancelled,
            ),
          );
        }
      }
    }

    final resultContent = isPlanExitInPlanMode
        ? ClaudeTranslator.planPresented
        : info.output;
    final resultIsError = isPlanExitInPlanMode ? true : info.isError;

    _emitAndLog({
      'type': 'user',
      'uuid': 'agy-tool-res-$turnId-$stepIndex',
      'message': {
        'role': 'user',
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': info.toolId,
            'content': resultContent,
            'is_error': resultIsError,
          },
        ],
      },
      if (!resultIsError && info.structuredResult != null)
        'tool_use_result': info.structuredResult,
    }, persist: true);
  }

  void settleEarlierSteps(int currentStepIndex) {
    for (final prevIdx in [...stepMessageStarted.keys]) {
      if (prevIdx < currentStepIndex) {
        finishStepMessage(prevIdx);
      }
    }
    for (final prevIdx in [...toolEmittedActive.keys]) {
      if (prevIdx < currentStepIndex && toolEmittedDone[prevIdx] != true) {
        completeToolStep(prevIdx);
      }
    }
  }

  void handleStepUpdate(Map<String, Object?> step) {
    if (step['conversation_id'] case final String convId
        when convId.isNotEmpty) {
      onConversationBound(convId);
    }
    final stepIndex = (step['step_index'] as num?)?.round() ?? 0;
    final state = step['state'] as String? ?? '';
    final stepType = step['step_type'] as String? ?? '';

    settleEarlierSteps(stepIndex);

    if (stepType == 'agent_response') {
      final thinkingDelta = step['thinking_delta'] as String? ?? '';
      final textDelta = step['text_delta'] as String? ?? '';
      final usage = transport._recordStepUsage(step['usage']);
      if (usage != null) {
        hadStepUsage = true;
        stepUsage[stepIndex] = usage;
        pendingSilentStepUsage = usage;
      }

      if (thinkingDelta.isNotEmpty) {
        ensureMessageStarted(stepIndex);
        if (stepThinkingStarted[stepIndex] != true) {
          stepThinkingStarted[stepIndex] = true;
          stepThinkingBuffer[stepIndex] = StringBuffer();
          transport._emit({
            'type': 'stream_event',
            'event': {
              'type': 'content_block_start',
              'index': 0,
              'content_block': const {'type': 'thinking'},
            },
          });
        }
        stepThinkingBuffer[stepIndex]!.write(thinkingDelta);
        transport._emit({
          'type': 'stream_event',
          'event': {
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'thinking_delta', 'thinking': thinkingDelta},
          },
        });
      }

      if (textDelta.isNotEmpty) {
        streamedAnyResponse = true;
        unansweredPermissionError = null;
        ensureMessageStarted(stepIndex);
        if (stepThinkingStarted[stepIndex] == true &&
            stepThinkingStopped[stepIndex] != true) {
          stepThinkingStopped[stepIndex] = true;
          transport._emit({
            'type': 'stream_event',
            'event': {'type': 'content_block_stop', 'index': 0},
          });
        }
        if (stepTextStarted[stepIndex] != true) {
          stepTextStarted[stepIndex] = true;
          stepTextBuffer[stepIndex] = StringBuffer();
          transport._emit({
            'type': 'stream_event',
            'event': {
              'type': 'content_block_start',
              'index': 1,
              'content_block': const {'type': 'text'},
            },
          });
        }
        stepTextBuffer[stepIndex]!.write(textDelta);
        transport._emit({
          'type': 'stream_event',
          'event': {
            'type': 'content_block_delta',
            'index': 1,
            'delta': {'type': 'text_delta', 'text': textDelta},
          },
        });
      }

      if (usage != null && stepMessageStarted[stepIndex] == true) {
        transport._emit({
          'type': 'stream_event',
          'event': {'type': 'message_delta', 'usage': usage},
        });
      }

      if (state == 'DONE') {
        finishStepMessage(stepIndex);
      }
    } else if (stepType == 'tool' || stepType == 'subagent') {
      if (transport._completedToolSteps.contains(stepIndex) ||
          toolEmittedDone[stepIndex] == true) {
        return;
      }
      final toolInfo = (step['tool_info'] as Map?)?.cast<String, Object?>();
      final subagentInfo =
          (step['subagent_info'] as Map?)?.cast<String, Object?>();
      final rawName =
          (toolInfo?['name'] as String?) ??
          (step['tool_name'] as String?) ??
          (subagentInfo != null ? 'invoke_subagent' : 'tool');
      final serverName =
          (toolInfo?['server_name'] as String?) ??
          (toolInfo?['serverName'] as String?) ??
          (step['server_name'] as String?) ??
          (step['serverName'] as String?);
      final rawParams =
          (toolInfo?['parameters'] as Map?)?.cast<String, Object?>() ??
          (subagentInfo ?? const <String, Object?>{});

      final isError = state == 'ERROR' || state == 'FAILED';
      final rawOutputStr = '${toolInfo?['output'] ?? ''}'.trim();
      final rawErrorStr =
          '${toolInfo?['error'] ?? step['error'] ?? ''}'.trim();
      final combinedRaw = isError && rawErrorStr.isNotEmpty
          ? (rawOutputStr.isNotEmpty
                ? '$rawErrorStr\n$rawOutputStr'
                : rawErrorStr)
          : rawOutputStr;
      final cleanedOutput = AntigravityTransport.cleanToolOutput(
        rawName,
        combinedRaw,
      );
      if (isError && cleanedOutput.isNotEmpty) {
        lastToolError = cleanedOutput;
        if (_isPermissionDenialError(cleanedOutput)) {
          unansweredPermissionError = cleanedOutput;
        }
      }

      final mapped = AntigravityTransport.mapTool(
        rawName,
        rawParams,
        cleanedOutput,
        defaultCwd: transport.launch.cwd,
        serverName: serverName,
      );
      final toolId = 'agy-tool-$turnId-$stepIndex';

      toolLatest[stepIndex] = (
        toolId: toolId,
        rawName: rawName,
        mappedName: mapped.name,
        input: mapped.input,
        output: cleanedOutput,
        structuredResult: mapped.structuredResult,
        isError: isError,
      );

      if (toolEmittedActive[stepIndex] != true) {
        toolEmittedActive[stepIndex] = true;
        if (mapped.name == 'ExitPlanMode') {
          sawExitPlanMode = true;
        } else if (_isEditHookTool(mapped.name)) {
          final path = _editTargetPath(mapped.input);
          if (path != null && !_isPlanFilePath(path)) {
            if (transport
                ._matchingHookCallbackIds('PreToolUse', mapped.name)
                .isNotEmpty) {
              _stepPreHookSent[stepIndex] = true;
              _enqueueHook(
                () => transport._dispatchEditHooks(
                  'PreToolUse',
                  toolName: mapped.name,
                  toolInput: mapped.input,
                  toolUseId: toolId,
                  isCancelled: () => _hooksCancelled,
                ),
              );
            }
          }
        }
        final attachedUsage = pendingSilentStepUsage;
        pendingSilentStepUsage = null;
        _emitAndLog({
          'type': 'assistant',
          'uuid': 'agy-tool-msg-$turnId-$stepIndex',
          'message': {
            'id': 'agy-tool-msg-$turnId-$stepIndex',
            'model': transport._model,
            'role': 'assistant',
            'content': [
              {
                'type': 'tool_use',
                'id': toolId,
                'name': mapped.name,
                'input': mapped.input,
              },
            ],
            'usage': ?attachedUsage,
          },
        }, persist: true);
      }

      final isBackgroundedDaemon = rawOutputStr.contains(
        'Tool is running as a background task',
      );
      if (state == 'DONE' || isError || isBackgroundedDaemon) {
        completeToolStep(stepIndex);
      }
    }
  }

  void handleLine(String line) {
    if (done.isCompleted) return;
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;
    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      stderrLines.add(trimmed);
      return;
    }
    if (decoded is! Map) return;
    final event = decoded.cast<String, Object?>();
    receivedAnyEvent = true;
    switch (event['event']) {
      case 'init':
        if (event['conversation_id'] case final String convId
            when convId.isNotEmpty) {
          onConversationBound(convId);
        }
      case 'step_update':
        if (event['step_update'] case final Map step) {
          handleStepUpdate(step.cast<String, Object?>());
        }
      case 'result':
        gotResult = true;
        for (final idx in [...stepMessageStarted.keys]) {
          finishStepMessage(idx);
        }
        for (final idx in [...toolEmittedActive.keys]) {
          completeToolStep(idx);
        }
        final result =
            (event['result'] as Map?)?.cast<String, Object?>() ?? const {};
        if (result['conversation_id'] case final String convId
            when convId.isNotEmpty) {
          onConversationBound(convId);
        }
        final status = result['status'] as String? ?? 'SUCCESS';
        final isError = status != 'SUCCESS';
        gotError = isError;
        final responseText = '${result['response'] ?? ''}'.trim();
        final errorText = '${result['error'] ?? ''}'.trim();
        final usage = transport._recordResultUsage(
          result['usage'],
          hadStepUsage: hadStepUsage,
        );

        if (isError &&
            allowAutoFailover &&
            !streamedAnyResponse &&
            !transport._interrupted &&
            AntigravityAccounts.instance.autoSwitch.enabled) {
          final combinedErr = '$errorText $responseText'.toLowerCase();
          if (combinedErr.contains('resource_exhausted') ||
              combinedErr.contains('quota') ||
              combinedErr.contains('rate limit') ||
              combinedErr.contains('too many requests') ||
              combinedErr.contains('429')) {
            hitQuotaLimit = true;
            deferredQuotaError = errorText.isNotEmpty
                ? errorText
                : responseText;
            if (!done.isCompleted) {
              done.complete();
            }
            return;
          }
        }

        if (_pendingHooks <= 0) {
          _emitResultAndComplete(
            isError: isError,
            responseText: responseText,
            errorText: errorText,
            usage: usage,
          );
        } else {
          _finalizingResult = true;
          unawaited(
            _finalizeResultAsync(
              isError: isError,
              responseText: responseText,
              errorText: errorText,
              usage: usage,
            ),
          );
        }
    }
  }

  void _synthesizeExitPlanMode(String planPath, String? planContent) {
    var content = planContent;
    if (content == null || content.isEmpty) {
      try {
        final file = File(planPath);
        if (file.existsSync()) {
          final bytes = file.readAsBytesSync();
          final capped = bytes.length > 16384 ? bytes.sublist(0, 16384) : bytes;
          final decoded = const Utf8Decoder(allowMalformed: true)
              .convert(capped)
              .trim();
          if (decoded.isNotEmpty) content = decoded;
        }
      } on Object {
        // Plan path alone still surfaces the awaiting card.
      }
    }
    final synthId = 'agy-exit-plan-$turnId';
    _emitAndLog({
      'type': 'assistant',
      'uuid': 'agy-exit-plan-msg-$turnId',
      'message': {
        'id': 'agy-exit-plan-msg-$turnId',
        'model': transport._model,
        'role': 'assistant',
        'content': [
          {
            'type': 'tool_use',
            'id': synthId,
            'name': 'ExitPlanMode',
            'input': {
              'planFilePath': planPath,
              if (content != null && content.isNotEmpty) 'plan': content,
            },
          },
        ],
      },
    }, persist: true);
    _emitAndLog({
      'type': 'user',
      'uuid': 'agy-exit-plan-res-$turnId',
      'message': {
        'role': 'user',
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': synthId,
            'content': ClaudeTranslator.planPresented,
            'is_error': true,
          },
        ],
      },
    }, persist: true);
  }

  static bool _isPermissionDenialError(String text) {
    final lower = text.toLowerCase();
    return lower.contains('permission check failed') ||
        lower.contains('user denied permission');
  }

  void _emitResultAndComplete({
    required bool isError,
    required String responseText,
    required String errorText,
    required Map<String, Object?>? usage,
  }) {
    if (!isError &&
        !transport._interrupted &&
        transport._permissionMode == 'plan' &&
        lastPlanPath != null &&
        !sawExitPlanMode) {
      _synthesizeExitPlanMode(lastPlanPath!, lastPlanContent);
    }

    if (!streamedAnyResponse) {
      final fallbackText = !isError && responseText.isNotEmpty
          ? responseText
          : (responseText.isEmpty && lastToolError != null
                ? '工具执行返回错误：\n```\n$lastToolError\n```'
                : '');
      if (fallbackText.isNotEmpty) {
        _emitAndLog({
          'type': 'assistant',
          'uuid': 'agy-final-$turnId',
          'message': {
            'id': 'agy-final-$turnId',
            'model': transport._model,
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': fallbackText},
            ],
            'usage': ?usage,
          },
        }, persist: true);
      }
    } else if (!transport._interrupted &&
        responseText.isEmpty &&
        unansweredPermissionError != null) {
      _emitAndLog({
        'type': 'assistant',
        'uuid': 'agy-perm-abort-$turnId',
        'message': {
          'id': 'agy-perm-abort-$turnId',
          'model': transport._model,
          'role': 'assistant',
          'content': [
            {
              'type': 'text',
              'text':
                  '当前工具调用被 Antigravity CLI 非交互权限检查拒绝并中止了本轮执行'
                  '（如需在计划模式或常规模式下自动放行，请将权限策略设为「完全访问 / 自动批准」）：\n'
                  '```\n$unansweredPermissionError\n```',
            },
          ],
          'usage': ?usage,
        },
      }, persist: true);
    }

    transport._emit({
      'type': 'result',
      'subtype': transport._interrupted
          ? 'error_during_execution'
          : isError
          ? 'error'
          : 'success',
      'is_error': isError && !transport._interrupted,
      'result': isError
          ? (errorText.isNotEmpty
                ? errorText
                : responseText.isNotEmpty
                ? responseText
                : 'Antigravity CLI 执行出错')
          : responseText,
      // `agy`'s `result.duration_seconds` is cumulative conversation age
      // since step 0, not the current turn's duration; always report this
      // turn's own wall-clock elapsed time instead.
      'duration_ms': transport._elapsedTurnMs(startedAt),
      'usage': ?usage,
      'modelUsage': {
        AntigravityModels.bareModelId(transport._model): {
          'contextWindow': transport._maxContextTokens,
          ...?usage,
        },
      },
    });

    if (!done.isCompleted) {
      done.complete();
    }
  }

  Future<void> _finalizeResultAsync({
    required bool isError,
    required String responseText,
    required String errorText,
    required Map<String, Object?>? usage,
  }) async {
    try {
      while (_pendingHooks > 0 &&
          !_hooksCancelled &&
          !transport._closed &&
          !transport._interrupted) {
        await _hookChain;
      }
      _emitResultAndComplete(
        isError: isError,
        responseText: responseText,
        errorText: errorText,
        usage: usage,
      );
    } finally {
      _finalizingResult = false;
      if (!done.isCompleted) {
        done.complete();
      }
    }
  }

  void handleStderr(String line) {
    stderrLines.add(line);
    if (stderrLines.length > 50) {
      stderrLines.removeAt(0);
    }
  }

  void handleProcessExit(int exitCode) {
    if (done.isCompleted || _finalizingResult) return;
    if (reusedProcess && !receivedAnyEvent && !transport._interrupted) {
      needsFreshRetry = true;
      done.complete();
      return;
    }
    for (final idx in [...stepMessageStarted.keys]) {
      finishStepMessage(idx);
    }
    for (final idx in [...toolEmittedActive.keys]) {
      completeToolStep(idx);
    }
    if (!gotResult) {
      final errText = stderrLines.join('\n').trim();
      transport._emit({
        'type': 'result',
        'subtype': transport._interrupted || exitCode == 0
            ? 'success'
            : 'error',
        'is_error': !transport._interrupted && exitCode != 0,
        'result': !transport._interrupted && exitCode != 0
            ? (errText.isNotEmpty
                  ? errText
                  : 'Antigravity CLI 退出（代码 $exitCode）')
            : '',
        'duration_ms': transport._elapsedTurnMs(startedAt),
      });
    }
    done.complete();
  }
}

/// Appends Claude Code-compatible `.jsonl` lines for an Antigravity CLI
/// session so Ayte's sidebar (`ClaudeSessions`), history pager, and Session
/// Replay work natively.
class _AntigravitySessionLog {
  _AntigravitySessionLog({
    required this.paths,
    required this.cwd,
    required this.sessionId,
    required this.persist,
  }) : filePath = paths.findSession(sessionId) ??
           paths.sessionFile(cwd, sessionId) {
    _loadExistingLeaf();
  }

  final AgentPaths paths;
  final String cwd;
  final String sessionId;
  final bool persist;
  final String filePath;

  String? _leafUuid;
  int _seq = 0;

  static List<String> _readLinesLossySync(File file) {
    final bytes = file.readAsBytesSync();
    final text = const Utf8Decoder(allowMalformed: true).convert(bytes);
    return const LineSplitter().convert(text);
  }

  void _loadExistingLeaf() {
    final file = File(filePath);
    if (!file.existsSync()) return;
    try {
      final lines = _readLinesLossySync(file);
      for (final line in lines.reversed) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        try {
          final decoded = jsonDecode(trimmed);
          if (decoded is Map && decoded['uuid'] is String) {
            _leafUuid = decoded['uuid'] as String;
            break;
          }
        } on Object {
          // Skip malformed JSON line.
        }
      }
    } on Object {
      // Ignore unreadable transcript file.
    }
  }

  void append(Map<String, Object?> entry) {
    if (!persist) return;
    final uuid =
        (entry['uuid'] as String?) ??
        'agy-$sessionId-${DateTime.now().microsecondsSinceEpoch}-${++_seq}';
    final line = <String, Object?>{
      'parentUuid': _leafUuid,
      'isSidechain': false,
      'userType': 'external',
      'cwd': cwd,
      'sessionId': sessionId,
      'version': agentVersion,
      ...entry,
      if (entry['tool_use_result'] != null && entry['toolUseResult'] == null)
        'toolUseResult': entry['tool_use_result'],
      'uuid': uuid,
      'timestamp':
          entry['timestamp'] ?? DateTime.now().toUtc().toIso8601String(),
    };
    _leafUuid = uuid;
    _writeRaw(line);
  }

  void noteTitle(String title) {
    if (!persist) return;
    _writeRaw({
      'type': 'custom-title',
      'customTitle': title,
      'sessionId': sessionId,
    });
  }

  void _writeRaw(Map<String, Object?> line) {
    try {
      final file = File(filePath);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        '${jsonEncode(line)}\n',
        mode: FileMode.append,
        flush: true,
      );
    } on Object {
      // Ignore disk errors.
    }
  }

  /// Reads the latest single-request context token count recorded in `.jsonl`.
  int? readLastContextTokens() {
    final file = File(filePath);
    if (!file.existsSync()) return null;
    try {
      final lines = _readLinesLossySync(file);
      for (final line in lines.reversed) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        try {
          final decoded = jsonDecode(trimmed);
          if (decoded is! Map) continue;
          if (decoded['type'] == 'system' &&
              decoded['subtype'] == 'compact_boundary') {
            final meta = decoded['compact_metadata'];
            if (meta is Map && meta['post_tokens'] is num) {
              return (meta['post_tokens'] as num).round();
            }
            return null;
          }
          if (decoded['type'] != 'assistant') continue;
          final msg = decoded['message'];
          if (msg is! Map) continue;
          final usage = msg['usage'];
          if (usage is! Map) continue;
          final input = (usage['input_tokens'] as num?)?.round() ?? 0;
          final cacheRead =
              (usage['cache_read_input_tokens'] as num?)?.round() ?? 0;
          final cacheCreate =
              (usage['cache_creation_input_tokens'] as num?)?.round() ?? 0;
          final output = (usage['output_tokens'] as num?)?.round() ?? 0;
          final total = input + cacheRead + cacheCreate + output;
          if (total > 0) return total;
        } on Object {
          continue;
        }
      }
    } on Object {
      // Ignore unreadable file errors.
    }
    return null;
  }

  /// Extracts a concise summary of recent turns when switching an existing
  /// Claude Code session to Antigravity CLI mid-conversation.
  String buildRecentContextSummary({int maxChars = 4000}) {
    final file = File(filePath);
    if (!file.existsSync()) return '';
    try {
      final snippets = <String>[];
      for (final line in _readLinesLossySync(file)) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        try {
          final decoded = jsonDecode(trimmed);
          if (decoded is! Map) continue;
          final type = decoded['type'];
          final msg = decoded['message'];
          if (msg is! Map) continue;
          final content = msg['content'];
          if (type == 'user' && decoded['toolUseResult'] == null) {
            final text = _extractText(content);
            if (text.isNotEmpty && !text.startsWith('<')) {
              snippets.add('User: $text');
            }
          } else if (type == 'assistant') {
            final text = _extractText(content);
            if (text.isNotEmpty) {
              snippets.add('Assistant: $text');
            }
          }
        } on Object {
          continue;
        }
      }
      if (snippets.isEmpty) return '';
      final joined = snippets.reversed.take(8).toList().reversed.join('\n\n');
      return joined.length > maxChars
          ? joined.substring(joined.length - maxChars)
          : joined;
    } on Object {
      return '';
    }
  }

  static String _extractText(Object? content) {
    if (content is String) return content.trim();
    if (content is List) {
      final parts = <String>[];
      for (final block in content) {
        if (block is Map && block['type'] == 'text') {
          final t = '${block['text'] ?? ''}'.trim();
          if (t.isNotEmpty) parts.add(t);
        }
      }
      return parts.join('\n');
    }
    return '';
  }
}

/// Converts `~/.gemini/antigravity-cli/brain/<sessionId>/.system_generated/logs/transcript.jsonl`
/// into a Claude Code `.jsonl` session file under `~/.claude/projects/<cwd>/<sessionId>.jsonl`
/// when the `.jsonl` file does not exist yet.
///
/// Returns the `.jsonl` file path when it exists or was synthesized, or `null`
/// if neither `.jsonl` nor an Antigravity brain transcript exists.
String? syncAntigravityTranscriptIfNeeded({
  required String cwd,
  required String sessionId,
  AgentPaths? paths,
  String model = 'gemini-3.8-flash-high',
}) {
  if (sessionId.isEmpty) return null;
  final resolvedPaths = paths ?? AgentPaths.from(Platform.environment);
  final targetPath =
      resolvedPaths.findSession(sessionId) ??
      resolvedPaths.sessionFile(cwd, sessionId);
  final targetFile = File(targetPath);
  if (targetFile.existsSync() && targetFile.lengthSync() > 0) {
    return targetPath;
  }

  final brainTranscript = File(
    p.join(
      resolvedPaths.home,
      '.gemini',
      'antigravity-cli',
      'brain',
      sessionId,
      '.system_generated',
      'logs',
      'transcript.jsonl',
    ),
  );
  if (!brainTranscript.existsSync()) return null;

  final steps = <Map<String, Object?>>[];
  try {
    final bytes = brainTranscript.readAsBytesSync();
    final text = const Utf8Decoder(allowMalformed: true).convert(bytes);
    for (final line in const LineSplitter().convert(text)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map) {
          steps.add(decoded.cast<String, Object?>());
        }
      } on Object {
        // Skip malformed JSON line while preserving remaining transcript.
      }
    }
  } on Object {
    return null;
  }
  if (steps.isEmpty) return null;

  final log = _AntigravitySessionLog(
    paths: resolvedPaths,
    cwd: cwd,
    sessionId: sessionId,
    persist: true,
  );

  var seq = 0;
  for (var i = 0; i < steps.length; i++) {
    try {
      final step = steps[i];
      final type = switch (step['type']) {
        final String s => s,
        _ => '',
      };
      final timestamp = switch (step['created_at']) {
        final String s when s.isNotEmpty => s,
        _ => null,
      };

      if (type == 'USER_INPUT') {
        final rawContent = '${step['content'] ?? ''}';
        final match = RegExp(
          r'<USER_REQUEST>\s*([\s\S]*?)\s*</USER_REQUEST>',
        ).firstMatch(rawContent);
        final userText = (match != null ? match.group(1)! : rawContent).trim();
        if (userText.isEmpty) continue;
        seq++;
        log.append({
          'type': 'user',
          'uuid': 'agy-import-$sessionId-u-$seq',
          'timestamp': ?timestamp,
          'message': {
            'role': 'user',
            'content': userText,
          },
        });
      } else if (type == 'CHECKPOINT') {
        seq++;
        log.append({
          'type': 'system',
          'subtype': 'compact_boundary',
          'uuid': 'agy-import-$sessionId-c-$seq',
          'timestamp': ?timestamp,
          'compact_metadata': const {'trigger': 'auto'},
        });
      } else if (type == 'PLANNER_RESPONSE') {
        final thinking = '${step['thinking'] ?? ''}'.trim();
        final text = '${step['content'] ?? ''}'.trim();
        final inputTokens = (step['input_tokens'] as num?)?.round() ?? 0;
        final outputTokens = (step['output_tokens'] as num?)?.round() ?? 0;
        final cacheRead = (step['cache_read_tokens'] as num?)?.round() ?? 0;
        final uncachedInput = math.max(0, inputTokens - cacheRead);
        final usage = (inputTokens > 0 || outputTokens > 0 || cacheRead > 0)
            ? <String, Object?>{
                'input_tokens': uncachedInput,
                'output_tokens': outputTokens,
                if (cacheRead > 0) 'cache_read_input_tokens': cacheRead,
              }
            : null;

        if (thinking.isNotEmpty || text.isNotEmpty) {
          seq++;
          log.append({
            'type': 'assistant',
            'uuid': 'agy-import-$sessionId-a-$seq',
            'timestamp': ?timestamp,
            'message': {
              'id': 'agy-import-$sessionId-a-$seq',
              'model': model,
              'role': 'assistant',
              'content': [
                if (thinking.isNotEmpty)
                  {'type': 'thinking', 'thinking': thinking},
                if (text.isNotEmpty) {'type': 'text', 'text': text},
              ],
              'usage': ?usage,
            },
          });
        }

        final toolCalls = step['tool_calls'];
        if (toolCalls is List && toolCalls.isNotEmpty) {
          Map<String, Object?>? nextGeneric;
          if (i + 1 < steps.length && steps[i + 1]['type'] == 'GENERIC') {
            nextGeneric = steps[i + 1];
          }
          for (final rawCall in toolCalls) {
            if (rawCall is! Map) continue;
            try {
              final rawName = '${rawCall['name'] ?? 'tool'}';
              final serverName = switch (rawCall['server_name'] ??
                  rawCall['serverName']) {
                final String s => s,
                _ => null,
              };
              final rawArgs =
                  (rawCall['args'] as Map?)?.cast<String, Object?>() ??
                  const {};
              final isError = nextGeneric?['status'] == 'ERROR';
              final rawOut = '${nextGeneric?['content'] ?? ''}'.trim();
              final rawErr = '${nextGeneric?['error'] ?? ''}'.trim();
              final combinedOut =
                  isError && rawErr.isNotEmpty ? rawErr : rawOut;
              final cleanedOut = AntigravityTransport.cleanToolOutput(
                rawName,
                combinedOut,
              );
              final mapped = AntigravityTransport.mapTool(
                rawName,
                rawArgs,
                cleanedOut,
                defaultCwd: cwd,
                serverName: serverName,
              );
              seq++;
              final toolId = 'agy-import-$sessionId-t-$seq';
              final resultTs = switch (nextGeneric?['created_at']) {
                final String s when s.isNotEmpty => s,
                _ => timestamp,
              };
              log.append({
                'type': 'assistant',
                'uuid': 'agy-import-$sessionId-tu-$seq',
                'timestamp': ?timestamp,
                'message': {
                  'id': 'agy-import-$sessionId-tu-$seq',
                  'model': model,
                  'role': 'assistant',
                  'content': [
                    {
                      'type': 'tool_use',
                      'id': toolId,
                      'name': mapped.name,
                      'input': mapped.input,
                    },
                  ],
                },
              });
              log.append({
                'type': 'user',
                'uuid': 'agy-import-$sessionId-tr-$seq',
                'timestamp': ?resultTs,
                'message': {
                  'role': 'user',
                  'content': [
                    {
                      'type': 'tool_result',
                      'tool_use_id': toolId,
                      'content': cleanedOut,
                      'is_error': isError,
                    },
                  ],
                },
                if (!isError && mapped.structuredResult != null)
                  'tool_use_result': mapped.structuredResult,
              });
            } on Object {
              // Skip malformed tool call entry while preserving remaining calls.
            }
          }
        }
      }
    } on Object {
      // Skip type-corrupt transcript step while preserving remaining steps.
    }
  }
  return targetFile.existsSync() ? targetPath : null;
}
