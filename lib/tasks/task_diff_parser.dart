import 'package:flutter/foundation.dart';

/// File-level change status extracted from a unified git diff.
enum TaskDiffFileStatus { added, modified, deleted, renamed }

/// Kind of a single line inside a unified diff hunk.
enum TaskDiffLineKind { context, added, removed, meta }

/// One parsed line inside a [TaskDiffHunk] with 1-based line numbers.
@immutable
class TaskDiffLine {
  const TaskDiffLine({
    required this.kind,
    required this.text,
    this.oldLine,
    this.newLine,
  });

  final TaskDiffLineKind kind;
  final String text;
  final int? oldLine;
  final int? newLine;
}

/// One aligned row for side-by-side diff viewing.
@immutable
class TaskDiffSplitRow {
  const TaskDiffSplitRow({this.left, this.right});

  final TaskDiffLine? left;
  final TaskDiffLine? right;
}

/// One `@@ -old +new @@` hunk belonging to a [TaskDiffFile].
@immutable
class TaskDiffHunk {
  const TaskDiffHunk({
    required this.header,
    required this.oldStart,
    required this.newStart,
    required this.lines,
  });

  final String header;
  final int oldStart;
  final int newStart;
  final List<TaskDiffLine> lines;

  /// Pairs consecutive removed (`-`) and added (`+`) lines for side-by-side display.
  List<TaskDiffSplitRow> toSplitRows() {
    final rows = <TaskDiffSplitRow>[];
    var i = 0;
    while (i < lines.length) {
      final line = lines[i];
      if (line.kind == TaskDiffLineKind.context ||
          line.kind == TaskDiffLineKind.meta) {
        rows.add(TaskDiffSplitRow(left: line, right: line));
        i++;
        continue;
      }
      final removed = <TaskDiffLine>[];
      final added = <TaskDiffLine>[];
      while (i < lines.length && lines[i].kind == TaskDiffLineKind.removed) {
        removed.add(lines[i++]);
      }
      while (i < lines.length && lines[i].kind == TaskDiffLineKind.added) {
        added.add(lines[i++]);
      }
      final count = removed.length > added.length
          ? removed.length
          : added.length;
      for (var k = 0; k < count; k++) {
        rows.add(
          TaskDiffSplitRow(
            left: k < removed.length ? removed[k] : null,
            right: k < added.length ? added[k] : null,
          ),
        );
      }
    }
    return rows;
  }
}

/// Parsed diff for a single file from a unified `git diff` output.
@immutable
class TaskDiffFile {
  const TaskDiffFile({
    required this.path,
    this.oldPath,
    required this.status,
    required this.added,
    required this.removed,
    required this.hunks,
    this.isBinary = false,
  });

  final String path;
  final String? oldPath;
  final TaskDiffFileStatus status;
  final int added;
  final int removed;
  final List<TaskDiffHunk> hunks;
  final bool isBinary;

  String get statusBadge => switch (status) {
    TaskDiffFileStatus.added => 'A',
    TaskDiffFileStatus.modified => 'M',
    TaskDiffFileStatus.deleted => 'D',
    TaskDiffFileStatus.renamed => 'R',
  };
}

/// Parses standard unified `git diff` text into structured [TaskDiffFile]s.
abstract final class TaskDiffParser {
  static final _gitHeaderRe = RegExp(
    r'^diff --git (?:"a/(.+?)"|a/(.+?)) (?:"b/(.+?)"|b/(.+?))$',
  );
  static final _hunkHeaderRe = RegExp(
    r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@',
  );

  static ({int files, int added, int removed}) summarize(
    List<TaskDiffFile> parsed,
  ) {
    var added = 0;
    var removed = 0;
    for (final f in parsed) {
      added += f.added;
      removed += f.removed;
    }
    return (files: parsed.length, added: added, removed: removed);
  }

