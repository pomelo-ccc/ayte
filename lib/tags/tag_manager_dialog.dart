import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ide/ide_button.dart';
import '../ide/ide_input.dart';
import '../theme/codicons.dart';
import '../theme/workbench_theme.dart' show themeColors;
import '../workspace/workspace.dart';
import 'tag_store.dart';

/// Opens the Tag & Tag Group management dialog (create/rename/delete groups and
/// tags, assign colors, move tags between groups).
Future<void> showTagManagerDialog(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const _TagManagerDialog(),
);

/// Opens a quick picker dialog to assign grouped tags to [thread].
Future<void> showThreadTagPickerDialog(
  BuildContext context,
  AgentThread thread,
) => showDialog<void>(
  context: context,
  builder: (_) => _ThreadTagPickerDialog(thread: thread),
);

/// Opens the Cross-Session Handoff preview & launch dialog.
Future<void> showSessionHandoffDialog(
  BuildContext context, {
  required AgentThread thread,
  required void Function(String brief) onStartNewSession,
}) {
  final brief = TagStore.buildHandoffBrief(thread);
  return showDialog<void>(
    context: context,
    builder: (_) => _HandoffDialog(
      initialBrief: brief,
      onStartNewSession: onStartNewSession,
    ),
  );
}

class _TagManagerDialog extends StatefulWidget {
  const _TagManagerDialog();

  @override
  State<_TagManagerDialog> createState() => _TagManagerDialogState();
}

class _TagManagerDialogState extends State<_TagManagerDialog> {
  final _groupInput = TextEditingController();
  final _tagInput = TextEditingController();
  String? _selectedGroupId;
  int _selectedColor = TagStore.palette.first;

  TagStore get _store => TagStore.instance;

  @override
  void initState() {
    super.initState();
    _selectedGroupId =
        _store.groups.isNotEmpty ? _store.groups.first.id : null;
  }

