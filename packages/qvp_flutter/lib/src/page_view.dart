// QvpPageView — the Flutter host renderer for a QvpPage.
//
// Draw order per frame (same as web/qvp.js CanvasRenderer):
//   cached ornament layer → highlight bands → cached base ink → styled paths → mask boxes
// The engine decides everything (layout, hit-testing, colours, boxes); this
// widget only converts geometry into ui.Path objects once, caches the
// unstyled ink as an image at the current transform, and forwards gestures
// to the engine's hit test / selection.
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'engine.dart';

/// Layout parameters of [QvpPageView] (viewport size is taken from the widget's constraints).
/// Spacing only opens up: `lineSpacing` < 1 is clamped by the engine.
/// Pinch limits as multiples of the fitted scale; the same pair on every platform.
const double kMinZoom = 0.5;
const double kMaxZoom = 12;

@immutable
class QvpViewLayout {
  const QvpViewLayout({this.padTop = 24, this.padBottom = 24, this.padSide = 16, this.lineSpacing = 1, this.fillHeight = false, this.gridLines = 0, this.surahFrames = true});
  final double padTop, padBottom, padSide, lineSpacing;
  final bool fillHeight, surahFrames;
  final int gridLines;

  QvpViewLayout copyWith({double? padTop, double? padBottom, double? padSide, double? lineSpacing, bool? fillHeight, int? gridLines, bool? surahFrames}) => QvpViewLayout(
        padTop: padTop ?? this.padTop,
        padBottom: padBottom ?? this.padBottom,
        padSide: padSide ?? this.padSide,
        lineSpacing: lineSpacing ?? this.lineSpacing,
        fillHeight: fillHeight ?? this.fillHeight,
        gridLines: gridLines ?? this.gridLines,
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
        maxAspectSlack: QvpDefaults.aspectSlack,
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
      other.surahFrames == surahFrames;

  @override
  int get hashCode => Object.hash(padTop, padBottom, padSide, lineSpacing, fillHeight, gridLines, surahFrames);
}

/// Pan / zoom on top of the engine layout. `view px = offsetX + layout px * scale`.
class QvpViewController extends ChangeNotifier {
  double scale = 1, offsetX = 0, offsetY = 0;
  bool _fitRequested = true;

  /// Size of the last laid-out viewport (logical px).
  Size viewport = Size.zero;

  void set({double? scale, double? offsetX, double? offsetY}) {
    this.scale = scale ?? this.scale;
    this.offsetX = offsetX ?? this.offsetX;
    this.offsetY = offsetY ?? this.offsetY;
    notifyListeners();
  }

  /// Repaints views using this controller.
  void refresh() => notifyListeners();

  /// Fits the page into the viewport on the next frame.
  void fit() {
    _fitRequested = true;
    notifyListeners();
  }

  /// Zooms by [factor] around a point in widget coordinates (default: centre).
  void zoomBy(double factor, {Offset? around, double minScale = kMinZoom, double maxScale = kMaxZoom}) {
    final c = around ?? Offset(viewport.width / 2, viewport.height / 2);
    final ns = (scale * factor).clamp(minScale, maxScale);
    final k = ns / scale;
    set(scale: ns, offsetX: c.dx - (c.dx - offsetX) * k, offsetY: c.dy - (c.dy - offsetY) * k);
  }

  /// Pans the view by [delta] in widget coordinates.
  void panBy(Offset delta) => set(offsetX: offsetX + delta.dx, offsetY: offsetY + delta.dy);

  /// Resets scale and offset to identity and requests fit.
  void reset() {
    scale = 1.0;
    offsetX = 0;
    offsetY = 0;
    fit();
  }

