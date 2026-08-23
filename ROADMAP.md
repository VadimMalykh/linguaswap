# LinguaSwap — Development Roadmap

Derived from `DESIGN.md` (Q1–Q4 decisions) and `SPEC.md`. This turns the chosen
directions into ordered, shippable phases. Each phase is independently useful and
leaves the product in a working state.

**Status: Phases 0 and 1 are built and tested. Phase 2 is next.**
See "Where things stand" at the end for what a new session needs to know.

Ordering principle: **data model first, then selection, then coverage, then
naturalness, then the architectural shift to runtime intelligence.** Every phase
before 5 keeps the runtime client dumb and fast (Q4 "precompute-first").

---

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

## Phase 2 — Lemmatization coverage (Q1-B) ← next

*Big coverage jump on real pages; still base-form target output.*

- Backend fills and serves `lemma`; API keys entries by lemma as well as surface.
- Client-side English lemmatizer (irregular map + suffix rules), small enough to
  ship in the content script.
- Casing and punctuation preserved around the swap.
- **Proper-noun guard** — never replace mid-sentence capitalized tokens, acronyms,
  or stoplisted brand names (SPEC open question 1).

## Phase 3 — Phrases and density control (Q3-B, with Q3-A as safety net)

- Multi-token dictionary entries (`token_count > 1`) served to the client.
- Longest-match n-gram tokenizer in the content script (currently single-token).
- **Density cap**: never exceed X% of tokens per sentence/page; priority ordering
  (frontier > due-for-review > trivial) decides what gets swapped — prevents the
  pidgin effect before sentence swap exists.

## Phase 4 — LLM precompute pipeline (Q1-E, Q4-A)

- `Linguaswap.LLM` (Req + Claude Messages API) generating, at word-add/import
  time: translation, lemma, POS, and **target-side inflected forms** into `forms`.
- Review workflow in the dashboard (approve / reject generated forms).
- Rate limiting and cost caps (SPEC open question 4).
- Client picks the right stored form from features the lemmatizer already detects
  (tense, number) — natural output with a still-dumb runtime.

## Phase 5 — Sentence-level swap (Q3-C, gated by Q3-D and Q3-E)

*The architectural shift: first runtime intelligence.*

- Client sentence segmentation; crossing a density threshold triggers a
  sentence-level request instead of accumulating word swaps.
- `POST /api/v1/translate/sentence`, backed by a cache table keyed on
  sentence hash + language pair (hybrid, Q4-C).
- **New interaction model** for whole-sentence swaps — per-word reveal/rating does
  not carry over (called out in DESIGN as a follow-up).
- Mode selection by user level (Q3-D) and comprehension-gated density from
  per-page reveal ratio (Q3-E).

## Phase 6 — Harvest and ecosystem

- Auto-harvest unknown high-frequency words from pages the user actually visits →
  candidate queue → LLM translation → active pool (DESIGN Q2 "compelling later
  addition").
- Anki/SRS export (SPEC open question 3), gamification, more language pairs,
  cross-device sync.

---

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

# Where things stand

Written so a session with no prior context can continue. Everything below is in
the repository as of the Phase 1 work.

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

### Surfaces

- `GET /api/v1/words` gained a `pool` object:
  `%{budget, active, graduated, remaining}`. The extension ignores unknown keys,
  so this is backward compatible.
- The dashboard has a "Learning Pool" card with a progress bar.
- There is **no UI yet for changing the budget**; it is settable through
  `PUT /api/v1/settings` under `settings.word_budget`.

## Verified behaviour (dev database, 197 seeded words)

A fresh user activates 50 words in true frequency order (`the, be, to, of,
and…`). Graduating one word refills the pool to 50 active / 1 graduated /
48 remaining, and the extension receives 51 words.

## Conventions worth knowing

- **All commands run in Docker** (`docker compose exec app …`), per `AGENTS.md`.
- `mix test` and `mix precommit` need `-e MIX_ENV=test`, because
  `docker-compose.yml` pins `MIX_ENV=dev` and that overrides the task default:
  `docker compose exec -e MIX_ENV=test app mix precommit`.
- Test suite is at 184 tests, all passing.

## Picking up Phase 2

Phase 2 is client-side coverage: lemmatize English page text so "running"
matches the `run` entry. The groundwork exists — `words.lemma` is populated and
indexed on `(language_pair, lemma)`.

Open decisions to make first:

1. **Where the lemmatizer runs.** `DESIGN.md` Q1-B says client. That means
   shipping a small irregular-verb map plus suffix rules inside `content.js`,
   which currently has no module structure and no test harness.
2. **What the API sends.** Today `GET /api/v1/words` sends `original`; the client
   builds `wordMap` keyed on the lowercased original
   (`chrome-extension/content.js:214`). It will need `lemma` as well, so the
   client can key on lemma and still display the right surface form.
3. **Proper-noun guard** (SPEC open question 1) belongs in the same pass, since
   both touch the token-matching loop in `replaceWordsInTextNode`
   (`chrome-extension/content.js:532`).
