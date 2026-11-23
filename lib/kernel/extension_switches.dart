import 'package:flutter/foundation.dart';

import '../customize/customizations.dart';

/// Skills, MCP servers and MCP tools the user switched off in Settings →
/// Customize: the `claudeCode.disabledSkills`, `claudeCode.disabledMcpServers`
/// and `claudeCode.disabledMcpTools` settings. All on while unset. Given the
/// agent as flag settings (permission rules and `skillOverrides`), at start
/// and again as they change, so a running session follows at once.
@immutable
class ExtensionSwitches {
  const ExtensionSwitches({
    this.disabledSkills = const {},
    this.disabledServers = const {},
    this.disabledTools = const {},
  });

  static const skillsKey = 'claudeCode.disabledSkills';
  static const serversKey = 'claudeCode.disabledMcpServers';
  static const toolsKey = 'claudeCode.disabledMcpTools';

  static const none = ExtensionSwitches();

  /// Skills by name: the user's, a project's, those synced from claude.ai
  /// (not a plugin's, which Claude Code keeps on).
  final Set<String> disabledSkills;

  /// MCP servers by name, as configured.
  final Set<String> disabledServers;

  /// MCP tools by server, then by the tool's own name.
  final Map<String, Set<String>> disabledTools;

  /// As [settings] (`User/settings.json`'s values) have them.
  factory ExtensionSwitches.parse(Map<String, Object?> settings) {
    Set<String> names(Object? value) => switch (value) {
      final List<Object?> list => {
        for (final item in list)
          if (item is String && item.trim().isNotEmpty) item.trim(),
      },
      _ => const {},
    };
    return ExtensionSwitches(
      disabledSkills: names(settings[skillsKey]),
      disabledServers: names(settings[serversKey]),
      disabledTools: switch (settings[toolsKey]) {
        final Map<Object?, Object?> map => {
          for (final MapEntry(:key, :value) in map.entries)
            if (key is String &&
                key.trim().isNotEmpty &&
                names(value).isNotEmpty)
              key.trim(): names(value),
        },
        _ => const {},
      },
    );
  }

  bool skillEnabled(String name) => !disabledSkills.contains(name.trim());

  bool serverEnabled(String server) => !disabledServers.contains(server.trim());

  bool toolEnabled(String server, String tool) =>
      !(disabledTools[server.trim()]?.contains(tool.trim()) ?? false);

  /// Whether [server] is switched off either by exact configured name or by its
  /// normalized MCP identifier (e.g. `claude.ai Docs` vs `claude_ai_Docs`).
  bool matchesServerDisabled(String server) {
    final trimmed = server.trim();
    if (trimmed.isEmpty) return false;
    if (disabledServers.contains(server) || disabledServers.contains(trimmed)) {
      return true;
    }
    final norm = normalize(trimmed);
    for (final entry in disabledServers) {
      if (normalize(entry) == norm) return true;
    }
    return false;
  }

  static String _cleanSkillKey(String raw) {
    var s = raw.trim();
    while (s.startsWith('/')) {
      s = s.substring(1).trim();
    }
    return s;
  }

  static Set<String> _skillMatchCandidates(
    String name, {
    String? folderName,
    Iterable<String> pluginNames = const [],
  }) {
    final cleanName = _cleanSkillKey(name);
    final cleanFolder = folderName == null ? '' : _cleanSkillKey(folderName);
    return {
      if (cleanName.isNotEmpty) cleanName,
      if (cleanFolder.isNotEmpty) cleanFolder,
      for (final rawPlugin in pluginNames)
        if (_cleanSkillKey(rawPlugin) case final plugin
            when plugin.isNotEmpty) ...[
          if (cleanName.isNotEmpty) '$plugin:$cleanName',
          if (cleanFolder.isNotEmpty) '$plugin:$cleanFolder',
        ],
    };
  }

