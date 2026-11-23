import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../claude_code/claude_code_transport.dart';
import '../claude_code/claude_environment.dart';
import '../claude_code/claude_path_setting.dart';

/// Built-in provider id for Antigravity CLI (`agy`) in Settings → Models
/// and the session model picker.
const antigravityBuiltinProviderId = 'antigravity-cli';

/// Settings → General → Antigravity CLI: custom executable path
/// (`antigravity.path` in settings.json).
abstract final class AntigravityPathSetting {
  static const settingKey = 'antigravity.path';

  static String? parse(Object? value) => switch (value) {
    final String path when path.trim().isNotEmpty => path.trim(),
    _ => null,
  };

  /// The path set now: main.dart reads it from settings.json.
  static String? Function() current = () => null;
}

/// Canonical reasoning effort tiers supported by `agy --effort`.
const antigravityEffortOrder = ['low', 'medium', 'high', 'xhigh', 'max'];

/// Native preset context window choices defined by `agy` (`ParsePresetContextWindow`).
const antigravityPresetContextChoices = <int, String>{
  256000: '256K',
  512000: '512K',
  900000: '900K',
};

/// A deduplicated model family offered by Antigravity CLI (`agy`).
class AntigravityModel {
  const AntigravityModel({
    required this.id,
    required this.label,
    this.cliModelId,
    this.description = '',
    this.effortLevels = const [],
    this.defaultEffort,
    this.contextOptions = const [256000],
    this.defaultContext = 256000,
    this.supportsPresetContextWindow = false,
  });

  /// Canonical family id (e.g. `gemini-4-carbon`, `claude-opus-5-5`).
  final String id;

  /// Actual `--model` flag value passed to `agy` (`id` by default, or an
  /// explicit single-tier id such as `gpt-oss-120b-medium`).
  final String? cliModelId;

  /// Clean display name without `(Low)` / `(Medium)` / `(High)` suffix.
  final String label;

  /// Short capability summary shown in descriptions.
  final String description;

  /// Supported `--effort` levels when 2+ levels are available.
  final List<String> effortLevels;

  /// Default effort level when [effortLevels] is non-empty.
  final String? defaultEffort;

  /// Selectable context window capacities (in tokens).
  final List<int> contextOptions;

  /// Default context window capacity (in tokens).
  final int defaultContext;

  /// Whether `agy` natively switches this model's server preset window via
  /// `--settings={"contextWindow":"256K"|"512K"|"900K"}` (`offersContextWindow`).
  final bool supportsPresetContextWindow;

  String get effectiveCliModel => cliModelId ?? id;

  /// Resolves [candidate] to a valid option in [contextOptions], snapping
  /// legacy values (such as `200000` or `400000`) to the closest `agy` option.
  int resolveContextWindow(int? candidate) {
    if (contextOptions.isEmpty) return defaultContext;
    if (candidate == null || candidate <= 0) return defaultContext;
    if (contextOptions.contains(candidate)) return candidate;
    var best = contextOptions.first;
    var bestDiff = (candidate - best).abs();
    for (final option in contextOptions.skip(1)) {
      final diff = (candidate - option).abs();
      if (diff < bestDiff || (diff == bestDiff && option > best)) {
        best = option;
        bestDiff = diff;
      }
    }
    return best;
  }

  /// Menu label for a selectable context window option (`baseLabel` is e.g.
  /// `256K` or `512K`).
  String contextOptionLabel(String baseLabel, int tokens) {
    if (contextOptions.length == 1) return '$baseLabel（官方固定）';
    if (!supportsPresetContextWindow && tokens > defaultContext) {
      return '$baseLabel（强制）';
    }
    return baseLabel;
  }

  /// Human-readable description for a selectable context window option.
  String contextOptionDescription(int tokens) {
    if (supportsPresetContextWindow) {
      return switch (tokens) {
        256000 => '默认窗口 · 1x 配额倍率',
        512000 => '扩展窗口 · 1.3x 配额倍率',
        900000 => '超长窗口 · 1.8x 配额倍率',
        _ => tokens == defaultContext ? '默认窗口' : '扩展上下文窗口',
      };
    }
    if (tokens == defaultContext) return '默认完整窗口';
    if (tokens > defaultContext) {
      return '强制 ${antigravityPresetContextChoices[tokens] ?? '$tokens'} 上下文窗口';
    }
    return switch (tokens) {
      64000 => '64K 自动压缩阈值',
      256000 => '256K 自动压缩阈值',
      512000 => '512K 自动压缩阈值',
      900000 => '900K 自动压缩阈值',
      _ => '提前自动压缩，降低长对话延迟',
    };
  }
}

