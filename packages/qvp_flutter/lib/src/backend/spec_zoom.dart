// What both backends hand back from `zoomSpec`. Not exported from the package.
import '../types.dart';

/// [spec] with the reflow zoom the engine wrote back. The control owns the reflow zoom alone,
/// and the engine hands every other field back as the host set it. So the host's own spec
/// carries every knob, and only the zoom comes from the engine. On the printed page the zoom is
/// 0 and the knobs stay: dropping them there would leave the pinch that leaves the printed page
/// to lay it out with the engine's defaults.
QvpLayoutSpec withReflowZoom(QvpLayoutSpec spec, double zoom) {
  final given = spec.reflow;
  final reflow = given != null
      ? given.copyWith(zoom: zoom)
      : zoom > 0
      ? QvpReflowSpec(zoom: zoom)
      : null;
  return QvpLayoutSpec(
    viewportW: spec.viewportW,
    viewportH: spec.viewportH,
    padTop: spec.padTop,
    padBottom: spec.padBottom,
    padLeft: spec.padLeft,
    padRight: spec.padRight,
    lineSpacing: spec.lineSpacing,
    fillHeight: spec.fillHeight,
    gridLines: spec.gridLines,
    cropLeft: spec.cropLeft,
    cropRight: spec.cropRight,
    maxAspectSlack: spec.maxAspectSlack,
    reflow: reflow,
    bannerZoom: spec.bannerZoom,
    surahFrames: spec.surahFrames,
  );
}
