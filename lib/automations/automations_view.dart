import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../acp/acp_agent_service.dart';
import '../canvas/canvas_controller.dart';
import '../ide/ide_button.dart';
import '../ide/ide_input.dart';
import '../theme/app_theme.dart';
import '../theme/codicons.dart';
import '../theme/workbench_theme.dart' show themeColors;
import '../workspace/window_controls.dart';
import 'automation_service.dart';
import 'cron_parser.dart';

/// UI panel for creating, scheduling, editing, toggling, and running Cron
/// automations across native coding kernels and Canvas workflows.
class AutomationsView extends StatefulWidget {
  const AutomationsView({
    super.key,
    this.defaultCwd,
    this.availableRepos = const [],
    this.onPickDirectory,
    this.onHandOff,
  });

  final String? defaultCwd;
  final List<String> availableRepos;
  final Future<String?> Function()? onPickDirectory;
  final Future<void> Function(AutomationRule rule)? onHandOff;

  @override
  State<AutomationsView> createState() => _AutomationsViewState();
}

class _AutomationsViewState extends State<AutomationsView> {
  final _nameCtrl = TextEditingController();
  final _cronCtrl = TextEditingController(text: '0 9 * * 1-5');
  final _promptCtrl = TextEditingController();
  String _selectedCwd = '';
  final List<String> _customRepos = [];
  String _selectedAgent = 'agy';
  String _selectedModel = '';
  String _selectedEffort = '';
  String? _selectedWorkflowId;
  bool _useWorktree = false;
  String? _error;
  String? _expandedId;

  AutomationService get _svc => AutomationService.instance;

  @override
  void initState() {
    super.initState();
    _initSelectedCwd();
  }