  static List<TaskDiffFile> parse(String unifiedDiff) {
    if (unifiedDiff.trim().isEmpty) return const [];
    final rawLines = unifiedDiff.replaceAll('\r\n', '\n').split('\n');
    final files = <TaskDiffFile>[];

    String? currentPath;
    String? oldPath;
    var status = TaskDiffFileStatus.modified;
    var isBinary = false;
    var added = 0;
    var removed = 0;
    var hunks = <TaskDiffHunk>[];

    String? hunkHeader;
    var hunkOldStart = 0;
    var hunkNewStart = 0;
    var oldLine = 0;
    var newLine = 0;
    var hunkLines = <TaskDiffLine>[];

    void flushHunk() {
      if (hunkHeader == null) return;
      hunks.add(
        TaskDiffHunk(
          header: hunkHeader!,
          oldStart: hunkOldStart,
          newStart: hunkNewStart,
          lines: List.unmodifiable(hunkLines),
        ),
      );
      hunkHeader = null;
      hunkLines = [];
    }

    void flushFile() {
      flushHunk();
      if (currentPath == null) return;
      files.add(
        TaskDiffFile(
          path: currentPath!,
          oldPath: oldPath,
          status: status,
          added: added,
          removed: removed,
          hunks: List.unmodifiable(hunks),
          isBinary: isBinary,
        ),
      );
      currentPath = null;
      oldPath = null;
      status = TaskDiffFileStatus.modified;
      isBinary = false;
      added = 0;
      removed = 0;
      hunks = [];
    }

    String unescapeGitPath(String raw) {
      if (!raw.contains(r'\')) return raw;
      return raw
          .replaceAll(r'\\', r'\')
          .replaceAll(r'\"', '"')
          .replaceAll(r'\t', '\t');
    }

    for (final raw in rawLines) {
      if (raw.startsWith('diff --git ')) {
        flushFile();
        final match = _gitHeaderRe.firstMatch(raw);
        if (match != null) {
          final aPath = unescapeGitPath(match.group(1) ?? match.group(2) ?? '');
          final bPath = unescapeGitPath(match.group(3) ?? match.group(4) ?? '');
          currentPath = bPath.isNotEmpty ? bPath : aPath;
          if (aPath.isNotEmpty && bPath.isNotEmpty && aPath != bPath) {
            oldPath = aPath;
          }
        } else {
          final parts = raw.substring('diff --git '.length).split(' ');
          currentPath = parts.isNotEmpty
              ? parts.last.replaceFirst(RegExp(r'^b/'), '')
              : 'unknown';
        }
        continue;
      }

      if (currentPath == null) continue;

      if (hunkHeader == null) {
        if (raw.startsWith('new file mode')) {
          status = TaskDiffFileStatus.added;
          continue;
        }
        if (raw.startsWith('deleted file mode')) {
          status = TaskDiffFileStatus.deleted;
          continue;
        }
        if (raw.startsWith('rename from ')) {
          status = TaskDiffFileStatus.renamed;
          oldPath = unescapeGitPath(raw.substring('rename from '.length));
          continue;
        }
        if (raw.startsWith('rename to ')) {
          status = TaskDiffFileStatus.renamed;
          currentPath = unescapeGitPath(raw.substring('rename to '.length));
          continue;
        }
        if (raw.startsWith('Binary files ') || raw.startsWith('GIT binary patch')) {
          isBinary = true;
          continue;
        }
      }

      if (raw.startsWith('@@ ')) {
        final match = _hunkHeaderRe.firstMatch(raw);
        if (match != null) {
          flushHunk();
          hunkHeader = raw;
          hunkOldStart = int.tryParse(match.group(1) ?? '0') ?? 0;
          hunkNewStart = int.tryParse(match.group(2) ?? '0') ?? 0;
          oldLine = hunkOldStart;
          newLine = hunkNewStart;
          continue;
        }
      }

      if (hunkHeader == null) {
        // Skip header metadata lines (`index ...`, `--- a/...`, `+++ b/...`).
        continue;
      }

      if (raw.startsWith('+')) {
        added++;
        hunkLines.add(
          TaskDiffLine(
            kind: TaskDiffLineKind.added,
            text: raw.substring(1),
            newLine: newLine++,
          ),
        );
      } else if (raw.startsWith('-')) {
        removed++;
        hunkLines.add(
          TaskDiffLine(
            kind: TaskDiffLineKind.removed,
            text: raw.substring(1),
            oldLine: oldLine++,
          ),
        );
      } else if (raw.startsWith(' ')) {
        hunkLines.add(
          TaskDiffLine(
            kind: TaskDiffLineKind.context,
            text: raw.substring(1),
            oldLine: oldLine++,
            newLine: newLine++,
          ),
        );
      } else if (raw.startsWith(r'\ No newline at end of file')) {
        hunkLines.add(TaskDiffLine(kind: TaskDiffLineKind.meta, text: raw));
      } else if (raw.startsWith('... (truncated)')) {
        hunkLines.add(TaskDiffLine(kind: TaskDiffLineKind.meta, text: raw));
      }
    }

    flushFile();
    return files;
  }
}
