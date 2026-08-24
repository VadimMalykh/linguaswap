# LinguaSwap — Development Roadmap

Derived from `DESIGN.md` (Q1–Q4 decisions) and `SPEC.md`. This turns the chosen
directions into ordered, shippable phases, and records what is actually built.

Ordering principle: **data model first, then selection, then coverage, then
naturalness, then the architectural shift to runtime intelligence.** Every phase
before 5 keeps the runtime client dumb and fast (Q4 "precompute-first").

---

# Status at a glance

| Phase | Delivers | Status |
| --- | --- | --- |
| 0 — Data foundations | Word metadata, frequency ranks, importer | ✅ done |
| 1 — Adaptive word intake | Per-user active pool with a budget | ✅ done |
| 2 — Lemmatization coverage | One entry matches every inflection | ✅ done |
| 3 — Phrases and density control | Multi-word entries, swap-density cap | ⬜ next |
| 4 — LLM precompute pipeline | Generated translations, POS, inflected forms | ⬜ planned |
| 5 — Sentence-level swap | Whole-sentence translation above a threshold | ⬜ planned |
| 6 — Harvest and ecosystem | Auto-harvest from real pages, Anki export | ⬜ planned |

Both test suites pass:

```bash
docker compose exec -e MIX_ENV=test app mix test              # 192 tests
docker compose exec app node --test 'chrome-extension/test/*.test.js'   # 18 tests
```

## What works today

The app is usable end to end as a local, single-machine build:

1. **Register and sign in** on the Phoenix app at `localhost:4000`, and sign in
   again from the extension popup, which stores a session token.
2. **The extension pulls your active pool** on every page load — up to your word
   budget (default 50) of `hard`/`simple` words in frequency order, plus every
   word you have already graduated.
3. **Words are swapped in place on any page.** Page text is lemmatized in the
   client, so one dictionary entry covers every inflection: `was`, `been` and
   `being` all reach the `be` entry. Punctuation and capitalization survive the
   swap; names, acronyms and stoplisted brands are left alone.
4. **Hover reveals the original**; clicking opens Hard / Simple / Easy. Rating
   one form settles every form of the same word on the page.
5. **Words graduate.** Rating a word "Easy" — or 100 exposures with no reveal —
   promotes it to `trivial`, which frees budget and pulls the next frontier word
   into the pool automatically.
6. **The dashboard** shows pool state (active / graduated / frontier), stats and
   page-visit history.
7. **YouTube video titles** are translated too, through a separate path that
   copes with YouTube reusing the title node across navigations.

## What is not built yet

Ordered by how much it limits real use.

| Gap | Why it matters | Addressed by |
| --- | --- | --- |
| **The dictionary holds 197 entries** (99 en-es, 98 en-uz) | The budget alone is 50, so a user nearly exhausts the data. The importer exists and is unused on a real list. | Unscheduled — see below |
| **Localhost only** | `manifest.json` allows `http://localhost:4000/*` and `background.js` hardcodes that API base. Nobody else can run it. | Unscheduled |
| **Single words only** | "a lot of" cannot be an entry; the tokenizer walks one whitespace segment at a time. | Phase 3 |
| **No density cap** | A word-dense page can be swapped into pidgin. Nothing limits swaps per sentence. | Phase 3 |
| **Base-form output only** | The target side is always the dictionary form: "she ser running", never "she era". | Phase 4 |
| **No LLM anywhere** | Translations, POS and inflected forms are all hand-authored TSV. | Phase 4 |
| **Exposure counting is approximate** | `increment_exposure/2` bumps every active word on any page visit, whether or not the word appeared. Auto-promotion is driven by that count, so it runs faster than real exposure warrants. | Unscheduled |
| **No UI for the word budget** | Settable only through `PUT /api/v1/settings` under `settings.word_budget`. | Unscheduled |

### Unscheduled work (no phase owns these)

- [ ] **Import a real frequency list.** `mix linguaswap.import_words` has been
      built and tested since Phase 0 but has only ever been fed the seed TSVs.
      This is the cheapest large win available and blocks nothing.
- [ ] **Make the backend reachable.** A configurable API base in
      `background.js` plus matching `host_permissions`, so the extension can
      point at something other than `localhost:4000`.
