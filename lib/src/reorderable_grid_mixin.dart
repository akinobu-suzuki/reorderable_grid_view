import 'dart:typed_data';
import 'dart:ui' as ui show Image, ImageByteFormat;
import 'dart:math';
import 'dart:developer' as developer;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:reorderable_grid_view/src/reorderable_item.dart';
import 'package:reorderable_grid_view/src/util.dart';

import '../reorderable_grid_view.dart';
import 'drag_info.dart';

abstract class ReorderableChildPosDelegate {
  const ReorderableChildPosDelegate();

  /// 获取子view的位置
  Offset getPos(int index, Map<int, ReorderableItemViewState> items,
      BuildContext context);
}

mixin ReorderableGridWidgetMixin on StatefulWidget {
  DragEnableConfig? get dragEnableConfig;
  ReorderCallback get onReorder;
  DragWidgetBuilderV2? get dragWidgetBuilder;
  ScrollSpeedController? get scrollSpeedController;
  PlaceholderBuilder? get placeholderBuilder;
  OnDragStart? get onDragStart;
  OnDragUpdate? get onDragUpdate;

  Widget get child;
  Duration? get dragStartDelay;
  bool? get dragEnabled;

  bool? get isSliver;

  bool? get restrictDragScope;

  // every time an animation occurs begin
  OnDropIndexChange? get onDropIndexChange;
}

