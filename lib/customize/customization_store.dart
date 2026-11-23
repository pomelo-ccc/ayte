import 'dart:convert';
import 'dart:io' show Platform;

import 'package:bao_remote/files.dart'
    show IdeFileExistsException, IdeFileNotFoundException;
import 'package:path/path.dart' as p;

import '../kernel/extension_switches.dart';
import 'customization_disk.dart';
import 'customizations.dart';

/// Multi-kernel customizations on a [CustomizationDisk] across Antigravity
/// (`~/.gemini/config`, `<project>/.agents`), Claude Code (`~/.claude`,
/// `~/.claude.json`, `<project>/.claude`), CodeBuddy (`~/.codebuddy`,
/// `<project>/.codebuddy`), and Codex (`~/.codex`, `<project>/.codex`).
class CustomizationStore {
  CustomizationStore({
    this.configDir,
    this.homeDir,
    String? codexHome,
    CustomizationDisk? disk,
  }) : _codexHomeOverride = codexHome,
       _disk = disk ?? CustomizationDisk.local;

  /// Primary global config folder (`~/.gemini/config` locally by default).
  final String? configDir;

  /// The user's home directory.
  final String? homeDir;

  final String? _codexHomeOverride;
  final CustomizationDisk? _disk;

  CustomizationDisk get _files =>
      _disk ?? (throw UnsupportedError('No files on the web'));

  p.Context get _paths => _files.paths;

  /// Whether there are files to read and write here (not on the web).
  bool get supported => _disk != null;

  /// Whether the files are this machine's (not a remote host's): shown in
  /// its file manager, opened in its IDE.
  bool get isLocal => _disk?.isLocal ?? true;

  /// How paths are spelled where the files are.
  p.Context get paths => _disk == null ? p.context : _paths;

  Future<String> config() async => configDir ?? await _files.configDir();

  Future<String?> _home() async => homeDir ?? await _files.homeDir();

  bool get _caseInsensitivePaths => _paths.style == p.Style.windows;

