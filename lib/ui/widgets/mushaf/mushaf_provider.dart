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
  static const int _maxCachedPages = 64;
  Timer? _preloadDebounce;

  void preloadAdjacentPages(int pageNumber, [Size? viewportSize]) {
    final size = viewportSize ?? lastViewportSize;
    if (size == null || size.width <= 0 || size.height <= 0) return;
    _preloadDebounce?.cancel();
    _preloadDebounce = Timer(const Duration(milliseconds: 35), () {
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

    for (final target in [pageNumber + 1, pageNumber - 1]) {
      if (target >= 1 && target <= 604) {
        await _preloadSinglePage(target, size, dpr, inkColor, layout);
      }
    }
  }

  Future<void> _preloadSinglePage(
    int target,
    Size size,
    double dpr,
    Color inkColor,
    QvpViewLayout layout,
  ) async {
    final cached = getCachedPage(target);
    if (cached != null && !cached.isDisposed && cached.currentLayout != null) {
      cached.setDefaultColor(inkColor);
      QvpPageView.prepare(cached, scale: cached.currentLayout!.scale, dpr: dpr, inkColor: inkColor);
      return;
    }
    final p = await getPage(target);
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

  Future<void> _ensureExtracted() async {
    if (kIsWeb) {
      if (_webAtlasBytes != null && _webPageBytes.length >= 604) return;
      try {
        final archiveData = await rootBundle.load('assets/pages.tar.xz');
        final bytes = archiveData.buffer.asUint8List();
        final tarBytes = XZDecoder().decodeBytes(bytes);
        final archive = TarDecoder().decodeBytes(tarBytes);
        for (final file in archive) {
          if (file.isFile) {
            final fileName = file.name.replaceAll(r'\', '/').split('/').last;
            if (fileName == 'atlas.qva') {
              _webAtlasBytes = file.content;
            } else if (fileName.endsWith('.qvp')) {
              final pageNum = int.tryParse(fileName.replaceAll('.qvp', ''));
              if (pageNum != null) {
                _webPageBytes[pageNum] = file.content;
              }
            }
          }
        }
      } catch (e) {
        debugPrint('Error extracting pages.tar.xz on Web: $e');
      }
      return;
    }
    if (_extractedPagesPath != null) return;
    try {
      final appDir = await getApplicationSupportDirectory();
      final dir = Directory('${appDir.path}/mushaf_pages');
      final atlasFile = File('${dir.path}/atlas.qva');
      if (dir.existsSync() &&
          atlasFile.existsSync() &&
          File('${dir.path}/604.qvp').existsSync()) {
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
      await _ensureExtracted();

      if (_atlas == null) {
        final Uint8List atlasBytes;
        if (kIsWeb) {
          if (_webAtlasBytes != null) {
            atlasBytes = _webAtlasBytes!;
          } else {
            throw StateError('Mushaf atlas.qva not found in Web memory');
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
        final p = _webPageBytes[pageNumber];
        if (p != null) {
          pageBytes = p;
        } else {
          throw StateError('Mushaf page $pageNumber not found in Web memory');
        }
      } else {
        final localPage = _extractedPagesPath != null
            ? File('$_extractedPagesPath/${_pad(pageNumber)}.qvp')
            : null;
        if (localPage != null && localPage.existsSync()) {
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
          if (currentPage > 0 && (k - currentPage).abs() <= 3) continue;
          evictKey = k;
          break;
        }
        evictKey ??= _pageCache.keys.first;
        final oldestPage = _pageCache.remove(evictKey);
        oldestPage?.dispose();
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