- [ ] **Wire up `POST /api/v1/words/replace`.** The route, the controller
      action, `Vocabulary.record_word_replacement/2` and the background
      handler for `RECORD_REPLACEMENT` all exist, but **nothing in the content
      script ever sends it**. Sending it per actual on-page swap is what would
      make exposure counts real, and would retire the blanket increment in
      `increment_exposure/2`.
- [ ] **Turn off the title tracer.** `titleDebug` in `content.js` is `true`, so
      every page logs `LS-TITLE …` to the console, as does the load banner.
- [ ] **A budget control in the dashboard.**
- [ ] **DOM-level tests for the content script.** `lemmatizer.js` is covered;
      `content.js` — the walker, the mutation observer, the title pipeline — is
      not, and has no harness.

---

# The phases in detail

## Phase 0 — Data foundations ✅ done

*No user-visible change. Unblocks every later phase.*

- `words` gains `lemma`, `pos`, `token_count` (1 = word, >1 = phrase), `forms`
  (jsonb, target-side inflections — filled in Phase 4), `source`.
- Indexes for frontier ordering `(language_pair, frequency_rank)` and lemma
  lookup `(language_pair, lemma)`.
- `user_words` gains `activated_at` (when the word entered the active pool).
- `get_or_create_word!/3` stops hardcoding `frequency_rank: 0` /
  `difficulty_score: 0` — the dead-field problem from DESIGN.md.
- `language_pair` validated against a known set instead of free-form string.
- Import task for a real per-language frequency dataset
  (`mix linguaswap.import_words`), with `difficulty_score` derived from the
  frequency band.

Resolves: DESIGN dependency "per-language frequency_rank dataset", "dead fields".

## Phase 1 — Adaptive word intake (Q2-B budget model) ✅ done

*First real behaviour change: users stop getting the whole dictionary.*

- Per-user **active pool**: a budget (default ~50, user-settable) of
  `hard` + `simple` words, filled in frequency order from the candidate list.
- **Graduation hook**: promotion to `trivial` frees budget and activates the next
  frontier word(s) — the missing trigger noted in DESIGN Q2.
- `GET /api/v1/words` returns the active pool only, plus pool metadata.
- Dashboard shows pool state: active / graduated / frontier.

## Phase 2 — Lemmatization coverage (Q1-B) ✅ done

*Big coverage jump on real pages; still base-form target output.*

- Backend fills and serves `lemma`; API keys entries by lemma as well as surface.
- Client-side English lemmatizer (irregular map + suffix rules), small enough to
  ship in the content script.
- Casing and punctuation preserved around the swap.
- **Proper-noun guard** — never replace mid-sentence capitalized tokens, acronyms,
  or stoplisted brand names (SPEC open question 1).

## Phase 3 — Phrases and density control (Q3-B, with Q3-A as safety net) ⬜ next

- Multi-token dictionary entries (`token_count > 1`) served to the client.
- Longest-match n-gram tokenizer in the content script (currently single-token).
- **Density cap**: never exceed X% of tokens per sentence/page; priority ordering
  (frontier > due-for-review > trivial) decides what gets swapped — prevents the
  pidgin effect before sentence swap exists.

See "Picking up Phase 3" below for how the Phase 2 code shapes this.

## Phase 4 — LLM precompute pipeline (Q1-E, Q4-A) ⬜ planned

- `Linguaswap.LLM` (Req + Claude Messages API) generating, at word-add/import
  time: translation, lemma, POS, and **target-side inflected forms** into `forms`.
- Review workflow in the dashboard (approve / reject generated forms).
- Rate limiting and cost caps (SPEC open question 4).
- Client picks the right stored form from features the lemmatizer already detects
  (tense, number) — natural output with a still-dumb runtime.

## Phase 5 — Sentence-level swap (Q3-C, gated by Q3-D and Q3-E) ⬜ planned

*The architectural shift: first runtime intelligence.*

- Client sentence segmentation; crossing a density threshold triggers a
  sentence-level request instead of accumulating word swaps.
- `POST /api/v1/translate/sentence`, backed by a cache table keyed on
  sentence hash + language pair (hybrid, Q4-C).
- **New interaction model** for whole-sentence swaps — per-word reveal/rating does
  not carry over (called out in DESIGN as a follow-up).
- Mode selection by user level (Q3-D) and comprehension-gated density from
  per-page reveal ratio (Q3-E).

## Phase 6 — Harvest and ecosystem ⬜ planned