  @override
  void dispose() {
    _groupInput.dispose();
    _tagInput.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final colors = themeColors;
    return Dialog(
      backgroundColor: colors['editor.background'],
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: colors['widget.border']),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 660, maxHeight: 520),
        child: ListenableBuilder(
          listenable: _store,
          builder: (context, _) {
            final groups = _store.groups;
            final activeGroupId = groups.any((g) => g.id == _selectedGroupId)
                ? _selectedGroupId!
                : (groups.isNotEmpty ? groups.first.id : '');
            final groupTags = _store.tagsInGroup(activeGroupId);

            return Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(Codicons.tag, size: 16, color: colors['foreground']),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          isZh ? '标签与标签分组管理' : 'Manage Tags & Tag Groups',
                          style: TextStyle(
                            color: colors['foreground'],
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IdeButton(
                        label: isZh ? '关闭' : 'Close',
                        secondary: true,
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Left: Tag Groups
                        SizedBox(
                          width: 220,
                          child: Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: colors['sideBar.background'],
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
                                Text(
                                  isZh ? '标签分组' : 'Tag Groups',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: colors['descriptionForeground'],
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Expanded(
                                      child: IdeInputBox(
                                        controller: _groupInput,
                                        placeholder: isZh ? '新分组名' : 'New group',
                                        onSubmitted: (_) => _createGroup(),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    IdeButton(
                                      label: '+',
                                      onPressed: _createGroup,
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Expanded(
                                  child: ListView(
                                    children: [
                                      for (final g in groups)
                                        InkWell(
                                          borderRadius: BorderRadius.circular(5),
                                          onTap: () => setState(
                                            () => _selectedGroupId = g.id,
                                          ),
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 7,
                                            ),
                                            margin: const EdgeInsets.only(bottom: 4),
                                            decoration: BoxDecoration(
                                              color: g.id == activeGroupId
                                                  ? colors['list.activeSelectionBackground']
                                                        .withValues(alpha: 0.4)
                                                  : Colors.transparent,
                                              borderRadius:
                                                  BorderRadius.circular(5),
                                            ),
                                            child: Row(
                                              children: [
                                                Container(
                                                  width: 8,
                                                  height: 8,
                                                  decoration: BoxDecoration(
                                                    color: Color(g.colorValue),
                                                    shape: BoxShape.circle,
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                Expanded(
                                                  child: Text(
                                                    '${g.name} (${_store.tagsInGroup(g.id).length})',
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      fontSize: 12.5,
                                                      color:
                                                          colors['foreground'],
                                                    ),
                                                  ),
                                                ),
                                                if (groups.length > 1)
                                                  InkWell(
                                                    onTap: () =>
                                                        _store.deleteGroup(g.id),
                                                    child: Icon(
                                                      Codicons.trash,
                                                      size: 12,
                                                      color: colors[
                                                          'descriptionForeground'],
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        // Right: Tags inside selected group
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: colors['sideBar.background'],
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
                                Text(
                                  isZh ? '分组内标签' : 'Tags in Group',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: colors['descriptionForeground'],
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Expanded(
                                      child: IdeInputBox(
                                        controller: _tagInput,
                                        placeholder: isZh
                                            ? '输入新标签名'
                                            : 'New tag name',
                                        onSubmitted: (_) =>
                                            _createTag(activeGroupId),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    IdeButton(
                                      label: isZh ? '添加标签' : 'Add Tag',
                                      onPressed: () => _createTag(activeGroupId),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 6,
                                  children: [
                                    for (final c in TagStore.palette)
                                      GestureDetector(
                                        onTap: () =>
                                            setState(() => _selectedColor = c),
                                        child: Container(
                                          width: 18,
                                          height: 18,
                                          decoration: BoxDecoration(
                                            color: Color(c),
                                            shape: BoxShape.circle,
                                            border: _selectedColor == c
                                                ? Border.all(
                                                    color: Colors.white,
                                                    width: 2,
                                                  )
                                                : null,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Expanded(
                                  child: groupTags.isEmpty
                                      ? Center(
                                          child: Text(
                                            isZh
                                                ? '此分组暂无标签，上方输入框可快速添加。'
                                                : 'No tags in this group yet.',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: colors[
                                                  'descriptionForeground'],
                                            ),
                                          ),
                                        )
                                      : ListView.separated(
                                          itemCount: groupTags.length,
                                          separatorBuilder: (_, _) => Divider(
                                            height: 1,
                                            color: colors['widget.border']
                                                .withValues(alpha: 0.35),
                                          ),
                                          itemBuilder: (context, i) {
                                            final tag = groupTags[i];
                                            return Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    vertical: 6,
                                                  ),
                                              child: Row(
                                                children: [
                                                  Container(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 8,
                                                          vertical: 2,
                                                        ),
                                                    decoration: BoxDecoration(
                                                      color: Color(tag.colorValue)
                                                          .withValues(
                                                            alpha: 0.18,
                                                          ),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            10,
                                                          ),
                                                      border: Border.all(
                                                        color: Color(
                                                          tag.colorValue,
                                                        ).withValues(alpha: 0.6),
                                                      ),
                                                    ),
                                                    child: Text(
                                                      tag.name,
                                                      style: TextStyle(
                                                        fontSize: 12,
                                                        color: Color(
                                                          tag.colorValue,
                                                        ),
                                                        fontWeight:
                                                            FontWeight.w600,
                                                      ),
                                                    ),
                                                  ),
                                                  const Spacer(),
                                                  if (groups.length > 1)
                                                    PopupMenuButton<String>(
                                                      tooltip: isZh
                                                          ? '移动到其他分组'
                                                          : 'Move to group',
                                                      icon: Icon(
                                                        Codicons.folder,
                                                        size: 13,
                                                        color: colors[
                                                            'descriptionForeground'],
                                                      ),
                                                      onSelected: (gid) =>
                                                          _store.updateTag(
                                                            tag.id,
                                                            groupId: gid,
                                                          ),
                                                      itemBuilder: (_) => [
                                                        for (final g in groups)
                                                          if (g.id !=
                                                              tag.groupId)
                                                            PopupMenuItem(
                                                              value: g.id,
                                                              child: Text(
                                                                g.name,
                                                              ),
                                                            ),
                                                      ],
                                                    ),
                                                  IconButton(
                                                    icon: Icon(
                                                      Codicons.trash,
                                                      size: 13,
                                                      color: colors[
                                                          'descriptionForeground'],
                                                    ),
                                                    onPressed: () =>
                                                        _store.deleteTag(tag.id),
                                                  ),
                                                ],
                                              ),
                                            );
                                          },
                                        ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  void _createGroup() {
    final name = _groupInput.text.trim();
    if (name.isEmpty) return;
    final g = _store.addGroup(name, colorValue: _selectedColor);
    setState(() => _selectedGroupId = g.id);
    _groupInput.clear();
  }

  void _createTag(String groupId) {
    final name = _tagInput.text.trim();
    if (name.isEmpty || groupId.isEmpty) return;
    _store.addTag(name: name, groupId: groupId, colorValue: _selectedColor);
    _tagInput.clear();
  }
}

class _ThreadTagPickerDialog extends StatelessWidget {
  const _ThreadTagPickerDialog({required this.thread});

  final AgentThread thread;

  @override
  Widget build(BuildContext context) {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final colors = themeColors;
    final store = TagStore.instance;
    return Dialog(
      backgroundColor: colors['editor.background'],
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: colors['widget.border']),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 460),
        child: ListenableBuilder(
          listenable: store,
          builder: (context, _) {
            final assignedIds = store.tagsOf(thread).map((t) => t.id).toSet();
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Icon(Codicons.tag, size: 15, color: colors['foreground']),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          isZh
                              ? '为「${thread.title}」选择标签'
                              : 'Tags for "${thread.title}"',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: colors['foreground'],
                          ),
                        ),
                      ),
                      IdeButton(
                        label: isZh ? '管理分组' : 'Manage',
                        secondary: true,
                        onPressed: () {
                          Navigator.of(context).pop();
                          showTagManagerDialog(context);
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final g in store.groups) ...[
                          Padding(
                            padding: const EdgeInsets.only(top: 6, bottom: 6),
                            child: Text(
                              g.name,
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: colors['descriptionForeground'],
                              ),
                            ),
                          ),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final t in store.tagsInGroup(g.id))
                                InkWell(
                                  borderRadius: BorderRadius.circular(12),
                                  onTap: () =>
                                      store.toggleTagForThread(thread, t.id),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: assignedIds.contains(t.id)
                                          ? Color(t.colorValue)
                                          : Color(
                                              t.colorValue,
                                            ).withValues(alpha: 0.14),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: Color(t.colorValue),
                                      ),
                                    ),
                                    child: Text(
                                      t.name,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: assignedIds.contains(t.id)
                                            ? Colors.white
                                            : Color(t.colorValue),
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: IdeButton(
                      label: isZh ? '完成' : 'Done',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _HandoffDialog extends StatefulWidget {
  const _HandoffDialog({
    required this.initialBrief,
    required this.onStartNewSession,
  });

  final String initialBrief;
  final void Function(String brief) onStartNewSession;

  @override
  State<_HandoffDialog> createState() => _HandoffDialogState();
}

class _HandoffDialogState extends State<_HandoffDialog> {
  late final _controller = TextEditingController(text: widget.initialBrief);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final colors = themeColors;
    return Dialog(
      backgroundColor: colors['editor.background'],
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: colors['widget.border']),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 500),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Codicons.arrowSwap,
                    size: 15,
                    color: colors['foreground'],
                  ),
                  const SizedBox(width: 8),
                  Text(
                    isZh ? '跨会话交接 (Session Handoff)' : 'Session Handoff',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: colors['foreground'],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                isZh
                    ? '可编辑下方上下文交接摘要，点击「交接到新会话」会自动新建会话并预填，方便切换其他模型继续执行。'
                    : 'Review or edit the handoff summary below, then launch a new session with this context prefilled.',
                style: TextStyle(
                  fontSize: 12,
                  color: colors['descriptionForeground'],
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: IdeInputBox(
                  controller: _controller,
                  minLines: 12,
                  maxLines: 20,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IdeButton(
                    label: isZh ? '复制摘要' : 'Copy',
                    secondary: true,
                    onPressed: () => Clipboard.setData(
                      ClipboardData(text: _controller.text),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IdeButton(
                    label: isZh ? '取消' : 'Cancel',
                    secondary: true,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 8),
                  IdeButton(
                    label: isZh ? '交接到新会话' : 'Start Handoff Session',
                    icon: Codicons.arrowRight,
                    onPressed: () {
                      final text = _controller.text.trim();
                      Navigator.of(context).pop();
                      if (text.isNotEmpty) widget.onStartNewSession(text);
                    },
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
