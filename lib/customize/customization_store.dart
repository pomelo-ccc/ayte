import 'dart:convert';

import 'package:bao_remote/files.dart'
    show IdeFileExistsException, IdeFileNotFoundException;
import 'package:path/path.dart' as p;

import 'customization_disk.dart';
import 'customizations.dart';

/// Antigravity (`agy`) customizations on a [CustomizationDisk]:
/// - User global customizations under `~/.gemini/config` (`skills/`,
///   `plugins/`, `AGENTS.md`, `GEMINI.md`, `rules/`, `mcp_config.json`,
///   `hooks.json`, `agents/`, `commands/`).
/// - Workspace project customizations under `<project>/.agents` (and
///   `<project>/GEMINI.md`, `<project>/AGENTS.md`).
class CustomizationStore {
  CustomizationStore({this.configDir, this.homeDir, CustomizationDisk? disk})
    : _disk = disk ?? CustomizationDisk.local;

  /// Antigravity's global config folder (`~/.gemini/config` by default).
  final String? configDir;

  /// The user's home directory.
  final String? homeDir;

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

  /// Those of [kind], the user's and [project]'s (none of a project's when
  /// null), by scope then name.
  Future<List<Customization>> list(
    CustomizationKind kind, {
    String? project,
  }) async {
    if (!supported) return const [];
    final config = await this.config();
    final dotAgents = project == null ? null : _paths.join(project, '.agents');
    final items = switch (kind) {
      CustomizationKind.skills => [
        ...await _skills(
          CustomizationScope.user,
          _paths.join(config, 'skills'),
        ),
        ...await _pluginSkills(config),
        if (dotAgents != null)
          ...await _skills(
            CustomizationScope.project,
            _paths.join(dotAgents, 'skills'),
          ),
      ],
      CustomizationKind.subagents => [
        ...await _markdown(
          kind,
          CustomizationScope.user,
          _paths.join(config, 'agents'),
        ),
        if (dotAgents != null)
          ...await _markdown(
            kind,
            CustomizationScope.project,
            _paths.join(dotAgents, 'agents'),
          ),
      ],
      CustomizationKind.commands => [
        ...await _markdown(
          kind,
          CustomizationScope.user,
          _paths.join(config, 'commands'),
        ),
        if (dotAgents != null)
          ...await _markdown(
            kind,
            CustomizationScope.project,
            _paths.join(dotAgents, 'commands'),
          ),
      ],
      CustomizationKind.rules => await _rules(config, project),
      CustomizationKind.memory => await _memories(project),
      CustomizationKind.mcps => await _servers(config, project),
      CustomizationKind.hooks => await _hooks(config, project),
      CustomizationKind.plugins => await _plugins(config, project),
    };
    return [...items]..sort((a, b) {
      final scope = a.scope.index.compareTo(b.scope.index);
      return scope != 0
          ? scope
          : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  }

  /// The file of the `/command` [name]: a skill's SKILL.md or a command's
  /// markdown, the user's, [project]'s or a plugin's (`plugin:name`); null
  /// for none (one built in).
  Future<String?> commandFile(String name, {String? project}) async {
    if (!supported) return null;
    final colon = name.indexOf(':');
    if (colon > 0) {
      return _pluginCommandFile(
        name.substring(0, colon),
        name.substring(colon + 1),
      );
    }
    for (final skill in await list(
      CustomizationKind.skills,
      project: project,
    )) {
      if (skill.name == name ||
          _paths.basename(_paths.dirname(skill.path)) == name) {
        return skill.path;
      }
    }
    for (final command in await list(
      CustomizationKind.commands,
      project: project,
    )) {
      if (command.name == '/$name') return command.path;
    }
    return null;
  }

  Future<String?> _pluginCommandFile(String plugin, String name) async {
    final config = await this.config();
    final root = _paths.join(config, 'plugins', plugin);
    for (final path in [
      _paths.join(root, 'skills', name, 'SKILL.md'),
      _paths.join(root, 'commands', '$name.md'),
    ]) {
      if (await _files.read(path) != null) return path;
    }
    return null;
  }

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
    final base = scope == CustomizationScope.user
        ? await config()
        : _paths.join(project!, '.agents');
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
  /// `mcp_config.json` for MCPs, `hooks.json` for hooks.
  Future<String?> configFile(
    CustomizationKind kind,
    CustomizationScope scope, {
    String? project,
  }) async {
    if (!kind.configuredIn(scope) || !supported) return null;
    final config = await this.config();
    if (kind == CustomizationKind.mcps) {
      return switch (scope) {
        CustomizationScope.user => _paths.join(config, 'mcp_config.json'),
        CustomizationScope.project when project != null => _paths.join(
          project,
          '.agents',
          'mcp_config.json',
        ),
        _ => null,
      };
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

  /// Skills bundled inside installed Antigravity plugins
  /// (`~/.gemini/config/plugins/<plugin>/skills/<skill>/SKILL.md`).
  Future<List<Customization>> _pluginSkills(String config) async {
    final skills = <Customization>[];
    for (final pluginDir in await _subfolders(_paths.join(config, 'plugins'))) {
      for (final folder in await _subfolders(_paths.join(pluginDir, 'skills'))) {
        skills.addAll([?await _skill(CustomizationScope.plugin, folder)]);
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

  /// Rules Antigravity reads: `GEMINI.md`, `AGENTS.md`, `rules/*.md` globally
  /// (`~/.gemini/config`), inside plugins, and in the workspace (`.agents/rules`).
  Future<List<Customization>> _rules(String config, String? project) async {
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

    final pluginRules = <Customization>[];
    for (final pluginDir in await _subfolders(_paths.join(config, 'plugins'))) {
      pluginRules.addAll(
        await folder(
          CustomizationScope.plugin,
          _paths.join(pluginDir, 'rules'),
          _paths.join(config, 'plugins'),
          editable: false,
        ),
      );
    }

    return [
      ?await ruleFile(
        CustomizationScope.user,
        _paths.join(config, 'GEMINI.md'),
        config,
      ),
      ?await ruleFile(
        CustomizationScope.user,
        _paths.join(config, 'AGENTS.md'),
        config,
      ),
      ...await folder(
        CustomizationScope.user,
        _paths.join(config, 'rules'),
        config,
      ),
      ...pluginRules,
      if (project != null) ...[
        ?await ruleFile(
          CustomizationScope.project,
          _paths.join(project, 'GEMINI.md'),
          project,
        ),
        ?await ruleFile(
          CustomizationScope.project,
          _paths.join(project, 'AGENTS.md'),
          project,
        ),
        ...await folder(
          CustomizationScope.project,
          _paths.join(project, '.agents', 'rules'),
          project,
        ),
      ],
    ];
  }

  /// Project memory files stored under `~/.ayte/projects/<project>/memory/`.
  Future<List<Customization>> _memories(String? project) async {
    if (project == null) return const [];
    final home = await _home();
    if (home == null || home.isEmpty) return const [];
    final folder = _paths.join(
      home,
      '.ayte',
      'projects',
      claudeProjectDirName(project),
      'memory',
    );
    return [
      for (final child in await _files.children(folder))
        if (!child.directory && child.path.endsWith('.md'))
          if (await _files.read(child.path) case final text?)
            Customization(
              kind: CustomizationKind.memory,
              scope: CustomizationScope.project,
              name: _paths.basename(child.path),
              description: describeMarkdown(text),
              path: child.path,
              removePath: child.path,
            ),
    ];
  }

  /// MCP servers configured in `~/.gemini/config/mcp_config.json`, inside
  /// Antigravity plugins, or in `<project>/.agents/mcp_config.json` (and `.mcp.json`).
  Future<List<Customization>> _servers(String config, String? project) async {
    List<Customization> servers(
      CustomizationScope scope,
      Object? entries,
      String path, {
      required bool editable,
    }) => [
      if (entries is Map<String, Object?>)
        for (final MapEntry(key: name, value: server) in entries.entries)
          Customization(
            kind: CustomizationKind.mcps,
            scope: scope,
            name: name,
            description: _describeServer(server),
            path: path,
            editable: editable,
            detail: _pretty.convert({name: server}),
            server: server is Map<String, Object?> ? server : null,
            enabled: server is Map<String, Object?> && server['disabled'] == true
                ? false
                : null,
          ),
    ];

    final userMcp = _paths.join(config, 'mcp_config.json');
    final pluginMcps = <Customization>[];
    for (final pluginDir in await _subfolders(_paths.join(config, 'plugins'))) {
      for (final candidate in [
        _paths.join(pluginDir, 'mcp_config.json'),
        _paths.join(pluginDir, 'mcp.json'),
      ]) {
        final json = await _json(candidate);
        if (json != null) {
          pluginMcps.addAll(
            servers(
              CustomizationScope.plugin,
              json['mcpServers'] ?? json,
              candidate,
              editable: false,
            ),
          );
        }
      }
    }

    final projectFiles = [
      if (project != null) _paths.join(project, '.agents', 'mcp_config.json'),
      if (project != null) _paths.join(project, '.mcp.json'),
    ];
    final projectMcps = <Customization>[];
    for (final file in projectFiles) {
      final json = await _json(file);
      if (json != null) {
        projectMcps.addAll(
          servers(
            CustomizationScope.project,
            json['mcpServers'],
            file,
            editable: true,
          ),
        );
      }
    }

    return [
      ...servers(
        CustomizationScope.user,
        (await _json(userMcp))?['mcpServers'],
        userMcp,
        editable: true,
      ),
      ...pluginMcps,
      ...projectMcps,
    ];
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

  Future<List<Customization>> _hooks(String config, String? project) async => [
    for (final (scope, path) in _hooksFiles(config, project))
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

  /// Installed Antigravity plugins under `~/.gemini/config/plugins/<name>/plugin.json`.
  Future<List<Customization>> _plugins(String config, String? project) async {
    final globalConfig = await _json(_paths.join(config, 'config.json'));
    final disabledPlugins = <String>{
      if (globalConfig?['disabledPlugins'] case final List<Object?> list)
        ...list.whereType<String>(),
    };
    final result = <Customization>[];
    for (final pluginDir in await _subfolders(_paths.join(config, 'plugins'))) {
      final dirName = _paths.basename(pluginDir);
      final manifestPath = _paths.join(pluginDir, 'plugin.json');
      final manifest = await _json(manifestPath);
      if (manifest == null) continue;
      final name = switch (manifest['name']) {
        final String s when s.trim().isNotEmpty => s.trim(),
        _ => dirName,
      };
      final enabled = !disabledPlugins.contains(dirName) &&
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