// What I want is I can call setState and get those properties.
// So I want my widget to on The ReorderableGridWidgetMixin
mixin ReorderableGridStateMixin<T extends ReorderableGridWidgetMixin>
    on State<T>, TickerProviderStateMixin<T> {
  DragEnableConfig get dragEnableConfig => widget.dragEnableConfig ?? (index) => true;
  MultiDragGestureRecognizer? _recognizer;
  
  // GlobalKeyの重複を防ぐため、遅延初期化（各インスタンスで一意）
  GlobalKey<OverlayState>? _overlayKey;
  GlobalKey<OverlayState> get overlayKey {
    _overlayKey ??= GlobalKey<OverlayState>(debugLabel: 'overlay_${identityHashCode(this)}');
    return _overlayKey!;
  }
  // late Overlay overlay = Overlay(key: overlayKey);

  Duration get dragStartDelay => widget.dragStartDelay ?? kLongPressTimeout;
  bool get dragEnabled => widget.dragEnabled ?? true;
  // it's not as drag start?
  void startDragRecognizer(int index, PointerDownEvent event,
      MultiDragGestureRecognizer recognizer) {
    // how to fix enter this twice?
    setState(() {
      if (_dragIndex != null) {
        _dragReset();
      }

      _dragIndex = index;
      _recognizer = recognizer
        ..onStart = _onDragStart
        ..addPointer(event);
    });
  }

  int? _dragIndex;

  int? _dropIndex;

  int get dropIndex => _dropIndex ?? -1;

  PlaceholderBuilder? get placeholderBuilder => widget.placeholderBuilder;

  OverlayState? getOverlay() {
    return overlayKey.currentState;
  }

  bool containsByIndex(int index) {
    return __items.containsKey(index);
  }

  Offset getPosByOffset(int index, int dIndex) {
    // how to do to this?
    var keys = __items.keys.toList();
    var keyIndex = keys.indexOf(index);
    keyIndex = keyIndex + dIndex;
    if (keyIndex < 0) {
      keyIndex = 0;
    }
    if (keyIndex > keys.length - 1) {
      keyIndex = keys.length - 1;
    }

    return getPosByIndex(keys[keyIndex], safe: true);
  }

  // The pos is relate to the container's 0, 0
  Offset getPosByIndex(int index, {bool safe = true}) {
    if (safe) {
      if (index < 0) {
        index = 0;
      }
    }

    if (index < 0) {
      return Offset.zero;
    }

    var child = __items[index];

    if (child == null) {
      debug("child is null for index: $index, will calculate from layout");
    }

    // how to do?
    var thisRenderObject = context.findRenderObject();
    // RenderSliverGrid

    if (thisRenderObject is RenderSliverGrid) {
      var renderObject = thisRenderObject;

      final SliverConstraints constraints = renderObject.constraints;
      final SliverGridLayout layout =
          renderObject.gridDelegate.getLayout(constraints);

      // childがnullでも、layoutから直接位置を計算できる
      final fixedIndex = child?.indexInAll ?? child?.index ?? index;
      
      try {
        final SliverGridGeometry gridGeometry =
            layout.getGeometryForChildIndex(fixedIndex);
        final rst =
            Offset(gridGeometry.crossAxisOffset, gridGeometry.scrollOffset);
        
        if (child == null) {
          debugPrint('🔍 getPosByIndex($index) child=null, fixedIndex=$fixedIndex, result=$rst');
        }
        
        return rst;
      } catch (e) {
        debugPrint('❌ getPosByIndex($index) エラー: $e');
        return Offset.zero;
      }
    }

    var renderObject = child?.context.findRenderObject();
    if (renderObject == null) {
      return Offset.zero;
    }
    RenderBox box = renderObject as RenderBox;

    var parentRenderObject = context.findRenderObject() as RenderBox;
    final pos =
        parentRenderObject.globalToLocal(box.localToGlobal(Offset.zero));
    return pos;
  }

  // Ok, let's no calc the dropIndex
  // Check the dragInfo before you call this function.
  int _calcDropIndex(int defaultIndex) {

    if (_dragInfo == null) {
      // _debug("_dragInfo is null, so return: $defaultIndex");
      return defaultIndex;
    }

    for (var item in __items.values) {
      RenderBox box = item.context.findRenderObject() as RenderBox;
      Offset pos = box.globalToLocal(_dragInfo!.getCenterInGlobal());
      if (pos.dx > 0 &&
          pos.dy > 0 &&
          pos.dx < box.size.width &&
          pos.dy < box.size.height) {
        if (dragEnableConfig(item.index)) {
          return item.index;
        }
      }
    }
    return defaultIndex;
  }

  Offset getOffsetInDrag(int index) {
    if (_dragInfo == null || _dropIndex == null || _dragIndex == _dropIndex) {
      return Offset.zero;
    }

    // ok now we check.
    bool inDragRange = false;
    bool isMoveLeft = _dropIndex! > _dragIndex!;

    int minPos = min(_dragIndex!, _dropIndex!);
    int maxPos = max(_dragIndex!, _dropIndex!);

    if (index >= minPos && index <= maxPos) {
      inDragRange = true;
    }

    if (!inDragRange) {
      return Offset.zero;
    } else {
      var preIndex = _findPreviousCanDrag(index);
      var nextIndex = _findNextCanDrag(index);
      if (isMoveLeft) {
        if (!containsByIndex(preIndex) || !containsByIndex(index)) {
          return Offset.zero;
        }
        return getPosByIndex(preIndex) - getPosByIndex(index);
      } else {
        if (!containsByIndex(nextIndex) || !containsByIndex(index)) {
          return Offset.zero;
        }
        return getPosByIndex(nextIndex) - getPosByIndex(index);
      }
    }
  }

  int _findPreviousCanDrag(int start) {
    for (var i = start - 1; i >= 0; i--) {
      if (dragEnableConfig(i)) {
        return i;
      }
    }
    return -1;
  }

  int _findNextCanDrag(int start) {
    var max = __items.keys.reduce((a, b) => a > b? a: b);
    for (var i = start + 1; i <= max; i++) {
      if (dragEnableConfig(i)) {
        return i;
      }
    }
    return -1;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isSliver?? false || !(widget.restrictDragScope?? false)) {
      return widget.child;
    }
    return Stack(children: [
      widget.child,
      Overlay(key: overlayKey,)
    ]);
  }

  // position is the global position
  Drag _onDragStart(Offset position) {
    // how can I delay for take snapshot?
    debug("_onDragStart: $position, __dragIndex: $_dragIndex");
    assert(_dragInfo == null);
    widget.onDragStart?.call(_dragIndex!);

    final ReorderableItemViewState item = __items[_dragIndex!]!;

    _dropIndex = _dragIndex;
    if (_dropIndex != null) {
      widget.onDropIndexChange?.call(_dropIndex!, null);
    }

    _dragInfo = DragInfo(
      item: item,
      tickerProvider: this,
      overlay: getOverlay(),
      context: context,
      dragWidgetBuilder: widget.dragWidgetBuilder,
      scrollSpeedController: widget.scrollSpeedController,
      onStart: _onDragStart,
      dragPosition: position,
      onUpdate: _onDragUpdate,
      onCancel: _onDragCancel,
      onEnd: _onDragEnd,
      readyCallback: () {
        item.dragging = true;
        item.rebuild();
        updateDragTarget();
      },
    );

    // ok, how about at here, do a capture?
    // _dragInfo!.startDrag();
    _startDrag(item);

    return _dragInfo!;
  }

  void _startDrag(ReorderableItemViewState item) async {
    if (_dragInfo == null) {
      // should never happen
      return;
    }
    if (widget.dragWidgetBuilder?.isScreenshotDragWidget?? false) {
      ui.Image? screenshot = await takeScreenShot(item);
      ByteData? byteData = await screenshot?.toByteData(format: ui.ImageByteFormat.png);
      developer.log("screen shot is null: $screenshot, byteData: $byteData");
      if (byteData != null) {
        _dragInfo?.startDrag(MemoryImage(byteData.buffer.asUint8List()));
      }
    } else {
      _dragInfo?.startDrag(null);
    }
  }

  _onDragUpdate(DragInfo item, Offset position, Offset delta) {
    widget.onDragUpdate?.call(_dragIndex!, position, delta);
    updateDragTarget();
  }

  _onDragCancel(DragInfo item) {
    _dragReset();
    setState(() {});
  }

  _onDragEnd(DragInfo item) async {
    final dragIndex = _dragIndex;
    final dropIndex = _dropIndex;
    if (dragIndex == null || dropIndex == null) {
      _dragReset();
      return;
    }

    final targetGlobal = _globalPositionForIndex(dropIndex);
    if (targetGlobal != null) {
      await item.animateToTarget(targetGlobal);
    }

    widget.onReorder(dragIndex, dropIndex);
    _dragReset();
  }

  Offset? _globalPositionForIndex(int index) {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox) {
      return null;
    }
    final localOffset = getPosByIndex(index);
    return renderObject.localToGlobal(localOffset);
  }

  // ok, drag is end.
  _dragReset() {
    if (_dragIndex != null) {
      if (__items.containsKey(_dragIndex!)) {
        final ReorderableItemViewState item = __items[_dragIndex!]!;
        item.dragging = false;
        item.rebuild();
      }

      _dragIndex = null;
      _dropIndex = null;

      for (var item in __items.values) {
        item.resetGap();
      }
    }

    _recognizer?.dispose();
    _recognizer = null;

    _dragInfo?.dispose();
    _dragInfo = null;
  }

  // stock at here.
  static ReorderableGridStateMixin of(BuildContext context) {
    return context.findAncestorStateOfType<ReorderableGridStateMixin>()!;
  }

  // Places the value from startIndex one space before the element at endIndex.
  void reorder(int startIndex, int endIndex) {
    // what to do??
    setState(() {
      if (startIndex != endIndex) widget.onReorder(startIndex, endIndex);
      // Animates leftover space in the drop area closed.
    });
  }

  final Map<int, ReorderableItemViewState> __items =
      <int, ReorderableItemViewState>{};

  DragInfo? _dragInfo;

  void registerItem(ReorderableItemViewState item) {
    __items[item.index] = item;
    if (item.index == _dragInfo?.index) {
      item.dragging = true;
      item.rebuild();
    }
  }

  void unRegisterItem(int index, ReorderableItemViewState item) {
    // why you check the item?
    var current = __items[index];
    if (current == item) {
      __items.remove(index);
    }
  }

  Future<void> updateDragTarget() async {
    int newTargetIndex = _calcDropIndex(_dropIndex!);
    if (newTargetIndex != _dropIndex) {
      widget.onDropIndexChange?.call(newTargetIndex, _dropIndex);
      _dropIndex = newTargetIndex;
      for (var item in __items.values) {
        item.updateForGap(_dropIndex!);
      }
    }
  }

  /// Animates a gap-closure when removing an item at [removedIndex].
  /// Items after the removed index will slide to fill the empty slot.
  Future<void> removeItem(int removedIndex, Duration duration) async {
    if (!mounted) return;

    final futures = <Future<void>>[];
    final indices = __items.keys.toList()..sort();

    for (final index in indices) {
      if (index <= removedIndex) {
        continue;
      }

      final previousIndex = _findPreviousExistingIndex(index);
      if (previousIndex == null) {
        continue;
      }

      final currentPos = getPosByIndex(index, safe: false);
      final targetPos = getPosByIndex(previousIndex, safe: false);
      final delta = targetPos - currentPos;
      final item = __items[index];
      if (item != null) {
        futures.add(item.animateShift(delta, duration));
      }
    }

    await Future.wait(futures);
  }

  /// Animates items shifting to make room when inserting at [insertedIndex].
  /// Items at or after the inserted index will slide **backward** by one slot.
  Future<void> insertItem(int insertedIndex, Duration duration) async {
    if (!mounted) return;

    final futures = <Future<void>>[];
    // 末尾から処理することで、多重シフトによるズレを防ぐ
    final indices = __items.keys.toList()..sort((a, b) => b.compareTo(a));

    for (final index in indices) {
      if (index < insertedIndex) {
        continue;
      }

      // 現在位置と「1つ後ろ」の位置との差分を計算してシフトさせる
      final currentPos = getPosByIndex(index, safe: false);
      final targetPos = getPosByIndex(index + 1, safe: false);
      final delta = targetPos - currentPos;
      final item = __items[index];
      if (item != null) {
        futures.add(item.animateShift(delta, duration));
      }
    }

    await Future.wait(futures);
  }

  /// Animates items shifting to make room when inserting [count] items at [insertedIndex].
  /// Items at or after the inserted index will slide backward by [count] slots.
  Future<void> insertItems(int insertedIndex, int count, Duration duration) async {
    if (!mounted || count <= 0) return;

    final futures = <Future<void>>[];
    final indices = __items.keys.toList()..sort();

    debugPrint('📍 insertItems: insertedIndex=$insertedIndex, count=$count');
    debugPrint('📍 レンダリングされているアイテムのインデックス: $indices');
    debugPrint('📍 レンダリングされているアイテム数: ${indices.length}');

    // 古いリストの最大インデックス（新しいアイテムが追加される前）
    final oldMaxIndex = indices.isNotEmpty ? indices.last : -1;
    
    // 横の個数とセルサイズを計算（最初の数個のアイテムから）
    int crossAxisCount = 1;
    double cellWidthWithSpacing = 0;
    double cellHeightWithSpacing = 0;
    Offset basePos = Offset.zero;
    
    if (indices.length >= 2) {
      basePos = getPosByIndex(indices[0], safe: false);
      final pos1 = getPosByIndex(indices[1], safe: false);
      
      if (basePos.dy == pos1.dy) {
        // 同じ行にある場合、横の個数を数える
        cellWidthWithSpacing = pos1.dx - basePos.dx;
        
        for (int i = 0; i < indices.length; i++) {
          final pos = getPosByIndex(indices[i], safe: false);
          if (pos.dy == basePos.dy) {
            crossAxisCount++;
          } else {
            // 次の行に移ったので、縦のスペーシングも計算
            cellHeightWithSpacing = pos.dy - basePos.dy;
            break;
          }
        }
      }
    }
    
    debugPrint('📊 crossAxisCount: $crossAxisCount, cellSize: ${cellWidthWithSpacing}x$cellHeightWithSpacing');
    
    for (final index in indices) {
      if (index < insertedIndex) {
        continue;
      }

      final item = __items[index];
      if (item == null) continue;
      
      // アイテムがレンダリングされているか確認
      try {
        final renderBox = item.context.findRenderObject() as RenderBox?;
        if (renderBox == null || !renderBox.hasSize) {
          debugPrint('⚠️ アイテム[$index] レンダリングなし（スキップ）');
          continue;
        }
      } catch (e) {
        debugPrint('❌ RenderBox取得エラー for item[$index]: $e');
        continue;
      }

      // 現在位置
      final currentPos = getPosByIndex(index, safe: false);
      
      // ターゲットインデックス
      final targetIndex = index + count;
      Offset targetPos;
      
      if (targetIndex > oldMaxIndex) {
        // 範囲外なので手動計算
        debugPrint('🧮 アイテム[$index] → [$targetIndex] 手動計算（oldMax=$oldMaxIndex）');
        
        // まずgetPosByIndexを試す
        targetPos = getPosByIndex(targetIndex, safe: false);
        
        if (targetPos == Offset.zero && targetIndex != 0) {
          // (0,0)が返ってきた＝無効なので手動計算
          debugPrint('   🧮 完全手動計算にフォールバック');
          
          if (crossAxisCount > 0 && cellWidthWithSpacing > 0 && cellHeightWithSpacing > 0) {
            final targetRow = targetIndex ~/ crossAxisCount;
            final targetCol = targetIndex % crossAxisCount;
            
            final targetX = basePos.dx + (targetCol * cellWidthWithSpacing);
            final targetY = basePos.dy + (targetRow * cellHeightWithSpacing);
            
            targetPos = Offset(targetX, targetY);
            debugPrint('   🧮 手動計算: row=$targetRow, col=$targetCol, pos=$targetPos');
          } else {
            debugPrint('   ❌ グリッド情報不足、スキップ');
            continue;
          }
        } else {
          debugPrint('   ✅ getPosByIndex成功: $targetPos');
        }
      } else {
        targetPos = getPosByIndex(targetIndex, safe: false);
      }
      
      final delta = targetPos - currentPos;
      
      debugPrint('🔄 アイテム[$index] シフト: $currentPos -> $targetPos (delta=$delta)');
      
      futures.add(item.animateShift(delta, duration));
    }

    debugPrint('📍 実際にアニメーションするアイテム数: ${futures.length}');

    await Future.wait(futures);
    
    // アニメーション完了後、すべてのアイテムのオフセットをリセット
    for (final item in __items.values) {
      item.resetGap();
    }
  }

  int? _findPreviousExistingIndex(int start) {
    for (var i = start - 1; i >= 0; i--) {
      if (__items.containsKey(i)) {
        return i;
      }
    }
    return null;
  }

  int? _findNextExistingIndex(int start) {
    final indices = __items.keys.toList()..sort();
    for (var i = start + 1; i <= (indices.isNotEmpty ? indices.last : start); i++) {
      if (__items.containsKey(i)) {
        return i;
      }
    }
    return null;
  }
}
