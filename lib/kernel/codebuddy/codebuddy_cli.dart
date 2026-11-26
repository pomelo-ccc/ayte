import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../claude_code/claude_code_transport.dart';
import '../claude_code/claude_environment.dart';
import '../claude_code/claude_path_setting.dart';
import 'codebuddy_account_models.dart';

/// Built-in provider id for CodeBuddy CLI (`codebuddy` / `cbc`) in Settings →
/// Models and the session model picker.
const codebuddyBuiltinProviderId = 'codebuddy-cli';

/// Built-in CodeBuddy CLI (`codebuddy` / `cbc`) slash commands offered in the
/// composer's `/` menu before and after session initialization.
const List<Map<String, Object?>> codebuddyBuiltinCommands = [
  {
    'name': 'compact',
    'description': 'Compact conversation context to free up context window',
    'argumentHint': '[instructions]',
    'builtin': true,
    'category': 'builtin',
  },
  {
    'name': 'clear',
    'description': 'Start a fresh conversation',
    'builtin': true,
    'category': 'builtin',
  },
  {
    'name': 'plan',
    'description': 'Plan step-by-step before execution',
    'argumentHint': '<task>',
    'builtin': true,
    'category': 'builtin',
  },
  {
    'name': 'init',
    'description': 'Initialize project CODEBUDDY.md instructions',
    'builtin': true,
    'category': 'builtin',
  },
  {
    'name': 'review',
    'description': 'Review current code changes and diffs',
    'argumentHint': '[target]',
    'builtin': true,
    'category': 'builtin',
  },
  {
    'name': 'context',
    'description': 'Show current context window usage',
    'builtin': true,
    'category': 'builtin',
  },
  {
    'name': 'cost',
    'description': 'Show token and credit usage for the current session',
    'builtin': true,
    'category': 'builtin',
  },
  {
    'name': 'status',
    'description': 'Show CodeBuddy account, model, and session status',
    'builtin': true,
    'category': 'builtin',
  },
];

/// Settings → General → CodeBuddy CLI: custom executable path
/// (`codebuddy.path` in settings.json).
abstract final class CodeBuddyPathSetting {
  static const settingKey = 'codebuddy.path';

  static String? parse(Object? value) => switch (value) {
    final String path when path.trim().isNotEmpty => path.trim(),
    _ => null,
  };

  /// The path set now: main.dart reads it from settings.json.
  static String? Function() current = () => null;
}

/// Canonical thinking effort order in WorkBuddy (`ck` in WorkBuddy's ModelSelector).
const workbuddyEffortOrder = [
  'low',
  'medium',
  'high',
  'xhigh',
  'max',
];

/// Canonical reasoning effort tiers accepted by `codebuddy --effort`.
const codebuddyEffortOrder = [
  'minimal',
  'low',
  'medium',
  'high',
  'xhigh',
  'max',
];

/// WorkBuddy's exact localized label for a thinking effort / mode value.
String codebuddyEffortLabel(String level, {bool isZh = true}) =>
    switch (level) {
      'none' || 'disabled' => isZh ? '关闭' : 'Off',
      'enabled' => isZh ? '开启' : 'On',
      'minimal' || 'low' => isZh ? '低' : 'Low',
      'medium' => isZh ? '中' : 'Medium',
      'high' => isZh ? '高' : 'High',
      'xhigh' => isZh ? '超高' : 'Extra High',
      'max' => isZh ? '极致' : 'Max',
      _ => level,
    };

/// WorkBuddy's description for each thinking effort option.
String codebuddyEffortDescription(String level, {bool isZh = true}) =>
    switch (level) {
      'none' || 'disabled' => isZh ? '关闭思考模式，直接快速响应' : 'Disable thinking mode',
      'enabled' => isZh ? '开启深度思考模式' : 'Enable thinking mode',
      'minimal' || 'low' => isZh ? '轻量思考，响应更快' : 'Light thinking, faster',
      'medium' => isZh ? '思考深度与速度均衡' : 'Balanced speed and depth',
      'high' => isZh ? '深度思考，适合复杂编程任务' : 'Deep reasoning for coding',
      'xhigh' => isZh ? '超深度推理，适合疑难架构问题' : 'Extra-high reasoning depth',
      'max' => isZh ? '最高思考强度，充分推理' : 'Maximum thinking intensity',
      _ => '',
    };

/// Extracts WorkBuddy's compact credit multiplier (`"x0.29 credits"` → `"0.29x"`).
String? formatCodeBuddyCreditsRate(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  final match = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(raw);
  if (match == null) return raw.trim();
  return '${match.group(1)}x';
}

/// A model offered by CodeBuddy CLI (`codebuddy` / `cbc`), modeled 1:1 after
/// WorkBuddy's `ModelOption` & `isReasoningConfigurable` specification.
class CodeBuddyModel {
  const CodeBuddyModel({
    required this.id,
    required this.label,
    this.cliModelId,
    this.description = '',
    this.creditsRate,
    this.supportsReasoning = false,
    this.onlyReasoning = false,
    this.canDisableThinking = false,
    this.supportedEfforts = const [],
    this.defaultEffort,
    this.contextOptions = const [200000],
    this.defaultContext = 200000,
  });

  final String id;
  final String? cliModelId;
  final String label;
  final String description;

  /// Credit consumption multiplier reported by CodeBuddy (`"0.29x"`, `"0.00x"`).
  final String? creditsRate;

  /// Whether the model supports chain-of-thought reasoning.
  final bool supportsReasoning;

  /// When true, thinking is always-on and cannot be disabled (`thoughtLevel: "disabled"` is forbidden).
  final bool onlyReasoning;

  /// Raw `canDisableThinking` flag when `onlyReasoning` is false.
  final bool canDisableThinking;

