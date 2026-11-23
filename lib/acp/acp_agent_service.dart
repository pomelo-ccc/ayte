import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../kernel/antigravity/antigravity_cli.dart';
import '../kernel/claude_code/claude_code_kernel.dart';
import '../kernel/claude_code/claude_environment.dart';
import '../kernel/claude_code/cli_locator.dart';
import '../kernel/codebuddy/codebuddy_accounts.dart';
import '../kernel/codebuddy/codebuddy_cli.dart';
import '../kernel/codex/codex_models.dart';
import '../network/network_proxy_io.dart';
import '../platform/app_paths.dart';
import '../settings/user_settings.dart';

/// Descriptor for one of Ayte's four directly supported native coding kernels
/// used in unattended Task Queue, Cron Automations, Workflow Canvas, and `ayte-cli`.
@immutable
class AcpAgentProfile {
  const AcpAgentProfile({
    required this.id,
    required this.name,
    required this.command,
    this.args = const [],
    this.builtIn = true,
  });

  final String id;
  final String name;
  final String command;
  final List<String> args;
  final bool builtIn;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'command': command,
    'args': args,
  };
}

/// A selectable model option for a specific native kernel in Workflow / Task UI.
@immutable
class WorkflowModelOption {
  const WorkflowModelOption({
    required this.id,
    required this.label,
    this.description = '',
    this.effortLevels = const [],
  });

  final String id;
  final String label;
  final String description;
  final List<String> effortLevels;
}

/// Manages headless prompt execution for Ayte's 4 directly supported native
/// kernels (`Antigravity (agy)`, `CodeBuddy`, `Claude Code`, `Codex`) without
/// requiring ACP wrappers.
class AcpAgentService extends ChangeNotifier {
  AcpAgentService._();
  static final instance = AcpAgentService._();

  static const List<AcpAgentProfile> builtInAgents = [
    AcpAgentProfile(
      id: 'agy',
      name: 'Antigravity (agy)',
      command: 'agy',
      args: [
        '--dangerously-skip-permissions',
        '--output-format',
        'stream-json',
        '-p',
      ],
      builtIn: true,
    ),
    AcpAgentProfile(
      id: 'codebuddy',
      name: 'CodeBuddy',
      command: 'codebuddy',
      args: ['-y', '--output-format', 'stream-json', '-p'],
      builtIn: true,
    ),
    AcpAgentProfile(
      id: 'claude',
      name: 'Claude Code',
      command: 'claude',
      args: [
        '--dangerously-skip-permissions',
        '--verbose',
        '--output-format',
        'stream-json',
        '-p',
      ],
      builtIn: true,
    ),
    AcpAgentProfile(
      id: 'codex',
      name: 'Codex',
      command: 'codex',
      args: ['exec', '--json', '--full-auto'],
      builtIn: true,
    ),
  ];

  List<AcpAgentProfile> get selectableAgents => builtInAgents;

  /// Normalizes CLI / kernel aliases (`antigravity`, `antigravity-cli`,
  /// `claude-code`, `codebuddy-cli`, `cbc`, etc.) to canonical agent IDs
  /// (`agy`, `claude`, `codebuddy`, `codex`), preserving unrecognized IDs.
  static String normalizeAgentId(String id) {
    final trimmed = id.trim();
    return switch (trimmed.toLowerCase()) {
      'agy' || 'antigravity' || 'antigravity-cli' => 'agy',
      'claude' || 'claude-code' => 'claude',
      'codebuddy' || 'codebuddy-cli' || 'cbc' => 'codebuddy',
      'codex' => 'codex',
      _ => trimmed,
    };
  }

  AcpAgentProfile? byId(String id) {
    final canonical = normalizeAgentId(id);
    if (canonical.isEmpty) return null;
    for (final a in builtInAgents) {
      if (a.id == canonical) return a;
    }
    return null;
  }

