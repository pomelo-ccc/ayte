import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../customize/customizations.dart'
    show describeMarkdown, parseFrontMatter;

/// Built-in Antigravity CLI (`agy`) slash commands offered in the composer's
/// `/` menu before and after session initialization.
const List<Map<String, Object?>> antigravityBuiltinCommands = [
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
    'name': 'goal',
    'description': 'Run autonomously until the goal is fully achieved',
    'argumentHint': '<goal>',
    'builtin': true,
    'category': 'builtin',
  },
  {
    'name': 'teamwork',
    'description': 'Launch a team of autonomous agents working together',
    'argumentHint': '<task>',
    'builtin': true,
    'category': 'builtin',
  },
  {
    'name': 'swarm',
    'description': 'Start a multi-agent swarm with coordinator and workers',
    'argumentHint': '<task>',
    'builtin': true,
    'category': 'builtin',
  },
  {
    'name': 'boost',
    'description':
        'Deep thinking, strategic planning, and rigorous verification',
    'argumentHint': '<task>',
    'builtin': true,
    'category': 'builtin',
  },
  {
    'name': 'grill-me',
    'description':
        'Interactive interview to align on a plan and design decisions',
    'argumentHint': '[topic]',
    'builtin': true,
    'category': 'builtin',
  },
  {
    'name': 'schedule',
    'description': 'Run a recurring schedule or one-time timer',
    'argumentHint': '<instruction>',
    'builtin': true,
    'category': 'builtin',
  },
  {
    'name': 'browser',
    'description': 'Browse the web, search, or interact with web apps',
    'argumentHint': '<task>',
    'builtin': true,
    'category': 'builtin',
  },
  {
    'name': 'learn',
    'description': 'Persist a correction or setup into reusable instructions',
    'argumentHint': '[topic]',
    'builtin': true,
    'category': 'builtin',
  },
];

/// Discovers Antigravity (`agy`) slash commands, workflows, and skills for
/// [cwd] and [home], respecting disabled plugins in `~/.gemini/config/config.json`
/// and [disabledSkills].
///
/// Order & precedence:
/// 1. Built-in `agy` slash commands (`category: 'builtin'`)
/// 2. Project commands / workflows / skills under `.agents/` (and `.agent/`),
///    walking up from [cwd] to the Git repository root (`category: 'project'`)
/// 3. User global commands / workflows / skills under `~/.gemini/config/` and
///    `~/.gemini/antigravity/global_workflows/` (`category: 'user'`)
/// 4. Enabled installed plugin commands / workflows / skills under
///    `~/.gemini/config/plugins/` (`category: 'plugin'`)
Future<List<Map<String, Object?>>> discoverAntigravityCommands({
  required String cwd,
  required String home,
  Set<String> disabledSkills = const {},
}) async {
  final normalizedDisabled = <String>{
    for (final raw in disabledSkills)
      if (_cleanCommandName(raw) case final cleaned when cleaned.isNotEmpty)
        cleaned,
  };

  final seen = <String>{};
  final result = <Map<String, Object?>>[];

  void addIfNew(Map<String, Object?> entry) {
    final name = (entry['name'] as String? ?? '').trim();
    if (name.isEmpty) return;
    if (seen.add(name.toLowerCase())) {
      result.add(entry);
    }
  }

  for (final builtin in antigravityBuiltinCommands) {
    addIfNew(builtin);
  }

  // 1. Project-level (.agents / .agent from cwd up to git root).
  final projectEntries = <Map<String, Object?>>[];
  final projectSeen = <String>{};
  if (cwd.trim().isNotEmpty) {
    for (final dir in _projectRoots(cwd)) {
      for (final folder in const ['.agents', '.agent']) {
        final base = p.join(dir, folder);
        await _collectMarkdownCommands(
          p.join(base, 'commands'),
          category: 'project',
          into: projectEntries,
          seen: projectSeen,
        );
        await _collectMarkdownCommands(
          p.join(base, 'workflows'),
          category: 'project',
          into: projectEntries,
          seen: projectSeen,
        );
        await _collectSkills(
          p.join(base, 'skills'),
          category: 'project',
          disabledSkills: normalizedDisabled,
          into: projectEntries,
          seen: projectSeen,
        );
      }
    }
  }
  _sortByName(projectEntries);
  for (final entry in projectEntries) {
    addIfNew(entry);
  }

  if (home.trim().isEmpty) return result;
  final configDir = p.join(home, '.gemini', 'config');

  // 2. User global commands, global workflows & skills.
  final userEntries = <Map<String, Object?>>[];
  final userSeen = <String>{};
  await _collectMarkdownCommands(
    p.join(configDir, 'commands'),
    category: 'user',
    into: userEntries,
    seen: userSeen,
  );
  await _collectMarkdownCommands(
    p.join(home, '.gemini', 'antigravity', 'global_workflows'),
    category: 'user',
    into: userEntries,
    seen: userSeen,
  );
  await _collectSkills(
    p.join(configDir, 'skills'),
    category: 'user',
    disabledSkills: normalizedDisabled,
    into: userEntries,
    seen: userSeen,
  );
  _sortByName(userEntries);
  for (final entry in userEntries) {
    addIfNew(entry);
  }

  // 3. Installed & enabled plugins under ~/.gemini/config/plugins/<plugin>/.
  final disabledPlugins = await _readDisabledPlugins(
    p.join(configDir, 'config.json'),
  );
  final pluginEntries = <Map<String, Object?>>[];
  final pluginSeen = <String>{};
  for (final pluginDir in await _subfolders(p.join(configDir, 'plugins'))) {
    final dirName = p.basename(pluginDir);
    final manifestName = await _readPluginName(
      p.join(pluginDir, 'plugin.json'),
      fallback: dirName,
    );
    if (disabledPlugins.contains(dirName) ||
        disabledPlugins.contains(manifestName)) {
      continue;
    }
    await _collectMarkdownCommands(
      p.join(pluginDir, 'commands'),
      category: 'plugin',
      source: manifestName,
      into: pluginEntries,
      seen: pluginSeen,
    );
    await _collectMarkdownCommands(
      p.join(pluginDir, 'workflows'),
      category: 'plugin',
      source: manifestName,
      into: pluginEntries,
      seen: pluginSeen,
    );
    await _collectSkills(
      p.join(pluginDir, 'skills'),
      category: 'plugin',
      source: manifestName,
      pluginDirName: dirName,
      disabledSkills: normalizedDisabled,
      into: pluginEntries,
      seen: pluginSeen,
    );
  }
  _sortByName(pluginEntries);
  for (final entry in pluginEntries) {
    addIfNew(entry);
  }

  return result;
}

