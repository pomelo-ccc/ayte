import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../kernel_types.dart';

/// A model reported by local Codex CLI (`~/.codex/` catalog or `codex app-server`
/// `model/list`).
class CodexModelInfo {
  const CodexModelInfo({
    required this.id,
    required this.label,
    this.description = '',
    this.isDefault = false,
    this.effortLevels = const [],
    this.defaultEffort,
  });

  final String id;
  final String label;
  final String description;
  final bool isDefault;
  final List<String> effortLevels;
  final String? defaultEffort;

  KernelOption toOption(KernelOptionGroup group) => KernelOption(
    id,
    label,
    Icons.bolt_rounded,
    description,
    group: group,
  );
}

/// Loads real Codex models from the local `~/.codex/` configuration
/// (`config.toml` -> `model_catalog_json` or `models_cache.json`) and parses
/// live `codex app-server` `model/list` responses.
abstract final class CodexModels {
  static final KernelOptionGroup group = const KernelOptionGroup(
    'codex',
    'Codex CLI',
  );

  static const List<CodexModelInfo> fallback = [
    CodexModelInfo(
      id: 'gpt-5.4',
      label: 'GPT-5.4',
      description: 'Default Codex coding model',
      isDefault: true,
      effortLevels: ['low', 'medium', 'high', 'xhigh'],
      defaultEffort: 'medium',
    ),
    CodexModelInfo(
      id: 'gpt-5.4-mini',
      label: 'GPT-5.4 mini',
      description: 'Fast Codex coding model',
      effortLevels: ['low', 'medium', 'high'],
      defaultEffort: 'medium',
    ),
  ];

  /// Reads the user's local `~/.codex/` model list & default model/effort
  /// synchronously so the model picker is accurate immediately on selection.
  static ({
    List<CodexModelInfo> models,
    String? defaultModel,
    String? defaultEffort,
  })
  loadLocalCatalog({String? codexHome}) {
    try {
      final home =
          codexHome ??
          Platform.environment['CODEX_HOME'] ??
          p.join(
            Platform.environment['HOME'] ??
                Platform.environment['USERPROFILE'] ??
                '',
            '.codex',
          );
      if (home.isEmpty || !Directory(home).existsSync()) {
        return (models: fallback, defaultModel: null, defaultEffort: null);
      }

      String? configuredModel;
      String? configuredCatalog;
      String? configuredEffort;

      final configFile = File(p.join(home, 'config.toml'));
      if (configFile.existsSync()) {
        final lines = configFile.readAsLinesSync();
        for (final raw in lines) {
          final line = raw.trim();
          if (line.isEmpty || line.startsWith('#')) continue;
          // Stop at first TOML section header ([...]): top-level keys come first.
          if (line.startsWith('[')) break;
          final m = _parseTomlString(line, 'model');
          if (m != null) configuredModel = m;
          final c = _parseTomlString(line, 'model_catalog_json');
          if (c != null) configuredCatalog = c;
          final e = _parseTomlString(line, 'model_reasoning_effort');
          if (e != null) configuredEffort = e;
        }
      }

      final catalogCandidates = <String>[
        if (configuredCatalog != null && configuredCatalog.isNotEmpty)
          p.isAbsolute(configuredCatalog)
              ? configuredCatalog
              : p.join(home, configuredCatalog),
        p.join(home, 'models_cache.json'),
      ];

      for (final path in catalogCandidates) {
        final file = File(path);
        if (!file.existsSync()) continue;
        final parsed = parseCatalogJson(
          file.readAsStringSync(),
          configuredModel: configuredModel,
        );
        if (parsed.isNotEmpty) {
          return (
            models: parsed,
            defaultModel: configuredModel,
            defaultEffort: configuredEffort,
          );
        }
      }

      if (configuredModel != null && configuredModel.isNotEmpty) {
        return (
          models: [
            CodexModelInfo(
              id: configuredModel,
              label: configuredModel,
              description: 'Configured in ~/.codex/config.toml',
              isDefault: true,
              effortLevels: const ['low', 'medium', 'high', 'xhigh', 'max'],
              defaultEffort: configuredEffort ?? 'medium',
            ),
            ...fallback.where((m) => m.id != configuredModel),
          ],
          defaultModel: configuredModel,
          defaultEffort: configuredEffort,
        );
      }
    } on Object {
      // Fall back safely if config cannot be read.
    }
    return (models: fallback, defaultModel: null, defaultEffort: null);
  }

