# LinguaSwap — Design Discussion & Decisions

Status: brainstorm captured, phase-1 direction chosen. No implementation yet.
Last updated: Aug 2026.

This document records the design discussion around three hard problems that
surfaced once the basic prototype was working, the full option space for each,
and the preliminary decisions for the first phase of development.

---

## Grounding: how replacement actually works today

Before the options, the current reality (from the code) so decisions are anchored:

- **All swapping happens client-side** in the Chrome extension. The Elixir
  backend only serves a static word dictionary and records stats. There is **no
  server-side text replacement**.
  - Core routine: `replaceWordsInTextNode` — `chrome-extension/content.js:532`
  - Lookup build: `loadWordsAndReplace` — `chrome-extension/content.js:214`
  - Dictionary source: `Vocabulary.get_words_for_replacement/2` —
    `lib/linguaswap/vocabulary.ex:198`
- **Matching is exact whole-word**, case-insensitive, punctuation-stripped:
  ```js
  const clean = segment.replace(/[^\w']/g, ""); // content.js:549
  const lower = clean.toLowerCase();            // content.js:550
  if (wordMap[lower]) { ... }                   // content.js:552
  ```
- **There is NO morphology/suffix/stemming/lemmatization anywhere.** The
  perceived "-ing" behavior is an artifact of the dictionary entries, not of any
  transformation code. This makes the naturalness work a greenfield feature, not
  a bug fix.
- **Difficulty fields exist but are dead.** `Word.frequency_rank` and
  `Word.difficulty_score` are stored but never read; both are hardcoded to `0`
  in `get_or_create_word!` (`lib/linguaswap/vocabulary.ex:44-45`). Every user
  currently receives the full 100-word seed list regardless of progress.
- **Live progress system** uses per-user statuses `hard | simple | trivial`
  (`lib/linguaswap/vocabulary.ex:10`) with:
  - reveal-driven demotion — `record_word_reveal/2` (`vocabulary.ex:74`)
  - exposure-driven auto-promotion — `maybe_auto_promote/1` (`vocabulary.ex:161`)
- **Tokenization is single-token only.** Whitespace split, no n-gram/phrase
  matching, no sentence segmentation.
- **Supported pairs** (`en-es`, `en-uz`) are hardcoded in the extension UI and
  seed data; `language_pair` is a free-form string column with no enum.

Two cross-cutting truths that shape everything below:

1. **Single-word swap cannot reorder.** Even with perfect suffixes, English
   (SVO) → Uzbek (SOV) word order can't be fixed by swapping words in place.
   This is why Q1 (morphology) and Q3 (density) are linked.
2. **The current architecture is "dumb fast client + static served dictionary."**
   Options that precompute data fit it cheaply; options that need runtime
   intelligence (LLM/MT per page) are a larger architectural shift.

---

## Q1 — Morphology / naturalness for non-English-like languages

**Problem.** English inflects via suffixes and word order in ways that don't map
1:1 onto agglutinative (Uzbek, Turkish, Finnish) or fusional (Russian)
languages. "running" is not "run" + "ing" in Uzbek — the tense/aspect marker
attaches to the verb root at the *end*, and vowel harmony changes the suffix
form. Naively appending "-ing" equivalents produces unnatural output.

The prior meta-question: **do we inflect, or sidestep it?**

### Options

- **A — Base-form only (sidestep inflection).**
  Only swap words in their dictionary base form; skip inflected English.
  - Pros: zero morphology code; never unnatural; matches current architecture.
  - Cons: misses most words on a real page (most are inflected); weak learning
    signal from low coverage.

- **B — English-side lemmatization, target base form.** *(chosen for phase 1)*
  Normalize the English input word to its lemma before lookup ("running"→"run"),
  show the target's base form. Keep a small English stemmer/lemma map in the
  extension.
  - Pros: big coverage jump; English morphology is simple and covered by tiny
    libraries; no target-language morphology required.
  - Cons: shows an *uninflected* target word inside an inflected English
    sentence. Usually acceptable for vocabulary learning, can read slightly
    oddly. Does not make the target language itself natural — it avoids the
    problem rather than solving it.

- **C — Runtime per-language morphology engine (target-side).**
  A rules engine keyed by `language_pair` that knows target inflection and maps
  detected English features (tense, number, POS) to target transformations
  (e.g. English "-ing" → Uzbek continuous suffix at word end with vowel-harmony
  resolution).
  - Pros: genuinely natural output; linguistically "correct."
  - Cons: heavy — needs English POS/feature detection, a per-language morphology
    module, and allomorph/vowel-harmony logic. Each new language is real
    linguistic work; fragile.