  /// Explicit configurable intensity levels (`['low', 'medium', 'high', 'xhigh', 'max']`).
  /// Empty when the model uses a fixed internal effort (e.g. `Auto`, `GLM-5.2`).
  final List<String> supportedEfforts;

  final String? defaultEffort;
  final List<int> contextOptions;
  final int defaultContext;

  String get effectiveCliModel => cliModelId ?? id;

  /// WorkBuddy's exact `canToggleThinking`:
  /// `!!supportsReasoning && !onlyReasoning && canDisableThinking !== false`.
  bool get canToggleThinking =>
      supportsReasoning && !onlyReasoning && canDisableThinking;

  /// WorkBuddy's exact `isReasoningConfigurable`:
  /// `supportsReasoning && (supportedEfforts.isNotEmpty || canToggleThinking)`.
  bool get isReasoningConfigurable =>
      supportsReasoning && (supportedEfforts.isNotEmpty || canToggleThinking);

  /// Whether reasoning is always active at a single fixed effort level that the
  /// user cannot toggle off or adjust (rendered as a read-only indicator).
  bool get isReasoningFixed =>
      supportsReasoning && !canToggleThinking && supportedEfforts.length == 1;

  /// Menu label for an effort option (`baseLabel` is e.g. `High`).
  String effortOptionLabel(String level, String baseLabel) =>
      isReasoningFixed ? '固定 $baseLabel（不支持调整）' : baseLabel;

  /// Valid effort states selectable in the kernel:
  /// - Empty when `!isReasoningConfigurable` (no effort menu shown).
  /// - Includes `'none'` when `canToggleThinking` is true.
  /// - Includes `'enabled'` when `canToggleThinking` is true and `supportedEfforts` is empty.
  List<String> get effortLevels {
    if (!isReasoningConfigurable) return const [];
    return [
      if (canToggleThinking) 'none',
      if (canToggleThinking && supportedEfforts.isEmpty)
        'enabled'
      else
        ...supportedEfforts,
    ];
  }

  /// Default effort when this model is selected.
  String? get initialEffort {
    final levels = effortLevels;
    if (levels.isEmpty) return null;
    if (defaultEffort != null && levels.contains(defaultEffort)) {
      return defaultEffort;
    }
    if (supportedEfforts.isNotEmpty) return supportedEfforts.first;
    if (levels.contains('enabled')) return 'enabled';
    return levels.first;
  }

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
  /// `256K` or `1M`).
  String contextOptionLabel(String baseLabel, int tokens) =>
      contextOptions.length == 1 ? '$baseLabel（官方固定）' : baseLabel;

  String contextOptionDescription(int tokens) {
    if (tokens == defaultContext) return '默认上下文窗口';
    return switch (tokens) {
      200000 => '200K 上下文窗口',
      256000 => '256K 上下文窗口',
      512000 => '512K 扩展上下文窗口',
      1000000 => '1M 长上下文窗口',
      _ => tokens < defaultContext ? '紧凑上下文窗口' : '扩展长上下文窗口',
    };
  }

  /// Normalizes a raw effort/thinking-level token to [workbuddyEffortOrder],
  /// returning `null` for disabled/off/unknown values.
  static String? _normalizeEffortToken(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim().toLowerCase();
    if (trimmed.isEmpty) return null;
    final norm = trimmed == 'minimal' ? 'low' : trimmed;
    return workbuddyEffortOrder.contains(norm) ? norm : null;
  }

  static bool _isOffEffortToken(String raw) =>
      const {'off', 'none', 'disabled'}.contains(raw.trim().toLowerCase());