- Auto-harvest unknown high-frequency words from pages the user actually visits →
  candidate queue → LLM translation → active pool (DESIGN Q2 "compelling later
  addition").
- Anki/SRS export (SPEC open question 3), gamification, more language pairs,
  cross-device sync.

## Phase dependency map

```
Phase 0 ──┬─> Phase 1 (needs frequency_rank + activated_at)
          ├─> Phase 2 (needs lemma column)
          ├─> Phase 3 (needs token_count)
          └─> Phase 4 (needs forms jsonb)

Phase 2 ──> Phase 3 ──> Phase 5
Phase 4 ──> Phase 5 (cache/LLM plumbing reused)
Phase 1 ──> Phase 6 (pool is where harvested words land)
```

---

# Appendix: where things stand

Written so a session with no prior context can continue. Everything below is in
the repository as of the Phase 2 work.

## Conventions worth knowing

- **All commands run in Docker** (`docker compose exec app …`), per `AGENTS.md`.
- `mix test` and `mix precommit` need `-e MIX_ENV=test`, because
  `docker-compose.yml` pins `MIX_ENV=dev` and that overrides the task default:
  `docker compose exec -e MIX_ENV=test app mix precommit`.
- The extension's JS tests run with Node **inside the same container** (the repo
  is bind-mounted at `/app`):
  `docker compose exec app node --test 'chrome-extension/test/*.test.js'`.
  Quote the glob so the shell does not expand it.
- After changing `manifest.json` or adding an extension file, the extension must
  be **reloaded** in Chrome; a page refresh is not enough.

## What Phase 0 built

| Thing | Where |
| --- | --- |
| Word metadata migration (`lemma`, `pos`, `token_count`, `forms`, `source`) | `priv/repo/migrations/20260821120000_add_word_metadata.exs` |
| `Word` schema: language-pair validation, derived `lemma`/`token_count` | `lib/linguaswap/vocabulary/word.ex` |
| `upsert_word/1`, `get_or_create_word!/4` | `lib/linguaswap/vocabulary.ex` |
| TSV importer | `lib/mix/tasks/linguaswap.import_words.ex` |
| Dictionary data (197 entries) | `priv/data/en-es.tsv`, `priv/data/en-uz.tsv` |
| Seeds driving the importer | `priv/repo/seeds.exs` |

`frequency_rank` and `difficulty_score` are no longer dead fields. Unknown
frequency is stored as `nil`, not `0`, so unranked entries sort **last** in
frontier ordering instead of masquerading as the most common word in the
language.

## What Phase 1 built

The **active pool**: a user carries a fixed budget of words in flight, and new
words only enter as others graduate.

- `Vocabulary.ensure_active_pool/3` tops the pool back up to the budget,
  taking candidates in frequency order (`asc_nulls_last`).
- `Vocabulary.active_pool/2`, `frontier_words/3`, `pool_stats/3`.
- `Vocabulary.get_words_for_replacement/2` now returns **the user's own words**
  (active pool + graduated), not the entire dictionary. This is the behavioural
  break with the pre-Phase-1 API.
- `user_words.activated_at` records pool entry.

### The two budget rules that matter

1. **Only `hard` and `simple` occupy budget.** `trivial` words are mastered,
   cost nothing, and keep being replaced on the page — silently, per SPEC. So
   immersion keeps growing as the user learns; the *learning load* is what stays
   capped. This is why the API serves graduated words too.
2. **The budget always comes from the user's settings** (`settings["word_budget"]`,
   default 50, via `Vocabulary.word_budget/1`). The optional third argument to
   `ensure_active_pool/3` and `pool_stats/3` is an override for callers that have
   already resolved it. Background top-ups triggered by graduation must see the
   same number as an explicit API call — an earlier version of this code let the
   two diverge and refilled to the default instead of the user's budget.

### Where the pool is refilled

- `ApiController.get_words/2` — every extension page load.
- `Vocabulary.rate_word/3` — when the user rates a word "Easy" (`trivial`).
- `Vocabulary.increment_exposure/2` — after auto-promotion on a page visit.

### How a word graduates

- **By rating**: the user picks "Easy" in the popup.
- **By exposure**: `hard` → `simple` at 50 exposures with zero reveals,
  `simple` → `trivial` at 100. Exposure is counted per page visit for every
  active word, not per actual on-page swap — see the gap table above.

### Surfaces

- `GET /api/v1/words` gained a `pool` object:
  `%{budget, active, graduated, remaining}`. The extension ignores unknown keys,
  so this is backward compatible.
