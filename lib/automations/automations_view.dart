import 'dart:async';

import 'package:flutter/material.dart';

import '../ide/ide_button.dart';
import '../ide/ide_input.dart';
import '../theme/app_theme.dart';
import '../theme/codicons.dart';
import '../theme/workbench_theme.dart' show themeColors;
import 'automation_service.dart';
import 'cron_parser.dart';

/// UI panel for creating, scheduling, toggling, and running Cron automations.
class AutomationsView extends StatefulWidget {
  const AutomationsView({super.key, this.defaultCwd});

  final String? defaultCwd;

  @override
  State<AutomationsView> createState() => _AutomationsViewState();
}

class _AutomationsViewState extends State<AutomationsView> {
  final _nameCtrl = TextEditingController();
  final _cronCtrl = TextEditingController(text: '0 9 * * 1-5');
  final _promptCtrl = TextEditingController();
  bool _useWorktree = false;
  String? _error;
  String? _expandedId;

  AutomationService get _svc => AutomationService.instance;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _cronCtrl.dispose();
    _promptCtrl.dispose();
    super.dispose();
  }

  void _add(bool isZh) {
    final name = _nameCtrl.text.trim();
    final cron = _cronCtrl.text.trim();
    final prompt = _promptCtrl.text.trim();
    final cwd = widget.defaultCwd?.trim() ?? '';
    if (name.isEmpty || prompt.isEmpty) {
      setState(() => _error = isZh ? '请填写任务名称和指令内容' : 'Name and prompt are required');
      return;
    }
    if (CronSchedule.tryParse(cron) == null) {
      setState(() => _error = isZh ? '无效的 5 位 Cron 表达式' : 'Invalid 5-field cron expression');
      return;
    }
    setState(() => _error = null);
    _svc.addRule(
      name: name,
      prompt: prompt,
      cwd: cwd,
      cronExpression: cron,
      useWorktree: _useWorktree,
    );
    _nameCtrl.clear();
    _promptCtrl.clear();
  }

  static String _fmtTime(DateTime? dt) {
    if (dt == null) return '-';
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$m-$d $h:$min';
  }

  @override
  Widget build(BuildContext context) {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final colors = themeColors;
    return ListenableBuilder(
      listenable: _svc,
      builder: (context, _) {
        final rules = _svc.rules;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: colors['widget.border'].withValues(alpha: 0.4),
                  ),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: IdeInputBox(
                          controller: _nameCtrl,
                          placeholder: isZh ? '自动化名称（如：每日代码巡检）' : 'Automation name',
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        flex: 2,
                        child: IdeInputBox(
                          controller: _cronCtrl,
                          placeholder: '0 9 * * 1-5',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final preset in [
                        ('每小时', 'Hourly', '0 * * * *'),
                        ('每天 9:00', 'Daily 9am', '0 9 * * *'),
                        ('工作日 9:30', 'Weekdays 9:30', '30 9 * * 1-5'),
                        ('每周一 9:00', 'Mon 9am', '0 9 * * 1'),
                      ])
                        InkWell(
                          onTap: () => setState(() => _cronCtrl.text = preset.$3),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: colors['sideBar.background'],
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: colors['widget.border'].withValues(
                                  alpha: 0.5,
                                ),
                              ),
                            ),
                            child: Text(
                              isZh ? preset.$1 : preset.$2,
                              style: TextStyle(
                                fontSize: 11,
                                color: colors['descriptionForeground'],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: IdeInputBox(
                          controller: _promptCtrl,
                          minLines: 1,
                          maxLines: 3,
                          placeholder: isZh ? '定时执行的 Prompt 指令…' : 'Prompt to run on schedule...',
                          onSubmitted: (_) => _add(isZh),
                        ),
                      ),
                      const SizedBox(width: 6),
                      IdeButton(
                        label: isZh ? '创建' : 'Create',
                        icon: Codicons.add,
                        onPressed: () => _add(isZh),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      InkWell(
                        onTap: () =>
                            setState(() => _useWorktree = !_useWorktree),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _useWorktree
                                  ? Codicons.passFilled
                                  : Codicons.circleLargeOutline,
                              size: 13,
                              color: colors['foreground'],
                            ),
                            const SizedBox(width: 5),
                            Text(
                              isZh
                                  ? '派发到独立 Git Worktree 队列'
                                  : 'Dispatch into isolated Git worktree queue',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: colors['descriptionForeground'],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      _error!,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: Color(0xFFE5534B),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              child: rules.isEmpty
                  ? Center(
                      child: Text(
                        isZh
                            ? '暂无定时自动化任务。可创建每日巡检、提交审查或一键重复执行的模板。'
                            : 'No automations configured yet.',
                        style: TextStyle(
                          fontSize: 12,
                          color: colors['descriptionForeground'],
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(10),
                      itemCount: rules.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, i) {
                        final r = rules[i];
                        final open = _expandedId == r.id;
                        return Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: colors['sideBar.background'].withValues(
                              alpha: 0.55,
                            ),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: colors['widget.border'].withValues(
                                alpha: 0.5,
                              ),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Codicons.clock,
                                    size: 13,
                                    color: r.enabled
                                        ? const Color(0xFF3FB950)
                                        : colors['descriptionForeground'],
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      r.name,
                                      style: TextStyle(
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w600,
                                        color: colors['foreground'],
                                      ),
                                    ),
                                  ),
                                  IdeButton(
                                    label: r.running
                                        ? (isZh ? '运行中…' : 'Running…')
                                        : (isZh ? '立即运行' : 'Run Now'),
                                    secondary: true,
                                    onPressed: r.running
                                        ? null
                                        : () => unawaited(_svc.runNow(r.id)),
                                  ),
                                  const SizedBox(width: 4),
                                  IdeButton(
                                    label: r.enabled
                                        ? (isZh ? '暂停' : 'Pause')
                                        : (isZh ? '启用' : 'Enable'),
                                    secondary: true,
                                    onPressed: () =>
                                        _svc.toggleRule(r.id, !r.enabled),
                                  ),
                                  const SizedBox(width: 4),
                                  InkWell(
                                    onTap: () => setState(
                                      () => _expandedId = open ? null : r.id,
                                    ),
                                    child: Icon(
                                      open
                                          ? Codicons.chevronUp
                                          : Codicons.chevronDown,
                                      size: 14,
                                      color: colors['descriptionForeground'],
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  InkWell(
                                    onTap: () => _svc.deleteRule(r.id),
                                    child: Icon(
                                      Codicons.trash,
                                      size: 13,
                                      color: colors['descriptionForeground'],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Cron: ${r.cronExpression} · ${isZh ? "下次" : "Next"}: ${_fmtTime(r.nextRun)} · ${isZh ? "上次" : "Last"}: ${_fmtTime(r.lastRunAt)}',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontFamily: AppFonts.mono,
                                  color: colors['descriptionForeground'],
                                ),
                              ),
                              if (open) ...[
                                const SizedBox(height: 6),
                                Text(
                                  r.prompt,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: colors['foreground'],
                                  ),
                                ),
                                if (r.history.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  for (final h in r.history.take(5))
                                    Padding(
                                      padding: const EdgeInsets.only(bottom: 4),
                                      child: Container(
                                        padding: const EdgeInsets.all(6),
                                        decoration: BoxDecoration(
                                          color: AppColors.code,
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: Text(
                                          '[${_fmtTime(h.startedAt)}] ${h.ok ? "OK" : "ERR"}: ${h.summary}',
                                          maxLines: 6,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontFamily: AppFonts.mono,
                                            color: h.ok
                                                ? colors['editor.foreground']
                                                : const Color(0xFFE5534B),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ],
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}