  /// Widget coordinates → layout viewport px (what the engine's `*View` calls take).
  Offset toView(Offset local) => Offset((local.dx - offsetX) / scale, (local.dy - offsetY) / scale);
}


/// Renders a [QvpPage] with the engine's layout, animated highlights, masks,
/// styled paths, tap / long-press selection and pinch / pan.
class QvpPageView extends StatefulWidget {
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
    this.minScale = kMinZoom,
    this.maxScale = kMaxZoom,
    this.maxZoom = kMaxZoom,
    this.onZoomChanged,
  });

  final QvpPage page;
  final QvpViewLayout layout;

  /// The size the reader is at changed: a pinch committed, or a step was asked for. The page
  /// reflows as they zoom, so this is where a host redraws its own furniture.
  final void Function(QvpZoom)? onZoomChanged;

  /// Paper colour behind the ink (null = transparent).
  final Color? paper;

  /// Default ink; applied to the page with `setDefaultColor` when it changes. Anything [rgba] accepts.
  final Object? defaultInk;
  final QvpViewController? controller;

  /// Tap on a word (gap-aware). [hit] carries path / decoration / line / distance.
  final void Function(int word, QvpHit hit)? onWordTap;

  /// Tap on a decoration (ayah mark, surah banner, …) that is not a word.
  final void Function(QvpDecorationInfo decoration)? onDecorationTap;
  final VoidCallback? onEmptyTap;

  /// Whole-word selection changed through long-press-drag (empty list = cleared).
  final void Function(List<int> words)? onSelectionChanged;

  /// Max distance (page units) for the gap-aware tap.
  final double hitMaxDistance;
  final bool selectionEnabled, panZoomEnabled, paperShadow;

  /// Band colour of the drag selection (0xRRGGBBAA), drawn in [QvpLayer.selection].
  final int selectionBand;
  final double minScale, maxScale;

  /// How far the magnifying glass may go: the ceiling the pinch is clamped to under
  /// [QvpZoomMode.magnify], [kMaxZoom] unless the host lowers it. A host that draws its own
  /// furniture beside the ink and scales it with the glass says here what that furniture can
  /// survive. A ceiling under the fitted page is the fitted page, since a pinch never shrinks
  /// the page inside the screen. 0 or below is the engine's own ceiling.
  final double maxZoom;

  /// Pre-rasterizes base ink into the global GPU texture cache so page turns are instant.
  static void prepare(QvpPage page, {double scale = 1.0, double dpr = 1.0, Color? inkColor}) {
    _InkCache.prepare(page, scale: scale, dpr: dpr, inkColor: inkColor);
  }

  @override
  State<QvpPageView> createState() => QvpPageViewState();
}

class QvpPageViewState extends State<QvpPageView> with SingleTickerProviderStateMixin {
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

  // scale gesture
  double _gScale = 1, _gOx = 0, _gOy = 0;
  /// Where the reader's zoom control stands, and where it stood when a pinch began.
  QvpZoom _zoom = const QvpZoom();
  QvpZoom _gZoom = const QvpZoom();
  /// The scale the page was last fitted at: the floor of a magnifying pinch.
  double _fitScale = 1;

