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

> **Release Status**: Production builds for Google Play, App Store, Web, and Windows are tracked on the [`ReciteQuran-الحمدلله`](https://github.com/Recite-Quran/Natlu/tree/ReciteQuran-%D8%A7%D9%84%D8%AD%D9%85%D8%AF%D9%84%D9%84%D9%87) release branch. This branch hosts active mainline development.

**Natlu (نتلو)** is an open-source, fully offline, privacy-first Quran recitation, memorization, and Tajweed revision application built with Flutter. It combines an on-device neural ASR pipeline with real-time acoustic phoneme alignment, measuring vowel duration (المدود), nasalization (الغنة), and consonant pressure (الشدة) with millisecond accuracy across an authentic 15-line Mus'haf rendered natively via vector graphics.

Natlu serves as the flagship reference application for [`package:recite_quran`](https://pub.dev/packages/recite_quran)—the open Dart package that abstracts streaming sherpa-onnx inference, acoustic duration analysis, and Myers phonetic search into an embeddable engine.

- **100% On-Device Neural Inference**: Powered by a quantized INT8 Zipformer model (`zipformer_p_arabic_v3.int8.onnx`). Zero audio frames ever leave the physical device.
- **Zero Telemetry & Zero Accounts**: No tracking, no user identifiers, no remote database, and no mandatory internet connection.
- **Collaborative Study Circles (Maglis P2P)**: Decentralized, serverless group recitation for up to 4 participants with synchronized Mus'haf tracking, custom binary DataChannel serialization, and WebRTC voice calls.
- **Dedicated for Allah Alone**: 100% free forever—no ads, no paywalls, no subscriptions, and no commercialization.

---

## Architecture

Natlu separates high-performance presentation, native vector rendering, decentralized real-time networking, and neural acoustic modeling into strictly decoupled layers:

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
│     package:qvp_flutter      │  │        package:recite_quran          │
│  (Native Vector Engine)      │  │  (ASR & Acoustic Tajweed Pipeline)   │
│  ├── C++/Rust FFI & WASM     │  │  ├── SherpaEngine (ONNX Isolate)     │
│  ├── Sub-ms HafsSmart layout │  │  ├── AudioProcessor (16 kHz PCM)     │
│  └── Dynamic vector canvas   │  │  ├── HighlightingController (DP)     │
└──────────────────────────────┘  │  ├── TajweedValidator (Acoustic ms)  │
                                  │  └── QuranData (Myers Search, 6236 v)│
                                  └──────────────────────────────────────┘
                                                     ▲
                                                     │ Direct WebRTC & Data
┌────────────────────────────────────────────────────┴───────────────────┐
│                     Maglis P2P Engine (lib/maglis/)                    │
│  ├── MaglisBinaryPacker (Custom varint wire protocol, >60% payload drop)│
│  ├── MaglisPeerSession (Dual SCTP DataChannels, WebRTC Opus conference)│
│  ├── MaglisRelayFleet (Hybrid signaling: Cloudflare DO + 7 Nostr nodes) │
│  └── MaglisConfigManager (Remote fleet discovery & dynamic TURN cache) │
└────────────────────────────────────────────────────────────────────────┘
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

## Collaborative Recitation Circles — Maglis P2P ( القران العظيم)

**Maglis (مجلس)** is Natlu's decentralized, real-time collaboration engine for Quran study circles, teacher-student revision, and group recitation. It operates with zero user accounts, zero databases, and zero centralized servers.

```text
┌────────────────────────────────────────────────────────────────────────┐
│                     Natlu Maglis Session (5-Digit Room Code)           │
│                                                                        │
│   Peer A (Active Reciter) ◄── Direct WebRTC DataChannel (Sync) ──► Peer B (Student)
│   Peer A (Microphone)     ◄── Direct WebRTC Opus (48 kHz)      ──► Peer B (Speaker)
│             │                                                            │
│             └─────────────────────┬──────────────────────────────────────┘
│                                   │ Direct WebRTC Full Mesh
│                                   ▼
│                        Peer C (Teacher / Listener)
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ Ephemeral BIP-340 Signaling
                                    ▼
                    ┌───────────────────────────────┐
                    │     Decentralized Fleet       │
                    ├───────────────────────────────┤
                    │ 1. Cloudflare Edge Relay (DO) │
                    │ 2. Public Nostr Relays (7x)   │
                    │ 3. Dynamic STUN/TURN Engine   │
                    └───────────────────────────────┘
```

### 1. Frictionless User Experience
- **5-Digit Room Codes**: Connect instantly by sharing a simple 5-digit room code (supports Eastern Arabic numerals `٠-٩`). No phone numbers, email addresses, or account registrations.
- **Up to 4 Participants**: Optimized full-mesh peer topology for family halaqas, teacher-student evaluations, and study circles.
- **Turn-Taking Floor Control**: Tap "Record / تلاوة" to claim the active recitation floor (`floorClaim`). The Mus'haf page, active verse, and word-by-word highlights automatically synchronize to all participant screens in real time.

### 2. High-Efficiency Binary Wire Protocol (`MaglisBinaryPacker`)
To eliminate the overhead and JSON parsing latency over WebRTC SCTP DataChannels, Maglis implements a custom binary serialization format:

| Byte Offset | Field | Format / Encoding | Purpose |
| :--- | :--- | :--- | :--- |
| `0x00` | Magic | `0x51` (ASCII 'Q') | Wire protocol identifier |
| `0x01` | Version | `0x01` | Protocol versioning |
| `0x02` | Packet Type | `uint8` enum (0-5) | `snapshot`, `recitationUpdate`, `floorClaim`, `floorRelease`, `ping`, `pong` |
| `0x03+` | Sequence & Sender | Varint + Length-prefixed UTF-8 | Monotonic ordering & peer ID |
| `Offset` | Navigation | 3x Varints (`page`, `surah`, `ayah`) | Viewport page & verse coordinate |
| `Offset` | Bit Flags | `uint8` bitmask | Indicates presence of words, errors, active reciter, and cumulative maps |
| `Offset` | Packed Word Arrays | Varint lengths + Varint IDs | Delta-compressed green, yellow, and red word indices |
| `End` | Epoch Timestamp | Varint (platform-safe division) | 41-bit+ millisecond timestamp safe from 32-bit truncation on Web |

> **Performance Impact**: Achieves a **>60% payload reduction** compared to equivalent JSON payloads, cutting DataChannel transmission latency down to **sub-15 milliseconds**.

### 3. Dedicated Quranic Opus Audio Pipeline
General VoIP algorithms (like Zoom or Discord) aggressively gate background sound and cut off soft frequencies, causing prolonged Madd (up to 6 harakat) and quiet Ghunnah to stutter. Maglis custom-tunes the audio stack specifically for Quran recitation:
- **Sample Rate**: Full-band 48 kHz / 16-bit PCM mono.
- **Tailored APM Constraints**: Echo cancellation (`echoCancellation: true`) and automatic gain control (`autoGainControl: true`) are enforced for loud loudspeaker output across Android, iOS, Windows, and Web.
- **Preserved Vocal Warmth**: Telephony noise suppression (`noiseSuppression: false`) and telephony highpass filters (`highpassFilter: false`) are intentionally disabled to preserve subtle vocal resonance and breath pauses.
- **Custom SDP Munging**: Injects Opus parameters (`useinbandfec=1`, `usedtx=0`, `maxaveragebitrate=48000`, `ptime=20`) to eliminate audio gating and guarantee forward error recovery over lossy cellular networks.
- **Hardware Routing**: Automatic loudspeaker enforcement, headphone unplug protection (`becomingNoisyEventStream`), and automatic audio recovery after incoming phone calls.

### 4. Synchronized Mus'haf & Collaborative Tajweed Tooltips
- As the active reciter reads, all connected peers follow the exact page turns, scrolling, and word-level coloring live.
- **Remote Tajweed Inspector**: When an acoustic Tajweed error occurs, the word turns yellow on everyone's screen, and an on-canvas tooltip ("اضغط هنا") appears. Any participant can tap the word to inspect the error diagnostics in real time.
- **Cumulative Session History**: Highlights from earlier verses in the current session are retained across page turns and cleared deterministically upon new passage recitation.

### 5. Resilient Hybrid Signaling Fleet
- **Tier 1 (Sub-30ms Edge)**: Private Cloudflare Edge Worker utilizing SQLite-backed **Durable Objects** and WebSocket Hibernation (zero compute costs when idle).
- **Tier 2 (Decentralized Backbone)**: Connects to a quorum of 7 public Nostr relays (`relay.damus.io`, `relay.primal.net`, `nos.lol`, `nostr.mom`, etc.) ensuring censorship resistance and high availability even if custom servers are unreachable.
- **Smart Socket Sleep**: Once WebRTC direct peer connections are established, signaling WebSocket connections automatically sleep, dropping idle network traffic to **0 KB/s**.

### 6. End-to-End Cryptographic Privacy
- **BIP-340 Schnorr Cryptography**: Ephemeral keypairs are generated per session for Nostr signaling event authorization.
- **Rotating Blinded Room Tags**: 15-minute epoch-based blinded tags (`blindedTag`) derived via HMAC-SHA256 with an internal 256-bit application pepper prevent public relay observers from rainbow-tabling or tracking 5-digit room codes.
- **AES-256-GCM Payload Encryption**: All signaling payloads (SDP offers, answers, and ICE candidate batches) are symmetrically encrypted before leaving the device.

### 7. Dynamic Fleet Configuration (Zero App Updates)
Natlu synchronizes its relay list and STUN/TURN ICE fleet dynamically on startup via `maglis_config.json`:
- **Multi-Tier CDN Fallback**: `Edge Worker (/config)` ➔ `jsDelivr CDN` ➔ `GitHub Raw` ➔ `SharedPreferences Cache` ➔ `Hardcoded Fallback`.
- **Zero Store Delays**: Maintainers can cycle, optimize, or replace STUN/TURN servers remotely in seconds without waiting for Google Play or Apple App Store review cycles.

### 8. Mesh Self-Healing & Glare Resolution
- **Deterministic Glare Resolution**: When two peers initiate connections simultaneously, the peer with the lexicographically lower peer ID acts as the designated offerer, cleanly preventing WebRTC offer glare.
- **1-Hop Deduplicated Mesh Relay**: If a peer is temporarily blocked behind symmetric NAT or mid-negotiation, other connected peers relay floor claims and recitation packets transparently over active DataChannels.
- **Bounded 15s Recovery Window**: Disconnections trigger paced ICE restarts (at 2s and 6.5s) before tearing down peer state, absorbing transient Wi-Fi/cellular handoffs.

---

## Deploying Your Own Maglis Relay (`maglis_relay/`)

The `maglis_relay/` directory contains a self-contained Cloudflare Worker with SQLite-backed Durable Objects and WebSocket Hibernation. It runs within Cloudflare's free tier with zero ongoing hosting costs.

### 1. Prerequisites
- [Node.js](https://nodejs.org/) v18 or later.
- A free [Cloudflare Account](https://dash.cloudflare.com/sign-up).

### 2. Deploy the Worker
From the repository root:
```bash
cd maglis_relay
npx wrangler deploy
```
- Wrangler will authenticate via your browser.
- Authorize your account, and Wrangler will provision the Durable Object binding and output your live endpoint:
  ```text
  Deployed quran-maglis triggers
    https://quran-maglis.<your-account>.workers.dev
  ```

### 3. Update the Dynamic Fleet
Edit `maglis_relay/maglis_config.json`:
```json
{
  "version": 1,
  "relays": [
    "wss://quran-maglis.<your-account>.workers.dev",
    "wss://relay.primal.net",
    "wss://nos.lol",
    "wss://relay.damus.io"
  ]
}
```
Push changes to your repository. Connected client applications will automatically ingest the new relay fleet upon launch.

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

## Using `package:recite_quran` in Your Flutter App

To integrate real-time Quran speech alignment into your own Flutter application, add `recite_quran` to your `pubspec.yaml`:

```yaml
dependencies:
  flutter:
    sdk: flutter
  recite_quran: ^1.0.5
```

```dart
import 'package:flutter/material.dart';
import 'package:recite_quran/recite_quran.dart';

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