/// Built-in and dynamically queried model families of Antigravity CLI (`agy`).
abstract final class AntigravityModels {
  static const List<AntigravityModel> defaults = [
    AntigravityModel(
      id: 'gemini-4-neon',
      label: 'Gemini 4 Neon',
      description: '256K–512K context · Frontier reasoning & coding',
      effortLevels: ['low', 'medium', 'high', 'xhigh'],
      defaultEffort: 'high',
      contextOptions: [256000, 512000],
      defaultContext: 256000,
    ),
    AntigravityModel(
      id: 'gemini-4-carbon',
      label: 'Gemini 4 Carbon',
      description: '256K–512K context · Frontier deep reasoning',
      effortLevels: ['low', 'medium', 'high'],
      defaultEffort: 'high',
      contextOptions: [256000, 512000],
      defaultContext: 256000,
    ),
    AntigravityModel(
      id: 'gemini-4-argon',
      label: 'Gemini 4 Argon',
      description: '256K–900K context · Frontier reasoning & coding',
      effortLevels: ['low', 'medium', 'high'],
      defaultEffort: 'high',
      contextOptions: [256000, 512000, 900000],
      defaultContext: 256000,
      supportsPresetContextWindow: true,
    ),
    AntigravityModel(
      id: 'gemini-4-hydrogen',
      label: 'Gemini 4 Hydrogen',
      description: '256K–512K context · High-speed agentic engine',
      effortLevels: ['low', 'medium', 'high', 'xhigh'],
      defaultEffort: 'high',
      contextOptions: [256000, 512000],
      defaultContext: 256000,
    ),
    AntigravityModel(
      id: 'gemini-pro-orchestrator-neon',
      label: 'Orchestrator (Neon)',
      description: '256K–512K context · Neon planner + Hydrogen executor',
      contextOptions: [256000, 512000],
      defaultContext: 256000,
    ),
    AntigravityModel(
      id: 'gemini-pro-orchestrator',
      label: 'Orchestrator (Carbon)',
      description: '256K–512K context · Carbon planner + Hydrogen executor',
      contextOptions: [256000, 512000],
      defaultContext: 256000,
    ),
    AntigravityModel(
      id: 'gemini-pro-orchestrator-argon',
      label: 'Orchestrator (Argon)',
      description: '256K–512K context · Argon planner + Hydrogen executor',
      contextOptions: [256000, 512000],
      defaultContext: 256000,
    ),
    AntigravityModel(
      id: 'gemini-3.8-flash',
      label: 'Gemini 3.8 Flash',
      description: '256K–512K context · Low-latency coding & sub-tasks',
      effortLevels: ['low', 'medium', 'high'],
      defaultEffort: 'high',
      contextOptions: [256000, 512000],
      defaultContext: 256000,
    ),
    AntigravityModel(
      id: 'claude-opus-5-5',
      label: 'Claude Opus 5.5',
      description: '256K–512K context · Anthropic flagship reasoning',
      effortLevels: ['low', 'medium', 'high'],
      defaultEffort: 'high',
      contextOptions: [256000, 512000],
      defaultContext: 256000,
    ),
    AntigravityModel(
      id: 'claude-sonnet-5-5',
      label: 'Claude Sonnet 5.5',
      description: '256K–512K context · Balanced Anthropic coding model',
      effortLevels: ['low', 'medium', 'high'],
      defaultEffort: 'medium',
      contextOptions: [256000, 512000],
      defaultContext: 256000,
    ),
    AntigravityModel(
      id: 'gpt-oss-120b',
      cliModelId: 'gpt-oss-120b-medium',
      label: 'GPT-OSS 120B',
      description: '128K context · Open-weight reasoning model',
      contextOptions: [128000],
      defaultContext: 128000,
    ),
  ];

  static List<AntigravityModel> _current = defaults;

  static List<AntigravityModel> get current => _current;

