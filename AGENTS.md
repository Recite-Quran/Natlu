# Agent Guidelines & Architectural Invariants

## Strict Mushaf Vector Rendering Invariants

### 1. Single-Pass GPU Canvas Underlay (`MushafOverlays.paintAyahHighlights`)
- **NEVER** re-introduce native multi-handle FFI highlights (`QvpPage.highlight`, `_hlGrey`, `_hlGreen`, `_hlRed`, `_hlYellow`, `_hlNeon`).
- All Ayah and word highlights in the Mushaf vector view MUST be drawn directly via the GPU underlay canvas pass in `MushafOverlays.paintAyahHighlights`.
- The Ayah highlight is **ONE continuous rounded highlight box** per line (`RRect.fromRectAndRadius(outerRect, Radius.circular(3.0))`).
- Adjacent words on the same line MUST meet at their exact midpoint ($X_{split} = (x0_i + x1_{i+1}) / 2.0$) with **0.0 px overlap and 0.0 px gap**.
- **NEVER** draw overlapping bounding boxes for adjacent words; Skia `srcOver` alpha compositing will cause green and red to blend into dark red/dirty brown.

### 2. Highlighting State Machine & Single Source of Truth
- `HighlightingController` in `lib/core/highlighting_controller.dart` is the **ONLY** source of truth for:
  - Local ASR recitation
  - Remote Maglis WebRTC recitation
  - Audio playback tracking (`QuranAudioService`)
  - Ayah selection & navigation
- **NEVER** duplicate highlight state, lists, or separate controllers in UI widgets.
- Presentation layers (`MushafView`, `VerseListView`, `VerseRow`, dialogs) only read from `HighlightingController`.

### 3. Word Color Rules
- **Selected Ayah (Idle / Not Recording):** All unrecited words in the selected ayah are neutral GREY (`palette.activeAyahBand`). The lead awaited word must NOT turn neon when idle.
- **Recording Mode (`isRecording == true`):** The current awaited word is NEON (`palette.leadWordBand`). When recited correctly, it turns GREEN (`palette.greenBand`). If Tajweed warning, YELLOW (`palette.yellowBand`). If mispronounced, RED (`palette.redBand`).
- **Audio Playback Mode:** The word currently spoken by the reciter is NEON (`palette.leadWordBand`), moving synchronously with audio millisecond timing.
- **Persistence Across Page Turns:** Ayahs containing yellow (Tajweed) or evaluated words MUST remain highlighted when navigating across pages. `controller.hasAyahHighlights(surah, ayah)` and `getWordStatus` are the source of truth for preserving these marks.

### 4. Hifz / Hide Verse Mode Rules
- When Hide Verse is ON (`isBlurEffective == true`), all unrecited words MUST remain masked by native vector invisible ink (`page.mask(hiddenWords, 'hide')`), **INCLUDING the current awaited word** — the word's text must never be revealed before recitation.
- The continuous GREY highlight band for the selected ayah MUST always be drawn behind the ink.
- When recording (`isRecording == true`), the NEON highlight box is drawn for the awaited word's bounding box (highlight box only, not the text ink).
- Once recited correctly (`state > 0`), the word's text ink is unmasked and displayed in its evaluated color (green/yellow/red).

