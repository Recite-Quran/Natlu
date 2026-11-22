<div align="center">


# و ما اسالكم عليه من اجر ان اجري الا على رب العالمين
### الحمد لله رب العالمين • بفضل الله و برحمته

# QuranTarteel — ترتيل القرآن
### Real-Time On-Device Quran Recitation Tracking, Tajweed Verification & Voice Navigation for Flutter

[![License](https://img.shields.io/badge/License-For%20The%20Sake%20Of%20Allah%20Subhanu-purple.svg)](#-sacred-covenant--license-لوجه-الله-تعالى)
[![pub package](https://img.shields.io/badge/pub.dev-quran__tarteel%20v1.0.0-blue.svg)](https://pub.dev/packages/quran_tarteel)
[![Platform](https://img.shields.io/badge/Platform-Android%20%7C%20iOS%20%7C%20macOS%20%7C%20Windows%20%7C%20Linux%20%7C%20Web-green.svg)](https://pub.dev/packages/quran_tarteel)
[![SDK](https://img.shields.io/badge/Engine-QuranLab%20SDK%204.0-blue.svg)](https://pub.dev/packages/quranlab_tajweedformer)

*Neural engine:* Powered by **QuranLab TajweedFormer SDK 4.0** with on-device cached neural inference.

</div>

---

> [!NOTE]
> **Naming & Independence Notice (تسمية حرة لوجه الله):**
> `quran_tarteel` is an independent, non-commercial open-source engine dedicated for the sake of Allah alone (لوجه الله تعالى). The name derives from the divine Quranic commandment in Surah Al-Muzzammil: **{وَرَتِّلِ الْقُرْآنَ تَرْتِيلًا}**. This project is not affiliated with, sponsored by, or associated with Tarteel Inc.

---

> [!IMPORTANT]
> **Scholarly & Pedagogical Covenant:**
> **This engine is an assistive algorithmic aid designed to facilitate revision, memorization practice, and self-testing.**
> It **can never substitute** for learning directly from and reciting to a qualified, certified Sheikh. Verifying letter articulation points, subtle oral characteristics, and sound Hifdh must always be confirmed through direct recitation to authorized scholars.

---

## 📑 Table of Contents

- [⚡ 60-Second Quick Start](#-60-second-quick-start)
- [🏗️ System Architecture](#️-system-architecture)
- [  Core Features (With Deep Dive Guides)](#-core-features-with-deep-dive-guides)
  - [1. Hands-Free Dictation & Auto-Scroll](#1-hands-free-dictation--auto-scroll)
  - [2. Real-Time Deterministic Tajweed Matrix](#2-real-time-deterministic-tajweed-matrix)
  - [3. "Recite to Navigate" Voice Search](#3-recite-to-navigate-voice-search)
  - [4. Tarteel-Style Hifdh Memorization Mode](#4-tarteel-style-hifdh-memorization-mode)
  - [5. Production Audio Pipeline & Microphone Hardware](#5-production-audio-pipeline--microphone-hardware)
  - [6. Authentic Mus'haf UI & Page Layout](#6-authentic-mushaf-ui--page-layout)
- [🎨 Color Highlighting & Event Protocol](#-color-highlighting--event-protocol)
- [⚙️ Configuration Presets (`TrackerConfig`)](#️-configuration-presets-trackerconfig)
- [📚 Full Documentation Suite](#-full-documentation-suite)
- [  Sacred Covenant & License (لوجه الله تعالى)](#️-sacred-covenant--license-لوجه-الله-تعالى)
- [ Acknowledgments](#-acknowledgments)

---

## ⚡ 60-Second Quick Start

Get deterministic word recitation verification running in your Flutter app in four simple steps:

### 1. Add Dependency
```yaml
dependencies:
  quran_tarteel: ^1.0.0
```

### 2. Initialize & Evaluate Target Word
```dart
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:quran_tajweedformer/quran_tajweedformer.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Initialize Quran repository & engine
  final repository = QuranRepository(QuranMetadataService());
  final engine = ReciteQuran(
    repository: repository,
    isTajweed: true, // Enables Tajweed rule verification (Madd, Ghunnah, Shaddah)
  );
  await engine.initialize();

  // 2. Set target word: surah:ayah:word (Surah 1, Ayah 1, Word 0: "بiسمi")
  engine.setTargetWord(surah: 1, ayah: 1, wordIndex: 0);

  // 3. Listen to right / wrong word evaluation & diagnostic errors:
  engine.onWordEvaluated.listen((WordEvaluationResult result) {
    print('📍 Coordinate: ${result.surah}:${result.ayah}:${result.wordIndex} (Word #${result.wordNumber})');
    print('📖 Expected: "${result.expectedPhonemes}" | Heard: "${result.recognizedPhonemes}"');

    if (result.isRight) {
      if (result.verdict == WordVerdict.correct) {
        print('🟢 Right word! Perfectly recited.');
      } else if (result.verdict == WordVerdict.tajweedWarning) {
        print('🟡 Right word, but Tajweed warning: ${result.errors.first.messageEn}');
      }
    } else {
      print('🔴 Wrong word / mispronounced!');
      for (final error in result.errors) {
        print('   ❌ ${error.messageEn} (${error.messageAr})');
        print('   💡 Advice: ${error.adviceEn}');
      }
    }
  });

  // 4. Stream 16kHz Float32 audio into the engine
  final audio = AudioProcessor();
  await audio.start(
    onChunk: (Float32List chunk, bool isFinal) {
      engine.feedAudio(chunk, isFinal: isFinal);
    },
  );
}
```

### Or Target an Entire Ayah Sequentially:
```dart
// Advances automatically through words of Ayah 1 as they are recited:
engine.setTargetAyah(surah: 1, ayah: 1);
```

👉 **Need state management or Mus'haf UI?** [Read the Complete App Integration Guide →](doc/APP_INTEGRATION_GUIDE.md)

---

## 🏗️ System Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                 Microphone Audio Stream                     │
│    Raw 16kHz Mono 16-bit PCM (Hardware DSP Filters Bypassed) │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│             QuranLabSdkEngine (Streaming ASR)               │
│     Official Quran Lab SDK 4.0 Neural ASR Streaming Engine  │
│       Emits phonetic token stream: [بِ], [س], [مِ], [للَ]... │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│        PhonemeAlignmentIsolate (Background Dart Isolate)    │
│  - Executes 2D Dynamic Programming alignment                │
│  - Evaluates deterministic Tajweed acoustic matrix          │
│  - Emits real-time WordMatchedEvent (Zero UI jank)          │
└──────────────────────────────┬──────────────────────────────┘
                               │
            ┌──────────────────┴──────────────────┐
            ▼                                     ▼
 ┌──────────────────────┐              ┌──────────────────────┐
 │ Hands-Free Dictation │              │ Tajweed Evaluation   │
 │ Early Matching Commits│              │ Madd & Ghunnah Spans │
 └──────────┬───────────┘              └──────────┬───────────┘
            │                                     │
            └──────────────────┬──────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│                       Flutter UI Layer                      │
│   🟢 Green (Read) | 🟡 Yellow (Tajweed Slip) | 🔴 Red (Skip)│
│   Smooth auto-scroll keeps active word centered at 60 FPS   │
└─────────────────────────────────────────────────────────────┘
```

---

##   Core Features (With Deep Dive Guides)

### 1. Hands-Free Dictation & Auto-Scroll
Designed for seamless, responsive page reading:
- **Early Matching**: Commits words as soon as root consonants match without waiting for trailing vowels or pauses.
- **Automatic Re-anchoring (`enableAutoReanchor: true`)**: If a user skips ahead or jumps verses, the engine detects the stall and automatically re-anchors the Mus'haf to their active position hands-free.
- **💡 Author's Note & Strong Recommendation (Enable It!)**:
  > `enableAutoReanchor` defaults to `false` in `TrackerConfig` purely out of conservative caution—the author didn't want unexpected jumps during strict memorization exams or edge cases that had not yet undergone massive real-world testing.
  >
  > **However, for any Quran reading, Tilawah, or consumer Mus'haf app, you are STRONGLY ENCOURAGED to enable it (`enableAutoReanchor: true`)!**
  >
  > The engine is protected by an **Anti-Ambiguity Guard** ($\Delta\text{dist} < 3$) and multi-stage window probing, ensuring that false jumps are suppressed even across repeated refrains (*فَبِأَيِّ آلَاءِ رَبِّكُمَا تُكَذِّبَانِ* in Surah Ar-Rahman). Enjoy the magical hands-free experience!

👉 [**Deep Dive: Dictation Integration Guide →**](https://github.com/Iam-Muslim/quran_tarteel/blob/HEAD/doc/DICTATION_SYSTEM_GUIDE.md)

---

### 2. Real-Time Deterministic Tajweed Matrix
Evaluates reciter pronunciation against an acoustic matrix:
- **Madd Rules (1–7)**: Validates elongation duration (2, 4, 5, 6 Harakat) with legitimate *Al-Madd Al-Aared Lissukun* Waqf flexibility (Qasr, Tawassut, Tool).
- **Mushaddad Ghunnah**: Enforces 2-Harakah nasal holding on Noon (`نّ`) and Meem (`مّ`).
- **Shaddah**: Measures consonant closure duration (~1.5 Harakat) and doubling.
- **Pedagogical Feedback**: Emits bilingual explanations (Arabic & English) via `ErrorExplainer` and the pre-built `TajweedErrorSheet`.

👉 [**Deep Dive: Tajweed Verification Guide →**](https://github.com/Iam-Muslim/quran_tarteel/blob/HEAD/doc/TAJWEED_GUIDE.md)

---

### 3. "Recite to Navigate" Voice Search
Search across all **6,236 Ayahs** in $< 5\text{ ms}$:
- **Myers 64-Bit Bit-Parallel Search**: Scans the entire normalized Quran on background threads with zero UI freeze.
- **Prefix Stripping**: Intelligently removes *Isti'adha* and *Basmalah* if recited before the verse.
- **Auto-Navigation**: Emits live candidate verses and navigates immediately upon detecting a unique match.

👉 [**Deep Dive: Voice Search & Ayah Finder Guide →**](https://github.com/Iam-Muslim/quran_tarteel/blob/HEAD/doc/VOICE_SEARCH_GUIDE.md)

---

### 4. Tarteel-Style Hifdh Memorization Mode
Build a full digital memorization companion:
- **Blind Recitation**: Words remain masked (`•••••`) or blurred until the reciter pronounces them correctly.
- **Progressive Revealing**: Words animate into view in Green upon correct recitation.
- **Omission Detection**: Built-in skip lookahead pinpoints skipped or forgotten words.
- **Hint System**: Peek at the next word for 2 seconds or reveal the first letter.

👉 [**Deep Dive: Memorization & Mistake Detection Guide →**](https://github.com/Iam-Muslim/quran_tarteel/blob/HEAD/doc/MEMORIZATION_MODE_GUIDE.md)

---

### 5. Production Audio Pipeline & Microphone Hardware
Studio-grade audio recording tailored for Quranic speech:
- **Bypassing Hardware DSP Filters**: Explicitly disables Acoustic Echo Cancellation (AEC) and Noise Suppression (NS) so quiet breath consonants (`هـ`, `ح`, `ث`) and Madd elongation are not muted.
- **Automatic 16kHz Resampling**: Resamples hardware streams to 16,000 Hz Mono Float32 `[-1.0, 1.0]`.
- **Audio Interruption Resilience**: Gracefully handles incoming phone calls, Siri/Google Assistant, and Bluetooth AirPods switches.

👉 [**Deep Dive: Production Audio Pipeline Guide →**](https://github.com/Iam-Muslim/quran_tarteel/blob/HEAD/doc/AUDIO_PIPELINE_GUIDE.md)

---

### 6. Authentic Mus'haf UI & Page Layout
Render authentic Islamic typography in Flutter:
- **15-Line Madani Mus'haf (604 Pages)**: Support for authentic page layouts matching the printed King Fahd Complex Mus'haf.
- **Uthmanic Fonts**: Guidance on integrating `KFGQPC Uthman Taha Naskh` and handling diacritics and verse end markers (۝).
- **Smooth Auto-Scroll & Page Turns**: Automatically flips pages when the reciter reaches the last word of a page.

👉 [**Deep Dive: Interactive Mus'haf UI & Layout Guide →**](https://github.com/Iam-Muslim/quran_tarteel/blob/HEAD/doc/MUSHAF_UI_GUIDE.md)

---

## 🎨 Color Highlighting & Event Protocol

Every word alignment emitted on `tracker.onWordMatched` resolves into one of three color states:

```
┌─────────────────────────────────────────────────────────────┐
│ 🟢 GREEN  (Valid Pronunciation & Correct Tajweed)           │
│    event.isGreen == true (event.isRed == false & no errors) │
├─────────────────────────────────────────────────────────────┤
│ 🟡 YELLOW (Pronounced Correctly, but with a Tajweed Slip)   │
│    event.isYellow == true (tajweedErrors is not empty)      │
│    Tap word to open TajweedErrorSheet with corrective advice│
├─────────────────────────────────────────────────────────────┤
│ 🔴 RED    (Skipped Word, Omission, or Gross Mispronunciation)│
│    event.isRed == true                                      │
└─────────────────────────────────────────────────────────────┘
```

---

## ⚙️ Configuration Presets (`TrackerConfig`)

```dart
// 1. Hands-Free Page Reading (Forgiving & Auto-Navigating)
final dictationConfig = TrackerConfig.dictation();

// 2. Strict Tajweed Examination
final examConfig = const TrackerConfig(
  recitationSpeed: RecitationSpeed.normal,
  matchingStrictness: MatchingStrictness.strict,
  enableEarlyMatching: false, // Must pronounce full vowel duration
  enableAutoReanchor: false,  // Skipping is flagged in RED
);

// 3. Fast Revision (Taraweeh / Hadr Tempo)
final fastConfig = TrackerConfig.fast();
```

👉 **Need quick method signatures?** [Check the API Quick Reference Cheat Sheet →](https://github.com/Iam-Muslim/quran_tarteel/blob/HEAD/doc/API_REFERENCE.md)

---

## 📚 Full Documentation Suite

All in-depth documentation is housed in the [`doc/`](https://github.com/Iam-Muslim/quran_tarteel/tree/HEAD/doc) directory:

| Guide | Description |
| :--- | :--- |
| 🗺️ [**Documentation Hub**](https://github.com/Iam-Muslim/quran_tarteel/blob/HEAD/doc/README.md) | Master directory index and structured learning pathways |
| 📖 [**Dictation Integration Guide**](https://github.com/Iam-Muslim/quran_tarteel/blob/HEAD/doc/DICTATION_SYSTEM_GUIDE.md) | Early Matching, Auto Re-anchoring, 24 vs 30 phoneme threshold |
| 🎯 [**Tajweed Verification Guide**](https://github.com/Iam-Muslim/quran_tarteel/blob/HEAD/doc/TAJWEED_GUIDE.md) | Madd rules, Ghunnah, Shaddah, speed calibration, `ErrorExplainer` |
| 🎙️ [**Voice Search Guide**](https://github.com/Iam-Muslim/quran_tarteel/blob/HEAD/doc/VOICE_SEARCH_GUIDE.md) | "Recite to Navigate", 6,236 Ayah Myers bit-parallel search |
| 🧠 [**Memorization & Mistake Detection Guide**](https://github.com/Iam-Muslim/quran_tarteel/blob/HEAD/doc/MEMORIZATION_MODE_GUIDE.md) | Tarteel-style Hifdh testing, hidden words, built-in omission lookahead |
| 🎧 [**Production Audio Pipeline Guide**](https://github.com/Iam-Muslim/quran_tarteel/blob/HEAD/doc/AUDIO_PIPELINE_GUIDE.md) | 16kHz Float32 streaming, bypassing DSP filters, interruptions |
| 📜 [**Interactive Mus'haf UI & Layout Guide**](https://github.com/Iam-Muslim/quran_tarteel/blob/HEAD/doc/MUSHAF_UI_GUIDE.md) | 15-line Madani layout, Uthmanic fonts, line centering, page turns |
| 📱 [**Complete App Integration Guide**](https://github.com/Iam-Muslim/quran_tarteel/blob/HEAD/doc/APP_INTEGRATION_GUIDE.md) | State management (Riverpod/Bloc), lifecycle, 1-file minimal app |
| ⚡ [**API Quick Reference & Cheat Sheet**](https://github.com/Iam-Muslim/quran_tarteel/blob/HEAD/doc/API_REFERENCE.md) | High-density method signatures, streams, configs, models |
| 🛠️ [**Troubleshooting & FAQ**](https://github.com/Iam-Muslim/quran_tarteel/blob/HEAD/doc/TROUBLESHOOTING_FAQ.md) | Debugging microphone silence, alignment lag, repeated refrain jumping |

---

## License (لوجه الله تعالى)

### **مَا أَسْأَلُكُمْ عَلَيْهِ مِنْ أَجْرٍ ۖ إِنْ أَجْرِيَ إِلَّا عَلَىٰ رَبِّ الْعَالَمِينَ**

> **THIS PACKAGE AND SOURCE CODE ARE DEDICATED FOR THE SAKE OF ALLAH ALONE.**

Before viewing, using, distributing, or modifying any part of this repository, you explicitly agree to the following covenants:

1. **100% Free to End Users**:
   You may use, study, and redistribute this software or its logic **ONLY** in applications and services that are completely free of charge to all end users till the end inshaa Allah .
2. **Strict Prohibition on Commercialization & Profit**:
   You are **STRICTLY FORBIDDEN** from selling this application, placing it behind paywalls, subscription models, in-app purchases, charging download fees, monetizing it with advertisements (AdMob, Unity Ads, etc.), or extracting any financial revenue from this codebase, models, or outputs.
3. **Pass-Through**:
   These terms are immutable and strictly pass on to any fork, derivative work, or redistributed component.

---

##   Acknowledgments

*Alhamdulillah (الحمد لله رب العالمين) — بفضل الله وبرحمته وحده*

- **[QuranLab](https://huggingface.co/Quran-Lab)** (Brother Mustafa) for the causal streaming ASR acoustic model training powering TajweedFormer V4.
- **[quran-transcript](https://github.com/obadx/quran-transcript)** by Brother Abdullah Aml, for the authentic Hafs phonetic dataset and sound-level Tajweed rule annotations.
- **[quranic-phonemizer](https://github.com/M97Chahboun/quranic-phonemizer)** for generating native phonetic datasets.

---

<div align="center">

**هذا من فضل ربي - ربنا تقبل منا انك انت السميع العليم**

</div>
