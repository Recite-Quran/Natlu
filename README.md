<div align="center">
  
**بفضل الله وبرحمته - و ما اسالكم عليه اجرا ان اجري الا على رب العالمين**

<br/>
<img width="1500" height="600" alt="ReciteQuran" src="https://github.com/user-attachments/assets/97aeb9d0-ba14-4722-8443-7e6fc87d96cf" />

# Natlu — نتلو
<br/>

<p align="center">
  <a href="https://play.google.com/store/apps/details?id=com.recitequran.app" target="_blank">
    <img src="https://raw.githubusercontent.com/Recite-Quran/Natlu/refs/heads/ReciteQuran-%D8%A7%D9%84%D8%AD%D9%85%D8%AF%D9%84%D9%84%D9%87/docs/badges/google_play.svg" height="34" alt="Get it on Google Play" />
  </a>
  &nbsp;&nbsp;
  <a href="https://apps.apple.com/app/id6806614841" target="_blank">
    <img src="https://raw.githubusercontent.com/Recite-Quran/Natlu/refs/heads/ReciteQuran-%D8%A7%D9%84%D8%AD%D9%85%D8%AF%D9%84%D9%84%D9%87/docs/badges/app_store.svg" height="34" alt="Download on the App Store" />
  </a>
  &nbsp;&nbsp;
  <a href="https://recitequran.pages.dev/recite" target="_blank">
    <img src="https://raw.githubusercontent.com/Recite-Quran/Natlu/refs/heads/ReciteQuran-%D8%A7%D9%84%D8%AD%D9%85%D8%AF%D9%84%D9%84%D9%87/docs/badges/web_app.svg" height="34" alt="Web App" />
  </a>
  &nbsp;&nbsp;
  <a href="https://recitequran.pages.dev/" target="_blank">
    <img src="https://raw.githubusercontent.com/Recite-Quran/Natlu/refs/heads/ReciteQuran-%D8%A7%D9%84%D8%AD%D9%85%D8%AF%D9%84%D9%84%D9%87/docs/badges/official_site.svg" height="34" alt="Official Website" />
  </a>
</p>

<p align="center">
  <a href="https://pub.dev/packages/quran_tajweedformer" target="_blank">
    <img src="https://img.shields.io/badge/pub.dev-recite__quran%20^1.0.5-0175C2?logo=dart&logoColor=white" height="20" alt="quran_tajweedformer on pub.dev" />
  </a>
  &nbsp;
  <a href="https://huggingface.co/Quran-Lab/zipformer_p-arabic-v3" target="_blank">
    <img src="https://img.shields.io/badge/Hugging%20Face-Zipformer%20v3%20Model-FFD21E?logo=huggingface&logoColor=black" height="20" alt="Zipformer v3 Model on Hugging Face" />
  </a>
  &nbsp;
  <img src="https://img.shields.io/badge/Dedicated-For%20Allah%20Alone-059669" height="20" alt="For Allah Alone" />
</p>

**The official open-source Tarteel AI Alternative**  

</div>


---

## Overview

