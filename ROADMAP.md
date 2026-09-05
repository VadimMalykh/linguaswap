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
| 3 — Phrases and density control | Multi-word entries, swap-density cap | ✅ done |
| 4 — LLM precompute pipeline | Generated POS and inflected forms, with review | ✅ done |
| 5 — Sentence-level swap | Whole-sentence translation above a threshold | ⬜ next |
| 6 — Harvest and ecosystem | Auto-harvest from real pages, Anki export | ⬜ planned |

Both test suites pass:

```bash
docker compose exec -e MIX_ENV=test app mix test              # 249 tests
docker compose exec app node --test 'chrome-extension/test/*.test.js'   # 50 tests
```

## What works today

The app is usable end to end as a local, single-machine build:

1. **Register and sign in** on the Phoenix app at `localhost:4000`, and sign in
   again from the extension popup, which stores a session token.
2. **The extension pulls your active pool** on every page load — up to your word
   budget (default 50) of `hard`/`simple` words in frequency order, plus every
   word you have already graduated.
3. **Words and phrases are swapped in place on any page.** Page text is
   lemmatized in the client, so one dictionary entry covers every inflection:
   `was`, `been` and `being` all reach the `be` entry. Multi-word entries match
   longest-first, so `a lot of` wins over the `a` that starts in the same place,
   and `gave up` reaches `give up`. Punctuation and capitalization survive the
   swap; names, acronyms and stoplisted brands are left alone.
4. **No sentence goes past the density cap.** At most ~35% of a sentence's words
   are swapped, spread across it rather than bunched at the front, and when the
   cap forces a choice it keeps the words the user is still learning. This is
   what stops a word-dense page from turning into pidgin.
5. **The target side is inflected.** "She was running" comes out as "She era
   corriendo", not "She ser correr": the client records *which* English rule
   reached the entry — a past tense, a gerund, a plural — and picks the stored
   target form for it, falling back to the dictionary form when there is none.
   Those forms are generated with the Claude API at import time and are not
   served until a human approves them at `/dictionary/review`.
6. **Hover reveals the original**; clicking opens Hard / Simple / Easy. Rating
   one form settles every form of the same word on the page.
7. **Words graduate.** Rating a word "Easy" — or 100 exposures with no reveal —
   promotes it to `trivial`, which frees budget and pulls the next frontier word
   into the pool automatically.
8. **The dashboard** shows pool state (active / graduated / frontier), stats and
   page-visit history.
9. **YouTube video titles** are translated too, through a separate path that
   copes with YouTube reusing the title node across navigations.

## What is not built yet

Ordered by how much it limits real use.

| Gap | Why it matters | Addressed by |
| --- | --- | --- |
| **No forms are generated yet** | Phase 4 built the pipeline and nothing has been run through it: every `words.forms` in the repository database is still empty, so the inflected output above is what the code does, not what a user sees today. Running `--generate` for en-es is a one-command job that costs money and needs reviewing. | A generation run |
| **No LLM at page-load time** | Sentence-level swap, cache misses and novel inflections all need a runtime call; today the client only reads precomputed data. | Phase 5 |
| **Phrase ranks are hand-placed** | The corpus list is unigrams, so it cannot say where "of course" belongs among single words. The 45 phrase ranks in `en-es.tsv` are estimates. | A bigram frequency source |
| **en-uz has no phrases, and is still the 98-word seed** | en-es was rebuilt from a corpus frequency list; Uzbek was left alone rather than machine-translated without a speaker to check it. Phase 4 can now generate it, and the review queue is where a speaker would check it — but the reviewer is still the missing piece, not the pipeline. | A native reviewer |
| **The density cap is per text node, not per rendered sentence** | Markup splits sentences: `<p>Some <b>bold</b> text.</p>` is three runs, and the cap applies to each. It bounds every fragment, which errs toward swapping too little. | Unscheduled |
| **No UI for the word budget or the density** | Settable only through `PUT /api/v1/settings` under `settings.word_budget` and `settings.swap_density`. | Unscheduled |

### Unscheduled work (no phase owns these)

- [x] **Import a real frequency list.** ~~`mix linguaswap.import_words` has only
      ever been fed the seed TSVs.~~ Done for en-es: `priv/data/en-es.tsv` now
      holds 494 entries in OpenSubtitles-2018 frequency order, built by
      `priv/data/build_dictionary.py`. en-uz is untouched — see the gap table.