  /// Whether a skill identified by [name] (or [folderName], or qualified by
  /// any [pluginNames]) is switched off.
  bool matchesSkillDisabled(
    String name, {
    String? folderName,
    Iterable<String> pluginNames = const [],
  }) {
    final candidates = _skillMatchCandidates(
      name,
      folderName: folderName,
      pluginNames: pluginNames,
    );
    if (candidates.isEmpty) return false;
    if (disabledSkills.contains(name) ||
        (folderName != null && disabledSkills.contains(folderName)) ||
        candidates.any(disabledSkills.contains)) {
      return true;
    }
    for (final entry in disabledSkills) {
      final cleanEntry = _cleanSkillKey(entry);
      if (cleanEntry.isNotEmpty && candidates.contains(cleanEntry)) {
        return true;
      }
    }
    return false;
  }

  /// Codex `config.toml` `-c mcp_servers.<name>.enabled=false` override map
  /// for disabled MCP servers.
  Map<String, bool> get codexMcpOverrides => {
    for (final server in _sorted(disabledServers)) server: false,
  };

  /// The folder containing a skill's `SKILL.md`, or null if unavailable.
  static String? skillFolderName(String path) {
    if (path.isEmpty) return null;
    final parts = path
        .split(RegExp(r'[/\\]+'))
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.length < 2) return null;
    final folder = parts[parts.length - 2];
    if (folder == '.' || folder == '..' || folder.endsWith(':')) return null;
    return folder;
  }

  /// The plugin directory name for a directory-based plugin skill path
  /// (`.../plugins/<pluginDir>/skills/<skillFolder>/SKILL.md`), or null.
  static String? skillPluginDirName(String path) {
    if (path.isEmpty) return null;
    final parts = path
        .split(RegExp(r'[/\\]+'))
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.length < 5) return null;
    if (parts[parts.length - 3].toLowerCase() != 'skills') return null;
    if (parts[parts.length - 5].toLowerCase() != 'plugins') return null;
    final pluginDir = parts[parts.length - 4];
    if (pluginDir == '.' || pluginDir == '..' || pluginDir.endsWith(':')) {
      return null;
    }
    return pluginDir;
  }

  /// Whether [item] is enabled according to both its own config metadata and
  /// these [ExtensionSwitches].
  bool allowsCustomization(
    Customization item, {
    Iterable<String> pluginNames = const [],
  }) => switch (item.kind) {
    CustomizationKind.skills =>
      item.enabled != false &&
          !matchesSkillDisabled(
            item.name,
            folderName: skillFolderName(item.path),
            pluginNames: {
              ...pluginNames,
              if (item.scope == CustomizationScope.plugin)
                ?skillPluginDirName(item.path),
            },
          ),
    CustomizationKind.mcps =>
      item.enabled != false && !matchesServerDisabled(item.name),
    _ => item.enabled != false,
  };

  /// Filters [items] to those allowed by [allowsCustomization].
  List<Customization> filterEnabled(Iterable<Customization> items) => [
    for (final item in items)
      if (allowsCustomization(item)) item,
  ];

  ExtensionSwitches withSkills(Iterable<String> names, bool enabled) =>
      _copy(disabledSkills: _toggled(disabledSkills, names, enabled));

  /// Toggles a skill identified by [name] (and any [folderName] or
  /// [pluginNames] aliases). Re-enabling clears every matching alias entry.
  ExtensionSwitches withSkillMatched(
    String name,
    bool enabled, {
    String? folderName,
    Iterable<String> pluginNames = const [],
  }) {
    if (!enabled) return withSkills([name], false);
    final candidates = _skillMatchCandidates(
      name,
      folderName: folderName,
      pluginNames: pluginNames,
    );
    if (candidates.isEmpty) return this;
    final next = {
      for (final entry in disabledSkills)
        if (!candidates.contains(_cleanSkillKey(entry))) entry,
    };
    if (next.length == disabledSkills.length) return this;
    return _copy(disabledSkills: next);
  }

  ExtensionSwitches withServer(String server, bool enabled) {
    final trimmed = server.trim();
    if (trimmed.isEmpty) return this;
    if (!enabled) {
      return _copy(disabledServers: _toggled(disabledServers, [trimmed], false));
    }
    final norm = normalize(trimmed);
    final next = {
      for (final entry in disabledServers)
        if (entry.trim() != trimmed && normalize(entry.trim()) != norm) entry,
    };
    if (next.length == disabledServers.length) return this;
    return _copy(disabledServers: next);
  }

  ExtensionSwitches withTool(String server, String tool, bool enabled) {
    final cleanServer = server.trim();
    final cleanTool = tool.trim();
    if (cleanServer.isEmpty || cleanTool.isEmpty) return this;
    final tools = _toggled(
      disabledTools[cleanServer] ?? const {},
      [cleanTool],
      enabled,
    );
    return _copy(
      disabledTools: {
        for (final MapEntry(:key, :value) in disabledTools.entries)
          if (key != cleanServer) key: value,
        if (tools.isNotEmpty) cleanServer: tools,
      },
    );
  }

  static Set<String> _toggled(
    Set<String> off,
    Iterable<String> names,
    bool enabled,
  ) {
    final normalized = {
      for (final name in names)
        if (name.trim().isNotEmpty) name.trim(),
    };
    if (normalized.isEmpty) return off;
    return enabled ? off.difference(normalized) : {...off, ...normalized};
  }

  ExtensionSwitches _copy({
    Set<String>? disabledSkills,
    Set<String>? disabledServers,
    Map<String, Set<String>>? disabledTools,
  }) => ExtensionSwitches(
    disabledSkills: disabledSkills ?? this.disabledSkills,
    disabledServers: disabledServers ?? this.disabledServers,
    disabledTools: disabledTools ?? this.disabledTools,
  );

  /// The settings as they are written, by key; null for one left out
  /// (nothing off).
  Map<String, Object?> toSettings() => {
    skillsKey: disabledSkills.isEmpty ? null : _sorted(disabledSkills),
    serversKey: disabledServers.isEmpty ? null : _sorted(disabledServers),
    toolsKey: disabledTools.isEmpty
        ? null
        : {
            for (final server in _sorted(disabledTools.keys))
              server: _sorted(disabledTools[server]!),
          },
  };

  static List<String> _sorted(Iterable<String> names) => [...names]..sort();

  /// The name Claude Code gives an MCP server or tool in a tool's name:
  /// anything but letters, digits, `_` and `-` as `_`.
  static String normalize(String name) =>
      name.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');

  /// The permission rules that turn them off: a server's tools all
  /// (`mcp__server`), a tool (`mcp__server__tool`).
  List<String> get denyRules => [
    for (final server in _sorted(disabledServers)) 'mcp__${normalize(server)}',
    for (final server in _sorted(disabledTools.keys))
      if (serverEnabled(server))
        for (final tool in _sorted(disabledTools[server]!))
          'mcp__${normalize(server)}__${normalize(tool)}',
  ];

  /// `skillOverrides`: each skill off, from the model and from `/name`.
  Map<String, String> get skillOverrides => {
    for (final skill in _sorted(disabledSkills)) skill: 'off',
  };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! ExtensionSwitches) return false;
    if (!setEquals(other.disabledSkills, disabledSkills) ||
        !setEquals(other.disabledServers, disabledServers) ||
        other.disabledTools.length != disabledTools.length) {
      return false;
    }
    for (final MapEntry(:key, :value) in disabledTools.entries) {
      final otherTools = other.disabledTools[key];
      if (otherTools == null || !setEquals(otherTools, value)) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    Object.hashAll(_sorted(disabledSkills)),
    Object.hashAll(_sorted(disabledServers)),
    Object.hashAll([
      for (final server in _sorted(disabledTools.keys))
        Object.hash(server, Object.hashAll(_sorted(disabledTools[server]!))),
    ]),
  );

  /// The settings as they are now, what tells they changed, and what
  /// writes them; main() points them at settings.json.
  static ExtensionSwitches Function() current = () => none;
  static Listenable? changes;
  static Future<void> Function(ExtensionSwitches switches)? save;
}