  QvpViewController get controller => _ctl;
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
    widget.page.addListener(_onPageChanged);
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
    if (ink != null && rgba(ink) != widget.page.defaultInk) widget.page.setDefaultColor(ink);
  }

  @override
  void didUpdateWidget(QvpPageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) _ctl = widget.controller ?? (oldWidget.controller == null ? _ctl : QvpViewController());
    if (oldWidget.page != widget.page) {
      oldWidget.page.removeListener(_onPageChanged);
      _attachPage();
    }
    if (oldWidget.defaultInk != widget.defaultInk) _applyInk();
    if (oldWidget.layout != widget.layout) _ctl._fitRequested = true;
  }

  @override
  void dispose() {
    widget.page.removeListener(_onPageChanged);
    _ticker.dispose();
    _cache.dispose();
    _frame.dispose();
    if (widget.controller == null) _ctl.dispose();
    super.dispose();
  }

  bool _isRelayouting = false;

  void _onPageChanged() {
    if (_isRelayouting) return;
    // the app cleared the selection behind our back → drop our band
    if (_selHandle != 0 && !_selecting && !page.isDisposed && page.selection().isEmpty) {
      final h = _selHandle;
      _selHandle = 0;
      page.removeHighlight(h);
      return; // removeHighlight notifies again
    }
    // A dress or an undress can change how big the page is. Fit it again only when the
    // engine's dressed box changed. A new colour keeps the box, so it keeps the reader's zoom.
    if (!page.isDisposed && !identical(page.dressSpec, _fittedDress) && mounted) {
      _fittedDress = page.dressSpec;
      final box = _dressBox();
      if (!listEquals(box, _fittedBox)) {
        _fittedBox = box;
        _ctl._fitRequested = true;
        // A dress made while the tree builds waits for the frame to end.
        if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
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
    _isRelayouting = true;
    try {
      page.layout(_spec(size));
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
    // A dress or an undress refits in the engine, so read the layout again.
    final l = page.readLayout() ?? page.currentLayout!;
    _ctl._fitRequested = false;
    _fittedDress = page.dressSpec;
    _fittedBox = _dressBox();
    // The engine fits the content plus the dress overflow. A reflowed page is taller than the
    // screen because the reader asked for it: the engine shows its top.
    _ctl.scale = l.fitScale;
    _fitScale = l.fitScale;
    _ctl.offsetX = l.fitX;
    _ctl.offsetY = l.fitY;
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
    return page.hitTestView(v.dx, v.dy, QvpHitOptions(maxDistance: maxDistance ?? 0));
  }

  void _onTapUp(TapUpDetails d) {
    final h = _hitAt(d.localPosition, maxDistance: widget.hitMaxDistance);
    if (h != null && h.word >= 0) {
      widget.onWordTap?.call(h.word, h);
    } else if (h != null && h.decoration >= 0) {
      widget.onDecorationTap?.call(page.decorations[h.decoration]);
    } else {
      widget.onEmptyTap?.call();
    }
  }

  void _onScaleStart(ScaleStartDetails d) {
    _gScale = _ctl.scale;
    _gOx = _ctl.offsetX;
    _gOy = _ctl.offsetY;
    // where the control stood when the fingers went down: the engine measures them against this,
    // so a slow pinch walks the steps one at a time instead of running away through them
    _gZoom = _zoom;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (!widget.panZoomEnabled || _size == Size.zero) return;
    final f = d.localFocalPoint;
    if (_gZoom.mode == QvpZoomMode.magnify) {
      // The printed page under a magnifying glass: the rows never move. The floor is the
      // settled page, and a host ceiling set under it does not lower it: a pinch magnifies the
      // print, it does not shrink the page inside the screen. The engine applies the clamp.
      final floor = math.max(_fitScale, kMinZoom);
      final v = page.engine.viewZoomAbout(QvpView(scale: _gScale, offsetX: _gOx, offsetY: _gOy), f.dx, f.dy, d.scale, min: floor, max: widget.maxZoom);
      final h = page.dressClamp(v, _size.width, _size.height);
      _ctl.set(scale: h.scale, offsetX: h.offsetX, offsetY: h.offsetY);
      return;
    }
    // The engine owns the whole pinch: which step it lands on, when it commits, and what holds
    // the reader's place when the page reflows under the fingers.
    final c = page.zoomPinch(
      widget.layout.toSpec(_size.width, _size.height),
      _gZoom,
      QvpView(scale: _gScale, offsetX: _gOx, offsetY: _gOy),
      d.scale,
      f.dx,
      f.dy,
    );
    if (c.relaid) {
      _zoom = c.zoom;
      page.readLayout();
      _fittedBox = _dressBox(); // a new layout moves the overflow, not the dress
      widget.onZoomChanged?.call(c.zoom);
    }
    final h = page.dressClamp(c.view, _size.width, _size.height);
    _ctl.set(scale: h.scale, offsetX: h.offsetX, offsetY: h.offsetY);
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
    _ctl.set(scale: c.view.scale, offsetX: c.view.offsetX, offsetY: c.view.offsetY);
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
    setState(() => _zoom = page.zoomMode(widget.layout.toSpec(_size.width, _size.height), _zoom, mode));
    fit();
    widget.onZoomChanged?.call(_zoom);
  }

  void _onLongPressStart(LongPressStartDetails d) {
    if (!widget.selectionEnabled) return;
    final h = _hitAt(d.localPosition, maxDistance: widget.hitMaxDistance);
    if (h == null || h.word < 0) return;
    _selecting = true;
    _selAnchor = h.word;
    HapticFeedback.selectionClick();
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
      _selHandle = page.highlight(T.words(ws), QvpHighlightStyle(mode: 'band', band: widget.selectionBand, padX: 0.6, ms: 0, layer: QvpLayer.selection));
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
    return LayoutBuilder(builder: (context, c) {
      final size = Size(c.maxWidth.isFinite ? c.maxWidth : 400, c.maxHeight.isFinite ? c.maxHeight : 600);
      if (size != _size || _laidOut != widget.layout || page.currentLayout == null) {
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
            onLongPressStart: widget.selectionEnabled ? _onLongPressStart : null,
            onLongPressMoveUpdate: widget.selectionEnabled ? _onLongPressMove : null,
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
                ),
              ),
            ),
          ),
        ),
      );
    });
  }
}

