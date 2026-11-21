# expected_tj3.zfx: the reference data (the expected units of each ayah)

One file per model build (`sdk/v4.0/expected_tj3.zfx`, manifest role `reference`). It holds, for every ayah of the
Hafs reading, the expected tj3 token sequence, the word of every token, the per-token site metadata, the madd
entries and every legal form of every word. It is made from the expected table `expected_tj3.jsonl.gz` (built with quran-g2p) by
`tools/zfexpected.py`. It holds no Arabic text, only token ids of `tokens.txt`.

It is data, read only. Since SDK 3.0.0 the engine has no scorer and a model never reads this file: the reader is
`tajweed/src/reference.c` (`zf_tajweed_reference_open`, `_open_memory`, `_ayah_count`, `_units`,
`_tokens_sha256` in `zf_tajweed.h`), which has no link to a model and returns, for a surah and an ayah, the unit
ids and the word of each unit. It reads the header, the ayah counts, the ayah index, the tokens and the words, and
checks that every section lies inside the file. The other sections (token flags, madd, forms, names) are in the
file for a developer's own judge; the engine does not read them. The format is unchanged from 2.x, which read the
same file for its scorer.

All integers are little-endian. Every section starts on a 4-byte boundary (zero padding between sections). Readers
read bytes, never aligned words, and check every offset and count against the file size before use.

## Header (160 bytes)

| Offset | Size | Field |
|---|---|---|
| 0 | 8 | magic `ZFTJEXP1` |
| 8 | 4 | format version, 1 |
| 12 | 4 | header size, 160 |
| 16 | 4 | file size in bytes |
| 20 | 4 | surahs (114) |
| 24 | 4 | ayahs (6,236 for the full table) |
| 28 | 4 | tokens, all ayahs together |
| 32 | 4 | madd entries, all ayahs together |
| 36 | 4 | bytes of the forms section |
| 40 | 32 | sha256 of the source `expected_tj3.jsonl.gz` |
| 72 | 32 | sha256 of the `tokens.txt` the ids refer to (`zf_tajweed_reference_tokens_sha256`; an SDK compares it with the model's tokens.txt) |
| 104 | 32 | section offsets, 8 x u32: ayah counts, ayah index, tokens, words, token flags, madd, forms, names |
| 136 | 24 | zero |

## Sections

- **Ayah counts**: u16 per surah. Ayah `a` of surah `s` is record `sum(counts[0 .. s-2]) + a - 1` of the index.
- **Ayah index**: 20 bytes per ayah, in reading order: u32 first token, u32 first madd entry, u32 byte offset of the
  ayah's forms in the forms section, u16 tokens, u16 madd entries, u8 words, 3 zero bytes.
- **Tokens**: u8 tj3 id per token (1 to 36: `|` between words, consonants, the nasal, vowels; never blank or
  `<foreign>`). This is the sequence `zf_tajweed_reference_units` returns: the canonical reading (ibtida at the
  first word, wasl inside, the pausal sukun form at the ayah's end).
- **Words**: u8 per token, the 0-based word; a `|` belongs to the word before it.
- **Token flags**: u16 per token:

  | Bits | Meaning |
  |---|---|
  | 0 | geminate (shadda) consonant |
  | 1 | qalqalah site (the release rule's site: b j d T q with no vowel after) |
  | 2-3 | qalqalah expected: 0 none, 1 sughra, 2 kubra (attr_qalqalah classes) |
  | 4-6 | ghunna expected: attr_ghunna class 0 to 4 |
  | 7-8 | tafkheem expected: attr_tafkheem class 0 to 2 |
  | 9-11 | madd class of the entry at this token: 0 none, 1 fixed2, 2 muttasil, 3 free, 4 lazim, 5 consonant length |
  | 12-15 | zero |

- **Madd**: 8 bytes per entry, sorted by token within an ayah: u16 token index in the ayah, u8 class (1 fixed2,
  2 muttasil, 3 free, 4 lazim, 5 consonant length: leen and ghunna lengths, not on the madd ladder), u8 kind (0
  fixed, 1 free), u8 allowed counts (bit c = count c), u8 scoring counts (bit c = count c accepted), u8 canonical
  count, u8 flags (bit 0: the entry's base is a madd letter, alef_madd / waw_madd / yeh_madd / alef_imala; the
  madd ladder applies only to those).
- **Forms**: per ayah, per word in order:
  - u8 word flags (bit 0: a stop is allowed after this word);
  - u8 distinct token strings, then each: u8 length and that many u8 token ids (no `|`);
  - u8 forms (at least 1), then each 4 bytes: u8 flags, u8 string index, u16 wajh name (0 none, else an index into
    the names section). Flags: bit 0 L is ibtida (else wasl), bit 1 R is waqf (else wasl), bits 2-4 mode (0 plain,
    1 sukun, 2 rawm, 3 ishmam), bit 5 cross-ayah form.

  Every form of the row is stored, in the row's order, followed by the cross-ayah forms (`cross_ayah.prev` on the
  first word, `cross_ayah.next` on the last): the path search keeps the earlier form on a tie, so the order is part
  of the data.
- **Names**: u32 count, then each: u8 length and that many UTF-8 bytes (the wajh names of the khilaf forms). Name
  ids count from 1.

## How the forms are meant to be read

Nothing in the engine reads the forms. They are there so that a judge built on the SDK can accept every legal
reading, as the reference implementation does (`tajweed_ref.lattice_path`): one form per word with agreeing
boundary states (a form with L ibtida follows a stop, L wasl follows a wasl ending or a cross-ayah start; R waqf
ends in a stop), the minimum edit distance to the greedy decode of log_probs, the earlier form on a tie, a stop
before a wasl ending on a tie. The chosen path is then the expected sequence of that take, so a legal stop, ibtida,
rawm, khilaf wajh or wasl across the ayah boundary is not counted against the reciter.

## Size

The full table (expected_tj3.jsonl.gz sha256 ea5159cb..., 6,236 ayahs, 542,325 tokens, 67,489 madd entries, 7
wajh names) converts to 5,489,848 bytes (forms 2,655,405 of them), 1,004,498 bytes gzipped (`gzip -9`), zfx sha256
4e17b776b3b88b4d6d45f39ebf49654aa9593501ce7053b18152e57f1271cdc6. The synthetic test table (`tests/data/model`) is a few
kB.
