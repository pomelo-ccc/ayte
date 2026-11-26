import 'dart:convert';
import 'dart:io';

import 'package:bao_agent/bao_agent.dart' show AgentPaths;
import 'package:bao_remote/claude.dart' show ClaudeHistoryPage;
import 'package:path/path.dart' as p;

import '../../remote/remote_claude.dart';
import '../../remote/remote_location.dart';
import '../agent_kernel.dart';
import '../antigravity/antigravity_catalog.dart';
import '../claude_code/claude_storage_io.dart' show ClaudeStorage;
import 'codebuddy_cli.dart';

/// CodeBuddy CLI (`codebuddy` / `cbc`) session catalog:
/// - Discovers native CodeBuddy `.jsonl` transcripts stored under
///   `~/.codebuddy/projects/<encoded-cwd>/<sessionId>.jsonl` (and top-level
///   `~/.codebuddy/projects/<sessionId>.jsonl`).
/// - Claims legacy `codebuddy-cli`-authored `.jsonl` sessions from [claude]
///   without claiming `claude-code` or `antigravity-cli` sessions.
/// - Translates CodeBuddy's native transcript schema (`type: "message"`,
///   `"reasoning"`, `"function_call"`, `"function_call_result"`) into standard
///   Claude Code transcript entries when reopening a session.
class CodeBuddyCatalog implements SessionCatalog, MovesSessions {
  const CodeBuddyCatalog({
    this.claude = const ClaudeCatalog(),
    this.homeDir,
    this.paths,
  });

  final ClaudeCatalog claude;
  final String? homeDir;
  final AgentPaths? paths;

  static final RegExp _validIdPattern = RegExp(r'^[0-9a-zA-Z][0-9a-zA-Z_-]*$');
  static const int _maxSummaryHeadBytes = 128 * 1024;
  static const int _maxSummaryTailBytes = 32 * 1024;
  static const int _maxFullSummaryBytes = 256 * 1024;
  static const int _maxTitleChars = 120;
  static const int _maxTimestampMillis = 253402300799000;

  static final RegExp _userRequestRegex = RegExp(
    r'<USER_REQUEST>\s*([\s\S]*?)\s*</USER_REQUEST>',
  );
  static final RegExp _ignoredTagsRegex = RegExp(
    r'<(system-reminder|local-command-caveat|CONVERSATION_CONTEXT)>[\s\S]*?</\1>',
    caseSensitive: false,
  );

  String get _resolvedHome => resolveHomeDir(homeDir: homeDir, paths: paths);

  static String resolveHomeDir({String? homeDir, AgentPaths? paths}) {
    if (homeDir != null && homeDir.isNotEmpty) return homeDir;
    if (paths != null && paths.home.isNotEmpty) return paths.home;
    return AgentPaths.from(Platform.environment).home;
  }

  static String projectsRoot({String? homeDir, AgentPaths? paths}) =>
      p.join(resolveHomeDir(homeDir: homeDir, paths: paths), '.codebuddy', 'projects');

  ClaudeCatalog get _effectiveClaude {
    if (paths != null &&
        claude.local.configDir == null &&
        claude.local.cacheFile == null) {
      return ClaudeCatalog(local: ClaudeStorage(configDir: paths!.configDir));
    }
    return claude;
  }

  static bool isValidSessionId(String id) => _validIdPattern.hasMatch(id);

  /// Finds the native CodeBuddy `.jsonl` file for [sessionId] under
  /// `~/.codebuddy/projects/`, or `null` if not found.
  static File? findNativeSessionFile(
    String sessionId, {
    String? homeDir,
    AgentPaths? paths,
  }) {
    if (!isValidSessionId(sessionId)) return null;
    final root = Directory(projectsRoot(homeDir: homeDir, paths: paths));
    if (!root.existsSync()) return null;
    final targetName = '$sessionId.jsonl';
    final direct = File(p.join(root.path, targetName));
    if (direct.existsSync()) return direct;
    List<FileSystemEntity> entries;
    try {
      entries = root.listSync(followLinks: false);
    } on Object {
      return null;
    }
    for (final entity in entries) {
      if (entity is! Directory) continue;
      final candidate = File(p.join(entity.path, targetName));
      if (candidate.existsSync()) return candidate;
    }
    return null;
  }

