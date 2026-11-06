import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qvp_flutter/qvp_flutter.dart';
import 'package:recite_quran/recite_quran.dart';

import '../../../state/app_state.dart';
import 'web/mushaf_web_storage.dart'
    if (dart.library.js_interop) 'web/mushaf_web_storage_web.dart'
    as web_storage;

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

/// High-performance data provider for the Mushaf layout backed by pristine qvp_flutter.
/// On Web, manages on-demand CDN streaming, IndexedDB persistence, and pre-rasterization.
/// On Native, manages isolate archive extraction and local filesystem page access.
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
  static const int _maxCachedPages = 16;
  final Map<int, Future<QvpPage?>> _pendingLoads = {};
  Timer? _preloadDebounce;
  int? _preloadingTargetPage;

  void preloadAdjacentPages(int pageNumber, [Size? viewportSize]) {
    final size = viewportSize ?? lastViewportSize;
    if (size != null && size.width > 0 && size.height > 0) {
      lastViewportSize = size;
    }

    _preloadingTargetPage = pageNumber;
    _preloadDebounce?.cancel();
    _preloadDebounce = Timer(const Duration(milliseconds: 200), () {
      if (_preloadingTargetPage != pageNumber) return;
      final targetSize = size ?? lastViewportSize;
      if (targetSize == null || targetSize.width <= 0 || targetSize.height <= 0) return;

      final neighbors = [pageNumber - 1, pageNumber + 1];
      final currentInkColor = AppState.instance.colors.text;

      for (final p in neighbors) {
        if (p < 1 || p > 604) continue;
        final cached = getCachedPage(p);
        if (cached != null && !cached.isDisposed) {
          if (cached.currentLayout == null ||
              (cached.currentLayout!.contentW - targetSize.width).abs() > 1) {
            cached.layout(const QvpViewLayout(
              padTop: 0,
              padBottom: 0,
              padSide: 4,
              lineSpacing: 1.0,
              fillHeight: true,
              surahFrames: false,
            ).toSpec(targetSize.width, targetSize.height));
          }
          QvpPageView.prepare(
            cached,
            inkColor: currentInkColor,
            surahFrames: false,
          );
          continue;
        }

        unawaited(() async {
          if (_preloadingTargetPage != pageNumber) return;
          final page = await getPage(p);
          if (page != null &&
              !page.isDisposed &&
              _preloadingTargetPage == pageNumber) {
            if (page.currentLayout == null ||
                (page.currentLayout!.contentW - targetSize.width).abs() > 1) {
              page.layout(const QvpViewLayout(
                padTop: 0,
                padBottom: 0,
                padSide: 4,
                lineSpacing: 1.0,
                fillHeight: true,
                surahFrames: false,
              ).toSpec(targetSize.width, targetSize.height));
            }
            QvpPageView.prepare(
              page,
              inkColor: currentInkColor,
              surahFrames: false,
            );
          }
        }());
      }
    });
  }

  void preloadData({bool force = false}) {
    if ((_isReady && !force) || _isLoading) return;
    unawaited(loadData(force: force));
  }

  /// Pages are fetched and cached strictly on-demand as the user navigates,
  /// matching the pure on-demand architecture of quran-engine.
  void startBackgroundMushafCaching() {}

  Future<void> _ensureExtracted({bool force = false}) async {
    if (kIsWeb || (_extractedPagesPath != null && !force)) return;
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
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
          try {
            const MethodChannel('com.recitequran.app/storage')
                .invokeMethod('excludeFromBackup', {'path': dir.path});
          } catch (_) {}
        }
        return;
      }

      final ByteData archiveData;
      try {
        archiveData = await rootBundle.load('assets/pages.tar.xz');
      } catch (_) {
        return;
      }

      final bytes = archiveData.buffer.asUint8List();
      final targetPath = dir.path;
      await compute(_extractTarXzIsolate, (bytes, targetPath));
      _extractedPagesPath = targetPath;
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
        try {
          const MethodChannel('com.recitequran.app/storage')
              .invokeMethod('excludeFromBackup', {'path': targetPath});
        } catch (_) {}
      }
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
        _engine ??= QvpEngine.open();

        if (_atlas == null || force) {
          var atlasBytes = await web_storage.getPageFromIndexedDb('atlas.qva');
          if (atlasBytes == null || atlasBytes.isEmpty) {
            atlasBytes = await web_storage.fetchPageFromCdn('atlas.qva');
            if (atlasBytes != null && atlasBytes.isNotEmpty) {
              unawaited(
                  web_storage.savePageToIndexedDb('atlas.qva', atlasBytes));
            }
          }
          if (atlasBytes != null && atlasBytes.isNotEmpty) {
            _atlas = _engine!.loadAtlas(atlasBytes);
          } else {
            throw StateError(
                'Mushaf atlas.qva could not be loaded from CDN or Cache');
          }
        }
      } else {
        _engine ??= QvpEngine.open();
        await _ensureExtracted(force: force);
        if (_atlas == null || force) {
          final localAtlas = _extractedPagesPath != null
              ? File('$_extractedPagesPath/atlas.qva')
              : null;
          if (localAtlas != null && localAtlas.existsSync()) {
            final atlasBytes = await localAtlas.readAsBytes();
            _atlas = _engine!.loadAtlas(atlasBytes);
          } else {
            throw StateError(
                'Mushaf atlas.qva not found at ${localAtlas?.path}');
          }
        }
      }
      _isReady = true;

      if (kIsWeb) {
        final initialPage =
            AppState.instance.currentMushafPage.value.clamp(1, 604);
        unawaited(getPage(initialPage));
        startBackgroundMushafCaching();
      }
    } catch (e, st) {
      debugPrint('Error loading MushafProvider QVP data: $e\n$st');
    } finally {
      _isLoading = false;
      _loadingCompleter?.complete();
    }
  }

  String _pad(int n) => n.toString().padLeft(3, '0');

  Future<QvpPage?> getPage(int pageNumber) async {
    if (!_isReady) {
      await loadData();
    }
    if (_engine == null) return null;

    final cached = getCachedPage(pageNumber);
    if (cached != null) return cached;

    final pending = _pendingLoads[pageNumber];
    if (pending != null) return pending;

    final future = _loadPageInternal(pageNumber);
    _pendingLoads[pageNumber] = future;
    return future.whenComplete(() => _pendingLoads.remove(pageNumber));
  }

  Future<QvpPage?> _loadPageInternal(int pageNumber) async {
    final cached = _pageCache.remove(pageNumber);
    if (cached != null && !cached.isDisposed) {
      _pageCache[pageNumber] = cached;
      return cached;
    }

    try {
      Uint8List? pageBytes;
      if (kIsWeb) {
        final key = '${_pad(pageNumber)}.qvp';
        pageBytes = await web_storage.getPageFromIndexedDb(key);
        if (pageBytes == null || pageBytes.isEmpty) {
          // Fallback check unpadded key
          pageBytes = await web_storage.getPageFromIndexedDb('$pageNumber.qvp');
        }
        if (pageBytes == null || pageBytes.isEmpty) {
          pageBytes = await web_storage.fetchPageFromCdn(key);
          if (pageBytes != null && pageBytes.isNotEmpty) {
            unawaited(web_storage.savePageToIndexedDb(key, pageBytes));
          }
        }
      } else {
        var localPage = _extractedPagesPath != null
            ? File('$_extractedPagesPath/${_pad(pageNumber)}.qvp')
            : null;
        if (localPage == null ||
            !localPage.existsSync() ||
            localPage.lengthSync() == 0) {
          await _ensureExtracted(force: true);
          localPage = _extractedPagesPath != null
              ? File('$_extractedPagesPath/${_pad(pageNumber)}.qvp')
              : null;
        }
        if (localPage != null &&
            localPage.existsSync() &&
            localPage.lengthSync() > 0) {
          pageBytes = await localPage.readAsBytes();
        }
      }

      if (pageBytes != null && pageBytes.isNotEmpty) {
        final page = _engine!.loadPage(pageBytes);
        page.hide(Sel.kind(QvpKind.ayahMarkOrnament));

        if (_pageCache.length >= _maxCachedPages) {
          final currentPage = AppState.instance.currentMushafPage.value;
          int? evictKey;
          int maxDistance = -1;
          for (final k in _pageCache.keys) {
            final distance = (k - currentPage).abs();
            // Protect pages within the active reading window (±3 pages)
            if (currentPage > 0 && distance <= 3) continue;
            if (distance > maxDistance) {
              maxDistance = distance;
              evictKey = k;
            }
          }
          // If all cached pages are inside the reading window, fallback to furthest key that isn't current page
          if (evictKey == null) {
            for (final k in _pageCache.keys) {
              if (k != currentPage) {
                final distance = (k - currentPage).abs();
                if (distance > maxDistance) {
                  maxDistance = distance;
                  evictKey = k;
                }
              }
            }
          }
          if (evictKey != null) {
            final oldestPage = _pageCache.remove(evictKey);
            oldestPage?.dispose();
            QvpPageView.evictPage(evictKey);
          }
        }
        _pageCache[pageNumber] = page;
        return page;
      }
      return null;
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
    if (page != null) {
      _pageCache.remove(pageNumber);
      _pageCache[pageNumber] = page;
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
