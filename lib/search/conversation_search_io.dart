import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../kernel/agent_message_parser.dart';
import '../kernel/claude_code/claude_environment.dart';
import 'conversation_search.dart';

/// Searches kept conversations across Ayte and all local agent kernels:
/// - Ayte / Claude Code / CodeBuddy `.jsonl` transcripts (`projects/*/*.jsonl`)
/// - Antigravity native `brain/<id>/.system_generated/logs/transcript.jsonl`
/// - Codex CLI `sessions/**/*.jsonl`
///
/// Read once in a background isolate and kept in memory until a file's size or
/// modification timestamp changes.
class ClaudeConversationSearch implements ConversationSearch {
  ClaudeConversationSearch({
    this.configDir,
    String? homeDir,
    String? claudeConfigDir,
    String? codebuddyConfigDir,
    String? codexHome,
    String? antigravityDir,
  }) : _overrides = (
         homeDir: homeDir,
         claudeConfigDir: claudeConfigDir,
         codebuddyConfigDir: codebuddyConfigDir,
         codexHome: codexHome,
         antigravityDir: antigravityDir,
       );

  /// Ayte / Claude Code's config folder; by default as its kernel finds it.
  final String? configDir;
  final ({
    String? homeDir,
    String? claudeConfigDir,
    String? codebuddyConfigDir,
    String? codexHome,
    String? antigravityDir,
  })
  _overrides;

  final Map<String, _Kept> _kept = {};
  Future<void>? _preparing;

  @override
  Future<void> prepare() =>
      _preparing ??= _prepare().whenComplete(() => _preparing = null);

  Future<void> _prepare() async {
    final roots = await _resolveRoots();
    final known = {
      for (final MapEntry(:key, :value) in _kept.entries)
        key: (size: value.size, modified: value.modified),
    };
    final read = await Isolate.run(() => _readChanged(roots, known));
    _kept.removeWhere((pathKey, _) => !read.present.contains(pathKey));
    for (final session in read.changed) {
      _kept[session.pathKey] = _Kept(
        session.sessionId,
        session.size,
        session.modified,
        session.text,
        session.text.toLowerCase(),
      );
    }
  }

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

  static String _resolveHome(Map<String, String> env) {
    final win = Platform.isWindows;
    final envHome = _lookupEnvVar(env, 'HOME', win: win);
    if (envHome != null && envHome.isNotEmpty) return envHome;
    final envUserProfile = _lookupEnvVar(env, 'USERPROFILE', win: win);
    if (envUserProfile != null && envUserProfile.isNotEmpty) {
      return envUserProfile;
    }
    return '';
  }