  /// Whether [path] points to a native CodeBuddy transcript file rather than a
  /// Claude Code `.jsonl` transcript.
  static bool isNativeCodeBuddyJsonl(String path) {
    if (path.isEmpty) return false;
    final normalized = path.replaceAll('\\', '/');
    if (normalized.contains('/.codebuddy/projects/')) return true;
    RandomAccessFile? raf;
    try {
      final file = File(path);
      if (!file.existsSync()) return false;
      raf = file.openSync();
      final bytes = raf.readSync(32 * 1024);
      if (bytes.isEmpty) return false;
      final text = utf8.decode(bytes, allowMalformed: true);
      var inspected = 0;
      for (final rawLine in const LineSplitter().convert(text)) {
        final line = rawLine.trim();
        if (line.isEmpty) continue;
        inspected++;
        if (inspected > 20) break;
        final decoded = _tryDecodeMap(line);
        if (decoded == null) continue;
        final type = decoded['type'];
        if (type == 'message' ||
            type == 'session-meta' ||
            type == 'reasoning' ||
            type == 'function_call' ||
            type == 'function_call_result' ||
            decoded.containsKey('__codebuddyLocal')) {
          return true;
        }
        if (type == 'user' || type == 'assistant') {
          return false;
        }
      }
      return false;
    } on Object {
      return false;
    } finally {
      try {
        raf?.closeSync();
      } on Object {
        // Ignore close errors.
      }
    }
  }

  @override
  Future<List<ProjectRecord>> projects() async {
    final byId = <String, SessionRecord>{};

    // 1. Discover native CodeBuddy sessions under `~/.codebuddy/projects/`.
    final nativeIds = <String>{};
    for (final file in _listNativeSessionFiles(_resolvedHome)) {
      final id = p.basenameWithoutExtension(file.path);
      if (!isValidSessionId(id)) continue;
      final summary = _parseNativeSummary(file);
      if (!summary.hasConversation && summary.customTitle == null) continue;
      final cwd = summary.cwd != null ? _normalizePath(summary.cwd!) : '';
      if (cwd.isEmpty || !_safeDirExists(cwd)) continue;
      final title = summary.customTitle ?? summary.firstUserTitle ?? '';
      if (title.isEmpty && !summary.hasConversation) continue;
      final updatedAt = summary.updatedAt ?? _safeModified(file);
      nativeIds.add(id);
      final existing = byId[id];
      if (existing == null || updatedAt.isAfter(existing.updatedAt)) {
        byId[id] = SessionRecord(
          id: id,
          title: title,
          updatedAt: updatedAt,
          cwd: cwd,
          path: file.path,
        );
      }
    }

    // 2. Merge legacy CodeBuddy-authored sessions stored in ClaudeCatalog.
    final claudeProjects = await _effectiveClaude.projects();
    for (final project in claudeProjects) {
      for (final session in project.sessions) {
        final isCb =
            nativeIds.contains(session.id) ||
            (session.path != null &&
                AntigravityCatalog.inferJsonlKernelId(session.path!) ==
                    codebuddyBuiltinProviderId);
        if (!isCb) continue;
        final existing = byId[session.id];
        if (existing == null) {
          byId[session.id] = SessionRecord(
            id: session.id,
            title: session.title,
            updatedAt: session.updatedAt,
            cwd: _normalizePath(session.cwd),
            path: session.path,
          );
        } else {
          // Keep the native CodeBuddy file as primary path while preserving any
          // custom title or newer timestamp from the legacy record.
          final mergedTitle = existing.title.isNotEmpty
              ? existing.title
              : session.title;
          final mergedUpdatedAt = session.updatedAt.isAfter(existing.updatedAt)
              ? session.updatedAt
              : existing.updatedAt;
          byId[session.id] = SessionRecord(
            id: existing.id,
            title: mergedTitle,
            updatedAt: mergedUpdatedAt,
            cwd: existing.cwd.isNotEmpty
                ? existing.cwd
                : _normalizePath(session.cwd),
            path: existing.path ?? session.path,
          );
        }
      }
    }

    final grouped = <String, List<SessionRecord>>{};
    final displayCwd = <String, String>{};
    for (final session in byId.values) {
      final normCwd = _normalizePath(session.cwd);
      final key = _cwdKey(normCwd);
      displayCwd.putIfAbsent(key, () => normCwd);
      final canonicalCwd = displayCwd[key]!;
      final normalized = session.cwd == canonicalCwd
          ? session
          : SessionRecord(
              id: session.id,
              title: session.title,
              updatedAt: session.updatedAt,
              cwd: canonicalCwd,
              path: session.path,
            );
      (grouped[key] ??= []).add(normalized);
    }

    final projects = <ProjectRecord>[];
    for (final entry in grouped.entries) {
      final sessions = entry.value
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      projects.add(
        ProjectRecord(path: displayCwd[entry.key]!, sessions: sessions),
      );
    }
    projects.sort((a, b) {
      final aAt = a.sessions.isEmpty
          ? DateTime.fromMillisecondsSinceEpoch(0)
          : a.sessions.first.updatedAt;
      final bAt = b.sessions.isEmpty
          ? DateTime.fromMillisecondsSinceEpoch(0)
          : b.sessions.first.updatedAt;
      return bAt.compareTo(aAt);
    });
    return projects;
  }

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async {
    final targetKey = _cwdKey(_normalizePath(cwd));
    final all = await projects();
    return all
            .where((proj) => _cwdKey(_normalizePath(proj.path)) == targetKey)
            .firstOrNull
            ?.sessions ??
        const [];
  }

