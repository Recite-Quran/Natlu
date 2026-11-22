// example/lib/main.dart
// Real-time Quran Recitation Tracking, Tajweed Verification & Voice Navigation Engine Demo
// Powered by quran_tarteel (TajweedFormer V4 / Quran Lab SDK 4.0)

import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:quran_tarteel/quran_tarteel.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const QuranTarteelApp());
}

class QuranTarteelApp extends StatelessWidget {
  const QuranTarteelApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Quran Tarteel',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFFBFBFB),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF10B981),
          brightness: Brightness.light,
        ),
        fontFamily: 'HafsSmart',
        useMaterial3: true,
      ),
      home: const QuranRecitationScreen(),
    );
  }
}

class QuranRecitationScreen extends StatefulWidget {
  const QuranRecitationScreen({super.key});

  @override
  State<QuranRecitationScreen> createState() => _QuranRecitationScreenState();
}

class SessionMistake {
  final int surah;
  final int ayah;
  final int wordIndex;
  final String wordText;
  final WordEvaluationVerdict verdict;
  final String expectedPh;
  final String recognizedPh;
  final List<ReciterError>? tajweedErrors;
  final DateTime timestamp;

  SessionMistake({
    required this.surah,
    required this.ayah,
    required this.wordIndex,
    required this.wordText,
    required this.verdict,
    required this.expectedPh,
    required this.recognizedPh,
    this.tajweedErrors,
    required this.timestamp,
  });
}

class _QuranRecitationScreenState extends State<QuranRecitationScreen> {
  // Developer key from sdk.quranlab.ai (can override with --dart-define=QURANLAB_KEY=...)
  static const String _defaultApiKey =
      'qlk_v1_kn2gmnitsiua_R002fODh50Laz7Epx0gvyD';

  QuranTarteel? _engine;
  final AudioProcessor _audio = AudioProcessor();

  bool _isEngineReady = false;
  String? _initError;
  bool _isRecording = false;

  // Authentic Quran Words Dataset: Map<Surah, Map<Ayah, List<Word>>>
  final Map<int, Map<int, List<String>>> _quranWords = {};
  bool _isLoadingWords = true;

  // Active Navigation Target
  int _currentSurah = 1;
  int _activeAyah = 1;
  int _activeWordIndex = 0;

  // Word Evaluation State Tracking: key "$surah:$ayah:$wordIndex" -> verdict
  final Map<String, WordEvaluationVerdict> _wordVerdicts = {};
  final List<SessionMistake> _sessionMistakes = [];

  final ScrollController _scrollController = ScrollController();

  static const List<String> _surahNamesAr = [
    'الفَاتِحة', 'البَقَرَة', 'آل عِمرَان', 'النِّسَاء', 'المَائدة', 'الأنعَام',
    'الأعرَاف', 'الأَنفَال', 'التَّوبَة', 'يُونس', 'هُود', 'يُوسُف', 'الرَّعد',
    'إِبرَاهيم', 'الحِجر', 'النَّحل', 'الإِسرَاء', 'الكَهف', 'مَريَم', 'طه',
    'الأَنبيَاء', 'الحَجّ', 'المُؤمِنون', 'النُّور', 'الفُرقَان', 'الشُّعَرَاء',
    'النَّمل', 'القَصَص', 'العَنكبوت', 'الرُّوم', 'لُقمَان', 'السَّجدَة',
    'الأَحزَاب', 'سَبَأ', 'فَاطِر', 'يس', 'الصَّافَّات', 'ص', 'الزُّمَر',
    'غَافِر', 'فُصِّلَت', 'الشُّورَى', 'الزُّخرُف', 'الدُّخَان', 'الجَاثِية',
    'الأَحقَاف', 'مُحَمَّد', 'الفَتح', 'الحُجُرَات', 'ق', 'الذَّاريَات',
    'الطُّور', 'النَّجم', 'القَمَر', 'الرَّحمَٰن', 'الوَاقِعَة', 'الحَديد',
    'المُجَادلة', 'الحَشر', 'المُمتَحنَة', 'الصَّف', 'الجُمُعَة', 'المُنَافِقون',
    'التَّغَابُن', 'الطَّلَاق', 'التَّحريم', 'المُلك', 'القَلَم', 'الحَاقَّة',
    'المَعَارِج', 'نُوح', 'الجِنّ', 'المُزَّمِّل', 'المُدَّثِّر', 'القِيَامَة',
    'الإِنسَان', 'المُرسَلَات', 'النَّبَأ', 'النَّازِعَات', 'عَبَس', 'التَّكوير',
    'الانفِطَار', 'المُطَفِّفِين', 'الانشِقَاق', 'البُرُوج', 'الطَّارِق',
    'الأَعلَى', 'الغَاشِية', 'الفَجر', 'البَلَد', 'الشَّمس', 'اللَّيل',
    'الضُّحَى', 'الشَّرح', 'التِّين', 'العَلَق', 'القَدر', 'البَيِّنَة',
    'الزَّلزَلَة', 'العَاديَات', 'القَارِعَة', 'التَّكَاثُر', 'العَصر',
    'الهُمَزَة', 'الفِيل', 'قُرَيش', 'المَاعُون', 'الكَوثَر', 'الكافِرُون',
    'النَّصر', 'المَسَد', 'الإِخلَاص', 'الفَلَق', 'النَّاس'
  ];