  Future<_SearchRoots> _resolveRoots() async {
    final projectRoots = <String>[];
    final agyBrainRoots = <String>[];
    final codexSessionsRoots = <String>[];
    final seenProject = <String>{};
    final seenAgy = <String>{};
    final seenCodex = <String>{};

    void addRoot(List<String> list, Set<String> seen, String rawPath) {
      final norm = _normalizePath(rawPath);
      if (norm.isEmpty) return;
      if (seen.add(_pathKey(norm))) {
        list.add(norm);
      }
    }

    final win = Platform.isWindows;
    final explicitHome = _overrides.homeDir?.trim();
    final hasExplicitHome = explicitHome != null && explicitHome.isNotEmpty;
    final env = (configDir == null && !hasExplicitHome)
        ? await ClaudeEnvironment.of()
        : const <String, String>{};
    final resolvedHome = hasExplicitHome
        ? explicitHome
        : (configDir == null ? _resolveHome(env) : null);

    final explicitConfig = configDir?.trim();
    if (explicitConfig != null && explicitConfig.isNotEmpty) {
      addRoot(projectRoots, seenProject, p.join(explicitConfig, 'projects'));
    } else if (configDir == null) {
      if (hasExplicitHome) {
        addRoot(
          projectRoots,
          seenProject,
          p.join(explicitHome, '.ayte', 'projects'),
        );
      } else {
        final envAyte = _lookupEnvVar(
          env,
          ClaudeEnvironment.dataPathVariable,
          win: win,
        );
        final ayteConfig = (envAyte != null && envAyte.isNotEmpty)
            ? envAyte
            : (resolvedHome != null && resolvedHome.isNotEmpty
                  ? p.join(resolvedHome, '.ayte')
                  : '');
        if (ayteConfig.isNotEmpty) {
          addRoot(projectRoots, seenProject, p.join(ayteConfig, 'projects'));
        }
      }
    }

    if (_overrides.claudeConfigDir?.trim().isNotEmpty == true) {
      addRoot(
        projectRoots,
        seenProject,
        p.join(_overrides.claudeConfigDir!.trim(), 'projects'),
      );
    } else {
      if (configDir == null && !hasExplicitHome) {
        final envClaude = _lookupEnvVar(env, 'CLAUDE_CONFIG_DIR', win: win);
        if (envClaude != null && envClaude.isNotEmpty) {
          addRoot(projectRoots, seenProject, p.join(envClaude, 'projects'));
        }
      }
      if (resolvedHome != null && resolvedHome.isNotEmpty) {
        addRoot(
          projectRoots,
          seenProject,
          p.join(resolvedHome, '.claude', 'projects'),
        );
      }
    }

    if (_overrides.codebuddyConfigDir?.trim().isNotEmpty == true) {
      addRoot(
        projectRoots,
        seenProject,
        p.join(_overrides.codebuddyConfigDir!.trim(), 'projects'),
      );
    } else if (resolvedHome != null && resolvedHome.isNotEmpty) {
      addRoot(
        projectRoots,
        seenProject,
        p.join(resolvedHome, '.codebuddy', 'projects'),
      );
    }

    if (_overrides.antigravityDir?.trim().isNotEmpty == true) {
      addRoot(
        agyBrainRoots,
        seenAgy,
        p.join(_overrides.antigravityDir!.trim(), 'brain'),
      );
    } else if (resolvedHome != null && resolvedHome.isNotEmpty) {
      addRoot(
        agyBrainRoots,
        seenAgy,
        p.join(resolvedHome, '.gemini', 'antigravity-cli', 'brain'),
      );
    }

    if (_overrides.codexHome?.trim().isNotEmpty == true) {
      addRoot(
        codexSessionsRoots,
        seenCodex,
        p.join(_overrides.codexHome!.trim(), 'sessions'),
      );
    } else {
      final envCodex = (configDir == null && !hasExplicitHome)
          ? _lookupEnvVar(env, 'CODEX_HOME', win: win)
          : null;
      if (envCodex != null && envCodex.isNotEmpty) {
        addRoot(codexSessionsRoots, seenCodex, p.join(envCodex, 'sessions'));
      } else if (resolvedHome != null && resolvedHome.isNotEmpty) {
        addRoot(
          codexSessionsRoots,
          seenCodex,
          p.join(resolvedHome, '.codex', 'sessions'),
        );
      }
    }

    return (
      projectRoots: projectRoots,
      agyBrainRoots: agyBrainRoots,
      codexSessionsRoots: codexSessionsRoots,
    );
  }

  @override
  Future<List<ConversationHit>> search(String query, {int limit = 50}) async {
    await prepare();
    if (limit <= 0) return const [];
    final needle = query.trim();
    if (needle.isEmpty) return const [];
    final sessions = _kept.values.toList()
      ..sort((a, b) => b.modified.compareTo(a.modified));
    final hits = <ConversationHit>[];
    final seenSessionIds = <String>{};
    for (final kept in sessions) {
      if (kept.text.isEmpty || kept.sessionId.isEmpty) continue;
      if (!seenSessionIds.add(kept.sessionId)) continue;
      final hit = findIn(kept.sessionId, kept.text, needle, lower: kept.lower);
      if (hit == null) continue;
      hits.add(hit);
      if (hits.length >= limit) break;
    }
    return hits;
  }
}

enum _SourceKind { claude, antigravity, codex }

