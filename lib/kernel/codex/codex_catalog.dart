import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import '../agent_kernel.dart';
import '../agent_message_parser.dart';

/// A single turn parsed from a local Codex `rollout-*.jsonl` transcript.
class CodexHistoryTurn {
  const CodexHistoryTurn({
    required this.items,
    this.model,
    this.effort,
  });

  /// Normalized v2-compatible item maps (`userMessage`, `reasoning`,
  /// `agentMessage`, `commandExecution`, `fileChange`, `mcpToolCall`,
  /// `contextCompaction`).
  final List<Map<String, Object?>> items;
  final String? model;
  final String? effort;
}

/// Paginated slice of a Codex rollout file returned by [CodexCatalog.readRolloutPage].
class CodexHistoryPage {
  const CodexHistoryPage({
    required this.turns,
    this.earlierBeforeTurn,
    this.model,
    this.effort,
  });

  final List<CodexHistoryTurn> turns;
  final int? earlierBeforeTurn;
  final String? model;
  final String? effort;
}

/// Codex CLI's local session record under `~/.codex/` (`sessions/**/rollout-*.jsonl`
/// and `session_index.jsonl`).
class CodexCatalog implements SessionCatalog {
  const CodexCatalog({this.codexHome, @visibleForTesting this.environment});

  /// Optional override for `~/.codex` (falls back to `CODEX_HOME`, then
  /// `<HOME|USERPROFILE>/.codex`).
  final String? codexHome;

  @visibleForTesting
  final Map<String, String>? environment;

  static final _idPattern = RegExp(r'^[0-9a-zA-Z][0-9a-zA-Z_-]*$');
  static final _scanning = <String, Future<List<ProjectRecord>>>{};
  static final _scanNext = <String, Future<List<ProjectRecord>>>{};

  static String? _nonEmptyEnv(String? value) =>
      (value != null && value.trim().isNotEmpty) ? value.trim() : null;

  static String? _lookupEnvVar(
    Map<String, String> env,
    String name, {
    required bool win,
  }) {
    final direct = _nonEmptyEnv(env[name]);
    if (direct != null) return direct;
    if (win) {
      final lower = name.toLowerCase();
      for (final entry in env.entries) {
        if (entry.key.toLowerCase() == lower) {
          final value = _nonEmptyEnv(entry.value);
          if (value != null) return value;
        }
      }
      for (final entry in env.entries) {
        if (entry.key.toLowerCase() == lower) {
          return '';
        }
      }
    } else if (env.containsKey(name)) {
      return _nonEmptyEnv(env[name]) ?? '';
    }
    return null;
  }

  static String resolveHomeFromEnv(
    Map<String, String> env, {
    String? codexHome,
    bool? forceWindows,
  }) {
    if (_nonEmptyEnv(codexHome) case final explicit?) return explicit;
    final win = forceWindows ?? Platform.isWindows;
    final envCodex = _lookupEnvVar(env, 'CODEX_HOME', win: win);
    if (envCodex != null && envCodex.isNotEmpty) return envCodex;
    final join = win ? p.windows.join : p.posix.join;
    final home = _lookupEnvVar(env, 'HOME', win: win);
    if (home != null && home.isNotEmpty) {
      return join(home, '.codex');
    }
    final userProfile = _lookupEnvVar(env, 'USERPROFILE', win: win);
    if (userProfile != null && userProfile.isNotEmpty) {
      return join(userProfile, '.codex');
    }
    return '';
  }

  String resolveHome() => resolveHomeFromEnv(
    environment ?? Platform.environment,
    codexHome: codexHome,
  );