  static String? _parseTomlString(String line, String key) {
    final re = RegExp('^$key\\s*=\\s*"([^"]*)"');
    return re.firstMatch(line)?.group(1);
  }

  /// Parses `~/.codex/croli-model-catalog.json` or `~/.codex/models_cache.json`.
  static List<CodexModelInfo> parseCatalogJson(
    String rawJson, {
    String? configuredModel,
  }) {
    final decoded = jsonDecode(rawJson);
    if (decoded is! Map) return const [];
    final rawModels = decoded['models'];
    if (rawModels is! List) return const [];
    final out = <CodexModelInfo>[];
    final seen = <String>{};
    for (final item in rawModels) {
      if (item is! Map) continue;
      final map = item.cast<String, Object?>();
      final visibility = '${map['visibility'] ?? 'list'}';
      if (visibility == 'hide') continue;
      final slug = '${map['slug'] ?? map['id'] ?? ''}'.trim();
      if (slug.isEmpty || !seen.add(slug)) continue;
      final displayName = '${map['display_name'] ?? map['displayName'] ?? slug}'
          .trim();
      final description = '${map['description'] ?? ''}'.trim();
      final defaultEffort =
          (map['default_reasoning_level'] ?? map['defaultReasoningEffort'])
              as String?;
      final efforts = <String>[];
      final rawLevels =
          map['supported_reasoning_levels'] ??
          map['supportedReasoningEfforts'];
      if (rawLevels is List) {
        for (final lvl in rawLevels) {
          if (lvl is Map) {
            final e = (lvl['effort'] ?? lvl['reasoningEffort']) as String?;
            if (e != null && e.isNotEmpty && !efforts.contains(e)) {
              efforts.add(e);
            }
          } else if (lvl is String && lvl.isNotEmpty && !efforts.contains(lvl)) {
            efforts.add(lvl);
          }
        }
      }
      out.add(
        CodexModelInfo(
          id: slug,
          label: displayName.isNotEmpty ? displayName : slug,
          description: description,
          isDefault: configuredModel != null && slug == configuredModel,
          effortLevels: efforts,
          defaultEffort: defaultEffort,
        ),
      );
    }
    return out;
  }

  /// Parses live `codex app-server` JSON-RPC `model/list` `result`.
  static List<CodexModelInfo> parseRpcModelList(Map<String, Object?> result) {
    final rawData = result['data'];
    if (rawData is! List) return const [];
    final out = <CodexModelInfo>[];
    final seen = <String>{};
    for (final item in rawData) {
      if (item is! Map) continue;
      final map = item.cast<String, Object?>();
      if (map['hidden'] == true) continue;
      final id = '${map['id'] ?? map['model'] ?? ''}'.trim();
      if (id.isEmpty || !seen.add(id)) continue;
      final displayName = '${map['displayName'] ?? id}'.trim();
      final description = '${map['description'] ?? ''}'.trim();
      final isDefault = map['isDefault'] == true;
      final defaultEffort = map['defaultReasoningEffort'] as String?;
      final efforts = <String>[];
      if (map['supportedReasoningEfforts'] case final List rawLevels) {
        for (final lvl in rawLevels) {
          if (lvl is Map) {
            final e = (lvl['reasoningEffort'] ?? lvl['effort']) as String?;
            if (e != null && e.isNotEmpty && !efforts.contains(e)) {
              efforts.add(e);
            }
          }
        }
      }
      out.add(
        CodexModelInfo(
          id: id,
          label: displayName.isNotEmpty ? displayName : id,
          description: description,
          isDefault: isDefault,
          effortLevels: efforts,
          defaultEffort: defaultEffort,
        ),
      );
    }
    return out;
  }
}
