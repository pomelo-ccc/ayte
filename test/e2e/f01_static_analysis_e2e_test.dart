import 'dart:io';

import 'package:baocode/kernel/claude_code/claude_core_setting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'helpers/e2e_env.dart';
import 'helpers/e2e_waiters.dart';

/// F1 — Baseline Static Analysis Cleanup (`test/` & `tool/`).
///
/// Requirements from PROJECT.md § Feature Inventory (F1) & survey_2 (GAP-SHARED-04):
/// - Resolve all 20 pre-existing `flutter analyze --no-pub` errors across the 8
///   broken `test/` and `tool/` files (`ClaudeCore.cli`, missing
///   `process_transport.dart` / `process_transport_io.dart`, missing
///   `claude_resets.dart` references) so `flutter analyze --no-pub` exits 0
///   across the entire repository.
void main() {
  const f1BrokenTestFiles = [
    'test/e2e_review_real_test.dart',
    'test/kernel/bash_exe_windows_e2e_test.dart',
    'test/remote/remote_project_test.dart',
    'test/workspace/session_tools_e2e_test.dart',
    'test/settings/models_page_test.dart',
  ];

  const f1BrokenToolFiles = [
    'tool/perf/perf_app.dart',
    'tool/showcase/showcase_app.dart',
    'tool/windows_close_smoke.dart',
  ];

  const f1AllTargets = [...f1BrokenTestFiles, ...f1BrokenToolFiles];

  group('F1 Tier 1 — Static Analysis & ClaudeCore Contract', () {
    test(
      'F1-T1-01: whole-repo flutter analyze --no-pub exits 0 with No issues found',
      () async {
        final result = await AnalyzeHelper.runFlutterAnalyze();
        expect(
          result.exitCode,
          0,
          reason:
              'Whole-repo flutter analyze must pass with 0 errors.\n'
              '${result.stdout}\n${result.stderr}',
        );
        expect(result.stdout, contains('No issues found!'));
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test('F1-T1-02: ClaudeCore enum exposes only antigravity and builtin', () {
      expect(ClaudeCore.values, [ClaudeCore.antigravity, ClaudeCore.builtin]);
      expect(ClaudeCore.parse('antigravity'), ClaudeCore.antigravity);
      expect(ClaudeCore.parse('builtin'), ClaudeCore.builtin);
    });

    test(
      'F1-T1-03: all 5 repaired F1 test files pass flutter analyze --no-pub',
      () async {
        final result = await AnalyzeHelper.runFlutterAnalyze(
          targets: f1AllTargets,
        );
        for (final path in f1BrokenTestFiles) {
          expect(
            result.issuesFor(path),
            isEmpty,
            reason: 'Expected zero analyzer issues in $path\n${result.stdout}',
          );
        }
        expect(result.exitCode, 0, reason: result.stdout);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'F1-T1-04: all 3 repaired F1 tool files pass flutter analyze --no-pub',
      () async {
        final result = await AnalyzeHelper.runFlutterAnalyze(
          targets: f1AllTargets,
        );
        for (final path in f1BrokenToolFiles) {
          expect(
            result.issuesFor(path),
            isEmpty,
            reason: 'Expected zero analyzer issues in $path\n${result.stdout}',
          );
        }
        expect(result.exitCode, 0, reason: result.stdout);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'F1-T1-05: test/e2e directory passes flutter analyze --no-pub cleanly',
      () async {
        final result = await AnalyzeHelper.runFlutterAnalyze(
          targets: const ['test/e2e'],
        );
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(result.stdout, contains('No issues found!'));
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });

  group('F1 Tier 2 — Boundaries, Stale Symbol Scan & Regression', () {
    test(
      'F1-T2-01: ClaudeCore.parse handles removed cli, empty, null and non-string safely',
      () {
        E2eSandbox.create();
        ClaudeCore.antigravityInstalled = () => false;
        expect(ClaudeCore.parse('cli'), ClaudeCore.builtin);
        expect(ClaudeCore.parse(''), ClaudeCore.builtin);
        expect(ClaudeCore.parse(null), ClaudeCore.builtin);
        expect(ClaudeCore.parse(123), ClaudeCore.builtin);

        ClaudeCore.antigravityInstalled = () => true;
        expect(ClaudeCore.parse('cli'), ClaudeCore.antigravity);
        expect(ClaudeCore.parse(null), ClaudeCore.antigravity);
      },
    );

    test(
      'F1-T2-02: repaired F1 files contain no stale references to deleted APIs',
      () {
        final root = AnalyzeHelper.findRepoRoot();
        const bannedTokens = [
          'ClaudeCore.cli',
          'process_transport.dart',
          'process_transport_io.dart',
          'claude_resets.dart',
        ];
        for (final rel in f1AllTargets) {
          final file = File(p.join(root, rel));
          expect(file.existsSync(), isTrue, reason: 'Missing file $rel');
          final content = file.readAsStringSync();
          for (final token in bannedTokens) {
            expect(
              content,
              isNot(contains(token)),
              reason: '$rel still contains stale reference "$token"',
            );
          }
        }
      },
    );

    test(
      'F1-T2-03: lib/ passes flutter analyze --no-pub with zero errors',
      () async {
        final result = await AnalyzeHelper.runFlutterAnalyze(
          targets: const ['lib'],
        );
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'F1-T2-04: repaired test/settings/models_page_test.dart executes and passes',
      () async {
        final root = AnalyzeHelper.findRepoRoot();
        final res = await Process.run(
          'flutter',
          const ['test', 'test/settings/models_page_test.dart'],
          workingDirectory: root,
          runInShell: Platform.isWindows,
        );
        expect(
          res.exitCode,
          0,
          reason:
              'models_page_test.dart must compile and pass:\n'
              '${res.stdout}\n${res.stderr}',
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'F1-T2-05: baseline uncommitted test files pass flutter analyze --no-pub',
      () async {
        final result = await AnalyzeHelper.runFlutterAnalyze(
          targets: const [
            'test/kernel/antigravity_commands_test.dart',
            'test/tasks/task_queue_and_acp_test.dart',
          ],
        );
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}