class _PictureCacheEntry {
  final String key;
  final ui.Picture picture;
  _PictureCacheEntry(this.key, this.picture);

  void dispose() {
    try {
      picture.dispose();
    } on Object catch (_) {}
  }
}

class _LruCache {
  static const int maxEntries = 32;
  final LinkedHashMap<String, _PictureCacheEntry> _entries = LinkedHashMap();

  _PictureCacheEntry? get(String key) {
    final entry = _entries.remove(key);
    if (entry != null) {
      _entries[key] = entry;
      return entry;
    }
    return null;
  }

  void put(String key, ui.Picture pic) {
    final old = _entries.remove(key);
    if (old != null && old.picture != pic) {
      old.dispose();
    }
    _entries[key] = _PictureCacheEntry(key, pic);
    while (_entries.length > maxEntries) {
      final firstKey = _entries.keys.first;
      _entries.remove(firstKey)?.dispose();
    }
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
    required this.key,
  });

  final List<QvpDraw> draws;
  final List<QvpPlacement> places;
  final Map<int, int> ofPath;
  final String key;
}

/// Per-page render cache: base ink picture and layout draws.
class _InkCache {
  static final _LruCache _globalInkCache = _LruCache();
  static final _LruCache _globalOrnamentCache = _LruCache();

  static _PictureCacheEntry? getGlobalInk(String key) => _globalInkCache.get(key);
  static void keepGlobalInk(String key, ui.Picture pic) => _globalInkCache.put(key, pic);

  static _PictureCacheEntry? getGlobalOrnament(String key) => _globalOrnamentCache.get(key);
  static void keepGlobalOrnament(String key, ui.Picture pic) => _globalOrnamentCache.put(key, pic);