typedef _SearchRoots = ({
  List<String> projectRoots,
  List<String> agyBrainRoots,
  List<String> codexSessionsRoots,
});

class _Kept {
  _Kept(this.sessionId, this.size, this.modified, this.text, this.lower);

  final String sessionId;
  final int size;
  final int modified;
  final String text;
  final String lower;
}

typedef _Read = ({
  Set<String> present,
  List<
    ({String pathKey, String sessionId, int size, int modified, String text})
  >
  changed,
});

final RegExp _agyValidIdPattern = RegExp(r'^[0-9a-zA-Z][0-9a-zA-Z_-]*$');
final RegExp _agyUserRequestRegex = RegExp(
  r'<USER_REQUEST>\s*([\s\S]*?)\s*</USER_REQUEST>',
);
final RegExp _agyIgnoredTagsRegex = RegExp(
  r'<(system-reminder|CONVERSATION_CONTEXT)>[\s\S]*?</\1>',
  caseSensitive: false,
);
final RegExp _cliWrapperXmlRegex = RegExp(
  r'^<(?:command-name|command-message|command-args|'
  r'local-command-stdout|local-command-stderr|local-command-caveat|'
  r'system-reminder|bash-input|bash-stdout|bash-stderr|'
  r'task-notification|CONVERSATION_CONTEXT|user_info|user_information|'
  r'environment_context|user_instructions|INSTRUCTIONS|permissions|'
  r'AGENTS\.md|collaboration_mode|skills_instructions|turn_aborted|'
  r'ide_opened_file|ide_selection)(?=[\s>/])',
  caseSensitive: false,
);
final RegExp _codexUuidSuffixRegex = RegExp(
  r'([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$',
);
final RegExp _codexRolloutPrefixRegex = RegExp(
  r'^rollout-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}(?:\.\d+)?Z?-(.+)$',
);

