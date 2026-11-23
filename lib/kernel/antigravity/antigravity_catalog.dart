import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:bao_agent/bao_agent.dart' show AgentPaths;
import 'package:path/path.dart' as p;

import '../../remote/remote_claude.dart';
import '../../remote/remote_location.dart';
import '../agent_kernel.dart';
import '../claude_code/claude_storage_io.dart' show ClaudeStorage;
import '../codebuddy/codebuddy_cli.dart';
import 'antigravity_cli.dart';
import 'antigravity_transport.dart';

/// Antigravity CLI (`agy`) session catalog:
/// - Claims `antigravity-cli`-authored `.jsonl` sessions from [claude] without
///   claiming `claude-code` or `codebuddy-cli` sessions.
/// - Discovers native `agy` sessions stored under
///   `~/.gemini/antigravity-cli/brain/*/` using `jetbox_summaries_proto.pb`
///   and `.system_generated/logs/transcript.jsonl`.
/// - Leaves unsynced native sessions with `SessionRecord.path == null` so
///   [ClaudeStorage.read] / [ClaudeStorage.readPage] invokes
///   [syncAntigravityTranscriptIfNeeded] lazily when opened.
class AntigravityCatalog implements SessionCatalog, MovesSessions {
  const AntigravityCatalog({
    this.claude = const ClaudeCatalog(),
    this.homeDir,
    this.paths,
  });

  final ClaudeCatalog claude;
  final String? homeDir;
  final AgentPaths? paths;

  static final RegExp _validIdPattern = RegExp(r'^[0-9a-zA-Z][0-9a-zA-Z_-]*$');
  static const int _maxHeaderBytes = 256 * 1024;
  static const int _maxHeaderLines = 40;
  static const int _maxTranscriptHeadBytes = 128 * 1024;
  static const int _maxTranscriptTailBytes = 32 * 1024;
  static const int _maxTranscriptLineBytes = 1024 * 1024;
  static const int _maxFullTranscriptBytes = 256 * 1024;
  static const int _maxTitleChars = 120;
  static const int _maxTimestampSeconds = 253402300799; // 9999-12-31T23:59:59Z