  static void prepare(QvpPage page, {double scale = 1.0, double dpr = 1.0, Color? inkColor}) {
    if (page.isDisposed) return;
    final l = page.currentLayout;
    if (l == null) return;
    final ink = inkColor != null ? (inkColor.toARGB32() & 0xFFFFFF) : page.defaultInk;
    final key = '${page.page}|$ink|${l.scale}|0.0|${math.max(l.contentH, 1.0).toInt()}|1';
    if (getGlobalInk(key) != null) return;

    final rec = ui.PictureRecorder();
    final c = ui.Canvas(rec);
    final paint = ui.Paint()
      ..color = QvpColor.toColor(ink)
      ..isAntiAlias = true;
    final draws = page.layoutDrawList();
    final places = page.layoutPlacements();
    var cur = -1, open = false;
    for (final d in draws) {
      if (d.placement != cur) {
        if (open) c.restore();
        c.save();
        _QvpPainter._placeInLayout(c, l, d.placement < places.length ? places[d.placement] : QvpPlacement.identity);
        open = true;
        cur = d.placement;
      }
      c.drawPath(page.path(d.path), paint);
    }
    if (open) c.restore();
    final pic = rec.endRecording();
    keepGlobalInk(key, pic);
  }

  QvpPage? page;
  ui.Picture? picture;
  String key = '';

  /// The ornament layer: picture in layout px.
  ui.Picture? ornaments;
  String ornamentKey = '';

  _DrawList? _drawList;

  _DrawList getDrawList(QvpPage page, QvpLayout? l, double top, double bandH, double contentH) {
    final key = '${page.page}|$top|$bandH|$contentH|${l?.scale}';
    if (_drawList != null && _drawList!.key == key) return _drawList!;
    final draws = top == 0.0 && bandH >= contentH
        ? page.layoutDrawList()
        : page.layoutDrawList(bandTop: top, bandBottom: top + bandH);
    final places = page.layoutPlacements();
    final ofPath = <int, int>{
      for (var i = 0; i < draws.length; i++) draws[i].path: draws[i].placement,
    };
    return _drawList = _DrawList(draws: draws, places: places, ofPath: ofPath, key: key);
  }

  QvpDressInfo? _dress;
  int? _dressRevision;

  QvpDressInfo? getDress(QvpPage page) {
    if (_dress != null && _dressRevision == page.revision) return _dress;
    _dressRevision = page.revision;
    return _dress = page.dressInfo();
  }

  List<QvpBox>? _bands;
  int? _bandsRevision;

  List<QvpBox> getBands(QvpPage page) {
    if (_bands != null && _bandsRevision == page.revision) return _bands!;
    _bandsRevision = page.revision;
    return _bands = page.highlightBoxesView();
  }

  /// Stats of the last frame (for HUDs).
  int basePaths = 0, overlayPaths = 0, bands = 0;
  double baseMs = 0, overlayMs = 0;

  void attach(QvpPage p) {
    if (page == p) return;
    page = p;
    key = '';
    _dropPicture();
    dropOrnaments();
    _drawList = null;
    _dress = null;
    _bands = null;
  }

  void _dropPicture() {
    if (picture != null) {
      if (!_globalInkCache.containsPicture(picture!)) {
        try {
          picture!.dispose();
        } on Object catch (_) {}
      }
      picture = null;
    }
  }

  void dropOrnaments() {
    if (ornaments != null) {
      if (!_globalOrnamentCache.containsPicture(ornaments!)) {
        try {
          ornaments!.dispose();
        } on Object catch (_) {}
      }
      ornaments = null;
      ornamentKey = '';
    }
  }

  void dispose() {
    _dropPicture();
    dropOrnaments();
    page = null;
    _drawList = null;
    _dress = null;
    _bands = null;
  }
}