  /// Returns live/local selectable models for one of the 4 native kernels.
  List<WorkflowModelOption> modelsForAgent(String agentId) {
    switch (normalizeAgentId(agentId)) {
      case 'agy':
        return [
          for (final m in AntigravityModels.current)
            WorkflowModelOption(
              id: m.id,
              label: m.label,
              description: m.description,
              effortLevels: m.effortLevels,
            ),
        ];
      case 'codebuddy':
        return [
          for (final m in CodeBuddyModels.current)
            WorkflowModelOption(
              id: m.id,
              label: m.label,
              description: m.creditsRate != null
                  ? '${m.creditsRate} · ${m.description}'
                  : m.description,
              effortLevels: m.supportedEfforts,
            ),
        ];
      case 'claude':
        final cached = ClaudeCodeKernel.modelCache?.get(
          ClaudeCodeKernel.modelCacheKey,
        );
        final out = <WorkflowModelOption>[];
        final seenIds = <String>{};
        if (cached is List) {
          for (final raw in cached) {
            if (raw is Map) {
              final id = '${raw['value'] ?? raw['id'] ?? ''}'.trim();
              final label =
                  '${raw['displayName'] ?? raw['label'] ?? id}'.trim();
              if (id.isNotEmpty &&
                  id != 'default' &&
                  !AntigravityModels.isAntigravityModel(id) &&
                  !CodeBuddyModels.isCodeBuddyModel(id) &&
                  seenIds.add(id)) {
                final supportsEffort = raw['supportsEffort'];
                final List<String> effortLevels;
                if (supportsEffort == false) {
                  effortLevels = const [];
                } else {
                  final rawEfforts = raw['supportedEffortLevels'];
                  final parsedEfforts = <String>[
                    if (rawEfforts is List)
                      for (final e in rawEfforts)
                        if ('$e'.trim().isNotEmpty) '$e'.trim(),
                  ];
                  effortLevels = parsedEfforts.isNotEmpty
                      ? parsedEfforts
                      : const ['low', 'medium', 'high', 'max'];
                }
                out.add(
                  WorkflowModelOption(
                    id: id,
                    label: label,
                    description: '${raw['description'] ?? ''}'.trim(),
                    effortLevels: effortLevels,
                  ),
                );
              }
            }
          }
        }
        if (out.isNotEmpty) return out;
        return const [
          WorkflowModelOption(
            id: 'opus',
            label: 'Claude Opus',
            description: '深度推理与复杂代码修复',
            effortLevels: ['low', 'medium', 'high', 'max'],
          ),
          WorkflowModelOption(
            id: 'sonnet',
            label: 'Claude Sonnet',
            description: '均衡速度与代码质量',
            effortLevels: ['low', 'medium', 'high', 'max'],
          ),
          WorkflowModelOption(
            id: 'haiku',
            label: 'Claude Haiku',
            description: '轻量极速分类与整理',
            effortLevels: ['low', 'medium', 'high'],
          ),
        ];
      case 'codex':
        final catalog = CodexModels.loadLocalCatalog();
        return [
          for (final m in catalog.models)
            WorkflowModelOption(
              id: m.id,
              label: m.label,
              description: m.description,
              effortLevels: m.effortLevels.isEmpty
                  ? const ['low', 'medium', 'high', 'xhigh']
                  : m.effortLevels,
            ),
        ];
      default:
        return modelsForAgent('agy');
    }
  }

  /// Resolves a concise display label for [modelId] under [agentId].
  String modelLabel(String agentId, String modelId) {
    final trimmed = modelId.trim();
    if (trimmed.isEmpty) return '';
    for (final m in modelsForAgent(agentId)) {
      if (m.id == trimmed) return m.label;
    }
    return trimmed;
  }

  void follow(UserSettings settings) {
    // Kept for lifecycle compatibility; built-in 4 kernels require no ACP list.
  }

  /// Optional test hook replacing subprocess execution in [runHeadlessPrompt].
  @visibleForTesting
  Future<({bool ok, String output, String? error})> Function({
    required String agentId,
    required String prompt,
    required String cwd,
    String? model,
    String? effort,
    void Function(String chunk)? onChunk,
    void Function(Process proc)? onProcessStarted,
    Duration timeout,
  })?
  headlessRunnerOverride;

  /// Terminates [proc] and all of its descendant processes (`taskkill /T /F`
  /// on Windows to avoid orphaned child shells/Node processes holding locks).
  static Future<void> killProcessTree(Process proc) async {
    if (Platform.isWindows) {
      try {
        await Process.run('taskkill', ['/T', '/F', '/PID', '${proc.pid}']);
        return;
      } on Object {
        // Fall through to standard kill.
      }
    }
    try {
      proc.kill(ProcessSignal.sigterm);
    } on Object {
      // Process may have already exited.
    }
  }

