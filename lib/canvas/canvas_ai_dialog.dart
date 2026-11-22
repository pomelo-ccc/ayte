import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../ide/ide_button.dart';
import '../theme/app_theme.dart';
import '../theme/codicons.dart';
import '../theme/workbench_theme.dart' show themeColors;
import 'canvas_ai_generator.dart';
import 'canvas_controller.dart';

/// Opens the AI Workflow Generator dialog ("一句话生成/修改工作流").
/// Returns `true` if a workflow was generated and applied to [ctrl].
Future<bool> showCanvasAiWorkflowDialog(
  BuildContext context, {
  required CanvasController ctrl,
  required bool isZh,
  String? cwd,
}) async {
  final applied = await showDialog<bool>(
    context: context,
    builder: (_) => _CanvasAiWorkflowDialog(ctrl: ctrl, isZh: isZh, cwd: cwd),
  );
  return applied == true;
}

/// Opens the Inspector "AI 帮写 / 优化脚本与提示词" modal for a single [node].
/// Returns the updated content/expression text, or `null` if cancelled.
Future<String?> showCanvasNodeAiAssistDialog(
  BuildContext context, {
  required CanvasNode node,
  required List<String> availableVars,
  required bool isZh,
  String? cwd,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _CanvasNodeAiAssistDialog(
      node: node,
      availableVars: availableVars,
      isZh: isZh,
      cwd: cwd,
    ),
  );
}

/// Opens the Portable JSON Export / Import dialog for sharing workflows.
/// Returns `true` if a workflow was imported.
Future<bool> showCanvasJsonDialog(
  BuildContext context, {
  required CanvasController ctrl,
  required bool isZh,
  String? defaultDir,
}) async {
  final imported = await showDialog<bool>(
    context: context,
    builder: (_) => _CanvasJsonIoDialog(
      ctrl: ctrl,
      isZh: isZh,
      defaultDir: defaultDir,
    ),
  );
  return imported == true;
}

class _CanvasAiWorkflowDialog extends StatefulWidget {
  const _CanvasAiWorkflowDialog({
    required this.ctrl,
    required this.isZh,
    this.cwd,
  });

  final CanvasController ctrl;
  final bool isZh;
  final String? cwd;

  @override
  State<_CanvasAiWorkflowDialog> createState() =>
      _CanvasAiWorkflowDialogState();
}

class _CanvasAiWorkflowDialogState extends State<_CanvasAiWorkflowDialog> {
  final _promptCtrl = TextEditingController();
  late bool _modifyCurrent = widget.ctrl.nodes.isNotEmpty;
  bool _createNewTab = true;
  bool _busy = false;
  String? _error;
  Completer<void>? _cancelCompleter;