- [x] **Make the backend reachable.** ~~A configurable API base in
      `background.js` plus matching `host_permissions`.~~ Done: the server URL
      is stored in `chrome.storage.local` and set from the popup, which requests
      the matching host permission at the same time.
- [x] **Wire up `POST /api/v1/words/replace`.** ~~Nothing in the content script
      ever sends it.~~ Done: the content script batches the swaps it actually
      made and posts them once the page settles, and
      `Vocabulary.record_word_replacements/3` replaced the blanket
      `increment_exposure/2`.
- [x] **Turn off the title tracer.** ~~`titleDebug` is `true`.~~ Done: one
      `DEBUG` constant at the top of `content.js` now gates the title trace and
      the load banner together.
- [ ] **Budget and density controls in the dashboard.**
- [ ] **DOM-level tests for the content script.** `lemmatizer.js` and
      `background.js` are covered; `content.js` — the walker, the mutation
      observer, the title pipeline, the swap-report batching, and now the
      dictionary build that decides `maxPhraseTokens` — is not, and has no
      harness. Phase 3 kept the decisions in the pure module for exactly this
      reason, but the wiring around them is still untested.

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

## Phase 3 — Phrases and density control (Q3-B, with Q3-A as safety net) ✅ done

- Multi-token dictionary entries (`token_count > 1`) served to the client.
- Longest-match n-gram tokenizer in the content script.
- **Density cap**: never exceed X% of a sentence's words; priority ordering
  (frontier > due-for-review > trivial) decides what gets swapped — prevents the
  pidgin effect before sentence swap exists.

## Phase 4 — LLM precompute pipeline (Q1-E, Q4-A) ✅ done

- `Linguaswap.LLM` (Req + Claude Messages API, structured outputs) generating,
  at import time: translation, lemma, POS, and **target-side inflected forms**
  into `forms`.
- Review workflow in the dashboard (approve / reject generated forms) at
  `/dictionary/review`; nothing generated is served before approval.
- Rate limiting and cost caps (SPEC open question 4) in `Linguaswap.LLM.Budget`.
- Client picks the right stored form from features the lemmatizer now reports
  (tense, number) — natural output with a still-dumb runtime.

## Phase 5 — Sentence-level swap (Q3-C, gated by Q3-D and Q3-E) ⬜ next

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
the repository as of the Phase 4 work.

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
- `Vocabulary.record_word_replacements/3` — after auto-promotion on a reported
  page of swaps.

### How a word graduates

- **By rating**: the user picks "Easy" in the popup.
- **By exposure**: `hard` → `simple` at 50 exposures with zero reveals,
  `simple` → `trivial` at 100. One exposure means **one page on which the word
  actually appeared**, reported by the content script — not one page visit, and
  not one occurrence. A page that repeats a word twenty times is still one
  encounter, which is what keeps a single article from graduating a word.

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

## What the unscheduled pass built

Four items from the list above, done after Phase 2 and before Phase 3 started.

### Real exposure counting

`Vocabulary.increment_exposure/2` is gone. In its place,
`Vocabulary.record_word_replacements/3` takes the words a page actually showed
and moves two counters differently:

- `replacement_count` gains **every occurrence** — that is literally how often
  the word was put on the page.
- `exposure_count` gains **exactly one** — an exposure is "the user met this
  word while reading", and the 50/100 promotion thresholds are tuned to that.

`POST /api/v1/words/replace` grew a batch body,
`{"words": [{"word": "run", "count": 3}], "language_pair": "en-es"}`, and still
accepts a bare list or the original single-`word` form so an older extension
build keeps working. `POST /api/v1/pagevisit` no longer touches exposure at all;
it is history and timing only.

On the client, `noteSwap` tallies each entry as it is swapped — from the page
walker and the YouTube title path both — and `flushSwapReport` posts the batch
once, 2.5s after the last swap, on a hidden tab, and before unload. **Each entry
is reported once per page**: later occurrences of an already-reported word are
dropped rather than re-sent, which keeps one page worth exactly one exposure no
matter how many times the mutation observer re-runs.

### A configurable server

`background.js` resolves its API base at call time from
`chrome.storage.local.serverUrl`, defaulting to `http://localhost:4000`. The
popup has a Server field; saving it calls `chrome.permissions.request` for that
origin first, which is why the manifest keeps `host_permissions` at localhost
and adds `optional_host_permissions`. `normalizeServerUrl` absorbs trailing
slashes and a pasted `/api/v1` — the two things people actually type — and is
covered by `chrome-extension/test/background.test.js`.