  static bool _isWindowsBatchFile(String path) {
    if (!Platform.isWindows) return false;
    final ext = p.extension(path).toLowerCase();
    return ext == '.cmd' || ext == '.bat';
  }

  /// Builds an enriched PATH across Windows, macOS, and Linux so Node/npm,
  /// Bun, Volta, Homebrew, and all 4 native coding kernels resolve reliably
  /// even when Ayte is launched from a GUI shortcut.
  static String buildEnrichedPath([Map<String, String>? baseEnv]) {
    final env = baseEnv ?? Platform.environment;
    final win = Platform.isWindows;
    final home = win
        ? switch (_readEnvVar(env, 'USERPROFILE')) {
            final up when up.isNotEmpty => up,
            _ => _readEnvVar(env, 'HOME'),
          }
        : AppPaths.home(env);
    final sep = win ? ';' : ':';
    final currentPath = _readPathVar(env);
    final appData = _readEnvVar(env, 'APPDATA');
    final localAppData = _readEnvVar(env, 'LOCALAPPDATA');
    final volta = _readEnvVar(env, 'VOLTA_HOME');
    final programFiles = _readEnvVar(env, 'ProgramFiles');
    final extras = <String>[
      if (win) ...[
        if (appData.isNotEmpty) p.join(appData, 'npm'),
        if (localAppData.isNotEmpty) ...[
          p.join(localAppData, 'Programs', 'claude'),
          p.join(localAppData, 'Volta', 'bin'),
        ],
        if (volta.isNotEmpty) p.join(volta, 'bin'),
        if (programFiles.isNotEmpty) p.join(programFiles, 'nodejs'),
        if (home.isNotEmpty) ...[
          p.join(home, '.gemini', 'bin'),
          p.join(home, '.local', 'bin'),
          p.join(home, '.claude', 'local'),
          p.join(home, '.codebuddy', 'bin'),
          p.join(home, '.antigravity', 'antigravity', 'bin'),
          p.join(home, '.bun', 'bin'),
          p.join(home, '.volta', 'bin'),
        ],
      ] else ...[
        if (home.isNotEmpty) ...[
          p.join(home, '.local', 'bin'),
          p.join(home, '.hermes', 'node', 'bin'),
          p.join(home, '.gemini', 'bin'),
          p.join(home, '.claude', 'local'),
          p.join(home, '.codebuddy', 'bin'),
          p.join(home, '.bun', 'bin'),
          p.join(home, '.volta', 'bin'),
        ],
        '/opt/homebrew/bin',
        '/usr/local/bin',
        '/usr/bin',
        '/bin',
      ],
    ];
    final existing = currentPath
        .split(sep)
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty);
    final seen = <String>{};
    final merged = <String>[];
    for (final dir in [...existing, ...extras]) {
      final key = Platform.isWindows ? dir.toLowerCase() : dir;
      if (seen.add(key)) merged.add(dir);
    }
    return merged.join(sep);
  }

  static String _readEnvVar(
    Map<String, String> env,
    String name, {
    bool? forceWindows,
  }) {
    if (env[name] case final v? when v.isNotEmpty) return v;
    if (forceWindows ?? Platform.isWindows) {
      final lower = name.toLowerCase();
      for (final entry in env.entries) {
        if (entry.key.toLowerCase() == lower && entry.value.isNotEmpty) {
          return entry.value;
        }
      }
    }
    return '';
  }

  static String _readPathVar(Map<String, String> env) =>
      _readEnvVar(env, 'PATH');

  static Map<String, String> _withPath(
    Map<String, String> base,
    String pathValue,
  ) {
    final result = <String, String>{};
    for (final entry in base.entries) {
      if (Platform.isWindows && entry.key.toLowerCase() == 'path') continue;
      result[entry.key] = entry.value;
    }
    result['PATH'] = pathValue;
    return result;
  }

  /// Unwraps a Windows npm `.cmd` shim (e.g. `codex.cmd`, `codebuddy.cmd`)
  /// into `(executable: node.exe, prefixArgs: [script.js])` so multi-line
  /// prompts and special shell characters (`&`, `|`, `<`, `>`, `%`) bypass
  /// `cmd.exe` parsing completely.
  @visibleForTesting
  static ({String executable, List<String> prefixArgs})? unwrapWindowsNpmShim(
    String shimPath,
    Map<String, String> env, {
    bool forceWindows = false,
  }) {
    if (!forceWindows && !Platform.isWindows) return null;
    final ext = p.extension(shimPath).toLowerCase();
    if (ext != '.cmd' && ext != '.bat') return null;
    final shimFile = File(shimPath);
    if (!shimFile.existsSync()) return null;

    String content;
    try {
      content = shimFile.readAsStringSync();
    } on Object {
      return null;
    }

    final match = RegExp(
      r'''["']%(?:dp0%|~dp0%?)[/\\]?([^"']+\.(?:c|m)?js)["']''',
      caseSensitive: false,
    ).firstMatch(content);
    if (match == null) return null;

    final relScript = match
        .group(1)!
        .replaceAll('/', p.separator)
        .replaceAll('\\', p.separator);
    final shimDir = p.dirname(shimPath);
    final scriptPath = p.normalize(p.join(shimDir, relScript));
    if (!File(scriptPath).existsSync()) return null;

    final localNode = p.join(shimDir, 'node.exe');
    String? nodeExe = File(localNode).existsSync() ? localNode : null;
    if (nodeExe == null) {
      final pathVar = _readPathVar(env);
      final sep = forceWindows || Platform.isWindows ? ';' : ':';
      for (final dir in pathVar.split(sep)) {
        final trimmed = dir.trim();
        if (trimmed.isEmpty) continue;
        final candidate = p.join(
          trimmed,
          forceWindows || Platform.isWindows ? 'node.exe' : 'node',
        );
        if (File(candidate).existsSync()) {
          nodeExe = candidate;
          break;
        }
      }
    }
    if (nodeExe == null) return null;
    return (executable: nodeExe, prefixArgs: [scriptPath]);
  }

  /// Resolves a native kernel executable using the same cross-platform locator
  /// stack as interactive chat (`LocalAntigravity`, `LocalCodeBuddy`,
  /// `CliLocator`, and Codex PATH/npm discovery) plus enriched environment.
  Future<
    ({
      String executable,
      List<String> prefixArgs,
      Map<String, String> environment,
      bool throughShell,
    })?
  >
  resolveKernelLaunch(String agentId) async {
    Map<String, String> baseEnv;
    try {
      baseEnv = await ClaudeEnvironment.of();
    } on Object {
      baseEnv = Map<String, String>.of(Platform.environment);
    }

    final agent = byId(agentId);
    if (agent == null) return null;
    final canonicalId = agent.id;

    String? executable;
    Map<String, String> env = baseEnv;
    bool throughShell = false;

    try {
      switch (canonicalId) {
        case 'agy':
          final cli = await LocalAntigravity.locate();
          executable = cli.executable;
          env = cli.environment;
          throughShell = _isWindowsBatchFile(executable);
        case 'codebuddy':
          final cli = await LocalCodeBuddy.locate();
          executable = cli.executable;
          env = cli.environment;
          throughShell = cli.throughShell;
        case 'claude':
          final cli = await CliLocator.locate();
          executable = cli.executable;
          env = cli.environment;
          throughShell = cli.throughShell;
        case 'codex':
          final enriched = _withPath(env, buildEnrichedPath(env));
          executable = await resolveBinary('codex', environment: enriched);
          env = enriched;
          if (executable != null) {
            throughShell = _isWindowsBatchFile(executable);
          }
      }
    } on Object {
      // Fall back to generic cross-platform binary resolution below.
    }

    if (executable == null) {
      final cmd = agent.command;
      final enriched = _withPath(env, buildEnrichedPath(env));
      executable = await resolveBinary(cmd, environment: enriched);
      if (executable == null && canonicalId == 'codebuddy') {
        executable =
            await resolveBinary('cbc', environment: enriched) ??
            await resolveBinary('codebuddy-code', environment: enriched);
      }
      env = enriched;
      if (executable != null) {
        throughShell = _isWindowsBatchFile(executable);
      }
    }

    if (executable == null) return null;

    final enrichedEnv = _withPath(env, buildEnrichedPath(env));
    if (Platform.isWindows && throughShell) {
      final unwrapped = unwrapWindowsNpmShim(executable, enrichedEnv);
      if (unwrapped != null) {
        return (
          executable: unwrapped.executable,
          prefixArgs: unwrapped.prefixArgs,
          environment: enrichedEnv,
          throughShell: false,
        );
      }
    }

    return (
      executable: executable,
      prefixArgs: const <String>[],
      environment: enrichedEnv,
      throughShell: throughShell,
    );
  }

  /// Resolves a native kernel executable on PATH or common install locations
  /// across Windows (`.exe` / `.cmd` / `.bat` + `where`) and POSIX (`which`).
  Future<String?> resolveBinary(
    String command, {
    Map<String, String>? environment,
  }) async {
    final trimmed = command.trim();
    if (trimmed.isEmpty) return null;
    if (File(trimmed).existsSync()) return trimmed;

    final env = environment ?? Platform.environment;
    final enrichedPath = buildEnrichedPath(env);
    final sep = Platform.isWindows ? ';' : ':';
    // On Windows prefer native `.exe` before `.cmd`/`.bat` shims.
    final hasExt = Platform.isWindows && p.extension(trimmed).isNotEmpty;
    final exts = Platform.isWindows
        ? (hasExt ? const [''] : const ['.exe', '.cmd', '.bat', ''])
        : const [''];

    final dirs = enrichedPath
        .split(sep)
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty);
    for (final dir in dirs) {
      for (final ext in exts) {
        final candidate = p.join(dir, '$trimmed$ext');
        if (File(candidate).existsSync()) return candidate;
      }
    }

    try {
      final res = await Process.run(
        Platform.isWindows ? 'where' : 'which',
        [trimmed],
        environment: _withPath(env, enrichedPath),
      );
      if (res.exitCode == 0) {
        final hits = const LineSplitter()
            .convert('${res.stdout}'.trim())
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty && File(l).existsSync())
            .toList();
        if (hits.isNotEmpty) {
          if (Platform.isWindows) {
            final exeHit = hits
                .where((h) => h.toLowerCase().endsWith('.exe'))
                .firstOrNull;
            if (exeHit != null) return exeHit;
          }
          return hits.first;
        }
      }
    } on Object {
      // Ignore probe errors.
    }
    return null;
  }

  /// Builds exact non-interactive CLI arguments for [agentId], injecting
  /// optional `--model` and `--effort` flags in the position each CLI requires.
  static List<String> buildCliArgs({
    required String agentId,
    required String prompt,
    String? model,
    String? effort,
  }) {
    final m = (model ?? '').trim();
    final e = (effort ?? '').trim();
    return switch (normalizeAgentId(agentId)) {
      'agy' => [
        '--dangerously-skip-permissions',
        '--output-format',
        'stream-json',
        if (m.isNotEmpty && m != 'default') ...[
          '--model',
          AntigravityModels.cliModelIdOf(m),
        ],
        if (e.isNotEmpty) ...['--effort', e],
        '-p',
        prompt,
      ],
      'codebuddy' => [
        '-y',
        '--output-format',
        'stream-json',
        if (m.isNotEmpty && m != 'default' && m != 'default-model') ...[
          '--model',
          CodeBuddyModels.of(m)?.effectiveCliModel ?? m,
        ],
        if (e.isNotEmpty) ...['--effort', e],
        '-p',
        prompt,
      ],
      'claude' => [
        '--dangerously-skip-permissions',
        '--verbose',
        '--output-format',
        'stream-json',
        if (m.isNotEmpty && m != 'default') ...['--model', m],
        if (e.isNotEmpty) ...['--effort', e],
        '-p',
        prompt,
      ],
      'codex' => [
        'exec',
        '--json',
        '--full-auto',
        if (m.isNotEmpty && m != 'default') ...['-m', m],
        if (e.isNotEmpty) ...['-c', 'model_reasoning_effort=$e'],
        prompt,
      ],
      _ => [
        '--dangerously-skip-permissions',
        '--output-format',
        'stream-json',
        if (m.isNotEmpty && m != 'default') ...['--model', m],
        if (e.isNotEmpty) ...['--effort', e],
        '-p',
        prompt,
      ],
    };
  }

  /// Runs a headless prompt directly against one of the 4 native kernels with
  /// live streaming output (closing stdin immediately so CLIs never hang).
  Future<({bool ok, String output, String? error})> runHeadlessPrompt({
    required String agentId,
    required String prompt,
    required String cwd,
    String? model,
    String? effort,
    void Function(String chunk)? onChunk,
    void Function(Process proc)? onProcessStarted,
    Duration timeout = const Duration(minutes: 15),
  }) async {
    final agent = byId(agentId);
    if (agent == null) {
      return (
        ok: false,
        output: '',
        error: 'Unknown agent: $agentId',
      );
    }
    if (headlessRunnerOverride case final runner?) {
      return runner(
        agentId: agent.id,
        prompt: prompt,
        cwd: cwd,
        model: model,
        effort: effort,
        onChunk: onChunk,
        onProcessStarted: onProcessStarted,
        timeout: timeout,
      );
    }

    final launch = await resolveKernelLaunch(agent.id);
    if (launch == null) {
      return (
        ok: false,
        output: '',
        error: '未在 PATH 或默认安装路径中找到内核可执行文件 "${agent.command}"。',
      );
    }

    final extraEnv = <String, String>{};
    try {
      final proxyEnv = await NetworkProxy.instance.environment();
      extraEnv.addAll(proxyEnv);
    } on Object {
      // Proxy resolution is best-effort; continue with inherited env.
    }

    if (agent.id == 'codebuddy') {
      await CodeBuddyAccounts.instance.ensureInitialized();
      var account = CodeBuddyAccounts.instance.currentAccount;
      if (account != null) {
        account = await CodeBuddyAccounts.instance.ensureFreshAccount(account);
        extraEnv.addAll(account.processEnvironment());
      }
    }

    final cliArgs = buildCliArgs(
      agentId: agent.id,
      prompt: prompt,
      model: model,
      effort: effort,
    );
    final useStreamJson =
        cliArgs.contains('stream-json') ||
        (agent.id == 'codex' && cliArgs.contains('--json'));

    return _runCliPrompt(
      bin: launch.executable,
      args: [...launch.prefixArgs, ...cliArgs],
      cwd: cwd,
      baseEnv: launch.environment,
      extraEnv: extraEnv,
      throughShell: launch.throughShell,
      streamJson: useStreamJson,
      onChunk: onChunk,
      onProcessStarted: onProcessStarted,
      timeout: timeout,
    );
  }

  Future<({bool ok, String output, String? error})> _runCliPrompt({
    required String bin,
    required List<String> args,
    required String cwd,
    Map<String, String> baseEnv = const {},
    Map<String, String> extraEnv = const {},
    bool throughShell = false,
    bool streamJson = false,
    void Function(String chunk)? onChunk,
    void Function(Process proc)? onProcessStarted,
    required Duration timeout,
  }) async {
    try {
      final mergedBase = <String, String>{
        ...Platform.environment,
        ...baseEnv,
        ...extraEnv,
      };
      final env = _withPath(mergedBase, buildEnrichedPath(mergedBase));
      final proc = await Process.start(
        bin,
        args,
        workingDirectory: cwd.isNotEmpty && Directory(cwd).existsSync()
            ? cwd
            : null,
        environment: env,
        includeParentEnvironment: Platform.isWindows,
        runInShell: throughShell,
      );
      onProcessStarted?.call(proc);
      // Critical: close stdin immediately so CLIs (agy/claude/codebuddy/codex)
      // never block waiting for piped stdin EOF.
      unawaited(proc.stdin.close().catchError((_) {}));

      final outBuf = StringBuffer();
      final errBuf = StringBuffer();
      String? finalResultText;
      String? streamError;
      var streamFailed = false;
      var unrecoveredError = false;
      var lineCarry = '';

      String extractCodexItemText(Map<Object?, Object?> item) {
        final direct = item['text'];
        if (direct is String) return direct;
        final content = item['content'];
        if (content is List) {
          final buf = StringBuffer();
          for (final block in content) {
            if (block is Map && block['text'] is String) {
              buf.write(block['text'] as String);
            }
          }
          return buf.toString();
        }
        return '';
      }

      void handleStreamLine(String rawLine) {
        final line = rawLine.trim();
        if (line.isEmpty) return;
        if (!streamJson || !line.startsWith('{')) {
          final chunk = '$rawLine\n';
          outBuf.write(chunk);
          onChunk?.call(chunk);
          return;
        }
        try {
          final decoded = jsonDecode(line);
          if (decoded is! Map) {
            final chunk = '$rawLine\n';
            outBuf.write(chunk);
            onChunk?.call(chunk);
            return;
          }
          // 1) Antigravity (agy) stream-json schema
          if (decoded['event'] case final String ev) {
            if (ev == 'init') {
              onChunk?.call('[Agent] 已初始化会话，开始分析任务…\n');
            } else if (ev == 'step_update') {
              final step = decoded['step_update'];
              if (step is Map) {
                final textDelta = step['text_delta'] as String?;
                final stepType = step['step_type'] as String? ?? '';
                final state = step['state'] as String? ?? '';
                final toolName =
                    step['tool_name'] as String? ??
                    step['name'] as String? ??
                    '';
                if (textDelta != null && textDelta.isNotEmpty) {
                  outBuf.write(textDelta);
                  onChunk?.call(textDelta);
                } else if (state == 'ACTIVE' &&
                    stepType.isNotEmpty &&
                    stepType != 'user_input' &&
                    stepType != 'agent_response') {
                  final label = toolName.isNotEmpty
                      ? '$stepType ($toolName)'
                      : stepType;
                  onChunk?.call('\n⚙ [工具] $label…\n');
                }
              }
            } else if (ev == 'result') {
              final res = decoded['result'];
              if (res is Map) {
                final resp = res['response'] as String?;
                if (resp != null && resp.trim().isNotEmpty) {
                  finalResultText = resp;
                  if (outBuf.isEmpty) {
                    outBuf.write(resp);
                    onChunk?.call(resp);
                  }
                }
              }
            }
            return;
          }

          // 2) Claude Code / CodeBuddy stream-json & Codex exec --json NDJSON
          if (decoded['type'] case final String type) {
            if (type == 'system' && decoded['subtype'] == 'init') {
              onChunk?.call('[Agent] 已初始化会话，开始分析任务…\n');
            } else if (type == 'content_block_delta') {
              final delta = decoded['delta'];
              if (delta is Map && delta['text'] is String) {
                final text = delta['text'] as String;
                outBuf.write(text);
                onChunk?.call(text);
              }
            } else if (type == 'assistant') {
              final msg = decoded['message'];
              if (msg is Map && msg['content'] is List) {
                for (final block in msg['content'] as List) {
                  if (block is Map) {
                    if (block['type'] == 'text' && block['text'] is String) {
                      final text = block['text'] as String;
                      if (text.isNotEmpty) {
                        outBuf.write(text);
                        onChunk?.call(text);
                      }
                    } else if (block['type'] == 'tool_use') {
                      final name = block['name'] as String? ?? 'tool';
                      onChunk?.call('\n⚙ [调用工具] $name…\n');
                    }
                  }
                }
              }
            } else if (type == 'result') {
              final res = decoded['result'] as String?;
              if (res != null && res.trim().isNotEmpty) {
                finalResultText = res;
                if (outBuf.isEmpty) {
                  outBuf.write(res);
                  onChunk?.call(res);
                }
              }
            } else if (type == 'thread.started') {
              onChunk?.call('[Codex] 会话已启动…\n');
            } else if (type == 'turn.started') {
              // Lifecycle marker; no extra output needed.
            } else if (type == 'turn.completed') {
              unrecoveredError = false;
            } else if (type == 'error') {
              final errObj = decoded['error'];
              final msg =
                  '${decoded['message'] ?? (errObj is Map ? errObj['message'] : null) ?? ''}'
                      .trim();
              unrecoveredError = true;
              if (msg.isNotEmpty) {
                streamError = msg;
                onChunk?.call('\n[Codex Error] $msg\n');
              }
            } else if (type == 'turn.failed') {
              streamFailed = true;
              final errObj = decoded['error'];
              final msg =
                  '${(errObj is Map ? errObj['message'] : null) ?? decoded['message'] ?? ''}'
                      .trim();
              if (msg.isNotEmpty) {
                streamError = msg;
                onChunk?.call('\n[Codex Failed] $msg\n');
              }
            } else if (type == 'item.started' ||
                type == 'item.updated' ||
                type == 'item.completed') {
              final item = decoded['item'];
              if (item is Map) {
                final itemType = '${item['type'] ?? ''}';
                switch (itemType) {
                  case 'agent_message' || 'agentMessage':
                    if (type == 'item.completed') {
                      final text = extractCodexItemText(item);
                      if (text.trim().isNotEmpty) {
                        unrecoveredError = false;
                        finalResultText = text;
                        outBuf.write(text);
                        onChunk?.call(text);
                      }
                    }
                  case 'command_execution' || 'commandExecution':
                    final cmd = '${item['command'] ?? ''}'.trim();
                    if (type == 'item.started') {
                      onChunk?.call('\n⚙ [命令] $cmd…\n');
                    } else if (type == 'item.completed') {
                      final exitCode = item['exit_code'] ?? item['exitCode'];
                      onChunk?.call(
                        '\n⚙ [命令完成] $cmd (exit=${exitCode ?? '?'})\n',
                      );
                    }
                  case 'file_change' || 'fileChange':
                    if (type == 'item.completed') {
                      final changes = item['changes'];
                      final paths = <String>[
                        if (changes is List)
                          for (final c in changes)
                            if (c is Map && c['path'] != null) '${c['path']}',
                      ];
                      final summary = paths.isEmpty
                          ? '${item['status'] ?? 'updated'}'
                          : paths.take(5).join(', ');
                      onChunk?.call('\n⚙ [文件变更] $summary\n');
                    }
                  case 'mcp_tool_call' || 'mcpToolCall':
                    if (type == 'item.started' || type == 'item.completed') {
                      final server = '${item['server'] ?? ''}'.trim();
                      final tool = '${item['tool'] ?? ''}'.trim();
                      final name = server.isNotEmpty && tool.isNotEmpty
                          ? '$server.$tool'
                          : (tool.isNotEmpty ? tool : server);
                      onChunk?.call('\n⚙ [MCP] $name\n');
                    }
                  case 'web_search' || 'webSearch':
                    if (type == 'item.started') {
                      final query = '${item['query'] ?? ''}'.trim();
                      onChunk?.call('\n⚙ [搜索] $query\n');
                    }
                  case 'reasoning':
                    if (type == 'item.completed') {
                      final text = extractCodexItemText(item).trim();
                      if (text.isNotEmpty) {
                        onChunk?.call('\n💭 [思考] $text\n');
                      }
                    }
                }
              }
            }
            return;
          }
        } on Object {
          onChunk?.call('$rawLine\n');
        }
      }

      final subOut = proc.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen((c) {
            if (!streamJson) {
              outBuf.write(c);
              onChunk?.call(c);
              return;
            }
            lineCarry += c;
            while (true) {
              final nl = lineCarry.indexOf('\n');
              if (nl < 0) break;
              final line = lineCarry.substring(0, nl);
              lineCarry = lineCarry.substring(nl + 1);
              handleStreamLine(line);
            }
          });
      final subErr = proc.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen((c) {
            errBuf.write(c);
            onChunk?.call(c);
          });
      final code = await proc.exitCode.timeout(
        timeout,
        onTimeout: () async {
          await killProcessTree(proc);
          return -1;
        },
      );
      await subOut.cancel();
      await subErr.cancel();
      if (streamJson && lineCarry.trim().isNotEmpty) {
        handleStreamLine(lineCarry);
      }
      final effectiveOutput =
          (finalResultText != null && finalResultText!.trim().isNotEmpty)
          ? finalResultText!
          : outBuf.toString();
      final stderrText = errBuf.toString().trim();
      final hasFailed = code != 0 || streamFailed || unrecoveredError;
      final effectiveError = !hasFailed
          ? null
          : (stderrText.isNotEmpty
                ? stderrText
                : (streamError != null && streamError!.isNotEmpty
                      ? streamError
                      : (code != 0 ? 'Exited with code $code' : 'Turn failed')));
      return (
        ok: !hasFailed,
        output: effectiveOutput,
        error: effectiveError,
      );
    } on Object catch (e) {
      return (ok: false, output: '', error: '$e');
    }
  }
}
