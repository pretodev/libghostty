import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:libghostty/libghostty.dart'
    show MouseAction, MouseButton, MouseTracking, Position;
import 'package:meta/meta.dart';

import '../foundation.dart';
import '../links/link_settings.dart';
import 'link_interaction.dart';
import 'terminal_raw_gesture_detector.dart';
import 'terminal_view_binding.dart';

/// Interprets gestures as terminal actions: selection, mouse tracking
/// reports, and focus requests.
///
/// Reports all gestures to [TerminalViewBinding] which handles
/// snapping, scroll offset, and encoding.
@internal
class TerminalGestureDetector extends StatefulWidget {
  final Widget child;
  final int visibleRows;
  final CellMetrics metrics;
  final TerminalViewBinding binding;
  final TerminalGestureSettings settings;
  final LinkInteraction links;
  final ValueChanged<ActivatedLink>? onLinkActivate;
  final ScrollController? scrollController;

  const TerminalGestureDetector({
    super.key,
    required this.child,
    this.visibleRows = 0,
    required this.metrics,
    required this.binding,
    required this.links,
    this.onLinkActivate,
    this.scrollController,
    this.settings = const TerminalGestureSettings(),
  });

  @override
  State<TerminalGestureDetector> createState() =>
      _TerminalGestureDetectorState();
}

class _TerminalGestureDetectorState extends State<TerminalGestureDetector> {
  _DragState? _drag;
  Position? _pressCell;
  var _linkPressActive = false;
  Timer? _autoScrollTimer;

  TerminalViewBinding get _binding => widget.binding;

