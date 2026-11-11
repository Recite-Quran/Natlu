// QvpPageView — the Flutter host renderer for a QvpPage.
//
// Draw order per frame (same as web/qvp.js CanvasRenderer):
//   cached ornament layer → highlight bands → cached base ink → styled paths → mask boxes
// The engine decides everything (layout, hit-testing, colours, boxes); this
// widget only converts geometry into ui.Path objects once, caches the
// unstyled ink as a recorded ui.Picture in layout units, and forwards gestures
// to the engine's hit test / selection.
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'engine.dart';
import 'page.dart' show pageClock;

/// Layout parameters of [QvpPageView] (viewport size is taken from the widget's constraints).
/// Spacing only opens up: `lineSpacing` < 1 is clamped by the engine.
@immutable
class QvpViewLayout {
  /// The defaults leave 24 px above and below the page and 16 px at each side, at the printed
  /// line spacing.
  const QvpViewLayout({
    this.padTop = 24,
    this.padBottom = 24,
    this.padSide = 16,
    this.lineSpacing = 1,
    this.fillHeight = false,
    this.gridLines = 0,
    this.maxAspectSlack = QvpDefaults.aspectSlack,
    this.surahFrames = true,
  });

  /// [padTop], [padBottom] and [padSide] are the space around the page in viewport px;
  /// [padSide] goes on the left and on the right. [lineSpacing] multiplies the printed spacing.
  final double padTop, padBottom, padSide, lineSpacing;

  /// [fillHeight] opens the line spacing until the page fills the padded height.
  /// [surahFrames] draws the print's own frames around surah names; a reflowed page has none.
  final bool fillHeight, surahFrames;

  /// The grid to lay the page out inside, in lines; 0 is the page's own ([QvpPage.grid]).
  final int gridLines;

  /// Maximum aspect slack for viewport fit guard.
  final double maxAspectSlack;

  QvpViewLayout copyWith({
    double? padTop,
    double? padBottom,
    double? padSide,
    double? lineSpacing,
    bool? fillHeight,
    int? gridLines,
    double? maxAspectSlack,
    bool? surahFrames,
  }) => QvpViewLayout(
    padTop: padTop ?? this.padTop,
    padBottom: padBottom ?? this.padBottom,
    padSide: padSide ?? this.padSide,
    lineSpacing: lineSpacing ?? this.lineSpacing,
    fillHeight: fillHeight ?? this.fillHeight,
    gridLines: gridLines ?? this.gridLines,
    maxAspectSlack: maxAspectSlack ?? this.maxAspectSlack,
    surahFrames: surahFrames ?? this.surahFrames,
  );

  QvpLayoutSpec toSpec(double viewportW, double viewportH) => QvpLayoutSpec(
    viewportW: viewportW,
    viewportH: viewportH,
    padTop: padTop,
    padBottom: padBottom,
    padLeft: padSide,
    padRight: padSide,
    lineSpacing: lineSpacing,
    fillHeight: fillHeight,
    gridLines: gridLines,
    maxAspectSlack: maxAspectSlack,
    surahFrames: surahFrames,
  );

  @override
  bool operator ==(Object other) =>
      other is QvpViewLayout &&
      other.padTop == padTop &&
      other.padBottom == padBottom &&
      other.padSide == padSide &&
      other.lineSpacing == lineSpacing &&
      other.fillHeight == fillHeight &&
      other.gridLines == gridLines &&
      other.maxAspectSlack == maxAspectSlack &&
      other.surahFrames == surahFrames;

  @override
  int get hashCode => Object.hash(
    padTop,
    padBottom,
    padSide,
    lineSpacing,
    fillHeight,
    gridLines,
    maxAspectSlack,
    surahFrames,
  );
}

/// Pan / zoom on top of the engine layout. `view px = offsetX + layout px * scale`. The
/// arithmetic is the engine's: [zoomBy], [panBy] and [toView] call it through the view that
/// holds the controller. [zoomBy] and [panBy] keep working with the engine of the last view
/// after that view is gone. [toView] needs a view that holds the controller now, and throws a
/// [StateError] without one. Before any [QvpPageView] has taken the controller, all three throw.
class QvpViewController extends ChangeNotifier {
  /// The reader's zoom and pan: a layout point `p` draws at `offset + scale · p`. Set them
  /// with [set], which notifies the view.
  double scale = 1, offsetX = 0, offsetY = 0;
  bool _fitRequested = true;

  /// Size of the last laid-out viewport (logical px).
  Size viewport = Size.zero;

  /// The view that holds this controller now. A host may hand one controller to a new view
  /// before the old one is disposed, so only the view that holds it can let it go.
  QvpPageViewState? _holder;

  /// The engine of the last view that held this controller. It outlives the view, so
  /// [zoomBy] and [panBy] keep working after the view is gone.
  QvpEngine? _engine;

  void _attach(QvpPageViewState view) {
    _holder = view;
    _engine = view.page.engine;
  }

  void _detach(QvpPageViewState view) {
    if (identical(_holder, view)) _holder = null;
  }

  QvpEngine get _attachedEngine =>
      _engine ??
      (throw StateError(
        'QvpViewController: give it to a QvpPageView before zooming or panning',
      ));

  /// The reader's pan and zoom as the engine has it.
  QvpView get view => QvpView(scale: scale, offsetX: offsetX, offsetY: offsetY);

  /// Sets the fields given and notifies the views that use this controller.
  void set({double? scale, double? offsetX, double? offsetY}) {
    this.scale = scale ?? this.scale;
    this.offsetX = offsetX ?? this.offsetX;
    this.offsetY = offsetY ?? this.offsetY;
    notifyListeners();
  }

  void _setView(QvpView v) =>
      set(scale: v.scale, offsetX: v.offsetX, offsetY: v.offsetY);

  /// Repaints views using this controller.
  void refresh() => notifyListeners();

  /// Fits the page into the viewport on the next frame.
  void fit() {
    _fitRequested = true;
    notifyListeners();
  }

  /// Zooms by [factor] around a point in widget coordinates (default: centre), with the scale
  /// held between [min] and [max]. The engine computes the view. [min] defaults to the scale
  /// the page is fitted at and [max] to [QvpPageView.maxZoom], as a magnifying pinch has them.
  /// Without a view that holds the controller, both default to 0, the engine's own limits.
  void zoomBy(double factor, {Offset? around, double? min, double? max}) {
    final c = around ?? Offset(viewport.width / 2, viewport.height / 2);
    final holder = _holder;
    _setView(
      _attachedEngine.viewZoomAbout(
        view,
        c.dx,
        c.dy,
        factor,
        min: min ?? holder?._fitScale ?? 0,
        max: max ?? holder?.widget.maxZoom ?? 0,
      ),
    );
  }

  /// Pans the view by [delta] in widget coordinates.
  void panBy(Offset delta) =>
      _setView(_attachedEngine.viewPan(view, delta.dx, delta.dy));

  /// Resets scale and offset to identity and requests fit.
  void reset() {
    scale = 1.0;
    offsetX = 0;
    offsetY = 0;
    fit();
  }

  /// Widget coordinates → layout viewport px (what the engine's `*View` calls take). Throws a
  /// [StateError] when no view holds the controller.
  Offset toView(Offset local) {
    final page = _holder?.page;
    if (page == null || page.isDisposed) {
      throw StateError(
        'QvpViewController: toView needs a QvpPageView that holds the controller',
      );
    }
    final q = page.viewToLayout(view, local.dx, local.dy);
    return Offset(q.x, q.y);
  }
}

/// A tap on a word: the word itself, as on Android and iOS, and the gap-aware
/// hit that found it. The index is `word.index`.
typedef QvpWordTapCallback = void Function(QvpWordInfo word, QvpHit hit);

