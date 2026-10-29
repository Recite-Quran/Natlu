<div align="center">
  
**بفضل الله وبرحمته - و ما اسالكم عليه اجرا ان اجري الا على رب العالمين**

<br/>
<img width="1500" height="200" alt="ReciteQuran" src="https://github.com/user-attachments/assets/97aeb9d0-ba14-4722-8443-7e6fc87d96cf" />

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
  <a href="https://pub.dev/packages/recite_quran" target="_blank">
    <img src="https://img.shields.io/badge/pub.dev-recite__quran%20^1.0.5-0175C2?logo=dart&logoColor=white" height="20" alt="recite_quran on pub.dev" />
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
open the branch [ReciteQuran-الحمدلله](https://github.com/Recite-Quran/Natlu/tree/ReciteQuran-%D8%A7%D9%84%D8%AD%D9%85%D8%AF%D9%84%D9%84%D9%87) For the production app on web/playstore/android/ios/windows  but here it is the latest updates and stable

**Natlu (نتلو)** is an open-source, on-device Quran Recitation application for Flutter. It listens to your recitation in real time, guides your pronunciation word-by-word with instant visual feedback, checks acoustic Tajweed rules with millisecond precision, and allows hands-free navigation across an authentic 15-line  Mus'haf.

Natlu is the flagship reference application built upon [`recite_quran`](https://pub.dev/packages/recite_quran). All neural ASR inference, phoneme alignment, Myers phonetic search, and Tajweed duration grading are handled directly by the `recite_quran` engine package.

- **100% On-Device**: Speech recognition runs entirely offline via quantized ONNX models (`zipformer_p_arabic_v3.int8.onnx`).
- **Complete Privacy**: Zero audio is transmitted over the network, zero accounts required, and zero telemetry collected.
- **For the Sake of Allah**: 100% free with no ads, no subscriptions, and no monetization.

---

## Key Features

### 1. Real-Time Word Tracking (تتبع الكلمات المباشر)
- Sub-frame acoustic alignment follows speech word-by-word as you recite.
- **Live Color Feedback**:
  - **Green**: Correct recitation (consonants and Harakat match the Quranic text).
  - **Yellow**: Tajweed observation (e.g. insufficient Madd holding or premature release).
  - **Red**: Word skipped, substituted, or mispronounced.
- Smooth automatic page scrolling and turning as recitation advances.

### 2. Acoustic Tajweed Checking (فحص وتدقيق أحكام التجويد)
- Evaluates acoustic vowel holding durations against authentic Quranic *Tadweer* timing standards:
  - **Madd Elongation (المدود)**: Differentiates 2-harakah Madd Asli, 4–5 harakat Madd Munfasil/Muttasil, and 6-harakat Madd Lazim.
  - **Mushaddad Ghunnah (غنة النون والميم المشددتين)**: Confirms complete 2-harakah nasalization duration.
  - **Shaddah Holding (الشدة)**: Confirms consonant doubling pressure.
- Tap any highlighted word to inspect expected vs. recited duration in milliseconds.

### 3. "Recite to Navigate" Instant Voice Search (البحث الصوتي الفوري)
- Recite any phrase from any Ayah in the Great Quran (القرآن العظيم) to jump directly to its exact page in under 15ms.
- Powered by Myers bit-parallel approximate string matching across all 6,236 verses.

### 4. 15-Line  Mus'haf (مصحف   15 سطرًا)
- Rendered using the official King Fahd Complex font standard (`HafsSmart`).
- True-to-print 15-line layout with accurate word spacing, surah headers, and ayah end markers.

### 5. Hifz Revision & Memorization Mode (وضع تثبيت الحفظ)
- Words stay concealed until recited correctly from memory, providing an interactive self-testing tool for Huffaz.
- Employs Best-Drop LCS omission detection to flag skipped words or line jumps.

### 6. Reference Audio Playback (الاستماع المرجعي المتقن)
- Unified audio playback for words and full Ayahs by Sheikh Mahmoud Khalil Al-Husary via MP3Quran API.
- Sample-accurate timestamp seeking with a single unified audio session.

### 7. Multi-Riwayah Architecture (الروايات المتواترة ومذاهب العد)
- Architecture designed to support the 10 Mutawatir Qira'at and canonical counting schools.

---

## Modern Architecture

Natlu is structured into a clean presentation and application layer, delegating all acoustic and alignment engineering to `package:recite_quran`:

```
┌────────────────────────────────────────────────────────┐
│                       Natlu App                        │
│   (UI / 15-Line Mushaf / AppState / AudioSession)      │
└───────────────────────────┬────────────────────────────┘
                            │ imports
                            ▼
┌────────────────────────────────────────────────────────┐
│             package:recite_quran (^1.0.5)              │
│ ├── SherpaEngine (Streaming Zipformer ONNX Isolate)    │
│ ├── AudioProcessor (16 kHz PCM chunk capture)          │
│ ├── HighlightingController (DP phoneme alignment & UI) │
│ ├── TajweedValidator (Acoustic duration verification)  │
│ └── QuranData (6,236 Ayahs, Myers phonetic search)     │
└────────────────────────────────────────────────────────┘
```

## Guide

### 1. Clone & Fetch Dependencies
```bash
git clone https://github.com/Iam-Muslim/Natlu.git
cd Natlu
flutter pub get
```

### 2. Neural ASR Model
On first launch, Natlu automatically displays an in-app download dialog to fetch the neural model. Alternatively, you can pre-download it manually into `assets/model/`:

```bash
pip install -U "huggingface_hub[cli]"
hf download Quran-Lab/zipformer_p-arabic-v3 zipformer_p_arabic_v3.int8.onnx --local-dir assets/model
```

### 3. Run Across Platforms

#### Android
```bash
flutter run -d android
flutter build apk --release --split-per-abi
```

#### Windows
```bash
flutter run -d windows
```

#### Other Platforms works Elhamdle Allah

---

## Using `recite_quran` in Your Flutter App

To integrate real-time Quran tracking into any Flutter application, add `recite_quran` to your `pubspec.yaml`:

```yaml
dependencies:
  flutter:
    sdk: flutter
  recite_quran: ^1.0.5
```

```dart
import 'package:flutter/material.dart';
import 'package:recite_quran/recite_quran.dart';

// Initialize the engine and controller
final engine = SherpaEngine();
final audio = AudioProcessor();

final controller = HighlightingController(
  engine: engine,
  audioProcessor: audio,
  onWordMatched: (wordIndex, status, tajweedError) {
    // Live update UI as words are recited
  },
);

await engine.initialize(modelPath: 'assets/model/zipformer_p_arabic_v3.int8.onnx');
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