### A real dictionary for en-es

`priv/data/en-es.tsv` went from 99 hand-authored entries to 494 in corpus
frequency order, built by `priv/data/build_dictionary.py` from the
OpenSubtitles-2018 English frequency list. The important part is that the
reduction uses **the extension's own lemmatizer**, so the dictionary and the
runtime agree on what a distinct word is: "is", "are" and "was" collapse into
one "be" entry rather than wasting three.

Two judgement calls are worth knowing about, both documented in the script:

1. **Irregulars are trusted, suffix guesses are not.** The irregular map is
   hand-curated, so its base is taken outright. A `-ed`/`-ing` base is only
   believed if the corpus shows it is common in its own right — that is what
   rejects "need" → "nee" and "something" → "someth", which the bare suffix
   rules do produce.
2. **Plural stripping is trusted.** It cannot reach a shorter word with an
   unrelated meaning the way `-ed` can, so the entry lands on "eye" rather than
   "eyes", and both forms on a page find it.

`candidates()` is ported to Python there and is the one thing that can drift
from the JS; `priv/data/dump_candidates.js` exists to diff the two.

Rebuilding a dictionary also surfaced a gap in the importer: it upserts, so the
99 old en-es entries did not go away when the file was replaced, and two of them
survived — `begin`, and a capitalised `I` that collided with the new `i` on
lemma and cost every user a pool slot. `mix linguaswap.import_words --prune`
now deletes entries a rebuilt file no longer carries. It never deletes one a
user has progress on, because `user_words.word_id` cascades and would take that
history with it; those are reported for a human to resolve instead. Resolving
the `I` case meant repointing its `user_words` rows onto the new entry before
deleting it.

Both test suites pass at 204 Elixir / 23 JS, and the dev database now holds
exactly the 494 entries the file carries.

### Quieter console

One `DEBUG` constant at the top of `content.js` gates both the title trace and
the load banner.

## What Phase 3 built

Two things the client could not do before: match an entry that is more than one
word, and decide *not* to swap something it could have swapped.

| Thing | Where |
| --- | --- |
| N-gram matching, density cap, the "decide then commit" tokenizer | `chrome-extension/lemmatizer.js` |
| Tests for phrases, priority and spacing | `chrome-extension/test/lemmatizer.test.js` |
| Dictionary build and swap options on the client | `chrome-extension/content.js` |
| `swap` settings carried through with the dictionary | `chrome-extension/background.js` |
| `token_count` and `swap.max_density` served | `lib/linguaswap_web/api_controller.ex` |
| `Vocabulary.swap_density/1`, `default_swap_density/0` | `lib/linguaswap/vocabulary.ex` |
| 45 phrase entries | `priv/data/en-es.tsv` |

### The shape of the tokenizer now

`segmentText/3` used to be one loop that decided each token as it reached it.
It is now four passes, because a density cap cannot be applied by a function
that has already committed to the swap in front of it:

1. **Tokenize** into whitespace runs and word tokens, each already split into
   prefix / core / suffix. Whitespace is kept verbatim, which is what lets a
   phrase spanning `a  lot   of` be restored with its original spacing.
2. **Mark sentences.** Every word token learns which sentence it is in, using
   the same `startsSentence/1` rule Phase 2 introduced for the proper-noun
   guard. The cap is per sentence, so this has to happen before anything is
   chosen.
3. **Match**, longest-first and left to right. At each position the longest
   phrase that resolves wins and consumes its tokens.
4. **Cap**, by priority and then by spacing.

The `parts` contract did not change, so neither caller — the page walker or the
YouTube title translator — needed rewriting. Both gained one argument.

### Three decisions worth knowing about

1. **Only the head of a phrase is lemmatized.** English phrases carry their
   inflection on the first word — "gave up", "looks after", "took care of" — so
   `resolvePhrase` walks `candidates()` for the head and matches the rest as
   they stand. The alternative, lemmatizing every position, is a combinatorial
   product of candidate lists for a case English does not actually have.

2. **A phrase must be an uninterrupted run.** Punctuation between two of its
   words ends it, so "a lot, of them" never reaches the `a lot of` entry, and a
   name anywhere inside disqualifies the whole phrase. Same principle as Phase
   2: a wrong swap is worse than a missed one.