  /// Parses a full `rawModels` entry from `codebuddy`'s `get_available_models`
  /// control response using WorkBuddy's capability rules, supporting both
  /// `reasoning.supportedEfforts` arrays and `thinkingLevelMap` maps (including
  /// 2-tier and fixed single-tier reasoning models).
  factory CodeBuddyModel.fromRawJson(
    Map<String, Object?> raw, {
    CodeBuddyModel? fallback,
  }) {
    final id = (raw['id'] ?? raw['modelId'] ?? raw['value']) as String? ?? '';
    final rawName =
        ((raw['name'] ?? raw['displayName']) as String?)?.trim() ?? '';
    final creditsRate = formatCodeBuddyCreditsRate(raw['credits'] as String?);
    final isFreeVariant =
        id.endsWith('-free') ||
        creditsRate == '0x' ||
        creditsRate == '0.0x' ||
        creditsRate == '0.00x';
    var label = rawName.isNotEmpty ? rawName : CodeBuddyModels._prettifyId(id);
    if (isFreeVariant &&
        id.endsWith('-free') &&
        !label.contains('免费') &&
        !label.toLowerCase().contains('free')) {
      label = '$label (免费)';
    }

    final rawReasoning = raw['reasoning'];
    final reasoning = rawReasoning is Map
        ? rawReasoning.cast<String, Object?>()
        : null;
    final supportsReasoning =
        raw['supportsReasoning'] == true ||
        rawReasoning == true ||
        reasoning != null;
    final onlyReasoning = raw['onlyReasoning'] == true;

    final rawEfforts =
        reasoning?['supportedEfforts'] ??
        raw['supportedEfforts'] ??
        raw['supportedEffortLevels'] ??
        raw['effortLevels'];
    final rawThinkingMap =
        reasoning?['thinkingLevelMap'] ?? raw['thinkingLevelMap'];
    final hasExplicitEfforts = rawEfforts is List || rawThinkingMap is Map;

    final supportedSet = <String>{};
    var mapAllowsDisable = false;

    if (rawEfforts is List) {
      for (final item in rawEfforts) {
        if (item is String && _isOffEffortToken(item)) {
          mapAllowsDisable = true;
          continue;
        }
        final norm = _normalizeEffortToken(item);
        if (norm != null) {
          supportedSet.add(norm);
        }
      }
    }

    if (rawThinkingMap is Map) {
      for (final entry in rawThinkingMap.entries) {
        final key = entry.key.toString().trim().toLowerCase();
        final val = entry.value;
        if (val == null || val == false) continue;
        final valStr = val is String
            ? val.trim().toLowerCase()
            : (val == true ? key : '');
        if (valStr.isEmpty) continue;
        if (_isOffEffortToken(key) || _isOffEffortToken(valStr)) {
          if (_isOffEffortToken(key)) mapAllowsDisable = true;
          continue;
        }
        final norm =
            _normalizeEffortToken(valStr) ?? _normalizeEffortToken(key);
        if (norm != null) {
          supportedSet.add(norm);
        }
      }
    }

    final rawDefaultCandidates = [
      reasoning?['defaultEffort'],
      reasoning?['effort'],
      raw['defaultEffort'],
      raw['effort'],
      fallback?.defaultEffort,
    ];

    if (!hasExplicitEfforts && supportsReasoning) {
      if (fallback != null && fallback.supportedEfforts.isNotEmpty) {
        supportedSet.addAll(fallback.supportedEfforts);
      } else {
        for (final candidate in rawDefaultCandidates) {
          final norm = _normalizeEffortToken(candidate);
          if (norm != null) {
            supportedSet.add(norm);
            break;
          }
        }
      }
    }

    final supportedEfforts = [
      for (final tier in workbuddyEffortOrder)
        if (supportedSet.contains(tier)) tier,
    ];

    final bool canDisable;
    if (!supportsReasoning || onlyReasoning) {
      canDisable = false;
    } else if (rawThinkingMap is Map && rawEfforts is! List) {
      // A `thinkingLevelMap` with all-null / off-only entries must not produce
      // an empty or misleading toggle panel.
      canDisable =
          supportedEfforts.isNotEmpty &&
          (mapAllowsDisable ||
              raw['canDisableThinking'] == true ||
              reasoning?['canDisableThinking'] == true);
    } else {
      canDisable =
          raw['canDisableThinking'] != false &&
          reasoning?['canDisableThinking'] != false;
    }

    String? defaultEffort;
    for (final candidate in rawDefaultCandidates) {
      final norm = _normalizeEffortToken(candidate);
      if (norm != null && supportedEfforts.contains(norm)) {
        defaultEffort = norm;
        break;
      }
    }
    defaultEffort ??= supportedEfforts.firstOrNull;

    final maxInput = (raw['maxInputTokens'] as num?)?.toInt() ?? 200000;
    final cwMap = (raw['contextWindow'] as Map?)?.cast<String, Object?>();
    final rawLengths =
        cwMap?['supportedLengths'] ?? raw['supportedContextWindows'];
    final lengths = <int>{};
    if (rawLengths is List) {
      for (final v in rawLengths) {
        if (v is num && v.toInt() > 0 && v.toInt() <= maxInput) {
          lengths.add(v.toInt());
        }
      }
    }
    final sortedLengths = lengths.toList()..sort();
    final contextOptions = sortedLengths.length >= 2
        ? sortedLengths
        : <int>[maxInput];
    final rawDefaultLen = (cwMap?['defaultLength'] as num?)?.toInt();
    final defaultContext =
        (rawDefaultLen != null && contextOptions.contains(rawDefaultLen))
        ? rawDefaultLen
        : contextOptions.last;

    final rawDesc =
        (raw['descriptionZh'] ?? raw['description']) as String? ?? '';
    final descParts = <String>[
      if (creditsRate != null && creditsRate.isNotEmpty) '倍率 $creditsRate',
      if (rawDesc.trim().isNotEmpty) rawDesc.trim(),
    ];

    return CodeBuddyModel(
      id: id,
      label: label,
      description: descParts.isNotEmpty ? descParts.join(' · ') : 'CodeBuddy 模型',
      creditsRate: creditsRate,
      supportsReasoning: supportsReasoning,
      onlyReasoning: onlyReasoning,
      canDisableThinking: canDisable,
      supportedEfforts: supportedEfforts,
      defaultEffort: defaultEffort,
      contextOptions: contextOptions,
      defaultContext: defaultContext,
    );
  }
}

/// Built-in and dynamically queried models of CodeBuddy CLI (`codebuddy`).
abstract final class CodeBuddyModels {
  static final ValueNotifier<int> changes = ValueNotifier<int>(0);

