import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';
import '../../theme/codicons.dart';
import '../../theme/workbench_theme.dart' show themeColors;

/// Parses RFC 6902 JSONL Patch lines (or a single JSON object) produced by the
/// `ui-render` / `json-render` spec into an interactive UI tree + state model.
class SpecDocument {
  SpecDocument({
    required this.rootId,
    required this.elements,
    required this.state,
  });

  final String rootId;
  final Map<String, Map<String, Object?>> elements;
  final Map<String, Object?> state;

  static SpecDocument? parse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    // 1. Try single complete JSON object format: {"root": ..., "elements": ..., "state": ...}
    if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map<String, Object?> &&
            decoded.containsKey('root') &&
            decoded['elements'] is Map) {
          final elements = <String, Map<String, Object?>>{};
          for (final e in (decoded['elements'] as Map).entries) {
            if (e.value is Map) {
              elements['${e.key}'] = Map<String, Object?>.from(e.value as Map);
            }
          }
          final state = decoded['state'] is Map
              ? _deepCopyMap(decoded['state'] as Map)
              : <String, Object?>{};
          return SpecDocument(
            rootId: '${decoded['root']}',
            elements: elements,
            state: state,
          );
        }
      } on Object {
        // Fall through to JSONL patch parsing.
      }
    }

    // 2. Parse RFC 6902 JSONL patch lines.
    final doc = <String, Object?>{
      'elements': <String, Object?>{},
      'state': <String, Object?>{},
    };
    var applied = 0;
    for (final line in trimmed.split('\n')) {
      final l = line.trim();
      if (l.isEmpty) continue;
      try {
        final patch = jsonDecode(l);
        if (patch is! Map) continue;
        final op = patch['op'] as String?;
        final path = patch['path'] as String?;
        if (op == null || path == null || !path.startsWith('/')) continue;
        _applyPatch(doc, op, path, patch['value']);
        applied++;
      } on Object {
        // Ignore partial streaming lines.
      }
    }
    if (applied == 0) return null;
    final root = doc['root'];
    if (root is! String || root.isEmpty) return null;
    final rawElems = doc['elements'];
    if (rawElems is! Map) return null;
    final elements = <String, Map<String, Object?>>{};
    for (final e in rawElems.entries) {
      if (e.value is Map) {
        elements['${e.key}'] = Map<String, Object?>.from(e.value as Map);
      }
    }
    final state = doc['state'] is Map
        ? _deepCopyMap(doc['state'] as Map)
        : <String, Object?>{};
    return SpecDocument(rootId: root, elements: elements, state: state);
  }

  static Map<String, Object?> _deepCopyMap(Map<Object?, Object?> src) => {
    for (final e in src.entries) '${e.key}': _deepCopyValue(e.value),
  };

  static Object? _deepCopyValue(Object? v) {
    if (v is Map) return _deepCopyMap(v);
    if (v is List) return [for (final i in v) _deepCopyValue(i)];
    return v;
  }

  static List<String> _decodePointer(String path) => path
      .substring(1)
      .split('/')
      .map((s) => s.replaceAll('~1', '/').replaceAll('~0', '~'))
      .toList();

  static void _applyPatch(
    Map<String, Object?> root,
    String op,
    String path,
    Object? value,
  ) {
    final segs = _decodePointer(path);
    if (segs.isEmpty) return;
    Object? curr = root;
    for (var i = 0; i < segs.length - 1; i++) {
      final seg = segs[i];
      if (curr is Map<String, Object?>) {
        curr = curr.putIfAbsent(seg, () => <String, Object?>{});
      } else if (curr is List<Object?>) {
        final idx = int.tryParse(seg);
        if (idx == null || idx < 0 || idx >= curr.length) return;
        curr = curr[idx];
      } else {
        return;
      }
    }
    final last = segs.last;
    if (curr is Map<String, Object?>) {
      if (op == 'remove') {
        curr.remove(last);
      } else {
        curr[last] = _deepCopyValue(value);
      }
    } else if (curr is List<Object?>) {
      if (op == 'remove') {
        final idx = int.tryParse(last);
        if (idx != null && idx >= 0 && idx < curr.length) curr.removeAt(idx);
      } else if (last == '-') {
        curr.add(_deepCopyValue(value));
      } else {
        final idx = int.tryParse(last);
        if (idx == null || idx < 0) return;
        if (idx < curr.length) {
          if (op == 'add') {
            curr.insert(idx, _deepCopyValue(value));
          } else {
            curr[idx] = _deepCopyValue(value);
          }
        } else if (idx == curr.length) {
          curr.add(_deepCopyValue(value));
        }
      }
    }
  }

  static Object? readPointer(Map<String, Object?> state, String pointer) {
    if (pointer.isEmpty || pointer == '/') return state;
    final norm = pointer.startsWith('/') ? pointer : '/$pointer';
    Object? curr = state;
    for (final seg in _decodePointer(norm)) {
      if (curr is Map) {
        curr = curr[seg];
      } else if (curr is List) {
        final idx = int.tryParse(seg);
        if (idx == null || idx < 0 || idx >= curr.length) return null;
        curr = curr[idx];
      } else {
        return null;
      }
    }
    return curr;
  }

  static void writePointer(
    Map<String, Object?> state,
    String pointer,
    Object? value,
  ) {
    final norm = pointer.startsWith('/') ? pointer : '/$pointer';
    _applyPatch(state, 'replace', norm, value);
  }
}