/// Draws a laid-out passage on [canvas], in the layout's own px from the canvas origin: every
/// path of [layout], from its page in [pages] (by page number), in [ink]. Translate the canvas
/// to where the passage goes first. [paths] optionally caches or provides pre-built paths.
/// Without it, paths are lazily resolved via [page.path] without building whole-page lists.
void paintPassage(ui.Canvas canvas, QvpPassageLayout layout, Map<int, QvpPage> pages, Color ink, {Map<int, List<ui.Path>>? paths}) {
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
    final path = (paths != null && paths[d.page] != null) ? paths[d.page]![d.path] : page.path(d.path);
    if (d.placement != cur) {
      if (open) canvas.restore();
      canvas.save();
      final q = d.placement < places.length ? places[d.placement] : QvpPlacement.identity;
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
  }) : super(repaint: Listenable.merge([page, view, frame]));

  final QvpPage page;
  final QvpViewController view;
  final _InkCache cache;
  final double dpr;
  final Color? paper;
  final bool paperShadow;

  final ui.Paint _boxPaint = ui.Paint()..isAntiAlias = true;
  final ui.Path _boxPath = ui.Path();
  final ui.Paint _styledPaint = ui.Paint()..isAntiAlias = true..blendMode = ui.BlendMode.src;
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
    c.translate(view.offsetX + view.scale * ((l?.offsetX ?? 0) + q.dx * ls), view.offsetY + view.scale * ((l?.offsetY ?? 0) + q.dy * ls));
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
    final key = '${page.page}|${info.revision}|${l?.scale}';
    final kept = _InkCache.getGlobalOrnament(key);
    if (kept != null) {
      cache.ornaments = kept.picture;
      cache.ornamentKey = key;
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
          _placeInLayout(c, l, pi != null && pi < places.length ? places[pi] : QvpPlacement.identity);
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
      final pic = rec.endRecording();
      cache.ornaments = pic;
      cache.ornamentKey = key;
      _InkCache.keepGlobalOrnament(key, pic);
    }
    if (cache.ornaments != null) {
      canvas.save();
      canvas.translate(view.offsetX, view.offsetY);
      canvas.scale(view.scale);
      canvas.drawPicture(cache.ornaments!);
      canvas.restore();
    }
  }

  void _drawBoxes(ui.Canvas c, List<QvpBox> boxes) {
    if (boxes.isEmpty) return;
    c.save();
    c.translate(view.offsetX, view.offsetY);
    c.scale(view.scale);
    var id = -1, col = 0, hasPath = false;

    for (var i = 0; i < boxes.length; i++) {
      final b = boxes[i];
      if (!hasPath || b.id != id || b.color != col) {
        if (hasPath) {
          _boxPaint.color = QvpColor.toColor(col);
          c.drawPath(_boxPath, _boxPaint);
          _boxPath.reset();
        }
        hasPath = true;
        id = b.id;
        col = b.color;
      }
      final r = Rect.fromLTRB(b.x0, b.y0, b.x1, b.y1);
      if (b.radius > 0) {
        _boxPath.addRRect(RRect.fromRectAndRadius(r, Radius.circular(b.radius)));
      } else {
        _boxPath.addRect(r);
      }
    }
    if (hasPath) {
      _boxPaint.color = QvpColor.toColor(col);
      c.drawPath(_boxPath, _boxPaint);
      _boxPath.reset();
    }
    c.restore();
  }

  @override
  void paint(ui.Canvas canvas, Size size) {
    if (page.isDisposed) return;
    final l = page.currentLayout;
    final styled = page.styledPaths();
    final ink = page.defaultInk;
    // read once per frame: the paper and the ornament layer both use it
    final dress = cache.getDress(page);

    // paper, grown by the dress overflow so a border sits on it
    final paperColor = paper;
    if (paperColor != null) {
      final o = dress?.overflow ?? const [0.0, 0.0, 0.0, 0.0];
      final rect = Rect.fromLTRB(view.offsetX - o[0] * view.scale, view.offsetY - o[1] * view.scale, view.offsetX + ((l?.contentW ?? page.width) + o[2]) * view.scale,
          view.offsetY + ((l?.contentH ?? page.height) + o[3]) * view.scale);
      if (paperShadow) {
        _boxPath.reset();
        _boxPath.addRect(rect);
        canvas.drawShadow(_boxPath, const Color(0x66000000), 6, false);
        _boxPath.reset();
      }
      _boxPaint.color = paperColor;
      canvas.drawRect(rect, _boxPaint);
    }

    // calculate band for base ink: standard pages fit entirely in one GPU texture (top = 0);
    // tall reflowed pages (>4096px) use discrete stepped bands matching native QvpPageView.kt
    final contentH = (l?.contentH ?? page.height);
    final double top, bandH;
    if (contentH <= 4096.0 || size.height <= 0 || view.scale <= 0) {
      top = 0.0;
      bandH = math.max(contentH, 1.0);
    } else {
      final screenH = (size.height / view.scale).clamp(1.0, 4096.0);
      final tall = math.min(screenH * 2.0, 4096.0);
      final step = math.max((tall - screenH) / 2.0, 1.0);
      top = (((-view.offsetY / view.scale) - step) / step).floorToDouble() * step;
      bandH = tall;
    }

    // base ink cache: recorded in layout px with _placeInLayout so offset/scale don't invalidate it
    int styledKey = 1;
    for (var i = 0; i < styled.length; i++) {
      styledKey = 31 * styledKey + styled[i].path;
    }
    final q = cache.getDrawList(page, l, top, bandH, contentH);
    final key = '${page.page}|$ink|${l?.scale}|$top|${bandH.toInt()}|$styledKey';
    final kept = _InkCache.getGlobalInk(key);
    if (kept != null) {
      cache.picture = kept.picture;
      cache.key = key;
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

      final omitted = styled.isEmpty ? null : {for (var i = 0; i < styled.length; i++) styled[i].path};

      var cur = -1, n = 0, open = false;
      for (final d in q.draws) {
        if (omitted != null && omitted.contains(d.path)) continue;
        if (d.placement != cur) {
          if (open) c.restore();
          c.save();
          _placeInLayout(c, l, d.placement < q.places.length ? q.places[d.placement] : QvpPlacement.identity);
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
      cache.key = key;
      cache.basePaths = n;
      cache.baseMs = sw.elapsedMicroseconds / 1000;
      _InkCache.keepGlobalInk(key, pic);
    }

    final sw = Stopwatch()..start();
    // 0. the ornament layer of a dressed page, behind everything else
    _drawOrnaments(canvas, l, dress);

    // 1. highlight bands (behind the ink)
    final bands = cache.getBands(page);
    _drawBoxes(canvas, bands);

    // 2. base ink: direct vector picture playback
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
      var cur = -1, open = false;
      for (var i = 0; i < styled.length; i++) {
        final s = styled[i];
        if ((s.color & 0xff) == 0) continue;
        final pi = q.ofPath[s.path] ?? page.pathLine(s.path);
        if (pi < 0) continue;
        if (pi != cur) {
          if (open) canvas.restore();
          canvas.save();
          _placeAt(canvas, l, pi < q.places.length ? q.places[pi] : QvpPlacement.identity);
          open = true;
          cur = pi;
        }
        _styledPaint.color = QvpColor.toColor(s.color);
        canvas.drawPath(page.path(s.path), _styledPaint);
      }
      if (open) canvas.restore();
    }

    // 4. mask boxes (block / blur) on top
    _drawBoxes(canvas, page.maskBoxesView());
    cache.overlayMs = sw.elapsedMicroseconds / 1000;
    cache.overlayPaths = styled.length;
    cache.bands = bands.length;
  }

  @override
  bool shouldRepaint(_QvpPainter old) =>
      old.page != page ||
      old.view != view ||
      old.dpr != dpr ||
      old.paper != paper ||
      old.paperShadow != paperShadow ||
      old.cache != cache;
}

/// Render statistics of a [QvpPageView] (base / overlay timings of the last frame).
extension QvpPageViewStats on QvpPageViewState {
  ({int basePaths, double baseMs, int overlayPaths, double overlayMs, int bands}) get stats =>
      (basePaths: _cache.basePaths, baseMs: _cache.baseMs, overlayPaths: _cache.overlayPaths, overlayMs: _cache.overlayMs, bands: _cache.bands);
}