  @override
  Future<void> delete(String id) async {
    try {
      await _effectiveClaude.delete(id);
    } on Object {
      // Best-effort cleanup of any legacy Claude-side record.
    }
    if (!isValidSessionId(id)) return;
    final nativeFile = findNativeSessionFile(
      id,
      homeDir: homeDir,
      paths: paths,
    );
    if (nativeFile != null) {
      try {
        if (nativeFile.existsSync()) nativeFile.deleteSync();
      } on Object {
        // Ignore delete failures.
      }
      final siblingDir = Directory(
        p.join(nativeFile.parent.path, id),
      );
      try {
        if (siblingDir.existsSync()) siblingDir.deleteSync(recursive: true);
      } on Object {
        // Ignore sibling directory cleanup failures.
      }
    }
  }

  @override
  Future<int> moveSessions(String from, String to) async {
    if (RemoteLocation.isRemote(from) || RemoteLocation.isRemote(to)) {
      throw UnsupportedError('Sessions are only moved on this machine');
    }
    final normFrom = _normalizePath(from);
    final normTo = _normalizePath(to);
    if (normFrom.isEmpty ||
        normTo.isEmpty ||
        _cwdKey(normFrom) == _cwdKey(normTo)) {
      return 0;
    }
    var moved = await _effectiveClaude.moveSessions(normFrom, normTo);
    final fromKey = _cwdKey(normFrom);
    final root = projectsRoot(homeDir: homeDir, paths: paths);
    final destDir = Directory(p.join(root, encodeProjectDirName(normTo)));
    for (final file in _listNativeSessionFiles(_resolvedHome)) {
      final summary = _parseNativeSummary(file);
      if (summary.cwd == null) continue;
      if (_cwdKey(_normalizePath(summary.cwd!)) != fromKey) continue;
      try {
        if (!destDir.existsSync()) destDir.createSync(recursive: true);
        final destFile = File(p.join(destDir.path, p.basename(file.path)));
        if (destFile.path != file.path) {
          file.renameSync(destFile.path);
          moved++;
        }
      } on Object {
        // Best-effort move.
      }
    }
    return moved;
  }

  /// CodeBuddy CLI encodes `/Users/foo/bar` as `Users-foo-bar` under
  /// `~/.codebuddy/projects/`.
  static String encodeProjectDirName(String cwd) {
    final normalized = _normalizePath(cwd);
    final stripped = normalized.replaceFirst(RegExp(r'^[/\\]+'), '');
    return stripped.replaceAll(RegExp(r'[/\\:]'), '-');
  }