  /// Default CN (`internal` · `copilot.tencent.com` / `codebuddy.cn`) catalog
  /// matching WorkBuddy's exact model definitions and `supportedEfforts`.
  static const List<CodeBuddyModel> cnDefaults = [
    CodeBuddyModel(
      id: 'default-model',
      label: 'Auto (智能路由)',
      description: '自动匹配最佳编程模型',
      contextOptions: [200000],
      defaultContext: 200000,
    ),
    CodeBuddyModel(
      id: 'hy4std',
      label: 'Hy4',
      description: '倍率 0.29x · 腾讯混元旗舰编程推理模型',
      creditsRate: '0.29x',
      supportsReasoning: true,
      onlyReasoning: true,
      supportedEfforts: ['high'],
      defaultEffort: 'high',
      contextOptions: [960000],
      defaultContext: 960000,
    ),
    CodeBuddyModel(
      id: 'hy4flash-free',
      label: 'Hy4 flash (免费)',
      description: '倍率 0.00x · 腾讯混元高速编程模型（免费额度）',
      creditsRate: '0.00x',
      supportsReasoning: true,
      onlyReasoning: true,
      supportedEfforts: ['high'],
      defaultEffort: 'high',
      contextOptions: [960000],
      defaultContext: 960000,
    ),
    CodeBuddyModel(
      id: 'hy4flash',
      label: 'Hy4 flash',
      description: '倍率 0.03x · 腾讯混元高速编程推理模型',
      creditsRate: '0.03x',
      supportsReasoning: true,
      onlyReasoning: true,
      supportedEfforts: ['high'],
      defaultEffort: 'high',
      contextOptions: [960000],
      defaultContext: 960000,
    ),
    CodeBuddyModel(
      id: 'deepseek-v4.1-flash',
      label: 'DeepSeek-V4.1-Flash',
      description: '倍率 0.11x · 高速推理编码模型',
      creditsRate: '0.11x',
      supportsReasoning: true,
      onlyReasoning: true,
      supportedEfforts: ['low', 'high', 'max'],
      defaultEffort: 'high',
      contextOptions: [1000000],
      defaultContext: 1000000,
    ),
    CodeBuddyModel(
      id: 'glm-5.3',
      label: 'GLM-5.3',
      description: '倍率 0.69x · 智谱旗舰代码与工具调用模型',
      creditsRate: '0.69x',
      supportsReasoning: true,
      onlyReasoning: true,
      supportedEfforts: ['low', 'high', 'max'],
      defaultEffort: 'max',
      contextOptions: [1000000],
      defaultContext: 1000000,
    ),
    CodeBuddyModel(
      id: 'glm-5.3-flash',
      label: 'GLM-5.3-Flash',
      description: '倍率 0.08x · 智谱高速编程推理模型',
      creditsRate: '0.08x',
      supportsReasoning: true,
      onlyReasoning: true,
      supportedEfforts: ['low', 'high', 'max'],
      defaultEffort: 'high',
      contextOptions: [1000000],
      defaultContext: 1000000,
    ),
    CodeBuddyModel(
      id: 'glm-5.2',
      label: 'GLM-5.2',
      description: '倍率 0.79x · 智谱高能力工程模型',
      creditsRate: '0.79x',
      supportsReasoning: true,
      onlyReasoning: true,
      contextOptions: [1000000],
      defaultContext: 1000000,
    ),
    CodeBuddyModel(
      id: 'space-bunny',
      label: 'Space-Bunny',
      description: '倍率 0.08x · 五档思考强度全能编程模型',
      creditsRate: '0.08x',
      supportsReasoning: true,
      onlyReasoning: true,
      supportedEfforts: ['low', 'medium', 'high', 'xhigh', 'max'],
      defaultEffort: 'max',
      contextOptions: [1000000],
      defaultContext: 1000000,
    ),
    CodeBuddyModel(
      id: 'minimax-m3.1-flash',
      label: 'MiniMax-M3.1-Flash',
      description: '倍率 0.08x · MiniMax 高速 Agent 工程模型',
      creditsRate: '0.08x',
      supportsReasoning: true,
      onlyReasoning: true,
      supportedEfforts: ['low', 'medium', 'high', 'xhigh', 'max'],
      defaultEffort: 'max',
      contextOptions: [1000000],
      defaultContext: 1000000,
    ),
    CodeBuddyModel(
      id: 'minimax-m2.7',
      label: 'MiniMax-M2.7',
      description: '倍率 0.19x · MiniMax 稳健编码模型',
      creditsRate: '0.19x',
      supportsReasoning: true,
      onlyReasoning: true,
      contextOptions: [200000],
      defaultContext: 200000,
    ),
    CodeBuddyModel(
      id: 'kimi-k3.1-pro',
      label: 'Kimi-K3.1-Pro',
      description: '倍率 0.97x · Moonshot 旗舰长上下文推理模型',
      creditsRate: '0.97x',
      supportsReasoning: true,
      onlyReasoning: true,
      supportedEfforts: ['low', 'high', 'max'],
      defaultEffort: 'high',
      contextOptions: [1000000],
      defaultContext: 1000000,
    ),
    CodeBuddyModel(
      id: 'kimi-k3-1',
      label: 'Kimi-K3',
      description: '倍率 1.62x · Moonshot 深度工程模型',
      creditsRate: '1.62x',
      supportsReasoning: true,
      onlyReasoning: true,
      contextOptions: [1000000],
      defaultContext: 1000000,
    ),
    CodeBuddyModel(
      id: 'kimi-k2.8-preview',
      label: 'Kimi-K2.8-Preview',
      description: '倍率 0.77x · Moonshot 敏捷推理编码预览版',
      creditsRate: '0.77x',
      supportsReasoning: true,
      onlyReasoning: true,
      supportedEfforts: ['low', 'high', 'max'],
      defaultEffort: 'high',
      contextOptions: [1000000],
      defaultContext: 1000000,
    ),
    CodeBuddyModel(
      id: 'deepseek-v4-pro',
      label: 'DeepSeek-V4-Pro',
      description: '倍率 0.51x · 深度架构推理与重构模型',
      creditsRate: '0.51x',
      supportsReasoning: true,
      onlyReasoning: true,
      contextOptions: [1000000],
      defaultContext: 1000000,
    ),
    CodeBuddyModel(
      id: 'step-5-preview',
      label: 'Step-5-Preview',
      description: '倍率 0.33x · 阶跃星辰推理编码预览版',
      creditsRate: '0.33x',
      supportsReasoning: true,
      onlyReasoning: true,
      supportedEfforts: ['low', 'medium', 'high'],
      defaultEffort: 'high',
      contextOptions: [1000000],
      defaultContext: 1000000,
    ),
    CodeBuddyModel(
      id: 'mimo-v2.6-pro',
      label: 'Xiaomi MiMo-V2.6-Pro',
      description: '倍率 0.13x · 小米高性价比推理编程模型',
      creditsRate: '0.13x',
      supportsReasoning: true,
      onlyReasoning: true,
      contextOptions: [1000000],
      defaultContext: 1000000,
    ),
  ];

