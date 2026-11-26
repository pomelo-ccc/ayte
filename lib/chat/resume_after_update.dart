import 'dart:async';

import 'package:flutter/foundation.dart';

import '../workspace/preference_store.dart';

/// Whether sessions that were actively running when Ayte restarted to install
/// an update automatically continue once the new version launches
/// (`update.resumeInterruptedSessions` in settings.json; enabled by default).
abstract final class ResumeAfterUpdateSetting {
  static const settingKey = 'update.resumeInterruptedSessions';

  /// Enabled unless explicitly set to `false`.
  static bool enabled(Object? setting) => setting != false;

  /// The setting as it is now, what notifies changes, and what persists it;
  /// `main.dart` points them at `settings.json`.
  static bool Function() current = () => true;
  static Listenable? changes;
  static void Function(bool on)? write;
}

/// Snapshot of an active agent session interrupted by an update restart.
@immutable
class UpdateResumeEntry {
  const UpdateResumeEntry({
    required this.sessionId,
    required this.savedAt,
    this.projectPath = '',
    this.kernelId = '',
    this.title = '',
    this.queuedTexts = const [],
    this.targetVersion,
  });

  final String sessionId;
  final DateTime savedAt;
  final String projectPath;
  final String kernelId;
  final String title;
  final List<String> queuedTexts;
  final String? targetVersion;

  Map<String, Object?> toJson() => {
    'session': sessionId,
    'savedAt': savedAt.toUtc().toIso8601String(),
    if (projectPath.isNotEmpty) 'projectPath': projectPath,
    if (kernelId.isNotEmpty) 'kernelId': kernelId,
    if (title.isNotEmpty) 'title': title,
    if (queuedTexts.isNotEmpty) 'queuedTexts': queuedTexts,
    if (targetVersion != null && targetVersion!.isNotEmpty)
      'targetVersion': targetVersion,
  };

  static UpdateResumeEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final sessionId = json['session'];
    final savedAtRaw = json['savedAt'];
    if (sessionId is! String || sessionId.isEmpty || savedAtRaw is! String) {
      return null;
    }
    final parsedAt = DateTime.tryParse(savedAtRaw);
    if (parsedAt == null) return null;
    final rawQueued = json['queuedTexts'];
    final queued = <String>[
      if (rawQueued is List)
        for (final item in rawQueued)
          if (item is String && item.trim().isNotEmpty) item.trim(),
    ];
    return UpdateResumeEntry(
      sessionId: sessionId,
      savedAt: parsedAt.toLocal(),
      projectPath: json['projectPath'] is String
          ? json['projectPath'] as String
          : '',
      kernelId: json['kernelId'] is String ? json['kernelId'] as String : '',
      title: json['title'] is String ? json['title'] as String : '',
      queuedTexts: queued,
      targetVersion: json['targetVersion'] is String
          ? json['targetVersion'] as String
          : null,
    );
  }
}

/// Result of attempting to auto-continue one interrupted session after restart.
enum UpdateResumeOutcome {
  /// Continuation message was sent to the session.
  resumed,

  /// Session no longer needs continuation (already running, waiting on user,
  /// archived/deleted, or feature disabled).
  skipped,

  /// Session is not ready yet (e.g. remote project still listing or history
  /// still loading) and should be retried shortly.
  retry,
}

typedef UpdateResumeAgent =
    Future<UpdateResumeOutcome> Function(UpdateResumeEntry entry);

/// Persists sessions that were actively running when Ayte quit for an update
/// and automatically sends them a continuation turn once the updated app
/// launches and finishes listing workspace threads.
class ResumeAfterUpdate extends ChangeNotifier {
  ResumeAfterUpdate({
    this.store,
    bool Function()? enabled,
    Listenable? enabledChanges,
    this.maxAge = const Duration(minutes: 30),
    this.initialDelay = const Duration(milliseconds: 600),
    this.retryAfter = const Duration(seconds: 5),
    this.attempts = 6,
    DateTime Function()? clock,
  }) : _enabled = enabled ?? (() => ResumeAfterUpdateSetting.current()),
       _enabledChanges = enabledChanges ?? ResumeAfterUpdateSetting.changes,
       _clock = clock ?? DateTime.now {
    _enabledChanges?.addListener(_settingChanged);
  }