3. **Spacing, not reading order, breaks a priority tie.** This is the decision
   the cap turns on. Taking capped swaps in reading order translates the front
   of a long sentence solid and leaves the back untouched — the pidgin effect
   moved rather than removed, and worse, it strips the English context that
   makes a swapped word guessable from its neighbours. So within one priority
   each pick goes to the candidate farthest from anything already swapped in
   that sentence. On the 29-word sentence quoted below, 35% buys ten swapped
   words either way; the difference is whether they arrive in one Spanish block
   at the front or spaced through the line.

   The priority order itself is the roadmap's: frontier (`hard`) before
   due-for-review (`simple`) before mastered (`trivial`). Spacing only ever
   breaks a tie inside one of those tiers; it never promotes a mastered word
   over one being learned.

### Where the numbers come from

- **`maxPhraseTokens`** is the longest `token_count` in the words the API
  actually sent, computed by the client on each dictionary load. A user whose
  pool holds no phrases gets 1, and the n-gram pass costs nothing.
- **`maxDensity`** is `settings.swap_density`, default 0.35, served in the
  `swap` object alongside the dictionary. It is a learning parameter, so it
  lives with `word_budget` and belongs to the server; the pure tokenizer
  defaults to *uncapped* so that a caller that has not resolved a setting
  behaves as it did before Phase 3, and `content.js` supplies the fallback.
- A sentence's allowance is `max(1, floor(words * density))`. The floor of one
  is deliberate: headings, links and list items are one- and two-word
  "sentences", and rounding them to zero would silence most of a real page.
- A phrase spends its whole token count against the allowance, because three
  English words becoming one Spanish phrase is three words the reader no longer
  has.

### The phrase entries

`priv/data/en-es.tsv` gained 45 phrases, from two tokens ("give up") to four
("at the same time"). Their frequency ranks are the one hand-placed thing in
that file, and are marked as such in its header: the OpenSubtitles list
`build_dictionary.py` reads is unigrams, so it cannot say where "of course"
belongs among single words. The ranks interleave the phrases with the words
rather than appending them after all 494, because a phrase ranked 495 would be
unreachable for every user until they had graduated the entire dictionary. A
default 50-word budget reaches "of course" and "come on".

### Verified behaviour

Against the real dictionary at a 120-word budget, "Of course we can go out and
find out what happened to the man at the same time, but we have a lot of work to
do right now." becomes, uncapped:

> Por supuesto nosotros poder ir fuera y find fuera qué happened a el hombre en
> el same tiempo, pero nosotros tener muchos work a hacer ahora mismo.

and at the default 0.35:

> Por supuesto we poder go out y find out qué happened to the hombre at the same
> tiempo, but we tener a lot of work to do ahora mismo.

`Of course`, `a lot of` and `right now` are each matched as one entry rather
than as their component words. `at the same time` and `find out` are not: they
rank 386 and 202, outside a 120-word budget, so the pool does not hold them yet
and their words are swapped singly (`en el same tiempo`, `find fuera`). That is
the budget model working on phrases exactly as it does on words.

The capped version keeps ten of the twenty-nine words in Spanish and spaces them
through the line. `a lot of` is among what it gives up, which is the cap
working: a three-token phrase costs three of the ten.

## What Phase 4 built

The first LLM in the codebase, and the first time the target side of a swap is
something other than the dictionary form.

| Thing | Where |
| --- | --- |
| Provider-agnostic facade: config, budget, retry | `lib/linguaswap/llm.ex` |
| The provider contract | `lib/linguaswap/llm/provider.ex` |
| Claude Messages API (Req, structured outputs) — the default | `lib/linguaswap/llm/provider/anthropic.ex` |
| Any `/v1/chat/completions` service (OpenAI, OpenRouter, Ollama) | `lib/linguaswap/llm/provider/openai_compatible.ex` |
| Rate limit and cost cap in front of every call | `lib/linguaswap/llm/budget.ex` |
| Generation, prompts, and the approve/reject workflow | `lib/linguaswap/dictionary.ex` |
| `--generate` / `--generate-limit` | `lib/mix/tasks/linguaswap.import_words.ex` |
| Review queue at `/dictionary/review` | `lib/linguaswap_web/live/dictionary_review_live.ex` |
| `review_status`, form-shape and POS validation, `servable_forms/1` | `lib/linguaswap/vocabulary/word.ex` |
| `pos` and `forms` served to the client | `lib/linguaswap_web/api_controller.ex` |
| Feature-reporting `analyze/1`, `formKeysFor/2`, `selectForm/2` | `chrome-extension/lemmatizer.js` |
| `words.review_status` + its index | `priv/repo/migrations/20260905120000_add_word_review_status.exs` |