String _normalizePath(String rawPath) {
  var path = rawPath.trim();
  if (path.isEmpty) return '';
  final lower = path.toLowerCase();
  if (lower.startsWith(r'\\?\unc\') || lower.startsWith('//?/unc/')) {
    path = r'\\' + path.substring(8);
  } else if (path.startsWith(r'\\?\') || path.startsWith('//?/')) {
    path = path.substring(4);
  }
  if (RegExp(r'^[A-Za-z]:[/\\]').hasMatch(path)) {
    path = p.windows.normalize(path.replaceAll('/', r'\'));
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

String _pathKey(String normalizedPath) =>
    Platform.isWindows ? normalizedPath.toLowerCase() : normalizedPath;

bool _isJsonlName(String name) =>
    name.toLowerCase().endsWith('.jsonl') && !name.startsWith('.');

String _stripJsonlExtension(String name) => name.toLowerCase().endsWith('.jsonl')
    ? name.substring(0, name.length - '.jsonl'.length)
    : name;

/// The session files under [roots], and the parsed text of those not matching
/// [known].
_Read _readChanged(
  _SearchRoots roots,
  Map<String, ({int size, int modified})> known,
) {
  final present = <String>{};
  final changed =
      <
        ({
          String pathKey,
          String sessionId,
          int size,
          int modified,
          String text,
        })
      >[];

  void visitFile(File file, _SourceKind kind, {String? explicitSessionId}) {
    final FileStat stat;
    try {
      stat = file.statSync();
    } on Object {
      return;
    }
    if (stat.type != FileSystemEntityType.file) return;
    final norm = _normalizePath(file.path);
    if (norm.isEmpty) return;
    final key = _pathKey(norm);
    if (!present.add(key)) return;
    final size = stat.size;
    final modified = stat.modified.microsecondsSinceEpoch;
    final was = known[key];
    if (was != null && was.size == size && was.modified == modified) {
      return;
    }
    final parsed = _parseSessionFile(
      file,
      kind,
      explicitSessionId: explicitSessionId,
    );
    changed.add((
      pathKey: key,
      sessionId: parsed.sessionId,
      size: size,
      modified: modified,
      text: parsed.text,
    ));
  }

  for (final root in roots.projectRoots) {
    final dir = Directory(root);
    final List<FileSystemEntity> projectDirs;
    try {
      if (!dir.existsSync()) continue;
      projectDirs = dir.listSync(followLinks: false);
    } on Object {
      continue;
    }
    for (final project in projectDirs) {
      if (project is! Directory) continue;
      if (p.basename(project.path).startsWith('.')) continue;
      final List<FileSystemEntity> files;
      try {
        files = project.listSync(followLinks: false);
      } on Object {
        continue;
      }
      for (final file in files) {
        if (file is! File) continue;
        if (!_isJsonlName(p.basename(file.path))) continue;
        visitFile(file, _SourceKind.claude);
      }
    }
  }

  for (final brainRoot in roots.agyBrainRoots) {
    final dir = Directory(brainRoot);
    final List<FileSystemEntity> brainDirs;
    try {
      if (!dir.existsSync()) continue;
      brainDirs = dir.listSync(followLinks: false);
    } on Object {
      continue;
    }
    for (final entry in brainDirs) {
      if (entry is! Directory) continue;
      final brainId = p.basename(entry.path);
      if (!_agyValidIdPattern.hasMatch(brainId)) continue;
      final transcript = File(
        p.join(entry.path, '.system_generated', 'logs', 'transcript.jsonl'),
      );
      try {
        if (!transcript.existsSync()) continue;
      } on Object {
        continue;
      }
      visitFile(
        transcript,
        _SourceKind.antigravity,
        explicitSessionId: brainId,
      );
    }
  }

  for (final sessionsRoot in roots.codexSessionsRoots) {
    final rootDir = Directory(sessionsRoot);
    try {
      if (!rootDir.existsSync()) continue;
    } on Object {
      continue;
    }
    final stack = <Directory>[rootDir];
    while (stack.isNotEmpty) {
      final current = stack.removeLast();
      final List<FileSystemEntity> children;
      try {
        children = current.listSync(followLinks: false);
      } on Object {
        continue;
      }
      for (final child in children) {
        if (child is Directory) {
          if (!p.basename(child.path).startsWith('.')) {
            stack.add(child);
          }
        } else if (child is File && _isJsonlName(p.basename(child.path))) {
          visitFile(child, _SourceKind.codex);
        }
      }
    }
  }

  return (present: present, changed: changed);
}

({String sessionId, String text}) _parseSessionFile(
  File file,
  _SourceKind kind, {
  String? explicitSessionId,
}) {
  final String rawText;
  try {
    final bytes = file.readAsBytesSync();
    rawText = const Utf8Decoder(allowMalformed: true).convert(bytes);
  } on Object {
    return (
      sessionId: explicitSessionId ?? _fallbackSessionId(file.path, kind),
      text: '',
    );
  }

  return switch (kind) {
    _SourceKind.claude => _parseClaudeJsonl(file.path, rawText),
    _SourceKind.antigravity => _parseAntigravityTranscript(
      explicitSessionId ?? '',
      rawText,
    ),
    _SourceKind.codex => _parseCodexRollout(file.path, rawText),
  };
}

String _fallbackSessionId(String filePath, _SourceKind kind) {
  final base = p.basename(filePath);
  return switch (kind) {
    _SourceKind.claude => _stripJsonlExtension(base),
    _SourceKind.antigravity =>
      p.basename(p.dirname(p.dirname(p.dirname(filePath)))),
    _SourceKind.codex => _codexIdFromFilename(base) ?? _stripJsonlExtension(base),
  };
}

/// Parses Claude / CodeBuddy / synced Antigravity `.jsonl` transcripts.
({String sessionId, String text}) _parseClaudeJsonl(
  String filePath,
  String rawText,
) {
  String? sessionId;
  final buffer = StringBuffer();
  for (final rawLine in const LineSplitter().convert(rawText)) {
    final line = rawLine.trim();
    if (line.isEmpty || !line.startsWith('{')) continue;
    final Object? entry;
    try {
      entry = jsonDecode(line);
    } on Object {
      continue;
    }
    if (entry is! Map<String, Object?>) continue;
    if (sessionId == null) {
      final sid = entry['sessionId'];
      if (sid is String && sid.trim().isNotEmpty) {
        sessionId = sid.trim();
      }
    }
    if (entry['isSidechain'] == true || entry['isMeta'] == true) continue;
    final type = entry['type'];
    if (type != 'user' && type != 'assistant') continue;
    final message = entry['message'];
    if (message is! Map<String, Object?>) continue;
    final content = message['content'];
    final parts = switch (content) {
      final String text => [text],
      final List<Object?> blocks => [
        for (final block in blocks)
          if (block is Map<String, Object?> &&
              (block['type'] == 'text' ||
                  block['type'] == 'input_text' ||
                  block['type'] == 'output_text') &&
              block['text'] is String)
            block['text']! as String,
      ],
      _ => const <String>[],
    };
    for (final part in parts) {
      var trimmed = part.trim();
      if (trimmed.isEmpty) continue;
      if (type == 'user') {
        final agentMsg = parseAgentMessage(trimmed);
        if (agentMsg != null) {
          trimmed = agentMsg.text.trim();
          if (trimmed.isEmpty) continue;
        } else if (_isCliWrapperXml(trimmed)) {
          // Command wrappers and CLI notes, not what was said.
          continue;
        }
      }
      buffer.writeln(trimmed);
    }
  }
  return (
    sessionId: sessionId ?? _stripJsonlExtension(p.basename(filePath)),
    text: buffer.toString(),
  );
}

/// Parses Antigravity native `brain/<id>/.system_generated/logs/transcript.jsonl`.
({String sessionId, String text}) _parseAntigravityTranscript(
  String brainId,
  String rawText,
) {
  final buffer = StringBuffer();
  for (final rawLine in const LineSplitter().convert(rawText)) {
    final line = rawLine.trim();
    if (line.isEmpty || !line.startsWith('{')) continue;
    final Object? step;
    try {
      step = jsonDecode(line);
    } on Object {
      continue;
    }
    if (step is! Map<String, Object?>) continue;
    final type = step['type'];
    if (type == 'USER_INPUT') {
      final raw = _extractAgyContentText(step['content']);
      final cleaned = _cleanAntigravityUserInput(raw);
      if (cleaned.isNotEmpty) {
        buffer.writeln(cleaned);
      }
    } else if (type == 'PLANNER_RESPONSE') {
      final raw = _extractAgyContentText(step['content']).trim();
      if (raw.isNotEmpty) {
        buffer.writeln(raw);
      }
    }
  }
  return (sessionId: brainId, text: buffer.toString());
}

String _extractAgyContentText(Object? content) {
  if (content is String) return content;
  if (content is! List<Object?>) return '';
  final buf = StringBuffer();
  for (final block in content) {
    if (block is! Map<String, Object?>) continue;
    final type = block['type'];
    if (type != null &&
        type != 'text' &&
        type != 'output_text' &&
        type != 'input_text') {
      continue;
    }
    final text = block['text'];
    if (text is String && text.isNotEmpty) {
      if (buf.isNotEmpty) buf.write('\n');
      buf.write(text);
    }
  }
  return buf.toString();
}

String _cleanAntigravityUserInput(String raw) {
  if (raw.trim().isEmpty) return '';
  var text = raw.replaceAll(_agyIgnoredTagsRegex, '');
  final match = _agyUserRequestRegex.firstMatch(text);
  final hasUserRequest = match != null;
  if (match != null) {
    text = match.group(1)!;
  } else {
    text = text
        .replaceAll('<USER_REQUEST>', '')
        .replaceAll('</USER_REQUEST>', '');
  }
  final trimmed = text.trim();
  if (trimmed.isEmpty) return '';
  final agentMsg = parseAgentMessage(trimmed);
  if (agentMsg != null) {
    return agentMsg.text.trim();
  }
  if (!hasUserRequest && _isCliWrapperXml(trimmed)) return '';
  return trimmed;
}

/// Parses Codex CLI rollout JSONL (`sessions/**/*.jsonl`).
({String sessionId, String text}) _parseCodexRollout(
  String filePath,
  String rawText,
) {
  String? sessionId;
  final buffer = StringBuffer();
  String? lastSpeaker;
  String? lastMessage;

  void appendMessage(String speaker, String raw, {bool isUser = false}) {
    var trimmed = raw.trim();
    if (trimmed.isEmpty) return;
    if (isUser) {
      final agentMsg = parseAgentMessage(trimmed);
      if (agentMsg != null) {
        trimmed = agentMsg.text.trim();
      } else if (_isCodexBoilerplate(trimmed) || _isCliWrapperXml(trimmed)) {
        return;
      }
    }
    if (trimmed.isEmpty) return;
    final canonical = trimmed.replaceAll('\r\n', '\n');
    if (lastSpeaker == speaker && lastMessage == canonical) {
      return;
    }
    lastSpeaker = speaker;
    lastMessage = canonical;
    buffer.writeln(trimmed);
  }

  for (final rawLine in const LineSplitter().convert(rawText)) {
    final line = rawLine.trim();
    if (line.isEmpty || !line.startsWith('{')) continue;
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on Object {
      continue;
    }
    if (decoded is! Map<String, Object?>) continue;
    final type = decoded['type'];
    final payload = decoded['payload'];
    final payloadMap = payload is Map<String, Object?> ? payload : null;

    switch (type) {
      case 'session_meta':
        final pid = payloadMap?['id'];
        if (sessionId == null && pid is String && pid.trim().isNotEmpty) {
          sessionId = pid.trim();
        }
      case 'event_msg':
        if (payloadMap == null) continue;
        final payloadType = payloadMap['type'];
        if (payloadType == 'user_message') {
          final msg = payloadMap['message'];
          if (msg is String) {
            appendMessage('user', msg, isUser: true);
          }
        } else if (payloadType == 'agent_message') {
          final msg = payloadMap['message'];
          if (msg is String) {
            appendMessage('assistant', msg);
          }
        }
      case 'response_item':
        if (payloadMap == null) continue;
        if (payloadMap['type'] != 'message') continue;
        final role = payloadMap['role'];
        if (role != 'user' && role != 'assistant') continue;
        final text = _extractCodexMessageText(payloadMap['content']);
        appendMessage(role! as String, text, isUser: role == 'user');
      case 'userMessage':
        final text = _extractCodexMessageText(decoded['content']);
        appendMessage('user', text, isUser: true);
    }
  }

  final resolvedId =
      sessionId ??
      _codexIdFromFilename(p.basename(filePath)) ??
      _stripJsonlExtension(p.basename(filePath));
  return (sessionId: resolvedId, text: buffer.toString());
}

String _extractCodexMessageText(Object? content) {
  if (content is String) return content;
  if (content is! List<Object?>) return '';
  final buf = StringBuffer();
  for (final block in content) {
    if (block is! Map<String, Object?>) continue;
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

bool _isCliWrapperXml(String text) {
  final trimmed = text.trimLeft();
  if (!trimmed.startsWith('<')) return false;
  return _cliWrapperXmlRegex.hasMatch(trimmed);
}

bool _isCodexBoilerplate(String text) {
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

String? _codexIdFromFilename(String basename) {
  var stem = basename;
  if (stem.toLowerCase().endsWith('.jsonl.zst')) {
    stem = stem.substring(0, stem.length - '.jsonl.zst'.length);
  } else if (stem.toLowerCase().endsWith('.jsonl')) {
    stem = stem.substring(0, stem.length - '.jsonl'.length);
  }
  if (stem.startsWith('rollout-')) {
    final uuidMatch = _codexUuidSuffixRegex.firstMatch(stem);
    if (uuidMatch != null) return uuidMatch.group(1)!;
    final tsMatch = _codexRolloutPrefixRegex.firstMatch(stem);
    if (tsMatch != null) return tsMatch.group(1)!;
  }
  return stem.isEmpty ? null : stem;
}