/// A tap on a decoration (ayah mark, surah banner, …) that is not a word, and
/// the hit that found it: line / distance / isExact, as for a word.
typedef QvpDecorationTapCallback =
    void Function(QvpDecorationInfo decoration, QvpHit hit);

/// Renders a [QvpPage] with the engine's layout, animated highlights, masks,
/// styled paths, tap / long-press selection and pinch / pan.
class QvpPageView extends StatefulWidget {
  /// Shows [page]. Every other argument has a default.
  const QvpPageView({
    super.key,
    required this.page,
    this.layout = const QvpViewLayout(),
    this.paper = const Color(0xfffffdf7),
    this.defaultInk,
    this.controller,
    this.onWordTap,
    this.onDecorationTap,
    this.onEmptyTap,
    this.onSelectionChanged,
    this.hitMaxDistance = QvpDefaults.tapDistance,
    this.selectionEnabled = true,
    this.panZoomEnabled = true,
    this.selectionBand = QvpDefaults.selectionBand,
    this.paperShadow = true,
    this.maxZoom = QvpDefaults.maxZoom,
    this.onZoomChanged,
    this.underlay,
    this.overlay,
    this.repaintListenable,
    this.onSwipe,
  });

  /// The page to draw. The view lays it out, ticks it and draws it; it does not free it.
  final QvpPage page;

  /// The padding, spacing and grid the view lays the page out with.
  final QvpViewLayout layout;

  /// Optional single-pass canvas painter drawn beneath the ink (e.g. Surah header backgrounds).
  final void Function(
    ui.Canvas canvas,
    Size size,
    QvpPage page,
    QvpLayout? layout,
  )?
  underlay;

  /// Optional single-pass canvas painter drawn above the ink (e.g. Ayah mark numerals, tajweed tooltips).
  final void Function(
    ui.Canvas canvas,
    Size size,
    QvpPage page,
    QvpLayout? layout,
  )?
  overlay;

  /// Optional listenable that requests a repaint of this view when fired (e.g. audio spinner).
  final Listenable? repaintListenable;

  /// Sideways flick / swipe turns pages: +1 for next page (in RTL), -1 for previous page.
  final void Function(int pages)? onSwipe;

  /// The size the reader is at changed: a pinch committed, or a step was asked for. The page
  /// reflows as they zoom, so this is where a host redraws its own furniture.
  final void Function(QvpZoom)? onZoomChanged;

  /// Paper colour behind the ink (null = transparent).
  final Color? paper;

  /// Default ink; applied to the page with `setDefaultColor` when it changes. Anything [rgba] accepts.
  final Object? defaultInk;

  /// The pan and zoom to share with the host. Null gives the view a controller of its own.
  final QvpViewController? controller;

  /// Tap on a word (gap-aware), with the word and its hit.
  final QvpWordTapCallback? onWordTap;

  /// Tap on a decoration that is not a word, with the decoration and its hit.
  final QvpDecorationTapCallback? onDecorationTap;

  /// Tap that hits neither a word nor a decoration.
  final VoidCallback? onEmptyTap;

  /// Whole-word selection changed through long-press-drag (empty list = cleared).
  final void Function(List<int> words)? onSelectionChanged;

  /// Max distance (page units) for the gap-aware tap.
  final double hitMaxDistance;

  /// [selectionEnabled] turns on long-press-drag selection, [panZoomEnabled] the pinch, pan
  /// and double-tap fit, and [paperShadow] a shadow under the paper.
  final bool selectionEnabled, panZoomEnabled, paperShadow;

  /// Band colour of the drag selection (0xRRGGBBAA), drawn in [QvpLayer.selection].
  final int selectionBand;

  /// How far the magnifying glass may go: the ceiling the pinch is clamped to under
  /// [QvpZoomMode.magnify], [QvpDefaults.maxZoom] unless the host lowers it. A host that draws
  /// its own furniture beside the ink and scales it with the glass says here what that
  /// furniture can survive. A ceiling under the fitted page is the fitted page, since a pinch
  /// never shrinks the page inside the screen. 0 or below is the engine's own ceiling.
  final double maxZoom;

  /// Pre-records base ink into the global picture cache so page turns are instant.
  static void prepare(
    QvpPage page, {
    double scale = 1.0,
    double dpr = 1.0,
    Color? inkColor,
    bool surahFrames = true,
    double? width,
    double? height,
  }) {
    _InkCache.prepare(
      page,
      inkColor: inkColor,
      surahFrames: surahFrames,
      dpr: dpr,
      width: width,
      height: height,
    );
  }

  /// Evicts any cached base ink pictures for [pageNumber] from the global cache.
  static void evictPage(int pageNumber) {
    _InkCache.evictPage(pageNumber);
  }

  /// Checks whether a cached base ink picture exists for [key] in the global cache.
  @visibleForTesting
  static bool hasCachedInk(Object key) => _InkCache.hasCachedInk(key);

  /// Maximum number of cached pictures allowed in the global picture cache.
  @visibleForTesting
  static int get maxPictureCacheEntries => _LruCache.maxEntries;

  @override
  State<QvpPageView> createState() => QvpPageViewState();
}

