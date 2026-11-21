import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../chat/chat_models.dart';
import '../platform/data_dir.dart';
import '../workspace/workspace.dart';

/// A named category/group that organizes session tags (e.g. Priority, Status, Topic).
@immutable
class TagGroup {
  const TagGroup({
    required this.id,
    required this.name,
    required this.colorValue,
    this.collapsed = false,
  });

  final String id;
  final String name;
  final int colorValue;
  final bool collapsed;

  TagGroup copyWith({String? name, int? colorValue, bool? collapsed}) =>
      TagGroup(
        id: id,
        name: name ?? this.name,
        colorValue: colorValue ?? this.colorValue,
        collapsed: collapsed ?? this.collapsed,
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'colorValue': colorValue,
    'collapsed': collapsed,
  };

  static TagGroup? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'] as String?;
    final name = raw['name'] as String?;
    if (id == null || id.isEmpty || name == null || name.trim().isEmpty) {
      return null;
    }
    return TagGroup(
      id: id,
      name: name.trim(),
      colorValue: (raw['colorValue'] as num?)?.toInt() ?? 0xFF58A6FF,
      collapsed: raw['collapsed'] == true,
    );
  }
}

/// A single tag belonging to a [TagGroup].
@immutable
class SessionTag {
  const SessionTag({
    required this.id,
    required this.name,
    required this.groupId,
    required this.colorValue,
  });

  final String id;
  final String name;
  final String groupId;
  final int colorValue;

  SessionTag copyWith({String? name, String? groupId, int? colorValue}) =>
      SessionTag(
        id: id,
        name: name ?? this.name,
        groupId: groupId ?? this.groupId,
        colorValue: colorValue ?? this.colorValue,
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'groupId': groupId,
    'colorValue': colorValue,
  };

  static SessionTag? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'] as String?;
    final name = raw['name'] as String?;
    final groupId = raw['groupId'] as String?;
    if (id == null ||
        id.isEmpty ||
        name == null ||
        name.trim().isEmpty ||
        groupId == null ||
        groupId.isEmpty) {
      return null;
    }
    return SessionTag(
      id: id,
      name: name.trim(),
      groupId: groupId,
      colorValue: (raw['colorValue'] as num?)?.toInt() ?? 0xFF58A6FF,
    );
  }
}

/// Persistent store for grouped session tags, sidebar tag/group filters,
/// and cross-session handoff summary generation.
class TagStore extends ChangeNotifier {
  TagStore._();
  static final instance = TagStore._();

  static const defaultGroups = [
    TagGroup(id: 'priority', name: '优先级', colorValue: 0xFFE5534B),
    TagGroup(id: 'status', name: '状态', colorValue: 0xFF3FB950),
    TagGroup(id: 'topic', name: '主题', colorValue: 0xFF58A6FF),
  ];

  static const defaultTags = [
    SessionTag(
      id: 'p0',
      name: '紧急',
      groupId: 'priority',
      colorValue: 0xFFE5534B,
    ),
    SessionTag(
      id: 'p1',
      name: '高优',
      groupId: 'priority',
      colorValue: 0xFFD29922,
    ),
    SessionTag(
      id: 'wip',
      name: '进行中',
      groupId: 'status',
      colorValue: 0xFF58A6FF,
    ),
    SessionTag(
      id: 'done',
      name: '已完成',
      groupId: 'status',
      colorValue: 0xFF3FB950,
    ),
    SessionTag(
      id: 'bug',
      name: 'Bug',
      groupId: 'topic',
      colorValue: 0xFFF78166,
    ),
    SessionTag(
      id: 'feat',
      name: '需求',
      groupId: 'topic',
      colorValue: 0xFFA371F7,
    ),
  ];

  static const palette = [
    0xFFE5534B,
    0xFFD29922,
    0xFF3FB950,
    0xFF58A6FF,
    0xFFA371F7,
    0xFFF778BA,
    0xFF39C5CF,
    0xFF8B949E,
  ];

  @visibleForTesting
  String? storagePathOverride;

  List<TagGroup> _groups = [...defaultGroups];
  List<SessionTag> _tags = [...defaultTags];
  final Map<String, List<String>> _sessionTags = {};
  String? _filterTagId;
  String? _filterGroupId;
  bool _loaded = false;

