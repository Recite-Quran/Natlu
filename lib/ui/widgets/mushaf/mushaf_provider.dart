import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qvp_flutter/qvp_flutter.dart';
import 'package:recite_quran/recite_quran.dart';

import '../../../state/app_state.dart';
import 'web/mushaf_web_storage.dart'
    if (dart.library.js_interop) 'web/mushaf_web_storage_web.dart' as web_storage;

/// Typed word reference within a Mushaf page for tracking and playback.
class MushafWordRef {
  final int surah;
  final int ayah;
  final int wordIndex1;
  final int wordIndex0;
  final String text;

  const MushafWordRef({
    required this.surah,
    required this.ayah,
    required this.wordIndex1,
    required this.wordIndex0,
    required this.text,
  });
}

/// High-performance data provider for the Mushaf layout backed by qvp_flutter.
/// Manages QvpEngine, atlas.qva, archive extraction on launch, and a bounded LRU cache of decoded QvpPage objects.
class MushafProvider {
  MushafProvider._();
  static final MushafProvider instance = MushafProvider._();

  QvpEngine? _engine;
  QvpAtlas? _atlas;
  bool _isReady = false;
  bool _isLoading = false;
  Completer<void>? _loadingCompleter;
  String? _extractedPagesPath;

  bool isSyncingSurah = false;
  bool get isReady => _isReady;
  QvpEngine get engine => _engine!;
  QvpAtlas get atlas => _atlas!;

  Size? lastViewportSize;
  final LinkedHashMap<int, QvpPage> _pageCache = LinkedHashMap<int, QvpPage>();
  final Map<int, Uint8List> _webPageBytes = {};
  Uint8List? _webAtlasBytes;
  static const int _maxCachedPages = 120;
  final Map<int, Future<QvpPage?>> _pendingLoads = {};
  Timer? _preloadDebounce;

  void preloadAdjacentPages(int pageNumber, [Size? viewportSize]) {
    final size = viewportSize ?? lastViewportSize;
    if (size == null || size.width <= 0 || size.height <= 0) return;
    lastViewportSize = size;
    _preloadDebounce?.cancel();
    _preloadDebounce = Timer(const Duration(milliseconds: 20), () {
      unawaited(_doPreloadAdjacentPages(pageNumber, size));
    });
  }

  Future<void> _doPreloadAdjacentPages(int pageNumber, Size size) async {
    final dpr = ui.PlatformDispatcher.instance.views.isNotEmpty
        ? ui.PlatformDispatcher.instance.views.first.devicePixelRatio
        : 1.0;
    final inkColor = AppState.instance.colors.text;
    const layout = QvpViewLayout(
      padTop: 0,
      padBottom: 0,
      padSide: 4,
      lineSpacing: 1.0,
      fillHeight: true,
      surahFrames: false,
    );

    // Eagerly preload adjacent sliding window concurrently
    final targets = <int>[
      pageNumber + 1,
      pageNumber + 2,
      pageNumber - 1,
      pageNumber + 3,
      pageNumber - 2,
    ].where((t) => t >= 1 && t <= 604).toList();

    await Future.wait(
      targets.map((target) => _preloadSinglePage(target, size, dpr, inkColor, layout)),
    );
  }

  Future<void> _preloadSinglePage(
    int target,
    Size size,
    double dpr,
    Color inkColor,
    QvpViewLayout layout,
  ) async {
    final cached = getCachedPage(target);
    QvpPage? p = cached;
    if (p == null || p.isDisposed) {
      p = await getPage(target);
    }
    if (p != null && !p.isDisposed) {
      p.setDefaultColor(inkColor);
      if (p.currentLayout == null) {
        p.layout(layout.toSpec(size.width, size.height));
      }
      if (p.currentLayout != null) {
        QvpPageView.prepare(p, scale: p.currentLayout!.scale, dpr: dpr, inkColor: inkColor);
      }
    }
  }

  void preloadData({bool force = false}) {
    if ((_isReady && !force) || _isLoading) return;
    unawaited(loadData(force: force));
  }