/// Walks from [cwd] up to the nearest Git repository root (capped so a folder
/// outside any repository only scans itself).
List<String> _projectRoots(String cwd) {
  final normalized = p.normalize(cwd);
  final roots = <String>[];
  var current = normalized;
  for (var depth = 0; depth < 12; depth++) {
    roots.add(current);
    final gitPath = p.join(current, '.git');
    if (Directory(gitPath).existsSync() || File(gitPath).existsSync()) {
      return roots;
    }
    final parent = p.dirname(current);
    if (parent == current) break;
    current = parent;
  }
  // Not inside a Git repository: only inspect cwd itself.
  return [normalized];
}

Future<Set<String>> _readDisabledPlugins(String configPath) async {
  final raw = await _readHead(configPath, maxBytes: 128 * 1024);
  if (raw == null) return const {};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return const {};
    final disabled = <String>{};
    if (decoded['disabledPlugins'] case final List list) {
      for (final item in list) {
        if (item is String && item.trim().isNotEmpty) {
          disabled.add(item.trim());
        }
      }
    }
    if (decoded['plugins'] case final Map plugins) {
      for (final MapEntry(:key, :value) in plugins.entries) {
        if (key is String && value is Map && value['enabled'] == false) {
          disabled.add(key.trim());
        }
      }
    }
    return disabled;
  } on Object {
    return const {};
  }
}

Future<String> _readPluginName(
  String manifestPath, {
  required String fallback,
}) async {
  final raw = await _readHead(manifestPath, maxBytes: 16 * 1024);
  if (raw == null) return fallback;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map && decoded['name'] is String) {
      final name = (decoded['name'] as String).trim();
      if (name.isNotEmpty) return name;
    }
  } on Object {
    // Ignore malformed plugin.json.
  }
  return fallback;
}

Future<void> _collectSkills(
  String root, {
  required String category,
  String? source,
  String? pluginDirName,
  required Set<String> disabledSkills,
  required List<Map<String, Object?>> into,
  required Set<String> seen,
}) async {
  for (final folder in await _subfolders(root)) {
    final folderName = p.basename(folder);
    final skillFile = p.join(folder, 'SKILL.md');
    final text = await _readHead(skillFile);
    if (text == null) continue;
    final frontMatter = parseFrontMatter(text);
    final rawName = frontMatter['name']?.trim() ?? '';
    final name = _cleanCommandName(rawName.isNotEmpty ? rawName : folderName);
    if (name.isEmpty) continue;
    if (_isDisabledSkill(
      name,
      folderName: folderName,
      source: source,
      pluginDirName: pluginDirName,
      disabledSkills: disabledSkills,
    )) {
      continue;
    }
    if (!seen.add(name.toLowerCase())) continue;
    final description = _cleanDescription(describeMarkdown(text));
    final argumentHint =
        (frontMatter['argument-hint'] ?? frontMatter['argumentHint'] ?? '')
            .trim();
    into.add({
      'name': name,
      'description': description,
      if (argumentHint.isNotEmpty) 'argumentHint': argumentHint,
      'builtin': false,
      'category': category,
      if (source != null && source.isNotEmpty) 'source': source,
    });
  }
}

