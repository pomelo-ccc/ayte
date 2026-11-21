import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../kernel/antigravity/antigravity_cli.dart';
import '../kernel/claude_code/claude_code_kernel.dart';
import '../kernel/codebuddy/codebuddy_accounts.dart';
import '../kernel/codebuddy/codebuddy_cli.dart';
import '../kernel/codex/codex_models.dart';
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
      args: ['exec', '--full-auto'],
      builtIn: true,
    ),
  ];

  List<AcpAgentProfile> get selectableAgents => builtInAgents;

  AcpAgentProfile? byId(String id) {
    for (final a in builtInAgents) {
      if (a.id == id) return a;
    }
    return null;
  }

  /// Returns live/local selectable models for one of the 4 native kernels.
  List<WorkflowModelOption> modelsForAgent(String agentId) {
    switch (agentId) {
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
        if (cached is List) {
          for (final raw in cached) {
            if (raw is Map) {
              final id = '${raw['value'] ?? raw['id'] ?? ''}'.trim();
              final label =
                  '${raw['displayName'] ?? raw['label'] ?? id}'.trim();
              if (id.isNotEmpty && id != 'default') {
                out.add(
                  WorkflowModelOption(
                    id: id,
                    label: label,
                    description: '${raw['description'] ?? ''}'.trim(),
                    effortLevels: const ['low', 'medium', 'high', 'max'],
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

  /// Builds an enriched PATH suitable for macOS GUI `.app` processes so Node,
  /// Angular CLI, tmux, Homebrew, and kernel binaries resolve reliably.
  static String buildEnrichedPath() {
    final home = Platform.environment['HOME'] ?? '';
    final currentPath = Platform.environment['PATH'] ?? '';
    final parts = <String>[
      if (home.isNotEmpty) p.join(home, '.local', 'bin'),
      if (home.isNotEmpty) p.join(home, '.hermes', 'node', 'bin'),
      if (home.isNotEmpty) p.join(home, '.gemini', 'bin'),
      if (home.isNotEmpty) p.join(home, '.codebuddy', 'bin'),
      if (home.isNotEmpty) p.join(home, '.bun', 'bin'),
      if (home.isNotEmpty) p.join(home, '.volta', 'bin'),
      '/opt/homebrew/bin',
      '/usr/local/bin',
      '/usr/bin',
      '/bin',
      if (currentPath.isNotEmpty) currentPath,
    ];
    return parts.join(Platform.isWindows ? ';' : ':');
  }

  /// Resolves a native kernel executable on PATH or common install locations.
  Future<String?> resolveBinary(String command) async {
    if (File(command).existsSync()) return command;
    final home = Platform.environment['HOME'] ?? '';
    final candidates = [
      p.join(home, '.local', 'bin', command),
      p.join(home, '.hermes', 'node', 'bin', command),
      p.join(home, '.gemini', 'bin', command),
      p.join(home, '.codebuddy', 'bin', command),
      p.join(home, '.bun', 'bin', command),
      '/opt/homebrew/bin/$command',
      '/usr/local/bin/$command',
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    try {
      final res = await Process.run('which', [command]);
      if (res.exitCode == 0) {
        final out = '${res.stdout}'.trim();
        if (out.isNotEmpty) return out;
      }
    } on Object {
      // Ignore.
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
    return switch (agentId) {
      'agy' => [
        '--dangerously-skip-permissions',
        '--output-format',
        'stream-json',
        if (m.isNotEmpty) ...['--model', AntigravityModels.cliModelIdOf(m)],
        if (e.isNotEmpty) ...['--effort', e],
        '-p',
        prompt,
      ],
      'codebuddy' => [
        '-y',
        '--output-format',
        'stream-json',
        if (m.isNotEmpty) ...[
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
        '--full-auto',
        if (m.isNotEmpty) ...['-m', m],
        if (e.isNotEmpty) ...['-c', 'model_reasoning_effort=$e'],
        prompt,
      ],
      _ => [
        '--dangerously-skip-permissions',
        '--output-format',
        'stream-json',
        if (m.isNotEmpty) ...['--model', m],
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
    final agent = byId(agentId) ?? builtInAgents.first;
    final bin = await resolveBinary(agent.command);
    if (bin == null) {
      return (
        ok: false,
        output: '',
        error: '未在 PATH 中找到内核可执行文件 "${agent.command}"。',
      );
    }

    final extraEnv = <String, String>{};
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
    final useStreamJson = cliArgs.contains('stream-json');

    return _runCliPrompt(
      bin: bin,
      args: cliArgs,
      cwd: cwd,
      extraEnv: extraEnv,
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
    Map<String, String> extraEnv = const {},
    bool streamJson = false,
    void Function(String chunk)? onChunk,
    void Function(Process proc)? onProcessStarted,
    required Duration timeout,
  }) async {
    try {
      final env = <String, String>{
        ...Platform.environment,
        'PATH': buildEnrichedPath(),
        ...extraEnv,
      };
      final proc = await Process.start(
        bin,
        args,
        workingDirectory: cwd.isNotEmpty && Directory(cwd).existsSync()
            ? cwd
            : null,
        environment: env,
      );
      onProcessStarted?.call(proc);
      // Critical: close stdin immediately so CLIs (agy/claude/codebuddy/codex)
      // never block waiting for piped stdin EOF.
      unawaited(proc.stdin.close().catchError((_) {}));

      final outBuf = StringBuffer();
      final errBuf = StringBuffer();
      String? finalResultText;
      var lineCarry = '';

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

          // 2) Claude Code / CodeBuddy stream-json schema
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
            }
            return;
          }
        } on Object {
          final chunk = '$rawLine\n';
          outBuf.write(chunk);
          onChunk?.call(chunk);
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
        onTimeout: () {
          proc.kill();
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
      return (
        ok: code == 0,
        output: effectiveOutput,
        error: code == 0
            ? null
            : (errBuf.toString().trim().isEmpty
                  ? 'Exited with code $code'
                  : errBuf.toString().trim()),
      );
    } on Object catch (e) {
      return (ok: false, output: '', error: '$e');
    }
  }
}
