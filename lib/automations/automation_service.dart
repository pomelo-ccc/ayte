import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../acp/acp_agent_service.dart';
import '../chat/chat_models.dart' show ToolKind;
import '../kernel/claude_code/claude_sdk_tools.dart';
import '../platform/data_dir.dart';
import '../tasks/task_queue_service.dart';
import 'cron_parser.dart';

class AutomationRunRecord {
  AutomationRunRecord({
    required this.startedAt,
    required this.ok,
    required this.summary,
  });

  final DateTime startedAt;
  final bool ok;
  final String summary;

  Map<String, Object?> toJson() => {
    'startedAt': startedAt.toIso8601String(),
    'ok': ok,
    'summary': summary,
  };

  static AutomationRunRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final at = DateTime.tryParse(raw['startedAt'] as String? ?? '');
    if (at == null) return null;
    return AutomationRunRecord(
      startedAt: at,
      ok: raw['ok'] == true,
      summary: raw['summary'] as String? ?? '',
    );
  }
}

class AutomationRule {
  AutomationRule({
    required this.id,
    required this.name,
    required this.prompt,
    required this.cwd,
    required this.cronExpression,
    this.agentId = 'agy',
    this.enabled = true,
    this.useWorktree = false,
    this.lastRunAt,
    this.running = false,
    List<AutomationRunRecord>? history,
  }) : history = history ?? [];

  final String id;
  String name;
  String prompt;
  String cwd;
  String cronExpression;
  String agentId;
  bool enabled;
  bool useWorktree;
  DateTime? lastRunAt;
  bool running;
  final List<AutomationRunRecord> history;

  DateTime? get nextRun {
    if (!enabled) return null;
    final schedule = CronSchedule.tryParse(cronExpression);
    return schedule?.nextAfter(DateTime.now());
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'prompt': prompt,
    'cwd': cwd,
    'cronExpression': cronExpression,
    'agentId': agentId,
    'enabled': enabled,
    'useWorktree': useWorktree,
    'lastRunAt': lastRunAt?.toIso8601String(),
    'history': [for (final h in history.take(20)) h.toJson()],
  };

  static AutomationRule? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'] as String?;
    final name = raw['name'] as String?;
    final prompt = raw['prompt'] as String?;
    final cwd = raw['cwd'] as String?;
    final cron = raw['cronExpression'] as String?;
    if (id == null ||
        name == null ||
        prompt == null ||
        cwd == null ||
        cron == null) {
      return null;
    }
    return AutomationRule(
      id: id,
      name: name,
      prompt: prompt,
      cwd: cwd,
      cronExpression: cron,
      agentId: raw['agentId'] as String? ?? 'agy',
      enabled: raw['enabled'] != false,
      useWorktree: raw['useWorktree'] == true,
      lastRunAt: DateTime.tryParse(raw['lastRunAt'] as String? ?? ''),
      history: [
        if (raw['history'] case final List list)
          for (final item in list) ?AutomationRunRecord.fromJson(item),
      ],
    );
  }
}

/// Manages recurring Cron automations and on-demand prompt templates, plus
/// exposes `create_automation` and `list_automations` to agents.
class AutomationService extends ChangeNotifier {
  AutomationService._();
  static final instance = AutomationService._();

  @visibleForTesting
  String? storagePathOverride;

  final List<AutomationRule> _rules = [];
  Timer? _tick;
  bool _loaded = false;
  bool _toolsRegistered = false;

  List<AutomationRule> get rules => List.unmodifiable(_rules);

  String get _filePath =>
      storagePathOverride ??
      p.join(DataDirectory.current.path, 'automations.json');