  static final RegExp _uriSchemeRegex = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]+:');
  static final RegExp _userRequestRegex = RegExp(
    r'<USER_REQUEST>\s*([\s\S]*?)\s*</USER_REQUEST>',
  );
  static final RegExp _ignoredTagsRegex = RegExp(
    r'<(system-reminder|CONVERSATION_CONTEXT)>[\s\S]*?</\1>',
    caseSensitive: false,
  );

  String get _resolvedHome {
    if (homeDir != null && homeDir!.isNotEmpty) return homeDir!;
    if (paths != null && paths!.home.isNotEmpty) return paths!.home;
    return AgentPaths.from(Platform.environment).home;
  }

  String get _antigravityRoot =>
      p.join(_resolvedHome, '.gemini', 'antigravity-cli');

  ClaudeCatalog get _effectiveClaude {
    if (paths != null &&
        claude.local.configDir == null &&
        claude.local.cacheFile == null) {
      return ClaudeCatalog(local: ClaudeStorage(configDir: paths!.configDir));
    }
    return claude;
  }

  static bool isValidSessionId(String id) => _validIdPattern.hasMatch(id);

  /// Inspects up to the first 40 non-empty lines (max 256 KB) of a `.jsonl`
  /// session file to infer whether it was authored by `antigravity-cli`,
  /// `codebuddy-cli`, or `claude-code`. Returns `null` when undetermined or
  /// unreadable.
  static String? inferJsonlKernelId(String path) {
    if (path.isEmpty) return null;
    RandomAccessFile? raf;
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      raf = file.openSync();
      final bytes = raf.readSync(_maxHeaderBytes);
      if (bytes.isEmpty) return null;
      final text = utf8.decode(bytes, allowMalformed: true);
      final lines = const LineSplitter().convert(text);
      var sawOtherModel = false;
      var inspected = 0;
      for (final rawLine in lines) {
        final line = rawLine.trim();
        if (line.isEmpty) continue;
        inspected++;
        if (inspected > _maxHeaderLines) break;
        Map<String, Object?>? decoded;
        try {
          final parsed = jsonDecode(line);
          if (parsed is Map) decoded = parsed.cast<String, Object?>();
        } on Object {
          continue;
        }
        if (decoded == null) continue;
        final uuid = decoded['uuid'];
        if (uuid is String && uuid.startsWith('agy-')) {
          return antigravityBuiltinProviderId;
        }
        final message = decoded['message'];
        final rawModel =
            (message is Map ? message['model'] : null) ?? decoded['model'];
        if (rawModel is String) {
          final model = rawModel.trim();
          if (model.isNotEmpty &&
              model != '<synthetic>' &&
              model != 'default') {
            if (AntigravityModels.isAntigravityModel(model)) {
              return antigravityBuiltinProviderId;
            }
            if (CodeBuddyModels.isCodeBuddyModel(model)) {
              return codebuddyBuiltinProviderId;
            }
            sawOtherModel = true;
          }
        }
      }
      return sawOtherModel ? 'claude-code' : null;
    } on Object {
      return null;
    } finally {
      try {
        raf?.closeSync();
      } on Object {
        // Ignore close failure.
      }
    }
  }

  /// Lazily converts an unsynced native `agy` session into a `.jsonl` file
  /// using [syncAntigravityTranscriptIfNeeded].
  String? ensureSynced(SessionRecord session) =>
      session.path ??
      syncAntigravityTranscriptIfNeeded(
        cwd: session.cwd,
        sessionId: session.id,
        paths: paths ?? _defaultPaths(),
      );

  AgentPaths _defaultPaths() {
    final home = _resolvedHome;
    final config = paths?.configDir ?? claude.local.configDir;
    if (home.isEmpty) {
      return AgentPaths.from(Platform.environment, configDir: config);
    }
    return AgentPaths(
      home: home,
      configDir: config ?? p.join(home, '.ayte'),
    );
  }

  @override
  Future<List<ProjectRecord>> projects() async {
    final root = _antigravityRoot;
    final pbEntries = _readSummaryProto(
      File(p.join(root, 'jetbox_summaries_proto.pb')),
    );

    final byId = <String, SessionRecord>{};
    final claudeProjects = await _effectiveClaude.projects();
    for (final project in claudeProjects) {
      for (final session in project.sessions) {
        if (!_isAntigravityJsonl(session, root, pbEntries)) continue;
        final existing = byId[session.id];
        if (existing == null || session.updatedAt.isAfter(existing.updatedAt)) {
          byId[session.id] = SessionRecord(
            id: session.id,
            title: session.title,
            updatedAt: session.updatedAt,
            cwd: _normalizePath(session.cwd),
            path: session.path,
          );
        }
      }
    }

    final brainDir = Directory(p.join(root, 'brain'));
    if (brainDir.existsSync()) {
      List<FileSystemEntity> entries;
      try {
        entries = brainDir.listSync(followLinks: false);
      } on Object {
        entries = const [];
      }
      for (final entity in entries) {
        if (entity is! Directory &&
            !(entity is Link &&
                FileSystemEntity.typeSync(entity.path) ==
                    FileSystemEntityType.directory)) {
          continue;
        }
        final id = p.basename(entity.path);
        if (!isValidSessionId(id)) continue;

        final transcriptFile = File(
          p.join(entity.path, '.system_generated', 'logs', 'transcript.jsonl'),
        );
        if (!transcriptFile.existsSync()) continue;
        try {
          if (transcriptFile.lengthSync() <= 0) continue;
        } on Object {
          continue;
        }

        final parsed = _parseTranscriptSummary(transcriptFile);
        final pb = pbEntries[id];
        final existing = byId[id];

        final promptTitle = parsed.title;
        final pbTitle = _cleanTitle(pb?.title);
        final resolvedTitle = (promptTitle != null && promptTitle.isNotEmpty)
            ? promptTitle
            : pbTitle;

        // Skip subagent-only sessions that have neither a user prompt nor a
        // clean summary title (unless already claimed as a .jsonl session).
        if (existing == null &&
            (resolvedTitle == null || resolvedTitle.isEmpty)) {
          continue;
        }

        final cwd = _resolveCwd(
          pbCwd: pb?.cwd,
          existingCwd: existing?.cwd,
          brainDirPath: entity.path,
          transcriptCwd: parsed.cwd,
        );
        if (cwd == null || cwd.isEmpty) continue;
        if (!_safeDirExists(cwd)) continue;

        var updatedAt =
            parsed.updatedAt ?? pb?.updatedAt ?? _safeModified(transcriptFile);
        if (pb?.updatedAt case final pbAt? when pbAt.isAfter(updatedAt)) {
          updatedAt = pbAt;
        }

        if (existing != null) {
          final mergedTitle = existing.title.isNotEmpty
              ? existing.title
              : (resolvedTitle ?? '');
          final mergedUpdatedAt = updatedAt.isAfter(existing.updatedAt)
              ? updatedAt
              : existing.updatedAt;
          byId[id] = SessionRecord(
            id: id,
            title: mergedTitle,
            updatedAt: mergedUpdatedAt,
            cwd: existing.cwd.isNotEmpty ? existing.cwd : cwd,
            path: existing.path,
          );
        } else {
          byId[id] = SessionRecord(
            id: id,
            title: resolvedTitle!,
            updatedAt: updatedAt,
            cwd: cwd,
            path: null,
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
      final normalizedSession = session.cwd == canonicalCwd
          ? session
          : SessionRecord(
              id: session.id,
              title: session.title,
              updatedAt: session.updatedAt,
              cwd: canonicalCwd,
              path: session.path,
            );
      (grouped[key] ??= []).add(normalizedSession);
    }

    final projects = <ProjectRecord>[
      for (final entry in grouped.entries)
        ProjectRecord(
          path: displayCwd[entry.key]!,
          sessions: entry.value
            ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)),
        ),
    ];
    projects.sort((a, b) => b.updatedAt!.compareTo(a.updatedAt!));
    return projects;
  }

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async {
    if (RemoteLocation.isRemote(cwd)) {
      return _effectiveClaude.sessionsIn(cwd);
    }
    final all = await projects();
    for (final project in all) {
      if (p.equals(project.path, cwd)) return project.sessions;
    }
    return const [];
  }

  @override
  Future<void> delete(String id) async {
    if (!isValidSessionId(id)) {
      throw ArgumentError.value(id, 'id', 'not a session id');
    }
    await _effectiveClaude.delete(id);
    final root = _antigravityRoot;
    final doomed = <FileSystemEntity>[
      Directory(p.join(root, 'brain', id)),
      for (final ext in const ['.db', '.db-wal', '.db-shm', '.pb'])
        File(p.join(root, 'conversations', '$id$ext')),
    ];
    for (final entity in doomed) {
      try {
        if (entity.existsSync()) {
          entity.deleteSync(recursive: true);
        }
      } on Object {
        // Ignore locked/missing files during best-effort cleanup.
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

    final root = _antigravityRoot;
    final brainDir = Directory(p.join(root, 'brain'));
    if (!brainDir.existsSync()) return moved;

    List<FileSystemEntity> entries;
    try {
      entries = brainDir.listSync(followLinks: false);
    } on Object {
      return moved;
    }

    final pbEntries = _readSummaryProto(
      File(p.join(root, 'jetbox_summaries_proto.pb')),
    );
    final effectivePaths = paths ?? _defaultPaths();
    final fromKey = _cwdKey(normFrom);

    for (final entity in entries) {
      if (entity is! Directory &&
          !(entity is Link &&
              FileSystemEntity.typeSync(entity.path) ==
                  FileSystemEntityType.directory)) {
        continue;
      }
      final id = p.basename(entity.path);
      if (!isValidSessionId(id)) continue;
      if (effectivePaths.findSession(id) != null) continue;

      final transcriptFile = File(
        p.join(entity.path, '.system_generated', 'logs', 'transcript.jsonl'),
      );
      if (!transcriptFile.existsSync()) continue;
      try {
        if (transcriptFile.lengthSync() <= 0) continue;
      } on Object {
        continue;
      }

      final parsed = _parseTranscriptSummary(transcriptFile);
      final pb = pbEntries[id];
      final promptTitle = parsed.title;
      final pbTitle = _cleanTitle(pb?.title);
      if ((promptTitle == null || promptTitle.isEmpty) &&
          (pbTitle == null || pbTitle.isEmpty)) {
        continue;
      }

      var matchesFrom = false;
      for (final raw in <String?>[
        pb?.cwd,
        _readMetadataCwd(File(p.join(entity.path, 'metadata.json'))),
        parsed.cwd,
      ]) {
        if (raw == null || raw.trim().isEmpty) continue;
        final converted = _workspaceUriToPath(raw);
        if (converted == null || converted.isEmpty) continue;
        final norm = _normalizePath(converted);
        if (_cwdKey(norm) == fromKey) {
          matchesFrom = true;
          break;
        }
        if (_safeDirExists(norm)) {
          break;
        }
      }
      if (!matchesFrom) continue;

      final synced = syncAntigravityTranscriptIfNeeded(
        cwd: normTo,
        sessionId: id,
        paths: effectivePaths,
      );
      if (synced != null) {
        moved++;
      }
    }
    return moved;
  }

  bool _isAntigravityJsonl(
    SessionRecord session,
    String root,
    Map<String, _SummaryProtoEntry> pbEntries,
  ) {
    final id = session.id;
    if (isValidSessionId(id)) {
      final brainTranscript = File(
        p.join(root, 'brain', id, '.system_generated', 'logs', 'transcript.jsonl'),
      );
      if (brainTranscript.existsSync()) return true;
      final convDb = File(p.join(root, 'conversations', '$id.db'));
      if (convDb.existsSync()) return true;
      final convPb = File(p.join(root, 'conversations', '$id.pb'));
      if (convPb.existsSync()) return true;
      if (pbEntries.containsKey(id)) return true;
    }
    if (session.path case final path?) {
      return inferJsonlKernelId(path) == antigravityBuiltinProviderId;
    }
    return false;
  }

  String? _resolveCwd({
    required String? pbCwd,
    required String? existingCwd,
    required String brainDirPath,
    required String? transcriptCwd,
  }) {
    final candidates = <String?>[
      existingCwd,
      pbCwd,
      _readMetadataCwd(File(p.join(brainDirPath, 'metadata.json'))),
      transcriptCwd,
    ];
    for (final raw in candidates) {
      if (raw == null || raw.trim().isEmpty) continue;
      final converted = _workspaceUriToPath(raw);
      if (converted == null || converted.isEmpty) continue;
      final norm = _normalizePath(converted);
      if (_safeDirExists(norm)) {
        return norm;
      }
    }
    return null;
  }

  static bool _safeDirExists(String path) {
    if (path.isEmpty) return false;
    try {
      return Directory(path).existsSync();
    } on Object {
      return false;
    }
  }

  static String? _readMetadataCwd(File file) {
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return null;
      for (final key in const ['cwd', 'workspace', 'workspaceUri']) {
        final value = decoded[key];
        if (value is String && value.trim().isNotEmpty) return value.trim();
      }
    } on Object {
      // Ignore malformed metadata.json.
    }
    return null;
  }

  static DateTime _safeModified(File file) {
    try {
      return file.lastModifiedSync();
    } on Object {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
  }

  static String _normalizePath(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return '';
    return p.normalize(trimmed);
  }

  static String _cwdKey(String normalizedPath) =>
      Platform.isWindows ? normalizedPath.toLowerCase() : normalizedPath;

  static String? _workspaceUriToPath(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.contains('://') || _uriSchemeRegex.hasMatch(trimmed)) {
      final uri = Uri.tryParse(trimmed);
      if (uri == null || uri.scheme != 'file') return null;
      try {
        final path = uri.toFilePath(windows: Platform.isWindows);
        return path.isEmpty ? null : path;
      } on Object {
        return null;
      }
    }
    return trimmed;
  }

  static String? _cleanTitle(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed.startsWith('<')) return null;
    final singleLine = trimmed.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (singleLine.isEmpty) return null;
    return _truncateTitle(singleLine);
  }

  static String? _extractUserInputTitle(String raw) {
    if (raw.isEmpty) return null;
    var text = raw.replaceAll(_ignoredTagsRegex, '');
    final match = _userRequestRegex.firstMatch(text);
    if (match != null) {
      text = match.group(1)!;
    }
    for (final line in const LineSplitter().convert(text)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed == '<USER_REQUEST>' || trimmed == '</USER_REQUEST>') {
        continue;
      }
      final collapsed = trimmed.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (collapsed.isNotEmpty) return _truncateTitle(collapsed);
    }
    return null;
  }

  static String _truncateTitle(String text) {
    if (text.length <= _maxTitleChars) return text;
    var cut = _maxTitleChars;
    final prev = text.codeUnitAt(cut - 1);
    if (prev >= 0xD800 && prev <= 0xDBFF) {
      cut--;
    }
    return '${text.substring(0, cut)}…';
  }

  static ({String? title, String? cwd, DateTime? updatedAt})
  _parseTranscriptSummary(File file) {
    String? title;
    String? cwd;
    DateTime? updatedAt;

    void inspectLine(String rawLine, {required bool lookForTitle}) {
      final line = rawLine.trim();
      if (line.isEmpty) return;
      Map<String, Object?>? step;
      try {
        final parsed = jsonDecode(line);
        if (parsed is Map) step = parsed.cast<String, Object?>();
      } on Object {
        return;
      }
      if (step == null) return;

      if (cwd == null) {
        final rawCwd = step['cwd'];
        if (rawCwd is String && rawCwd.trim().isNotEmpty) {
          cwd = rawCwd.trim();
        }
      }

      if (lookForTitle && title == null && step['type'] == 'USER_INPUT') {
        final content = step['content'];
        if (content is String) {
          title = _extractUserInputTitle(content);
        } else if (content is List) {
          final textParts = [
            for (final block in content)
              if (block is Map && block['text'] is String)
                block['text'] as String,
          ].join('\n');
          if (textParts.isNotEmpty) {
            title = _extractUserInputTitle(textParts);
          }
        }
      }

      final createdAt = step['created_at'];
      if (createdAt is String && createdAt.isNotEmpty) {
        final dt = DateTime.tryParse(createdAt);
        if (dt != null && (updatedAt == null || dt.isAfter(updatedAt!))) {
          updatedAt = dt;
        }
      }
    }

    try {
      final length = file.lengthSync();
      if (length <= _maxFullTranscriptBytes) {
        final bytes = file.readAsBytesSync();
        for (final line in const LineSplitter().convert(
          utf8.decode(bytes, allowMalformed: true),
        )) {
          inspectLine(line, lookForTitle: true);
        }
      } else {
        final raf = file.openSync();
        try {
          final headBytes = raf.readSync(_maxTranscriptHeadBytes);
          for (final line in const LineSplitter().convert(
            utf8.decode(headBytes, allowMalformed: true),
          )) {
            inspectLine(line, lookForTitle: true);
          }
          final tailOffset = math.max(0, length - _maxTranscriptTailBytes);
          var atBoundary = tailOffset == 0;
          if (!atBoundary) {
            raf.setPositionSync(tailOffset - 1);
            atBoundary = raf.readByteSync() == 0x0A;
          }
          raf.setPositionSync(tailOffset);
          final tailBytes = raf.readSync(length - tailOffset);
          if (atBoundary) {
            for (final line in const LineSplitter().convert(
              utf8.decode(tailBytes, allowMalformed: true),
            )) {
              inspectLine(line, lookForTitle: false);
            }
          } else {
            final firstNl = tailBytes.indexOf(0x0A);
            final hasAfterNl =
                firstNl >= 0 && _hasNonWhitespace(tailBytes, firstNl + 1);
            if (hasAfterNl) {
              final slice = Uint8List.sublistView(tailBytes, firstNl + 1);
              for (final line in const LineSplitter().convert(
                utf8.decode(slice, allowMalformed: true),
              )) {
                inspectLine(line, lookForTitle: false);
              }
            } else {
              final lineStart = _findLineStartBackward(
                raf,
                tailOffset,
                minOffset: math.max(0, length - _maxTranscriptLineBytes),
              );
              if (lineStart != null) {
                raf.setPositionSync(lineStart);
                final fullTail = raf.readSync(length - lineStart);
                for (final line in const LineSplitter().convert(
                  utf8.decode(fullTail, allowMalformed: true),
                )) {
                  inspectLine(line, lookForTitle: false);
                }
              }
            }
          }
        } finally {
          raf.closeSync();
        }
      }
    } on Object {
      // Return whatever partial metadata was decoded safely.
    }

    return (title: title, cwd: cwd, updatedAt: updatedAt);
  }

  static bool _hasNonWhitespace(Uint8List bytes, int start) {
    for (var i = start; i < bytes.length; i++) {
      final b = bytes[i];
      if (b != 0x20 && b != 0x09 && b != 0x0D && b != 0x0A) {
        return true;
      }
    }
    return false;
  }

  static int? _findLineStartBackward(
    RandomAccessFile raf,
    int beforeOffset, {
    required int minOffset,
  }) {
    var pos = beforeOffset;
    while (pos > minOffset) {
      final chunkStart = math.max(minOffset, pos - _maxTranscriptTailBytes);
      final chunkLen = pos - chunkStart;
      raf.setPositionSync(chunkStart);
      final chunk = raf.readSync(chunkLen);
      for (var i = chunk.length - 1; i >= 0; i--) {
        if (chunk[i] == 0x0A) {
          return chunkStart + i + 1;
        }
      }
      pos = chunkStart;
    }
    return minOffset == 0 ? 0 : null;
  }

  /// Pure-Dart protobuf wire reader for `jetbox_summaries_proto.pb`.
  ///
  /// Wire schema:
  /// - Top field 1 (len-delimited): entry message
  ///   - Field 1 (string): conversation_id
  ///   - Field 2 (len-delimited): Summary message
  ///     - Field 1 (string): title
  ///     - Field 3 (len-delimited): google.protobuf.Timestamp (field 1: seconds)
  ///     - Field 9 (len-delimited): Workspace message (field 1: workspaceUri)
  static Map<String, _SummaryProtoEntry> _readSummaryProto(File file) {
    if (!file.existsSync()) return const {};
    Uint8List bytes;
    try {
      bytes = file.readAsBytesSync();
    } on Object {
      return const {};
    }
    final result = <String, _SummaryProtoEntry>{};
    for (final field in _readProtoFields(bytes, 0, bytes.length)) {
      if (field.fieldNumber == 1 && field.bytes != null) {
        final entry = _parseProtoEntry(field.bytes!);
        if (entry != null) {
          result[entry.id] = entry;
        }
      }
    }
    return result;
  }

  static _SummaryProtoEntry? _parseProtoEntry(Uint8List bytes) {
    String? id;
    String? title;
    DateTime? updatedAt;
    String? cwd;

    for (final field in _readProtoFields(bytes, 0, bytes.length)) {
      if (field.fieldNumber == 1 && field.bytes != null) {
        id = utf8.decode(field.bytes!, allowMalformed: true).trim();
      } else if (field.fieldNumber == 2 && field.bytes != null) {
        for (final sumField in _readProtoFields(
          field.bytes!,
          0,
          field.bytes!.length,
        )) {
          if (sumField.fieldNumber == 1 && sumField.bytes != null) {
            title = utf8.decode(sumField.bytes!, allowMalformed: true);
          } else if (sumField.fieldNumber == 3 && sumField.bytes != null) {
            updatedAt = _parseTimestamp(sumField.bytes!);
          } else if (sumField.fieldNumber == 9 && sumField.bytes != null) {
            for (final wsField in _readProtoFields(
              sumField.bytes!,
              0,
              sumField.bytes!.length,
            )) {
              if (wsField.fieldNumber == 1 && wsField.bytes != null) {
                final uri = utf8
                    .decode(wsField.bytes!, allowMalformed: true)
                    .trim();
                final parsed = _workspaceUriToPath(uri);
                if (parsed != null &&
                    parsed.isNotEmpty &&
                    (cwd == null ||
                        (!_safeDirExists(cwd) && _safeDirExists(parsed)))) {
                  cwd = parsed;
                }
              }
            }
          }
        }
      }
    }
    if (id == null || id.isEmpty) return null;
    return _SummaryProtoEntry(
      id: id,
      title: title,
      updatedAt: updatedAt,
      cwd: cwd,
    );
  }

  static DateTime? _parseTimestamp(Uint8List bytes) {
    int? seconds;
    var nanos = 0;
    for (final field in _readProtoFields(bytes, 0, bytes.length)) {
      if (field.fieldNumber == 1 && field.varint != null) {
        seconds = field.varint!;
      } else if (field.fieldNumber == 2 && field.varint != null) {
        nanos = field.varint!;
      }
    }
    if (seconds == null || seconds <= 0 || seconds > _maxTimestampSeconds) {
      return null;
    }
    final safeNanos = (nanos >= 0 && nanos < 1000000000) ? nanos : 0;
    final micros = seconds * 1000000 + (safeNanos ~/ 1000);
    return DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true).toLocal();
  }

  static Iterable<({int fieldNumber, int? varint, Uint8List? bytes})>
  _readProtoFields(Uint8List data, int start, int end) sync* {
    var pos = start;
    while (pos < end) {
      final tagRes = _readVarint(data, pos, end);
      if (tagRes == null) break;
      final (tag, afterTag) = tagRes;
      pos = afterTag;
      final wireType = tag & 0x07;
      final fieldNumber = tag >>> 3;
      if (fieldNumber == 0) break;

      switch (wireType) {
        case 0:
          final valRes = _readVarint(data, pos, end);
          if (valRes == null) return;
          final (val, nextPos) = valRes;
          pos = nextPos;
          yield (fieldNumber: fieldNumber, varint: val, bytes: null);
        case 1:
          if (end - pos < 8) return;
          pos += 8;
        case 2:
          final lenRes = _readVarint(data, pos, end);
          if (lenRes == null) return;
          final (len, afterLen) = lenRes;
          if (len < 0 || len > end - afterLen) return;
          final slice = Uint8List.sublistView(data, afterLen, afterLen + len);
          pos = afterLen + len;
          yield (fieldNumber: fieldNumber, varint: null, bytes: slice);
        case 3 || 4:
          // Deprecated group wire types: stop safely.
          return;
        case 5:
          if (end - pos < 4) return;
          pos += 4;
        default:
          return;
      }
    }
  }

  static (int, int)? _readVarint(Uint8List data, int start, int end) {
    var result = 0;
    var shift = 0;
    var pos = start;
    while (pos < end && shift < 64) {
      final byte = data[pos++];
      result |= (byte & 0x7f) << shift;
      if ((byte & 0x80) == 0) {
        return (result, pos);
      }
      shift += 7;
    }
    return null;
  }
}

class _SummaryProtoEntry {
  const _SummaryProtoEntry({
    required this.id,
    this.title,
    this.updatedAt,
    this.cwd,
  });

  final String id;
  final String? title;
  final DateTime? updatedAt;
  final String? cwd;
}