  @override
  void didUpdateWidget(AutomationsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_selectedCwd.isEmpty) {
      _initSelectedCwd();
    }
  }

  void _initSelectedCwd() {
    final def = widget.defaultCwd?.trim() ?? '';
    if (def.isNotEmpty) {
      _selectedCwd = def;
    } else if (widget.availableRepos.isNotEmpty) {
      _selectedCwd = widget.availableRepos.first.trim();
    }
  }

  List<String> _allRepoChoices([String? extra]) {
    final seen = <String>{};
    final out = <String>[];
    void addPath(String? raw) {
      final v = raw?.trim() ?? '';
      if (v.isNotEmpty && seen.add(v)) out.add(v);
    }

    addPath(widget.defaultCwd);
    for (final r in widget.availableRepos) {
      addPath(r);
    }
    for (final r in _customRepos) {
      addPath(r);
    }
    addPath(_selectedCwd);
    addPath(extra);
    return out;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _cronCtrl.dispose();
    _promptCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDirectory(bool isZh) async {
    final picker = widget.onPickDirectory ?? WindowControls.pickDirectory;
    final picked = await picker();
    if (!mounted || picked == null || picked.trim().isEmpty) return;
    final clean = picked.trim();
    setState(() {
      if (!_customRepos.contains(clean)) _customRepos.add(clean);
      _selectedCwd = clean;
      _error = null;
    });
  }

  void _add(bool isZh) {
    final name = _nameCtrl.text.trim();
    final cron = _cronCtrl.text.trim();
    final prompt = _promptCtrl.text.trim();
    final cwd = _selectedCwd.trim();
    if (cwd.isEmpty) {
      setState(
        () => _error = isZh
            ? '请先选择目标工作目录 (cwd)'
            : 'Please select a working directory (cwd) first',
      );
      return;
    }
    if (!Directory(cwd).existsSync()) {
      setState(
        () => _error = isZh
            ? '目标工作目录不存在：$cwd'
            : 'Working directory does not exist: $cwd',
      );
      return;
    }
    if (name.isEmpty || prompt.isEmpty) {
      setState(
        () => _error = isZh
            ? '请填写任务名称和指令内容'
            : 'Name and prompt are required',
      );
      return;
    }
    if (CronSchedule.tryParse(cron) == null) {
      setState(
        () => _error = isZh
            ? '无效的 5 位 Cron 表达式'
            : 'Invalid 5-field cron expression',
      );
      return;
    }
    final isWorkflow = _selectedWorkflowId != null;
    try {
      _svc.addRule(
        name: name,
        prompt: prompt,
        cwd: cwd,
        cronExpression: cron,
        agentId: _selectedAgent,
        model: isWorkflow || _selectedModel.isEmpty ? null : _selectedModel,
        effort: isWorkflow || _selectedEffort.isEmpty ? null : _selectedEffort,
        workflowTemplateId: _selectedWorkflowId,
        useWorktree: _useWorktree,
      );
    } on ArgumentError catch (e) {
      setState(() => _error = '${e.message}');
      return;
    }
    setState(() => _error = null);
    _nameCtrl.clear();
    _promptCtrl.clear();
  }

  Future<void> _editRuleDialog(AutomationRule rule, bool isZh) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => _EditAutomationDialog(
        rule: rule,
        isZh: isZh,
        repoChoicesBuilder: (extra) => _allRepoChoices(extra),
        onPickDirectory: () async {
          final picker = widget.onPickDirectory ?? WindowControls.pickDirectory;
          final picked = await picker();
          if (picked != null && picked.trim().isNotEmpty) {
            final clean = picked.trim();
            if (mounted && !_customRepos.contains(clean)) {
              setState(() => _customRepos.add(clean));
            }
            return clean;
          }
          return null;
        },
        onSave: ({
          required String name,
          required String prompt,
          required String cwd,
          required String cronExpression,
          required String agentId,
          required String model,
          required String effort,
          required String? workflowTemplateId,
          required bool useWorktree,
        }) {
          final isWorkflow = workflowTemplateId != null;
          _svc.updateRule(
            rule.id,
            name: name,
            prompt: prompt,
            cwd: cwd,
            cronExpression: cronExpression,
            agentId: agentId,
            model: isWorkflow ? null : model,
            clearModel: isWorkflow || model.isEmpty,
            effort: isWorkflow ? null : effort,
            clearEffort: isWorkflow || effort.isEmpty,
            workflowTemplateId: workflowTemplateId,
            clearWorkflow: workflowTemplateId == null,
            useWorktree: useWorktree,
          );
        },
      ),
    );
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
      listenable: Listenable.merge([
        _svc,
        AcpAgentService.instance,
        CanvasController.instance,
      ]),
      builder: (context, _) {
        final rules = _svc.rules;
        final agents = AcpAgentService.instance.selectableAgents;
        final workflows = CanvasController.instance.runnableWorkflowChoices;
        if (!agents.any((a) => a.id == _selectedAgent) && agents.isNotEmpty) {
          _selectedAgent = agents.first.id;
        }
        if (_selectedWorkflowId != null &&
            !workflows.any((w) => w.id == _selectedWorkflowId)) {
          _selectedWorkflowId = null;
        }
        final models = AcpAgentService.instance.modelsForAgent(_selectedAgent);
        if (_selectedModel.isNotEmpty &&
            !models.any((m) => m.id == _selectedModel)) {
          _selectedModel = '';
        }
        final selectedModelObj = models
            .where((m) => m.id == _selectedModel)
            .firstOrNull;
        final effortLevels = selectedModelObj?.effortLevels ?? const <String>[];
        if (_selectedEffort.isNotEmpty &&
            !effortLevels.contains(_selectedEffort)) {
          _selectedEffort = '';
        }
        final repoChoices = _allRepoChoices();

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
                          placeholder: isZh
                              ? '自动化名称（如：每日代码巡检）'
                              : 'Automation name',
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
                  // Directory / repository picker row
                  Row(
                    children: [
                      Icon(
                        Codicons.folderOpened,
                        size: 14,
                        color: _selectedCwd.isEmpty
                            ? const Color(0xFFD29922)
                            : colors['descriptionForeground'],
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: colors['input.background'],
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: _selectedCwd.isEmpty
                                  ? const Color(0xFFD29922)
                                        .withValues(alpha: 0.65)
                                  : colors['input.border'],
                            ),
                          ),
                          child: repoChoices.isEmpty
                              ? Text(
                                  isZh
                                      ? '未选择目标目录 — 点击右侧「浏览目录」选择'
                                      : 'No working directory selected — click Browse',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Color(0xFFD29922),
                                  ),
                                )
                              : DropdownButton<String>(
                                  value: repoChoices.contains(_selectedCwd)
                                      ? _selectedCwd
                                      : repoChoices.first,
                                  isExpanded: true,
                                  isDense: true,
                                  underline: const SizedBox.shrink(),
                                  dropdownColor: colors['editor.background'],
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: colors['foreground'],
                                  ),
                                  items: [
                                    for (final repo in repoChoices)
                                      DropdownMenuItem(
                                        value: repo,
                                        child: Text(
                                          '${p.basename(repo)}  ·  $repo',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                  ],
                                  onChanged: (v) {
                                    if (v != null) {
                                      setState(() {
                                        _selectedCwd = v;
                                        _error = null;
                                      });
                                    }
                                  },
                                ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      IdeButton(
                        label: isZh ? '浏览目录' : 'Browse',
                        icon: Codicons.folderOpened,
                        secondary: true,
                        onPressed: () => unawaited(_pickDirectory(isZh)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // Kernel/Workflow + Model + Effort selector row
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _AutoDropdown<String>(
                        value: _selectedWorkflowId ?? '__agent__:$_selectedAgent',
                        maxWidth: 200,
                        items: [
                          for (final a in agents)
                            DropdownMenuItem(
                              value: '__agent__:${a.id}',
                              child: Text(
                                a.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          for (final wf in workflows)
                            DropdownMenuItem(
                              value: wf.id,
                              child: Text(
                                '⚡ ${wf.name}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() {
                            if (v.startsWith('__agent__:')) {
                              _selectedWorkflowId = null;
                              final next = v.substring(10);
                              if (next != _selectedAgent) {
                                _selectedAgent = next;
                                _selectedModel = '';
                                _selectedEffort = '';
                              }
                            } else {
                              _selectedWorkflowId = v;
                            }
                          });
                        },
                      ),
                      if (_selectedWorkflowId == null) ...[
                        _AutoDropdown<String>(
                          value: _selectedModel,
                          maxWidth: 210,
                          items: [
                            DropdownMenuItem(
                              value: '',
                              child: Text(
                                isZh ? '默认模型' : 'Default model',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            for (final m in models)
                              DropdownMenuItem(
                                value: m.id,
                                child: Text(
                                  m.label,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (v) {
                            if (v == null) return;
                            setState(() {
                              _selectedModel = v;
                              _selectedEffort = '';
                            });
                          },
                        ),
                        if (effortLevels.isNotEmpty)
                          _AutoDropdown<String>(
                            value: _selectedEffort,
                            maxWidth: 120,
                            items: [
                              DropdownMenuItem(
                                value: '',
                                child: Text(
                                  isZh ? '默认强度' : 'Effort',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              for (final e in effortLevels)
                                DropdownMenuItem(
                                  value: e,
                                  child: Text(
                                    e,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: (v) {
                              if (v != null) {
                                setState(() => _selectedEffort = v);
                              }
                            },
                          ),
                      ],
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
                          placeholder: isZh
                              ? '定时执行的 Prompt 指令…'
                              : 'Prompt to run on schedule...',
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
                        final modelLabel =
                            r.model != null && r.model!.isNotEmpty
                            ? AcpAgentService.instance.modelLabel(
                                r.agentId,
                                r.model!,
                              )
                            : '';
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
                                  if (widget.onHandOff != null) ...[
                                    const SizedBox(width: 4),
                                    IdeButton(
                                      label: isZh ? '接管' : 'Hand Off',
                                      icon: Codicons.commentDiscussion,
                                      secondary: true,
                                      onPressed: () =>
                                          unawaited(widget.onHandOff!(r)),
                                    ),
                                  ],
                                  const SizedBox(width: 4),
                                  Tooltip(
                                    message: isZh ? '编辑' : 'Edit',
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(4),
                                      onTap: () => unawaited(
                                        _editRuleDialog(r, isZh),
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.all(3),
                                        child: Icon(
                                          Codicons.edit,
                                          size: 13,
                                          color:
                                              colors['descriptionForeground'],
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 2),
                                  InkWell(
                                    onTap: () => setState(
                                      () => _expandedId = open ? null : r.id,
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.all(3),
                                      child: Icon(
                                        open
                                            ? Codicons.chevronUp
                                            : Codicons.chevronDown,
                                        size: 14,
                                        color: colors['descriptionForeground'],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 2),
                                  InkWell(
                                    onTap: () => _svc.deleteRule(r.id),
                                    child: Padding(
                                      padding: const EdgeInsets.all(3),
                                      child: Icon(
                                        Codicons.trash,
                                        size: 13,
                                        color: colors['descriptionForeground'],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 5),
                              Wrap(
                                spacing: 6,
                                runSpacing: 4,
                                children: [
                                  if (r.cwd.isNotEmpty)
                                    Tooltip(
                                      message: r.cwd,
                                      child: _AutoMetaPill(
                                        icon: Codicons.folderOpened,
                                        text: p.basename(r.cwd),
                                      ),
                                    ),
                                  if (r.workflowTemplateId != null &&
                                      r.workflowTemplateId!.isNotEmpty)
                                    _AutoMetaPill(
                                      text: '⚡ ${r.workflowTemplateId}',
                                    )
                                  else
                                    _AutoMetaPill(text: r.agentId),
                                  if (modelLabel.isNotEmpty)
                                    _AutoMetaPill(text: modelLabel),
                                  if (r.effort != null && r.effort!.isNotEmpty)
                                    _AutoMetaPill(
                                      text: isZh
                                          ? '强度: ${r.effort}'
                                          : 'Effort: ${r.effort}',
                                    ),
                                  if (r.useWorktree)
                                    _AutoMetaPill(
                                      icon: Codicons.gitBranch,
                                      text: 'Worktree',
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
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
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

class _EditAutomationDialog extends StatefulWidget {
  const _EditAutomationDialog({
    required this.rule,
    required this.isZh,
    required this.repoChoicesBuilder,
    required this.onPickDirectory,
    required this.onSave,
  });

  final AutomationRule rule;
  final bool isZh;
  final List<String> Function(String? extra) repoChoicesBuilder;
  final Future<String?> Function() onPickDirectory;
  final void Function({
    required String name,
    required String prompt,
    required String cwd,
    required String cronExpression,
    required String agentId,
    required String model,
    required String effort,
    required String? workflowTemplateId,
    required bool useWorktree,
  })
  onSave;

  @override
  State<_EditAutomationDialog> createState() => _EditAutomationDialogState();
}

class _EditAutomationDialogState extends State<_EditAutomationDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _cronCtrl;
  late final TextEditingController _promptCtrl;
  late String _cwd;
  late String _agent;
  late String _model;
  late String _effort;
  String? _workflowId;
  late bool _useWorktree;
  String? _dialogError;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.rule.name);
    _cronCtrl = TextEditingController(text: widget.rule.cronExpression);
    _promptCtrl = TextEditingController(text: widget.rule.prompt);
    _cwd = widget.rule.cwd;
    _agent = widget.rule.agentId;
    _model = widget.rule.model ?? '';
    _effort = widget.rule.effort ?? '';
    _workflowId = widget.rule.workflowTemplateId;
    _useWorktree = widget.rule.useWorktree;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _cronCtrl.dispose();
    _promptCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isZh = widget.isZh;
    final colors = themeColors;
    final agents = AcpAgentService.instance.selectableAgents;
    if (!agents.any((a) => a.id == _agent) && agents.isNotEmpty) {
      _agent = agents.first.id;
    }
    final workflows = CanvasController.instance.runnableWorkflowChoices;
    if (_workflowId != null && !workflows.any((w) => w.id == _workflowId)) {
      _workflowId = null;
    }
    final models = AcpAgentService.instance.modelsForAgent(_agent);
    if (_model.isNotEmpty && !models.any((m) => m.id == _model)) {
      _model = '';
    }
    final modelObj = models.where((m) => m.id == _model).firstOrNull;
    final efforts = modelObj?.effortLevels ?? const <String>[];
    if (_effort.isNotEmpty && !efforts.contains(_effort)) {
      _effort = '';
    }
    final choices = widget.repoChoicesBuilder(_cwd);
    if (_cwd.trim().isEmpty && choices.isNotEmpty) {
      _cwd = choices.first;
    }

    return AlertDialog(
      title: Text(isZh ? '编辑自动化规则' : 'Edit Automation Rule'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: IdeInputBox(
                      controller: _nameCtrl,
                      placeholder: isZh ? '自动化名称' : 'Automation name',
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
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: colors['input.background'],
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: colors['input.border']),
                      ),
                      child: choices.isEmpty
                          ? Text(
                              _cwd.isEmpty
                                  ? (isZh ? '未选择目录' : 'No directory')
                                  : _cwd,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: colors['foreground'],
                              ),
                            )
                          : DropdownButton<String>(
                              value: choices.contains(_cwd)
                                  ? _cwd
                                  : choices.first,
                              isExpanded: true,
                              isDense: true,
                              underline: const SizedBox.shrink(),
                              dropdownColor: colors['editor.background'],
                              style: TextStyle(
                                fontSize: 12,
                                color: colors['foreground'],
                              ),
                              items: [
                                for (final dir in choices)
                                  DropdownMenuItem(
                                    value: dir,
                                    child: Text(
                                      '${p.basename(dir)}  ·  $dir',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                              onChanged: (v) {
                                if (v != null) {
                                  setState(() {
                                    _cwd = v;
                                    _dialogError = null;
                                  });
                                }
                              },
                            ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IdeButton(
                    label: isZh ? '浏览目录' : 'Browse',
                    icon: Codicons.folderOpened,
                    secondary: true,
                    onPressed: () async {
                      final picked = await widget.onPickDirectory();
                      if (!mounted || picked == null) return;
                      setState(() {
                        _cwd = picked;
                        _dialogError = null;
                      });
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  DropdownButton<String>(
                    value: _workflowId ?? '__agent__:$_agent',
                    isDense: true,
                    underline: const SizedBox.shrink(),
                    dropdownColor: colors['editor.background'],
                    style: TextStyle(
                      fontSize: 12,
                      color: colors['foreground'],
                    ),
                    items: [
                      for (final a in agents)
                        DropdownMenuItem(
                          value: '__agent__:${a.id}',
                          child: Text(a.name),
                        ),
                      for (final wf in workflows)
                        DropdownMenuItem(
                          value: wf.id,
                          child: Text('⚡ ${wf.name}'),
                        ),
                    ],
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() {
                        if (v.startsWith('__agent__:')) {
                          _workflowId = null;
                          final next = v.substring(10);
                          if (next != _agent) {
                            _agent = next;
                            _model = '';
                            _effort = '';
                          }
                        } else {
                          _workflowId = v;
                        }
                      });
                    },
                  ),
                  if (_workflowId == null) ...[
                    DropdownButton<String>(
                      value: _model,
                      isDense: true,
                      underline: const SizedBox.shrink(),
                      dropdownColor: colors['editor.background'],
                      style: TextStyle(
                        fontSize: 12,
                        color: colors['foreground'],
                      ),
                      items: [
                        DropdownMenuItem(
                          value: '',
                          child: Text(isZh ? '默认模型' : 'Default model'),
                        ),
                        for (final m in models)
                          DropdownMenuItem(value: m.id, child: Text(m.label)),
                      ],
                      onChanged: (v) {
                        if (v == null) return;
                        setState(() {
                          _model = v;
                          _effort = '';
                        });
                      },
                    ),
                    if (efforts.isNotEmpty)
                      DropdownButton<String>(
                        value: _effort,
                        isDense: true,
                        underline: const SizedBox.shrink(),
                        dropdownColor: colors['editor.background'],
                        style: TextStyle(
                          fontSize: 12,
                          color: colors['foreground'],
                        ),
                        items: [
                          DropdownMenuItem(
                            value: '',
                            child: Text(isZh ? '默认强度' : 'Effort'),
                          ),
                          for (final e in efforts)
                            DropdownMenuItem(value: e, child: Text(e)),
                        ],
                        onChanged: (v) {
                          if (v != null) {
                            setState(() => _effort = v);
                          }
                        },
                      ),
                  ],
                  IdeButton(
                    label: _useWorktree
                        ? (isZh ? '隔离 Worktree' : 'Worktree')
                        : (isZh ? '当前工作区直跑' : 'In-Place'),
                    secondary: _useWorktree,
                    onPressed: () =>
                        setState(() => _useWorktree = !_useWorktree),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              IdeInputBox(
                controller: _promptCtrl,
                minLines: 4,
                maxLines: 8,
                placeholder: isZh ? '定时执行的 Prompt 指令' : 'Prompt',
              ),
              if (_dialogError != null) ...[
                const SizedBox(height: 6),
                Text(
                  _dialogError!,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: Color(0xFFE5534B),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(isZh ? '取消' : 'Cancel'),
        ),
        TextButton(
          onPressed: () {
            final nextName = _nameCtrl.text.trim();
            final nextPrompt = _promptCtrl.text.trim();
            final nextCron = _cronCtrl.text.trim();
            final nextCwd = _cwd.trim();
            if (nextName.isEmpty || nextPrompt.isEmpty) {
              setState(
                () => _dialogError = isZh
                    ? '请填写名称和指令内容'
                    : 'Name and prompt are required',
              );
              return;
            }
            if (nextCwd.isEmpty || !Directory(nextCwd).existsSync()) {
              setState(
                () => _dialogError = isZh
                    ? '目标工作目录不存在'
                    : 'Working directory does not exist',
              );
              return;
            }
            if (CronSchedule.tryParse(nextCron) == null) {
              setState(
                () => _dialogError = isZh
                    ? '无效的 5 位 Cron 表达式'
                    : 'Invalid 5-field cron expression',
              );
              return;
            }
            widget.onSave(
              name: nextName,
              prompt: nextPrompt,
              cwd: nextCwd,
              cronExpression: nextCron,
              agentId: _agent,
              model: _model,
              effort: _effort,
              workflowTemplateId: _workflowId,
              useWorktree: _useWorktree,
            );
            Navigator.of(context).pop();
          },
          child: Text(isZh ? '保存' : 'Save'),
        ),
      ],
    );
  }
}

class _AutoDropdown<T> extends StatelessWidget {
  const _AutoDropdown({
    required this.value,
    required this.items,
    required this.onChanged,
    this.maxWidth = 180,
  });

  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final colors = themeColors;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: colors['input.background'],
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: colors['input.border']),
        ),
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          isDense: true,
          underline: const SizedBox.shrink(),
          dropdownColor: colors['editor.background'],
          style: TextStyle(fontSize: 12, color: colors['foreground']),
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _AutoMetaPill extends StatelessWidget {
  const _AutoMetaPill({required this.text, this.icon});

  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final colors = themeColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colors['editor.background'],
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: colors['widget.border'].withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: colors['descriptionForeground']),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: TextStyle(
              fontSize: 10.5,
              fontFamily: AppFonts.mono,
              color: colors['descriptionForeground'],
            ),
          ),
        ],
      ),
    );
  }
}