  @override
  void initState() {
    super.initState();
    _loadQuranWordsDataset();
    _initEngine();
  }

  Future<void> _loadQuranWordsDataset() async {
    try {
      final jsonStr =
          await rootBundle.loadString('assets/model/quran_words.json');
      final Map<String, dynamic> raw = jsonDecode(jsonStr);

      for (final entry in raw.entries) {
        final parts = entry.key.split(':');
        if (parts.length == 2) {
          final s = int.parse(parts[0]);
          final a = int.parse(parts[1]);
          final words = List<String>.from(entry.value);
          _quranWords.putIfAbsent(s, () => {})[a] = words;
        }
      }

      if (mounted) {
        setState(() => _isLoadingWords = false);
      }
    } catch (e) {
      debugPrint('Error loading quran_words.json: $e');
      if (mounted) {
        setState(() => _isLoadingWords = false);
      }
    }
  }

  Future<void> _initEngine() async {
    try {
      const envKey = String.fromEnvironment('QURANLAB_KEY');
      final apiKey = envKey.isNotEmpty ? envKey : _defaultApiKey;

      _engine = QuranTarteel.sdk(
        apiKey: apiKey,
        isTajweed: true, // Enables full deterministic Tajweed matrix
      );

      await _engine!.initialize();
      _engine!.preloadVoiceSearch();

      _engine!.setTargetAyah(_currentSurah, _activeAyah);
      _engine!.onWordEvaluated.listen(_onWordEvaluated);
      _engine!.onAutoReanchored.listen((event) {
        if (!mounted) return;
        setState(() {
          _activeAyah = event.ayah;
          _activeWordIndex = event.wordInAyah;
        });
      });

      if (mounted) {
        setState(() => _isEngineReady = true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _initError = e.toString());
      }
    }
  }

  void _onWordEvaluated(WordMatchedEvent event) {
    if (!mounted) return;

    final s = event.surah > 0 ? event.surah : _currentSurah;
    final a = event.ayah;
    final wIdx = event.wordIndex;
    final key = '$s:$a:$wIdx';

    final words = _quranWords[s]?[a];
    final wordText = (words != null && wIdx < words.length)
        ? words[wIdx]
        : event.cleanAsr;

    setState(() {
      _wordVerdicts[key] = event.verdict;
      _activeAyah = a;

      if (event.isRight) {
        _activeWordIndex = wIdx + 1;
      }

      // Record any Tajweed slips or mispronunciations in the session mistakes list
      if (event.verdict == WordEvaluationVerdict.tajweedWarning ||
          event.verdict == WordEvaluationVerdict.mispronounced) {
        _sessionMistakes.add(SessionMistake(
          surah: s,
          ayah: a,
          wordIndex: wIdx,
          wordText: wordText,
          verdict: event.verdict,
          expectedPh: event.expectedPhonemes,
          recognizedPh: event.cleanAsr,
          tajweedErrors: event.tajweedErrors,
          timestamp: DateTime.now(),
        ));
      }
    });
  }