  /// Legacy / routing aliases resolved seamlessly when reopening older sessions.
  static const List<CodeBuddyModel> _legacyAliases = [
    CodeBuddyModel(
      id: 'primary-model',
      label: 'Primary (主力编程)',
      description: '主力编程预设模型',
      creditsRate: '1.20x',
      supportsReasoning: true,
      onlyReasoning: true,
      contextOptions: [200000],
      defaultContext: 200000,
    ),
    CodeBuddyModel(
      id: 'deep-model',
      label: '极致 (预设路由)',
      description: '倍率 1.20x · 优先深度与准确性',
      creditsRate: '1.20x',
      supportsReasoning: true,
      onlyReasoning: true,
      contextOptions: [200000],
      defaultContext: 200000,
    ),
    CodeBuddyModel(
      id: 'balanced-model',
      label: '均衡 (预设路由)',
      description: '倍率 0.65x · 兼顾速度与质量',
      creditsRate: '0.65x',
      supportsReasoning: true,
      onlyReasoning: true,
      contextOptions: [200000],
      defaultContext: 200000,
    ),
    CodeBuddyModel(
      id: 'fast-model',
      label: '快速 (预设路由)',
      description: '倍率 0.21x · 优先响应速度',
      creditsRate: '0.21x',
      supportsReasoning: true,
      onlyReasoning: true,
      contextOptions: [200000],
      defaultContext: 200000,
    ),
    CodeBuddyModel(
      id: 'hy4-preview',
      cliModelId: 'hy4std',
      label: 'Hy4',
      description: '倍率 0.29x · 腾讯混元旗舰编程模型',
      creditsRate: '0.29x',
      supportsReasoning: true,
      onlyReasoning: true,
      supportedEfforts: ['high'],
      defaultEffort: 'high',
      contextOptions: [256000, 512000, 960000],
      defaultContext: 960000,
    ),
  ];

  /// Default Global (`www.codebuddy.ai`) models.
  static const List<CodeBuddyModel> globalDefaults = [
    CodeBuddyModel(
      id: 'default-model',
      label: 'Auto (智能路由)',
      description: 'Automatic optimal model routing',
      contextOptions: [200000],
      defaultContext: 200000,
    ),
    CodeBuddyModel(
      id: 'gpt-6-astra',
      label: 'GPT-6 Astra',
      description: 'Flagship deep reasoning & coding',
      supportsReasoning: true,
      onlyReasoning: true,
      supportedEfforts: ['low', 'medium', 'high', 'xhigh', 'max'],
      defaultEffort: 'high',
      contextOptions: [256000, 512000, 1000000],
      defaultContext: 1000000,
    ),
    CodeBuddyModel(
      id: 'gpt-5.6-sol',
      label: 'GPT-5.6 Sol',
      description: 'High-capability engineering model',
      supportsReasoning: true,
      onlyReasoning: true,
      supportedEfforts: ['low', 'medium', 'high', 'xhigh'],
      defaultEffort: 'high',
      contextOptions: [256000, 512000, 1000000],
      defaultContext: 1000000,
    ),
    CodeBuddyModel(
      id: 'gpt-5.6-terra',
      label: 'GPT-5.6 Terra',
      description: 'Balanced frontier reasoning',
      supportsReasoning: true,
      onlyReasoning: true,
      supportedEfforts: ['low', 'medium', 'high'],
      defaultEffort: 'medium',
      contextOptions: [256000, 512000, 1000000],
      defaultContext: 1000000,
    ),
    CodeBuddyModel(
      id: 'gemini-3.5-flash',
      label: 'Gemini 3.5 Flash',
      description: 'Multimodal fast reasoning & coding',
      supportsReasoning: true,
      canDisableThinking: true,
      supportedEfforts: ['low', 'medium', 'high'],
      defaultEffort: 'medium',
      contextOptions: [256000, 512000, 1000000],
      defaultContext: 1000000,
    ),
    CodeBuddyModel(
      id: 'deepseek-v4.1-flash',
      label: 'DeepSeek-V4.1-Flash',
      description: 'Fast reasoning & code synthesis',
      supportsReasoning: true,
      onlyReasoning: true,
      supportedEfforts: ['low', 'high', 'max'],
      defaultEffort: 'high',
      contextOptions: [1000000],
      defaultContext: 1000000,
    ),
    CodeBuddyModel(
      id: 'glm-5.3',
      label: 'GLM-5.3',
      description: 'Flagship agentic coding model',
      supportsReasoning: true,
      onlyReasoning: true,
      supportedEfforts: ['low', 'high', 'max'],
      defaultEffort: 'max',
      contextOptions: [1000000],
      defaultContext: 1000000,
    ),
    CodeBuddyModel(
      id: 'kimi-k3.1-pro',
      label: 'Kimi-K3.1-Pro',
      description: 'Long-context reasoning & coding',
      supportsReasoning: true,
      onlyReasoning: true,
      supportedEfforts: ['low', 'high', 'max'],
      defaultEffort: 'high',
      contextOptions: [1000000],
      defaultContext: 1000000,
    ),
  ];

  static List<CodeBuddyModel> _current = cnDefaults;

  static List<CodeBuddyModel> get current => _current;

  static void _setCurrent(List<CodeBuddyModel> next) {
    _current = next;
    changes.value++;
  }

  /// Updates [current] to the default catalog for [region].
  static void syncForRegion(CodeBuddyRegion region) {
    _setCurrent(
      region == CodeBuddyRegion.global ? globalDefaults : cnDefaults,
    );
  }

