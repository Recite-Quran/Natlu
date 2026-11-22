// example/lib/main.dart
// Real-time Quran Recitation Tracking, Tajweed Verification & Voice Navigation Engine Demo
// Powered by quran_tarteel (TajweedFormer V4 / Quran Lab SDK 4.0)

import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:quran_tarteel/quran_tarteel.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const QuranTarteelExampleApp());
}

class QuranTarteelExampleApp extends StatelessWidget {
  const QuranTarteelExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Quran Tarteel Engine Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0F766E),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const QuranTarteelMainScreen(),
    );
  }
}

class QuranTarteelMainScreen extends StatefulWidget {
  const QuranTarteelMainScreen({super.key});

  @override
  State<QuranTarteelMainScreen> createState() => _QuranTarteelMainScreenState();
}

class WordTrackItem {
  final String text;
  WordEvaluationVerdict? verdict;
  double? score;
  String? cleanAsr;
  List<ReciterError>? tajweedErrors;
  String expectedPhonemes;

  WordTrackItem({
    required this.text,
    this.expectedPhonemes = '',
  });
}

class AyahTarget {
  final String title;
  final int surah;
  final int ayah;
  final List<String> words;

  const AyahTarget({
    required this.title,
    required this.surah,
    required this.ayah,
    required this.words,
  });
}