- **D — Store multiple surface forms per word in the dictionary.**
  Precompute instead of transforming at runtime. Dictionary stores common
  inflected variants (e.g. `run`→X, `running`→Y, `ran`→Z), as sibling rows or a
  JSON map on the word.
  - Pros: no runtime morphology; output quality equals data quality; extends to
    any language; reuses the existing `words` table pattern.
  - Cons: data volume; forms must be generated (LLM at import or curation);
    larger payload to the extension.

- **E — LLM at import/curation time, static at runtime (hybrid of C+D).**
  *(chosen as the evolution target)*
  Use an LLM to generate inflected forms *when a word is added* (see Q2), store
  them (Option D's structure), serve them statically. Runtime stays dumb/fast.
  - Pros: natural output; cheap runtime; scales to any language; no linguistic
    engine to maintain.
  - Cons: generation cost/quality; needs a review workflow; per-form storage.

### Decision (Q1)

**Start with B, evolve toward E.**

- Phase 1: English-side lemmatization + base-form target for immediate coverage
  with minimal complexity.
- Later: precompute inflected target forms via LLM at word-add/import time and
  serve them statically (E), keeping the runtime client dumb.
- We deliberately avoid a runtime per-language morphology engine (C) as the
  primary path — high effort, brittle per language. E gives most of C's quality
  with far less maintenance.

---

## Q2 — Adding new words for replacement (adaptive difficulty)

**Problem / intuition.** "The more easy words the user knows, the more (harder)
new words we introduce." This is a spaced-introduction / i+1 comprehensible-input
model. Infrastructure is *almost* there but unused: `frequency_rank` and
`difficulty_score` are never read; every user gets the full seed list.

### Options

- **A — Frequency-ranked drip.**
  Order the global word list by `frequency_rank`. Each user has a "frontier" (the
  next N words). As words graduate to `trivial`, the frontier advances.
  - Pros: simple; well-founded (frequency ≈ usefulness); uses existing fields.
  - Cons: needs good per-language frequency data (current seed scores are
    arbitrary 1–3).

- **B — Budget / capacity model.** *(chosen for phase 1)*
  Maintain a target number of "active" (hard+simple) words per user. As words
  graduate to `trivial`, free budget and introduce new words to keep the active
  pool full.
  - Pros: directly implements the "learn easy → get more" intuition; self-pacing;
    won't overwhelm.
  - Cons: must tune the budget size and the add-rate per graduation.

- **C — Difficulty-tiered unlocking.**
  Words grouped into tiers by `difficulty_score`; tier N unlocks when X% of tier
  N−1 is `trivial`.
  - Pros: clear progression; gamifiable.
  - Cons: coarser; rigid tier boundaries.

- **D — Density-based (ties to Q3).**
  Don't cap word *count*; cap the *fraction of a page* swapped. Introduce more
  words when the user reveals fewer (high comprehension).
  - Pros: adapts to actual reading, not abstract counts; connects to Q3.
  - Cons: more complex; per-page rather than per-user state.

### Orthogonal sub-decisions

1. **Where do candidate words come from?**
   - Curated seed list (current).
   - Auto-harvested from pages the user actually visits (add high-frequency
     unknown words they encounter). *Compelling later addition.*
   - LLM-generated.
2. **Graduation → introduction trigger.** The `trivial` promotion already exists
   (`vocabulary.ex:161`). The missing piece is a hook: on promotion to
   `trivial`, activate the next frontier word(s).

### Decision (Q2)

**Budget model (B), backed by frequency ordering (A) for choosing which words
enter the active pool.** Auto-harvesting from visited pages is a strong later
addition. Explicit data dependency: **a real per-language `frequency_rank`
dataset** is required for good ordering.

---

## Q3 — Replacement strategy as density increases

**Problem.** Word-for-word swap is fine at ~5% density but becomes an
ungrammatical pidgin at ~40%, especially for word-order-divergent languages
(the SOV/SVO issue from Q1). As more of a sentence becomes target-language,
isolated single-word swaps stop being readable *and* stop teaching grammar.

### Options

- **A — Cap density, do nothing else.**
  Never exceed X% swapped per sentence/page; prioritize highest-value words
  (due-for-review, frontier).
  - Pros: trivial; always readable; fully client-side.
  - Cons: caps the immersion ceiling; never progresses past vocabulary drilling.

- **B — Phrase / collocation swapping.** *(chosen starting point for phase 1)*
  Move from single words to multi-word units ("in front of" → one target
  phrase). Requires phrase entries in the dictionary and longest-match n-gram
  tokenization (currently single-token only).
  - Pros: more natural than word salad; handles fixed expressions correctly;
    also improves Q1 quality.
  - Cons: needs a phrase dictionary + longest-match tokenizer; still cannot do
    arbitrary reordering.

- **C — Clause / sentence-level swap at high density.** *(chosen evolution target)*
  When a sentence crosses a density threshold, replace the whole clause/sentence
  with a proper native (grammatical, reordered) translation instead of
  accumulating word swaps.
  - Pros: solves grammar AND word order naturally; the true "next level" of
    immersion.
  - Cons: needs sentence-level translation (LLM/MT); loses the fine-grained
    per-word reveal/rating UX → requires a new interaction model; larger
    architectural shift.

- **D — Graduated pipeline (staged by user level).**
  Progression: word swap (beginner) → phrase swap (intermediate) →
  clause/sentence swap (advanced); the user's overall level (from Q2) selects
  the mode per sentence.
  - Pros: coherent long-term product vision; each stage matches ability.
  - Cons: most work; three interaction models to build and maintain.

- **E — Comprehension-gated density.**
  Density adapts to demonstrated comprehension on the current page: few reveals →
  increase density; many reveals → back off. Reuses existing reveal tracking.
  - Pros: personalized; keeps the user in the productive "desirable difficulty"
    zone.
  - Cons: needs per-page/session state; tuning.

### Decision (Q3)

**Start with B (phrase/collocation swapping), evolve into C (sentence-level
swap), incorporating elements of D (mode selection by user level) and E
(comprehension-gated density).**

- Phrase swap is the lower-risk step that improves readability now and also
  benefits Q1 naturalness.
- Sentence-level native translation is the flagship advanced mode, gated by
  user level (D) and/or per-page comprehension (E).
- Note: this aligns with the existing SPEC "Phase 2: Sentence-level translation"
  intent (`SPEC.md:71`), now with a defined intermediate (phrase) step.

---

## Q4 — Where the intelligence lives (runtime vs. precompute)

**Problem.** The current architecture is a dumb fast client + static served
dictionary. Some options (Q1-E precompute, Q3-B phrase data) keep smarts at
import time; others (Q1-C engine, Q3-C sentence swap) push toward runtime
intelligence with latency, cost, and new failure modes.

### Options

- **A — Precompute at import, keep client dumb.**
  Generate morphology/phrases/translations when words are added; serve static
  data.
  - Pros: fits current architecture; low latency; low cost; offline-friendly.
  - Cons: less flexible; can't handle arbitrary unseen input live.

- **B — Runtime LLM/MT calls.**
  Compute morphology and sentence translations live per page.
  - Pros: most flexible; handles arbitrary text.
  - Cons: latency, cost, rate limits, failure modes.

- **C — Hybrid.**
  Static for common cases; runtime LLM only for high-density sentence swaps or
  cache misses.

### Decision (Q4)

**Move toward more runtime intelligence over time — including calling LLMs and,
where it helps, our own model — but start precompute-first.** Practically this
means a hybrid trajectory: precompute the common cases now (cheap, fits the
architecture), and progressively add runtime LLM/MT for the harder cases
(sentence-level swaps, cache misses, novel inflections) as they become the
bottleneck. Backend LLM integration is already anticipated in the architecture
(`SPEC.md:38`, `SPEC.md:126`).

---

## Phase 1 development direction (summary)

Chosen decisions, to be turned into concrete tasks later (no implementation yet):

| Area | Phase 1 choice | Evolution target |
| --- | --- | --- |
| Q1 Morphology | **B** — English lemmatization + base-form target | **E** — LLM-precomputed inflected forms, served statically |
| Q2 New words | **B** — budget/capacity model, frequency-ordered intake | Auto-harvest from visited pages |
| Q3 Density | **B** — phrase/collocation swapping | **C** — sentence-level swap, with **D** (level-gated) + **E** (comprehension-gated) |
| Q4 Intelligence | Precompute-first (**A**) | Increasing **runtime LLM/our own model** (hybrid **C** → more **B**) |

### Known dependencies / follow-ups to resolve before building

- Per-language **frequency_rank dataset** (Q2 requires real data; seed scores are
  currently arbitrary). `frequency_rank`/`difficulty_score` are currently dead
  fields.
- **English lemmatizer** choice for the client (Q1-B) — small footprint, works
  in the extension.
- **Phrase dictionary + longest-match n-gram tokenizer** design (Q3-B) — current
  tokenizer is single-token.
- **Graduation hook**: on promotion to `trivial`, activate next frontier
  word(s) (Q2 trigger; extends `maybe_auto_promote/1`).
- **Density cap + word-priority selection** even before sentence swap, to prevent
  the pidgin effect (safety net alongside Q3-B).
- **New interaction model** for sentence-level swaps (Q3-C) — per-word
  reveal/rating UX doesn't directly translate to whole-sentence replacements.
- **LLM cost/rate-limiting** strategy for the runtime path (Q4; also
  `SPEC.md:231` open question 4).
- Carryover open questions from SPEC: proper nouns/brand names must never be
  replaced; minimum frequency threshold; optional Anki/SRS integration.