  Future<void> _ensureExtracted({bool force = false}) async {
    if (kIsWeb) {
      if (_webAtlasBytes != null && !force) return;
      try {
        final initialPage = AppState.instance.currentMushafPage.value.clamp(1, 604);
        final futures = <Future>[];
        if (_webAtlasBytes == null || force) {
          futures.add(() async {
            _webAtlasBytes ??= await web_storage.getPageFromIndexedDb('atlas');
            if (_webAtlasBytes == null) {
              _webAtlasBytes = await web_storage.fetchPageFromCdn('atlas.qva');
              if (_webAtlasBytes != null) {
                unawaited(web_storage.savePageToIndexedDb('atlas', _webAtlasBytes!));
              }
            }
          }());
        }
        if (!_webPageBytes.containsKey(initialPage) || force) {
          futures.add(() async {
            var p = await web_storage.getPageFromIndexedDb(initialPage.toString());
            if (p == null) {
              p = await web_storage.fetchPageFromCdn('${_pad(initialPage)}.qvp');
              if (p != null) {
                unawaited(web_storage.savePageToIndexedDb(initialPage.toString(), p));
              }
            }
            if (p != null) {
              _webPageBytes[initialPage] = p;
            }
          }());
        }
        await Future.wait(futures);
      } catch (e) {
        debugPrint('Error loading Mushaf atlas on Web: $e');
      }
      return;
    }
    if (_extractedPagesPath != null && !force) return;
    try {
      final appDir = await getApplicationSupportDirectory();
      final dir = Directory('${appDir.path}/mushaf_pages');
      final marker = File('${dir.path}/.extracted');
      final atlasFile = File('${dir.path}/atlas.qva');
      if (!force &&
          dir.existsSync() &&
          marker.existsSync() &&
          atlasFile.existsSync() &&
          atlasFile.lengthSync() > 0) {
        _extractedPagesPath = dir.path;
        return;
      }

      // Check if compressed archive exists in assets
      final ByteData archiveData;
      try {
        archiveData = await rootBundle.load('assets/pages.tar.xz');
      } catch (_) {
        // Archive not in assets; fallback to assets/pages directory if available
        return;
      }

      final bytes = archiveData.buffer.asUint8List();
      final targetPath = dir.path;
      await compute(_extractTarXzIsolate, (bytes, targetPath));
      _extractedPagesPath = targetPath;
    } catch (e) {
      debugPrint('Error extracting pages.tar.xz: $e');
    }
  }

