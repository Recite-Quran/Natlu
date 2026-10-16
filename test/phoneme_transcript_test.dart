import 'package:flutter_test/flutter_test.dart';
import 'package:the_great_quran/services/recitation/phoneme_transcript.dart';

void main() {
  late DateTime clock;
  late PhonemeTranscript t;

  setUp(() {
    clock = DateTime(2026, 10, 15, 20);
    t = PhonemeTranscript(capacity: 20, now: () => clock);
  });

  test('a growing segment adds only what is new', () {
    t.addResult(tokens: ['قُ', 'ل']);
    t.addResult(tokens: ['قُ', 'ل', 'هُ', 'وَ']);
    expect(t.text, 'قُلهُوَ');
    expect(t.length, 7);
  });

  test('blank tokens are ignored', () {
    t.addResult(tokens: ['قُ', '<blk>', 'ل', '']);
    expect(t.text, 'قُل');
  });

  test('a new segment after an endpoint continues the stream', () {
    t.addResult(tokens: ['قُ', 'ل'], isFinal: true);
    t.addResult(tokens: ['هُ']);
    t.addResult(tokens: ['هُ', 'وَ']);
    expect(t.text, 'قُلهُوَ');
  });

  test('a reset (new epoch) starts a new segment', () {
    t.addResult(tokens: ['قُ', 'ل'], epoch: 1);
    t.addResult(tokens: ['قُ'], epoch: 2);
    expect(t.text, 'قُلقُ');
  });

  test('a revised segment end is taken back', () {
    t.addResult(tokens: ['قُ', 'ل', 'هَ']);
    t.addResult(tokens: ['قُ', 'ل', 'هُ', 'وَ']);
    expect(t.text, 'قُلهُوَ');
    expect(t.length, 7);
  });

  test('keeps only the newest characters but counts all of them', () {
    for (int i = 0; i < 15; i++) {
      t.addResult(tokens: ['اب'], isFinal: true);
    }
    expect(t.text.length, 20);
    expect(t.length, 30);
    expect(t.since(26), 'اب' * 2);
    expect(t.since(0), t.text, reason: 'older text is no longer kept');
    expect(t.since(30), '');
  });

  test('since() returns what was heard after a mark', () {
    t.addResult(tokens: ['قُ', 'ل']);
    final mark = t.length;
    t.addResult(tokens: ['قُ', 'ل', 'هُ']);
    expect(t.since(mark), 'هُ');
  });

  test('remembers when it last grew', () {
    expect(t.lastGrowth, isNull);
    t.addResult(tokens: ['قُ']);
    expect(t.lastGrowth, clock);
    clock = clock.add(const Duration(seconds: 3));
    t.addResult(tokens: ['قُ']); // nothing new
    expect(t.lastGrowth, DateTime(2026, 10, 15, 20));
    t.addResult(tokens: ['قُ', 'ل']);
    expect(t.lastGrowth, clock);
  });

  test('clear forgets everything', () {
    t.addResult(tokens: ['قُ', 'ل']);
    t.clear();
    expect(t.text, '');
    expect(t.length, 0);
    expect(t.lastGrowth, isNull);
    t.addResult(tokens: ['قُ', 'ل']);
    expect(t.text, 'قُل');
  });
}