/// The state of a [QvpPageView]. Reach it with a `GlobalKey` to read the zoom, the render
/// [QvpPageViewStats.stats] or the clock the view ticks the page with.
class QvpPageViewState extends State<QvpPageView>
    with SingleTickerProviderStateMixin {
  late QvpViewController _ctl;
  late final Ticker _ticker;
  final Stopwatch _clock = Stopwatch()..start();
  final ValueNotifier<int> _frame = ValueNotifier(0);
  final _InkCache _cache = _InkCache();
  Size _size = Size.zero;
  QvpViewLayout? _laidOut;
  int _selHandle = 0, _selAnchor = -1;
  bool _selecting = false;

  /// The dress the page was last fitted with, and the dressed box the engine gave for it.
  QvpDressSpec? _fittedDress;
  List<double>? _fittedBox;

  /// The view the engine works from in a pinch, and where the fingers went down. The view is
  /// the one the pinch began on, and under the reflowing controls the one the last frame
  /// returned, before the drift.
  QvpView _gView = const QvpView();
  Offset _gFocal = Offset.zero;

  /// Where the reader's zoom control stands, and where it stood when a pinch began.
  QvpZoom _zoom = const QvpZoom();
  QvpZoom _gZoom = const QvpZoom();

  /// The scale the page was last fitted at: the floor of a magnifying pinch.
  double _fitScale = 1;

  /// The controller in use: the widget's own, or the one the view made.
  QvpViewController get controller => _ctl;

  /// The page the widget shows.
  QvpPage get page => widget.page;

  /// How far the glass is over the fitted page: the view scale over the fitted scale, 1 at rest
  /// and in every mode but [QvpZoomMode.magnify]. A host overlay divides this out of the view
  /// transform to draw its furniture once and let the glass scale that one raster.
  double get peekScale => _fitScale > 0 ? _ctl.scale / _fitScale : 1;

  /// True while the engine is animating.
  bool get animating => _ticker.isActive;

  @override
  void initState() {
    super.initState();
    _ctl = widget.controller ?? QvpViewController();
    _ticker = createTicker(_onTick);
    _attachPage();
    _applyInk();
  }

  void _attachPage() {
    _applyInk();
    widget.page.addListener(_onPageChanged);
    _ctl._attach(this);
    _cache.attach(widget.page);
    _selHandle = 0;
    _selAnchor = -1;
    _laidOut = null;
    _fittedDress = widget.page.dressSpec;
    _fittedBox = null;
    _ctl._fitRequested = true;
  }

  /// The dressed box as the engine gives it: the view box, then the overflow. Null when the
  /// page is not dressed.
  List<double>? _dressBox() {
    final info = page.dressInfo();
    return info == null ? null : [...info.viewBox, ...info.overflow];
  }

  void _applyInk() {
    final ink = widget.defaultInk;
    if (ink != null && rgba(ink) != widget.page.defaultInk) {
      widget.page.setDefaultColor(ink);
    }
  }

  @override
  void didUpdateWidget(QvpPageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _ctl._detach(this);
      _ctl =
          widget.controller ??
          (oldWidget.controller == null ? _ctl : QvpViewController());
      _ctl._attach(this);
    }
    if (oldWidget.page != widget.page) {
      oldWidget.page.removeListener(_onPageChanged);
      _attachPage();
    }
    if (oldWidget.defaultInk != widget.defaultInk) _applyInk();
    if (oldWidget.layout != widget.layout) _ctl._fitRequested = true;
    if (oldWidget.defaultInk != widget.defaultInk) {
      _cache._dropPicture();
      _cache.entry = null;
      _ctl.refresh();
    }
  }

  @override
  void dispose() {
    widget.page.removeListener(_onPageChanged);
    _ticker.dispose();
    _cache.dispose();
    _frame.dispose();
    // A host may have handed the controller to a new view already: let it go only if it is
    // still this view's.
    _ctl._detach(this);
    if (widget.controller == null) _ctl.dispose();
    super.dispose();
  }

  bool _isRelayouting = false;

  void _onPageChanged() {
    if (_isRelayouting) return;
    // the app cleared the selection behind our back → drop our band
    if (_selHandle != 0 &&
        !_selecting &&
        !page.isDisposed &&
        page.selection().isEmpty) {
      final h = _selHandle;
      _selHandle = 0;
      page.removeHighlight(h);
      return; // removeHighlight notifies again
    }
    // A dress or an undress can change how big the page is. Fit it again only when the
    // engine's dressed box changed. A new colour keeps the box, so it keeps the reader's zoom.
    if (!page.isDisposed &&
        !identical(page.dressSpec, _fittedDress) &&
        mounted) {
      _fittedDress = page.dressSpec;
      final box = _dressBox();
      if (!listEquals(box, _fittedBox)) {
        _fittedBox = box;
        _ctl._fitRequested = true;
        // A dress made while the tree builds waits for the frame to end.
        if (SchedulerBinding.instance.schedulerPhase ==
            SchedulerPhase.persistentCallbacks) {
          SchedulerBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() {});
          });
        } else {
          setState(() {});
        }
      }
    }
    _ensureTicking();
  }

  void _ensureTicking() {
    if (!_ticker.isActive && mounted && !page.isDisposed) {
      final more = page.tick(nowMs);
      if (more) _ticker.start();
    }
  }

  /// Milliseconds since the view was made: the time the view passes to [QvpPage.tick].
  double get nowMs => _clock.elapsedMicroseconds / 1000;

  void _onTick(Duration _) {
    if (page.isDisposed) {
      _ticker.stop();
      return;
    }
    final more = page.tick(nowMs);
    _frame.value++;
    if (!more) _ticker.stop();
  }

  // ── layout & fit (engine layout, then pan/zoom on top) ──
  /// The spec the page is laid out under: the reader's layout, with the size their zoom control
  /// asks for written onto it. The engine decides what that is.
  QvpLayoutSpec _spec(Size size) {
    final base = widget.layout.toSpec(size.width, size.height);
    return page.zoomSpec(base, _zoom);
  }

  void _relayout(Size size) {
    if (page.isDisposed) return;
    _isRelayouting = true;
    try {
      final spec = _spec(size);
      page.layout(spec);
      _cache._drawList = null;
      _cache._dropPicture();
      _laidOut = widget.layout;
      _size = size;
      _ctl.viewport = size;
      _fittedDress = page.dressSpec;
      _fittedBox = _dressBox();
    } finally {
      _isRelayouting = false;
    }
  }

  void _fit(Size size) {
    if (page.isDisposed) return;
    // A dress or an undress refits in the engine, so read the layout again.
    final l = page.readLayout() ?? page.currentLayout;
    if (l == null) return;
    _ctl._fitRequested = false;
    _fittedDress = page.dressSpec;
    _fittedBox = _dressBox();
    // The engine fits the content plus the dress overflow. A reflowed page is taller than the
    // screen because the reader asked for it: the engine shows its top.
    _ctl.scale = l.fitScale;
    _fitScale = l.fitScale;
    // Land the page on whole device pixels, exactly matching native Android's round(v.offsetX/Y).
    // A fractional offset forces Skia to resample every texture blit, causing blurriness and extra raster load.
    _ctl.offsetX = l.fitX.roundToDouble();
    _ctl.offsetY = l.fitY.roundToDouble();
  }

  /// Re-runs the engine layout and fits the page.
  void fit() {
    if (_size == Size.zero) return;
    _relayout(_size);
    _fit(_size);
    _ctl.refresh();
  }

  // ── gestures ──
  QvpHit? _hitAt(Offset local, {double? maxDistance}) {
    final v = _ctl.toView(local);
    return page.hitTestView(
      v.dx,
      v.dy,
      QvpHitOptions(maxDistance: maxDistance ?? 0),
    );
  }

  void _onTapUp(TapUpDetails d) {
    final v = _ctl.toView(d.localPosition);
    final exact = page.hitTestExactView(v.dx, v.dy);
    if (exact != null &&
        exact.decoration >= 0 &&
        exact.decoration < page.decorations.length) {
      widget.onDecorationTap?.call(page.decorations[exact.decoration], exact);
      return;
    }

    for (final m in page.ayahMarksView()) {
      final dx = v.dx - m.cx;
      final dy = v.dy - m.cy;
      final r = m.r + 14.0;
      if (dx * dx + dy * dy <= r * r &&
          m.decoration >= 0 &&
          m.decoration < page.decorations.length) {
        final hit = QvpHit(
          word: -1,
          path: m.ornamentPath,
          decoration: m.decoration,
          line: m.line,
          distance: 0,
          isExact: true,
        );
        widget.onDecorationTap?.call(page.decorations[m.decoration], hit);
        return;
      }
    }

    final h = _hitAt(d.localPosition, maxDistance: widget.hitMaxDistance);
    if (h != null &&
        h.decoration >= 0 &&
        h.decoration < page.decorations.length) {
      widget.onDecorationTap?.call(page.decorations[h.decoration], h);
    } else if (h != null && h.word >= 0 && h.word < page.words.length) {
      widget.onWordTap?.call(page.words[h.word], h);
    } else {
      widget.onEmptyTap?.call();
    }
  }

  double _swipeDx = 0.0;

  /// The fingers went down, or their number changed: Flutter starts the scale gesture again
  /// then, with `scale` back at 1, so this is where every pinch is measured from.
  void _onScaleStart(ScaleStartDetails d) {
    _swipeDx = 0.0;
    _gView = _ctl.view;
    _gFocal = d.localFocalPoint;
    // where the control stood when the fingers went down: the engine measures them against this,
    // so a slow pinch walks the steps one at a time instead of running away through them
    _gZoom = _zoom;
  }

  /// The view the engine handed back, held against the viewport. A dressed page holds its
  /// border on the screen too, not only its text.
  void _hold(QvpView v) {
    final h = page.dressClamp(v, _size.width, _size.height);
    _ctl.set(
      scale: h.scale,
      offsetX: h.offsetX.roundToDouble(),
      offsetY: h.offsetY.roundToDouble(),
    );
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (!widget.panZoomEnabled || _size == Size.zero) return;
    if (d.pointerCount < 2) {
      // One finger: a drag. A page with no sideways travel to spend scrolls up and down only;
      // the engine says which, and holds the page against the viewport either way.
      final sideways =
          page.sidewaysDrag(_zoom, _ctl.view, _fitScale) == QvpSideways.pan;
      _hold(
        page.engine.viewPan(
          _ctl.view,
          sideways ? d.focalPointDelta.dx : 0,
          d.focalPointDelta.dy,
        ),
      );
      if (d.pointerCount == 1) {
        _swipeDx += d.focalPointDelta.dx;
      }
      return;
    }
    // the fingers' drift since the pinch began: it pans the page, so two fingers drag it
    final drift = d.localFocalPoint - _gFocal;
    if (_gZoom.mode == QvpZoomMode.magnify) {
      // The printed page under a magnifying glass: the rows never move. The engine zooms the
      // view the pinch began on about the point it began at, by the whole gesture, with the
      // settled page as the floor and the host's ceiling above, then pans it by the drift: a
      // pinch magnifies the print, it does not shrink the page inside the screen, not even for
      // a ceiling set under it.
      final zoomed = page.engine.viewZoomAbout(
        _gView,
        _gFocal.dx,
        _gFocal.dy,
        d.scale,
        min: _fitScale,
        max: widget.maxZoom,
      );
      _hold(page.engine.viewPan(zoomed, drift.dx, drift.dy));
      return;
    }
    // The engine owns the whole pinch: which step it lands on, when it commits, and what holds
    // the reader's place when the page reflows under the fingers. The control and the focal
    // point stay where the gesture began. The view is the one the last frame returned, before
    // the drift: a step committed earlier in this gesture moved the page, and the engine finds
    // the word under the fingers on the layout it has now.
    final c = page.zoomPinch(
      widget.layout.toSpec(_size.width, _size.height),
      _gZoom,
      _gView,
      d.scale,
      _gFocal.dx,
      _gFocal.dy,
    );
    _gView = c.view;
    if (c.relaid) {
      _zoom = c.zoom;
      page.readLayout();
      _fittedBox =
          _dressBox(); // a new layout moves the overflow, not the dress
      widget.onZoomChanged?.call(c.zoom);
    }
    _hold(page.engine.viewPan(c.view, drift.dx, drift.dy));
  }

  int _resolveSwipe(double dx, double vx) {
    // The engine owns the swipe classifier on every platform (Android Types.kt,
    // Swift Types.swift, web qvp.js — all delegated to `swipe_direction`): a
    // released drag is a page swipe when it is more sideways than vertical and
    // either farther than 40 viewport px or faster than 500 px/s. The engine
    // holds the mushaf's RTL sign, so a flick to the right turns to the next
    // page and no host turns the book backwards (docs/API.md).
    return page.engine.swipePages(dx, 0.0, vx, 0.0);
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (widget.onSwipe != null) {
      final sideways = page.sidewaysDrag(_zoom, _ctl.view, _fitScale);
      if (sideways == QvpSideways.turnPage) {
        final vx = d.velocity.pixelsPerSecond.dx;
        final dir = _resolveSwipe(_swipeDx, vx);
        if (dir != 0) {
          widget.onSwipe!(dir);
        }
      }
    }
    _swipeDx = 0.0;
  }

  /// Move the control to one of the page's steps: 0 is the printed page.
  void zoomToStep(int step) {
    if (_size == Size.zero) return;
    final c = page.zoomToStep(
      widget.layout.toSpec(_size.width, _size.height),
      _zoom,
      step,
      QvpView(scale: _ctl.scale, offsetX: _ctl.offsetX, offsetY: _ctl.offsetY),
    );
    setState(() => _zoom = c.zoom);
    page.readLayout();
    _fittedBox = _dressBox(); // a new layout moves the overflow, not the dress
    _ctl.set(
      scale: c.view.scale,
      offsetX: c.view.offsetX,
      offsetY: c.view.offsetY,
    );
    widget.onZoomChanged?.call(c.zoom);
  }

  /// Where the reader's zoom control stands.
  QvpZoom get zoom => _zoom;

  /// What a pinch does to the page. Stepped is what a reader gets: the pinch lands on one of
  /// the page's own zoom steps and the page breaks its rows again at that size. Magnify scales
  /// the printed page as it is, up to [QvpPageView.maxZoom]. The page is laid out and fitted
  /// again under the new policy, at the size the reader is already at.
  void setZoomMode(QvpZoomMode mode) {
    if (_zoom.mode == mode || _size == Size.zero) return;
    setState(
      () => _zoom = page.zoomMode(
        widget.layout.toSpec(_size.width, _size.height),
        _zoom,
        mode,
      ),
    );
    fit();
    widget.onZoomChanged?.call(_zoom);
  }

  void _onLongPressStart(LongPressStartDetails d) {
    if (!widget.selectionEnabled) return;
    final h = _hitAt(d.localPosition, maxDistance: widget.hitMaxDistance);
    if (h == null || h.word < 0) return;
    _selecting = true;
    _selAnchor = h.word;
    _updateSelection(h.word);
  }

  void _onLongPressMove(LongPressMoveUpdateDetails d) {
    if (!_selecting) return;
    final h = _hitAt(d.localPosition);
    if (h != null && h.word >= 0) _updateSelection(h.word);
  }

  void _updateSelection(int focus) {
    page.select(_selAnchor, focus);
    final ws = page.selection();
    if (_selHandle != 0) {
      page.moveHighlight(_selHandle, T.words(ws));
    } else {
      _selHandle = page.highlight(
        T.words(ws),
        QvpHighlightStyle(
          mode: 'band',
          band: widget.selectionBand,
          padX: QvpDefaults.selectionPadX,
          ms: 0,
          layer: QvpLayer.selection,
        ),
      );
    }
  }

  void _onLongPressEnd(LongPressEndDetails d) {
    if (!_selecting) return;
    _selecting = false;
    widget.onSelectionChanged?.call(page.selection());
  }

  /// Clears the drag selection and its band.
  void clearSelection() {
    if (_selHandle != 0) {
      page.removeHighlight(_selHandle);
      _selHandle = 0;
    }
    page.clearSelection();
    widget.onSelectionChanged?.call(const []);
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, c) {
        if (page.isDisposed) return const SizedBox.shrink();
        final size = Size(
          c.maxWidth.isFinite ? c.maxWidth : 400,
          c.maxHeight.isFinite ? c.maxHeight : 600,
        );
        if (size != _size ||
            _laidOut != widget.layout ||
            page.currentLayout == null) {
          _relayout(size);
          _ctl._fitRequested = true;
        }
        if (_ctl._fitRequested) _fit(size);
        return ClipRect(
          child: Semantics(
            label: 'Quran Mushaf page ${page.page}',
            textDirection: TextDirection.rtl,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: _onTapUp,
              onDoubleTap: widget.panZoomEnabled ? fit : null,
              onScaleStart: widget.panZoomEnabled ? _onScaleStart : null,
              onScaleUpdate: widget.panZoomEnabled ? _onScaleUpdate : null,
              onScaleEnd: widget.panZoomEnabled ? _onScaleEnd : null,
              onHorizontalDragStart:
                  (!widget.panZoomEnabled && widget.onSwipe != null)
                  ? (_) => _swipeDx = 0.0
                  : null,
              onHorizontalDragUpdate:
                  (!widget.panZoomEnabled && widget.onSwipe != null)
                  ? (d) => _swipeDx += d.primaryDelta ?? d.delta.dx
                  : null,
              onHorizontalDragEnd:
                  (!widget.panZoomEnabled && widget.onSwipe != null)
                  ? (d) {
                      final vx = d.primaryVelocity ?? 0.0;
                      final dir = _resolveSwipe(_swipeDx, vx);
                      if (dir != 0) {
                        widget.onSwipe!(dir);
                      }
                      _swipeDx = 0.0;
                    }
                  : null,
              onHorizontalDragCancel:
                  (!widget.panZoomEnabled && widget.onSwipe != null)
                  ? () => _swipeDx = 0.0
                  : null,
              onLongPressStart: widget.selectionEnabled
                  ? _onLongPressStart
                  : null,
              onLongPressMoveUpdate: widget.selectionEnabled
                  ? _onLongPressMove
                  : null,
              onLongPressEnd: widget.selectionEnabled ? _onLongPressEnd : null,
              child: RepaintBoundary(
                child: CustomPaint(
                  size: size,
                  isComplex: true,
                  willChange: false,
                  painter: _QvpPainter(
                    page: page,
                    view: _ctl,
                    frame: _frame,
                    cache: _cache,
                    dpr: dpr,
                    paper: widget.paper,
                    paperShadow: widget.paperShadow,
                    surahFrames: widget.layout.surahFrames,
                    underlay: widget.underlay,
                    overlay: widget.overlay,
                    repaintListenable: widget.repaintListenable,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// What a recording of the base ink was made for. A frame compares its own values with
/// [matches] first and builds a key only when they differ, so a frame that keeps its ink
/// allocates nothing for the key.
@immutable
class _InkKey {
  const _InkKey(
    this.page,
    this.ink,
    this.scale,
    this.offsetX,
    this.offsetY,
    this.top,
    this.bandH,
    this.styled,
    this.surahFrames,
  );

  final int page, ink, bandH, styled;
  final double? scale, offsetX, offsetY;
  final double top;
  final bool surahFrames;

  bool matches(
    int page,
    int ink,
    double? scale,
    double? offsetX,
    double? offsetY,
    double top,
    int bandH,
    int styled,
    bool surahFrames,
  ) {
    if (page != this.page) return false;
    if (ink != this.ink) return false;
    if (styled != this.styled) return false;
    if (surahFrames != this.surahFrames) return false;
    if ((top - this.top).abs() > 0.5) return false;
    if ((bandH - this.bandH).abs() > 1.0) return false;
    if (scale != null && this.scale != null) {
      if ((scale - this.scale!).abs() > 0.001) return false;
    } else if (scale != this.scale) {
      return false;
    }
    if (offsetX != null && this.offsetX != null) {
      if ((offsetX - this.offsetX!).abs() > 0.5) return false;
    } else if (offsetX != this.offsetX) {
      return false;
    }
    if (offsetY != null && this.offsetY != null) {
      if ((offsetY - this.offsetY!).abs() > 0.5) return false;
    } else if (offsetY != this.offsetY) {
      return false;
    }
    return true;
  }

  @override
  bool operator ==(Object other) =>
      other is _InkKey &&
      other.matches(
        page,
        ink,
        scale,
        offsetX,
        offsetY,
        top,
        bandH,
        styled,
        surahFrames,
      );

  static int _quantize(double? v, double step) =>
      v == null ? 0 : (v / step).round();

  @override
  int get hashCode => Object.hash(
    page,
    ink,
    _quantize(scale, 0.001),
    _quantize(offsetX, 0.5),
    _quantize(offsetY, 0.5),
    _quantize(top, 0.5),
    bandH,
    styled,
    surahFrames,
  );
}

class _PictureCacheEntry {
  final _InkKey key;
  final ui.Picture picture;

  /// How many engine paths the recording draws. A replay draws all of them, so the stats of
  /// the last frame need this on a cache hit as much as on a fresh recording.
  final int paths;

  _PictureCacheEntry(this.key, this.picture, this.paths);

  /// True once the cache has let the picture go. A view that holds the entry records again.
  bool disposed = false;

  void dispose() {
    disposed = true;
    try {
      picture.dispose();
    } on Object catch (_) {}
  }
}

class _LruCache {
  /// How many page vector pictures to keep in cache (vector pictures take <100KB each).
  static const int maxEntries = 32;
  final LinkedHashMap<_InkKey, _PictureCacheEntry> _entries = LinkedHashMap();

  void evictPage(int pageNumber) {
    final keysToRemove = _entries.keys
        .where((k) => k.page == pageNumber)
        .toList();
    for (final k in keysToRemove) {
      _entries.remove(k)?.dispose();
    }
  }

  bool hasCachedInk(Object key) => key is _InkKey
      ? _entries.containsKey(key)
      : (key is int && _entries.keys.any((k) => k.page == key));

  _PictureCacheEntry? get(_InkKey key) {
    final entry = _entries.remove(key);
    if (entry != null) {
      _entries[key] = entry;
      return entry;
    }
    // Epsilon-safe fallback scan over cached entries (at most 32 entries)
    for (final e in _entries.entries) {
      if (e.key.matches(
        key.page,
        key.ink,
        key.scale,
        key.offsetX,
        key.offsetY,
        key.top,
        key.bandH,
        key.styled,
        key.surahFrames,
      )) {
        _entries.remove(e.key);
        _entries[key] = e.value;
        return e.value;
      }
    }
    return null;
  }

  _PictureCacheEntry put(_InkKey key, ui.Picture pic, int paths) {
    final old = _entries.remove(key);
    if (old != null && old.picture != pic) {
      old.dispose();
    }
    final entry = _entries[key] = _PictureCacheEntry(key, pic, paths);
    while (_entries.length > maxEntries) {
      final firstKey = _entries.keys.first;
      _entries.remove(firstKey)?.dispose();
    }
    return entry;
  }

  bool containsPicture(ui.Picture p) {
    for (final e in _entries.values) {
      if (e.picture == p) return true;
    }
    return false;
  }
}

class _DrawList {
  _DrawList({
    required this.draws,
    required this.places,
    required this.ofPath,
    required this.page,
    required this.top,
    required this.bandH,
    required this.contentH,
    required this.scale,
    required this.offsetX,
    required this.offsetY,
  });

  final List<QvpDraw> draws;
  final List<QvpPlacement> places;
  final Map<int, int> ofPath;

  /// What the list was read for: the page, the band and the layout's place.
  final int page;
  final double top, bandH, contentH;
  final double? scale, offsetX, offsetY;

  bool matches(
    int page,
    double top,
    double bandH,
    double contentH,
    QvpLayout? l,
  ) {
    if (page != this.page) return false;
    if ((top - this.top).abs() > 0.5) return false;
    if ((bandH - this.bandH).abs() > 1.0) return false;
    if ((contentH - this.contentH).abs() > 1.0) return false;
    if (l?.scale != null && scale != null) {
      if ((l!.scale - scale!).abs() > 0.001) return false;
    } else if (l?.scale != scale) {
      return false;
    }
    if (l?.offsetX != null && offsetX != null) {
      if ((l!.offsetX - offsetX!).abs() > 0.5) return false;
    } else if (l?.offsetX != offsetX) {
      return false;
    }
    if (l?.offsetY != null && offsetY != null) {
      if ((l!.offsetY - offsetY!).abs() > 0.5) return false;
    } else if (l?.offsetY != offsetY) {
      return false;
    }
    return true;
  }
}

/// Boxes the engine placed in viewport px, highlight bands or mask blocks, as one nonzero path
/// for each run of boxes that share a highlight and a colour. The layer builds the paths when
/// the boxes change, and every frame after that draws them as they are.
class _BoxLayer {
  final List<ui.Path> _paths = [];
  final List<Color> _colors = [];
  int _groups = 0;

  /// How many boxes the paths hold.
  int boxes = 0;

  void set(List<QvpBox> list) {
    _groups = 0;
    boxes = list.length;
    var id = -1, col = 0;
    ui.Path? path;
    for (var i = 0; i < list.length; i++) {
      final b = list[i];
      if (path == null || b.id != id || b.color != col) {
        path = _take(_groups, b.color);
        _groups++;
        id = b.id;
        col = b.color;
      }
      final r = Rect.fromLTRB(b.x0, b.y0, b.x1, b.y1);
      if (b.radius > 0) {
        path.addRRect(RRect.fromRectAndRadius(r, Radius.circular(b.radius)));
      } else {
        path.addRect(r);
      }
    }
  }

  ui.Path _take(int i, int color) {
    if (i == _paths.length) {
      _paths.add(ui.Path());
      _colors.add(QvpColor.toColor(color));
    } else {
      _paths[i].reset();
      _colors[i] = QvpColor.toColor(color);
    }
    return _paths[i];
  }

  void draw(ui.Canvas c, ui.Paint paint, QvpViewController view) {
    if (_groups == 0) return;
    c.save();
    c.translate(view.offsetX, view.offsetY);
    c.scale(view.scale);
    for (var i = 0; i < _groups; i++) {
      paint.color = _colors[i];
      c.drawPath(_paths[i], paint);
    }
    c.restore();
  }
}

/// Per-page render cache: base ink picture and layout draws.
class _InkCache {
  static final _LruCache _globalInkCache = _LruCache();

  static _PictureCacheEntry? getGlobalInk(_InkKey key) =>
      _globalInkCache.get(key);

  static void evictPage(int pageNumber) =>
      _globalInkCache.evictPage(pageNumber);

  static bool hasCachedInk(Object key) => _globalInkCache.hasCachedInk(key);
  static _PictureCacheEntry keepGlobalInk(
    _InkKey key,
    ui.Picture pic,
    int paths,
  ) => _globalInkCache.put(key, pic, paths);

  static void prepare(
    QvpPage page, {
    Color? inkColor,
    bool surahFrames = true,
    double dpr = 1.0,
    double? width,
    double? height,
  }) {
    if (page.isDisposed) return;
    if (inkColor != null && rgba(inkColor) != page.defaultInk) {
      page.setDefaultColor(inkColor);
    }
    final l = page.currentLayout;
    if (l == null) return;
    final ink = page.defaultInk;
    const double top = 0.0;
    final double bandH = math.max(l.contentH, 1.0);
    final styledPaths = page.styledPaths();
    var keyVal = 1;
    for (var i = 0; i < styledPaths.length; i++) {
      keyVal = 31 * (31 * keyVal + styledPaths[i].path) + styledPaths[i].color;
    }
    final key = _InkKey(
      page.page,
      ink,
      l.scale,
      l.offsetX,
      l.offsetY,
      top,
      bandH.toInt(),
      keyVal,
      surahFrames,
    );
    final existing = getGlobalInk(key);
    if (existing != null) return;

    final rec = ui.PictureRecorder();
    final c = ui.Canvas(rec);
    if (top != 0.0) {
      c.translate(0, -top);
    }
    final paint = ui.Paint()
      ..color = QvpColor.toColor(ink)
      ..isAntiAlias = true;

    final omitted = styledPaths.isEmpty
        ? null
        : {for (final s in styledPaths) s.path};
    final draws = (top == 0.0 && bandH >= l.contentH)
        ? page.layoutDrawList()
        : page.layoutDrawList(bandTop: top, bandBottom: top + bandH);
    final places = page.layoutPlacements();
    var cur = -1, open = false, n = 0;
    for (final d in draws) {
      if (omitted != null && omitted.contains(d.path)) continue;
      if (d.placement != cur) {
        if (open) c.restore();
        c.save();
        _QvpPainter._placeInLayout(
          c,
          l,
          d.placement < places.length
              ? places[d.placement]
              : QvpPlacement.identity,
        );
        open = true;
        cur = d.placement;
      }
      c.drawPath(page.path(d.path), paint);
      n++;
    }
    if (open) c.restore();
    final pic = rec.endRecording();

    keepGlobalInk(key, pic, n);
  }

  QvpPage? page;
  ui.Picture? picture;

  /// The global cache's entry for [picture], or null when this cache recorded nothing yet.
  _PictureCacheEntry? entry;

  /// The ornament layer: picture in layout px, and the dress revision and layout it was
  /// recorded for.
  ui.Picture? ornaments;
  int ornamentRevision = -1;
  double? ornamentScale, ornamentOffsetX, ornamentOffsetY;

  _DrawList? _drawList;

  _DrawList getDrawList(
    QvpPage page,
    QvpLayout? l,
    double top,
    double bandH,
    double contentH,
  ) {
    final kept = _drawList;
    if (kept != null && kept.matches(page.page, top, bandH, contentH, l)) {
      return kept;
    }
    final draws = top == 0.0 && bandH >= contentH
        ? page.layoutDrawList()
        : page.layoutDrawList(bandTop: top, bandBottom: top + bandH);
    final places = page.layoutPlacements();
    final ofPath = <int, int>{};
    for (var i = 0; i < draws.length; i++) {
      ofPath.putIfAbsent(draws[i].path, () => draws[i].placement);
    }
    return _drawList = _DrawList(
      draws: draws,
      places: places,
      ofPath: ofPath,
      page: page.page,
      top: top,
      bandH: bandH,
      contentH: contentH,
      scale: l?.scale,
      offsetX: l?.offsetX,
      offsetY: l?.offsetY,
    );
  }

  // What the last frame read from the engine, kept until the page or the clock moves.
  QvpPage? _readPage;
  QvpLayout? _readLayout;
  int _readRevision = 0, _readClock = 0;

  /// Paths off the default ink, their colours, and a hash of which paths they are: the
  /// base ink leaves them out, so the key of its recording holds the hash.
  List<QvpStyledPath> styled = const [];
  List<Color> styledColors = const [];
  int styledKey = 1;
  QvpDressInfo? dress;
  final _BoxLayer bands = _BoxLayer(), masks = _BoxLayer();

  /// Asks the engine again for what is drawn over and under the base ink, if any of it can
  /// have changed: a call on the page moves its revision, a zoom lays it out again, and a
  /// tick from any caller moves [pageClock]. The styled paths and the bands follow the clock as well. The
  /// masks and the dress follow the page alone. A frame where nothing changed asks for nothing.
  void read(QvpPage page) {
    final l = page.currentLayout;
    final changed =
        !identical(page, _readPage) ||
        page.revision != _readRevision ||
        !identical(l, _readLayout);
    final clock = pageClock(page);

    if (changed || clock != _readClock) {
      styled = page.styledPaths();
      var key = 1;
      for (var i = 0; i < styled.length; i++) {
        key = 31 * (31 * key + styled[i].path) + styled[i].color;
      }
      styledKey = key;
      styledColors = [for (final s in styled) QvpColor.toColor(s.color)];
      bands.set(page.highlightBoxesView());
      masks.set(page.maskBoxesView());
    }
    if (changed) {
      dress = page.dressInfo();
    }
    _readPage = page;
    _readLayout = l;
    _readRevision = page.revision;
    _readClock = clock;
  }

  /// The paper of the last frame, kept while the view and the dress leave it where it is.
  Rect paper = Rect.zero;

  /// Times the overlay of each frame.
  final Stopwatch overlayClock = Stopwatch();

  /// Stats of the last frame (for HUDs).
  int basePaths = 0, overlayPaths = 0, bandCount = 0;
  double baseMs = 0, overlayMs = 0;

  void attach(QvpPage p) {
    if (page == p) return;
    page = p;
    _dropPicture();
    dropOrnaments();
    _drawList = null;
    _readPage = null;
  }

  void _dropPicture() {
    entry = null;
    if (picture != null) {
      if (!_globalInkCache.containsPicture(picture!)) {
        try {
          picture!.dispose();
        } on Object catch (_) {}
      }
      picture = null;
    }
  }

  /// Drops the ornament picture. This cache owns it outright, unlike the base ink, which the
  /// global cache may still hold, so it is always safe to dispose here.
  void dropOrnaments() {
    if (ornaments != null) {
      try {
        ornaments!.dispose();
      } on Object catch (_) {}
      ornaments = null;
      ornamentRevision = -1;
    }
  }

  void dispose() {
    _dropPicture();
    dropOrnaments();
    page = null;
    _drawList = null;
    _readPage = null;
    _readLayout = null;
  }
}

/// Draws a laid-out passage on [canvas], in the layout's own px from the canvas origin: every
/// path of [layout], from its page in [pages] (by page number), in [ink]. Translate the canvas
/// to where the passage goes first. [paths] optionally caches or provides pre-built paths.
/// Without it, paths are lazily resolved via [page.path] without building whole-page lists.
void paintPassage(
  ui.Canvas canvas,
  QvpPassageLayout layout,
  Map<int, QvpPage> pages,
  Color ink, {
  Map<int, List<ui.Path>>? paths,
}) {
  final places = layout.placements;
  final s = layout.scale;
  final paint = ui.Paint()
    ..color = ink
    ..isAntiAlias = true;
  // The same placement loop as the page painter: a point (x, y) draws at
  // scale · (kx · x + dx), scale · (ky · y + dy), and runs under one placement share a save.
  var cur = -1, open = false;
  for (final d in layout.draws) {
    final page = pages[d.page];
    if (page == null) continue;
    final path = (paths != null && paths[d.page] != null)
        ? paths[d.page]![d.path]
        : page.path(d.path);
    if (d.placement != cur) {
      if (open) canvas.restore();
      canvas.save();
      final q = d.placement < places.length
          ? places[d.placement]
          : QvpPlacement.identity;
      canvas.translate(s * q.dx, s * q.dy);
      canvas.scale(s * q.kx, s * q.ky);
      open = true;
      cur = d.placement;
    }
    canvas.drawPath(path, paint);
  }
  if (open) canvas.restore();
}

class _QvpPainter extends CustomPainter {
  _QvpPainter({
    required this.page,
    required this.view,
    required ValueListenable<int> frame,
    required this.cache,
    required this.dpr,
    required this.paper,
    required this.paperShadow,
    this.surahFrames = true,
    this.underlay,
    this.overlay,
    Listenable? repaintListenable,
  }) : super(
         repaint: Listenable.merge([
           page,
           view,
           frame,
           if (repaintListenable != null) repaintListenable,
         ]),
       );

  final QvpPage page;
  final QvpViewController view;
  final _InkCache cache;
  final double dpr;
  final Color? paper;
  final bool paperShadow;
  final bool surahFrames;
  final void Function(
    ui.Canvas canvas,
    Size size,
    QvpPage page,
    QvpLayout? layout,
  )?
  underlay;
  final void Function(
    ui.Canvas canvas,
    Size size,
    QvpPage page,
    QvpLayout? layout,
  )?
  overlay;

  final ui.Paint _boxPaint = ui.Paint()..isAntiAlias = true;
  final ui.Path _boxPath = ui.Path();
  final ui.Paint _styledPaint = ui.Paint()
    ..isAntiAlias = true
    ..blendMode = ui.BlendMode.srcOver;
  final ui.Paint _ornamentFill = ui.Paint()..isAntiAlias = true;
  final ui.Paint _ornamentStroke = ui.Paint()
    ..isAntiAlias = true
    ..style = ui.PaintingStyle.stroke
    ..strokeCap = ui.StrokeCap.round
    ..strokeJoin = ui.StrokeJoin.round;

  /// Put the canvas under one placement of the draw list: page units in, logical px out. A
  /// reflowed page moves words between rows, so a path is placed by the group the engine put it
  /// in and not by the line it was printed on.
  void _placeAt(ui.Canvas c, QvpLayout? l, QvpPlacement q) {
    final ls = l?.scale ?? 1;
    final s = view.scale * ls;
    c.translate(
      view.offsetX + view.scale * ((l?.offsetX ?? 0) + q.dx * ls),
      view.offsetY + view.scale * ((l?.offsetY ?? 0) + q.dy * ls),
    );
    c.scale(s * q.kx, s * q.ky);
  }

  /// Put the canvas under one placement in layout px, with no pan or zoom: page units in.
  static void _placeInLayout(ui.Canvas c, QvpLayout? l, QvpPlacement q) {
    final ls = l?.scale ?? 1;
    c.translate((l?.offsetX ?? 0) + q.dx * ls, (l?.offsetY ?? 0) + q.dy * ls);
    c.scale(ls * q.kx, ls * q.ky);
  }

  /// The ornament layer, behind everything else. Each draw carries the placement its ink is
  /// drawn under, so it moves with its word or title under any layout. The border carries none
  /// and sits in layout space. It is recorded once per dress revision (a new dress or a new
  /// layout), so a highlight animation or a pan never redraws a tiled border's hundreds of outlines.
  void _drawOrnaments(ui.Canvas canvas, QvpLayout? l, QvpDressInfo? info) {
    if (info == null) {
      if (cache.ornaments != null) cache.dropOrnaments();
      return;
    }
    // info.revision counts up on a new dress and on every layout, which is exactly what this
    // picture depends on: the colour and stroke width of every draw come from the dress, and
    // QvpDressSpec.colors, lineArt, ayahMarkScale and pageFrameScale each change them without
    // moving the page number or the layout. The counter restarts per QvpPage, so this key is
    // only sound in the per-instance cache, never in a static one shared across pages.
    if (cache.ornaments != null &&
        cache.ornamentRevision == info.revision &&
        cache.ornamentScale == l?.scale &&
        cache.ornamentOffsetX == l?.offsetX &&
        cache.ornamentOffsetY == l?.offsetY) {
      // already recorded for this dress and layout
    } else {
      cache.dropOrnaments();
      final rec = ui.PictureRecorder();
      final c = ui.Canvas(rec);
      final places = page.layoutPlacements();
      int? cur = -1;
      var open = false;
      for (final d in page.dressGeometry()) {
        if (!open || d.placement != cur) {
          if (open) c.restore();
          c.save();
          final pi = d.placement;
          _placeInLayout(
            c,
            l,
            pi != null && pi < places.length
                ? places[pi]
                : QvpPlacement.identity,
          );
          open = true;
          cur = d.placement;
        }
        if (d.stroke) {
          _ornamentStroke
            ..color = QvpColor.toColor(d.color)
            ..strokeWidth = d.strokeWidth;
          c.drawPath(d.path, _ornamentStroke);
        } else {
          _ornamentFill.color = QvpColor.toColor(d.color);
          c.drawPath(d.path, _ornamentFill);
        }
      }
      if (open) c.restore();
      cache.ornaments = rec.endRecording();
      cache.ornamentRevision = info.revision;
      cache.ornamentScale = l?.scale;
      cache.ornamentOffsetX = l?.offsetX;
      cache.ornamentOffsetY = l?.offsetY;
    }
    if (cache.ornaments != null) {
      canvas.save();
      canvas.translate(view.offsetX, view.offsetY);
      canvas.scale(view.scale);
      canvas.drawPicture(cache.ornaments!);
      canvas.restore();
    }
  }

  @override
  void paint(ui.Canvas canvas, Size size) {
    if (page.isDisposed) return;
    final l = page.currentLayout;
    // what the engine draws over and under the ink, read again only when something changed
    cache.read(page);
    final styled = cache.styled;
    final ink = page.defaultInk;
    // read once per frame: the paper and the ornament layer both use it
    final dress = cache.dress;

    // paper, grown by the dress overflow so a border sits on it
    final paperColor = paper;
    if (paperColor != null) {
      final o = dress?.overflow ?? const [0.0, 0.0, 0.0, 0.0];
      final left = view.offsetX - o[0] * view.scale;
      final top = view.offsetY - o[1] * view.scale;
      final right =
          view.offsetX + ((l?.contentW ?? page.width) + o[2]) * view.scale;
      final bottom =
          view.offsetY + ((l?.contentH ?? page.height) + o[3]) * view.scale;
      var rect = cache.paper;
      if (rect.left != left ||
          rect.top != top ||
          rect.right != right ||
          rect.bottom != bottom) {
        rect = cache.paper = Rect.fromLTRB(left, top, right, bottom);
      }
      if (paperShadow) {
        _boxPath.reset();
        _boxPath.addRect(rect);
        canvas.drawShadow(_boxPath, const Color(0x66000000), 6, false);
        _boxPath.reset();
      }
      _boxPaint.color = paperColor;
      canvas.drawRect(rect, _boxPaint);
    }

    // Single-pass underlay (e.g. Surah header cards)
    if (underlay != null) {
      canvas.save();
      canvas.translate(view.offsetX, view.offsetY);
      canvas.scale(view.scale);
      try {
        underlay!(canvas, size, page, l);
      } finally {
        canvas.restore();
      }
    }

    // The band of the page to record, in layout px. The engine picks it: the whole page when
    // it fits under the engine's ceiling, otherwise two screens around the reader, with a top
    // that moves in steps, so a pan reuses the picture until it crosses a step.
    final contentH = (l?.contentH ?? page.height);
    final double top, bandH;
    if (contentH <= 4096.0 || size.height <= 0 || view.scale <= 0) {
      top = 0.0;
      bandH = math.max(contentH, 1.0);
    } else {
      final band = page.layoutInkBand(view.view, size.width, size.height);
      top = band.top;
      bandH = math.max(band.height, 1.0);
    }

    // Base ink cache. The picture is recorded in layout px through _placeInLayout, so the
    // reader's pan and zoom never invalidate it. The engine layout's own offsets do, and they
    // are in the key: a relayout moves them and must redraw. A frame whose key matches the
    // picture in hand keeps it without asking the global cache.
    final styledKey = cache.styledKey;
    final q = cache.getDrawList(page, l, top, bandH, contentH);
    final held = cache.entry;
    if (held != null &&
        !held.disposed &&
        held.key.matches(
          page.page,
          ink,
          l?.scale,
          l?.offsetX,
          l?.offsetY,
          top,
          bandH.toInt(),
          styledKey,
          surahFrames,
        )) {
      cache.basePaths = held.paths;
      if (cache.picture == null) {
        cache.picture = held.picture;
      }
    } else {
      final key = _InkKey(
        page.page,
        ink,
        l?.scale,
        l?.offsetX,
        l?.offsetY,
        top,
        bandH.toInt(),
        styledKey,
        surahFrames,
      );
      final kept = _InkCache.getGlobalInk(key);
      if (kept != null) {
        cache.picture = kept.picture;
        cache.entry = kept;
        // the replay draws every path the recording holds, so the HUD reads the real number
        cache.basePaths = kept.paths;
      } else {
        final sw = Stopwatch()..start();
        final rec = ui.PictureRecorder();
        final c = ui.Canvas(rec);
        if (top != 0.0) {
          c.translate(0, -top);
        }
        final paint = ui.Paint()
          ..color = QvpColor.toColor(ink)
          ..isAntiAlias = true;

        final omitted = styled.isEmpty
            ? null
            : {for (var i = 0; i < styled.length; i++) styled[i].path};

        var cur = -1, n = 0, open = false;
        for (final d in q.draws) {
          if (omitted != null && omitted.contains(d.path)) continue;
          if (d.placement != cur) {
            if (open) c.restore();
            c.save();
            _placeInLayout(
              c,
              l,
              d.placement < q.places.length
                  ? q.places[d.placement]
                  : QvpPlacement.identity,
            );
            open = true;
            cur = d.placement;
          }
          c.drawPath(page.path(d.path), paint);
          n++;
        }
        if (open) c.restore();
        cache._dropPicture();
        final pic = rec.endRecording();

        cache.picture = pic;
        cache.basePaths = n;
        cache.baseMs = sw.elapsedMicroseconds / 1000;
        cache.entry = _InkCache.keepGlobalInk(key, pic, n);
      }
    }

    final sw = cache.overlayClock
      ..reset()
      ..start();
    // 0. the ornament layer of a dressed page, behind everything else
    _drawOrnaments(canvas, l, dress);

    // 1. highlight bands (behind the ink)
    if (cache.bands.boxes > 0) {
      cache.bands.draw(canvas, _boxPaint, view);
    }

    // 2. base ink: GPU hardware picture playback (0.05ms)
    if (cache.picture != null) {
      canvas.save();
      canvas.translate(view.offsetX, view.offsetY);
      canvas.scale(view.scale);
      if (top != 0.0) canvas.translate(0, top);
      canvas.drawPicture(cache.picture!);
      canvas.restore();
    }

    // 3. styled paths, placed the same way the ink under them was: by the group the engine put
    // the path in, which is the only answer that holds once a page has reflowed.
    if (styled.isNotEmpty) {
      final colors = cache.styledColors;
      var cur = -1, open = false;
      for (var i = 0; i < styled.length; i++) {
        final s = styled[i];
        if ((s.color & 0xff) == 0) continue;
        final pi = q.ofPath[s.path];
        if (pi == null || pi < 0) continue;
        if (pi != cur) {
          if (open) canvas.restore();
          canvas.save();
          _placeAt(
            canvas,
            l,
            pi < q.places.length ? q.places[pi] : QvpPlacement.identity,
          );
          open = true;
          cur = pi;
        }
        _styledPaint.color = colors[i];
        canvas.drawPath(page.path(s.path), _styledPaint);
      }
      if (open) canvas.restore();
    }

    // 4. mask boxes (block / blur) on top
    if (cache.masks.boxes > 0) {
      cache.masks.draw(canvas, _boxPaint, view);
    }

    // Single-pass overlay (e.g. Ayah marks, numerals, tooltips)
    if (overlay != null) {
      canvas.save();
      canvas.translate(view.offsetX, view.offsetY);
      canvas.scale(view.scale);
      try {
        overlay!(canvas, size, page, l);
      } finally {
        canvas.restore();
      }
    }

    sw.stop();
    cache.overlayMs = sw.elapsedMicroseconds / 1000;
    cache.overlayPaths = styled.length;
    cache.bandCount = cache.bands.boxes;
  }

  @override
  bool shouldRepaint(_QvpPainter old) =>
      old.page != page ||
      old.view != view ||
      old.dpr != dpr ||
      old.paper != paper ||
      old.paperShadow != paperShadow ||
      old.cache != cache ||
      old.surahFrames != surahFrames ||
      old.underlay != underlay ||
      old.overlay != overlay;
}

/// Render statistics of a [QvpPageView] (base / overlay timings of the last frame).
extension QvpPageViewStats on QvpPageViewState {
  /// What the last frame drew. `basePaths` and `baseMs` are the cached base ink's paths and
  /// milliseconds, `overlayPaths` and `overlayMs` the styled overlay's. `bands` counts the
  /// highlight bands.
  ({
    int basePaths,
    double baseMs,
    int overlayPaths,
    double overlayMs,
    int bands,
  })
  get stats => (
    basePaths: _cache.basePaths,
    baseMs: _cache.baseMs,
    overlayPaths: _cache.overlayPaths,
    overlayMs: _cache.overlayMs,
    bands: _cache.bandCount,
  );
}
