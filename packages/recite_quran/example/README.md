# quran_tajweedformer_example

A lightweight Flutter example demonstrating real-time Quran recitation tracking and deterministic Tajweed verification using `quran_tajweedformer`.

## What This Example Demonstrates

1. **Acoustic Audio Streaming**: Capturing 16 kHz microphone audio via `AudioProcessor` and feeding chunks directly into the neural ASR engine.
2. **Deterministic Alignment & Scoring**: Tracking recitation for Surah Al-Fatiha (Ayah 1: "بِسْمِ ٱللَّهِ ٱلرَّحْمَٰنِ ٱلرَّحِيمِ").
3. **Real-time Color State Transitions**:
   * **Neon Cyan Outline**: Currently awaited target word (lead cursor).
   * **Green**: Recited correctly with accurate Tajweed.
   * **Amber / Yellow**: Recited correctly, but with a Tajweed slip (e.g., short Madd, missing Ghunnah).
   * **Red**: Mispronounced or wrong word.
4. **Tajweed Diagnostic Card**: Displaying expected vs. recognized phonemes and specific rule warnings.

## Running the Example

```bash
# 1. Fetch dependencies
flutter pub get

# 2. Run with your Quran Lab developer API key (https://sdk.quranlab.ai)
flutter run --dart-define=QURANLAB_KEY=qlk_v1_your_api_key_here
```