> **Release Status**: Production builds for Google Play, App Store, Web, and Windows are tracked on the [`ReciteQuran-الحمدلله`](https://github.com/Recite-Quran/Natlu/tree/ReciteQuran-%D8%A7%D9%84%D8%AD%D9%85%D8%AF%D9%84%D9%84%D9%87) release branch. This branch hosts active mainline development.

**Natlu (نتلو)** is an open-source, fully offline, privacy-first Quran recitation, memorization, and Tajweed revision application built with Flutter. It combines an on-device neural ASR pipeline with real-time acoustic phoneme alignment, measuring vowel duration (المدود), nasalization (الغنة), and consonant pressure (الشدة) with millisecond accuracy across an authentic 15-line Mus'haf rendered natively via vector graphics.

Natlu serves as the flagship reference application for [`package:quran_tajweedformer`](https://pub.dev/packages/quran_tajweedformer)—the open Dart package that abstracts streaming sherpa-onnx inference, acoustic duration analysis, and Myers phonetic search into an embeddable engine.

- **100% On-Device Neural Inference**: Powered by a quantized INT8 Zipformer model (`zipformer_p_arabic_v3.int8.onnx`). Zero audio frames ever leave the physical device.
- **Zero Telemetry & Zero Accounts**: No tracking, no user identifiers, no remote database, and no mandatory internet connection.
- **Dedicated for Allah Alone**: 100% free forever—no ads, no paywalls, no subscriptions, and no commercialization.

---

## Architecture

Natlu separates high-performance presentation, native vector rendering, and neural acoustic modeling into strictly decoupled layers:

```text
┌────────────────────────────────────────────────────────────────────────┐
│                              Natlu UI                                  │
│  ├── MushafPageView (Gestures, smooth viewport scrolling & pagination) │
│  ├── MushafOverlays (Dynamic painters: highlights, markers, tooltips)  │
│  └── AppState (Theme, mode notifier, audio session management)         │
└───────────────┬────────────────────────────┬───────────────────────────┘
                │                            │
                ▼                            ▼
┌──────────────────────────────┐  ┌──────────────────────────────────────┐
│     package:qvp_flutter      │  │        package:quran_tajweedformer   │
│  (Native Vector Engine)      │  │  (ASR & Acoustic Tajweed Pipeline)   │
│  ├── C++/Rust FFI & WASM     │  │  ├── SherpaEngine (ONNX Isolate)     │
│  ├── Sub-ms HafsSmart layout │  │  ├── AudioProcessor (16 kHz PCM)     │
│  └── Dynamic vector canvas   │  │  ├── HighlightingController (DP)     │
└──────────────────────────────┘  │  ├── TajweedValidator (Acoustic ms)  │
                                  │  └── QuranData (Myers Search, 6236 v)│
                                  └──────────────────────────────────────┘
```

---

## Core Capabilities & Engineering

### 1. On-Device Real-Time Neural Speech Alignment
- **Quantized INT8 Zipformer**: Executes speech recognition entirely offline using `zipformer_p_arabic_v3.int8.onnx` inside a dedicated background Dart worker isolate, guaranteeing 60/120 FPS UI rendering without dropped frames.
- **Dynamic Programming (DP) Phoneme Alignment**: Continuously aligns live 16 kHz PCM audio chunks against Quranic phonetic targets in real time.
- **Color-Coded Instant Feedback**:
  - **Green**: Exact phonetic and Harakat match against the Uthmanic text.
  - **Yellow**: Acoustic Tajweed observation (e.g. premature release of Madd, under-elongated Ghunnah).
  - **Red**: Word skipped, omitted, substituted, or mispronounced.
- **Automatic Page & Line Progression**: Viewport scrolls and turns pages smoothly as recitation advances.

### 2. Acoustic Tajweed Duration Verification (فحص وتدقيق أحكام التجويد)
Instead of relying on fuzzy heuristics, Natlu evaluates vowel holding durations against authentic Quranic *Tadweer* tempo using millisecond acoustic boundaries:
- **Madd Elongation (المدود)**:
  - *Madd Asli / Tabee'i (المد الطبيعي)*: Confirms strict 2-harakah duration.
  - *Madd Munfasil / Muttasil (المد المنفصل والمتصل)*: Verifies 4–5 harakat holding.
  - *Madd Lazim (المد اللازم)*: Strictly enforces full 6-harakah elongation.
- **Mushaddad Ghunnah (غنة النون والميم المشددتين)**: Validates complete 2-harakah nasal resonance.
- **Consonant Doubling (الشدة)**: Measures acoustic closure and contact pressure duration.
- **Interactive Diagnostics**: Tapping any highlighted word displays expected vs. recited durations in milliseconds. Onboard tooltips (`MushafTajweedTooltipPainter`) paint dynamic guides directly below the word ink baseline on the vector canvas.

### 3. QVP Native Vector Mushaf Engine (`packages/qvp_flutter`)
Unlike applications that render rasterized PNG page scans (which blur on high-DPI tablets or zoom) or raw WebViews (which suffer high memory pressure):
- **C++/Rust FFI & WebAssembly**: High-performance native bindings (`qvp_ffi.dll`, `QvpEngine.xcframework`, and web WASM) load and render geometry once.
- **King Fahd Standard Typography**: Authentic 15-line Mus'haf layout rendered using the official `HafsSmart` font standard with sub-pixel glyph positioning.
- **Instant Vector Hit-Testing**: Words, ayah end-markers, and surah headers are interactive vector hit-targets with zero layout recalculation overhead.

### 4. Sub-15ms Voice Search: "Recite to Navigate" (البحث الصوتي الفوري)
- Recite any short phrase or sequence of words from anywhere in the Great Quran to jump directly to its exact page in **under 15 milliseconds**.
- Implements Myers bit-parallel approximate string matching over all 6,236 verses, handling diacritical variations, phonetic shifts, and acoustic noise effortlessly.

### 5. Hifz Revision & Self-Testing Mode (وضع تثبيت الحفظ)
- Conceals words dynamically until the reciter pronounces them correctly from memory.
- Uses **Best-Drop LCS (Longest Common Subsequence)** omission detection to instantly catch skipped words, premature line jumps, or verse substitutions without breaking rhythm.

### 6. Master Reference Audio & Multi-Riwayah
- **Reference Audio**: High-clarity unified audio playback by Sheikh Mahmoud Khalil Al-Husary via the MP3Quran API, featuring sample-accurate timestamp seeking.
- **Multi-Riwayah Ready**: Architectural foundations designed to support the 10 Mutawatir Qira'at and canonical verse-counting traditions.

---

## Build & Development Guide

### 1. Prerequisites
- [Flutter SDK](https://docs.flutter.dev/get-started/install) 3.5.0 or later.
- Platform toolchains:
  - **Android**: Android Studio & Android NDK (r25c+ recommended).
  - **iOS**: macOS with Xcode 15+.
  - **Windows**: Visual Studio 2022 with C++ desktop development workload.

### 2. Clone Repository
```bash
git clone https://github.com/Recite-Quran/Natlu.git
cd Natlu
flutter pub get
```

### 3. Download Neural ASR Model
On first launch, Natlu automatically presents an in-app download dialog to fetch the neural model. Alternatively, you can pre-fetch it manually into `assets/model/`:

```bash
pip install -U "huggingface_hub[cli]"
hf download Quran-Lab/zipformer_p-arabic-v3 zipformer_p_arabic_v3.int8.onnx --local-dir assets/model
```

### 4. Run Across Platforms

#### Android
```bash
flutter run -d android
flutter build apk --release --split-per-abi
```

#### Windows
```bash
flutter run -d windows
flutter build windows --release
```

#### Web (WASM & PWA)
```bash
flutter run -d chrome --web-renderer canvaskit
flutter build web --web-renderer canvaskit --release
```

#### iOS
```bash
flutter run -d ios
flutter build ipa --release
```

---

## Using `package:quran_tajweedformer` in Your Flutter App

To integrate real-time Quran speech alignment into your own Flutter application, add `quran_tajweedformer` to your `pubspec.yaml`:

```yaml
dependencies:
  flutter:
    sdk: flutter
  quran_tajweedformer: ^1.0.5
```

```dart
import 'package:flutter/material.dart';
import 'package:quran_tajweedformer/quran_tajweedformer.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final engine = SherpaEngine();
  final audio = AudioProcessor();

  final controller = HighlightingController(
    engine: engine,
    audioProcessor: audio,
    onWordMatched: (wordIndex, status, tajweedError) {
      // Receives real-time word match status & acoustic duration errors
      debugPrint('Word: $wordIndex, Status: $status, Tajweed: $tajweedError');
    },
  );

  // Initialize offline neural ASR model
  await engine.initialize(modelPath: 'assets/model/zipformer_p_arabic_v3.int8.onnx');

  // Start continuous listening & dynamic phoneme alignment
  await controller.startRecitation(surah: 1, ayah: 1);
}
```

---

## For the Sake of Allah Alone (في سبيل الله سبحانه وتعالى وحده)

### **وَمَا أَسْأَلُكُمْ عَلَيْهِ مِنْ أَجْرٍ إِنْ أَجْرِيَ إِلَّا عَلَىٰ رَبِّ الْعَالَمِينَ**
> *“And I do not ask you for it any payment. My payment is only from the Lord of the worlds.”*  

This project and its source code are dedicated solely for the sake of Allah alone:

1. **100% Free for All Users**:  
   This software is freely available to all Muslims and developers worldwide without charge.
2. **Strict Non-Commercialization**:  
   It is strictly forbidden to sell this application, place it behind paid subscriptions, paywalls, or in-app ads, or extract financial revenue from it.
3. **Educational Practice Aid**:  
   This engine is an algorithmic revision assistant for personal practice and self-testing. It does not replace direct recitation and verification before qualified teachers and scholars.

---

*Alhamdulillah (الحمد لله والشكر لله تعالى)*

<div align="center">


**هذا من فضل ربي - ربنا تقبل منا انك انت السميع العليم**

</div>