  static final RegExp _effortIdSuffix = RegExp(
    r'-(low|medium|high|xhigh|max)$',
    caseSensitive: false,
  );
  static final RegExp _effortLabelSuffix = RegExp(
    r'\s*\((Low|Medium|High|XHigh|Max)\)$',
    caseSensitive: false,
  );

  /// Strips `@antigravity-cli/` prefix if present.
  static String stripPrefix(String? model) {
    if (model == null || model.isEmpty) return '';
    const prefix = '@$antigravityBuiltinProviderId/';
    return model.startsWith(prefix) ? model.substring(prefix.length) : model;
  }

  /// Splits a raw variant ID like `gemini-4-carbon-high` into
  /// `(familyId: 'gemini-4-carbon', effort: 'high')`.
  static ({String familyId, String? effort}) splitVariantId(String rawId) {
    final trimmed = stripPrefix(rawId).trim();
    final match = _effortIdSuffix.firstMatch(trimmed);
    if (match == null) return (familyId: trimmed, effort: null);
    return (
      familyId: trimmed.substring(0, match.start),
      effort: match.group(1)!.toLowerCase(),
    );
  }

  /// Looks up the [AntigravityModel] family matching [model] (accepts both
  /// `@antigravity-cli/<id>`, family IDs like `gemini-4-carbon`, and legacy
  /// variant IDs like `gemini-4-carbon-medium`).
  static AntigravityModel? of(String? model) {
    if (model == null || model.isEmpty) return null;
    final prefixed = model.startsWith('@$antigravityBuiltinProviderId/');
    final bare = stripPrefix(model);
    if (bare.isEmpty) return null;
    if (bare == 'default') return prefixed ? _current.first : null;
    for (final m in _current) {
      if (m.id == bare || m.effectiveCliModel == bare) return m;
    }
    final (:familyId, effort: _) = splitVariantId(bare);
    for (final m in _current) {
      if (m.id == familyId) return m;
    }
    return null;
  }

  /// Resolves [model] into its canonical [AntigravityModel] and any explicit
  /// effort suffix carried by a legacy variant string.
  static ({AntigravityModel model, String? effort})? parseVariant(
    String? model,
  ) {
    final found = of(model);
    if (found == null) return null;
    final (:familyId, :effort) = splitVariantId(stripPrefix(model ?? ''));
    final validEffort =
        effort != null && found.effortLevels.contains(effort) ? effort : null;
    return (model: found, effort: validEffort);
  }

  /// Whether [model] is an `@antigravity-cli/<id>` reference or a known
  /// Antigravity CLI model/variant ID.
  static bool isAntigravityModel(String? model) {
    if (model == null || model.isEmpty) return false;
    if (model.startsWith('@$antigravityBuiltinProviderId/')) return true;
    return of(model) != null;
  }

  /// Canonical bare family ID (e.g. `gemini-4-carbon`) for UI selection state.
  static String bareModelId(String? model) {
    final found = of(model);
    if (found != null) return found.id;
    final bare = stripPrefix(model);
    if (bare.isEmpty || bare == 'default') return _current.first.id;
    return splitVariantId(bare).familyId;
  }

  /// CLI `--model` argument to pass to `agy`.
  static String cliModelIdOf(String? model) {
    final found = of(model);
    if (found != null) return found.effectiveCliModel;
    final bare = stripPrefix(model);
    if (bare.isEmpty || bare == 'default') return _current.first.effectiveCliModel;
    return bare;
  }

  /// Display label for [modelId].
  static String labelOf(String modelId) {
    return of(modelId)?.label ?? bareModelId(modelId);
  }

  /// Returns the canonical `agy` `--settings` `contextWindow` string (`"256K"`,
  /// `"512K"`, or `"900K"`) when [tokens] matches a preset window.
  static String? presetContextWindowName(int tokens) =>
      antigravityPresetContextChoices[tokens];