class _QuranTarteelMainScreenState extends State<QuranTarteelMainScreen>
    with SingleTickerProviderStateMixin {
  // Official developer key from sdk.quranlab.ai (can override with --dart-define=QURANLAB_KEY=...)
  static const String _defaultApiKey =
      'qlk_v1_kn2gmnitsiua_R002fODh50Laz7Epx0gvyD';

  late final TabController _tabController;

  QuranTarteel? _engine;
  final AudioProcessor _audio = AudioProcessor();

  bool _isInitializing = true;
  String? _initError;
  bool _isRecording = false;

  // ── Tab 1: Recitation Tracking State ──
  final List<AyahTarget> _targets = const [
    AyahTarget(
      title: 'سورة الإخلاص (١١٢: ١)',
      surah: 112,
      ayah: 1,
      words: ['قُلْ', 'هُوَ', 'ٱللَّهُ', 'أَحَدٌ'],
    ),
    AyahTarget(
      title: 'سورة الناس (١١٤: ١)',
      surah: 114,
      ayah: 1,
      words: ['قُلْ', 'أَعُوذُ', 'بِرَبِّ', 'ٱلنَّاسِ'],
    ),
    AyahTarget(
      title: 'سورة الفاتحة (١: ١)',
      surah: 1,
      ayah: 1,
      words: ['بِسْمِ', 'ٱللَّهِ', 'ٱلرَّحْمَٰنِ', 'ٱلرَّحِيمِ'],
    ),
  ];

  int _selectedTargetIndex = 0;
  AyahTarget get _currentTarget => _targets[_selectedTargetIndex];
  late List<WordTrackItem> _wordItems;
  int _awaitedWordIndex = 0;
  String _liveTranscript = '';
  WordMatchedEvent? _lastEvaluatedEvent;

  // ── Tab 2: Voice Search ("Recite to Navigate") State ──
  bool _isVoiceSearching = false;
  String _searchQuery = '';
  List<AyahSearchMatch> _searchCandidates = [];
  bool _isSearchUnique = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(_onTabChanged);
    _resetWordItems();
    _initEngine();
  }

  void _onTabChanged() {
    if (_isRecording) {
      _stopRecording();
    }
    setState(() {});
  }

  void _resetWordItems() {
    _wordItems =
        _currentTarget.words.map((w) => WordTrackItem(text: w)).toList();
    _awaitedWordIndex = 0;
    _liveTranscript = '';
    _lastEvaluatedEvent = null;
  }

  Future<void> _initEngine() async {
    setState(() {
      _isInitializing = true;
      _initError = null;
    });

    try {
      const envKey = String.fromEnvironment('QURANLAB_KEY');
      final apiKey = envKey.isNotEmpty ? envKey : _defaultApiKey;

      // 1. Initialize QuranTarteel engine with QuranLab SDK 4.0
      _engine = QuranTarteel.sdk(
        apiKey: apiKey,
        isTajweed: true, // Enables full deterministic Tajweed matrix
      );

      await _engine!.initialize();

      // 2. Preload 6,236 Ayah phonetic voice search index in background isolate
      _engine!.preloadVoiceSearch();

      // 3. Set initial Ayah target for recitation scoring
      _engine!.setTargetAyah(_currentTarget.surah, _currentTarget.ayah);

      // 4. Subscribe to word evaluation stream
      _engine!.onWordEvaluated.listen(_onWordEvaluated);

      // 5. Subscribe to live speech transcript stream
      _engine!.onTranscript.listen((text) {
        if (mounted && text.isNotEmpty) {
          setState(() {
            _liveTranscript = text;
            if (_tabController.index == 1) {
              _searchQuery = text;
            }
          });
        }
      });

      // 6. Subscribe to real-time voice search candidate stream
      _engine!.onSearchResult.listen((VoiceSearchResult result) {
        if (!mounted) return;
        setState(() {
          _searchQuery = result.queryText;
          _searchCandidates = result.candidates;
          _isSearchUnique = result.isUnique;
        });
      });

      // 7. Subscribe to auto-reanchor events (verse jumps)
      _engine!.onAutoReanchored.listen((event) {
        if (mounted) {
          debugPrint('Engine reanchored to Ayah: ${event.ayah}, Word: ${event.wordInAyah}');
        }
      });

      if (mounted) {
        setState(() => _isInitializing = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isInitializing = false;
          _initError = e.toString();
        });
      }
    }
  }

  void _onWordEvaluated(WordMatchedEvent event) {
    if (!mounted || _tabController.index != 0) return;

    final idx = event.wordIndex;
    if (idx < 0 || idx >= _wordItems.length) return;

    setState(() {
      _lastEvaluatedEvent = event;
      final item = _wordItems[idx];
      item.verdict = event.verdict;
      item.score = event.score;
      item.cleanAsr = event.cleanAsr;
      item.expectedPhonemes = event.expectedPhonemes;
      item.tajweedErrors = event.tajweedErrors;

      if (event.isRight) {
        _awaitedWordIndex = idx + 1;
      }
    });
  }

  void _selectTarget(int index) {
    if (_isRecording) _stopRecording();
    setState(() {
      _selectedTargetIndex = index;
      _resetWordItems();
    });
    _engine?.setTargetAyah(_currentTarget.surah, _currentTarget.ayah);
  }

  Future<void> _toggleRecording() async {
    if (_isRecording) {
      await _stopRecording();
    } else {
      await _startRecording();
    }
  }

  Future<void> _startRecording() async {
    final hasPermission = await _audio.hasPermission();
    if (!hasPermission) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission denied.')),
        );
      }
      return;
    }

    if (_tabController.index == 0) {
      // Tab 0: Word Recitation Scoring
      _engine?.setTargetAyah(_currentTarget.surah, _currentTarget.ayah);
      _resetWordItems();
    } else {
      // Tab 1: Voice Search Across all 6,236 Ayahs
      setState(() {
        _searchQuery = '';
        _searchCandidates = [];
        _isSearchUnique = false;
        _isVoiceSearching = true;
      });
      await _engine?.startVoiceSearch();
    }

    await _audio.start(
      onChunk: (Float32List chunk, bool isFinal) {
        _engine?.feedAudio(chunk, isFinal: isFinal);
      },
    );

    setState(() => _isRecording = true);
  }

  Future<void> _stopRecording() async {
    await _audio.stop();
    setState(() {
      _isRecording = false;
      _isVoiceSearching = false;
    });
  }

  /// Opens the detailed Tajweed Error Modal Sheet (like in Natlu)
  void _openTajweedErrorSheet(WordTrackItem item) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final errors = item.tajweedErrors ?? [];
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header with word text & verdict badge
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      item.text,
                      style: const TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: item.verdict == WordEvaluationVerdict.tajweedWarning
                            ? const Color(0x33FBBF24)
                            : const Color(0x33EF4444),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        item.verdict == WordEvaluationVerdict.tajweedWarning
                            ? 'تنبيه تجويد (Tajweed Notice)'
                            : 'خطأ نطق (Mispronounced)',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: item.verdict == WordEvaluationVerdict.tajweedWarning
                              ? const Color(0xFFFBBF24)
                              : const Color(0xFFEF4444),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Divider(color: Colors.white12),
                const SizedBox(height: 12),

                // Phoneme Comparison
                Row(
                  children: [
                    Expanded(
                      child: _infoColumn('المطلوب (Expected)', item.expectedPhonemes),
                    ),
                    Expanded(
                      child: _infoColumn('المسموع (Heard)', item.cleanAsr ?? '-'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Tajweed Rules Breakdown
                if (errors.isNotEmpty) ...[
                  const Text(
                    'الملاحظات التجويدية (Diagnostic Rules):',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.white70,
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final err in errors)
                    Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.white10),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.info_outline,
                                  size: 16, color: Color(0xFFFBBF24)),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  err.errorCode,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFFFBBF24),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _getTajweedAdvice(err),
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.white70,
                            ),
                          ),
                          if (err.expectedDuration != null &&
                              err.actualDuration != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              'الزمن المطلوب: ${(err.expectedDuration! * 1000).toInt()}ms | المنطوق: ${(err.actualDuration! * 1000).toInt()}ms',
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.white38,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                ] else
                  const Text(
                    'تم نطق الكلمة بحروف صحيحة دون أخطاء تجويدية مسجلة.',
                    style: TextStyle(color: Colors.white60, fontSize: 13),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _getTajweedAdvice(ReciterError err) {
    final code = err.errorCode.toLowerCase();
    if (code.contains('qalqalah')) {
      return 'توجيه: إظهار ارتداد واضطراب المخرج عند سكون حرف القلقلة (ق، ط، ب، ج، د) دون خلطه بحركة.';
    } else if (code.contains('ghunnah')) {
      return 'توجيه: مد زمن الغنة بمقدار حركتين كاملتين من الخيشوم (في النون والميم المشددتين أو الإخفاء).';
    } else if (code.contains('madd')) {
      return 'توجيه: الحفاظ على زمن المد كاملاً حسب الرواية (حركتان للمد الطبيعي أو ٤-٥ للمتصل والمنفصل).';
    } else if (code.contains('shaddah')) {
      return 'توجيه: إعطاء الحرف المشدد حقه من النبر والزمن لبيان تضعيف الحرف.';
    } else if (code.contains('tashkeel')) {
      return 'توجيه: ضبط حركة الحرف (فتحة، ضمة، كسرة) بدقة وتجنب اختلاس الحركة.';
    }
    return 'توجيه: تحقق من مخرج الحرف وصفته الصوتية وفق قواعد التجويد.';
  }

  Widget _infoColumn(String title, String val) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontSize: 11, color: Colors.white38)),
        const SizedBox(height: 2),
        Text(
          val.isEmpty ? '-' : val,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _audio.stop();
    _engine?.dispose();
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Quran Tarteel Engine Demo'),
        centerTitle: true,
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFF0D9488),
          tabs: const [
            Tab(icon: Icon(Icons.check_circle_outline), text: 'Recitation Scoring'),
            Tab(icon: Icon(Icons.search), text: 'Voice Search (6,236 Ayahs)'),
          ],
        ),
      ),
      body: SafeArea(
        child: _isInitializing
            ? const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Color(0xFF0D9488)),
                    SizedBox(height: 16),
                    Text(
                      'Connecting to QuranLab SDK 4.0...',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              )
            : _initError != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Text(
                        'Initialization Error: $_initError',
                        style: const TextStyle(color: Color(0xFFEF4444)),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : TabBarView(
                    controller: _tabController,
                    children: [
                      _buildScoringTab(),
                      _buildVoiceSearchTab(),
                    ],
                  ),
      ),
    );
  }

  // ── 1. Recitation Scoring Tab ──
  Widget _buildScoringTab() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 16.0),
      child: Column(
        children: [
          // Target Verses Presets
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: List.generate(_targets.length, (i) {
                return Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: ChoiceChip(
                    label: Text(_targets[i].title),
                    selected: i == _selectedTargetIndex,
                    onSelected: (_) => _selectTarget(i),
                  ),
                );
              }),
            ),
          ),
          const SizedBox(height: 20),

          // Word Cards (Tap any word to inspect Tajweed details!)
          Directionality(
            textDirection: TextDirection.rtl,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20.0),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _isRecording ? const Color(0xFF0F766E) : Colors.white10,
                  width: 2,
                ),
              ),
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 12,
                runSpacing: 16,
                children: List.generate(_wordItems.length, (i) {
                  final w = _wordItems[i];
                  final isAwaited = _isRecording && i == _awaitedWordIndex;

                  return InkWell(
                    onTap: () => _openTajweedErrorSheet(w),
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: _getWordBgColor(w.verdict, isAwaited),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: isAwaited
                              ? const Color(0xFF38BDF8)
                              : Colors.transparent,
                          width: 1.5,
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            w.text,
                            style: TextStyle(
                              fontSize: 30,
                              fontWeight: FontWeight.bold,
                              color: _getWordTextColor(w.verdict, isAwaited),
                            ),
                          ),
                          if (w.verdict == WordEvaluationVerdict.tajweedWarning)
                            const Text(
                              '⚠️ تجويد (tap)',
                              style: TextStyle(
                                fontSize: 10,
                                color: Color(0xFFFBBF24),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Live Stream Diagnostics Card
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14.0),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white12),
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Live ASR Stream: ${_liveTranscript.isEmpty ? "(speak to begin...)" : _liveTranscript}',
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF38BDF8),
                      ),
                    ),
                    const Divider(height: 20, color: Colors.white10),
                    if (_lastEvaluatedEvent != null) ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Verdict: ${_lastEvaluatedEvent!.verdict.name.toUpperCase()}',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: _getVerdictColor(_lastEvaluatedEvent!.verdict),
                            ),
                          ),
                          Text(
                            'Score: ${(_lastEvaluatedEvent!.score * 100).toStringAsFixed(1)}%',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.white70,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Expected: "${_lastEvaluatedEvent!.expectedPhonemes}" | Heard: "${_lastEvaluatedEvent!.cleanAsr}"',
                        style: const TextStyle(fontSize: 12, color: Colors.white60),
                      ),
                      if (_lastEvaluatedEvent!.tajweedErrors?.isNotEmpty ?? false) ...[
                        const SizedBox(height: 6),
                        Text(
                          'Notice: ${_lastEvaluatedEvent!.tajweedErrors!.first.errorCode} (Tap word for advice)',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFFFBBF24),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ] else
                      const Text(
                        'Tap Start Reciting to stream live audio into the scoring isolate.',
                        style: TextStyle(fontSize: 12, color: Colors.white38),
                      ),
                  ],
                ),
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Mic Action Button
          _buildMicButton(
            label: _isRecording ? 'Stop Recitation' : 'Start Reciting',
            color: _isRecording ? const Color(0xFFDC2626) : const Color(0xFF0D9488),
            onPressed: _toggleRecording,
          ),
        ],
      ),
    );
  }

  // ── 2. Voice Search Tab ("Recite to Navigate") ──
  Widget _buildVoiceSearchTab() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(16.0),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white12),
            ),
            child: Row(
              children: [
                Icon(
                  _isVoiceSearching ? Icons.mic : Icons.search,
                  color: const Color(0xFF38BDF8),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Recite to Navigate (ابحث بصوتك في ٦,٢٣٦ آية)',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _searchQuery.isEmpty
                            ? 'Recite any portion of any Ayah...'
                            : 'Query: "$_searchQuery"',
                        style: TextStyle(
                          fontSize: 12,
                          color: _searchQuery.isEmpty ? Colors.white38 : const Color(0xFF38BDF8),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_isSearchUnique)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0x3322C55E),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      'Unique Match!',
                      style: TextStyle(
                        fontSize: 11,
                        color: Color(0xFF22C55E),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          const Text(
            'MATCHING AYAH CANDIDATES (REAL-TIME ISOLATE RANKING):',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.1,
              color: Colors.white38,
            ),
          ),
          const SizedBox(height: 8),

          Expanded(
            child: _searchCandidates.isEmpty
                ? Center(
                    child: Text(
                      _isVoiceSearching
                          ? 'Listening and searching across all 6,236 Ayahs...'
                          : 'Tap "Start Voice Search" and recite any phrase from the Quran.',
                      style: const TextStyle(color: Colors.white38, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                  )
                : ListView.builder(
                    itemCount: _searchCandidates.length,
                    itemBuilder: (ctx, i) {
                      final c = _searchCandidates[i];
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F172A),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: i == 0 ? const Color(0xFF0D9488) : Colors.white10,
                          ),
                        ),
                        child: ListTile(
                          title: Text(
                            'سورة رقم ${c.surah} — آية ${c.ayah}',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                          subtitle: Text(
                            'Edit Distance: ${c.distance} | Offset Word: ${c.startWordIdx}',
                            style: const TextStyle(fontSize: 12, color: Colors.white60),
                          ),
                          trailing: Text(
                            '${(c.score * 100).toStringAsFixed(1)}%',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: i == 0 ? const Color(0xFF22C55E) : Colors.white70,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 16),

          // Voice Search Mic Button
          _buildMicButton(
            label: _isRecording ? 'Stop Search' : 'Start Voice Search',
            color: _isRecording ? const Color(0xFFDC2626) : const Color(0xFF0284C7),
            onPressed: _toggleRecording,
          ),
        ],
      ),
    );
  }

  Widget _buildMicButton({
    required String label,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton.icon(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        icon: Icon(_isRecording ? Icons.stop : Icons.mic),
        label: Text(
          label,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Color _getWordBgColor(WordEvaluationVerdict? verdict, bool isAwaited) {
    if (isAwaited) return const Color(0x3338BDF8);
    switch (verdict) {
      case WordEvaluationVerdict.correct:
        return const Color(0x3322C55E);
      case WordEvaluationVerdict.tajweedWarning:
        return const Color(0x33FBBF24);
      case WordEvaluationVerdict.mispronounced:
        return const Color(0x33EF4444);
      default:
        return Colors.transparent;
    }
  }

  Color _getWordTextColor(WordEvaluationVerdict? verdict, bool isAwaited) {
    if (isAwaited) return const Color(0xFF38BDF8);
    switch (verdict) {
      case WordEvaluationVerdict.correct:
        return const Color(0xFF22C55E);
      case WordEvaluationVerdict.tajweedWarning:
        return const Color(0xFFFBBF24);
      case WordEvaluationVerdict.mispronounced:
        return const Color(0xFFEF4444);
      default:
        return Colors.white70;
    }
  }

  Color _getVerdictColor(WordEvaluationVerdict verdict) {
    switch (verdict) {
      case WordEvaluationVerdict.correct:
        return const Color(0xFF22C55E);
      case WordEvaluationVerdict.tajweedWarning:
        return const Color(0xFFFBBF24);
      case WordEvaluationVerdict.mispronounced:
      case WordEvaluationVerdict.skipped:
        return const Color(0xFFEF4444);
    }
  }
}