  Future<void> start() async {
    await load();
    registerTools();
    if (_tick == null && !Platform.environment.containsKey('FLUTTER_TEST')) {
      _tick = Timer.periodic(const Duration(seconds: 30), (_) => _checkDue());
    }
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = File(_filePath);
      if (!file.existsSync()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is List) {
        _rules.clear();
        for (final item in decoded) {
          if (AutomationRule.fromJson(item) case final r?) _rules.add(r);
        }
        notifyListeners();
      }
    } on Object catch (e) {
      debugPrint('AutomationService load failed: $e');
    }
  }

  Future<void> _save() async {
    if (Platform.environment.containsKey('FLUTTER_TEST') &&
        storagePathOverride == null) {
      return;
    }
    try {
      final file = File(_filePath);
      file.parent.createSync(recursive: true);
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert([
          for (final r in _rules) r.toJson(),
        ]),
      );
    } on Object catch (e) {
      debugPrint('AutomationService save failed: $e');
    }
  }

  AutomationRule addRule({
    required String name,
    required String prompt,
    required String cwd,
    required String cronExpression,
    String agentId = 'agy',
    bool useWorktree = false,
  }) {
    if (CronSchedule.tryParse(cronExpression) == null) {
      throw ArgumentError('Invalid cron expression: $cronExpression');
    }
    final rule = AutomationRule(
      id: 'auto_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}',
      name: name.trim(),
      prompt: prompt.trim(),
      cwd: cwd.trim(),
      cronExpression: cronExpression.trim(),
      agentId: agentId,
      useWorktree: useWorktree,
    );
    _rules.insert(0, rule);
    notifyListeners();
    unawaited(_save());
    return rule;
  }

  void toggleRule(String id, bool enabled) {
    for (final r in _rules) {
      if (r.id == id) {
        r.enabled = enabled;
        notifyListeners();
        unawaited(_save());
        return;
      }
    }
  }

  void deleteRule(String id) {
    _rules.removeWhere((r) => r.id == id);
    notifyListeners();
    unawaited(_save());
  }

  void _checkDue() {
    final now = DateTime.now();
    for (final rule in _rules) {
      if (!rule.enabled || rule.running) continue;
      final schedule = CronSchedule.tryParse(rule.cronExpression);
      if (schedule == null) continue;
      if (!schedule.matches(now)) continue;
      // Avoid firing twice in the same minute.
      final last = rule.lastRunAt;
      if (last != null &&
          last.year == now.year &&
          last.month == now.month &&
          last.day == now.day &&
          last.hour == now.hour &&
          last.minute == now.minute) {
        continue;
      }
      unawaited(runNow(rule.id));
    }
  }

  Future<void> runNow(String ruleId) async {
    AutomationRule? rule;
    for (final r in _rules) {
      if (r.id == ruleId) {
        rule = r;
        break;
      }
    }
    if (rule == null || rule.running) return;
    rule.running = true;
    rule.lastRunAt = DateTime.now();
    notifyListeners();

    try {
      if (rule.useWorktree) {
        final task = TaskQueueService.instance.enqueue(
          title: '[Auto] ${rule.name}',
          prompt: rule.prompt,
          repoPath: rule.cwd,
          agentId: rule.agentId,
        );
        unawaited(TaskQueueService.instance.runTask(task.id));
        rule.history.insert(
          0,
          AutomationRunRecord(
            startedAt: rule.lastRunAt!,
            ok: true,
            summary: 'Dispatched into worktree task #${task.id}',
          ),
        );
      } else {
        final res = await AcpAgentService.instance.runHeadlessPrompt(
          agentId: rule.agentId,
          prompt: rule.prompt,
          cwd: rule.cwd,
        );
        final text = res.ok
            ? (res.output.trim().isEmpty ? 'Completed' : res.output.trim())
            : (res.error ?? 'Failed');
        rule.history.insert(
          0,
          AutomationRunRecord(
            startedAt: rule.lastRunAt!,
            ok: res.ok,
            summary: text.length > 2000 ? text.substring(0, 2000) : text,
          ),
        );
      }
      if (rule.history.length > 20) {
        rule.history.removeRange(20, rule.history.length);
      }
    } on Object catch (e) {
      rule.history.insert(
        0,
        AutomationRunRecord(
          startedAt: rule.lastRunAt!,
          ok: false,
          summary: '$e',
        ),
      );
    } finally {
      rule.running = false;
      notifyListeners();
      unawaited(_save());
    }
  }

  void registerTools() {
    if (_toolsRegistered) return;
    _toolsRegistered = true;
    ClaudeSdkTools.register(
      ClaudeSdkTool(
        name: 'list_automations',
        description: 'List all configured Cron automations in Ayte.',
        kind: ToolKind.other,
        inputSchema: const {'type': 'object', 'properties': <String, Object?>{}},
        summary: (_, _) => 'List automations',
        run: (_, _) async => jsonEncode([for (final r in _rules) r.toJson()]),
      ),
    );
    ClaudeSdkTools.register(
      ClaudeSdkTool(
        name: 'create_automation',
        description:
            'Create a recurring Cron automation rule in Ayte (5-field cron expression, e.g. "0 9 * * 1-5").',
        kind: ToolKind.other,
        inputSchema: const {
          'type': 'object',
          'required': ['name', 'prompt', 'cron'],
          'properties': {
            'name': {'type': 'string'},
            'prompt': {'type': 'string'},
            'cron': {'type': 'string'},
            'cwd': {'type': 'string'},
            'useWorktree': {'type': 'boolean'},
          },
        },
        summary: (input, _) => 'Create automation "${input['name']}"',
        run: (input, call) async {
          final rule = addRule(
            name: '${input['name'] ?? 'Automation'}',
            prompt: '${input['prompt'] ?? ''}',
            cwd: (input['cwd'] as String?)?.trim().isNotEmpty == true
                ? input['cwd'] as String
                : call.cwd,
            cronExpression: '${input['cron'] ?? ''}',
            useWorktree: input['useWorktree'] == true,
          );
          return jsonEncode(rule.toJson());
        },
      ),
    );
  }
}