Future<void> _collectMarkdownCommands(
  String root, {
  required String category,
  String? source,
  required List<Map<String, Object?>> into,
  required Set<String> seen,
}) async {
  const maxDepth = 4;

  Future<void> walk(String dir, int depth) async {
    final entries = await _listEntries(dir);
    for (final entry in entries) {
      if (entry.directory) {
        if (depth < maxDepth && !p.basename(entry.path).startsWith('.')) {
          await walk(entry.path, depth + 1);
        }
        continue;
      }
      if (!entry.path.toLowerCase().endsWith('.md')) continue;
      final base = p.basenameWithoutExtension(entry.path);
      if (base.isEmpty || base.startsWith('.')) continue;
      final text = await _readHead(entry.path);
      if (text == null) continue;
      final frontMatter = parseFrontMatter(text);
      final name = _cleanCommandName(base);
      if (name.isEmpty || !seen.add(name.toLowerCase())) continue;
      final description = _cleanDescription(describeMarkdown(text));
      final argumentHint =
          (frontMatter['argument-hint'] ?? frontMatter['argumentHint'] ?? '')
              .trim();
      into.add({
        'name': name,
        'description': description,
        if (argumentHint.isNotEmpty) 'argumentHint': argumentHint,
        'builtin': false,
        'category': category,
        if (source != null && source.isNotEmpty) 'source': source,
      });
    }
  }

  await walk(root, 0);
}

bool _isDisabledSkill(
  String name, {
  required String folderName,
  String? source,
  String? pluginDirName,
  required Set<String> disabledSkills,
}) {
  if (disabledSkills.isEmpty) return false;
  final cleanName = _cleanCommandName(name);
  final cleanFolder = _cleanCommandName(folderName);
  if (disabledSkills.contains(name) ||
      disabledSkills.contains(folderName) ||
      (cleanName.isNotEmpty && disabledSkills.contains(cleanName)) ||
      (cleanFolder.isNotEmpty && disabledSkills.contains(cleanFolder))) {
    return true;
  }
  for (final rawPlugin in [?source, ?pluginDirName]) {
    final plugin = _cleanCommandName(rawPlugin);
    if (plugin.isEmpty) continue;
    if ((cleanName.isNotEmpty && disabledSkills.contains('$plugin:$cleanName')) ||
        (cleanFolder.isNotEmpty &&
            disabledSkills.contains('$plugin:$cleanFolder'))) {
      return true;
    }
  }
  return false;
}

String _cleanCommandName(String raw) {
  var name = raw.trim();
  while (name.startsWith('/')) {
    name = name.substring(1).trim();
  }
  return name;
}

String _cleanDescription(String raw) {
  var text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  text = text.replaceAll('**', '');
  if (text.length > 220) {
    text = '${text.substring(0, 217).trimRight()}...';
  }
  return text;
}

void _sortByName(List<Map<String, Object?>> entries) {
  entries.sort((a, b) {
    final an = '${a['name'] ?? ''}'.toLowerCase();
    final bn = '${b['name'] ?? ''}'.toLowerCase();
    return an.compareTo(bn);
  });
}

Future<List<String>> _subfolders(String dir) async => [
  for (final entry in await _listEntries(dir))
    if (entry.directory && !p.basename(entry.path).startsWith('.')) entry.path,
];

Future<List<({String path, bool directory})>> _listEntries(String dir) async {
  try {
    final directory = Directory(dir);
    if (!await directory.exists()) return const [];
    final entries = <({String path, bool directory})>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is Directory) {
        entries.add((path: entity.path, directory: true));
      } else if (entity is File) {
        entries.add((path: entity.path, directory: false));
      } else if (entity is Link) {
        final type = await FileSystemEntity.type(entity.path);
        if (type == FileSystemEntityType.directory) {
          entries.add((path: entity.path, directory: true));
        } else if (type == FileSystemEntityType.file) {
          entries.add((path: entity.path, directory: false));
        }
      }
    }
    return entries;
  } on Object {
    return const [];
  }
}

/// Reads up to [maxBytes] from [path] so frontmatter extraction stays fast
/// even across 100+ skill markdown files.
Future<String?> _readHead(String path, {int maxBytes = 8192}) async {
  RandomAccessFile? raf;
  try {
    final file = File(path);
    if (!await file.exists()) return null;
    raf = await file.open();
    final bytes = await raf.read(maxBytes);
    return utf8.decode(bytes, allowMalformed: true);
  } on Object {
    return null;
  } finally {
    try {
      await raf?.close();
    } on Object {
      // Ignore close error.
    }
  }
}