  @override
  void dispose() {
    _cancelCompleter?.complete();
    _promptCtrl.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    final text = _promptCtrl.text.trim();
    if (text.isEmpty || _busy) return;
    final cancel = Completer<void>();
    setState(() {
      _busy = true;
      _error = null;
      _cancelCompleter = cancel;
    });
    try {
      final generated = await CanvasAiGenerator.generateWorkflow(
        text,
        existingNodes: _modifyCurrent ? widget.ctrl.nodes : const [],
        existingEdges: _modifyCurrent ? widget.ctrl.edges : const [],
        modifyCurrent: _modifyCurrent,
        cwd: widget.cwd,
        cancel: cancel.future,
      );
      if (!mounted) return;
      widget.ctrl.applyGeneratedWorkflow(
        name: generated.name,
        nodes: generated.nodes,
        edges: generated.edges,
        createNewTab: !_modifyCurrent && _createNewTab,
      );
      Navigator.of(context).pop(true);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString().replaceFirst('Bad state: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isZh = widget.isZh;
    final colors = themeColors;
    final dark = colors.dark;
    final bg = dark ? const Color(0xFF1A1D24) : Colors.white;
    final fieldFill = dark ? const Color(0xFF222630) : const Color(0xFFF5F6F8);
    final border = dark
        ? Colors.white.withValues(alpha: 0.1)
        : Colors.black.withValues(alpha: 0.085);

    final examples = isZh
        ? const [
            '拉取最新代码 → 并行跑前端单测和后端单测 → 人工审批 → 打包部署并发送 Webhook 通知',
            '扫描 Git diff → AI Agent 审查安全漏洞和性能隐患 → 条件判断无高危则自动提交 PR',
            '给当前工作流在失败分支增加自动采集日志与 AI 诊断节点',
          ]
        : const [
            'Git pull -> run unit tests & lint in parallel -> human approval -> deploy & notify webhook',
            'Inspect git diff -> AI Agent code review -> condition pass -> open PR',
            'Add failure diagnostics & notification nodes to current workflow',
          ];

    return Dialog(
      backgroundColor: bg,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(13),
        side: BorderSide(color: border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.fromLTRB(18, 15, 14, 13),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: border)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: const Color(0xFF8B5CF6).withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Codicons.wand,
                      size: 15,
                      color: Color(0xFF8B5CF6),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isZh ? 'AI 生成 / 改造工作流' : 'AI Workflow Generator',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: colors['foreground'],
                          ),
                        ),
                        Text(
                          isZh
                              ? '用自然语言描述目标流程，自动生成可执行 DAG 节点、变量连线与自动排版'
                              : 'Describe your pipeline in plain language to generate an executable DAG.',
                          style: TextStyle(
                            fontSize: 11,
                            color: colors['descriptionForeground'],
                          ),
                        ),
                      ],
                    ),
                  ),
                  InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => Navigator.of(context).pop(false),
                    child: Padding(
                      padding: const EdgeInsets.all(5),
                      child: Icon(
                        Codicons.close,
                        size: 14,
                        color: colors['descriptionForeground'],
                      ),
                    ),
                  ),
                ],
              ),
            ),

            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Mode switcher
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      _modePill(
                        label: isZh ? '新建工作流（新标签页）' : 'Create New Workflow',
                        selected: !_modifyCurrent && _createNewTab,
                        onTap: _busy
                            ? null
                            : () => setState(() {
                                _modifyCurrent = false;
                                _createNewTab = true;
                              }),
                        colors: colors,
                        fill: fieldFill,
                        border: border,
                      ),
                      if (widget.ctrl.nodes.isNotEmpty)
                        _modePill(
                          label: isZh ? '基于当前画布修改扩展' : 'Modify Current Canvas',
                          selected: _modifyCurrent,
                          onTap: _busy
                              ? null
                              : () => setState(() {
                                  _modifyCurrent = true;
                                  _createNewTab = false;
                                }),
                          colors: colors,
                          fill: fieldFill,
                          border: border,
                        ),
                      _modePill(
                        label: isZh ? '覆盖当前画布' : 'Replace Current Canvas',
                        selected: !_modifyCurrent && !_createNewTab,
                        onTap: _busy
                            ? null
                            : () => setState(() {
                                _modifyCurrent = false;
                                _createNewTab = false;
                              }),
                        colors: colors,
                        fill: fieldFill,
                        border: border,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _promptCtrl,
                    autofocus: true,
                    enabled: !_busy,
                    minLines: 4,
                    maxLines: 7,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.5,
                      color: colors['foreground'],
                    ),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: fieldFill,
                      hintText: isZh
                          ? '例如：先执行 npm test 和 flutter analyze 并行检查，通过后让 AI 总结改动并等待我人工审批，审批通过后执行发布脚本…'
                          : 'e.g. Run tests and linter in parallel, summarize with AI Agent, pause for approval, then deploy...',
                      hintStyle: TextStyle(
                        fontSize: 12,
                        color: colors['descriptionForeground'].withValues(
                          alpha: 0.65,
                        ),
                      ),
                      contentPadding: const EdgeInsets.all(12),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(
                          color: Color(0xFF8B5CF6),
                          width: 1.25,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    isZh ? '快捷灵感：' : 'Quick ideas:',
                    style: TextStyle(
                      fontSize: 10.8,
                      fontWeight: FontWeight.w600,
                      color: colors['descriptionForeground'],
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final ex in examples)
                        InkWell(
                          borderRadius: BorderRadius.circular(6),
                          onTap: _busy
                              ? null
                              : () => setState(() => _promptCtrl.text = ex),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: fieldFill,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: border),
                            ),
                            child: Text(
                              ex,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: colors['foreground'],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFDC2626).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(
                          color: const Color(0xFFDC2626).withValues(alpha: 0.4),
                        ),
                      ),
                      child: Text(
                        _error!,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: Color(0xFFEF4444),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),

            Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: border)),
              ),
              child: Row(
                children: [
                  if (_busy) ...[
                    const SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.9,
                        color: Color(0xFF8B5CF6),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      isZh ? 'AI 正在编排 DAG 节点…' : 'Designing workflow DAG...',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: colors['descriptionForeground'],
                      ),
                    ),
                  ],
                  const Spacer(),
                  IdeButton(
                    label: isZh ? '取消' : 'Cancel',
                    secondary: true,
                    onPressed: () {
                      _cancelCompleter?.complete();
                      Navigator.of(context).pop(false);
                    },
                  ),
                  const SizedBox(width: 8),
                  IdeButton(
                    label: _busy
                        ? (isZh ? '生成中…' : 'Generating...')
                        : (isZh ? '立即生成' : 'Generate'),
                    icon: Codicons.wand,
                    onPressed: _busy ? null : _generate,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _modePill({
    required String label,
    required bool selected,
    required VoidCallback? onTap,
    required dynamic colors,
    required Color fill,
    required Color border,
  }) => InkWell(
    borderRadius: BorderRadius.circular(6),
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: selected
            ? const Color(0xFF8B5CF6).withValues(alpha: 0.16)
            : fill,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: selected ? const Color(0xFF8B5CF6) : border,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          color: selected
              ? const Color(0xFF8B5CF6)
              : colors['foreground'] as Color,
        ),
      ),
    ),
  );
}