/// Interactive Flutter widget renderer for ```` ```spec ```` code blocks inside
/// chat replies (cards, tables, charts, tabs, accordions, metrics, badges,
/// progress bars, checklists, inputs, buttons).
class SpecRenderBlock extends StatefulWidget {
  const SpecRenderBlock({super.key, required this.code});

  final String code;

  @override
  State<SpecRenderBlock> createState() => _SpecRenderBlockState();
}

class _SpecRenderBlockState extends State<SpecRenderBlock> {
  SpecDocument? _doc;
  Map<String, Object?> _state = {};
  bool _showSource = false;
  bool _copied = false;
  final Map<String, int> _tabSelections = {};
  final Map<String, bool> _accordionOpen = {};
  final Map<String, ({int col, bool asc})> _tableSorts = {};
  final Map<String, TextEditingController> _inputControllers = {};
  int _idSeq = 0;

  @override
  void initState() {
    super.initState();
    _reparse();
  }

  @override
  void didUpdateWidget(SpecRenderBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.code != widget.code) {
      _reparse();
    }
  }

  @override
  void dispose() {
    for (final c in _inputControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _reparse() {
    final parsed = SpecDocument.parse(widget.code);
    _doc = parsed;
    if (parsed != null) {
      _state = SpecDocument._deepCopyMap(parsed.state);
    }
  }

  Object? _resolveExpr(
    Object? raw, {
    Object? item,
    int? index,
    String? itemPath,
  }) {
    if (raw is Map) {
      if (raw.containsKey(r'$state')) {
        return SpecDocument.readPointer(_state, '${raw[r'$state']}');
      }
      if (raw.containsKey(r'$bindState')) {
        return SpecDocument.readPointer(_state, '${raw[r'$bindState']}');
      }
      if (raw.containsKey(r'$item')) {
        final field = '${raw[r'$item']}';
        if (field.isEmpty) return item;
        return item is Map ? item[field] : null;
      }
      if (raw.containsKey(r'$bindItem')) {
        final field = '${raw[r'$bindItem']}';
        return item is Map ? item[field] : null;
      }
      if (raw.containsKey(r'$index')) return index;
      return {
        for (final e in raw.entries)
          '${e.key}': _resolveExpr(
            e.value,
            item: item,
            index: index,
            itemPath: itemPath,
          ),
      };
    }
    if (raw is List) {
      return [
        for (final e in raw)
          _resolveExpr(e, item: item, index: index, itemPath: itemPath),
      ];
    }
    return raw;
  }

  String _str(Object? raw, {Object? item, int? index, String? itemPath}) {
    final v = _resolveExpr(raw, item: item, index: index, itemPath: itemPath);
    if (v == null) return '';
    return '$v';
  }

  void _writeBinding(
    Object? bindingExpr,
    Object? value, {
    String? itemPath,
  }) {
    if (bindingExpr is! Map) return;
    if (bindingExpr[r'$bindState'] case final String path) {
      setState(() => SpecDocument.writePointer(_state, path, value));
    } else if (bindingExpr[r'$bindItem'] case final String field
        when itemPath != null) {
      setState(
        () => SpecDocument.writePointer(_state, '$itemPath/$field', value),
      );
    }
  }

  void _runAction(
    Object? actionSpec, {
    Object? item,
    int? index,
    String? itemPath,
  }) {
    if (actionSpec is! Map) return;
    final action = actionSpec['action'] as String?;
    final params = actionSpec['params'] is Map
        ? Map<String, Object?>.from(actionSpec['params'] as Map)
        : const <String, Object?>{};
    if (action == null) return;

    setState(() {
      switch (action) {
        case 'setState':
          final path = params['statePath'] as String?;
          if (path != null) {
            final val = _resolveExpr(
              params['value'],
              item: item,
              index: index,
              itemPath: itemPath,
            );
            SpecDocument.writePointer(_state, path, val);
          }
        case 'pushState':
          final path = params['statePath'] as String?;
          if (path != null) {
            final list = SpecDocument.readPointer(_state, path);
            final resolved = _materializeIds(
              _resolveExpr(
                params['value'],
                item: item,
                index: index,
                itemPath: itemPath,
              ),
            );
            if (list is List) {
              list.add(resolved);
            } else {
              SpecDocument.writePointer(_state, path, [resolved]);
            }
          }
          if (params['clearStatePath'] case final String clearPath) {
            SpecDocument.writePointer(_state, clearPath, '');
            _inputControllers[clearPath]?.clear();
          }
        case 'removeState':
          final path = params['statePath'] as String?;
          final idxVal = _resolveExpr(
            params['index'],
            item: item,
            index: index,
            itemPath: itemPath,
          );
          final idx = idxVal is num
              ? idxVal.toInt()
              : int.tryParse('$idxVal');
          if (path != null && idx != null) {
            final list = SpecDocument.readPointer(_state, path);
            if (list is List && idx >= 0 && idx < list.length) {
              list.removeAt(idx);
            }
          }
      }
    });
  }

  Object? _materializeIds(Object? val) {
    if (val == r'$id') return 'id_${++_idSeq}';
    if (val is Map) {
      return {for (final e in val.entries) '${e.key}': _materializeIds(e.value)};
    }
    if (val is List) return [for (final e in val) _materializeIds(e)];
    return val;
  }

  @override
  Widget build(BuildContext context) {
    final colors = themeColors;
    final doc = _doc;
    if (doc == null || _showSource) {
      return _buildFallbackSource(context, hasVisual: doc != null);
    }
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: colors['sideBar.background'].withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: colors['widget.border'].withValues(alpha: 0.65),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: colors['widget.border'].withValues(alpha: 0.35),
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Codicons.layout,
                  size: 12,
                  color: colors['descriptionForeground'],
                ),
                const SizedBox(width: 6),
                Text(
                  'UI Preview',
                  style: TextStyle(
                    fontSize: 11,
                    color: colors['descriptionForeground'],
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const Spacer(),
                _MiniBarButton(
                  icon: _copied ? Codicons.check : Codicons.copy,
                  label: _copied ? 'Copied' : 'Copy',
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: widget.code));
                    setState(() => _copied = true);
                    Future<void>.delayed(const Duration(seconds: 2), () {
                      if (mounted) setState(() => _copied = false);
                    });
                  },
                ),
                const SizedBox(width: 6),
                _MiniBarButton(
                  icon: Codicons.code,
                  label: 'Source',
                  onTap: () => setState(() => _showSource = true),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: _buildNode(context, doc, doc.rootId),
          ),
        ],
      ),
    );
  }

  Widget _buildFallbackSource(BuildContext context, {required bool hasVisual}) {
    final colors = themeColors;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.code,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors['widget.border'].withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (hasVisual)
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _MiniBarButton(
                  icon: Codicons.preview,
                  label: 'Preview UI',
                  onTap: () => setState(() => _showSource = false),
                ),
              ],
            ),
          SelectableText(
            widget.code,
            style: TextStyle(
              fontFamily: AppFonts.mono,
              fontSize: 12,
              color: colors['editor.foreground'],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildChildren(
    BuildContext context,
    SpecDocument doc,
    Map<String, Object?> elem, {
    Object? item,
    int? index,
    String? itemPath,
  }) {
    final childIds = (elem['children'] as List?)?.map((e) => '$e').toList() ?? const [];
    final repeat = elem['repeat'];
    if (repeat is Map) {
      final rawPath = repeat['statePath'];
      String? listPath;
      Object? listVal;
      if (rawPath is String) {
        listPath = rawPath;
        listVal = SpecDocument.readPointer(_state, rawPath);
      } else if (rawPath is Map && rawPath.containsKey(r'$item')) {
        final field = '${rawPath[r'$item']}';
        listPath = itemPath == null
            ? null
            : (field.isEmpty ? itemPath : '$itemPath/$field');
        listVal = field.isEmpty
            ? item
            : (item is Map ? item[field] : null);
      }
      if (listVal is! List) return const [];
      final widgets = <Widget>[];
      for (var i = 0; i < listVal.length; i++) {
        final entry = listVal[i];
        final entryPath = listPath == null ? null : '$listPath/$i';
        for (final cid in childIds) {
          widgets.add(
            _buildNode(
              context,
              doc,
              cid,
              item: entry,
              index: i,
              itemPath: entryPath,
            ),
          );
        }
      }
      return widgets;
    }
    return [
      for (final cid in childIds)
        _buildNode(
          context,
          doc,
          cid,
          item: item,
          index: index,
          itemPath: itemPath,
        ),
    ];
  }

  Widget _buildNode(
    BuildContext context,
    SpecDocument doc,
    String id, {
    Object? item,
    int? index,
    String? itemPath,
  }) {
    final elem = doc.elements[id];
    if (elem == null) return const SizedBox.shrink();
    final type = (elem['type'] as String? ?? '').trim();
    final props = elem['props'] is Map
        ? Map<String, Object?>.from(elem['props'] as Map)
        : const <String, Object?>{};
    final on = elem['on'] is Map
        ? Map<String, Object?>.from(elem['on'] as Map)
        : const <String, Object?>{};
    final colors = themeColors;

    final children = _buildChildren(
      context,
      doc,
      elem,
      item: item,
      index: index,
      itemPath: itemPath,
    );

    switch (type) {
      case 'Card':
        final title = _str(props['title'], item: item, index: index, itemPath: itemPath);
        final desc = _str(props['description'], item: item, index: index, itemPath: itemPath);
        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colors['editor.background'],
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: colors['widget.border'].withValues(alpha: 0.65),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (title.isNotEmpty)
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: colors['foreground'],
                  ),
                ),
              if (desc.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  desc,
                  style: TextStyle(
                    fontSize: 12,
                    color: colors['descriptionForeground'],
                  ),
                ),
              ],
              if ((title.isNotEmpty || desc.isNotEmpty) && children.isNotEmpty)
                const SizedBox(height: 10),
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const SizedBox(height: 8),
                children[i],
              ],
            ],
          ),
        );

      case 'Stack' || 'Column' || 'Row':
        final isRow = type == 'Row' || props['direction'] == 'horizontal';
        final gap = switch (props['gap']) {
          'xs' => 4.0,
          'sm' => 6.0,
          'lg' => 14.0,
          'xl' => 18.0,
          final num n => n.toDouble(),
          _ => 8.0,
        };
        if (isRow) {
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: children,
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) SizedBox(height: gap),
              children[i],
            ],
          ],
        );

      case 'Grid':
        final cols = ((props['columns'] as num?)?.toInt() ?? 2).clamp(1, 6);
        final gap = switch (props['gap']) {
          'sm' => 6.0,
          'lg' => 14.0,
          final num n => n.toDouble(),
          _ => 10.0,
        };
        return LayoutBuilder(
          builder: (context, c) {
            final itemW = math.max(
              120.0,
              (c.maxWidth - gap * (cols - 1)) / cols,
            );
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final ch in children) SizedBox(width: itemW, child: ch),
              ],
            );
          },
        );

      case 'Heading':
        final text = _str(props['text'] ?? props['title'], item: item, index: index, itemPath: itemPath);
        final level = (props['level'] as num?)?.toInt() ?? 2;
        final size = switch (level) {
          1 => 18.0,
          3 => 13.5,
          _ => 15.0,
        };
        return Text(
          text,
          style: TextStyle(
            fontSize: size,
            fontWeight: FontWeight.w600,
            color: colors['foreground'],
          ),
        );

      case 'Text' || 'Paragraph':
        final text = _str(
          props['text'] ?? props['content'] ?? props['label'],
          item: item,
          index: index,
          itemPath: itemPath,
        );
        final muted = props['muted'] == true || props['variant'] == 'muted';
        return Text(
          text,
          style: TextStyle(
            fontSize: 12.5,
            color: muted ? colors['descriptionForeground'] : colors['foreground'],
          ),
        );

      case 'Badge' || 'Tag' || 'Chip':
        final text = _str(
          props['text'] ?? props['label'],
          item: item,
          index: index,
          itemPath: itemPath,
        );
        final tone = _badgeColor(props['variant'] as String? ?? props['color'] as String?);
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: tone.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: tone.withValues(alpha: 0.45)),
          ),
          child: Text(
            text,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: tone),
          ),
        );

      case 'Metric' || 'Stat' || 'KPI':
        final label = _str(props['label'] ?? props['title'], item: item, index: index, itemPath: itemPath);
        final value = _str(props['value'], item: item, index: index, itemPath: itemPath);
        final delta = _str(props['change'] ?? props['delta'] ?? props['trend'], item: item, index: index, itemPath: itemPath);
        return Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: colors['sideBar.background'].withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: colors['widget.border'].withValues(alpha: 0.5)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: colors['descriptionForeground'],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                value,
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                  color: colors['foreground'],
                ),
              ),
              if (delta.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  delta,
                  style: TextStyle(
                    fontSize: 11,
                    color: delta.startsWith('-')
                        ? const Color(0xFFE5534B)
                        : const Color(0xFF3FB950),
                  ),
                ),
              ],
            ],
          ),
        );

      case 'Progress' || 'ProgressBar':
        final rawVal = _resolveExpr(props['value'], item: item, index: index, itemPath: itemPath);
        final maxVal = (props['max'] as num?)?.toDouble() ?? 100.0;
        final val = (rawVal is num ? rawVal.toDouble() : double.tryParse('$rawVal') ?? 0.0);
        final pct = (maxVal <= 0 ? 0.0 : (val / maxVal)).clamp(0.0, 1.0);
        final label = _str(props['label'], item: item, index: index, itemPath: itemPath);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (label.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(label, style: TextStyle(fontSize: 12, color: colors['foreground'])),
                    Text('${(pct * 100).round()}%', style: TextStyle(fontSize: 11.5, color: colors['descriptionForeground'])),
                  ],
                ),
              ),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: pct,
                minHeight: 7,
                backgroundColor: colors['widget.border'].withValues(alpha: 0.35),
                valueColor: AlwaysStoppedAnimation(colors['button.background']),
              ),
            ),
          ],
        );

      case 'Table' || 'DataTable':
        return _buildTable(context, id, props, item: item, index: index, itemPath: itemPath);

      case 'BarChart' || 'LineChart' || 'Chart':
        return _buildChart(
          context,
          props,
          isLine: type == 'LineChart' || props['chartType'] == 'line',
          item: item,
          index: index,
          itemPath: itemPath,
        );

      case 'Tabs':
        return _buildTabs(context, id, props, children, item: item, index: index, itemPath: itemPath);

      case 'Accordion':
        final title = _str(props['title'] ?? props['label'], item: item, index: index, itemPath: itemPath);
        final open = _accordionOpen[id] ?? (props['defaultOpen'] == true);
        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: colors['widget.border'].withValues(alpha: 0.5)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InkWell(
                onTap: () => setState(() => _accordionOpen[id] = !open),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Row(
                    children: [
                      Icon(
                        open ? Codicons.chevronDown : Codicons.chevronRight,
                        size: 13,
                        color: colors['foreground'],
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          title,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                            color: colors['foreground'],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (open && children.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: children,
                  ),
                ),
            ],
          ),
        );

      case 'Checkbox' || 'CheckBox' || 'Switch':
        final label = _str(props['label'] ?? props['title'], item: item, index: index, itemPath: itemPath);
        final checkedExpr = props['checked'] ?? props['value'];
        final checked = _resolveExpr(checkedExpr, item: item, index: index, itemPath: itemPath) == true;
        return InkWell(
          onTap: () => _writeBinding(checkedExpr, !checked, itemPath: itemPath),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                checked ? Codicons.passFilled : Codicons.circleLargeOutline,
                size: 15,
                color: checked ? const Color(0xFF3FB950) : colors['descriptionForeground'],
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: checked ? colors['descriptionForeground'] : colors['foreground'],
                    decoration: checked ? TextDecoration.lineThrough : null,
                  ),
                ),
              ),
            ],
          ),
        );

      case 'Button':
        final label = _str(props['label'] ?? props['text'], item: item, index: index, itemPath: itemPath);
        final secondary = props['variant'] == 'secondary' || props['variant'] == 'ghost';
        return InkWell(
          borderRadius: BorderRadius.circular(5),
          onTap: () => _runAction(
            on['press'] ?? on['click'],
            item: item,
            index: index,
            itemPath: itemPath,
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: secondary ? colors['sideBar.background'] : colors['button.background'],
              borderRadius: BorderRadius.circular(5),
              border: Border.all(
                color: secondary ? colors['widget.border'] : colors['button.background'],
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: secondary ? colors['foreground'] : Colors.white,
              ),
            ),
          ),
        );

      case 'Input' || 'TextField':
        final valueExpr = props['value'];
        final bindKey = valueExpr is Map ? (valueExpr[r'$bindState'] as String? ?? id) : id;
        final ctrl = _inputControllers.putIfAbsent(
          bindKey,
          () => TextEditingController(
            text: _str(valueExpr, item: item, index: index, itemPath: itemPath),
          ),
        );
        final placeholder = _str(props['placeholder'], item: item, index: index, itemPath: itemPath);
        return SizedBox(
          height: 30,
          child: TextField(
            controller: ctrl,
            style: TextStyle(fontSize: 12.5, color: colors['input.foreground']),
            decoration: InputDecoration(
              hintText: placeholder,
              hintStyle: TextStyle(fontSize: 12, color: colors['input.placeholderForeground']),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              filled: true,
              fillColor: colors['input.background'],
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(5),
                borderSide: BorderSide(color: colors['input.border']),
              ),
            ),
            onChanged: (v) => _writeBinding(valueExpr, v, itemPath: itemPath),
          ),
        );

      case 'Alert' || 'Callout':
        final title = _str(props['title'], item: item, index: index, itemPath: itemPath);
        final msg = _str(props['message'] ?? props['description'] ?? props['text'], item: item, index: index, itemPath: itemPath);
        final tone = _badgeColor(props['variant'] as String? ?? 'info');
        return Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: tone.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: tone.withValues(alpha: 0.4)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (title.isNotEmpty)
                Text(title, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: tone)),
              if (msg.isNotEmpty)
                Text(msg, style: TextStyle(fontSize: 12, color: colors['foreground'])),
            ],
          ),
        );

      case 'Divider' || 'Separator':
        return Divider(height: 12, color: colors['widget.border'].withValues(alpha: 0.5));

      default:
        if (children.isNotEmpty) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          );
        }
        final fallback = _str(props['text'] ?? props['label'] ?? props['title'], item: item, index: index, itemPath: itemPath);
        return fallback.isEmpty
            ? const SizedBox.shrink()
            : Text(fallback, style: TextStyle(fontSize: 12.5, color: colors['foreground']));
    }
  }

  Widget _buildTable(
    BuildContext context,
    String id,
    Map<String, Object?> props, {
    Object? item,
    int? index,
    String? itemPath,
  }) {
    final colors = themeColors;
    final rawCols = _resolveExpr(props['columns'], item: item, index: index, itemPath: itemPath);
    final rawRows = _resolveExpr(
      props['rows'] ?? props['data'],
      item: item,
      index: index,
      itemPath: itemPath,
    );
    final cols = <({String key, String label})>[];
    if (rawCols is List) {
      for (final c in rawCols) {
        if (c is String) {
          cols.add((key: c, label: c));
        } else if (c is Map) {
          final k = '${c['key'] ?? c['accessorKey'] ?? c['label'] ?? ''}';
          final l = '${c['label'] ?? c['header'] ?? k}';
          cols.add((key: k, label: l));
        }
      }
    }
    final rows = <List<String>>[];
    if (rawRows is List) {
      for (final r in rawRows) {
        if (r is List) {
          rows.add([for (final cell in r) '${cell ?? ''}']);
        } else if (r is Map) {
          if (cols.isEmpty) {
            for (final k in r.keys) {
              cols.add((key: '$k', label: '$k'));
            }
          }
          rows.add([for (final col in cols) '${r[col.key] ?? ''}']);
        }
      }
    }
    if (cols.isEmpty) return const SizedBox.shrink();

    final sort = _tableSorts[id];
    if (sort != null && sort.col < cols.length) {
      rows.sort((a, b) {
        final av = sort.col < a.length ? a[sort.col] : '';
        final bv = sort.col < b.length ? b[sort.col] : '';
        final an = num.tryParse(av.replaceAll(RegExp(r'[^0-9.-]'), ''));
        final bn = num.tryParse(bv.replaceAll(RegExp(r'[^0-9.-]'), ''));
        final cmp = (an != null && bn != null) ? an.compareTo(bn) : av.compareTo(bv);
        return sort.asc ? cmp : -cmp;
      });
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingRowHeight: 32,
        dataRowMinHeight: 30,
        dataRowMaxHeight: 38,
        horizontalMargin: 10,
        columnSpacing: 18,
        columns: [
          for (var c = 0; c < cols.length; c++)
            DataColumn(
              label: InkWell(
                onTap: () {
                  setState(() {
                    final prev = _tableSorts[id];
                    final asc = prev == null || prev.col != c ? true : !prev.asc;
                    _tableSorts[id] = (col: c, asc: asc);
                  });
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      cols[c].label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: colors['foreground'],
                      ),
                    ),
                    if (sort?.col == c)
                      Icon(
                        sort!.asc ? Codicons.arrowUp : Codicons.arrowDown,
                        size: 11,
                        color: colors['descriptionForeground'],
                      ),
                  ],
                ),
              ),
            ),
        ],
        rows: [
          for (final r in rows)
            DataRow(
              cells: [
                for (var c = 0; c < cols.length; c++)
                  DataCell(
                    Text(
                      c < r.length ? r[c] : '',
                      style: TextStyle(fontSize: 12, color: colors['foreground']),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildChart(
    BuildContext context,
    Map<String, Object?> props, {
    required bool isLine,
    Object? item,
    int? index,
    String? itemPath,
  }) {
    final colors = themeColors;
    final rawData = _resolveExpr(props['data'], item: item, index: index, itemPath: itemPath);
    final xKey = props['xKey'] as String? ?? 'label';
    final yKey = props['yKey'] as String? ?? 'value';
    final points = <({String label, double value})>[];
    if (rawData is List) {
      for (final entry in rawData) {
        if (entry is Map) {
          final label = '${entry[xKey] ?? entry['name'] ?? entry['x'] ?? ''}';
          final rawY = entry[yKey] ?? entry['y'] ?? entry['count'] ?? 0;
          final val = rawY is num ? rawY.toDouble() : double.tryParse('$rawY') ?? 0;
          points.add((label: label, value: val));
        }
      }
    }
    if (points.isEmpty) return const SizedBox.shrink();
    final title = _str(props['title'], item: item, index: index, itemPath: itemPath);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              title,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: colors['foreground'],
              ),
            ),
          ),
        SizedBox(
          height: 150,
          child: CustomPaint(
            painter: _SpecChartPainter(
              points: points,
              isLine: isLine,
              accent: colors['button.background'],
              textColor: colors['descriptionForeground'],
              gridColor: colors['widget.border'].withValues(alpha: 0.35),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTabs(
    BuildContext context,
    String id,
    Map<String, Object?> props,
    List<Widget> children, {
    Object? item,
    int? index,
    String? itemPath,
  }) {
    final colors = themeColors;
    final rawTabs = _resolveExpr(props['tabs'], item: item, index: index, itemPath: itemPath);
    final labels = <String>[
      if (rawTabs is List)
        for (final t in rawTabs)
          t is Map ? '${t['label'] ?? t['title'] ?? ''}' : '$t',
    ];
    final count = math.max(labels.length, children.length);
    if (count == 0) return const SizedBox.shrink();
    final selected = (_tabSelections[id] ?? 0).clamp(0, count - 1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 6,
          children: [
            for (var i = 0; i < count; i++)
              InkWell(
                borderRadius: BorderRadius.circular(5),
                onTap: () => setState(() => _tabSelections[id] = i),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: selected == i
                        ? colors['button.background'].withValues(alpha: 0.18)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(
                      color: selected == i
                          ? colors['button.background']
                          : colors['widget.border'].withValues(alpha: 0.5),
                    ),
                  ),
                  child: Text(
                    i < labels.length && labels[i].isNotEmpty ? labels[i] : 'Tab ${i + 1}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: selected == i ? FontWeight.w600 : FontWeight.normal,
                      color: colors['foreground'],
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        if (selected < children.length) children[selected],
      ],
    );
  }

  static Color _badgeColor(String? variant) => switch (variant?.toLowerCase()) {
    'success' || 'green' => const Color(0xFF3FB950),
    'warning' || 'yellow' || 'amber' => const Color(0xFFD29922),
    'danger' || 'error' || 'destructive' || 'red' => const Color(0xFFE5534B),
    _ => const Color(0xFF58A6FF),
  };
}

class _MiniBarButton extends StatelessWidget {
  const _MiniBarButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = themeColors['descriptionForeground'];
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 11, color: fg),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 11, color: fg)),
          ],
        ),
      ),
    );
  }
}