  /// Updates [current] to match [account]'s region + any custom `~/.codebuddy/models.json`.
  static void syncForAccount(CodeBuddyAccount account) {
    final base = account.region == CodeBuddyRegion.global
        ? globalDefaults
        : cnDefaults;
    final byId = <String, CodeBuddyModel>{
      for (final m in [...cnDefaults, ...globalDefaults, ..._legacyAliases])
        m.id: m,
    };

    final merged = <CodeBuddyModel>[...base];
    final seen = <String>{for (final m in merged) m.id};

    for (final serverId
        in account.quota?.availableModelIds ?? const <String>[]) {
      if (serverId.contains('image') || seen.contains(serverId)) continue;
      seen.add(serverId);
      merged.add(
        byId[serverId] ??
            CodeBuddyModel(
              id: serverId,
              label: _prettifyId(serverId),
              description: 'CodeBuddy 服务端可用模型',
              contextOptions: const [200000],
              defaultContext: 200000,
            ),
      );
    }

    for (final custom in _readUserCustomModels()) {
      final existingIdx = merged.indexWhere((m) => m.id == custom.id);
      if (existingIdx >= 0) {
        merged[existingIdx] = custom;
      } else {
        merged.add(custom);
      }
    }

    _setCurrent(merged);
  }

  /// Replaces/merges dynamic model descriptors reported by `codebuddy`
  /// `get_available_models.rawModels` (preferred, contains `reasoning` &
  /// `credits`) or `initialize.models` (basic `{id, name, description}` stubs).
  static void updateFromCliModels(List<Map<String, Object?>> rawModels) {
    if (rawModels.isEmpty) return;
    final byKnown = <String, CodeBuddyModel>{
      for (final m in [
        ...cnDefaults,
        ...globalDefaults,
        ..._legacyAliases,
        ..._current,
      ])
        m.id: m,
    };

    final updated = <CodeBuddyModel>[];
    final seen = <String>{};

    // Keep WorkBuddy's `Auto` smart-router option at the top if not in rawModels.
    final hasAutoInRaw = rawModels.any((r) {
      final id = (r['id'] ?? r['modelId'] ?? r['value']) as String? ?? '';
      return id == 'default-model' || id == 'auto';
    });
    if (!hasAutoInRaw) {
      seen.add('default-model');
      updated.add(cnDefaults.first);
    }

    for (final raw in rawModels) {
      final id = (raw['id'] ?? raw['modelId'] ?? raw['value']) as String? ?? '';
      if (id.isEmpty || id.contains('image') || !seen.add(id)) continue;

      final hasRichMetadata =
          raw.containsKey('supportsReasoning') ||
          raw.containsKey('reasoning') ||
          raw.containsKey('thinkingLevelMap') ||
          raw.containsKey('supportedEfforts') ||
          raw.containsKey('supportedEffortLevels') ||
          raw.containsKey('credits') ||
          raw.containsKey('onlyReasoning');

      if (hasRichMetadata) {
        updated.add(CodeBuddyModel.fromRawJson(raw, fallback: byKnown[id]));
        continue;
      }

      if (byKnown[id] case final known?) {
        updated.add(known);
        continue;
      }

      updated.add(CodeBuddyModel.fromRawJson(raw));
    }

    for (final custom in _readUserCustomModels()) {
      final existingIdx = updated.indexWhere((m) => m.id == custom.id);
      if (existingIdx >= 0) {
        updated[existingIdx] = custom;
      } else {
        updated.add(custom);
      }
    }

    if (updated.isNotEmpty) {
      _setCurrent(updated);
    }
  }

