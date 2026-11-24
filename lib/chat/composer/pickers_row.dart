import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// The composer's pickers in a row, centered on it: each as wide as it is
/// except the flexible picker (by default the last child, or [trailingCount]
/// from the end when fixed trailing badges such as the context meter follow
/// the model picker), which is given what is left of [maxWidth] and cuts its
/// label short there, down to [minLast]. Past that the row is wider than
/// [maxWidth], for its parent to scroll.
class PickersRow extends MultiChildRenderObjectWidget {
  const PickersRow({
    super.key,
    required this.maxWidth,
    this.minLast = 64,
    this.trailingCount = 0,
    super.children,
  });

  final double maxWidth;
  final double minLast;

  /// Number of fixed-width trailing children after the flexible picker.
  final int trailingCount;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderPickersRow(maxWidth, minLast, trailingCount);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderPickersRow renderObject,
  ) => renderObject
    ..maxWidth = maxWidth
    ..minLast = minLast
    ..trailingCount = trailingCount;
}

class _PickerParentData extends ContainerBoxParentData<RenderBox> {}

class RenderPickersRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _PickerParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _PickerParentData> {
  RenderPickersRow(this._maxWidth, this._minLast, [this._trailingCount = 0]);

  double get maxWidth => _maxWidth;
  double _maxWidth;
  set maxWidth(double value) {
    if (value == _maxWidth) return;
    _maxWidth = value;
    markNeedsLayout();
  }

  double get minLast => _minLast;
  double _minLast;
  set minLast(double value) {
    if (value == _minLast) return;
    _minLast = value;
    markNeedsLayout();
  }

  int get trailingCount => _trailingCount;
  int _trailingCount;
  set trailingCount(int value) {
    if (value == _trailingCount) return;
    _trailingCount = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _PickerParentData) {
      child.parentData = _PickerParentData();
    }
  }

  /// The width the flexible picker may take, the others [fixed] wide.
  double _flexWidth(double fixed) => math.max(_minLast, _maxWidth - fixed);

  Size _layout(BoxConstraints constraints, {required bool dry}) {
    final height = constraints.maxHeight;
    final children = <RenderBox>[];
    for (var child = firstChild; child != null; child = childAfter(child)) {
      children.add(child);
    }
    if (children.isEmpty) return constraints.constrain(Size.zero);
    final flexIndex = children.length - 1 - _trailingCount;
    var fixedWidth = 0.0;
    var tallest = 0.0;
    for (var i = 0; i < children.length; i++) {
      if (i == flexIndex) continue;
      final limits = BoxConstraints(
        maxWidth: double.infinity,
        maxHeight: height,
      );
      final child = children[i];
      final size = dry
          ? child.getDryLayout(limits)
          : (child..layout(limits, parentUsesSize: true)).size;
      fixedWidth += size.width;
      tallest = math.max(tallest, size.height);
    }
    var flexWidth = 0.0;
    if (flexIndex >= 0 && flexIndex < children.length) {
      final limits = BoxConstraints(
        maxWidth: _flexWidth(fixedWidth),
        maxHeight: height,
      );
      final child = children[flexIndex];
      final size = dry
          ? child.getDryLayout(limits)
          : (child..layout(limits, parentUsesSize: true)).size;
      flexWidth = size.width;
      tallest = math.max(tallest, size.height);
    }
    return constraints.constrain(Size(fixedWidth + flexWidth, tallest));
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _layout(constraints, dry: true);

  @override
  void performLayout() {
    size = _layout(constraints, dry: false);
    var x = 0.0;
    for (var child = firstChild; child != null; child = childAfter(child)) {
      (child.parentData! as _PickerParentData).offset = Offset(
        x,
        (size.height - child.size.height) / 2,
      );
      x += child.size.width;
    }
  }

  double _sum(double Function(RenderBox child) of) {
    var sum = 0.0;
    for (var child = firstChild; child != null; child = childAfter(child)) {
      sum += of(child);
    }
    return sum;
  }

  double _max(double Function(RenderBox child) of) {
    var most = 0.0;
    for (var child = firstChild; child != null; child = childAfter(child)) {
      most = math.max(most, of(child));
    }
    return most;
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      _sum((child) => child.getMinIntrinsicWidth(height));

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _sum((child) => child.getMaxIntrinsicWidth(height));

  @override
  double computeMinIntrinsicHeight(double width) =>
      _max((child) => child.getMinIntrinsicHeight(double.infinity));

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _max((child) => child.getMaxIntrinsicHeight(double.infinity));

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      defaultComputeDistanceToHighestActualBaseline(baseline);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);
}
