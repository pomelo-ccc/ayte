import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../browser/embedded/embedded_browser_controller.dart';
import '../chat/chat_session.dart';
import '../ide/ide_button.dart';
import '../ide/ide_input.dart';
import '../theme/app_theme.dart';
import '../theme/codicons.dart';
import '../theme/workbench_theme.dart' show themeColors;
import '../workspace/editor_launcher.dart' show openExternal;
import 'document_preview_service.dart';

class _LibraryEntry {
  const _LibraryEntry({
    required this.path,
    required this.name,
    required this.kind,
    required this.modified,
    this.fromSession = false,
  });

  final String path;
  final String name;
  final LibraryDocKind kind;
  final DateTime modified;
  final bool fromSession;
}

/// Library panel that aggregates documents, Office files, PDFs, images, and
/// artifacts touched by the session or present in the workspace, with inline
/// structured previews for `.docx`, `.xlsx`, `.pptx`, `.pdf`, images, and docs.
class LibraryView extends StatefulWidget {
  const LibraryView({super.key, required this.session});

  final ChatSession session;

  @override
  State<LibraryView> createState() => _LibraryViewState();
}

class _LibraryViewState extends State<LibraryView> {
  final _searchCtrl = TextEditingController();
  List<_LibraryEntry> _entries = const [];
  String _category = 'all'; // all | office | image | doc
  _LibraryEntry? _selected;
  DocumentPreviewResult? _preview;
  bool _loadingPreview = false;
  int _selectedSheet = 0;

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() => setState(() {}));
    unawaited(_scan());
  }

  @override
  void didUpdateWidget(LibraryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session.root != widget.session.root) {
      unawaited(_scan());
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final seen = <String>{};
    final items = <_LibraryEntry>[];

    // 1. Files touched by the active session first.
    for (final change in widget.session.fileChanges) {
      final path = change.path;
      if (seen.add(path) && File(path).existsSync()) {
        final kind = LibraryDocKind.fromPath(path);
        final stat = File(path).statSync();
        items.add(
          _LibraryEntry(
            path: path,
            name: p.basename(path),
            kind: kind,
            modified: stat.modified,
            fromSession: true,
          ),
        );
      }
    }

    // 2. Scan workspace directory (bounded depth) for Office / PDF / docs / images.
    final root = widget.session.root;
    if (root != null && Directory(root).existsSync()) {
      await _walk(Directory(root), 0, seen, items);
    }

    items.sort((a, b) {
      if (a.fromSession != b.fromSession) return a.fromSession ? -1 : 1;
      return b.modified.compareTo(a.modified);
    });
    if (mounted) {
      setState(() => _entries = items);
    }
  }

  Future<void> _walk(
    Directory dir,
    int depth,
    Set<String> seen,
    List<_LibraryEntry> out,
  ) async {
    if (depth > 3 || out.length >= 200) return;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (out.length >= 200) return;
        final name = p.basename(entity.path);
        if (name.startsWith('.') ||
            const {
              'node_modules',
              'build',
              '.dart_tool',
              'dist',
              'target',
              '.git',
            }.contains(name)) {
          continue;
        }
        if (entity is Directory) {
          await _walk(entity, depth + 1, seen, out);
        } else if (entity is File) {
          final kind = LibraryDocKind.fromPath(entity.path);
          if (kind == LibraryDocKind.other) continue;
          if (!seen.add(entity.path)) continue;
          final stat = entity.statSync();
          out.add(
            _LibraryEntry(
              path: entity.path,
              name: name,
              kind: kind,
              modified: stat.modified,
            ),
          );
        }
      }
    } on Object {
      // Ignore permission errors.
    }
  }

  Future<void> _select(_LibraryEntry entry) async {
    setState(() {
      _selected = entry;
      _loadingPreview = true;
      _preview = null;
      _selectedSheet = 0;
    });
    final res = await DocumentPreviewService.loadPreview(entry.path);
    if (!mounted || _selected?.path != entry.path) return;
    setState(() {
      _preview = res;
      _loadingPreview = false;
    });
  }

  List<_LibraryEntry> get _filtered {
    final q = _searchCtrl.text.trim().toLowerCase();
    return [
      for (final e in _entries)
        if ((_category == 'all' ||
                (_category == 'office' && e.kind.isOfficeOrPdf) ||
                (_category == 'image' && e.kind == LibraryDocKind.image) ||
                (_category == 'doc' &&
                    (e.kind == LibraryDocKind.markdown ||
                        e.kind == LibraryDocKind.html ||
                        e.kind == LibraryDocKind.data))) &&
            (q.isEmpty ||
                e.name.toLowerCase().contains(q) ||
                e.path.toLowerCase().contains(q)))
          e,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final colors = themeColors;
    final list = _filtered;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: colors['widget.border'].withValues(alpha: 0.4),
              ),
            ),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: IdeInputBox(
                      controller: _searchCtrl,
                      placeholder: isZh
                          ? '搜索资料库（PDF / Word / Excel / PPT / 图片）'
                          : 'Search library (PDF / Office / Images / Docs)',
                    ),
                  ),
                  const SizedBox(width: 6),
                  IdeButton(
                    label: isZh ? '刷新' : 'Refresh',
                    icon: Codicons.refresh,
                    secondary: true,
                    onPressed: () => unawaited(_scan()),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  for (final c in [
                    ('all', isZh ? '全部' : 'All'),
                    ('office', 'Office / PDF'),
                    ('image', isZh ? '图片' : 'Images'),
                    ('doc', isZh ? '文档/数据' : 'Docs & Data'),
                  ])
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(4),
                        onTap: () => setState(() => _category = c.$1),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: _category == c.$1
                                ? colors['button.background'].withValues(
                                    alpha: 0.2,
                                  )
                                : colors['sideBar.background'],
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: _category == c.$1
                                  ? colors['button.background']
                                  : colors['widget.border'].withValues(
                                      alpha: 0.4,
                                    ),
                            ),
                          ),
                          child: Text(
                            c.$2,
                            style: TextStyle(
                              fontSize: 11,
                              color: colors['foreground'],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: _selected != null
              ? _buildPreviewPane(_selected!, isZh)
              : list.isEmpty
              ? Center(
                  child: Text(
                    isZh
                        ? '当前工作区暂无可预览文档或媒体文件。'
                        : 'No documents or media files found in this workspace.',
                    style: TextStyle(
                      fontSize: 12,
                      color: colors['descriptionForeground'],
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(8),
                  itemCount: list.length,
                  separatorBuilder: (_, _) => Divider(
                    height: 1,
                    color: colors['widget.border'].withValues(alpha: 0.3),
                  ),
                  itemBuilder: (context, i) {
                    final item = list[i];
                    return InkWell(
                      onTap: () => unawaited(_select(item)),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 8,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              _iconOf(item.kind),
                              size: 15,
                              color: _colorOf(item.kind),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w500,
                                      color: colors['foreground'],
                                    ),
                                  ),
                                  Text(
                                    item.fromSession
                                        ? (isZh ? '本会话产出 · ${item.path}' : 'Session artifact · ${item.path}')
                                        : item.path,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: colors['descriptionForeground'],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildPreviewPane(_LibraryEntry entry, bool isZh) {
    final colors = themeColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: colors['sideBar.background'],
            border: Border(
              bottom: BorderSide(
                color: colors['widget.border'].withValues(alpha: 0.4),
              ),
            ),
          ),
          child: Row(
            children: [
              IdeButton(
                label: isZh ? '返回列表' : 'Back',
                icon: Codicons.arrowLeft,
                secondary: true,
                onPressed: () => setState(() {
                  _selected = null;
                  _preview = null;
                }),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: colors['foreground'],
                  ),
                ),
              ),
              if (entry.kind == LibraryDocKind.pdf ||
                  entry.kind == LibraryDocKind.html)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: IdeButton(
                    label: isZh ? '内置浏览器打开' : 'Built-in Browser',
                    icon: Codicons.globe,
                    secondary: true,
                    onPressed: () => EmbeddedBrowserController.instance.openTab(
                      Uri.file(entry.path).toString(),
                    ),
                  ),
                ),
              IdeButton(
                label: isZh ? '系统打开' : 'Open External',
                icon: Codicons.linkExternal,
                secondary: true,
                onPressed: () => unawaited(openExternal(entry.path)),
              ),
            ],
          ),
        ),
        Expanded(
          child: _loadingPreview
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : _buildPreviewContent(entry, _preview, isZh),
        ),
      ],
    );
  }

  Widget _buildPreviewContent(
    _LibraryEntry entry,
    DocumentPreviewResult? res,
    bool isZh,
  ) {
    final colors = themeColors;
    if (res == null) return const SizedBox.shrink();
    if (res.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            res.error!,
            style: const TextStyle(fontSize: 12, color: Color(0xFFE5534B)),
          ),
        ),
      );
    }
    if (entry.kind == LibraryDocKind.image) {
      return InteractiveViewer(
        child: Center(
          child: Image.file(File(entry.path), fit: BoxFit.contain),
        ),
      );
    }
    if (entry.kind == LibraryDocKind.excel && res.sheets.isNotEmpty) {
      final idx = _selectedSheet.clamp(0, res.sheets.length - 1);
      final sheet = res.sheets[idx];
      final maxCols = sheet.rows.fold<int>(
        0,
        (m, r) => r.length > m ? r.length : m,
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (res.sheets.length > 1)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Wrap(
                spacing: 6,
                children: [
                  for (var i = 0; i < res.sheets.length; i++)
                    IdeButton(
                      label: res.sheets[i].name,
                      secondary: i != idx,
                      onPressed: () => setState(() => _selectedSheet = i),
                    ),
                ],
              ),
            ),
          Expanded(
            child: maxCols == 0
                ? Center(
                    child: Text(
                      isZh ? '空工作表' : 'Empty sheet',
                      style: TextStyle(color: colors['descriptionForeground']),
                    ),
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(8),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        headingRowHeight: 30,
                        dataRowMinHeight: 26,
                        dataRowMaxHeight: 34,
                        columns: [
                          for (var c = 0; c < maxCols; c++)
                            DataColumn(
                              label: Text(
                                sheet.rows.isNotEmpty && c < sheet.rows.first.length
                                    ? sheet.rows.first[c]
                                    : 'Col ${c + 1}',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: colors['foreground'],
                                ),
                              ),
                            ),
                        ],
                        rows: [
                          for (final r in sheet.rows.skip(1))
                            DataRow(
                              cells: [
                                for (var c = 0; c < maxCols; c++)
                                  DataCell(
                                    Text(
                                      c < r.length ? r[c] : '',
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        color: colors['foreground'],
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
          ),
        ],
      );
    }
    if (entry.kind == LibraryDocKind.powerpoint && res.slides.isNotEmpty) {
      return ListView.separated(
        padding: const EdgeInsets.all(10),
        itemCount: res.slides.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, i) {
          final slide = res.slides[i];
          return Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors['sideBar.background'],
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: colors['widget.border'].withValues(alpha: 0.6),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isZh ? '第 ${slide.index} 页' : 'Slide ${slide.index}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: colors['descriptionForeground'],
                  ),
                ),
                const SizedBox(height: 6),
                for (final line in slide.lines)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      line,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: colors['foreground'],
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: SelectableText(
        res.text.isEmpty ? (isZh ? '（无文本内容）' : '(No text content)') : res.text,
        style: TextStyle(
          fontSize: 12,
          height: 1.5,
          fontFamily: entry.kind == LibraryDocKind.data ? AppFonts.mono : null,
          color: colors['editor.foreground'],
        ),
      ),
    );
  }

  static IconData _iconOf(LibraryDocKind kind) => switch (kind) {
    LibraryDocKind.pdf => Codicons.filePdf,
    LibraryDocKind.word => Codicons.fileText,
    LibraryDocKind.excel => Codicons.table,
    LibraryDocKind.powerpoint => Codicons.preview,
    LibraryDocKind.image => Codicons.fileMedia,
    LibraryDocKind.markdown => Codicons.markdown,
    LibraryDocKind.html => Codicons.globe,
    LibraryDocKind.data => Codicons.json,
    LibraryDocKind.other => Codicons.file,
  };

  static Color _colorOf(LibraryDocKind kind) => switch (kind) {
    LibraryDocKind.pdf => const Color(0xFFE5534B),
    LibraryDocKind.word => const Color(0xFF58A6FF),
    LibraryDocKind.excel => const Color(0xFF3FB950),
    LibraryDocKind.powerpoint => const Color(0xFFD29922),
    LibraryDocKind.image => const Color(0xFFA371F7),
    _ => const Color(0xFF8B949E),
  };
}