  static List<CodeBuddyModel> _readUserCustomModels() {
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    if (home.isEmpty) return const [];
    final file = File(p.join(home, '.codebuddy', 'models.json'));
    if (!file.existsSync()) return const [];
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map || decoded['models'] is! List) return const [];
      final out = <CodeBuddyModel>[];
      for (final item in decoded['models'] as List) {
        if (item is! Map) continue;
        final map = item.cast<String, Object?>();
        final id = (map['id'] as String?)?.trim() ?? '';
        if (id.isEmpty) continue;
        if (map.containsKey('reasoning') ||
            map.containsKey('onlyReasoning') ||
            map.containsKey('thinkingLevelMap') ||
            map.containsKey('supportedEfforts') ||
            map.containsKey('supportedEffortLevels')) {
          out.add(CodeBuddyModel.fromRawJson(map));
          continue;
        }
        final name = (map['name'] as String?)?.trim();
        final maxIn = (map['maxInputTokens'] as num?)?.toInt() ?? 200000;
        final supportsReasoning = map['supportsReasoning'] as bool? ?? false;
        final onlyReasoning = map['onlyReasoning'] as bool? ?? false;
        out.add(
          CodeBuddyModel(
            id: id,
            label: (name != null && name.isNotEmpty) ? name : id,
            description: '自定义模型 (~/.codebuddy/models.json)',
            supportsReasoning: supportsReasoning,
            onlyReasoning: onlyReasoning,
            canDisableThinking: supportsReasoning && !onlyReasoning,
            supportedEfforts: supportsReasoning
                ? const ['low', 'medium', 'high']
                : const [],
            defaultEffort: supportsReasoning ? 'high' : null,
            contextOptions: [maxIn],
            defaultContext: maxIn,
          ),
        );
      }
      return out;
    } on Object {
      return const [];
    }
  }

  static String _prettifyId(String id) => id
      .split('-')
      .map((s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}')
      .join(' ');

  /// Strips `@codebuddy-cli/` prefix if present.
  static String stripPrefix(String? model) {
    if (model == null || model.isEmpty) return '';
    const prefix = '@$codebuddyBuiltinProviderId/';
    return model.startsWith(prefix) ? model.substring(prefix.length) : model;
  }

  static CodeBuddyModel? of(String? model) {
    if (model == null || model.isEmpty) return null;
    final prefixed = model.startsWith('@$codebuddyBuiltinProviderId/');
    final bare = stripPrefix(model);
    if (bare.isEmpty) return null;
    if (bare == 'default') return prefixed ? _current.first : null;
    for (final m in _current) {
      if (m.id == bare || m.effectiveCliModel == bare) return m;
    }
    for (final m in [...cnDefaults, ...globalDefaults, ..._legacyAliases]) {
      if (m.id == bare || m.effectiveCliModel == bare) return m;
    }
    return null;
  }

  static ({CodeBuddyModel model, String? effort})? parseVariant(String? model) {
    final found = of(model);
    if (found == null) return null;
    return (model: found, effort: null);
  }

  static bool isCodeBuddyModel(String? model) {
    if (model == null || model.isEmpty) return false;
    if (model.startsWith('@$codebuddyBuiltinProviderId/')) return true;
    return of(model) != null;
  }

  static String bareModelId(String? model) {
    final found = of(model);
    if (found != null) return found.id;
    final bare = stripPrefix(model);
    if (bare.isEmpty || bare == 'default') return _current.first.id;
    return bare;
  }

  static String cliModelIdOf(String? model) {
    final found = of(model);
    if (found != null) return found.effectiveCliModel;
    final bare = stripPrefix(model);
    if (bare.isEmpty || bare == 'default') {
      return _current.first.effectiveCliModel;
    }
    return bare;
  }

  /// Whether [model] is a client-side placeholder (`default`, `default-model`,
  /// or empty) that must not be passed literally to `codebuddy --model` or
  /// `set_model`.
  static bool isPlaceholderModel(String? model) {
    final bare = stripPrefix(model).trim();
    return bare.isEmpty ||
        bare == 'default' ||
        bare == 'default-model' ||
        bare.startsWith('default-model');
  }

  /// First concrete (non-placeholder) CLI model id available as fallback when
  /// switching back to Auto on an already-started session.
  static String? firstConcreteCliModel() {
    for (final m in [..._current, ...cnDefaults, ...globalDefaults]) {
      final id = m.effectiveCliModel;
      if (!isPlaceholderModel(id)) return id;
    }
    return null;
  }

  static String labelOf(String modelId) =>
      of(modelId)?.label ?? bareModelId(modelId);

  /// Fast model id used for title summarization / lightweight helper calls.
  static String get fastAuxiliaryModel => 'fast-model';
}

// ---------------------------------------------------------------------------
// Local CodeBuddy CLI (`codebuddy` / `cbc`) discovery, status & installation
// ---------------------------------------------------------------------------

class CodeBuddyCli {
  const CodeBuddyCli({
    required this.executable,
    required this.environment,
    this.throughShell = false,
  });

  final String executable;
  final Map<String, String> environment;
  final bool throughShell;
}

abstract final class LocalCodeBuddy {
  static bool? _installed;

  static String get installCommand =>
      'npm install -g @tencent-ai/codebuddy-code';

  static bool installed() =>
      _installed ??= _locateSync(Map.of(Platform.environment)) != null;

  static Future<void> lookForInstall() async {
    try {
      final env = await ClaudeEnvironment.of();
      _installed = _locateSync(env) != null;
    } on Object catch (error) {
      debugPrint('CodeBuddy CLI lookup failed: $error');
    }
  }

  static Future<LocalClaudeStatus?> status() async {
    try {
      final cli = await locate();
      final result = await Process.run(
        cli.executable,
        const ['--version'],
        environment: cli.environment,
        includeParentEnvironment: Platform.isWindows,
        runInShell: cli.throughShell,
      ).timeout(const Duration(seconds: 8));
      if (result.exitCode != 0) {
        _installed = false;
        return LocalClaudeFailed('${result.stderr}'.trim());
      }
      final ver =
          const LineSplitter()
              .convert('${result.stdout}'.trim())
              .where((l) => l.trim().isNotEmpty)
              .firstOrNull ??
          'unknown';
      _installed = true;
      return LocalClaudeFound(cli.executable, ver);
    } on ClaudeUnavailable catch (error) {
      _installed = false;
      return error.detail == null || error.message.contains('未检测到')
          ? const LocalClaudeMissing()
          : LocalClaudeFailed(error.detail!);
    } on Object catch (error) {
      return LocalClaudeFailed('$error');
    }
  }

  static Future<CodeBuddyCli> locate() async {
    final baseEnv = await ClaudeEnvironment.of();
    final env = _enrichedPathEnvironment(baseEnv);
    final found = _locateSync(env);
    if (found != null) {
      _installed = true;
      final isCmd =
          Platform.isWindows &&
          (found.toLowerCase().endsWith('.cmd') ||
              found.toLowerCase().endsWith('.bat'));
      return CodeBuddyCli(
        executable: found,
        environment: env,
        throughShell: isCmd,
      );
    }
    _installed = false;
    throw ClaudeUnavailable(
      '未检测到 CodeBuddy CLI (codebuddy / cbc)',
      detail:
          '请先在终端安装腾讯云 CodeBuddy Code CLI：\n$installCommand\n\n'
          '或在「设置 → 通用 → CodeBuddy CLI」中指定可执行文件路径。',
    );
  }

  /// Installs `@tencent-ai/codebuddy-code` globally via `npm`.
  static Future<void> install() async {
    final env = _enrichedPathEnvironment(await ClaudeEnvironment.of());
    final npm = _findBinaryInEnv('npm', env);
    if (npm == null) {
      throw ClaudeUnavailable(
        '未找到 npm，无法自动安装 CodeBuddy CLI',
        detail: '请先安装 Node.js (v18+)，然后运行：\n$installCommand',
      );
    }
    final res = await Process.run(
      npm,
      const ['install', '-g', '@tencent-ai/codebuddy-code'],
      environment: env,
      includeParentEnvironment: Platform.isWindows,
      runInShell: Platform.isWindows,
    );
    if (res.exitCode != 0) {
      throw ClaudeUnavailable(
        '安装 @tencent-ai/codebuddy-code 失败',
        detail: '${res.stderr}\n${res.stdout}'.trim(),
      );
    }
    _installed = true;
  }

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