- The dashboard has a "Learning Pool" card with a progress bar.
- There is **no UI yet for changing the budget**; it is settable through
  `PUT /api/v1/settings` under `settings.word_budget`.

### Verified behaviour (dev database, 197 seeded words)

A fresh user activates 50 words in true frequency order (`the, be, to, of,
and…`). Graduating one word refills the pool to 50 active / 1 graduated /
48 remaining, and the extension receives 51 words.

## What Phase 2 built

Page text is now matched through its **base form**, so one dictionary entry
covers every inflection of the word on the page.

| Thing | Where |
| --- | --- |
| Lemmatizer, proper-noun guard, casing/punctuation rules, tokenizer | `chrome-extension/lemmatizer.js` |
| JS tests for all of the above | `chrome-extension/test/lemmatizer.test.js` |
| `lemma` served per entry | `lib/linguaswap_web/api_controller.ex` |
| `get_word_by_original_or_lemma/2` | `lib/linguaswap/vocabulary.ex` |

### The decisions behind it

1. **The lemmatizer is a separate content script**, not code inside
   `content.js`. `manifest.json` loads `lemmatizer.js` first, and it exposes
   `LinguaSwapLemmatizer` on the page global; under Node the same file exports
   itself with `module.exports`, which is what makes it testable. Everything in
   it is pure — no DOM access — for exactly that reason.
2. **Wrong swaps are worse than missed ones.** The suffix rules refuse any
   candidate shorter than three characters, because that is where the damaging
   collisions live: "thing" → "th" → "the", "as" → "a". Bare `-er`/`-est`
   stripping is left out entirely ("corner" → "corn", "flower" → "flow"); only
   the `-ier`/`-iest` → `-y` forms survive. A closed list, `NO_SUFFIX_RULES`,
   protects function words whose ending merely looks inflected.
3. **Irregulars short-circuit.** A form in the irregular map returns
   immediately, so "does" can never be offered as "doe".
4. **All caps is read by length.** Up to three characters it is an initialism
   and is left alone (this is what protects "US" and "IT"); longer, it is
   treated as shouting and translated, which is what makes headlines work.
5. **Capitalization only means something away from a sentence start.** A
   capitalized token mid-sentence is a name; at a sentence start only a
   stoplisted brand is. "I" and "A" are exempt.
6. **One tokenizer, two callers.** `segmentText/2` returns neutral parts rather
   than strings or nodes, so the page walker (`replaceWordsInTextNode`) and the
   YouTube title translator (`translateString`) share one set of rules. The
   walker turns parts into DOM nodes; the title path calls `renderParts`.

### What changed in the swap itself

- **Punctuation stays outside the span.** A matched segment becomes up to three
  nodes — prefix text, the word span, suffix text — so "world," keeps its comma
  and hover reveal only ever touches the word.
- **Casing is carried over**: "Water" → "Agua", "WATER" → "AGUA".
- **Spans now carry two words.** `data-original` is the form as it appeared on
  the page (what hover reveals and what restore puts back); `data-entry` is the
  dictionary entry behind it. After lemmatization these differ, and the API only
  knows the entry — so reveals and ratings report `data-entry`. Rating one form
  updates every surface form on the page that resolved to the same entry.
- The API accepts either: `get_word_by_original_or_lemma/2` falls back to the
  lemma, with an exact spelling always winning.

### Verified behaviour

Against the live 50-word dev pool, "The Apple was on the table, and it had been
there for two days." becomes "El Apple ser en el table, y ello tener ser allí
para two days." — `was`, `had` and `been` all reach their lemmas, `Apple` is
left alone as a name, and the comma and full stop stay put.

## Picking up Phase 3

Two things about the Phase 2 code shape the work:

1. **The tokenizer is where n-grams go.** `segmentText/2` in
   `chrome-extension/lemmatizer.js` walks one whitespace segment at a time. A
   longest-match n-gram pass belongs there, behind the same `parts` contract, so
   neither caller has to change. `words.token_count` already marks phrase
   entries, and the API would need to send it.
2. **The density cap needs a second pass.** `segmentText/2` currently decides
   each token independently and in order. Capping swaps per sentence means
   collecting candidates first, then choosing among them by priority (frontier >
   due-for-review > trivial) — so expect the function to grow a "decide, then
   commit" shape rather than staying a single loop.