class _SpecChartPainter extends CustomPainter {
  _SpecChartPainter({
    required this.points,
    required this.isLine,
    required this.accent,
    required this.textColor,
    required this.gridColor,
  });

  final List<({String label, double value})> points;
  final bool isLine;
  final Color accent;
  final Color textColor;
  final Color gridColor;

  @override
  void paint(Canvas canvas, Size size) {
    final maxV = points.fold<double>(
      1.0,
      (m, p) => p.value > m ? p.value : m,
    );
    final plotBottom = size.height - 22;
    final plotTop = 12.0;
    final plotH = math.max(10.0, plotBottom - plotTop);
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final y = plotTop + plotH * (i / 3);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    final slotW = size.width / points.length;
    final barPaint = Paint()..color = accent.withValues(alpha: 0.85);
    final linePaint = Paint()
      ..color = accent
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke;
    final path = Path();

    for (var i = 0; i < points.length; i++) {
      final pt = points[i];
      final ratio = (pt.value / maxV).clamp(0.0, 1.0);
      final cx = slotW * i + slotW / 2;
      final y = plotBottom - plotH * ratio;

      if (isLine) {
        if (i == 0) {
          path.moveTo(cx, y);
        } else {
          path.lineTo(cx, y);
        }
        canvas.drawCircle(Offset(cx, y), 3.5, barPaint);
      } else {
        final bw = math.min(34.0, slotW * 0.56);
        final rect = RRect.fromRectAndCorners(
          Rect.fromLTWH(cx - bw / 2, y, bw, plotBottom - y),
          topLeft: const Radius.circular(3),
          topRight: const Radius.circular(3),
        );
        canvas.drawRRect(rect, barPaint);
      }

      final tp = TextPainter(
        text: TextSpan(
          text: pt.label,
          style: TextStyle(fontSize: 10, color: textColor),
        ),
        maxLines: 1,
        ellipsis: '…',
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: math.max(24, slotW - 4));
      tp.paint(canvas, Offset(cx - tp.width / 2, plotBottom + 4));
    }

    if (isLine && points.length > 1) {
      canvas.drawPath(path, linePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _SpecChartPainter oldDelegate) =>
      oldDelegate.points != points || oldDelegate.isLine != isLine;
}