  /// Context window presets inferred for a dynamically discovered model family.
  ///
  /// Both Antigravity IDE (`R.base === "Gemini 4 Argon"`) and `agy` CLI
  /// (`backend.ContextWindowSelectable = ["Gemini 4 Argon"]`) only expose
  /// selectable `256K / 512K / 900K` windows on `Gemini 4 Argon`; all other
  /// families use Cortex's fixed `256K` (`256,000`) checkpoint limit (`128K`
  /// for `gpt-oss-*`).
  static ({
    List<int> options,
    int defaultContext,
    String summary,
    bool supportsPreset,
  })
  _contextProfileFor(String familyId) {
    final lower = familyId.toLowerCase();
    if (lower.startsWith('gpt-oss')) {
      return (
        options: const [128000],
        defaultContext: 128000,
        summary: '128K context · Open-weight model',
        supportsPreset: false,
      );
    }
    if (lower == 'gemini-4-argon') {
      return (
        options: const [256000, 512000, 900000],
        defaultContext: 256000,
        summary: '256K–900K context · Google Antigravity',
        supportsPreset: true,
      );
    }
    if (lower.startsWith('claude-')) {
      return (
        options: const [256000, 512000],
        defaultContext: 256000,
        summary: '256K–512K context · Anthropic coding model',
        supportsPreset: false,
      );
    }
    return (
      options: const [256000, 512000],
      defaultContext: 256000,
      summary: '256K–512K context · Google Antigravity',
      supportsPreset: false,
    );
  }

  /// Updates the cached model list from `agy --output-format json models`,
  /// collapsing `(Low)` / `(Medium)` / `(High)` / `(XHigh)` / `(Max)` rows
  /// into clean model families with structured effort & context options.
  static void updateFromJson(Object? decoded) {
    if (decoded is! Map) return;
    final command = decoded['command'];
    if (command is! Map) return;
    final data = command['data'];
    if (data is! Map) return;
    final rawModels = data['models'];
    if (rawModels is! List || rawModels.isEmpty) return;

    final groups = <String, _FamilyBuilder>{};
    final order = <String>[];

    for (final item in rawModels) {
      if (item is! Map || item['id'] is! String) continue;
      final rawId = (item['id'] as String).trim();
      if (rawId.isEmpty) continue;
      final rawLabel = ((item['label'] as String?) ?? rawId).trim();

      final (:familyId, :effort) = splitVariantId(rawId);
      final cleanLabel = effort != null
          ? rawLabel.replaceFirst(_effortLabelSuffix, '').trim()
          : rawLabel;

      final builder = groups.putIfAbsent(familyId, () {
        order.add(familyId);
        return _FamilyBuilder(familyId: familyId, label: cleanLabel);
      });
      builder.rawVariantIds.add(rawId);
      if (effort != null && !builder.efforts.contains(effort)) {
        builder.efforts.add(effort);
      }
    }

    if (order.isEmpty) return;

    final byDefaultId = {for (final m in defaults) m.id: m};
    final parsed = <AntigravityModel>[];

    for (final familyId in order) {
      final b = groups[familyId]!;
      final sortedEfforts = [
        for (final level in antigravityEffortOrder)
          if (b.efforts.contains(level)) level,
      ];
      final preset = byDefaultId[familyId];
      final profile = _contextProfileFor(familyId);
      final multiEffort = sortedEfforts.length > 1;
      final defaultEffort = multiEffort
          ? (preset?.defaultEffort != null &&
                    sortedEfforts.contains(preset!.defaultEffort)
                ? preset.defaultEffort
                : sortedEfforts.contains('high')
                ? 'high'
                : sortedEfforts.first)
          : null;

      parsed.add(
        AntigravityModel(
          id: familyId,
          cliModelId: multiEffort ? null : b.rawVariantIds.first,
          label: b.label.isNotEmpty ? b.label : (preset?.label ?? familyId),
          description: preset?.description ?? profile.summary,
          effortLevels: multiEffort ? sortedEfforts : const [],
          defaultEffort: defaultEffort,
          contextOptions: preset?.contextOptions ?? profile.options,
          defaultContext: preset?.defaultContext ?? profile.defaultContext,
          supportsPresetContextWindow:
              preset?.supportsPresetContextWindow ?? profile.supportsPreset,
        ),
      );
    }

    if (parsed.isNotEmpty) {
      _current = parsed;
    }
  }
}

class _FamilyBuilder {
  _FamilyBuilder({required this.familyId, required this.label});

  final String familyId;
  final String label;
  final List<String> rawVariantIds = [];
  final List<String> efforts = [];
}

/// Locates and inspects the Antigravity CLI (`agy`) on this machine.
abstract final class LocalAntigravity {
  static bool? _installed;
  static Map<String, String>? _shellEnv;