  /// Reads a native CodeBuddy `.jsonl` file and translates it into standard
  /// Claude Code transcript entries consumable by `ClaudeCodeKernel`.
  static Future<List<Map<String, Object?>>> readNative(String path) async {
    final file = File(path);
    if (!file.existsSync()) return const [];
    final String text;
    try {
      final bytes = await file.readAsBytes();
      text = const Utf8Decoder(allowMalformed: true).convert(bytes);
    } on Object {
      return const [];
    }
    final rawEntries = <Map<String, Object?>>[];
    for (final rawLine in const LineSplitter().convert(text)) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final decoded = _tryDecodeMap(line);
      if (decoded != null) rawEntries.add(decoded);
    }
    return translateNativeEntries(rawEntries);
  }

  /// Paginated view over [readNative] matching [ClaudeSessions.readPage].
  static Future<ClaudeHistoryPage> readNativePage(
    String path, {
    required int turns,
    String? before,
  }) async {
    final entries = await readNative(path);
    if (entries.isEmpty) return const ClaudeHistoryPage([]);
    return sliceHistoryPage(entries, turns: turns, before: before);
  }

  /// Slices translated transcript [entries] to the last [turns] user prompts
  /// before [before] (matching `ClaudeSessions.readPage` semantics).
  static ClaudeHistoryPage sliceHistoryPage(
    List<Map<String, Object?>> entries, {
    required int turns,
    String? before,
  }) {
    if (entries.isEmpty) return const ClaudeHistoryPage([]);
    var end = entries.length;
    if (before != null && before.isNotEmpty) {
      final idx = entries.indexWhere((e) => e['uuid'] == before);
      if (idx >= 0) end = idx;
    }
    if (end <= 0) return const ClaudeHistoryPage([]);
    if (turns <= 0) {
      return ClaudeHistoryPage(entries.sublist(0, end));
    }

    var start = 0;
    var userTurns = 0;
    for (var i = end - 1; i >= 0; i--) {
      if (_isUserPromptEntry(entries[i])) {
        userTurns++;
        if (userTurns >= turns) {
          start = i;
          break;
        }
      }
    }
    final page = entries.sublist(start, end);
    final earlier = start > 0 ? page.first['uuid'] as String? : null;
    return ClaudeHistoryPage(page, earlier: earlier);
  }

  static bool _isUserPromptEntry(Map<String, Object?> entry) {
    if (entry['type'] != 'user') return false;
    final msg = entry['message'];
    if (msg is! Map) return false;
    final content = msg['content'];
    if (content is String) return content.trim().isNotEmpty;
    if (content is List) {
      return content.any((b) => b is Map && b['type'] != 'tool_result');
    }
    return false;
  }

  /// Translates raw CodeBuddy `.jsonl` entries into Claude Code transcript
  /// entries (`user`, `assistant`, `custom-title`, etc.).
  static List<Map<String, Object?>> translateNativeEntries(
    List<Map<String, Object?>> rawEntries,
  ) {
    final out = <Map<String, Object?>>[];
    var seq = 0;

    String nextUuid(Object? rawId, String prefix) {
      seq++;
      if (rawId is String && rawId.trim().isNotEmpty) return rawId.trim();
      return 'cb-$prefix-$seq';
    }

    for (final entry in rawEntries) {
      final type = entry['type'] as String? ?? '';
      final timestamp = _formatIsoTimestamp(entry['timestamp']);
      final providerData = (entry['providerData'] as Map?)
          ?.cast<String, Object?>();
      final model = _extractModel(entry, providerData);
      final msgId = (providerData?['messageId'] as String?)?.trim();

      switch (type) {
        case 'user' || 'assistant' || 'system' || 'custom-title':
          out.add(entry);

        case 'message':
          final role = entry['role'] as String? ?? '';
          if (role == 'user') {
            final blocks = _translateUserContent(entry['content']);
            if (blocks.isEmpty) continue;
            final contentValue =
                blocks.length == 1 && blocks.first['type'] == 'text'
                ? blocks.first['text']
                : blocks;
            out.add({
              'type': 'user',
              'uuid': nextUuid(entry['id'], 'u'),
              'timestamp': ?timestamp,
              'message': {
                'role': 'user',
                'content': contentValue,
              },
            });
          } else if (role == 'assistant') {
            final blocks = _translateAssistantContent(entry['content']);
            if (blocks.isEmpty) continue;
            final uuid = nextUuid(entry['id'], 'a');
            out.add({
              'type': 'assistant',
              'uuid': uuid,
              'timestamp': ?timestamp,
              'message': {
                'id': (msgId != null && msgId.isNotEmpty) ? msgId : uuid,
                'role': 'assistant',
                'model': ?model,
                'content': blocks,
              },
            });
          }

        case 'reasoning':
          final thinking = _extractReasoningText(entry, providerData);
          if (thinking.isEmpty) continue;
          final uuid = nextUuid(entry['id'], 'r');
          out.add({
            'type': 'assistant',
            'uuid': uuid,
            'timestamp': ?timestamp,
            'message': {
              'id': (msgId != null && msgId.isNotEmpty) ? msgId : uuid,
              'role': 'assistant',
              'model': ?model,
              'content': [
                {'type': 'thinking', 'thinking': thinking},
              ],
            },
          });

        case 'function_call':
          final name = (entry['name'] as String?)?.trim() ?? '';
          if (name.isEmpty) continue;
          final uuid = nextUuid(entry['id'], 'fc');
          final callId =
              (entry['callId'] as String?)?.trim().isNotEmpty == true
              ? (entry['callId'] as String).trim()
              : uuid;
          final input = _parseToolArguments(entry['arguments']);
          out.add({
            'type': 'assistant',
            'uuid': uuid,
            'timestamp': ?timestamp,
            'message': {
              'id': (msgId != null && msgId.isNotEmpty) ? msgId : uuid,
              'role': 'assistant',
              'model': ?model,
              'content': [
                {
                  'type': 'tool_use',
                  'id': callId,
                  'name': name,
                  'input': input,
                },
              ],
            },
          });

        case 'function_call_result':
          final uuid = nextUuid(entry['id'], 'fr');
          final callId =
              (entry['callId'] as String?)?.trim().isNotEmpty == true
              ? (entry['callId'] as String).trim()
              : uuid;
          final outputText = _extractToolOutput(entry['output']);
          final status = (entry['status'] as String?)?.trim().toLowerCase();
          final isError =
              entry['isError'] == true ||
              entry['is_error'] == true ||
              status == 'error' ||
              status == 'failed';
          out.add({
            'type': 'user',
            'uuid': uuid,
            'timestamp': ?timestamp,
            'message': {
              'role': 'user',
              'content': [
                {
                  'type': 'tool_result',
                  'tool_use_id': callId,
                  'content': outputText,
                  if (isError) 'is_error': true,
                },
              ],
            },
          });
      }
    }
    return out;
  }

  static List<Map<String, Object?>> _translateUserContent(Object? raw) {
    if (raw is String) {
      final cleaned = _stripSystemTags(raw).trim();
      if (cleaned.isEmpty) return const [];
      return [
        {'type': 'text', 'text': cleaned},
      ];
    }
    if (raw is! List) return const [];
    final blocks = <Map<String, Object?>>[];
    for (final item in raw) {
      if (item is String) {
        final cleaned = _stripSystemTags(item).trim();
        if (cleaned.isNotEmpty) {
          blocks.add({'type': 'text', 'text': cleaned});
        }
        continue;
      }
      if (item is! Map) continue;
      final type = item['type'] as String? ?? '';
      if (type == 'input_text' || type == 'text') {
        final text = item['text'];
        if (text is String) {
          final cleaned = _stripSystemTags(text).trim();
          if (cleaned.isNotEmpty) {
            blocks.add({'type': 'text', 'text': cleaned});
          }
        }
      } else if (type == 'image') {
        blocks.add(item.cast<String, Object?>());
      } else if (type == 'input_image') {
        final url = item['image_url'] ?? item['url'];
        if (url is String && url.startsWith('data:')) {
          final comma = url.indexOf(',');
          if (comma > 5) {
            final header = url.substring(5, comma);
            final mediaType = header.split(';').first;
            final data = url.substring(comma + 1);
            blocks.add({
              'type': 'image',
              'source': {
                'type': 'base64',
                'media_type': mediaType.isNotEmpty ? mediaType : 'image/png',
                'data': data,
              },
            });
          }
        }
      }
    }
    return blocks;
  }

  static List<Map<String, Object?>> _translateAssistantContent(Object? raw) {
    if (raw is String) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) return const [];
      return [
        {'type': 'text', 'text': trimmed},
      ];
    }
    if (raw is! List) return const [];
    final blocks = <Map<String, Object?>>[];
    for (final item in raw) {
      if (item is String && item.trim().isNotEmpty) {
        blocks.add({'type': 'text', 'text': item});
        continue;
      }
      if (item is! Map) continue;
      final type = item['type'] as String? ?? '';
      if (type == 'output_text' || type == 'text') {
        final text = item['text'];
        if (text is String && text.isNotEmpty) {
          blocks.add({'type': 'text', 'text': text});
        }
      } else if (type == 'thinking' || type == 'reasoning_text') {
        final text = item['thinking'] ?? item['text'];
        if (text is String && text.trim().isNotEmpty) {
          blocks.add({'type': 'thinking', 'thinking': text});
        }
      }
    }
    return blocks;
  }

  static String _extractReasoningText(
    Map<String, Object?> entry,
    Map<String, Object?>? providerData,
  ) {
    final parts = <String>[];
    for (final key in const ['rawContent', 'content']) {
      final raw = entry[key];
      if (raw is String && raw.trim().isNotEmpty) {
        parts.add(raw.trim());
      } else if (raw is List) {
        for (final item in raw) {
          if (item is String && item.trim().isNotEmpty) {
            parts.add(item.trim());
          } else if (item is Map) {
            final t = item['text'] ?? item['thinking'];
            if (t is String && t.trim().isNotEmpty) {
              parts.add(t.trim());
            }
          }
        }
      }
      if (parts.isNotEmpty) break;
    }
    if (parts.isEmpty) {
      final fallback = providerData?['reasoning'];
      if (fallback is String && fallback.trim().isNotEmpty) {
        parts.add(fallback.trim());
      }
    }
    return parts.join('\n').trim();
  }

  static Map<String, Object?> _parseToolArguments(Object? rawArgs) {
    if (rawArgs is Map) {
      return rawArgs.cast<String, Object?>();
    }
    if (rawArgs is String) {
      final trimmed = rawArgs.trim();
      if (trimmed.isEmpty) return const {};
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map) return decoded.cast<String, Object?>();
      } on Object {
        // Fall through to raw wrapper.
      }
      return {'raw': trimmed};
    }
    return const {};
  }

  static String _extractToolOutput(Object? output) {
    if (output == null) return '';
    if (output is String) return output;
    if (output is Map) {
      final text = output['text'];
      if (text is String) return text;
      final content = output['content'];
      if (content is String) return content;
      return jsonEncode(output);
    }
    if (output is List) {
      final parts = <String>[];
      for (final item in output) {
        if (item is String) {
          parts.add(item);
        } else if (item is Map && item['text'] is String) {
          parts.add(item['text'] as String);
        }
      }
      return parts.isNotEmpty ? parts.join('\n') : jsonEncode(output);
    }
    return '$output';
  }

  static String? _extractModel(
    Map<String, Object?> entry,
    Map<String, Object?>? providerData,
  ) {
    for (final candidate in [
      providerData?['model'],
      providerData?['requestModelId'],
      entry['model'],
    ]) {
      if (candidate is String) {
        final trimmed = candidate.trim();
        if (trimmed.isNotEmpty && trimmed != '<synthetic>') return trimmed;
      }
    }
    return null;
  }

  static List<File> _listNativeSessionFiles(String home) {
    final root = Directory(p.join(home, '.codebuddy', 'projects'));
    if (!root.existsSync()) return const [];
    final files = <File>[];
    List<FileSystemEntity> topEntries;
    try {
      topEntries = root.listSync(followLinks: false);
    } on Object {
      return const [];
    }
    for (final entity in topEntries) {
      if (entity is File) {
        if (entity.path.endsWith('.jsonl') && _nonEmptyFile(entity)) {
          files.add(entity);
        }
        continue;
      }
      if (entity is! Directory) continue;
      List<FileSystemEntity> children;
      try {
        children = entity.listSync(followLinks: false);
      } on Object {
        continue;
      }
      for (final child in children) {
        if (child is File &&
            child.path.endsWith('.jsonl') &&
            _nonEmptyFile(child)) {
          files.add(child);
        }
      }
    }
    return files;
  }

  static bool _nonEmptyFile(File file) {
    try {
      return file.lengthSync() > 0;
    } on Object {
      return false;
    }
  }

  static ({
    String? cwd,
    String? customTitle,
    String? firstUserTitle,
    DateTime? updatedAt,
    bool hasConversation,
  })
  _parseNativeSummary(File file) {
    String? cwd;
    String? customTitle;
    String? firstUserTitle;
    DateTime? updatedAt;
    var hasConversation = false;

    void inspectLine(String rawLine, {required bool lookForUser}) {
      final line = rawLine.trim();
      if (line.isEmpty) return;
      final decoded = _tryDecodeMap(line);
      if (decoded == null) return;

      if (cwd == null) {
        final rawCwd =
            decoded['cwd'] ??
            (decoded['snapshot'] is Map
                ? (decoded['snapshot'] as Map)['cwd']
                : null);
        if (rawCwd is String && rawCwd.trim().isNotEmpty) {
          cwd = rawCwd.trim();
        }
      }

      final ts = _parseTimestamp(decoded['timestamp']);
      if (ts != null && (updatedAt == null || ts.isAfter(updatedAt!))) {
        updatedAt = ts;
      }

      final type = decoded['type'] as String? ?? '';
      if (type == 'custom-title') {
        final cleaned = _cleanTitle(decoded['customTitle'] as String?);
        if (cleaned != null) customTitle = cleaned;
      } else if (type == 'ai-title') {
        final cleaned = _cleanTitle(
          (decoded['aiTitle'] ?? decoded['title']) as String?,
        );
        if (cleaned != null) customTitle ??= cleaned;
      } else if (type == 'message') {
        hasConversation = true;
        if (lookForUser && firstUserTitle == null && decoded['role'] == 'user') {
          firstUserTitle = _extractUserTitle(decoded['content']);
        }
      } else if (type == 'user') {
        hasConversation = true;
        if (lookForUser && firstUserTitle == null) {
          final msg = decoded['message'];
          if (msg is Map) {
            firstUserTitle = _extractUserTitle(msg['content']);
          }
        }
      } else if (type == 'assistant' ||
          type == 'reasoning' ||
          type == 'function_call') {
        hasConversation = true;
      }
    }

    RandomAccessFile? raf;
    try {
      final length = file.lengthSync();
      if (length <= 0) {
        return (
          cwd: null,
          customTitle: null,
          firstUserTitle: null,
          updatedAt: null,
          hasConversation: false,
        );
      }
      raf = file.openSync();
      if (length <= _maxFullSummaryBytes) {
        final text = utf8.decode(raf.readSync(length), allowMalformed: true);
        for (final line in const LineSplitter().convert(text)) {
          inspectLine(line, lookForUser: true);
        }
      } else {
        final headText = utf8.decode(
          raf.readSync(_maxSummaryHeadBytes),
          allowMalformed: true,
        );
        final headLines = const LineSplitter().convert(headText);
        // Drop potentially truncated last line of the head slice.
        final headCount = headLines.length > 1
            ? headLines.length - 1
            : headLines.length;
        for (var i = 0; i < headCount; i++) {
          inspectLine(headLines[i], lookForUser: true);
        }
        final tailOffset = length - _maxSummaryTailBytes;
        raf.setPositionSync(tailOffset);
        final tailText = utf8.decode(
          raf.readSync(_maxSummaryTailBytes),
          allowMalformed: true,
        );
        final tailLines = const LineSplitter().convert(tailText);
        // Drop potentially truncated first line of the tail slice.
        for (var i = tailLines.length > 1 ? 1 : 0; i < tailLines.length; i++) {
          inspectLine(tailLines[i], lookForUser: false);
        }
      }
    } on Object {
      // Ignore unreadable files.
    } finally {
      try {
        raf?.closeSync();
      } on Object {
        // Ignore close errors.
      }
    }

    final modified = _safeModified(file);
    if (updatedAt == null || modified.isAfter(updatedAt!)) {
      updatedAt = modified;
    }

    return (
      cwd: cwd,
      customTitle: customTitle,
      firstUserTitle: firstUserTitle,
      updatedAt: updatedAt,
      hasConversation: hasConversation,
    );
  }

  static String? _extractUserTitle(Object? content) {
    final texts = <String>[];
    if (content is String) {
      texts.add(content);
    } else if (content is List) {
      for (final block in content) {
        if (block is String) {
          texts.add(block);
        } else if (block is Map) {
          final type = block['type'] as String? ?? '';
          if (type == 'tool_result') continue;
          final text = block['text'];
          if (text is String) texts.add(text);
        }
      }
    }
    for (final raw in texts) {
      var text = _stripSystemTags(raw);
      final match = _userRequestRegex.firstMatch(text);
      if (match != null) {
        text = match.group(1)!;
      }
      for (final line in const LineSplitter().convert(text)) {
        final trimmed = line.trim();
        if (trimmed.isEmpty ||
            trimmed == '<USER_REQUEST>' ||
            trimmed == '</USER_REQUEST>') {
          continue;
        }
        final collapsed = trimmed.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (collapsed.isNotEmpty) return _truncateTitle(collapsed);
      }
    }
    return null;
  }

  static String _stripSystemTags(String raw) =>
      raw.replaceAll(_ignoredTagsRegex, '');

  static String? _cleanTitle(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed.startsWith('<')) return null;
    final singleLine = trimmed.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (singleLine.isEmpty) return null;
    return _truncateTitle(singleLine);
  }

  static String _truncateTitle(String text) {
    if (text.length <= _maxTitleChars) return text;
    var cut = _maxTitleChars;
    final prev = text.codeUnitAt(cut - 1);
    if (prev >= 0xD800 && prev <= 0xDBFF) cut--;
    return '${text.substring(0, cut)}…';
  }

  static Map<String, Object?>? _tryDecodeMap(String line) {
    try {
      final parsed = jsonDecode(line);
      if (parsed is Map) return parsed.cast<String, Object?>();
    } on Object {
      // Ignore malformed line.
    }
    return null;
  }

  static DateTime? _parseTimestamp(Object? raw) {
    if (raw is num) {
      final ms = raw.toInt();
      if (ms > 0 && ms <= _maxTimestampMillis) {
        return DateTime.fromMillisecondsSinceEpoch(ms);
      }
      return null;
    }
    if (raw is String && raw.trim().isNotEmpty) {
      return DateTime.tryParse(raw.trim());
    }
    return null;
  }

  static String? _formatIsoTimestamp(Object? raw) {
    if (raw is String && raw.trim().isNotEmpty) return raw.trim();
    final dt = _parseTimestamp(raw);
    return dt?.toUtc().toIso8601String();
  }

  static DateTime _safeModified(File file) {
    try {
      return file.lastModifiedSync();
    } on Object {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
  }

  static bool _safeDirExists(String path) {
    if (path.isEmpty) return false;
    try {
      return Directory(path).existsSync();
    } on Object {
      return false;
    }
  }

  static String _normalizePath(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return '';
    return p.normalize(trimmed);
  }

  static String _cwdKey(String normalizedPath) =>
      Platform.isWindows ? normalizedPath.toLowerCase() : normalizedPath;
}