  /// Strips Windows extended-length prefixes (`\\?\` and `\\?\UNC\`) and
  /// normalizes directory separators/trailing slashes.
  static String normalizeWindowsPath(String rawPath) {
    var path = rawPath.trim();
    if (path.isEmpty) return '';
    final lower = path.toLowerCase();
    if (lower.startsWith(r'\\?\unc\') || lower.startsWith('//?/unc/')) {
      path = r'\\' + path.substring(8);
    } else if (path.startsWith(r'\\?\') || path.startsWith('//?/')) {
      path = path.substring(4);
    }
    if (RegExp(r'^[A-Za-z]:[/\\]').hasMatch(path)) {
      path = path.replaceAll('/', r'\');
      path = p.windows.normalize(path);
      if (path.length > 3 && path.endsWith(r'\')) {
        path = path.substring(0, path.length - 1);
      }
      return path;
    }
    if (path.startsWith(r'\\') || path.startsWith('//')) {
      path = p.windows.normalize(path.replaceAll('/', r'\'));
      final uncParts = path
          .substring(2)
          .split(r'\')
          .where((s) => s.isNotEmpty)
          .toList();
      if (uncParts.length >= 2 && path.endsWith(r'\')) {
        path = path.substring(0, path.length - 1);
      }
      return path;
    }
    return p.normalize(path);
  }

  static void _checkId(String id) {
    if (!_idPattern.hasMatch(id)) {
      throw ArgumentError.value(id, 'id', 'not a valid Codex session id');
    }
  }

  @override
  Future<List<ProjectRecord>> projects() async {
    final home = resolveHome();
    if (home.isEmpty) return const [];
    Future<List<ProjectRecord>> scan() =>
        _scanning[home] = Isolate.run(() => _scan(home)).whenComplete(() {
          _scanning.remove(home);
        });
    final running = _scanning[home];
    if (running == null) return scan();
    return _scanNext[home] ??= running.then<void>((_) {}, onError: (_) {}).then((
      _,
    ) {
      _scanNext.remove(home);
      return scan();
    });
  }

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async {
    final target = normalizeWindowsPath(cwd);
    if (target.isEmpty) return const [];
    final targetKey = Platform.isWindows ? target.toLowerCase() : target;
    final all = await projects();
    for (final project in all) {
      final key = Platform.isWindows
          ? project.path.toLowerCase()
          : project.path;
      if (key == targetKey) return project.sessions;
    }
    return const [];
  }

  @override
  Future<void> delete(String id) async {
    _checkId(id);
    final home = resolveHome();
    if (home.isEmpty) return;
    await Isolate.run(() => _delete(home, id));
  }

  /// Persists or updates a custom thread title in `<codexHome>/session_index.jsonl`.
  Future<void> noteSessionTitle(
    String id,
    String title, {
    DateTime? updatedAt,
  }) async {
    _checkId(id);
    final trimmed = title.trim();
    if (trimmed.isEmpty) return;
    final home = resolveHome();
    if (home.isEmpty) return;
    final when = (updatedAt ?? DateTime.now()).toUtc().toIso8601String();
    await Isolate.run(() {
      final indexFile = File(p.join(home, 'session_index.jsonl'));
      indexFile.parent.createSync(recursive: true);
      final line = jsonEncode({
        'id': id,
        'thread_name': trimmed,
        'updated_at': when,
      });
      indexFile.writeAsStringSync(
        '$line\n',
        mode: FileMode.append,
        flush: true,
      );
    });
  }

  /// Reads all turns from a local rollout `.jsonl` file.
  static Future<List<CodexHistoryTurn>> readRollout(String path) async {
    final page = await readRolloutPage(path, turns: 1000000);
    return page.turns;
  }

  /// Reads up to [turns] turns from a local rollout `.jsonl` file, ending
  /// before turn index [beforeTurn] when paginating backwards.
  static Future<CodexHistoryPage> readRolloutPage(
    String path, {
    required int turns,
    int? beforeTurn,
  }) => Isolate.run(() => _readRolloutPageSync(path, turns, beforeTurn));

  static List<ProjectRecord> _scan(String home) {
    final sessionsDir = Directory(p.join(home, 'sessions'));
    if (!sessionsDir.existsSync()) return const [];

    final index = _readIndex(p.join(home, 'session_index.jsonl'));
    final byProject = <String, ({String path, List<SessionRecord> sessions})>{};

    final entities = <File>[];
    try {
      for (final entity in sessionsDir.listSync(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File && entity.path.toLowerCase().endsWith('.jsonl')) {
          final name = p.basename(entity.path);
          if (name.startsWith('rollout-') || name.endsWith('.jsonl')) {
            entities.add(entity);
          }
        }
      }
    } on Object {
      return const [];
    }

    for (final file in entities) {
      final parsed = _parseSessionSummary(file, index);
      if (parsed == null) continue;
      final key = Platform.isWindows
          ? parsed.cwd.toLowerCase()
          : parsed.cwd;
      final bucket = byProject.putIfAbsent(
        key,
        () => (path: parsed.cwd, sessions: []),
      );
      bucket.sessions.add(parsed);
    }

    final projects = <ProjectRecord>[];
    for (final bucket in byProject.values) {
      bucket.sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      projects.add(ProjectRecord(path: bucket.path, sessions: bucket.sessions));
    }
    projects.sort((a, b) {
      final ua = a.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final ub = b.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return ub.compareTo(ua);
    });
    return projects;
  }

  static Map<String, ({String title, DateTime? updatedAt})> _readIndex(
    String indexPath,
  ) {
    final out = <String, ({String title, DateTime? updatedAt})>{};
    final file = File(indexPath);
    if (!file.existsSync()) return out;
    try {
      for (final line in file.readAsLinesSync()) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        try {
          final decoded = jsonDecode(trimmed);
          if (decoded is! Map) continue;
          final id = decoded['id'] as String?;
          if (id == null || id.isEmpty) continue;
          final title = (decoded['thread_name'] ?? decoded['title'] ?? '')
              .toString()
              .trim();
          final ts = DateTime.tryParse('${decoded['updated_at'] ?? ''}');
          final prev = out[id];
          final shouldReplaceTitle =
              title.isNotEmpty &&
              (prev == null ||
                  prev.title.isEmpty ||
                  prev.updatedAt == null ||
                  (ts != null && !ts.isBefore(prev.updatedAt!)));
          out[id] = (
            title: shouldReplaceTitle ? title : (prev?.title ?? ''),
            updatedAt: _laterDate(prev?.updatedAt, ts),
          );
        } on Object {
          // Ignore malformed index lines.
        }
      }
    } on Object {
      // Ignore unreadable index file.
    }
    return out;
  }

  static SessionRecord? _parseSessionSummary(
    File file,
    Map<String, ({String title, DateTime? updatedAt})> index,
  ) {
    List<String> lines;
    DateTime mtime;
    try {
      lines = file.readAsLinesSync();
      mtime = file.statSync().modified;
    } on Object {
      return null;
    }

    String? id;
    String? cwd;
    String? firstUserTitle;
    DateTime? latestTs;

    for (final raw in lines) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) continue;
      final Map<String, Object?> entry;
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is! Map) continue;
        entry = decoded.cast<String, Object?>();
      } on Object {
        continue;
      }

      if (entry['timestamp'] case final String tsStr) {
        latestTs = _laterDate(latestTs, DateTime.tryParse(tsStr));
      }

      final type = entry['type'] as String?;
      final payload = (entry['payload'] as Map?)?.cast<String, Object?>();
      switch (type) {
        case 'session_meta':
          if (payload != null) {
            if (payload['id'] case final String pid when pid.isNotEmpty) {
              id ??= pid;
            }
            if (payload['cwd'] case final String pcwd when pcwd.isNotEmpty) {
              cwd ??= normalizeWindowsPath(pcwd);
            }
            if (payload['timestamp'] case final String pts) {
              latestTs = _laterDate(latestTs, DateTime.tryParse(pts));
            }
          }
        case 'turn_context':
          if (cwd == null && payload != null) {
            if (payload['cwd'] case final String pcwd when pcwd.isNotEmpty) {
              cwd = normalizeWindowsPath(pcwd);
            }
          }
        case 'event_msg':
          if (firstUserTitle == null &&
              payload != null &&
              payload['type'] == 'user_message') {
            final msg = '${payload['message'] ?? ''}'.trim();
            firstUserTitle = _cleanTitle(msg);
          }
        case 'response_item':
          if (firstUserTitle == null &&
              payload != null &&
              payload['type'] == 'message' &&
              payload['role'] == 'user') {
            final text = _extractMessageText(payload['content']);
            firstUserTitle = _cleanTitle(text);
          }
        case 'userMessage':
          firstUserTitle ??= _cleanTitle(
            _extractMessageText(entry['content']),
          );
      }
    }

    id ??= _idFromFilename(p.basename(file.path));
    if (id == null || id.isEmpty || cwd == null || cwd.isEmpty) {
      return null;
    }

    final indexed = index[id];
    final title = (indexed != null && indexed.title.isNotEmpty)
        ? indexed.title
        : (firstUserTitle ?? '');
    final updatedAt =
        _laterDate(latestTs, indexed?.updatedAt) ?? mtime;

    return SessionRecord(
      id: id,
      title: title,
      updatedAt: updatedAt,
      cwd: cwd,
      path: file.path,
    );
  }

  static String? _idFromFilename(String basename) {
    var stem = basename;
    if (stem.endsWith('.jsonl.zst')) {
      stem = stem.substring(0, stem.length - '.jsonl.zst'.length);
    } else if (stem.endsWith('.jsonl')) {
      stem = stem.substring(0, stem.length - '.jsonl'.length);
    }
    if (stem.startsWith('rollout-')) {
      final uuidMatch = RegExp(
        r'([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$',
      ).firstMatch(stem);
      if (uuidMatch != null) return uuidMatch.group(1)!;
      final tsMatch = RegExp(
        r'^rollout-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}(?:\.\d+)?Z?-(.+)$',
      ).firstMatch(stem);
      if (tsMatch != null) return tsMatch.group(1)!;
    }
    return stem.isEmpty ? null : stem;
  }

  static String? _cleanTitle(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final parsed = parseAgentMessage(trimmed);
    final text = (parsed?.text ?? trimmed).trim();
    if (text.isEmpty || _isBoilerplateUserText(text)) return null;
    for (final line in text.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      return t.length <= 120 ? t : '${t.substring(0, 119).trimRight()}…';
    }
    return null;
  }

  static bool _isBoilerplateUserText(String text) {
    final trimmed = text.trimLeft();
    const prefixes = [
      '<environment_context>',
      '<user_instructions>',
      '<permissions instructions>',
      '<AGENTS.md',
      '# AGENTS.md instructions',
      '<collaboration_mode>',
      '<skills_instructions>',
      '<system-reminder>',
    ];
    for (final prefix in prefixes) {
      if (trimmed.startsWith(prefix)) return true;
    }
    return false;
  }

  static String _extractMessageText(Object? content) {
    if (content is String) return content;
    if (content is! List) return '';
    final buf = StringBuffer();
    for (final block in content) {
      if (block is! Map) continue;
      final type = block['type'];
      if (type == 'input_text' || type == 'output_text' || type == 'text') {
        final text = block['text'];
        if (text is String && text.isNotEmpty) {
          if (buf.isNotEmpty) buf.write('\n');
          buf.write(text);
        }
      }
    }
    return buf.toString();
  }

  static DateTime? _laterDate(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }

  static void _delete(String home, String id) {
    final sessionsDir = Directory(p.join(home, 'sessions'));
    if (sessionsDir.existsSync()) {
      try {
        for (final entity in sessionsDir.listSync(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is! File) continue;
          final name = p.basename(entity.path);
          final lowerName = name.toLowerCase();
          if (!lowerName.endsWith('.jsonl') &&
              !lowerName.endsWith('.jsonl.zst')) {
            continue;
          }
          var matches = _idFromFilename(name) == id;
          if (!matches && lowerName.endsWith('.jsonl')) {
            matches = _fileHasSessionId(entity, id);
          }
          if (matches) {
            try {
              entity.deleteSync();
            } on Object {
              // Best effort.
            }
          }
        }
      } on Object {
        // Ignore inaccessible directories.
      }
    }

    final indexFile = File(p.join(home, 'session_index.jsonl'));
    if (indexFile.existsSync()) {
      try {
        final kept = <String>[];
        var changed = false;
        for (final line in indexFile.readAsLinesSync()) {
          final trimmed = line.trim();
          if (trimmed.isEmpty) continue;
          try {
            final decoded = jsonDecode(trimmed);
            if (decoded is Map && decoded['id'] == id) {
              changed = true;
              continue;
            }
          } on Object {
            // Keep unparseable lines intact.
          }
          kept.add(trimmed);
        }
        if (changed) {
          indexFile.writeAsStringSync(
            kept.isEmpty ? '' : '${kept.join('\n')}\n',
            flush: true,
          );
        }
      } on Object {
        // Ignore index write failure.
      }
    }
  }

  static bool _fileHasSessionId(File file, String id) {
    try {
      // Read sync first few bytes to check session_meta without loading huge file.
      final raf = file.openSync();
      try {
        final bytes = raf.readSync(8192);
        final head = utf8.decode(bytes, allowMalformed: true);
        for (final line in const LineSplitter().convert(head)) {
          if (line.trim().isEmpty) continue;
          try {
            final decoded = jsonDecode(line);
            if (decoded is Map && decoded['type'] == 'session_meta') {
              final payload = decoded['payload'];
              if (payload is Map && payload['id'] == id) return true;
              return false;
            }
          } on Object {
            continue;
          }
        }
      } finally {
        raf.closeSync();
      }
    } on Object {
      // Ignore.
    }
    return false;
  }

  static CodexHistoryPage _readRolloutPageSync(
    String path,
    int turnsRequested,
    int? beforeTurn,
  ) {
    final file = File(path);
    if (!file.existsSync()) {
      return const CodexHistoryPage(turns: []);
    }

    final List<String> lines;
    try {
      lines = file.readAsLinesSync();
    } on Object {
      return const CodexHistoryPage(turns: []);
    }

    final parsedTurns = <CodexHistoryTurn>[];
    var currentItems = <Map<String, Object?>>[];
    final itemIndexById = <String, int>{};
    String? lastUserText;
    String? lastAssistantText;
    String? currentModel;
    String? currentEffort;
    String? latestModel;
    String? latestEffort;
    var itemSeq = 0;

    void flushTurn() {
      if (currentItems.isEmpty) return;
      parsedTurns.add(
        CodexHistoryTurn(
          items: currentItems,
          model: currentModel,
          effort: currentEffort,
        ),
      );
      currentItems = [];
      itemIndexById.clear();
      lastUserText = null;
      lastAssistantText = null;
    }

    void addItem(Map<String, Object?> item) {
      final id = item['id'] as String? ?? 'hist-${++itemSeq}';
      final normalized = {...item, 'id': id};
      final existingIdx = itemIndexById[id];
      if (existingIdx != null) {
        currentItems[existingIdx] = normalized;
      } else {
        itemIndexById[id] = currentItems.length;
        currentItems.add(normalized);
      }
    }

    void addUser(String text, {String? id}) {
      final trimmed = text.trim();
      if (trimmed.isEmpty || _isBoilerplateUserText(trimmed)) return;
      if (lastUserText == trimmed && currentItems.isNotEmpty) return;
      if (currentItems.isNotEmpty) {
        flushTurn();
      }
      lastUserText = trimmed;
      lastAssistantText = null;
      addItem({
        'type': 'userMessage',
        'id': id ?? 'hist-u-${++itemSeq}',
        'content': [
          {'type': 'text', 'text': text},
        ],
      });
    }

    void addAssistant(String text, {String? id}) {
      if (text.trim().isEmpty) return;
      if (lastAssistantText == text) return;
      lastAssistantText = text;
      addItem({
        'type': 'agentMessage',
        'id': id ?? 'hist-a-${++itemSeq}',
        'text': text,
      });
    }

    for (final raw in lines) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) continue;
      final Map<String, Object?> entry;
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is! Map) continue;
        entry = decoded.cast<String, Object?>();
      } on Object {
        continue;
      }

      final type = entry['type'] as String?;
      final payload = (entry['payload'] as Map?)?.cast<String, Object?>();

      switch (type) {
        case 'turn_context':
          if (payload != null) {
            if (payload['model'] case final String m when m.isNotEmpty) {
              currentModel = m;
              latestModel = m;
            }
            if (payload['effort'] case final String e when e.isNotEmpty) {
              currentEffort = e;
              latestEffort = e;
            }
          }
        case 'event_msg':
          if (payload == null) continue;
          switch (payload['type']) {
            case 'user_message':
              addUser('${payload['message'] ?? ''}');
            case 'agent_message':
              addAssistant('${payload['message'] ?? ''}');
            case 'agent_reasoning':
              final text = '${payload['text'] ?? ''}'.trim();
              if (text.isNotEmpty) {
                addItem({
                  'type': 'reasoning',
                  'id': 'hist-r-${++itemSeq}',
                  'summary': [text],
                });
              }
            case 'context_compacted':
              addItem({
                'type': 'contextCompaction',
                'id': 'hist-c-${++itemSeq}',
              });
          }
        case 'response_item':
          if (payload == null) continue;
          switch (payload['type']) {
            case 'message':
              final role = payload['role'] as String?;
              final text = _extractMessageText(payload['content']);
              if (role == 'user') {
                addUser(text);
              } else if (role == 'assistant') {
                addAssistant(text);
              }
            case 'reasoning':
              final summary = <String>[];
              if (payload['summary'] case final List rawSum) {
                for (final part in rawSum) {
                  if (part is Map && part['text'] is String) {
                    summary.add(part['text'] as String);
                  } else if (part is String) {
                    summary.add(part);
                  }
                }
              }
              if (summary.isEmpty && payload['content'] is List) {
                for (final part in payload['content'] as List) {
                  if (part is Map && part['text'] is String) {
                    summary.add(part['text'] as String);
                  }
                }
              }
              if (summary.isNotEmpty) {
                addItem({
                  'type': 'reasoning',
                  'id': payload['id'] as String? ?? 'hist-r-${++itemSeq}',
                  'summary': summary,
                });
              }
            case 'local_shell_call':
              final callId =
                  payload['call_id'] as String? ?? 'hist-cmd-${++itemSeq}';
              final action = payload['action'];
              final command = action is Map
                  ? (action['command'] is List
                        ? (action['command'] as List).join(' ')
                        : '${action['command'] ?? ''}')
                  : '${payload['command'] ?? ''}';
              addItem({
                'type': 'commandExecution',
                'id': callId,
                'command': command,
                'status': 'completed',
                'exitCode': 0,
                'aggregatedOutput': '',
              });
            case 'local_shell_call_output':
              final callId = payload['call_id'] as String?;
              if (callId != null && itemIndexById.containsKey(callId)) {
                final existing = currentItems[itemIndexById[callId]!];
                addItem({
                  ...existing,
                  'aggregatedOutput': '${payload['output'] ?? ''}',
                });
              }
            case 'function_call':
            case 'custom_tool_call':
              final callId =
                  payload['call_id'] as String? ?? 'hist-fn-${++itemSeq}';
              final name = '${payload['name'] ?? ''}';
              final rawArgs = payload['arguments'] ?? payload['input'];
              Map<String, Object?> args = const {};
              if (rawArgs is Map) {
                args = rawArgs.cast<String, Object?>();
              } else if (rawArgs is String && rawArgs.isNotEmpty) {
                try {
                  final decoded = jsonDecode(rawArgs);
                  if (decoded is Map) args = decoded.cast<String, Object?>();
                } on Object {
                  args = {'input': rawArgs};
                }
              }
              if (name == 'shell' ||
                  name == 'shell_command' ||
                  name == 'exec_command') {
                final cmd = args['command'] is List
                    ? (args['command'] as List).join(' ')
                    : '${args['command'] ?? args['cmd'] ?? ''}';
                addItem({
                  'type': 'commandExecution',
                  'id': callId,
                  'command': cmd,
                  'status': 'completed',
                  'exitCode': 0,
                  'aggregatedOutput': '',
                });
              } else if (name.isNotEmpty) {
                addItem({
                  'type': 'mcpToolCall',
                  'id': callId,
                  'server': payload['server'] ?? '',
                  'tool': name,
                  'arguments': args,
                  'status': 'completed',
                });
              }
            case 'function_call_output':
            case 'custom_tool_call_output':
              final callId = payload['call_id'] as String?;
              if (callId != null && itemIndexById.containsKey(callId)) {
                final existing = currentItems[itemIndexById[callId]!];
                final out = '${payload['output'] ?? ''}';
                if (existing['type'] == 'commandExecution') {
                  addItem({...existing, 'aggregatedOutput': out});
                } else {
                  addItem({
                    ...existing,
                    'result': {
                      'content': [
                        {'type': 'text', 'text': out},
                      ],
                    },
                  });
                }
              }
            case 'mcp_call':
              final callId =
                  payload['call_id'] as String? ?? 'hist-mcp-${++itemSeq}';
              addItem({
                'type': 'mcpToolCall',
                'id': callId,
                'server': payload['server'] ?? '',
                'tool': payload['tool'] ?? payload['name'] ?? '',
                'arguments': payload['arguments'] is Map
                    ? payload['arguments']
                    : const <String, Object?>{},
                'status': payload['error'] != null ? 'failed' : 'completed',
                if (payload['result'] != null) 'result': payload['result'],
                if (payload['error'] != null) 'error': payload['error'],
              });
          }
        case 'userMessage':
          addUser(
            _extractMessageText(entry['content']),
            id: entry['id'] as String?,
          );
        case 'agentMessage':
          addAssistant(
            '${entry['text'] ?? ''}',
            id: entry['id'] as String?,
          );
        case 'reasoning':
        case 'commandExecution':
        case 'fileChange':
        case 'mcpToolCall':
        case 'contextCompaction':
          addItem(entry);
      }
    }
    flushTurn();

    final end = (beforeTurn ?? parsedTurns.length).clamp(0, parsedTurns.length);
    final start = (end - turnsRequested).clamp(0, end);
    return CodexHistoryPage(
      turns: parsedTurns.sublist(start, end),
      earlierBeforeTurn: start > 0 ? start : null,
      model: latestModel,
      effort: latestEffort,
    );
  }
}