  void _switchSurah(int surah) {
    if (_isRecording) _stopRecording();
    setState(() {
      _currentSurah = surah;
      _activeAyah = 1;
      _activeWordIndex = 0;
      _wordVerdicts.clear();
      _sessionMistakes.clear();
    });
    _engine?.setTargetAyah(_currentSurah, 1);
  }

  Future<void> _toggleRecording() async {
    if (_isRecording) {
      await _stopRecording();
    } else {
      await _startRecording();
    }
  }

  Future<void> _startRecording() async {
    if (!_isEngineReady) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_initError != null
                ? 'فشل تهيئة المحرك: $_initError'
                : 'المحرك قيد التهيئة، يرجى الانتظار...'),
          ),
        );
      }
      return;
    }
    final hasPerm = await _audio.hasPermission();
    if (!hasPerm) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission required.')),
        );
      }
      return;
    }

    _engine?.setTargetAyah(_currentSurah, _activeAyah);

    await _audio.start(
      onChunk: (Float32List chunk, bool isFinal) {
        _engine?.feedAudio(chunk, isFinal: isFinal);
      },
    );

    setState(() => _isRecording = true);
  }

  Future<void> _stopRecording() async {
    await _audio.stop();
    setState(() => _isRecording = false);
  }

  /// Opens the "أخطاء" (Mistakes) session summary modal sheet
  void _openSessionMistakesSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'أخطاء وملاحظات التلاوة (${_sessionMistakes.length})',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'cairo',
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
                const Divider(),
                Expanded(
                  child: _sessionMistakes.isEmpty
                      ? const Center(
                          child: Text(
                            'ما شاء الله! لا توجد أخطاء مسجلة في هذه الجلسة.',
                            style: TextStyle(
                              fontSize: 15,
                              color: Colors.black54,
                              fontFamily: 'cairo',
                            ),
                          ),
                        )
                      : ListView.separated(
                          itemCount: _sessionMistakes.length,
                          separatorBuilder: (_, __) =>
                              const Divider(height: 16),
                          itemBuilder: (ctx, i) {
                            final m = _sessionMistakes[i];
                            final isTajweed =
                                m.verdict == WordEvaluationVerdict.tajweedWarning;

                            return Directionality(
                              textDirection: TextDirection.rtl,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        m.wordText,
                                        style: const TextStyle(
                                          fontSize: 26,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 3,
                                        ),
                                        decoration: BoxDecoration(
                                          color: isTajweed
                                              ? const Color(0xFFFEF3C7)
                                              : const Color(0xFFFEE2E2),
                                          borderRadius:
                                              BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          isTajweed
                                              ? 'تنبيه تجويدي'
                                              : 'خطأ نطق',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                            color: isTajweed
                                                ? const Color(0xFFB45309)
                                                : const Color(0xFFB91C1C),
                                            fontFamily: 'cairo',
                                          ),
                                        ),
                                      ),
                                      const Spacer(),
                                      Text(
                                        'آية ${m.ayah}',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: Colors.black45,
                                          fontFamily: 'cairo',
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'المطلوب: "${m.expectedPh}" | المسموع: "${m.recognizedPh}"',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.black87,
                                      fontFamily: 'cairo',
                                    ),
                                  ),
                                  if (m.tajweedErrors?.isNotEmpty ?? false)
                                    for (final err in m.tajweedErrors!)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 2.0),
                                        child: Text(
                                          '• ${err.errorCode}',
                                          style: const TextStyle(
                                            fontSize: 11,
                                            color: Color(0xFFD97706),
                                            fontFamily: 'cairo',
                                          ),
                                        ),
                                      ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Opens the Voice Search ("Recite to Navigate") dialog
  void _openVoiceSearchDialog() {
    showDialog(
      context: context,
      builder: (ctx) => _VoiceSearchDialog(
        engine: _engine,
        audio: _audio,
        onAyahSelected: (surah, ayah) {
          Navigator.pop(ctx);
          _switchSurah(surah);
          setState(() => _activeAyah = ayah);
        },
      ),
    );
  }

  @override
  void dispose() {
    _audio.stop();
    _engine?.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final surahMap = _quranWords[_currentSurah] ?? {};

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0.5,
        leading: IconButton(
          icon: const Icon(Icons.search, color: Colors.black87),
          tooltip: 'البحث بالصوت',
          onPressed: _openVoiceSearchDialog,
        ),
        title: DropdownButtonHideUnderline(
          child: DropdownButton<int>(
            value: _currentSurah,
            icon: const Icon(Icons.keyboard_arrow_down, color: Colors.black87),
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.black87,
              fontFamily: 'cairo',
            ),
            items: List.generate(114, (i) {
              final sNum = i + 1;
              return DropdownMenuItem<int>(
                value: sNum,
                child: Text('سُورَةُ ${_surahNamesAr[i]} ($sNum)'),
              );
            }),
            onChanged: (val) {
              if (val != null) _switchSurah(val);
            },
          ),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.black54),
            tooltip: 'إعادة ضبط التظليل',
            onPressed: () {
              setState(() {
                _wordVerdicts.clear();
                _sessionMistakes.clear();
                _activeWordIndex = 0;
              });
            },
          ),
        ],
      ),
      body: _isLoadingWords
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF10B981)),
            )
          : Stack(
              children: [
                // ── Verse List Flow (Authentic Display Words) ──
                Positioned.fill(
                  child: ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.only(
                      left: 16.0,
                      right: 16.0,
                      top: 16.0,
                      bottom: 120.0,
                    ),
                    itemCount: surahMap.length,
                    itemBuilder: (context, idx) {
                      final ayahNum = idx + 1;
                      final words = surahMap[ayahNum] ?? [];

                      return Directionality(
                        textDirection: TextDirection.rtl,
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 8.0),
                          padding: const EdgeInsets.all(16.0),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: (_isRecording && _activeAyah == ayahNum)
                                  ? const Color(0xFF10B981)
                                  : Colors.black.withValues(alpha: 0.06),
                              width: (_isRecording && _activeAyah == ayahNum)
                                  ? 1.5
                                  : 1.0,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.02),
                                blurRadius: 4,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // Ayah Header Badge
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    'آية $ayahNum',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.black45,
                                      fontFamily: 'cairo',
                                    ),
                                  ),
                                  if (_isRecording && _activeAyah == ayahNum)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFECFDF5),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: const Text(
                                        'جارِ الاستماع',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: Color(0xFF059669),
                                          fontFamily: 'cairo',
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 8),

                              // Ayah Words Wrap
                              Wrap(
                                alignment: WrapAlignment.start,
                                spacing: 8,
                                runSpacing: 10,
                                children: List.generate(words.length, (wIdx) {
                                  final wordText = words[wIdx];
                                  final key =
                                      '$_currentSurah:$ayahNum:$wIdx';
                                  final verdict = _wordVerdicts[key];

                                  final isAwaited = _isRecording &&
                                      _activeAyah == ayahNum &&
                                      _activeWordIndex == wIdx;

                                  return Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: _getWordBgColor(
                                          verdict, isAwaited),
                                      borderRadius:
                                          BorderRadius.circular(6),
                                      border: Border.all(
                                        color: isAwaited
                                            ? const Color(0xFF38BDF8)
                                            : Colors.transparent,
                                        width: 1.5,
                                      ),
                                    ),
                                    child: Text(
                                      wordText,
                                      style: TextStyle(
                                        fontSize: 26,
                                        color: _getWordTextColor(
                                            verdict, isAwaited),
                                      ),
                                    ),
                                  );
                                }),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),

                // ── Bottom Floating Bar (Matching Screenshot) ──
                Positioned(
                  left: 20,
                  right: 20,
                  bottom: 24,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // "أخطاء" (Mistakes) Pill Button
                      ElevatedButton.icon(
                        onPressed: _openSessionMistakesSheet,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.black87,
                          elevation: 3,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(24),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 14,
                          ),
                        ),
                        icon: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: _sessionMistakes.isEmpty
                                ? const Color(0xFFE2E8F0)
                                : const Color(0xFFEF4444),
                            shape: BoxShape.circle,
                          ),
                          child: Text(
                            '${_sessionMistakes.length}',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: _sessionMistakes.isEmpty
                                  ? Colors.black54
                                  : Colors.white,
                              fontFamily: 'cairo',
                            ),
                          ),
                        ),
                        label: const Text(
                          'أخطاء',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            fontFamily: 'cairo',
                          ),
                        ),
                      ),

                      // Circular Record Button
                      GestureDetector(
                        onTap: _toggleRecording,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: 68,
                          height: 68,
                          decoration: BoxDecoration(
                            color: _isRecording
                                ? const Color(0xFFDC2626)
                                : const Color(0xFF10B981),
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: (_isRecording
                                        ? const Color(0xFFDC2626)
                                        : const Color(0xFF10B981))
                                    .withValues(alpha: 0.35),
                                blurRadius: 16,
                                offset: const Offset(0, 6),
                              ),
                            ],
                          ),
                          child: Icon(
                            _isRecording ? Icons.stop : Icons.mic,
                            size: 34,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Color _getWordBgColor(WordEvaluationVerdict? verdict, bool isAwaited) {
    if (isAwaited) return const Color(0x3338BDF8);
    switch (verdict) {
      case WordEvaluationVerdict.correct:
        return const Color(0x2210B981);
      case WordEvaluationVerdict.tajweedWarning:
        return const Color(0x33FBBF24);
      case WordEvaluationVerdict.mispronounced:
        return const Color(0x33EF4444);
      default:
        return Colors.transparent;
    }
  }

  Color _getWordTextColor(WordEvaluationVerdict? verdict, bool isAwaited) {
    if (isAwaited) return const Color(0xFF0284C7);
    switch (verdict) {
      case WordEvaluationVerdict.correct:
        return const Color(0xFF059669);
      case WordEvaluationVerdict.tajweedWarning:
        return const Color(0xFFD97706);
      case WordEvaluationVerdict.mispronounced:
        return const Color(0xFFDC2626);
      default:
        return Colors.black87;
    }
  }
}