  String _canon(String path) {
    var norm = _paths.normalize(path);
    if (_paths.style == p.Style.windows) {
      while (norm.length > 3 && (norm.endsWith(r'\') || norm.endsWith('/'))) {
        norm = norm.substring(0, norm.length - 1);
      }
    } else {
      while (norm.length > 1 && norm.endsWith('/')) {
        norm = norm.substring(0, norm.length - 1);
      }
    }
    return norm;
  }

  String _pathKey(String path) {
    final norm = _canon(path);
    return _caseInsensitivePaths ? norm.toLowerCase() : norm;
  }

  bool _isClaudePrimary(String config) =>
      config.isNotEmpty && _paths.basename(_canon(config)) == '.claude';

  bool _isCodeBuddyPrimary(String config) =>
      config.isNotEmpty && _paths.basename(_canon(config)) == '.codebuddy';

  bool _isCodexPrimary(String config) =>
      config.isNotEmpty && _paths.basename(_canon(config)) == '.codex';

  String? _resolveCodexHome(String? home) {
    final override = _codexHomeOverride?.trim();
    if (override != null && override.isNotEmpty) return override;
    if (configDir == null && homeDir == null && isLocal) {
      final envCodex = Platform.environment['CODEX_HOME']?.trim();
      if (envCodex != null && envCodex.isNotEmpty) return envCodex;
    }
    if (home != null && home.isNotEmpty) {
      return _paths.join(home, '.codex');
    }
    return null;
  }

  List<String> _userRoots(String config, String? home) {
    final roots = <String>[];
    final seen = <String>{};
    void add(String? dir) {
      if (dir == null || dir.trim().isEmpty) return;
      final norm = _canon(dir.trim());
      if (seen.add(_pathKey(norm))) roots.add(norm);
    }

    add(config);
    if (home != null && home.isNotEmpty) {
      add(_paths.join(home, '.gemini', 'config'));
      add(_paths.join(home, '.claude'));
      add(_paths.join(home, '.codebuddy'));
      add(_resolveCodexHome(home));
      add(_paths.join(home, '.agents'));
    }
    return roots;
  }

  List<String> _projectFolders(String config, String project) {
    final folders = <String>[];
    final seen = <String>{};
    void add(String sub) {
      final dir = _paths.join(project, sub);
      if (seen.add(_pathKey(dir))) folders.add(dir);
    }

    if (_isClaudePrimary(config)) {
      add('.claude');
      add('.agents');
      add('.agent');
      add('.codebuddy');
      add('.codex');
    } else if (_isCodeBuddyPrimary(config)) {
      add('.codebuddy');
      add('.agents');
      add('.agent');
      add('.claude');
      add('.codex');
    } else if (_isCodexPrimary(config)) {
      add('.codex');
      add('.agents');
      add('.agent');
      add('.claude');
      add('.codebuddy');
    } else {
      add('.agents');
      add('.agent');
      add('.claude');
      add('.codebuddy');
      add('.codex');
    }
    return folders;
  }

  Future<bool> _usesInstalledPluginsJson(String root) async =>
      _paths.basename(_canon(root)) == '.claude' ||
      await _files.read(_paths.join(root, 'plugins', 'installed_plugins.json')) !=
          null;

  /// Those of [kind], the user's and [project]'s (none of a project's when
  /// null), by scope then name.
  Future<List<Customization>> list(
    CustomizationKind kind, {
    String? project,
  }) async {
    if (!supported) return const [];
    final config = await this.config();
    final home = await _home();
    final pluginNamesByPath = <String, Set<String>>{};
    final items = switch (kind) {
      CustomizationKind.skills => await _allSkills(
        config,
        home,
        project,
        pluginNamesByPath: pluginNamesByPath,
      ),
      CustomizationKind.subagents => await _allSubagents(config, home, project),
      CustomizationKind.commands => await _allCommands(config, home, project),
      CustomizationKind.rules => await _rules(config, home, project),
      CustomizationKind.memory => await _memories(config, home, project),
      CustomizationKind.mcps => await _servers(config, home, project),
      CustomizationKind.hooks => await _hooks(config, home, project),
      CustomizationKind.plugins => await _plugins(config, home, project),
    };
    final switches = ExtensionSwitches.current();
    return [
      for (final item in items)
        _applyExtensionSwitches(
          item,
          switches,
          pluginNames: pluginNamesByPath[_pathKey(item.path)] ?? const {},
        ),
    ]..sort((a, b) {
      final scope = a.scope.index.compareTo(b.scope.index);
      return scope != 0
          ? scope
          : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  }

  static Customization _applyExtensionSwitches(
    Customization item,
    ExtensionSwitches switches, {
    Iterable<String> pluginNames = const [],
  }) {
    if (item.kind != CustomizationKind.skills &&
        item.kind != CustomizationKind.mcps) {
      return item;
    }
    if (item.enabled == false ||
        switches.allowsCustomization(item, pluginNames: pluginNames)) {
      return item;
    }
    return Customization(
      kind: item.kind,
      scope: item.scope,
      name: item.name,
      path: item.path,
      description: item.description,
      editable: item.editable,
      removePath: item.removePath,
      detail: item.detail,
      enabled: false,
      server: item.server,
      unreachable: item.unreachable,
    );
  }

  Future<List<Customization>> _allSkills(
    String config,
    String? home,
    String? project, {
    Map<String, Set<String>>? pluginNamesByPath,
  }) async {
    final items = <Customization>[];
    final seen = <String>{};
    void addAll(Iterable<Customization> next) {
      for (final item in next) {
        if (seen.add(_pathKey(item.path))) items.add(item);
      }
    }

    for (final root in _userRoots(config, home)) {
      final skillsDir = _paths.join(root, 'skills');
      final isClaude = _paths.basename(_canon(root)) == '.claude';
      for (final folder in await _subfolders(skillsDir)) {
        if (isClaude && _paths.basename(folder) == 'synced') {
          for (final bucket in await _subfolders(folder)) {
            addAll(await _skills(CustomizationScope.synced, bucket));
          }
          continue;
        }
        if (await _skill(CustomizationScope.user, folder) case final skill?) {
          if (seen.add(_pathKey(skill.path))) items.add(skill);
        }
      }
    }
    addAll(
      await _pluginSkills(config, home, pluginNamesByPath: pluginNamesByPath),
    );
    if (project != null && project.isNotEmpty) {
      for (final dir in _projectFolders(config, project)) {
        addAll(
          await _skills(
            CustomizationScope.project,
            _paths.join(dir, 'skills'),
          ),
        );
      }
    }
    return items;
  }

  Future<List<Customization>> _allSubagents(
    String config,
    String? home,
    String? project,
  ) async {
    final items = <Customization>[];
    final seen = <String>{};
    void addAll(Iterable<Customization> next) {
      for (final item in next) {
        if (seen.add(_pathKey(item.path))) items.add(item);
      }
    }

    for (final root in _userRoots(config, home)) {
      addAll(
        await _markdown(
          CustomizationKind.subagents,
          CustomizationScope.user,
          _paths.join(root, 'agents'),
        ),
      );
    }
    if (project != null && project.isNotEmpty) {
      for (final dir in _projectFolders(config, project)) {
        addAll(
          await _markdown(
            CustomizationKind.subagents,
            CustomizationScope.project,
            _paths.join(dir, 'agents'),
          ),
        );
      }
    }
    return items;
  }

  Future<List<Customization>> _allCommands(
    String config,
    String? home,
    String? project,
  ) async {
    final items = <Customization>[];
    final seen = <String>{};
    void addAll(Iterable<Customization> next) {
      for (final item in next) {
        if (seen.add(_pathKey(item.path))) items.add(item);
      }
    }

    for (final root in _userRoots(config, home)) {
      addAll(
        await _markdown(
          CustomizationKind.commands,
          CustomizationScope.user,
          _paths.join(root, 'commands'),
        ),
      );
    }
    if (project != null && project.isNotEmpty) {
      for (final dir in _projectFolders(config, project)) {
        addAll(
          await _markdown(
            CustomizationKind.commands,
            CustomizationScope.project,
            _paths.join(dir, 'commands'),
          ),
        );
      }
    }
    return items;
  }

  static String _cleanName(String raw) {
    var value = raw.trim();
    while (value.startsWith('/')) {
      value = value.substring(1).trim();
    }
    return value;
  }

  static bool _isSafeName(String value) =>
      value.isNotEmpty &&
      !value.startsWith('.') &&
      !value.contains('/') &&
      !value.contains('\\') &&
      !value.contains(':') &&
      !value.contains('\x00');

  /// The file of the `/command` [name]: a skill's SKILL.md or a command's
  /// markdown, the user's, [project]'s or a plugin's (`plugin:name`); null
  /// for none (one built in).
  Future<String?> commandFile(String name, {String? project}) async {
    if (!supported) return null;
    final query = _cleanName(name);
    if (query.isEmpty) return null;
    final switches = ExtensionSwitches.current();
    final colon = query.indexOf(':');
    if (colon == 0) return null;
    if (colon > 0) {
      return _pluginCommandFile(
        query.substring(0, colon),
        query.substring(colon + 1),
        switches: switches,
      );
    }
    if (!_isSafeName(query)) return null;

    final config = await this.config();
    final home = await _home();

    // 1. Project (.agents / .agent / .claude / .codebuddy / .codex).
    if (project != null && project.isNotEmpty) {
      final projectDirs = _projectFolders(config, project);
      for (final base in projectDirs) {
        if (await _findSkillInRoot(
          _paths.join(base, 'skills'),
          query,
          switches: switches,
        ) case final hit?) {
          return hit;
        }
      }
      for (final base in projectDirs) {
        for (final sub in const ['commands', 'workflows']) {
          if (await _findMarkdownCommand(_paths.join(base, sub), query)
              case final hit?) {
            return hit;
          }
        }
      }
    }

    // 2. User global across all kernel roots + Antigravity global_workflows.
    final userRoots = _userRoots(config, home);
    for (final root in userRoots) {
      final skillsDir = _paths.join(root, 'skills');
      final isClaude = _paths.basename(_canon(root)) == '.claude';
      if (await _findSkillInRoot(
        skillsDir,
        query,
        switches: switches,
        skipSyncedFolder: isClaude,
      ) case final hit?) {
        return hit;
      }
      if (isClaude) {
        for (final bucket in await _subfolders(_paths.join(skillsDir, 'synced'))) {
          if (await _findSkillInRoot(bucket, query, switches: switches)
              case final hit?) {
            return hit;
          }
        }
      }
      if (await _findMarkdownCommand(_paths.join(root, 'commands'), query)
          case final hit?) {
        return hit;
      }
    }
    if (home != null && home.isNotEmpty) {
      if (await _findMarkdownCommand(
        _paths.join(home, '.gemini', 'antigravity', 'global_workflows'),
        query,
      ) case final hit?) {
        return hit;
      }
    }

    // 3. Enabled plugins (directory plugins + Claude installed_plugins.json).
    for (final root in userRoots) {
      if (await _usesInstalledPluginsJson(root)) {
        for (final plugin in await _enabledClaudePlugins(root)) {
          if (await _findSkillInRoot(
            _paths.join(plugin.dir, 'skills'),
            query,
            switches: switches,
            pluginNames: {plugin.shortKey, plugin.pluginKey, plugin.name},
          ) case final hit?) {
            return hit;
          }
          for (final sub in const ['commands', 'workflows']) {
            if (await _findMarkdownCommand(
              _paths.join(plugin.dir, sub),
              query,
            ) case final hit?) {
              return hit;
            }
          }
        }
      } else {
        for (final plugin in await _enabledPlugins(root)) {
          if (await _findSkillInRoot(
            _paths.join(plugin.dir, 'skills'),
            query,
            switches: switches,
            pluginNames: {plugin.dirName, plugin.name},
          ) case final hit?) {
            return hit;
          }
          for (final sub in const ['commands', 'workflows']) {
            if (await _findMarkdownCommand(
              _paths.join(plugin.dir, sub),
              query,
            ) case final hit?) {
              return hit;
            }
          }
        }
      }
    }
    return null;
  }

  Future<String?> _pluginCommandFile(
    String plugin,
    String name, {
    required ExtensionSwitches switches,
  }) async {
    final cleanPlugin = plugin.trim();
    final cleanSub = _cleanName(name);
    if (!_isSafeName(cleanPlugin) || !_isSafeName(cleanSub)) return null;
    final pluginSkillDisabled = switches.matchesSkillDisabled(
      '$cleanPlugin:$cleanSub',
    );
    final config = await this.config();
    final home = await _home();
    for (final root in _userRoots(config, home)) {
      if (await _usesInstalledPluginsJson(root)) {
        for (final entry in await _enabledClaudePlugins(root)) {
          if (entry.shortKey != cleanPlugin &&
              entry.pluginKey != cleanPlugin &&
              entry.name != cleanPlugin) {
            continue;
          }
          if (!pluginSkillDisabled) {
            if (await _findSkillInRoot(
              _paths.join(entry.dir, 'skills'),
              cleanSub,
              switches: switches,
              pluginNames: {entry.shortKey, entry.pluginKey, entry.name},
            ) case final hit?) {
              return hit;
            }
          }
          for (final sub in const ['commands', 'workflows']) {
            if (await _findMarkdownCommand(
              _paths.join(entry.dir, sub),
              cleanSub,
            ) case final hit?) {
              return hit;
            }
          }
        }
      } else {
        for (final entry in await _enabledPlugins(root)) {
          if (entry.dirName != cleanPlugin && entry.name != cleanPlugin) continue;
          if (!pluginSkillDisabled) {
            if (await _findSkillInRoot(
              _paths.join(entry.dir, 'skills'),
              cleanSub,
              switches: switches,
              pluginNames: {entry.dirName, entry.name},
            ) case final hit?) {
              return hit;
            }
          }
          for (final sub in const ['commands', 'workflows']) {
            if (await _findMarkdownCommand(
              _paths.join(entry.dir, sub),
              cleanSub,
            ) case final hit?) {
              return hit;
            }
          }
        }
      }
    }
    return null;
  }

  Future<String?> _findSkillInRoot(
    String root,
    String query, {
    ExtensionSwitches? switches,
    Iterable<String> pluginNames = const [],
    bool skipSyncedFolder = false,
  }) async {
    for (final folder in await _subfolders(root)) {
      final folderName = _paths.basename(folder);
      if (skipSyncedFolder && folderName == 'synced') continue;
      final skill = await _skill(CustomizationScope.plugin, folder);
      if (skill == null || skill.unreachable) continue;
      if (switches != null &&
          switches.matchesSkillDisabled(
            skill.name,
            folderName: folderName,
            pluginNames: pluginNames,
          )) {
        continue;
      }
      if (_cleanName(skill.name) == query || folderName == query) {
        return skill.path;
      }
    }
    return null;
  }

  Future<String?> _findMarkdownCommand(String root, String query) async {
    final direct = _paths.join(root, '$query.md');
    if (await _files.read(direct) != null) return direct;
    for (final command in await _markdown(
      CustomizationKind.commands,
      CustomizationScope.plugin,
      root,
    )) {
      if (command.name == '/$query') return command.path;
    }
    return null;
  }

  Future<Set<String>> _disabledPlugins(String config) async {
    if (config.isEmpty) return const {};
    final globalConfig = await _json(_paths.join(config, 'config.json'));
    return <String>{
      if (globalConfig?['disabledPlugins'] case final List<Object?> list)
        for (final item in list.whereType<String>())
          if (item.trim().isNotEmpty) item.trim(),
      if (globalConfig?['plugins'] case final Map<Object?, Object?> plugins)
        for (final MapEntry(:key, :value) in plugins.entries)
          if (key is String &&
              key.trim().isNotEmpty &&
              value is Map &&
              value['enabled'] == false)
            key.trim(),
    };
  }

  Future<List<({String dir, String dirName, String name})>> _enabledPlugins(
    String config,
  ) async {
    if (config.isEmpty) return const [];
    final disabled = await _disabledPlugins(config);
    final enabled = <({String dir, String dirName, String name})>[];
    for (final pluginDir in await _subfolders(_paths.join(config, 'plugins'))) {
      final dirName = _paths.basename(pluginDir);
      final manifest = await _json(_paths.join(pluginDir, 'plugin.json'));
      final name = switch (manifest?['name']) {
        final String s when s.trim().isNotEmpty => s.trim(),
        _ => dirName,
      };
      if (disabled.contains(dirName) || disabled.contains(name)) continue;
      enabled.add((dir: pluginDir, dirName: dirName, name: name));
    }
    return enabled;
  }

  Future<
    List<
      ({
        String pluginKey,
        String shortKey,
        String market,
        String dir,
        String name,
        String description,
        String? manifestPath,
        bool enabled,
      })
    >
  >
  _claudeInstalledPlugins(String claudeRoot) async {
    final installedPath = _paths.join(
      claudeRoot,
      'plugins',
      'installed_plugins.json',
    );
    final installed = await _json(installedPath);
    if (installed == null) return const [];
    final pluginsMap = installed['plugins'];
    if (pluginsMap is! Map<Object?, Object?>) return const [];
    final settings = await _json(_paths.join(claudeRoot, 'settings.json'));
    final enabledMap = settings?['enabledPlugins'];
    final out =
        <
          ({
            String pluginKey,
            String shortKey,
            String market,
            String dir,
            String name,
            String description,
            String? manifestPath,
            bool enabled,
          })
        >[];

    for (final MapEntry(:key, :value) in pluginsMap.entries) {
      if (key is! String || value is! List<Object?> || value.isEmpty) continue;
      final installs = value.whereType<Map<Object?, Object?>>().toList();
      if (installs.isEmpty) continue;
      final first =
          installs.where((e) => e['scope'] == 'user').firstOrNull ??
          installs.first;
      final installPath = first['installPath'];
      if (installPath is! String || installPath.trim().isEmpty) continue;
      final at = key.indexOf('@');
      final shortKey = at > 0 ? key.substring(0, at) : key;
      final market = at > 0 ? key.substring(at + 1) : '';
      final version = switch (first['version']) {
        final String v when v.trim().isNotEmpty => v.trim(),
        _ => '',
      };
      final manifestPath = _paths.join(
        installPath,
        '.claude-plugin',
        'plugin.json',
      );
      final manifest = await _json(manifestPath);
      final name = switch (manifest?['name']) {
        final String s when s.trim().isNotEmpty => s.trim(),
        _ => shortKey,
      };
      final description = switch (manifest?['description']) {
        final String d when d.trim().isNotEmpty => d.trim(),
        _ => [
          if (market.isNotEmpty) market,
          if (version.isNotEmpty) version,
        ].join(' · '),
      };
      final enabled = enabledMap is Map<Object?, Object?>
          ? enabledMap[key] == true
          : true;
      out.add((
        pluginKey: key,
        shortKey: shortKey,
        market: market,
        dir: installPath,
        name: name,
        description: description,
        manifestPath: manifest != null ? manifestPath : null,
        enabled: enabled,
      ));
    }
    return out;
  }

  Future<List<({String pluginKey, String shortKey, String dir, String name})>>
  _enabledClaudePlugins(String claudeRoot) async => [
    for (final item in await _claudeInstalledPlugins(claudeRoot))
      if (item.enabled)
        (
          pluginKey: item.pluginKey,
          shortKey: item.shortKey,
          dir: item.dir,
          name: item.name,
        ),
  ];

  Future<String> read(String path) async =>
      await _files.read(path) ?? (throw IdeFileNotFoundException(path));

  Future<bool> exists(String path) async =>
      await _files.isDirectory(path) == false;

  Future<void> write(String path, String text) => _files.write(path, text);

  /// Makes a new one of [kind] named [name] from its template: the user's,
  /// or [project]'s. Returns its file; throws an [IdeFileExistsException]
  /// when one by that name is there already.
  Future<String> create(
    CustomizationKind kind,
    CustomizationScope scope,
    String name, {
    String? project,
  }) async {
    if (!kind.creatable || !isCustomizationName(name)) {
      throw ArgumentError.value(name, 'name');
    }
    final config = await this.config();
    final String base;
    if (scope == CustomizationScope.user) {
      base = config;
    } else if (_isClaudePrimary(config)) {
      base = _paths.join(project!, '.claude');
    } else if (_isCodeBuddyPrimary(config)) {
      base = _paths.join(project!, '.codebuddy');
    } else if (_isCodexPrimary(config)) {
      base = _paths.join(project!, '.codex');
    } else {
      base = _paths.join(project!, '.agents');
    }
    final path = switch (kind) {
      CustomizationKind.skills => _paths.join(base, 'skills', name, 'SKILL.md'),
      CustomizationKind.subagents => _paths.join(base, 'agents', '$name.md'),
      CustomizationKind.commands => _paths.join(base, 'commands', '$name.md'),
      _ => _paths.join(base, 'rules', '$name.md'),
    };
    final taken = kind == CustomizationKind.skills
        ? await _files.isDirectory(_paths.dirname(path)) != null
        : await _files.isDirectory(path) != null;
    if (taken) throw IdeFileExistsException(path);
    await write(path, template(kind, name));
    return path;
  }

  /// The file [kind] is kept in for [scope], to be edited whole:
  /// `mcp_config.json` / `.mcp.json` for MCPs, `hooks.json` / `settings.json`
  /// for hooks.
  Future<String?> configFile(
    CustomizationKind kind,
    CustomizationScope scope, {
    String? project,
  }) async {
    if (!kind.configuredIn(scope) || !supported) return null;
    final config = await this.config();
    if (_isClaudePrimary(config)) {
      if (kind == CustomizationKind.mcps) {
        return switch (scope) {
          CustomizationScope.project when project != null => _paths.join(
            project,
            '.mcp.json',
          ),
          _ => null,
        };
      }
      return switch (scope) {
        CustomizationScope.user => _paths.join(config, 'settings.json'),
        CustomizationScope.local when project != null => _paths.join(
          project,
          '.claude',
          'settings.local.json',
        ),
        CustomizationScope.project when project != null => _paths.join(
          project,
          '.claude',
          'settings.json',
        ),
        _ => null,
      };
    }
    if (_isCodeBuddyPrimary(config)) {
      if (kind == CustomizationKind.mcps) {
        return switch (scope) {
          CustomizationScope.user => _paths.join(config, 'mcp_config.json'),
          CustomizationScope.project when project != null => _paths.join(
            project,
            '.codebuddy',
            'mcp.json',
          ),
          _ => null,
        };
      }
      return switch (scope) {
        CustomizationScope.user => _paths.join(config, 'settings.json'),
        CustomizationScope.project when project != null => _paths.join(
          project,
          '.codebuddy',
          'settings.json',
        ),
        CustomizationScope.local when project != null => _paths.join(
          project,
          '.codebuddy',
          'settings.local.json',
        ),
        _ => null,
      };
    }
    if (kind == CustomizationKind.mcps) {
      if (scope == CustomizationScope.user) {
        return _paths.join(config, 'mcp_config.json');
      }
      if (scope == CustomizationScope.project && project != null) {
        final agentsMcp = _paths.join(project, '.agents', 'mcp_config.json');
        if (await _files.isDirectory(agentsMcp) == false) return agentsMcp;
        final rootMcp = _paths.join(project, '.mcp.json');
        if (await _files.isDirectory(rootMcp) == false) return rootMcp;
        return agentsMcp;
      }
      return null;
    }
    for (final (own, path) in _hooksFiles(config, project)) {
      if (own == scope) return path;
    }
    return null;
  }

  /// Removes [item]'s file, or its folder (a skill's).
  Future<void> delete(Customization item) async {
    final path = item.removePath;
    if (path == null) return;
    await _files.delete(path);
  }

  // --- Reading ---------------------------------------------------------------

  Future<Map<String, Object?>?> _json(String path) async {
    final text = await _files.read(path);
    if (text == null) return null;
    try {
      final json = jsonDecode(text);
      return json is Map<String, Object?> ? json : null;
    } on Object {
      return null;
    }
  }

  static const _pretty = JsonEncoder.withIndent('  ');

  Future<List<String>> _subfolders(String dir) async => [
    for (final child in await _files.children(dir))
      if (child.directory && !_paths.basename(child.path).startsWith('.'))
        child.path,
  ];

  /// Each folder of [root] with a SKILL.md.
  Future<List<Customization>> _skills(
    CustomizationScope scope,
    String root,
  ) async {
    final skills = <Customization>[];
    for (final folder in await _subfolders(root)) {
      skills.addAll([?await _skill(scope, folder)]);
    }
    return skills;
  }

  /// Skills bundled inside enabled installed plugins across kernel roots.
  Future<List<Customization>> _pluginSkills(
    String config,
    String? home, {
    Map<String, Set<String>>? pluginNamesByPath,
  }) async {
    final skills = <Customization>[];
    final seen = <String>{};
    for (final root in _userRoots(config, home)) {
      if (await _usesInstalledPluginsJson(root)) {
        for (final plugin in await _enabledClaudePlugins(root)) {
          final names = <String>{
            if (plugin.shortKey.isNotEmpty) plugin.shortKey,
            if (plugin.pluginKey.isNotEmpty) plugin.pluginKey,
            if (plugin.name.isNotEmpty) plugin.name,
          };
          for (final folder in await _subfolders(
            _paths.join(plugin.dir, 'skills'),
          )) {
            if (await _skill(CustomizationScope.plugin, folder)
                case final skill?) {
              final key = _pathKey(skill.path);
              if (seen.add(key)) {
                skills.add(skill);
                if (pluginNamesByPath != null && names.isNotEmpty) {
                  pluginNamesByPath[key] = names;
                }
              }
            }
          }
        }
      } else {
        for (final plugin in await _enabledPlugins(root)) {
          final names = <String>{
            if (plugin.dirName.isNotEmpty) plugin.dirName,
            if (plugin.name.isNotEmpty) plugin.name,
          };
          for (final folder in await _subfolders(
            _paths.join(plugin.dir, 'skills'),
          )) {
            if (await _skill(CustomizationScope.plugin, folder)
                case final skill?) {
              final key = _pathKey(skill.path);
              if (seen.add(key)) {
                skills.add(skill);
                if (pluginNamesByPath != null && names.isNotEmpty) {
                  pluginNamesByPath[key] = names;
                }
              }
            }
          }
        }
      }
    }
    return skills;
  }

  Future<Customization?> _skill(CustomizationScope scope, String folder) async {
    final path = _paths.join(folder, 'SKILL.md');
    final text = await _files.read(path);
    if (text == null) {
      if (await _files.isDirectory(folder) != null) return null;
      return Customization(
        kind: CustomizationKind.skills,
        scope: scope,
        name: _paths.basename(folder),
        path: path,
        editable: false,
        detail: '',
        removePath: folder,
        unreachable: true,
      );
    }
    final readOnly =
        scope == CustomizationScope.synced || scope == CustomizationScope.plugin;
    return Customization(
      kind: CustomizationKind.skills,
      scope: scope,
      name: switch (parseFrontMatter(text)['name']) {
        final name? when name.isNotEmpty => name,
        _ => _paths.basename(folder),
      },
      description: describeMarkdown(text),
      path: path,
      editable: !readOnly,
      removePath: readOnly ? null : folder,
    );
  }

  static const _deepest = 8;

  Future<List<Customization>> _markdown(
    CustomizationKind kind,
    CustomizationScope scope,
    String root, {
    bool editable = true,
  }) async {
    final found = <Customization>[];
    Future<void> walk(String dir, int depth) async {
      for (final child in await _files.children(dir)) {
        if (child.directory) {
          if (depth < _deepest) await walk(child.path, depth + 1);
        } else if (child.path.endsWith('.md')) {
          if (await _files.read(child.path) case final text?) {
            found.add(
              Customization(
                kind: kind,
                scope: scope,
                name: _markdownName(kind, child.path, text),
                description: describeMarkdown(text),
                path: child.path,
                editable: editable,
                removePath: editable ? child.path : null,
              ),
            );
          }
        }
      }
    }

    await walk(root, 0);
    return found;
  }

  String _markdownName(CustomizationKind kind, String path, String text) {
    final file = _paths.basenameWithoutExtension(path);
    if (kind == CustomizationKind.commands) return '/$file';
    return switch (parseFrontMatter(text)['name']) {
      final name? when name.isNotEmpty => name,
      _ => file,
    };
  }

  /// Rules across Antigravity, Claude Code, CodeBuddy, and Codex roots.
  Future<List<Customization>> _rules(
    String config,
    String? home,
    String? project,
  ) async {
    final items = <Customization>[];
    final seen = <String>{};

    void add(Customization? rule) {
      if (rule == null) return;
      if (seen.add(_pathKey(rule.path))) items.add(rule);
    }

    void addAll(Iterable<Customization> rules) {
      for (final rule in rules) {
        add(rule);
      }
    }

    Future<Customization?> ruleFile(
      CustomizationScope scope,
      String path,
      String base,
    ) async {
      final text = await _files.read(path);
      if (text == null) return null;
      return Customization(
        kind: CustomizationKind.rules,
        scope: scope,
        name: _paths.relative(path, from: base),
        description: describeMarkdown(text),
        path: path,
        editable: !const {
          'GEMINI.md',
          'AGENTS.md',
          'AGENTS.override.md',
          'CLAUDE.md',
          'CODEBUDDY.md',
        }.contains(_paths.basename(path)),
      );
    }

    Future<List<Customization>> folder(
      CustomizationScope scope,
      String root,
      String base, {
      bool editable = true,
    }) async => [
      for (final rule in await _markdown(
        CustomizationKind.rules,
        scope,
        root,
        editable: editable,
      ))
        Customization(
          kind: rule.kind,
          scope: rule.scope,
          name: _paths.relative(rule.path, from: base),
          description: rule.description,
          path: rule.path,
          editable: editable,
          removePath: rule.removePath,
        ),
    ];

    final userRoots = _userRoots(config, home);
    for (final root in userRoots) {
      final baseName = _paths.basename(_canon(root));
      if (baseName == '.claude') {
        add(
          await ruleFile(
            CustomizationScope.user,
            _paths.join(root, 'CLAUDE.md'),
            root,
          ),
        );
        addAll(
          await folder(
            CustomizationScope.user,
            _paths.join(root, 'rules'),
            root,
          ),
        );
      } else if (baseName == '.codebuddy') {
        add(
          await ruleFile(
            CustomizationScope.user,
            _paths.join(root, 'CODEBUDDY.md'),
            root,
          ),
        );
        addAll(
          await folder(
            CustomizationScope.user,
            _paths.join(root, 'rules'),
            root,
          ),
        );
      } else if (baseName == '.codex') {
        add(
          await ruleFile(
            CustomizationScope.user,
            _paths.join(root, 'AGENTS.md'),
            root,
          ),
        );
        add(
          await ruleFile(
            CustomizationScope.user,
            _paths.join(root, 'AGENTS.override.md'),
            root,
          ),
        );
      } else {
        add(
          await ruleFile(
            CustomizationScope.user,
            _paths.join(root, 'GEMINI.md'),
            root,
          ),
        );
        add(
          await ruleFile(
            CustomizationScope.user,
            _paths.join(root, 'AGENTS.md'),
            root,
          ),
        );
        addAll(
          await folder(
            CustomizationScope.user,
            _paths.join(root, 'rules'),
            root,
          ),
        );
      }

      if (await _usesInstalledPluginsJson(root)) {
        for (final plugin in await _enabledClaudePlugins(root)) {
          addAll(
            await folder(
              CustomizationScope.plugin,
              _paths.join(plugin.dir, 'rules'),
              plugin.dir,
              editable: false,
            ),
          );
        }
      } else {
        for (final plugin in await _enabledPlugins(root)) {
          addAll(
            await folder(
              CustomizationScope.plugin,
              _paths.join(plugin.dir, 'rules'),
              _paths.join(root, 'plugins'),
              editable: false,
            ),
          );
        }
      }
    }

    if (project != null && project.isNotEmpty) {
      if (_isClaudePrimary(config)) {
        final rootClaude = await ruleFile(
          CustomizationScope.project,
          _paths.join(project, 'CLAUDE.md'),
          project,
        );
        final dotClaude = await ruleFile(
          CustomizationScope.project,
          _paths.join(project, '.claude', 'CLAUDE.md'),
          project,
        );
        final hasClaudeMd = rootClaude != null || dotClaude != null;
        if (!hasClaudeMd) {
          add(
            await ruleFile(
              CustomizationScope.project,
              _paths.join(project, 'AGENTS.md'),
              project,
            ),
          );
        }
        add(rootClaude);
        add(dotClaude);
        addAll(
          await folder(
            CustomizationScope.project,
            _paths.join(project, '.claude', 'rules'),
            project,
          ),
        );
        addAll(
          await folder(
            CustomizationScope.project,
            _paths.join(project, '.agents', 'rules'),
            project,
          ),
        );
      } else {
        for (final fileName in const [
          'GEMINI.md',
          'AGENTS.md',
          'AGENTS.override.md',
          'CLAUDE.md',
          'CODEBUDDY.md',
        ]) {
          add(
            await ruleFile(
              CustomizationScope.project,
              _paths.join(project, fileName),
              project,
            ),
          );
        }
        add(
          await ruleFile(
            CustomizationScope.project,
            _paths.join(project, '.claude', 'CLAUDE.md'),
            project,
          ),
        );
        for (final sub in const ['.agents', '.claude', '.codebuddy']) {
          addAll(
            await folder(
              CustomizationScope.project,
              _paths.join(project, sub, 'rules'),
              project,
            ),
          );
        }
      }
    }

    return items;
  }

  /// Project memory files stored under `<root>/projects/<project>/memory/`.
  Future<List<Customization>> _memories(
    String config,
    String? home,
    String? project,
  ) async {
    if (project == null || project.isEmpty) return const [];
    final dirName = claudeProjectDirName(project);
    final dirs = <String>[];
    final seenDirs = <String>{};
    void addDir(String d) {
      if (seenDirs.add(_pathKey(d))) dirs.add(d);
    }

    if (config.isNotEmpty) {
      addDir(_paths.join(config, 'projects', dirName, 'memory'));
    }
    if (home != null && home.isNotEmpty) {
      for (final root in const ['.ayte', '.claude', '.codebuddy']) {
        addDir(_paths.join(home, root, 'projects', dirName, 'memory'));
      }
    }

    final items = <Customization>[];
    final seenFiles = <String>{};
    for (final folder in dirs) {
      for (final child in await _files.children(folder)) {
        if (child.directory || !child.path.endsWith('.md')) continue;
        if (!seenFiles.add(_pathKey(child.path))) continue;
        if (await _files.read(child.path) case final text?) {
          items.add(
            Customization(
              kind: CustomizationKind.memory,
              scope: CustomizationScope.project,
              name: _paths.basename(child.path),
              description: describeMarkdown(text),
              path: child.path,
              removePath: child.path,
            ),
          );
        }
      }
    }
    return items;
  }

  /// MCP servers across Antigravity (`mcp_config.json`, `.mcp.json`), Claude
  /// (`~/.claude.json`, `.mcp.json`, enabled plugins), CodeBuddy (`mcp.json`,
  /// `mcp_config.json`), and Codex (`config.toml` `[mcp_servers.<name>]`).
  Future<List<Customization>> _servers(
    String config,
    String? home,
    String? project,
  ) async {
    final items = <Customization>[];
    final seen = <(String, CustomizationScope, String)>{};

    void addItem(Customization item) {
      final key = (_pathKey(item.path), item.scope, item.name);
      if (seen.add(key)) items.add(item);
    }

    void addServers(
      CustomizationScope scope,
      Object? entries,
      String path, {
      required bool editable,
    }) {
      if (entries is! Map<String, Object?>) return;
      for (final MapEntry(key: name, value: server) in entries.entries) {
        final serverMap = server is Map<String, Object?> ? server : null;
        final isDisabled =
            serverMap != null &&
            (serverMap['disabled'] == true || serverMap['enabled'] == false);
        addItem(
          Customization(
            kind: CustomizationKind.mcps,
            scope: scope,
            name: name,
            description: _describeServer(server),
            path: path,
            editable: editable,
            detail: _pretty.convert({name: server}),
            server: serverMap,
            enabled: isDisabled ? false : null,
          ),
        );
      }
    }

    // 1. User & plugin servers across kernel roots
    for (final root in _userRoots(config, home)) {
      final baseName = _paths.basename(_canon(root));
      if (baseName == '.claude') {
        for (final plugin in await _enabledClaudePlugins(root)) {
          final mcpFile = _paths.join(plugin.dir, '.mcp.json');
          final json = await _json(mcpFile);
          if (json != null) {
            addServers(
              CustomizationScope.plugin,
              json['mcpServers'] ?? json,
              mcpFile,
              editable: false,
            );
          }
        }
      } else if (baseName == '.codex') {
        final tomlPath = _paths.join(root, 'config.toml');
        await _collectTomlServers(
          CustomizationScope.user,
          tomlPath,
          addItem,
        );
      } else if (baseName == '.codebuddy') {
        for (final fileName in const ['mcp_config.json', 'mcp.json']) {
          final path = _paths.join(root, fileName);
          addServers(
            CustomizationScope.user,
            (await _json(path))?['mcpServers'],
            path,
            editable: true,
          );
        }
        if (await _usesInstalledPluginsJson(root)) {
          for (final plugin in await _enabledClaudePlugins(root)) {
            final mcpFile = _paths.join(plugin.dir, '.mcp.json');
            final json = await _json(mcpFile);
            if (json != null) {
              addServers(
                CustomizationScope.plugin,
                json['mcpServers'] ?? json,
                mcpFile,
                editable: false,
              );
            }
          }
        } else {
          for (final plugin in await _enabledPlugins(root)) {
            for (final candidate in [
              _paths.join(plugin.dir, 'mcp_config.json'),
              _paths.join(plugin.dir, 'mcp.json'),
            ]) {
              final json = await _json(candidate);
              if (json != null) {
                addServers(
                  CustomizationScope.plugin,
                  json['mcpServers'] ?? json,
                  candidate,
                  editable: false,
                );
              }
            }
          }
        }
      } else {
        final userMcp = _paths.join(root, 'mcp_config.json');
        addServers(
          CustomizationScope.user,
          (await _json(userMcp))?['mcpServers'],
          userMcp,
          editable: true,
        );
        if (await _usesInstalledPluginsJson(root)) {
          for (final plugin in await _enabledClaudePlugins(root)) {
            final mcpFile = _paths.join(plugin.dir, '.mcp.json');
            final json = await _json(mcpFile);
            if (json != null) {
              addServers(
                CustomizationScope.plugin,
                json['mcpServers'] ?? json,
                mcpFile,
                editable: false,
              );
            }
          }
        } else {
          for (final plugin in await _enabledPlugins(root)) {
            for (final candidate in [
              _paths.join(plugin.dir, 'mcp_config.json'),
              _paths.join(plugin.dir, 'mcp.json'),
            ]) {
              final json = await _json(candidate);
              if (json != null) {
                addServers(
                  CustomizationScope.plugin,
                  json['mcpServers'] ?? json,
                  candidate,
                  editable: false,
                );
              }
            }
          }
        }
      }
    }

    // 2. Claude ~/.claude.json (user, synced connectors, per-project local)
    if (home != null && home.isNotEmpty) {
      final claudeJsonPath = _paths.join(home, '.claude.json');
      final claudeJson = await _json(claudeJsonPath);
      if (claudeJson != null) {
        addServers(
          CustomizationScope.user,
          claudeJson['mcpServers'],
          claudeJsonPath,
          editable: false,
        );
        if (claudeJson['claudeAiMcpEverConnected'] case final List<Object?> list) {
          for (final entry in list.whereType<String>()) {
            if (entry.trim().isEmpty) continue;
            addItem(
              Customization(
                kind: CustomizationKind.mcps,
                scope: CustomizationScope.synced,
                name: entry,
                description: 'claude.ai',
                path: claudeJsonPath,
                editable: false,
              ),
            );
          }
        }
        if (project != null &&
            project.isNotEmpty &&
            claudeJson['projects'] is Map<String, Object?>) {
          final projectsMap = claudeJson['projects']! as Map<String, Object?>;
          final targetKey = _pathKey(project);
          final projEntry =
              projectsMap[project] ??
              projectsMap[_canon(project)] ??
              projectsMap.entries
                  .where((e) => _pathKey(e.key) == targetKey)
                  .map((e) => e.value)
                  .firstOrNull;
          if (projEntry is Map<String, Object?>) {
            addServers(
              CustomizationScope.local,
              projEntry['mcpServers'],
              claudeJsonPath,
              editable: false,
            );
          }
        }
      }
    }

    // 3. Project MCP configs
    if (project != null && project.isNotEmpty) {
      final projectFiles = [
        _paths.join(project, '.agents', 'mcp_config.json'),
        _paths.join(project, '.mcp.json'),
        _paths.join(project, '.codebuddy', 'mcp.json'),
        _paths.join(project, '.codebuddy', 'mcp_config.json'),
      ];
      for (final file in projectFiles) {
        final json = await _json(file);
        if (json != null) {
          addServers(
            CustomizationScope.project,
            json['mcpServers'],
            file,
            editable: true,
          );
        }
      }
      await _collectTomlServers(
        CustomizationScope.project,
        _paths.join(project, '.codex', 'config.toml'),
        addItem,
      );
    }

    return items;
  }

  Future<void> _collectTomlServers(
    CustomizationScope scope,
    String path,
    void Function(Customization) addItem,
  ) async {
    final text = await _files.read(path);
    if (text == null || text.trim().isEmpty) return;
    final servers = _parseCodexTomlMcpServers(text);
    for (final MapEntry(key: name, value: server) in servers.entries) {
      final disabled = server['enabled'] == false || server['disabled'] == true;
      addItem(
        Customization(
          kind: CustomizationKind.mcps,
          scope: scope,
          name: name,
          description: _describeServer(server),
          path: path,
          editable: true,
          detail: _pretty.convert({name: server}),
          server: server,
          enabled: disabled ? false : null,
        ),
      );
    }
  }

  static Map<String, Map<String, Object?>> _parseCodexTomlMcpServers(
    String text,
  ) {
    final result = <String, Map<String, Object?>>{};
    String? currentServer;
    List<String> currentSubPath = const [];
    final lines = const LineSplitter().convert(text);

    for (var i = 0; i < lines.length; i++) {
      final line = _stripTomlComment(lines[i]).trim();
      if (line.isEmpty) continue;

      if (line.startsWith('[') && !line.startsWith('[[')) {
        final end = line.lastIndexOf(']');
        if (end > 0) {
          final header = line.substring(1, end).trim();
          final parts = _splitTomlKeyPath(header);
          if (parts.length >= 2 && parts[0] == 'mcp_servers') {
            currentServer = parts[1];
            currentSubPath = parts.length >= 3 ? parts.sublist(2) : const [];
            var cursor = result.putIfAbsent(
              currentServer,
              () => <String, Object?>{},
            );
            for (final segment in currentSubPath) {
              final existing = cursor[segment];
              if (existing is Map<String, Object?>) {
                cursor = existing;
              } else {
                final nextMap = <String, Object?>{};
                cursor[segment] = nextMap;
                cursor = nextMap;
              }
            }
          } else {
            currentServer = null;
            currentSubPath = const [];
          }
          continue;
        }
      }
      if (line.startsWith('[[')) {
        currentServer = null;
        currentSubPath = const [];
        continue;
      }

      if (currentServer == null) continue;
      final eq = _findUnquotedChar(line, '=');
      if (eq <= 0) continue;
      final rawKey = line.substring(0, eq).trim();
      final keyParts = _splitTomlKeyPath(rawKey);
      if (keyParts.isEmpty) continue;
      var rawValue = line.substring(eq + 1).trim();

      // Support multi-line arrays / inline tables without swallowing
      // subsequent TOML tables or top-level assignments on malformed lines.
      while (!_hasUnclosedSingleLineQuote(rawValue) &&
          _hasUnclosedBrackets(rawValue) &&
          i + 1 < lines.length) {
        var nextIdx = i + 1;
        var peek = '';
        while (nextIdx < lines.length) {
          final candidate = _stripTomlComment(lines[nextIdx]).trim();
          if (candidate.isNotEmpty) {
            peek = candidate;
            break;
          }
          nextIdx++;
        }
        if (peek.isEmpty || _looksLikeTomlTableHeader(peek)) {
          break;
        }
        if (!_hasUnclosedCurly(rawValue) &&
            !peek.startsWith('{') &&
            _findUnquotedChar(peek, '=') > 0) {
          break;
        }
        i = nextIdx;
        rawValue = '$rawValue $peek';
      }

      final parsedValue = _parseTomlValue(rawValue);
      var cursor = result[currentServer]!;
      var valid = true;
      for (final segment in currentSubPath) {
        final existing = cursor[segment];
        if (existing is Map<String, Object?>) {
          cursor = existing;
        } else {
          valid = false;
          break;
        }
      }
      if (!valid) continue;
      for (var k = 0; k < keyParts.length - 1; k++) {
        final segment = keyParts[k];
        final existing = cursor[segment];
        if (existing is Map<String, Object?>) {
          cursor = existing;
        } else if (existing == null) {
          final nextMap = <String, Object?>{};
          cursor[segment] = nextMap;
          cursor = nextMap;
        } else {
          valid = false;
          break;
        }
      }
      if (valid) {
        cursor[keyParts.last] = parsedValue;
      }
    }
    return result;
  }

  static String _stripTomlComment(String line) {
    String? quote;
    var escaped = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (quote == '"' && ch == r'\') {
        escaped = true;
        continue;
      }
      if (quote != null) {
        if (ch == quote) quote = null;
      } else {
        if (ch == '"' || ch == "'") {
          quote = ch;
        } else if (ch == '#') {
          return line.substring(0, i);
        }
      }
    }
    return line;
  }

  static int _findUnquotedChar(String s, String target) {
    String? quote;
    var escaped = false;
    for (var i = 0; i < s.length; i++) {
      final ch = s[i];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (quote == '"' && ch == r'\') {
        escaped = true;
        continue;
      }
      if (quote != null) {
        if (ch == quote) quote = null;
      } else if (ch == '"' || ch == "'") {
        quote = ch;
      } else if (ch == target) {
        return i;
      }
    }
    return -1;
  }

  static bool _hasUnclosedBrackets(String s) {
    var sq = 0;
    var curly = 0;
    String? quote;
    var escaped = false;
    for (var i = 0; i < s.length; i++) {
      final ch = s[i];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (quote == '"' && ch == r'\') {
        escaped = true;
        continue;
      }
      if (quote != null) {
        if (ch == quote) quote = null;
      } else {
        if (ch == '"' || ch == "'") {
          quote = ch;
        } else if (ch == '[') {
          sq++;
        } else if (ch == ']') {
          if (sq > 0) sq--;
        } else if (ch == '{') {
          curly++;
        } else if (ch == '}') {
          if (curly > 0) curly--;
        }
      }
    }
    return sq > 0 || curly > 0;
  }

  static bool _hasUnclosedSingleLineQuote(String s) {
    String? quote;
    var escaped = false;
    for (var i = 0; i < s.length; i++) {
      final ch = s[i];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (quote == '"' && ch == r'\') {
        escaped = true;
        continue;
      }
      if (quote != null) {
        if (ch == quote) quote = null;
      } else if (ch == '"' || ch == "'") {
        quote = ch;
      }
    }
    return quote != null;
  }

  static bool _hasUnclosedCurly(String s) {
    var curly = 0;
    String? quote;
    var escaped = false;
    for (var i = 0; i < s.length; i++) {
      final ch = s[i];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (quote == '"' && ch == r'\') {
        escaped = true;
        continue;
      }
      if (quote != null) {
        if (ch == quote) quote = null;
      } else if (ch == '"' || ch == "'") {
        quote = ch;
      } else if (ch == '{') {
        curly++;
      } else if (ch == '}') {
        if (curly > 0) curly--;
      }
    }
    return curly > 0;
  }

  static bool _looksLikeTomlTableHeader(String line) {
    if (line.startsWith('[mcp_servers.')) return true;
    if (!line.startsWith('[') || !line.endsWith(']')) return false;
    final String inner;
    if (line.startsWith('[[')) {
      if (!line.endsWith(']]') || line.length < 5) return false;
      inner = line.substring(2, line.length - 2).trim();
    } else {
      inner = line.substring(1, line.length - 1).trim();
    }
    if (inner.isEmpty) return false;
    String? quote;
    var escaped = false;
    var hasUnquotedIdent = false;
    for (var i = 0; i < inner.length; i++) {
      final ch = inner[i];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (quote == '"' && ch == r'\') {
        escaped = true;
        continue;
      }
      if (quote != null) {
        if (ch == quote) quote = null;
      } else if (ch == '"' || ch == "'") {
        quote = ch;
      } else if (ch == ',' ||
          ch == '[' ||
          ch == ']' ||
          ch == '=' ||
          ch == '{' ||
          ch == '}') {
        return false;
      } else if (ch != ' ' && ch != '\t' && ch != '.') {
        hasUnquotedIdent = true;
      }
    }
    return quote == null && hasUnquotedIdent;
  }

  static List<String> _splitTomlKeyPath(String header) {
    final parts = <String>[];
    final buf = StringBuffer();
    String? quote;
    var escaped = false;
    for (var i = 0; i < header.length; i++) {
      final ch = header[i];
      if (escaped) {
        buf.write(ch);
        escaped = false;
        continue;
      }
      if (quote == '"' && ch == r'\') {
        escaped = true;
        continue;
      }
      if (quote != null) {
        if (ch == quote) {
          quote = null;
        } else {
          buf.write(ch);
        }
      } else if (ch == '"' || ch == "'") {
        quote = ch;
      } else if (ch == '.') {
        final token = buf.toString().trim();
        if (token.isNotEmpty) parts.add(token);
        buf.clear();
      } else {
        buf.write(ch);
      }
    }
    final last = buf.toString().trim();
    if (last.isNotEmpty) parts.add(last);
    return parts;
  }

  static String _unquoteTomlKey(String raw) {
    final trimmed = raw.trim();
    if (trimmed.length >= 2) {
      if ((trimmed.startsWith('"') && trimmed.endsWith('"')) ||
          (trimmed.startsWith("'") && trimmed.endsWith("'"))) {
        return trimmed.substring(1, trimmed.length - 1);
      }
    }
    return trimmed;
  }

  static Object? _parseTomlValue(String raw) {
    final v = raw.trim();
    if (v == 'true') return true;
    if (v == 'false') return false;
    if (int.tryParse(v) case final n?) return n;
    if (double.tryParse(v) case final d?) return d;
    if (v.length >= 2 &&
        ((v.startsWith('"') && v.endsWith('"')) ||
            (v.startsWith("'") && v.endsWith("'")))) {
      if (v.startsWith('"')) {
        try {
          final decoded = jsonDecode(v);
          if (decoded is String) return decoded;
        } on Object {
          // Fall through to simple unquoting.
        }
      }
      return v.substring(1, v.length - 1);
    }
    if (v.startsWith('[') && v.endsWith(']')) {
      final inner = v.substring(1, v.length - 1).trim();
      if (inner.isEmpty) return <Object?>[];
      return [
        for (final item in _splitTopLevel(inner, ','))
          if (item.trim().isNotEmpty) _parseTomlValue(item),
      ];
    }
    if (v.startsWith('{') && v.endsWith('}')) {
      final inner = v.substring(1, v.length - 1).trim();
      final map = <String, Object?>{};
      for (final entry in _splitTopLevel(inner, ',')) {
        final eq = _findUnquotedChar(entry, '=');
        if (eq <= 0) continue;
        final key = _unquoteTomlKey(entry.substring(0, eq));
        if (key.isEmpty) continue;
        map[key] = _parseTomlValue(entry.substring(eq + 1));
      }
      return map;
    }
    return v;
  }

  static List<String> _splitTopLevel(String s, String delimiter) {
    final parts = <String>[];
    final buf = StringBuffer();
    String? quote;
    var escaped = false;
    var sq = 0;
    var curly = 0;
    for (var i = 0; i < s.length; i++) {
      final ch = s[i];
      if (escaped) {
        buf.write(ch);
        escaped = false;
        continue;
      }
      if (quote == '"' && ch == r'\') {
        buf.write(ch);
        escaped = true;
        continue;
      }
      if (quote != null) {
        buf.write(ch);
        if (ch == quote) quote = null;
      } else {
        if (ch == '"' || ch == "'") {
          quote = ch;
          buf.write(ch);
        } else if (ch == '[') {
          sq++;
          buf.write(ch);
        } else if (ch == ']') {
          if (sq > 0) sq--;
          buf.write(ch);
        } else if (ch == '{') {
          curly++;
          buf.write(ch);
        } else if (ch == '}') {
          if (curly > 0) curly--;
          buf.write(ch);
        } else if (ch == delimiter && sq == 0 && curly == 0) {
          parts.add(buf.toString());
          buf.clear();
        } else {
          buf.write(ch);
        }
      }
    }
    if (buf.isNotEmpty) parts.add(buf.toString());
    return parts;
  }

  static String _describeServer(Object? server) {
    if (server is! Map<String, Object?>) return '';
    if (server['url'] case final String url) {
      return switch (server['type']) {
        final String type => '$type · $url',
        _ => url,
      };
    }
    return [
      if (server['command'] case final String command) command,
      if (server['args'] case final List<Object?> args)
        for (final arg in args) '$arg',
    ].join(' ');
  }

  List<(CustomizationScope, String)> _hooksFiles(
    String config,
    String? project,
  ) => [
    (CustomizationScope.user, _paths.join(config, 'hooks.json')),
    if (project != null) ...[
      (
        CustomizationScope.project,
        _paths.join(project, '.agents', 'hooks.json'),
      ),
      (
        CustomizationScope.local,
        _paths.join(project, '.agents', 'hooks.local.json'),
      ),
    ],
  ];

  List<(CustomizationScope, String)> _allHooksFiles(
    String config,
    String? home,
    String? project,
  ) {
    final files = <(CustomizationScope, String)>[];
    final seen = <String>{};
    void add(CustomizationScope scope, String path) {
      if (seen.add(_pathKey(path))) files.add((scope, path));
    }

    for (final root in _userRoots(config, home)) {
      final baseName = _paths.basename(_canon(root));
      if (baseName == '.claude' || baseName == '.codebuddy') {
        add(CustomizationScope.user, _paths.join(root, 'settings.json'));
      } else if (baseName != '.codex' && baseName != '.agents') {
        add(CustomizationScope.user, _paths.join(root, 'hooks.json'));
      }
    }
    if (project != null && project.isNotEmpty) {
      add(
        CustomizationScope.project,
        _paths.join(project, '.agents', 'hooks.json'),
      );
      add(
        CustomizationScope.local,
        _paths.join(project, '.agents', 'hooks.local.json'),
      );
      add(
        CustomizationScope.project,
        _paths.join(project, '.claude', 'settings.json'),
      );
      add(
        CustomizationScope.local,
        _paths.join(project, '.claude', 'settings.local.json'),
      );
      add(
        CustomizationScope.project,
        _paths.join(project, '.codebuddy', 'settings.json'),
      );
      add(
        CustomizationScope.local,
        _paths.join(project, '.codebuddy', 'settings.local.json'),
      );
    }
    return files;
  }

  Future<List<Customization>> _hooks(
    String config,
    String? home,
    String? project,
  ) async => [
    for (final (scope, path) in _allHooksFiles(config, home, project))
      if ((await _json(path))?['hooks'] case final Map<String, Object?> events)
        for (final MapEntry(key: event, value: groups) in events.entries)
          if (groups is List<Object?>)
            for (final group in groups.whereType<Map<String, Object?>>())
              for (final hook
                  in (group['hooks'] as List<Object?>? ?? const [])
                      .whereType<Map<String, Object?>>())
                Customization(
                  kind: CustomizationKind.hooks,
                  scope: scope,
                  name: switch (group['matcher']) {
                    final String matcher when matcher.isNotEmpty =>
                      '$event · $matcher',
                    _ => event,
                  },
                  description: switch (hook['command'] ?? hook['prompt']) {
                    final String command => command,
                    _ => '${hook['type'] ?? ''}',
                  },
                  path: path,
                ),
  ];

  /// Installed plugins across Antigravity/CodeBuddy (`plugins/*/plugin.json`)
  /// and Claude Code (`plugins/installed_plugins.json`).
  Future<List<Customization>> _plugins(
    String config,
    String? home,
    String? project,
  ) async {
    final result = <Customization>[];
    final seen = <String>{};
    for (final root in _userRoots(config, home)) {
      if (await _usesInstalledPluginsJson(root)) {
        final installedPath = _paths.join(
          root,
          'plugins',
          'installed_plugins.json',
        );
        for (final plugin in await _claudeInstalledPlugins(root)) {
          final path = plugin.manifestPath ?? installedPath;
          if (!seen.add('${_pathKey(path)}\u0000${plugin.pluginKey}')) {
            continue;
          }
          result.add(
            Customization(
              kind: CustomizationKind.plugins,
              scope: CustomizationScope.plugin,
              name: plugin.name,
              description: plugin.description,
              path: path,
              editable: false,
              detail: _pretty.convert({
                'plugin': plugin.pluginKey,
                'installPath': plugin.dir,
                'enabled': plugin.enabled,
              }),
              enabled: plugin.enabled,
            ),
          );
        }
      } else {
        final disabledPlugins = await _disabledPlugins(root);
        for (final pluginDir in await _subfolders(_paths.join(root, 'plugins'))) {
          final dirName = _paths.basename(pluginDir);
          final manifestPath = _paths.join(pluginDir, 'plugin.json');
          final manifest = await _json(manifestPath);
          if (manifest == null) continue;
          if (!seen.add(_pathKey(manifestPath))) continue;
          final name = switch (manifest['name']) {
            final String s when s.trim().isNotEmpty => s.trim(),
            _ => dirName,
          };
          final enabled =
              !disabledPlugins.contains(dirName) &&
              !disabledPlugins.contains(name);
          result.add(
            Customization(
              kind: CustomizationKind.plugins,
              scope: CustomizationScope.plugin,
              name: name,
              description: switch (manifest['description']) {
                final String description => description,
                _ => switch (manifest['version']) {
                  final String version => 'v$version',
                  _ => dirName,
                },
              },
              path: manifestPath,
              editable: false,
              detail: _pretty.convert({...manifest, 'enabled': enabled}),
              enabled: enabled,
            ),
          );
        }
      }
    }
    return result;
  }
}

/// Dashed directory name for [cwd] under `~/.ayte/projects/`.
String claudeProjectDirName(String cwd) {
  final dashed = cwd.replaceAll(RegExp('[^a-zA-Z0-9]'), '-');
  if (dashed.length <= 200) return dashed;
  var hash = 0;
  for (final unit in cwd.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return '${dashed.substring(0, 200)}-${hash.toRadixString(36)}';
}