  static void _extractTarXzIsolate((Uint8List bytes, String targetPath) args) {
    try {
      final tarBytes = XZDecoder().decodeBytes(args.$1);
      final archive = TarDecoder().decodeBytes(tarBytes);
      final outDir = Directory(args.$2);
      if (!outDir.existsSync()) outDir.createSync(recursive: true);
      for (final file in archive) {
        if (file.isFile) {
          final fileName = file.name.replaceAll(r'\', '/').split('/').last;
          if (fileName.isEmpty) continue;
          final out = File('${outDir.path}/$fileName');
          out.writeAsBytesSync(file.content as List<int>);
        }
      }
      File('${outDir.path}/.extracted').writeAsStringSync('ok');
    } catch (e) {
      debugPrint('Error inside _extractTarXzIsolate: $e');
    }
  }

  Future<void> loadData({bool force = false}) async {
    if (_isReady && !force) return;
    if (_isLoading) {
      await _loadingCompleter?.future;
      return;
    }
    _isLoading = true;
    _loadingCompleter = Completer<void>();

    try {
      if (kIsWeb) {
        await QvpEngine.initWeb();
      }
      _engine ??= QvpEngine.open();
      await _ensureExtracted(force: force);

      if (_atlas == null) {
        final Uint8List atlasBytes;
        if (kIsWeb) {
          _webAtlasBytes ??= await web_storage.getPageFromIndexedDb('atlas');
          if (_webAtlasBytes != null) {
            atlasBytes = _webAtlasBytes!;
          } else {
            throw StateError('Mushaf atlas.qva not found in Web memory or storage');
          }
        } else {
          final localAtlas = _extractedPagesPath != null
              ? File('$_extractedPagesPath/atlas.qva')
              : null;
          if (localAtlas != null && localAtlas.existsSync()) {
            atlasBytes = await localAtlas.readAsBytes();
          } else {
            throw StateError('Mushaf atlas.qva not found at ${localAtlas?.path}');
          }
        }
        _atlas = _engine!.loadAtlas(atlasBytes);
      }
      _isReady = true;
      if (kIsWeb) {
        final initialPage = AppState.instance.currentMushafPage.value.clamp(1, 604);
        unawaited(getPage(initialPage));
      }
    } catch (e, st) {
      debugPrint('Error loading MushafProvider QVP data: $e\n$st');
    } finally {
      _isLoading = false;
      _loadingCompleter?.complete();
    }
  }

  String _pad(int n) => n.toString().padLeft(3, '0');

  Future<QvpPage?> getPage(int pageNumber) {
    final cached = getCachedPage(pageNumber);
    if (cached != null) return Future.value(cached);

    final pending = _pendingLoads[pageNumber];
    if (pending != null) return pending;

    final future = _loadPageInternal(pageNumber);
    _pendingLoads[pageNumber] = future;
    return future.whenComplete(() => _pendingLoads.remove(pageNumber));
  }

  Future<QvpPage?> _loadPageInternal(int pageNumber) async {
    if (!_isReady) {
      await loadData();
    }
    if (_engine == null) return null;

    final cached = _pageCache.remove(pageNumber);
    if (cached != null) {
      if (!cached.isDisposed) {
        _pageCache[pageNumber] = cached;
        return cached;
      }
    }

    try {
      final Uint8List pageBytes;
      if (kIsWeb) {
        var p = _webPageBytes[pageNumber];
        if (p == null) {
          p = await web_storage.getPageFromIndexedDb(pageNumber.toString());
          if (p != null) {
            _webPageBytes[pageNumber] = p;
          }
        }
        if (p == null) {
          p = await web_storage.fetchPageFromCdn('${_pad(pageNumber)}.qvp');
          if (p != null) {
            _webPageBytes[pageNumber] = p;
            unawaited(web_storage.savePageToIndexedDb(pageNumber.toString(), p));
          }
        }
        if (p != null) {
          pageBytes = p;
        } else {
          throw StateError('Mushaf page $pageNumber not found in Web memory or storage');
        }
      } else {
        var localPage = _extractedPagesPath != null
            ? File('$_extractedPagesPath/${_pad(pageNumber)}.qvp')
            : null;
        if (localPage == null || !localPage.existsSync() || localPage.lengthSync() == 0) {
          await _ensureExtracted(force: true);
          localPage = _extractedPagesPath != null
              ? File('$_extractedPagesPath/${_pad(pageNumber)}.qvp')
              : null;
        }
        if (localPage != null && localPage.existsSync() && localPage.lengthSync() > 0) {
          pageBytes = await localPage.readAsBytes();
        } else {
          throw StateError('Mushaf page $pageNumber not found at ${localPage?.path}');
        }
      }
      final page = _engine!.loadPage(pageBytes);
      page.hide(Sel.kind(QvpKind.ayahMarkOrnament));

      if (_pageCache.length >= _maxCachedPages) {
        final currentPage = AppState.instance.currentMushafPage.value;
        int? evictKey;
        for (final k in _pageCache.keys) {
          if (currentPage > 0 && (k - currentPage).abs() <= 10) continue;
          evictKey = k;
          break;
        }
        if (evictKey != null) {
          final oldestPage = _pageCache.remove(evictKey);
          oldestPage?.dispose();
        }
      }
      _pageCache[pageNumber] = page;
      return page;
    } catch (e) {
      debugPrint('Error loading QVP page $pageNumber: $e');
      return null;
    }
  }

  QvpPage? getCachedPage(int pageNumber) {
    final page = _pageCache[pageNumber];
    if (page != null && page.isDisposed) {
      _pageCache.remove(pageNumber);
      return null;
    }
    return page;
  }

  (int surah, int ayah)? getFirstAyahOnPage(int pageNumber) {
    if (!_isReady || _atlas == null) return null;
    return _atlas!.pageRange(pageNumber)?.first;
  }

  int? getDominantSurahOnPage(int pageNumber) {
    if (!_isReady || _atlas == null) return null;
    return _atlas!.pageRange(pageNumber)?.first.$1;
  }

  bool isAyahOnPage({
    required int pageNumber,
    required int surah,
    required int ayah,
  }) {
    if (!_isReady || _atlas == null) return false;
    return _atlas!.pageOf(surah, ayah) == pageNumber;
  }

  int? getPageForAyah(int surah, int ayah) {
    if (!_isReady || _atlas == null) return null;
    return _atlas!.pageOf(surah, ayah);
  }

  MushafWordRef? getLastWordOnPage(int pageNumber) {
    final page = _pageCache[pageNumber];
    if (page != null && page.words.isNotEmpty) {
      final w = page.words.last;
      return MushafWordRef(
        surah: w.surah,
        ayah: w.ayah,
        wordIndex1: w.word,
        wordIndex0: w.word - 1,
        text: w.text,
      );
    }
    final r = _atlas?.pageRange(pageNumber);
    if (r != null) {
      return MushafWordRef(
        surah: r.last.$1,
        ayah: r.last.$2,
        wordIndex1: 1,
        wordIndex0: 0,
        text: '',
      );
    }
    return null;
  }

  Future<void> ensureActiveAyahOnCurrentPage({
    required HighlightingController controller,
    int? pageNumber,
  }) async {
    if (!_isReady) {
      await loadData();
    }
    final page = pageNumber ?? AppState.instance.currentMushafPage.value;
    final int? activeAyah = controller.activeAyah.value;
    final int targetSurah = controller.targetSurah != 0
        ? controller.targetSurah
        : AppState.instance.lastSurah;

    final bool isOnCurrentPage = activeAyah != null &&
        isAyahOnPage(pageNumber: page, surah: targetSurah, ayah: activeAyah);

    if (!isOnCurrentPage) {
      final first = getFirstAyahOnPage(page);
      if (first != null) {
        isSyncingSurah = true;
        try {
          if (controller.targetSurah != first.$1) {
            await controller.setTargetSurah(
              first.$1,
              preserveOtherSurahStates: true,
              clearTargetSurah: false,
            );
          }
          if (controller.activeAyah.value == first.$2) {
            controller.activeAyah.value = null;
          }
          controller.setManualAyah(first.$1, first.$2);
          controller.globalRevision.value++;
          AppState.instance.saveLastPosition(first.$1, first.$2);
        } finally {
          isSyncingSurah = false;
        }
      }
    }
  }
}

/// Backward compatibility alias
typedef MushafRepository = MushafProvider;