### The four decisions

1. **A form key names the English feature, not the target grammar.** `forms` is
   `%{"past" => "corrió", "gerund" => "corriendo"}` — keyed by what the client
   can *detect*, which is what English did to the page word. Keying it by
   Spanish grammar (preterite vs imperfect, say) would store data the runtime
   has no way to choose between, and choosing is precisely what the runtime is
   not allowed to do (Q4-A). The consequence is honest: every target language
   gets the same seven slots, and a distinction English does not mark is a
   distinction this design cannot serve.

2. **A phrase's form is the whole phrase.** "give up" carries
   `%{"past" => "se rindió"}`, not a head form the client would glue onto a
   tail. Phase 3's note was right that a phrase has a head that inflects and a
   fixed tail — but that split belongs at generation time, where a model can
   see the whole phrase, rather than at runtime where it would be string
   surgery in a content script. `resolvePhrase` reports the head's feature and
   the stored form answers for the span.

3. **`pos` is what resolves the "-s".** English spells the noun plural and the
   third-person verb identically, and the surface gives no clue which is which.
   So `analyze()` reports the deliberately vague feature `"s"`, and
   `formKeysFor("s", pos)` reads it as `plural` on a noun and `third_person` on
   a verb — the one place the ambiguity is resolved, and the reason `pos` is a
   closed set rather than a free-form label.

4. **Generated data is not served until someone approves it.** Rows land as
   `pending` and `Word.servable_forms/1` sends `%{}` for them, so the client
   falls back to the base translation and the page is exactly as good as it was
   before. Rejecting clears the forms rather than hiding them, because a
   rejected form is wrong and leaving it in the row invites a later change to
   start serving it. An entry the generator had nothing to say about — a
   pronoun, a preposition, no forms and no new translation — is approved on the
   spot rather than filling the queue with rows whose only answer is "yes, fine".

### What the generator will and will not touch

It fills `pos` and `forms` always, and `target_translation` and `lemma` only
when they are missing. A rebuilt `en-es.tsv` is hand-checked data, and replacing
it with a model's second opinion is not a decision an import should make on its
own — the existing translation is passed to the model instead, as context, so
the forms it returns agree with it.

`review_status IS NULL` is the marker for "never generated", so every seeded and
imported row queues exactly once and a row that has been through the pipeline
does not come back — whatever a human then decided about it. `Dictionary.requeue/1`
is the way back in.

### What it costs, and why that is not the interesting question

Measured from the real prompts: a batch of 20 entries is ~3,200 characters of
system prompt, entry list and schema (~850 input tokens), and comes back as
~130 characters per entry (~850 output tokens for the batch). The whole
dictionary — 539 en-es plus 98 en-uz — is 32 requests.

| Model | Full run | Halved by the Batch API |
| --- | --- | --- |
| Claude Opus 5, `effort: :low` (the default) | ~$1.15 | ~$0.57 |
| Claude Opus 5, default effort | ~$2.80 | ~$1.40 |
| Claude Sonnet 5, `effort: :low` | ~$0.45 | ~$0.23 |
| Claude Haiku 4.5 | ~$0.16 | ~$0.08 |
| A small non-Anthropic model | ~$0.02–0.17 | half that |

So the entire dictionary costs about a dollar at the top of the range, and the
$5 default cap is three re-runs of headroom rather than a tight constraint.
Two things follow:

1. **Model choice here is a quality decision, not a cost one.** The gap between
   the best and cheapest option is under $1.20 for the whole dictionary, spent
   once. Picking a weaker model to save it, on data a human then has to review
   entry by entry, trades an hour of review time for a dollar.
2. **`effort` matters more than the model.** Thinking tokens bill as output and
   are the largest line in the run — the difference between low and default
   effort on Opus 5 is larger than the difference between Opus 5 and Sonnet 5.
   Filling in dictionary forms is recall, not reasoning, so the config runs it
   at `:low`.

The cost conversation that actually matters belongs to Phase 5. A runtime
sentence-translation path is per page view and per user rather than once per
dictionary: at a thousand sentences a day and a 70% cache hit rate, that is
roughly $8/user/month on Haiku and $15 on Sonnet. Precompute is a one-off
dollar; runtime is a subscription.

### The cost controls

`Linguaswap.LLM.Budget` is the only path to a model, and it holds two limits:

- **Requests per minute** (default 20), a sliding window. Exceeding it returns
  `{:wait, ms}` and the client sleeps, because a batch job that has run out of
  window should pace itself, not fail.
- **A total cost cap** (default $5), for the life of the process — which for a
  `mix` task is the run. Reaching it is an error, not a wait. Cost comes from
  the usage the API reports, priced per model; a model with no price entry is
  billed at zero, so a new model cannot silently spend the cap on a guess.

Generation also walks the dictionary in frequency order and writes each batch as
it lands, so a run stopped by the cap has bought the most useful words first and
kept them.

Two failures stop a run outright rather than repeating once per batch: a missing
API key and an exhausted cap. Everything else — a bad batch, an entry the model
left out — is recorded against the entries it affected and the run continues.

### The provider seam

`Linguaswap.LLM` owns what is the same whoever answers — configuration, the
budget, the rate limit, the retry policy — and `Linguaswap.LLM.Provider` is the
one-callback behaviour for what is not: the URL, the auth header, the request
body, and where in the reply the JSON is. `Linguaswap.Dictionary` never learns
whose model answered it.

Two providers ship. `Provider.Anthropic` is the default and the one the prompts
were written against. `Provider.OpenAICompatible` covers every
`/v1/chat/completions` service in one adapter — OpenAI, OpenRouter, Together,
Groq, a self-hosted vLLM, a local Ollama — because that request shape became the
lingua franca; which one you get is decided by `:base_url` and `:model` alone. A
local Ollama makes the whole pipeline free to re-run, which is what makes
iterating on the prompts cheap.

Each provider normalises its usage report to the same keys, so `Budget` prices
any of them with one table and one piece of arithmetic. A model with no entry in
that table is billed at zero rather than at a guess — the run continues, the cap
just does not move, which is the right failure for a number nobody can verify.

Two differences the seam does not paper over, both documented at the adapter:
OpenAI's `strict: true` demands every property be required and this schema has
optional ones on purpose, so strict mode is off by default and `Dictionary`
re-validates what comes back; and there is no default `:model` for a compatible
endpoint, because the right one depends entirely on which service `:base_url`
points at and a guess would surface as a confusing 404.

**What the seam does not abstract is the prompt.** `Dictionary.system_prompt/1`
asks for lexicographic judgement in a particular voice and has only been checked
against Claude. Switching providers is a config change; trusting the output of
the new one is a review pass over the queue, which is what the queue is for.

### Verified behaviour

The pipeline is covered end to end against a stubbed API (`Req`'s `:plug`
answers in-process, so the suite needs neither a key nor a connection): the
request shape and structured-output schema, refusals, non-JSON replies, cost
accounting, the cap, form sanitising by POS, the review transitions, and the
queue in the LiveView. On the client, `analyze()` reports the right feature for
every suffix rule and every irregular, and a test asserts the two irregular
tables cannot drift apart.

What is **not** verified is generation against the real API: no run has been
made, so every `words.forms` in the repository database is still empty and the
inflected output above is what the code does rather than what a user sees today.
That is a `--generate` away, and it costs money, which is why it is a decision
rather than a step.

## Picking up Phase 5

Three things about the Phase 4 code shape the work:

1. **The LLM plumbing is reusable but not yet a runtime path.** `Linguaswap.LLM`
   is synchronous, unstreamed and budgeted for a batch job. A sentence request
   sits on a page load, so it needs a cache (Q4-C: sentence hash + language
   pair), a timeout the client can survive, and a budget that is per user rather
   than per run. The `Budget` process is the right shape for the second of those
   and the wrong scope; it caps a node, not an account.

2. **The client already segments sentences and knows their density.**
   `markSentences` and `applyDensityCap` compute, per sentence, exactly the
   number Phase 5 needs to threshold on: how much of it *would* be swapped. The
   trigger is that number crossing a line, and the data is already there —
   `applyDensityCap` currently throws away the matches it drops.

3. **The interaction model is the open question, not the swap.** A
   whole-sentence replacement has no per-word entry to hover, reveal or rate, so
   `record_word_reveal` and the rating popup have nothing to attach to. DESIGN
   flagged this as a follow-up and it is still unanswered; it is a product
   decision, and it gates the phase more than the plumbing does.

And the standing risk, unchanged: **en-uz**. Phase 4 can now generate it and the
review queue is where it would be checked, but the gap table's answer is still a
native reviewer, and generating 98 words of Uzbek that nobody can read would
only move the problem into the database.
