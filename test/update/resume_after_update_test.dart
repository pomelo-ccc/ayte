import 'dart:io';

import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/resume_after_update.dart';
import 'package:baocode/ide/ide_notifications.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/models/model_provider.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:baocode/settings/pages/settings_widgets.dart';
import 'package:baocode/settings/pages/updates_page.dart';
import 'package:baocode/settings/user_settings.dart';
import 'package:baocode/update/update_controller.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../kernel_test.dart' show FakeCli;
import 'update_fakes.dart';

const _gateway = ModelProvider(
  id: 'gw',
  name: 'Gateway',
  protocol: ProviderProtocol.openaiChat,
  baseUrl: 'https://gw.example.com/v1',
  models: [ProviderModel(id: 'gpt-5', contextWindow: 400000)],
);

class _MultiSessionCatalog implements SessionCatalog {
  _MultiSessionCatalog(this.sessions);

  final List<SessionRecord> sessions;

  @override
  Future<List<ProjectRecord>> projects() async => [
    ProjectRecord(path: '/tmp/project', sessions: sessions),
  ];

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async => const [];

  @override
  Future<void> delete(String id) async {}
}

void main() {
  group('ResumeAfterUpdate store & scheduling', () {
    test('captures, reloads, skips expired entries, and buffers pending notice', () async {
      final dir = await Directory.systemTemp.createTemp('ayte-resume-upd');
      addTearDown(() => dir.delete(recursive: true));
      final storePath = p.join(dir.path, ResumeAfterUpdate.fileName);

      var now = DateTime(2026, 11, 26, 16, 0);
      final first = ResumeAfterUpdate(
        store: PreferenceStore.file(storePath),
        enabled: () => true,
        clock: () => now,
      );
      await first.capture([
        UpdateResumeEntry(
          sessionId: 'sess-fresh',
          savedAt: now,
          projectPath: '/tmp/project',
          kernelId: 'antigravity-cli',
          title: 'Active task',
          queuedTexts: const ['记得跑单测'],
          targetVersion: '2.0.9',
        ),
        UpdateResumeEntry(
          sessionId: 'sess-stale',
          savedAt: now.subtract(const Duration(hours: 2)),
          projectPath: '/tmp/project',
        ),
      ]);
      first.dispose();

      // Advance 2 minutes (simulating update install + relaunch).
      now = now.add(const Duration(minutes: 2));
      final second = ResumeAfterUpdate(
        store: PreferenceStore.file(storePath),
        enabled: () => true,
        initialDelay: Duration.zero,
        retryAfter: const Duration(milliseconds: 20),
        clock: () => now,
      );
      addTearDown(second.dispose);

      await second.load();
      // Stale entry (>30m) must be pruned on load; fresh entry kept.
      expect(second.entries.map((e) => e.sessionId), ['sess-fresh']);
      expect(second.entries.single.queuedTexts, ['记得跑单测']);

      final attempts = <String>[];
      second.resume = (entry) async {
        attempts.add(entry.sessionId);
        // Retry once, then resume on second try.
        return attempts.length == 1
            ? UpdateResumeOutcome.retry
            : UpdateResumeOutcome.resumed;
      };

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(attempts, ['sess-fresh', 'sess-fresh']);
      expect(second.entries, isEmpty);

      // No stream listener was attached yet, so pending notice is buffered once.
      final notice = second.takePendingResumedNotice();
      expect(notice.map((e) => e.sessionId), ['sess-fresh']);
      expect(second.takePendingResumedNotice(), isEmpty);

      // Disk file must now be empty so a subsequent launch does not re-resume.
      final third = ResumeAfterUpdate(
        store: PreferenceStore.file(storePath),
        enabled: () => true,
        clock: () => now,
      );
      addTearDown(third.dispose);
      await third.load();
      expect(third.entries, isEmpty);
    });

    test('buildContinuePrompt formats Chinese and English with queued texts', () {
      final entry = UpdateResumeEntry(
        sessionId: 's1',
        savedAt: DateTime(2026, 11, 26),
        queuedTexts: const ['检查一下边界条件', '顺便更新文档'],
      );
      final zh = ResumeAfterUpdate.buildContinuePrompt(entry, isZh: true);
      expect(zh, contains('版本更新重启'));
      expect(zh, contains('- 检查一下边界条件'));
      expect(zh, contains('- 顺便更新文档'));

      final en = ResumeAfterUpdate.buildContinuePrompt(entry, isZh: false);
      expect(en, contains('restarted to finish an update'));
      expect(en, contains('- 检查一下边界条件'));
    });

    test('disabled setting drops loaded entries without resuming', () async {
      final dir = await Directory.systemTemp.createTemp('ayte-resume-off');
      addTearDown(() => dir.delete(recursive: true));
      final storePath = p.join(dir.path, ResumeAfterUpdate.fileName);
      final now = DateTime(2026, 11, 26, 16, 0);

      final saver = ResumeAfterUpdate(
        store: PreferenceStore.file(storePath),
        enabled: () => true,
        clock: () => now,
      );
      await saver.capture([UpdateResumeEntry(sessionId: 's1', savedAt: now)]);
      saver.dispose();

      var called = false;
      final loader = ResumeAfterUpdate(
        store: PreferenceStore.file(storePath),
        enabled: () => false,
        initialDelay: Duration.zero,
        clock: () => now,
      );
      addTearDown(loader.dispose);
      loader.resume = (_) async {
        called = true;
        return UpdateResumeOutcome.resumed;
      };
      await loader.load();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(called, isFalse);
      expect(loader.entries, isEmpty);
    });
  });

  group('Workspace update restart auto-resume end-to-end', () {
    testWidgets('snapshots only running threads and auto-continues them after restart', (
      tester,
    ) async {
      final sharedStore = MemoryPreferenceStore();

      final records = [
        SessionRecord(
          id: 'session-running',
          title: 'Refactor canvas',
          updatedAt: DateTime(2026, 11, 26, 16, 0),
          cwd: '/tmp/project',
          path: '/tmp/project/session-running.jsonl',
        ),
        SessionRecord(
          id: 'session-idle',
          title: 'Already done',
          updatedAt: DateTime(2026, 11, 26, 15, 0),
          cwd: '/tmp/project',
          path: '/tmp/project/session-idle.jsonl',
        ),
        SessionRecord(
          id: 'session-waiting',
          title: 'Waiting approval',
          updatedAt: DateTime(2026, 11, 26, 15, 30),
          cwd: '/tmp/project',
          path: '/tmp/project/session-waiting.jsonl',
        ),
      ];

      KernelDescriptor makeKernel(List<FakeCli> clis) {
        late final KernelDescriptor descriptor;
        descriptor = KernelDescriptor(
          id: 'claude-code',
          label: 'Claude Code',
          icon: Icons.auto_awesome_rounded,
          description: '',
          catalog: _MultiSessionCatalog(records),
          create: (context) => ClaudeCodeKernel(
            descriptor,
            context,
            start: (_) async {
              final cli = FakeCli();
              clis.add(cli);
              return cli;
            },
            readHistory: (_) async => const [],
            providers: ModelProviders.memory(providers: [_gateway]),
          ),
        );
        return descriptor;
      }

      // --- Session 1 (before update restart) ---
      final beforeClis = <FakeCli>[];
      final beforeResumes = ResumeAfterUpdate(
        store: sharedStore,
        enabled: () => true,
        initialDelay: Duration.zero,
      );
      final ws1 = Workspace(
        kernels: [makeKernel(beforeClis)],
        updateResumes: beforeResumes,
      );
      await ws1.load();
      await tester.pump();

      final runningThread = ws1.threads.firstWhere(
        (t) => t.id == 'session-running',
      );
      final idleThread = ws1.threads.firstWhere((t) => t.id == 'session-idle');
      final waitingThread = ws1.threads.firstWhere(
        (t) => t.id == 'session-waiting',
      );

      // Start an active turn on session-running and queue a follow-up message.
      final runningSession = runningThread.session..attach();
      await tester.pump(const Duration(milliseconds: 50));
      runningSession.send(const ComposerMessage(text: 'Implement feature X'));
      await tester.pump(const Duration(milliseconds: 50));
      runningSession.send(const ComposerMessage(text: 'Also run flutter test'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(runningThread.status, ThreadStatus.running);

      // Open idleThread (stays idle).
      final idleSession = idleThread.session..attach();
      await tester.pump(const Duration(milliseconds: 50));
      expect(idleThread.status, ThreadStatus.idle);

      // Put waitingThread into needsInput (permission request waiting on user).
      final waitingSession = waitingThread.session..attach();
      await tester.pump(const Duration(milliseconds: 50));
      waitingSession.send(const ComposerMessage(text: 'Run deploy'));
      await tester.pump(const Duration(milliseconds: 50));
      beforeClis.last.push({
        'type': 'control_request',
        'request_id': 'req-1',
        'request': {
          'subtype': 'can_use_tool',
          'tool_name': 'Bash',
          'input': {'command': 'rm -rf /tmp/x'},
        },
      });
      await tester.pump(const Duration(milliseconds: 50));
      expect(waitingThread.status, ThreadStatus.needsInput);

      // Snapshot right before update exit.
      final savedCount = await ws1.saveInterruptedForUpdate(
        targetVersion: '2.0.9',
      );
      expect(savedCount, 1);

      runningSession.detach();
      idleSession.detach();
      waitingSession.detach();
      ws1.dispose();
      beforeResumes.dispose();

      // --- Session 2 (after update relaunch) ---
      final afterClis = <FakeCli>[];
      final afterResumes = ResumeAfterUpdate(
        store: sharedStore,
        enabled: () => true,
        initialDelay: const Duration(milliseconds: 20),
      );
      final resumedBatches = <List<UpdateResumeEntry>>[];
      final sub = afterResumes.resumed.listen(resumedBatches.add);
      addTearDown(sub.cancel);
      addTearDown(afterResumes.dispose);

      await afterResumes.load();
      expect(afterResumes.entries.map((e) => e.sessionId), ['session-running']);

      final ws2 = Workspace(
        kernels: [makeKernel(afterClis)],
        updateResumes: afterResumes,
      );
      addTearDown(ws2.dispose);
      await ws2.load();
      await tester.pump(const Duration(milliseconds: 80));
      await tester.pump(const Duration(milliseconds: 80));

      // Only session-running should have been auto-resumed, with queued text included.
      expect(resumedBatches, hasLength(1));
      expect(resumedBatches.single.single.sessionId, 'session-running');
      expect(afterClis, hasLength(1));
      expect(afterClis.single.users, hasLength(1));
      final sentPayload = '${afterClis.single.users.single['message']}';
      expect(sentPayload, contains('restarted to finish an update'));
      expect(sentPayload, contains('Also run flutter test'));
      expect(afterResumes.entries, isEmpty);
    });
  });

  group('UpdatesSettingsPage & UpdateController integration', () {
    late Directory data;
    late UserSettings settings;

    setUp(() async {
      data = await Directory.systemTemp.createTemp('ayte-upd-toggle');
      settings = UserSettings(p.join(data.path, 'settings.json'));
      await settings.load();
    });

    tearDown(() async {
      settings.dispose();
      await data.delete(recursive: true);
    });

    testWidgets('toggle persists update.resumeInterruptedSessions (default true unwritten)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(900, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: UpdatesSettingsPage(settings: settings)),
        ),
      );
      await tester.pump();

      Future<void> settle(bool Function() done) async {
        for (var i = 0; i < 100 && !done(); i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
        expect(done(), isTrue);
        await tester.pump();
      }

      final row = find.byType(SettingsSwitchRow);
      final toggle = find.byType(SettingsSwitch);
      expect(row, findsOneWidget);
      expect(tester.widget<SettingsSwitchRow>(row).value, isTrue);
      expect(
        settings.values.containsKey(ResumeAfterUpdateSetting.settingKey),
        isFalse,
      );

      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pump();
      await settle(
        () => settings[ResumeAfterUpdateSetting.settingKey] == false,
      );
      expect(tester.widget<SettingsSwitchRow>(row).value, isFalse);

      await tester.tap(toggle);
      await tester.pump();
      await settle(
        () => !settings.values.containsKey(ResumeAfterUpdateSetting.settingKey),
      );
      expect(tester.widget<SettingsSwitchRow>(row).value, isTrue);
    });

    testWidgets('UpdateController.listen surfaces info toast when sessions auto-resume', (
      tester,
    ) async {
      final service = serviceOf(FakeBackend(manifestOf('1.0.0')));
      addTearDown(service.dispose);
      final controller = UpdateController(
        service: service,
        quit: () async {},
        openUrl: (_) async {},
      );
      final notifications = IdeNotifications();
      addTearDown(notifications.dispose);

      final prev = ResumeAfterUpdate.current;
      final fakeResumes = ResumeAfterUpdate(
        enabled: () => true,
        initialDelay: Duration.zero,
      );
      ResumeAfterUpdate.current = fakeResumes;
      addTearDown(() {
        ResumeAfterUpdate.current = prev;
        fakeResumes.dispose();
      });

      final stop = controller.listen(notifications, () => englishLocalizations);
      addTearDown(stop);

      await fakeResumes.capture([
        UpdateResumeEntry(sessionId: 's1', savedAt: DateTime.now()),
        UpdateResumeEntry(sessionId: 's2', savedAt: DateTime.now()),
      ]);
      fakeResumes.resume = (_) async => UpdateResumeOutcome.resumed;
      await tester.pump(const Duration(milliseconds: 40));

      expect(
        notifications.notifications.any(
          (n) => n.message.contains('automatically resumed 2 interrupted'),
        ),
        isTrue,
      );
    });
  });
}
