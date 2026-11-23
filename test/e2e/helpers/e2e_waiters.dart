import 'dart:async';
import 'dart:io';

import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Polls [condition] until it returns `true` or throws [TestFailure] on timeout.
Future<void> waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
  Duration poll = const Duration(milliseconds: 20),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(reason ?? 'Condition not met within ${timeout.inMilliseconds}ms');
    }
    await Future<void>.delayed(poll);
  }
}

/// Polls an async [condition] until it returns `true` or throws on timeout.
Future<void> waitUntilAsync(
  Future<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 10),
  Duration poll = const Duration(milliseconds: 25),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(
        reason ?? 'Async condition not met within ${timeout.inMilliseconds}ms',
      );
    }
    await Future<void>.delayed(poll);
  }
}

/// Waits for the next [KernelEvent] of type [T] matching optional [where].
Future<T> waitForKernelEvent<T extends KernelEvent>(
  Stream<KernelEvent> events, {
  bool Function(T event)? where,
  Duration timeout = const Duration(seconds: 10),
}) => events
    .where((e) => e is T && (where == null || where(e)))
    .cast<T>()
    .first
    .timeout(timeout);

/// Waits for the next raw transport message matching [predicate].
Future<Map<String, Object?>> waitForTransportMessage(
  Stream<Map<String, Object?>> messages,
  bool Function(Map<String, Object?> message) predicate, {
  Duration timeout = const Duration(seconds: 10),
}) => messages.firstWhere(predicate).timeout(timeout);

/// Waits for [thread] to receive a `sessionId` and finish streaming.
Future<void> settleAgentTurn(
  AgentThread thread, {
  Duration timeout = const Duration(seconds: 10),
}) => waitUntil(
  () => thread.session.sessionId != null && !thread.session.isStreaming,
  timeout: timeout,
  reason: 'AgentThread turn did not settle in ${timeout.inMilliseconds}ms',
);

/// Initializes a temporary git repository with an initial commit under [parent].
Future<Directory> initTempGitRepo(
  Directory parent, {
  String name = 'repo',
  Map<String, String> files = const {'README.md': '# E2E Repo\n'},
}) async {
  final dir = Directory(p.join(parent.path, name))..createSync(recursive: true);
  for (final MapEntry(:key, :value) in files.entries) {
    final file = File(p.join(dir.path, key));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(value);
  }
  await _git(dir.path, ['init']);
  await _git(dir.path, ['config', 'user.email', 'e2e@ayte.dev']);
  await _git(dir.path, ['config', 'user.name', 'Ayte E2E']);
  await _git(dir.path, ['add', '.']);
  await _git(dir.path, ['commit', '-m', 'Initial commit']);
  return dir;
}

Future<void> _git(String cwd, List<String> args) async {
  final res = await Process.run('git', args, workingDirectory: cwd);
  if (res.exitCode != 0) {
    throw ProcessException('git', args, '${res.stderr}', res.exitCode);
  }
}

/// Parsed diagnostic line from `flutter analyze` / `dart analyze`.
class AnalyzeIssue {
  const AnalyzeIssue({
    required this.severity,
    required this.message,
    required this.file,
    required this.line,
    required this.column,
    required this.code,
  });

  final String severity;
  final String message;
  final String file;
  final int line;
  final int column;
  final String code;

  String get normalizedFile => file.replaceAll('\\', '/');
}

/// Result of a batched analyzer invocation.
class AnalyzeResult {
  const AnalyzeResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.issues,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
  final List<AnalyzeIssue> issues;

  List<AnalyzeIssue> issuesFor(String relativePath) {
    final norm = relativePath.replaceAll('\\', '/');
    return [
      for (final issue in issues)
        if (issue.normalizedFile == norm ||
            issue.normalizedFile.endsWith('/$norm'))
          issue,
    ];
  }
}

/// Batched static analysis runner with a per-target-set shared [Future] cache.
abstract final class AnalyzeHelper {
  static final Map<String, Future<AnalyzeResult>> _cache = {};

  /// Resolves the repository root (`D:\Ayte\ayte-src` or current project root).
  static String findRepoRoot() {
    var dir = Directory.current;
    for (var i = 0; i < 6; i++) {
      final pubspec = File(p.join(dir.path, 'pubspec.yaml'));
      final libDir = Directory(p.join(dir.path, 'lib'));
      if (pubspec.existsSync() && libDir.existsSync()) {
        return dir.path;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return Directory.current.path;
  }

  /// Runs `flutter analyze --no-pub [targets]` once per distinct target key
  /// and caches the parsed [AnalyzeResult].
  static Future<AnalyzeResult> runFlutterAnalyze({
    List<String> targets = const [],
    String? workingDirectory,
    bool forceRefresh = false,
  }) {
    final root = workingDirectory ?? findRepoRoot();
    final key = 'flutter|$root|${targets.join(',')}';
    if (!forceRefresh && _cache.containsKey(key)) {
      return _cache[key]!;
    }
    final future = _execute(
      executable: 'flutter',
      args: ['analyze', '--no-pub', ...targets],
      workingDirectory: root,
    );
    _cache[key] = future;
    return future;
  }

  static Future<AnalyzeResult> _execute({
    required String executable,
    required List<String> args,
    required String workingDirectory,
  }) async {
    final result = await Process.run(
      executable,
      args,
      workingDirectory: workingDirectory,
      runInShell: Platform.isWindows,
    );
    final stdoutText = '${result.stdout}';
    final stderrText = '${result.stderr}';
    return AnalyzeResult(
      exitCode: result.exitCode,
      stdout: stdoutText,
      stderr: stderrText,
      issues: parseOutput('$stdoutText\n$stderrText'),
    );
  }

  static final _issuePattern = RegExp(
    r'^\s*(error|warning|info)\s*-\s*(.+?)\s*-\s*(.+?):(\d+):(\d+)\s*-\s*(\S+)\s*$',
  );

  /// Parses `flutter analyze` / `dart analyze` diagnostic lines.
  static List<AnalyzeIssue> parseOutput(String output) {
    final issues = <AnalyzeIssue>[];
    for (final line in output.split(RegExp(r'\r?\n'))) {
      final m = _issuePattern.firstMatch(line);
      if (m == null) continue;
      issues.add(
        AnalyzeIssue(
          severity: m[1]!,
          message: m[2]!,
          file: m[3]!,
          line: int.tryParse(m[4]!) ?? 0,
          column: int.tryParse(m[5]!) ?? 0,
          code: m[6]!,
        ),
      );
    }
    return issues;
  }
}