  /// App-wide singleton; `main.dart` wires it to `resume_after_update.json`.
  static ResumeAfterUpdate current = ResumeAfterUpdate();

  /// File name inside `DataDirectory.current.stateDir`.
  static const fileName = 'resume_after_update.json';

  final PreferenceStore? store;
  final bool Function() _enabled;
  final Listenable? _enabledChanges;
  final DateTime Function() _clock;

  /// Snapshots older than [maxAge] are discarded on launch so a long-delayed
  /// reopen never unexpectedly triggers stale work.
  final Duration maxAge;

  /// Brief settle delay after workspace load before dispatching resumes.
  final Duration initialDelay;

  /// Delay between retries when a session is still loading (e.g. remote SSH).
  final Duration retryAfter;
  final int attempts;

  bool get enabled => _enabled();

  UpdateResumeAgent? get resume => _resume;
  UpdateResumeAgent? _resume;
  set resume(UpdateResumeAgent? value) {
    _resume = value;
    _arm(delay: initialDelay);
  }

  final Map<String, UpdateResumeEntry> _entries = {};
  final Map<String, int> _failed = {};
  final List<UpdateResumeEntry> _pendingNotice = [];
  final StreamController<List<UpdateResumeEntry>> _resumed =
      StreamController<List<UpdateResumeEntry>>.broadcast();

  Timer? _timer;
  bool _firing = false;
  bool _disposed = false;

  /// Pending interrupted sessions still awaiting continuation.
  List<UpdateResumeEntry> get entries =>
      _entries.values.toList()..sort((a, b) => a.savedAt.compareTo(b.savedAt));

  /// Emits each batch of sessions automatically resumed after an update.
  Stream<List<UpdateResumeEntry>> get resumed => _resumed.stream;

  /// Returns and clears any resumed batch that completed before a listener
  /// attached (e.g. before the main window's notification host mounted).
  List<UpdateResumeEntry> takePendingResumedNotice() {
    if (_pendingNotice.isEmpty) return const [];
    final out = List<UpdateResumeEntry>.unmodifiable(_pendingNotice);
    _pendingNotice.clear();
    return out;
  }

  /// Records [entries] to disk right before quitting to install an update.
  /// Awaits persistence so the file is flushed before the app exits.
  Future<void> capture(Iterable<UpdateResumeEntry> entries) async {
    _entries.clear();
    _failed.clear();
    if (enabled) {
      for (final entry in entries) {
        if (entry.sessionId.isNotEmpty) {
          _entries[entry.sessionId] = entry;
        }
      }
    }
    await _writeNow();
    if (!_disposed) notifyListeners();
  }

  /// Clears any pending update-resume state on disk and in memory.
  Future<void> clear() async {
    _timer?.cancel();
    _timer = null;
    final had = _entries.isNotEmpty;
    _entries.clear();
    _failed.clear();
    await _writeNow();
    if (had && !_disposed) notifyListeners();
  }

  /// Loads persisted interrupted sessions from disk, dropping expired ones.
  Future<void> load() async {
    final kept = await store?.read() ?? const {};
    if (_disposed) return;
    final now = _clock();
    var pruned = false;
    final loaded = <UpdateResumeEntry>[];
    for (final raw in switch (kept['entries']) {
      final List<Object?> list => list,
      _ => const <Object?>[],
    }) {
      final entry = UpdateResumeEntry.fromJson(raw);
      if (entry == null) {
        pruned = true;
        continue;
      }
      final age = now.difference(entry.savedAt);
      if (age > maxAge || age < -const Duration(minutes: 5)) {
        pruned = true;
        continue;
      }
      loaded.add(entry);
    }
    if (!enabled) {
      if (loaded.isNotEmpty || pruned) {
        _entries.clear();
        _failed.clear();
        await _writeNow();
      }
      return;
    }
    for (final entry in loaded) {
      _entries.putIfAbsent(entry.sessionId, () => entry);
    }
    if (pruned) {
      await _writeNow();
    }
    _arm(delay: initialDelay);
    if (!_disposed) notifyListeners();
  }