class _CanvasNodeAiAssistDialog extends StatefulWidget {
  const _CanvasNodeAiAssistDialog({
    required this.node,
    required this.availableVars,
    required this.isZh,
    this.cwd,
  });

  final CanvasNode node;
  final List<String> availableVars;
  final bool isZh;
  final String? cwd;

  @override
  State<_CanvasNodeAiAssistDialog> createState() =>
      _CanvasNodeAiAssistDialogState();
}

class _CanvasNodeAiAssistDialogState extends State<_CanvasNodeAiAssistDialog> {
  final _ctrl = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    if (_ctrl.text.trim().isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await CanvasAiGenerator.assistNodeContent(
        widget.node,
        _ctrl.text.trim(),
        availableVars: widget.availableVars,
        cwd: widget.cwd,
      );
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString().replaceFirst('Bad state: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isZh = widget.isZh;
    final colors = themeColors;
    final dark = colors.dark;
    final bg = dark ? const Color(0xFF1A1D24) : Colors.white;
    final fieldFill = dark ? const Color(0xFF222630) : const Color(0xFFF5F6F8);
    final border = dark
        ? Colors.white.withValues(alpha: 0.1)
        : Colors.black.withValues(alpha: 0.085);

    return Dialog(
      backgroundColor: bg,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Codicons.wand, size: 15, color: Color(0xFF8B5CF6)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      isZh
                          ? 'AI 帮写 · ${widget.node.title}'
                          : 'AI Assist · ${widget.node.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: colors['foreground'],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _ctrl,
                autofocus: true,
                enabled: !_busy,
                minLines: 3,
                maxLines: 6,
                style: TextStyle(fontSize: 12.5, color: colors['foreground']),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: fieldFill,
                  hintText: isZh
                      ? '告诉 AI 你想怎么写或优化这个节点（例如：加入超时保护、兼容 Windows PowerShell 与 Bash、或改写为更严谨的审查提示词）'
                      : 'Describe how to write or refine this node payload...',
                  hintStyle: TextStyle(
                    fontSize: 12,
                    color: colors['descriptionForeground'].withValues(
                      alpha: 0.65,
                    ),
                  ),
                  contentPadding: const EdgeInsets.all(11),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(
                      color: Color(0xFF8B5CF6),
                      width: 1.2,
                    ),
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: Color(0xFFEF4444),
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IdeButton(
                    label: isZh ? '取消' : 'Cancel',
                    secondary: true,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 8),
                  IdeButton(
                    label: _busy
                        ? (isZh ? '生成中…' : 'Generating...')
                        : (isZh ? '应用到节点' : 'Apply'),
                    icon: Codicons.wand,
                    onPressed: _busy ? null : _run,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CanvasJsonIoDialog extends StatefulWidget {
  const _CanvasJsonIoDialog({
    required this.ctrl,
    required this.isZh,
    this.defaultDir,
  });

  final CanvasController ctrl;
  final bool isZh;
  final String? defaultDir;

  @override
  State<_CanvasJsonIoDialog> createState() => _CanvasJsonIoDialogState();
}

class _CanvasJsonIoDialogState extends State<_CanvasJsonIoDialog> {
  int _tab = 0; // 0 = Export, 1 = Import
  late final TextEditingController _exportCtrl = TextEditingController(
    text: widget.ctrl.exportWorkflowJson(),
  );
  final TextEditingController _importCtrl = TextEditingController();
  late final TextEditingController _filePathCtrl = TextEditingController(
    text: p.join(
      widget.defaultDir?.isNotEmpty == true
          ? widget.defaultDir!
          : Directory.current.path,
      'ayte-workflow.json',
    ),
  );
  bool _importAsNewTab = true;
  String? _statusMsg;
  bool _isError = false;

  @override
  void dispose() {
    _exportCtrl.dispose();
    _importCtrl.dispose();
    _filePathCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveToFile() async {
    final target = _filePathCtrl.text.trim();
    if (target.isEmpty) return;
    try {
      final f = File(target);
      await f.parent.create(recursive: true);
      await f.writeAsString(_exportCtrl.text);
      if (!mounted) return;
      setState(() {
        _isError = false;
        _statusMsg = widget.isZh ? '已保存到 $target' : 'Saved to $target';
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _isError = true;
        _statusMsg = e.toString();
      });
    }
  }

  Future<void> _loadFromFile() async {
    final target = _filePathCtrl.text.trim();
    if (target.isEmpty) return;
    try {
      final text = await File(target).readAsString();
      if (!mounted) return;
      setState(() {
        _importCtrl.text = text;
        _isError = false;
        _statusMsg = widget.isZh ? '已读取文件，点击「导入」生效' : 'Loaded file.';
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _isError = true;
        _statusMsg = e.toString();
      });
    }
  }

  void _doImport() {
    try {
      widget.ctrl.importWorkflowJson(
        _importCtrl.text.trim(),
        createNewTab: _importAsNewTab,
      );
      Navigator.of(context).pop(true);
    } on Object catch (e) {
      setState(() {
        _isError = true;
        _statusMsg = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isZh = widget.isZh;
    final colors = themeColors;
    final dark = colors.dark;
    final bg = dark ? const Color(0xFF1A1D24) : Colors.white;
    final fieldFill = dark ? const Color(0xFF13161C) : const Color(0xFFF6F7FA);
    final border = dark
        ? Colors.white.withValues(alpha: 0.1)
        : Colors.black.withValues(alpha: 0.09);

    return Dialog(
      backgroundColor: bg,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(13),
        side: BorderSide(color: border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 580),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(18, 14, 14, 10),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: border)),
              ),
              child: Row(
                children: [
                  const Icon(Codicons.json, size: 15, color: Color(0xFF2563EB)),
                  const SizedBox(width: 8),
                  Text(
                    isZh ? '工作流 JSON 导入 / 导出' : 'Workflow JSON Import / Export',
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: colors['foreground'],
                    ),
                  ),
                  const Spacer(),
                  _tabChip(
                    label: isZh ? '导出 JSON' : 'Export',
                    selected: _tab == 0,
                    onTap: () => setState(() {
                      _tab = 0;
                      _statusMsg = null;
                    }),
                    colors: colors,
                    border: border,
                  ),
                  const SizedBox(width: 6),
                  _tabChip(
                    label: isZh ? '导入 JSON' : 'Import',
                    selected: _tab == 1,
                    onTap: () => setState(() {
                      _tab = 1;
                      _statusMsg = null;
                    }),
                    colors: colors,
                    border: border,
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _filePathCtrl,
                            style: TextStyle(
                              fontSize: 11.5,
                              fontFamily: AppFonts.mono,
                              color: colors['foreground'],
                            ),
                            decoration: InputDecoration(
                              isDense: true,
                              filled: true,
                              fillColor: fieldFill,
                              hintText: isZh ? 'JSON 文件路径' : 'JSON file path',
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(6),
                                borderSide: BorderSide(color: border),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(6),
                                borderSide: const BorderSide(
                                  color: Color(0xFF2563EB),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IdeButton(
                          label: _tab == 0
                              ? (isZh ? '保存到文件' : 'Save File')
                              : (isZh ? '从文件读取' : 'Load File'),
                          icon: _tab == 0
                              ? Codicons.save
                              : Codicons.folderOpened,
                          secondary: true,
                          onPressed: _tab == 0 ? _saveToFile : _loadFromFile,
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: TextField(
                        controller: _tab == 0 ? _exportCtrl : _importCtrl,
                        readOnly: _tab == 0,
                        expands: true,
                        maxLines: null,
                        minLines: null,
                        textAlignVertical: TextAlignVertical.top,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontFamily: AppFonts.mono,
                          height: 1.45,
                          color: colors['foreground'],
                        ),
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: fieldFill,
                          hintText: _tab == 1
                              ? (isZh
                                    ? '在此粘贴工作流 JSON，或点击上方「从文件读取」…'
                                    : 'Paste workflow JSON here...')
                              : null,
                          contentPadding: const EdgeInsets.all(11),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(7),
                            borderSide: BorderSide(color: border),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(7),
                            borderSide: const BorderSide(
                              color: Color(0xFF2563EB),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (_statusMsg != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _statusMsg!,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: _isError
                              ? const Color(0xFFEF4444)
                              : const Color(0xFF16A34A),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: border)),
              ),
              child: Row(
                children: [
                  if (_tab == 1)
                    InkWell(
                      borderRadius: BorderRadius.circular(5),
                      onTap: () =>
                          setState(() => _importAsNewTab = !_importAsNewTab),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: Checkbox(
                              value: _importAsNewTab,
                              onChanged: (v) =>
                                  setState(() => _importAsNewTab = v ?? true),
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            isZh ? '导入到新工作流标签页' : 'Import as new workflow tab',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: colors['descriptionForeground'],
                            ),
                          ),
                        ],
                      ),
                    ),
                  const Spacer(),
                  IdeButton(
                    label: isZh ? '关闭' : 'Close',
                    secondary: true,
                    onPressed: () => Navigator.of(context).pop(false),
                  ),
                  const SizedBox(width: 8),
                  if (_tab == 0)
                    IdeButton(
                      label: isZh ? '复制 JSON' : 'Copy JSON',
                      icon: Codicons.copy,
                      onPressed: () {
                        unawaited(
                          Clipboard.setData(
                            ClipboardData(text: _exportCtrl.text),
                          ),
                        );
                        setState(() {
                          _isError = false;
                          _statusMsg = isZh ? '已复制到剪贴板' : 'Copied to clipboard';
                        });
                      },
                    )
                  else
                    IdeButton(
                      label: isZh ? '导入工作流' : 'Import Workflow',
                      icon: Codicons.cloudDownload,
                      onPressed: _doImport,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tabChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    required dynamic colors,
    required Color border,
  }) => InkWell(
    borderRadius: BorderRadius.circular(6),
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
      decoration: BoxDecoration(
        color: selected
            ? const Color(0xFF2563EB).withValues(alpha: 0.16)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: selected ? const Color(0xFF2563EB) : border,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          color: selected
              ? const Color(0xFF2563EB)
              : colors['descriptionForeground'] as Color,
        ),
      ),
    ),
  );
}