  @override
  Widget build(BuildContext context) {
    final tracked = _binding.mouseTracking != MouseTracking.none;

    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: tracked ? _handleTrackedDown : null,
      onPointerMove: tracked ? _handleTrackedMove : null,
      onPointerUp: tracked ? _handleTrackedUp : null,
      // With mouse tracking on (TUIs like claude/vim on the alt screen), the
      // wheel must be reported to the app instead of scrolling the viewport
      // scrollback. Otherwise the child `Scrollable` swallows the wheel (and
      // the alt screen has no scrollback), so the app's own scrolling never
      // works. That `Scrollable` is disabled (`NeverScrollableScrollPhysics`)
      // in this mode by `TerminalView`, so the two never contend for the same
      // pointer signal.
      onPointerSignal: tracked ? _handlePointerSignal : null,
      // macOS delivers trackpad scrolling as pan/zoom; forward it like a wheel.
      onPointerPanZoomStart: tracked ? _handlePointerPanZoomStart : null,
      onPointerPanZoomUpdate: tracked ? _handlePointerPanZoomUpdate : null,
      child: TerminalRawGestureDetector(
        onTapDown: _handleTapDown,
        onTapUp: _handleTapUp,
        onDragStart: _handleDragStart,
        onDragUpdate: _handleDragUpdate,
        onDragEnd: _handleDragEnd,
        onLongPressStart: _handleLongPressStart,
        onLongPressMoveUpdate: _handleLongPressMoveUpdate,
        onLongPressUp: _handleLongPressUp,
        child: widget.child,
      ),
    );
  }

  @override
  void didUpdateWidget(TerminalGestureDetector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.metrics != oldWidget.metrics ||
        widget.binding != oldWidget.binding) {
      _binding.invalidateSelection();
      _stopAutoScroll();
      _drag = null;
      _pressCell = null;
      _cancelLinkPress();
    }
  }

  @override
  void dispose() {
    _autoScrollTimer?.cancel();
    super.dispose();
  }

  void _autoScrollTick(Timer timer) {
    final scrollController = widget.scrollController;
    if (scrollController == null || !scrollController.hasClients) return;

    final drag = _drag;
    if (drag == null) {
      _stopAutoScroll();
      return;
    }

    _binding.updateSelectionAutoscroll(
      cell: drag.cell,
      localPosition: drag.localPosition,
      rectangle: drag.lastRectangle,
    );
  }

  void _cancelLinkPress() {
    if (!_linkPressActive) return;
    _linkPressActive = false;
    widget.links.cancel();
  }

  void _cancelSelectionPress() {
    if (_pressCell == null) return;
    _binding.cancelSelectionGesture();
    _pressCell = null;
  }

  int _clampInt(int value, int min, int max) {
    if (value < min) return min;
    if (value > max) return max;
    return value;
  }

  void _endDrag() {
    final drag = _drag;
    if (drag != null) {
      _releaseSelectionPress(drag.cell);
    } else {
      _releaseSelectionPress();
    }
    _stopAutoScroll();
    _drag = null;
    _cancelLinkPress();
  }

  void _handleDragEnd() => _endDrag();

  void _handleDragStart(DragStartDetails details) {
    _binding.requestFocus();
    _cancelLinkPress();
    if (_isMouseTracked(HardwareKeyboard.instance.isShiftPressed)) return;
    if (!widget.settings.dragSelection) {
      _cancelSelectionPress();
      return;
    }

    _startDrag(details.localPosition, beginPress: _pressCell == null);
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    if (_isMouseTracked(HardwareKeyboard.instance.isShiftPressed)) return;
    if (_drag != null) _updateDrag(details.localPosition);
  }

  void _handleLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    if (_drag != null) _updateDrag(details.localPosition);
  }

  void _handleLongPressStart(LongPressStartDetails details) {
    _binding.requestFocus();
    if (!widget.settings.longPressSelection) {
      _cancelSelectionPress();
      return;
    }
    _startDrag(
      details.localPosition,
      rectangle: widget.settings.longPressSelectionShape == .rectangle,
      beginPress: _pressCell == null,
    );
  }

  void _handleLongPressUp() => _endDrag();

  void _handleSelectionPress(Offset position) {
    final cell = widget.metrics.cellAt(position);
    _binding.handleSelectionPress(
      cell: cell,
      localPosition: position,
      settings: widget.settings,
    );
    _pressCell = cell;
  }

  void _handleTapDown(TapDownDetails details) {
    _binding.requestFocus();
    if (_isMouseTracked(HardwareKeyboard.instance.isShiftPressed)) return;
    if (widget.links.handlePress(
      localPosition: details.localPosition,
      metrics: widget.metrics,
      pointerKind: details.kind ?? .mouse,
      virtualMods: _binding.virtualMods,
    )) {
      _linkPressActive = true;
      _cancelSelectionPress();
      return;
    }
    _handleSelectionPress(details.localPosition);
  }

  void _handleTapUp(TapUpDetails details) {
    if (_linkPressActive) {
      _linkPressActive = false;
      final link = widget.links.handleRelease(
        localPosition: details.localPosition,
        metrics: widget.metrics,
      );
      if (link != null) widget.onLinkActivate?.call(link);
      return;
    }
    if (_pressCell == null &&
        _isMouseTracked(HardwareKeyboard.instance.isShiftPressed)) {
      return;
    }
    _releaseSelectionPress(widget.metrics.cellAt(details.localPosition));
  }

  void _handleTrackedDown(PointerDownEvent event) {
    final shift =
        event.buttons & kSecondaryButton != 0 ||
        HardwareKeyboard.instance.isShiftPressed;
    if (!_isMouseTracked(shift)) return;
    _sendMouseEvent(.press, event.localPosition);
  }

  void _handleTrackedMove(PointerMoveEvent event) {
    if (!_isMouseTracked(HardwareKeyboard.instance.isShiftPressed)) return;
    _sendMouseEvent(.motion, event.localPosition);
  }

  void _handleTrackedUp(PointerUpEvent event) {
    if (!_isMouseTracked(HardwareKeyboard.instance.isShiftPressed)) return;
    _sendMouseEvent(.release, event.localPosition);
  }

  bool _isBlockModifierPressed() {
    final modifier = widget.settings.blockSelectionModifier;
    if (modifier == null) return false;
    final keyboard = HardwareKeyboard.instance;
    final mods = _binding.virtualMods;
    return switch (modifier) {
      .alt => keyboard.isAltPressed || mods.hasAlt,
      .meta => keyboard.isMetaPressed || mods.hasSuper,
      .shift => keyboard.isShiftPressed || mods.hasShift,
      .control => keyboard.isControlPressed || mods.hasCtrl,
    };
  }

  bool _isMouseTracked(bool shift) {
    return _binding.mouseTracking != .none &&
        !shift &&
        !_binding.virtualMods.hasShift;
  }

  void _releaseSelectionPress([Position? cell]) {
    cell ??= _pressCell;
    if (cell == null) return;
    _binding.handleSelectionRelease(cell);
    _pressCell = null;
  }

  void _sendMouseEvent(MouseAction action, Offset position) {
    _binding.handleMouseEvent((
      action: action,
      button: .left,
      pixelX: position.dx,
      pixelY: position.dy,
    ));
  }

  /// Fractional line remainder left over while forwarding the wheel (the
  /// trackpad sends small, frequent deltas; accumulating keeps the forwarded
  /// scroll from running too fast).
  double _wheelAccum = 0;

  /// Accumulated pan of the pan/zoom gesture in flight
  /// ([PointerPanZoomUpdateEvent.pan] is cumulative since the start, so the
  /// per-update delta is derived from it).
  Offset _panZoomLast = Offset.zero;

  /// Wheel arriving as a [PointerSignalEvent] — a real mouse and, on macOS, the
  /// synthesized trackpad scroll. Forwarded to the app as a mouse report.
  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (!_isMouseTracked(HardwareKeyboard.instance.isShiftPressed)) return;
    // Mouse is discrete (one notch per event); trackpad is continuous, so it
    // accumulates.
    _forwardScroll(
      event.scrollDelta.dy,
      event.localPosition,
      discrete: event.kind == PointerDeviceKind.mouse,
    );
  }

  // On macOS the trackpad often arrives as a pan/zoom gesture rather than a
  // PointerScrollEvent, so without handling it two-finger scrolling forwards
  // nothing to the app. Same forwarding path as the wheel, continuous mode.
  void _handlePointerPanZoomStart(PointerPanZoomStartEvent event) {
    _panZoomLast = Offset.zero;
    _wheelAccum = 0;
  }

  void _handlePointerPanZoomUpdate(PointerPanZoomUpdateEvent event) {
    if (!_isMouseTracked(HardwareKeyboard.instance.isShiftPressed)) return;
    final dy = event.pan.dy - _panZoomLast.dy;
    _panZoomLast = event.pan;
    // Pan has the opposite sign of scrollDelta (finger up = negative pan.dy =
    // reveal content below = scroll down); negating it reuses the convention.
    _forwardScroll(-dy, event.localPosition, discrete: false);
  }

  /// Converts a vertical delta (px, `scrollDelta` convention) into line steps
  /// and forwards them to the app as wheel reports (button 4 = up, 5 = down).
  /// [discrete] means a mouse (at least one line per notch, no accumulation);
  /// otherwise the delta is continuous, as from a trackpad.
  void _forwardScroll(
    double deltaY,
    Offset localPosition, {
    required bool discrete,
  }) {
    final cellHeight = widget.metrics.cellHeight;
    if (cellHeight <= 0) return;
    final lines = deltaY / cellHeight;
    if (lines == 0) return;

    final int steps;
    if (discrete) {
      final mag = lines.abs().round();
      steps = (mag < 1 ? 1 : mag) * (lines.isNegative ? -1 : 1);
    } else {
      _wheelAccum += lines;
      steps = _wheelAccum.truncate();
      if (steps == 0) return;
      _wheelAccum -= steps;
    }

    // dy < 0 = scroll up = button 4; dy > 0 = scroll down = button 5.
    final button = steps < 0 ? MouseButton.four : MouseButton.five;
    for (var i = 0; i < steps.abs(); i++) {
      _binding.handleMouseEvent((
        action: MouseAction.press,
        button: button,
        pixelX: localPosition.dx,
        pixelY: localPosition.dy,
      ));
    }
  }

  void _startAutoScroll() {
    if (_autoScrollTimer != null) return;
    _autoScrollTimer = Timer.periodic(
      const Duration(milliseconds: 50),
      _autoScrollTick,
    );
  }

  void _startDrag(
    Offset position, {
    bool rectangle = false,
    bool beginPress = false,
  }) {
    final cell = widget.metrics.cellAt(position);
    final block = rectangle || _isBlockModifierPressed();
    _drag = _DragState(cell, position, baseRectangle: block);
    if (beginPress) _handleSelectionPress(position);
  }

  void _stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
  }

  void _updateDrag(Offset position) {
    final drag = _drag;
    if (drag == null) return;
    final cell = widget.metrics.cellAt(position);
    drag.cell = cell;
    drag.localPosition = position;

    final visibleRows = widget.visibleRows;
    if (visibleRows > 0) {
      if (cell.row < 0) {
        _startAutoScroll();
      } else if (cell.row >= visibleRows) {
        _startAutoScroll();
      } else {
        _stopAutoScroll();
      }
    }

    final clampedRow = visibleRows > 0
        ? _clampInt(cell.row, 0, visibleRows - 1)
        : cell.row;
    final clampedCell = Position(row: clampedRow, col: cell.col);
    final rectangle = drag.baseRectangle || _isBlockModifierPressed();
    if (clampedCell == drag.lastCell && rectangle == drag.lastRectangle) {
      return;
    }
    drag.lastCell = clampedCell;
    drag.lastRectangle = rectangle;

    _binding.updateSelectionDrag(
      cell: clampedCell,
      localPosition: position,
      rectangle: rectangle,
    );
  }
}

class _DragState {
  Position cell;
  Offset localPosition;
  final bool baseRectangle;
  bool lastRectangle;
  Position? lastCell;

  _DragState(this.cell, this.localPosition, {required this.baseRectangle})
    : lastRectangle = baseRectangle;
}
