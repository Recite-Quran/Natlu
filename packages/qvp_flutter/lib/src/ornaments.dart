import 'engine.dart';

/// The ornaments of other mushafs and fonts, from `ornaments.qvo`.
class QvpOrnaments {
  QvpOrnaments.fromHandle(this.engine, this._backend, this._handle, this.list)
      : count = list.length;

  final QvpEngine engine;
  final QvpBackend _backend;
  OrnamentsHandle? _handle;

  /// How many ornaments the set holds.
  final int count;

  /// Every ornament of the set, in order.
  final List<QvpOrnament> list;

  OrnamentsHandle get handle {
    assert(_handle != null, 'QvpOrnaments used after dispose()');
    return _handle!;
  }

  bool get isDisposed => _handle == null;

  void free() {
    if (_handle != null) {
      _backend.ornamentsFree(_handle!);
      _handle = null;
    }
  }

  void dispose() => free();

  /// The ornament of [kind] in [style], or null.
  QvpOrnament? find(QvpOrnamentKind kind, String style) {
    final i = _backend.ornamentFind(handle, kind.index, style);
    return i < 0 || i >= list.length ? null : list[i];
  }

  /// The ornaments of one kind.
  List<QvpOrnament> ofKind(QvpOrnamentKind kind) =>
      [for (final o in list) if (o.kind == kind) o];

  /// Every style in the set, with the ornament it has of each kind.
  List<QvpOrnamentStyle> styles() {
    final order = <String>[];
    final byStyle = <String, Map<QvpOrnamentKind, QvpOrnament>>{};
    final first = <String, QvpOrnament>{};
    for (final o in list) {
      if (!byStyle.containsKey(o.style)) {
        order.add(o.style);
        byStyle[o.style] = {};
        first[o.style] = o;
      }
      byStyle[o.style]![o.kind] = o;
    }
    return [
      for (final s in order)
        QvpOrnamentStyle(
          style: s,
          riwayah: first[s]!.riwayah,
          lineage: first[s]!.lineage,
          ayahMark: byStyle[s]![QvpOrnamentKind.ayahMark],
          surahHeader: byStyle[s]![QvpOrnamentKind.surahHeader],
          pageFrame: byStyle[s]![QvpOrnamentKind.pageFrame],
        ),
    ];
  }
}