  static String _readEnvWithFallback(
    Map<String, String> base,
    String name, {
    required bool win,
  }) {
    final direct = _lookupEnvVar(base, name, win: win);
    if (direct != null) return direct;
    return _lookupEnvVar(Platform.environment, name, win: win) ?? '';
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

  /// Reads `PATH` case-insensitively on Windows (e.g. `Path` vs `PATH`).
  @visibleForTesting
  static String readPathVar(
    Map<String, String> env, {
    bool? forceWindows,
  }) =>
      _lookupEnvVar(env, 'PATH', win: forceWindows ?? Platform.isWindows) ??
      '';

  static Map<String, String> _withPath(
    Map<String, String> base,
    String pathValue, {
    required bool win,
  }) {
    final result = <String, String>{};
    for (final entry in base.entries) {
      if (win && entry.key.toLowerCase() == 'path') continue;
      result[entry.key] = entry.value;
    }
    result['PATH'] = pathValue;
    return result;
  }

  /// Enriches `PATH` with CodeBuddy CLI runtime directories while keeping
  /// explicit `PATH` entries ahead of fallbacks and handling Windows env case
  /// insensitively.
  @visibleForTesting
  static Map<String, String> enrichedPathEnvironment(
    Map<String, String> base, {
    bool? forceWindows,
  }) => _enrichedPathEnvironment(base, forceWindows: forceWindows);

  static Map<String, String> _enrichedPathEnvironment(
    Map<String, String> base, {
    bool? forceWindows,
  }) {
    final win = forceWindows ?? Platform.isWindows;
    final home = _resolveHome(base, win: win);
    final sep = win ? ';' : ':';
    final rawPath =
        _lookupEnvVar(base, 'PATH', win: win) ??
        _lookupEnvVar(Platform.environment, 'PATH', win: win) ??
        '';
    final existing = rawPath
        .split(sep)
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final extras = <String>[
      if (home.isNotEmpty && !win) ...[
        p.posix.join(home, '.local', 'bin'),
        p.posix.join(home, '.hermes', 'node', 'bin'),
        p.posix.join(home, '.codebuddy', 'bin'),
        p.posix.join(home, '.bun', 'bin'),
        p.posix.join(home, '.volta', 'bin'),
        '/opt/homebrew/bin',
        '/usr/local/bin',
        ..._globNodeBins(
          p.posix.join(home, '.local', 'share', 'fnm', 'node-versions'),
          'installation/bin',
        ),
        ..._globNodeBins(p.posix.join(home, '.nvm', 'versions', 'node'), 'bin'),
      ],
      if (win) ...[
        if (_readEnvWithFallback(base, 'APPDATA', win: true)
            case final appData when appData.isNotEmpty)
          p.windows.join(appData, 'npm'),
        if (home.isNotEmpty) ...[
          p.windows.join(home, '.local', 'bin'),
          p.windows.join(home, '.bun', 'bin'),
        ],
      ],
    ];
    final seen = <String>{};
    final merged = <String>[];
    for (final dir in [...existing, ...extras]) {
      final key = win ? dir.toLowerCase() : dir;
      if (seen.add(key)) merged.add(dir);
    }
    return _withPath(base, merged.join(sep), win: win);
  }

  static List<String> _globNodeBins(String parentDir, String sub) {
    final d = Directory(parentDir);
    if (!d.existsSync()) return const [];
    try {
      final dirs =
          d
              .listSync()
              .whereType<Directory>()
              .map((e) => p.join(e.path, sub))
              .where((binPath) => Directory(binPath).existsSync())
              .toList()
            ..sort((a, b) => b.compareTo(a));
      return dirs;
    } on Object {
      return const [];
    }
  }

  @visibleForTesting
  static String? locateSyncForTesting(
    Map<String, String> env, {
    bool? forceWindows,
  }) => _locateSync(env, forceWindows: forceWindows);

  static String? _locateSync(
    Map<String, String> env, {
    bool? forceWindows,
  }) {
    final win = forceWindows ?? Platform.isWindows;
    final home = _resolveHome(env, win: win);

    if (CodeBuddyPathSetting.current() case final custom?
        when custom.isNotEmpty) {
      final expanded =
          (custom == '~' || custom.startsWith('~/') || custom.startsWith(r'~\'))
          ? '$home${custom.substring(1)}'
          : custom;
      if (File(expanded).existsSync()) return expanded;
    }

    final enriched = _enrichedPathEnvironment(env, forceWindows: win);
    for (final name in const ['codebuddy', 'cbc', 'codebuddy-code']) {
      if (_findBinaryInEnv(name, enriched, forceWindows: win) case final hit?) {
        return hit;
      }
    }
    return null;
  }

  static String? _findBinaryInEnv(
    String name,
    Map<String, String> env, {
    bool? forceWindows,
  }) {
    final win = forceWindows ?? Platform.isWindows;
    final sep = win ? ';' : ':';
    final pathVar = readPathVar(env, forceWindows: win);
    final exts = win ? const ['.cmd', '.exe', '.bat', ''] : const [''];
    for (final dir in pathVar.split(sep)) {
      if (dir.trim().isEmpty) continue;
      for (final ext in exts) {
        final candidate = p.join(dir.trim(), '$name$ext');
        if (File(candidate).existsSync()) return candidate;
      }
    }
    return null;
  }
}