  static String? _lookupEnvVar(
    Map<String, String> env,
    String name, {
    required bool win,
  }) {
    if (env[name] case final v? when v.isNotEmpty) return v;
    if (win) {
      final lower = name.toLowerCase();
      for (final entry in env.entries) {
        if (entry.key.toLowerCase() == lower && entry.value.isNotEmpty) {
          return entry.value;
        }
      }
      for (final entry in env.entries) {
        if (entry.key.toLowerCase() == lower) {
          return entry.value;
        }
      }
    } else if (env.containsKey(name)) {
      return env[name];
    }
    return null;
  }

  static String _resolveHome(
    Map<String, String> env, {
    required bool win,
  }) {
    final baseHome = _lookupEnvVar(env, 'HOME', win: win);
    if (baseHome != null && baseHome.isNotEmpty) return baseHome;
    final baseUserProfile = _lookupEnvVar(env, 'USERPROFILE', win: win);
    if (baseUserProfile != null && baseUserProfile.isNotEmpty) {
      return baseUserProfile;
    }
    if (baseHome != null || baseUserProfile != null) {
      return '';
    }
    final hostHome = _lookupEnvVar(Platform.environment, 'HOME', win: win);
    if (hostHome != null && hostHome.isNotEmpty) return hostHome;
    return _lookupEnvVar(Platform.environment, 'USERPROFILE', win: win) ?? '';
  }

  static String _readPathVar(
    Map<String, String> env, {
    required bool win,
  }) =>
      _lookupEnvVar(env, 'PATH', win: win) ??
      _lookupEnvVar(Platform.environment, 'PATH', win: win) ??
      '';

