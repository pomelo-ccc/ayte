import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import '../platform/data_dir.dart';
import '../theme/codicons.dart';
import '../workspace/workspace_hub_view.dart';

/// Top-level navigation entries in the left sidebar (beside "New Conversation").
enum SidebarNavItem {
  customize,
  stash,
  tasks,
  automations,
  library,
  canvas;

  static SidebarNavItem? parse(Object? raw) => values.asNameMap()[raw];

  IconData get icon => switch (this) {
    customize => Codicons.sparkle,
    stash => Codicons.note,
    tasks => WorkspacePage.tasks.icon,
    automations => WorkspacePage.automations.icon,
    library => WorkspacePage.library.icon,
    canvas => WorkspacePage.canvas.icon,
  };

  String label(bool isZh) => switch (this) {
    customize => isZh ? '插件' : 'Customize',
    stash => 'Stash',
    tasks => WorkspacePage.tasks.label(isZh),
    automations => WorkspacePage.automations.label(isZh),
    library => WorkspacePage.library.label(isZh),
    canvas => WorkspacePage.canvas.label(isZh),
  };

  String description(bool isZh) => switch (this) {
    customize => isZh ? 'Skills、MCP 与扩展工具管理' : 'Skills, MCP servers & tools',
    stash => isZh ? '跨会话暂存笔记与上下文片段' : 'Quick notes & saved context',
    tasks => isZh ? '无人值守队列与串行工作流执行' : 'Unattended & serial task queue',
    automations => isZh ? 'Cron 定时自动化任务' : 'Scheduled Cron automations',
    library => isZh ? '会话文档、PDF 与 Office 预览' : 'Session docs, PDF & Office preview',
    canvas => isZh ? '可视化 DAG 工作流编排与画布' : 'Visual DAG workflow canvas',
  };
}

/// Manages visibility and display order of the left sidebar's top navigation
/// entries, persisted to `sidebar_nav.json`.
class SidebarNavConfig extends ChangeNotifier {
  SidebarNavConfig._();
  static final instance = SidebarNavConfig._();

  /// Trim, high-frequency default set; remaining items stay 1 click away under
  /// "More" and can be pinned/reordered anytime.
  static const List<SidebarNavItem> defaultVisible = [
    SidebarNavItem.customize,
    SidebarNavItem.stash,
    SidebarNavItem.tasks,
    SidebarNavItem.canvas,
  ];

  @visibleForTesting
  String? storagePathOverride;

  List<SidebarNavItem> _visible = [...defaultVisible];
  bool _loaded = false;

  List<SidebarNavItem> get visibleItems => List.unmodifiable(_visible);

  List<SidebarNavItem> get hiddenItems => [
    for (final item in SidebarNavItem.values)
      if (!_visible.contains(item)) item,
  ];

  bool isVisible(SidebarNavItem item) => _visible.contains(item);

  String get _filePath =>
      storagePathOverride ??
      p.join(DataDirectory.current.path, 'sidebar_nav.json');

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = File(_filePath);
      if (!file.existsSync()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map && decoded['visible'] is List) {
        final parsed = <SidebarNavItem>[];
        for (final raw in decoded['visible'] as List) {
          final item = SidebarNavItem.parse(raw);
          if (item != null && !parsed.contains(item)) parsed.add(item);
        }
        _visible = parsed;
        notifyListeners();
      }
    } on Object catch (e) {
      debugPrint('SidebarNavConfig load failed: $e');
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
        const JsonEncoder.withIndent('  ').convert({
          'visible': [for (final item in _visible) item.name],
        }),
      );
    } on Object catch (e) {
      debugPrint('SidebarNavConfig save failed: $e');
    }
  }

  void showItem(SidebarNavItem item) {
    if (_visible.contains(item)) return;
    _visible = [..._visible, item];
    notifyListeners();
    unawaited(_save());
  }

  void hideItem(SidebarNavItem item) {
    if (!_visible.contains(item)) return;
    _visible = [for (final i in _visible) if (i != item) i];
    notifyListeners();
    unawaited(_save());
  }

  void toggleItem(SidebarNavItem item) {
    if (_visible.contains(item)) {
      hideItem(item);
    } else {
      showItem(item);
    }
  }

  /// Moves the item at [oldIndex] directly to [newIndex] (already adjusted,
  /// matching Flutter's `ReorderableListView.onReorderItem`).
  void reorderVisible(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _visible.length) return;
    final target = newIndex.clamp(0, _visible.length - 1);
    if (oldIndex == target) return;
    final next = [..._visible];
    final moved = next.removeAt(oldIndex);
    next.insert(target, moved);
    _visible = next;
    notifyListeners();
    unawaited(_save());
  }

  void moveUp(SidebarNavItem item) {
    final idx = _visible.indexOf(item);
    if (idx <= 0) return;
    reorderVisible(idx, idx - 1);
  }

  void moveDown(SidebarNavItem item) {
    final idx = _visible.indexOf(item);
    if (idx < 0 || idx >= _visible.length - 1) return;
    reorderVisible(idx, idx + 1);
  }

  void resetDefaults() {
    _visible = [...defaultVisible];
    notifyListeners();
    unawaited(_save());
  }
}