// ── Voice Search ("Recite to Navigate") Dialog ──
class _VoiceSearchDialog extends StatefulWidget {
  final QuranTarteel? engine;
  final AudioProcessor audio;
  final void Function(int surah, int ayah) onAyahSelected;

  const _VoiceSearchDialog({
    required this.engine,
    required this.audio,
    required this.onAyahSelected,
  });

  @override
  State<_VoiceSearchDialog> createState() => _VoiceSearchDialogState();
}

class _VoiceSearchDialogState extends State<_VoiceSearchDialog> {
  bool _isListening = false;
  String _searchQuery = '';
  List<AyahSearchMatch> _matches = [];

  @override
  void initState() {
    super.initState();
    _startSearchSession();
  }

  Future<void> _startSearchSession() async {
    final hasPerm = await widget.audio.hasPermission();
    if (!hasPerm) return;

    await widget.engine?.startVoiceSearch();
    widget.engine?.onSearchResult.listen((res) {
      if (mounted) {
        setState(() {
          _searchQuery = res.queryText;
          _matches = res.candidates;
        });
      }
    });

    await widget.audio.start(
      onChunk: (chunk, isFinal) {
        widget.engine?.feedAudio(chunk, isFinal: isFinal);
      },
    );

    setState(() => _isListening = true);
  }