  List<TagGroup> get groups => List.unmodifiable(_groups);
  List<SessionTag> get tags => List.unmodifiable(_tags);
  String? get filterTagId => _filterTagId;
  String? get filterGroupId => _filterGroupId;
  bool get hasFilter => _filterTagId != null || _filterGroupId != null;

  String get _filePath =>
      storagePathOverride ?? p.join(DataDirectory.current.path, 'tags.json');

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = File(_filePath);
      if (!file.existsSync()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return;
      final rawGroups = decoded['groups'];
      if (rawGroups is List && rawGroups.isNotEmpty) {
        final parsed = [for (final g in rawGroups) ?TagGroup.fromJson(g)];
        if (parsed.isNotEmpty) _groups = parsed;
      }
      final rawTags = decoded['tags'];
      if (rawTags is List) {
        _tags = [for (final t in rawTags) ?SessionTag.fromJson(t)];
      }
      final rawAssignments = decoded['sessionTags'];
      if (rawAssignments is Map) {
        _sessionTags.clear();
        for (final entry in rawAssignments.entries) {
          if (entry.value is List) {
            final ids = [
              for (final id in entry.value as List)
                if (id is String) id,
            ];
            if (ids.isNotEmpty) _sessionTags['${entry.key}'] = ids;
          }
        }
      }
      notifyListeners();
    } on Object catch (e) {
      debugPrint('TagStore load failed: $e');
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
          'groups': [for (final g in _groups) g.toJson()],
          'tags': [for (final t in _tags) t.toJson()],
          'sessionTags': _sessionTags,
        }),
      );
    } on Object catch (e) {
      debugPrint('TagStore save failed: $e');
    }
  }

  /// Stable key for an [AgentThread] whether open or persisted on disk.
  static String threadKey(AgentThread thread) =>
      thread.id ?? '${thread.project.path}::${thread.title}';

  List<SessionTag> tagsInGroup(String groupId) =>
      [for (final t in _tags) if (t.groupId == groupId) t];

  SessionTag? tagById(String id) {
    for (final t in _tags) {
      if (t.id == id) return t;
    }
    return null;
  }

  TagGroup? groupById(String id) {
    for (final g in _groups) {
      if (g.id == id) return g;
    }
    return null;
  }

  List<SessionTag> tagsOfKey(String key) {
    final ids = _sessionTags[key];
    if (ids == null || ids.isEmpty) return const [];
    return [for (final id in ids) ?tagById(id)];
  }

  List<SessionTag> tagsOf(AgentThread thread) => tagsOfKey(threadKey(thread));

  bool matchesFilter(AgentThread thread) {
    if (!hasFilter) return true;
    final assigned = tagsOf(thread);
    if (_filterTagId != null) {
      return assigned.any((t) => t.id == _filterTagId);
    }
    if (_filterGroupId != null) {
      return assigned.any((t) => t.groupId == _filterGroupId);
    }
    return true;
  }

  void setFilterTag(String? tagId) {
    _filterTagId = _filterTagId == tagId ? null : tagId;
    _filterGroupId = null;
    notifyListeners();
  }

  void setFilterGroup(String? groupId) {
    _filterGroupId = _filterGroupId == groupId ? null : groupId;
    _filterTagId = null;
    notifyListeners();
  }

  void clearFilter() {
    if (!hasFilter) return;
    _filterTagId = null;
    _filterGroupId = null;
    notifyListeners();
  }

  TagGroup addGroup(String name, {int? colorValue}) {
    final trimmed = name.trim();
    final group = TagGroup(
      id: 'grp_${DateTime.now().microsecondsSinceEpoch}',
      name: trimmed,
      colorValue: colorValue ?? palette[_groups.length % palette.length],
    );
    _groups = [..._groups, group];
    notifyListeners();
    unawaited(_save());
    return group;
  }

  void renameGroup(String groupId, String name, {int? colorValue}) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    _groups = [
      for (final g in _groups)
        g.id == groupId
            ? g.copyWith(name: trimmed, colorValue: colorValue)
            : g,
    ];
    notifyListeners();
    unawaited(_save());
  }

  void toggleGroupCollapsed(String groupId) {
    _groups = [
      for (final g in _groups)
        g.id == groupId ? g.copyWith(collapsed: !g.collapsed) : g,
    ];
    notifyListeners();
    unawaited(_save());
  }

  void deleteGroup(String groupId) {
    if (_groups.length <= 1) return;
    final fallbackId = _groups.firstWhere((g) => g.id != groupId).id;
    _groups = [for (final g in _groups) if (g.id != groupId) g];
    // Move orphaned tags into the first remaining group so user data isn't lost.
    _tags = [
      for (final t in _tags)
        t.groupId == groupId ? t.copyWith(groupId: fallbackId) : t,
    ];
    if (_filterGroupId == groupId) _filterGroupId = null;
    notifyListeners();
    unawaited(_save());
  }

  SessionTag addTag({
    required String name,
    required String groupId,
    int? colorValue,
  }) {
    final group = groupById(groupId) ?? _groups.first;
    final tag = SessionTag(
      id: 'tag_${DateTime.now().microsecondsSinceEpoch}',
      name: name.trim(),
      groupId: group.id,
      colorValue: colorValue ?? group.colorValue,
    );
    _tags = [..._tags, tag];
    notifyListeners();
    unawaited(_save());
    return tag;
  }

  void updateTag(
    String tagId, {
    String? name,
    String? groupId,
    int? colorValue,
  }) {
    _tags = [
      for (final t in _tags)
        t.id == tagId
            ? t.copyWith(
                name: name?.trim().isNotEmpty == true ? name!.trim() : null,
                groupId: groupId,
                colorValue: colorValue,
              )
            : t,
    ];
    notifyListeners();
    unawaited(_save());
  }

  void deleteTag(String tagId) {
    _tags = [for (final t in _tags) if (t.id != tagId) t];
    for (final list in _sessionTags.values) {
      list.remove(tagId);
    }
    _sessionTags.removeWhere((_, v) => v.isEmpty);
    if (_filterTagId == tagId) _filterTagId = null;
    notifyListeners();
    unawaited(_save());
  }

  void toggleTagForKey(String key, String tagId) {
    final list = [...?_sessionTags[key]];
    if (list.contains(tagId)) {
      list.remove(tagId);
    } else {
      list.add(tagId);
    }
    if (list.isEmpty) {
      _sessionTags.remove(key);
    } else {
      _sessionTags[key] = list;
    }
    notifyListeners();
    unawaited(_save());
  }

  void toggleTagForThread(AgentThread thread, String tagId) =>
      toggleTagForKey(threadKey(thread), tagId);

  /// Generates a structured cross-session Handoff prompt from [thread] so the
  /// user can seamlessly hand context off to another model or fresh session.
  static String buildHandoffBrief(AgentThread thread) {
    final buf = StringBuffer()
      ..writeln('# Session Handoff Context')
      ..writeln('- **Original Session**: ${thread.title}')
      ..writeln('- **Project**: ${thread.project.path}');

    final tags = TagStore.instance.tagsOf(thread);
    if (tags.isNotEmpty) {
      buf.writeln('- **Tags**: ${tags.map((t) => t.name).join(', ')}');
    }

    if (thread.isOpen) {
      final session = thread.session;
      final changes = session.fileChanges;
      if (changes.isNotEmpty) {
        buf.writeln('\n## Modified Files');
        for (final c in changes.take(25)) {
          buf.writeln('- `${c.path}` (${c.kind.name})');
        }
      }
      final excerpts = <String>[];
      final count = session.itemCount;
      final start = count > 14 ? count - 14 : 0;
      for (var i = start; i < count; i++) {
        final item = session.itemAt(i);
        if (item is UserMessageItem && item.text.trim().isNotEmpty) {
          excerpts.add('**User**: ${oneLineExcerpt(item.text, max: 240)}');
        } else if (item is AssistantTextItem && item.text.trim().isNotEmpty) {
          excerpts.add('**Assistant**: ${oneLineExcerpt(item.text, max: 320)}');
        }
      }
      if (excerpts.isNotEmpty) {
        buf.writeln('\n## Recent Conversation Highlights');
        for (final line in excerpts) {
          buf.writeln('- $line');
        }
      }
    }

    buf.writeln(
      '\n---\n请基于以上交接上下文继续推进任务。先确认当前状态，再说明下一步计划。',
    );
    return buf.toString();
  }
}