  static String _expandHome(String path, Map<String, String> env) {
    if (path == '~' || path.startsWith('~/') || path.startsWith(r'~\')) {
      final home = _resolveHome(env, win: Platform.isWindows);
      return '$home${path.substring(1)}';
    }
    return path;
  }

  @visibleForTesting
  static List<String> candidatesForTesting(
    Map<String, String> env, {
    bool? forceWindows,
    bool? forceMacOS,
    bool? forceLinux,
  }) => _candidates(
    env,
    forceWindows: forceWindows,
    forceMacOS: forceMacOS,
    forceLinux: forceLinux,
  );

  @visibleForTesting
  static String? findExecutableForTesting(
    Map<String, String> env, {
    bool? forceWindows,
  }) => _findExecutable(env, forceWindows: forceWindows);

  /// Candidate binary locations for `agy`, in priority order (explicit `PATH`
  /// entries first, followed by standard installation directories).
  static List<String> _candidates(
    Map<String, String> env, {
    bool? forceWindows,
    bool? forceMacOS,
    bool? forceLinux,
  }) {
    final win = forceWindows ?? Platform.isWindows;
    final mac = forceMacOS ?? (!win && Platform.isMacOS);
    final linux = forceLinux ?? (!win && !mac && Platform.isLinux);
    final home = _resolveHome(env, win: win);
    final exe = win ? 'agy.exe' : 'agy';
    final paths = <String>[];
    final seen = <String>{};
    void addCandidate(String candidate) {
      final key = win ? candidate.toLowerCase() : candidate;
      if (seen.add(key)) {
        paths.add(candidate);
      }
    }

    final pathVar = _readPathVar(env, win: win);
    final sep = win ? ';' : ':';
    for (final dir in pathVar.split(sep)) {
      final trimmed = dir.trim();
      if (trimmed.isEmpty) continue;
      addCandidate(win ? p.windows.join(trimmed, exe) : p.join(trimmed, exe));
    }

    if (home.isNotEmpty) {
      final join = win ? p.windows.join : p.join;
      addCandidate(join(home, '.gemini', 'bin', exe));
      addCandidate(join(home, '.local', 'bin', exe));
      addCandidate(join(home, '.antigravity', 'antigravity', 'bin', exe));
    }
    if (mac) {
      addCandidate('/Applications/Gemini.app/Contents/Helpers/agy');
      addCandidate('/Applications/Antigravity.app/Contents/Resources/app/bin/agy');
      addCandidate('/opt/homebrew/bin/agy');
      addCandidate('/usr/local/bin/agy');
    }
    if (linux) {
      addCandidate('/usr/local/bin/agy');
      addCandidate('/usr/bin/agy');
    }
    return paths;
  }

  static String? _findExecutable(
    Map<String, String> env, {
    bool? forceWindows,
  }) {
    final configured = AntigravityPathSetting.current();
    if (configured != null) {
      final expanded = _expandHome(configured, env);
      return File(expanded).existsSync() ? expanded : null;
    }
    for (final candidate in _candidates(env, forceWindows: forceWindows)) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  /// Whether `agy` is installed on this machine.
  static bool installed() {
    if (kIsWeb) return false;
    final configured = AntigravityPathSetting.current();
    if (configured != null) {
      final env = _shellEnv ?? Platform.environment;
      return File(_expandHome(configured, env)).existsSync();
    }
    return _installed ??=
        _findExecutable(_shellEnv ?? Platform.environment) != null;
  }

  /// Looks for `agy` on the user's login shell PATH and refreshes its models.
  static Future<void> lookForInstall() async {
    if (kIsWeb) return;
    try {
      final env = await ClaudeEnvironment.of();
      _shellEnv = env;
      final exe = _findExecutable(env);
      _installed = exe != null;
      if (exe != null) {
        unawaited(_refreshModels(exe, env));
      }
    } on Object catch (error) {
      debugPrint('Antigravity CLI not looked for: $error');
    }
  }

  static Future<void> _refreshModels(
    String executable,
    Map<String, String> env,
  ) async {
    try {
      final result = await Process.run(
        executable,
        const ['--output-format', 'json', 'models'],
        environment: env,
      ).timeout(const Duration(seconds: 6));
      if (result.exitCode == 0) {
        final stdout = '${result.stdout}'.trim();
        for (final line in const LineSplitter().convert(stdout)) {
          if (line.trim().startsWith('{')) {
            AntigravityModels.updateFromJson(jsonDecode(line));
          }
        }
      }
    } on Object {
      // Fall back to AntigravityModels.defaults.
    }
  }

  /// Status of `agy` on this machine for Settings → General.
  static Future<LocalClaudeStatus?> status() async {
    if (kIsWeb) return null;
    final env = await ClaudeEnvironment.of();
    _shellEnv = env;
    final configured = AntigravityPathSetting.current();
    if (configured != null) {
      final expanded = _expandHome(configured, env);
      if (!File(expanded).existsSync()) {
        _installed = false;
        return LocalClaudeFailed('找不到可执行文件：$expanded');
      }
      final version = await _versionOf(expanded, env);
      _installed = true;
      return LocalClaudeFound(expanded, version);
    }
    final exe = _findExecutable(env);
    if (exe == null) {
      _installed = false;
      return const LocalClaudeMissing();
    }
    _installed = true;
    final version = await _versionOf(exe, env);
    unawaited(_refreshModels(exe, env));
    return LocalClaudeFound(exe, version);
  }

  static Future<String?> _versionOf(
    String executable,
    Map<String, String> env,
  ) async {
    try {
      final result = await Process.run(
        executable,
        const ['--version'],
        environment: env,
      ).timeout(const Duration(seconds: 5));
      if (result.exitCode == 0) {
        final out = '${result.stdout}'.trim();
        if (out.isNotEmpty) return out.split('\n').first.trim();
      }
    } on Object {
      // Ignore version probe errors.
    }
    return null;
  }

  /// Locates the `agy` executable to launch a session, or throws
  /// [ClaudeUnavailable] if not found.
  static Future<({String executable, Map<String, String> environment})>
  locate() async {
    final env = await ClaudeEnvironment.of();
    _shellEnv = env;
    final configured = AntigravityPathSetting.current();
    if (configured != null) {
      final expanded = _expandHome(configured, env);
      if (!File(expanded).existsSync()) {
        throw ClaudeUnavailable(
          'Antigravity CLI (agy) 未找到',
          detail:
              '在路径 $expanded 未找到可执行文件。\n'
              '请在「设置 → 通用 → Antigravity CLI」中修正路径，或清空以自动查找。',
        );
      }
      return (executable: expanded, environment: env);
    }
    final exe = _findExecutable(env);
    if (exe == null) {
      throw const ClaudeUnavailable(
        '本机未找到 Antigravity CLI (agy)',
        detail:
            '请确认已安装 Antigravity (~/.gemini/bin/agy 或 ~/.local/bin/agy)，'
            '或在「设置 → 通用」中指定 agy 可执行文件路径。',
      );
    }
    return (executable: exe, environment: env);
  }
}