  @override
  void dispose() {
    widget.audio.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.mic, color: Color(0xFF10B981)),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'ابحث بتلاوتك (Recite to Navigate)',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'cairo',
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const Divider(),
            const SizedBox(height: 8),
            Text(
              _searchQuery.isEmpty
                  ? 'اتلُ أي مقطع من أي آية للبحث عبر ٦,٢٣٦ آية...'
                  : 'النص المسموع: "$_searchQuery"',
              style: TextStyle(
                fontSize: 13,
                color: _searchQuery.isEmpty ? Colors.black45 : Colors.black87,
                fontFamily: 'cairo',
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 220,
              child: _matches.isEmpty
                  ? Center(
                      child: Text(
                        _isListening
                            ? 'جارِ الاستماع والبحث في المصحف...'
                            : 'جارِ تهيئة الميكروفون...',
                        style: const TextStyle(
                            color: Colors.black38, fontFamily: 'cairo'),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _matches.length,
                      itemBuilder: (ctx, i) {
                        final m = _matches[i];
                        return ListTile(
                          title: Text(
                            'سورة رقم ${m.surah} — آية ${m.ayah}',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontFamily: 'cairo',
                            ),
                          ),
                          trailing: Text(
                            '${(m.score * 100).toInt()}%',
                            style: const TextStyle(
                              color: Color(0xFF10B981),
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          onTap: () =>
                              widget.onAyahSelected(m.surah, m.ayah),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