  /// Prompts an early retry when newly discovered threads arrive (for example
  /// after an SSH host finishes listing its remote sessions).
  void threadsUpdated() {
    if (_disposed || _firing || _entries.isEmpty || _resume == null) return;
    _arm(delay: const Duration(milliseconds: 250));
  }

  void _settingChanged() {
    if (_disposed) return;
    if (!enabled && _entries.isNotEmpty) {
      unawaited(clear());
      return;
    }
    _arm(delay: Duration.zero);
    notifyListeners();
  }

  Future<void> _writeNow() async {
    final store = this.store;
    if (store == null) return;
    try {
      await store.write({
        'entries': [for (final entry in entries) entry.toJson()],
      });
    } on Object catch (error) {
      debugPrint('Update resume entries not kept: $error');
    }
  }

  void _arm({required Duration delay}) {
    _timer?.cancel();
    _timer = null;
    if (_disposed || _firing || _entries.isEmpty) return;
    if (!enabled || _resume == null) return;
    _timer = Timer(delay.isNegative ? Duration.zero : delay, _fire);
  }

  Future<void> _fire() async {
    _timer = null;
    if (_disposed || _firing) return;
    final resume = _resume;
    if (resume == null) return;
    if (!enabled) {
      await clear();
      return;
    }
    _firing = true;
    var changed = false;
    final resumedNow = <UpdateResumeEntry>[];
    try {
      final snapshot = entries;
      final now = _clock();
      for (final entry in snapshot) {
        if (_disposed) return;
        if (now.difference(entry.savedAt) > maxAge) {
          _entries.remove(entry.sessionId);
          _failed.remove(entry.sessionId);
          changed = true;
          continue;
        }
        UpdateResumeOutcome outcome;
        try {
          outcome = await resume(entry);
        } on Object catch (error) {
          debugPrint('Not continued after update restart: $error');
          outcome = UpdateResumeOutcome.retry;
        }
        if (_disposed) return;
        if (!identical(_entries[entry.sessionId], entry)) continue;
        switch (outcome) {
          case UpdateResumeOutcome.resumed:
            _entries.remove(entry.sessionId);
            _failed.remove(entry.sessionId);
            resumedNow.add(entry);
            changed = true;
          case UpdateResumeOutcome.skipped:
            _entries.remove(entry.sessionId);
            _failed.remove(entry.sessionId);
            changed = true;
          case UpdateResumeOutcome.retry:
            final count = (_failed[entry.sessionId] ?? 0) + 1;
            if (count >= attempts) {
              _entries.remove(entry.sessionId);
              _failed.remove(entry.sessionId);
              changed = true;
            } else {
              _failed[entry.sessionId] = count;
            }
        }
      }
    } finally {
      _firing = false;
    }
    if (changed) {
      await _writeNow();
      if (!_disposed) notifyListeners();
    }
    if (resumedNow.isNotEmpty && !_disposed) {
      if (_resumed.hasListener) {
        _resumed.add(List<UpdateResumeEntry>.unmodifiable(resumedNow));
      } else {
        _pendingNotice.addAll(resumedNow);
      }
    }
    if (_entries.isNotEmpty) {
      _arm(delay: retryAfter);
    }
  }

  /// Builds the localized continuation message sent to an interrupted session.
  static String buildContinuePrompt(
    UpdateResumeEntry entry, {
    required bool isZh,
  }) {
    final base = isZh
        ? 'Ayte 刚因版本更新重启，上一轮任务在此处被中断。请检查当前状态与已有改动，从中断处继续完成剩余任务。'
        : 'Ayte just restarted to finish an update, which interrupted the previous turn. Check the current workspace state and continue the remaining task from where you left off.';
    if (entry.queuedTexts.isEmpty) return base;
    final header = isZh
        ? '\n\n重启前队列中还有以下补充指令，请一并处理：'
        : '\n\nThe following queued user instructions were pending before restart—please handle them as well:';
    final bullets = entry.queuedTexts.map((t) => '\n- $t').join();
    return '$base$header$bullets';
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _enabledChanges?.removeListener(_settingChanged);
    _timer?.cancel();
    unawaited(_resumed.close());
    super.dispose();
  }
}
