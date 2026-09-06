# Linguaswap

A Chrome extension that helps you learn a new language by gradually replacing words on web pages with their target language translations.

## Status

Phases 0–4 of [ROADMAP.md](ROADMAP.md) are built and tested; **Phase 5
(sentence-level swap) is next.**

Working today: sign-in, a per-user pool of words in flight (default 50, refilled
as words graduate), in-page swapping with client-side lemmatization so one entry
covers every inflection, multi-word phrase entries matched longest-first, a
density cap that keeps most of every sentence in English, hover-to-reveal and
Hard/Simple/Easy rating, a progress dashboard, and translated YouTube titles.
The extension reports the swaps it actually made, so a word graduates on real
exposure rather than on having been in the pool while you browsed.

The target side is inflected rather than always the dictionary form: "she was
running" comes out as "she era corriendo", because the client tells the server
*which* inflection it found and picks the matching stored form. Those forms are
generated with the Claude API at import time, and nothing generated is shown on
a page until a human approves it on the dashboard.

Not yet: whole-sentence translation, and any LLM call at page-load time — the
runtime is still a dumb, fast client over precomputed data. The Spanish
dictionary holds 539 entries in corpus frequency order, 45 of them phrases;
**Uzbek is still the original 98-word seed**.

**The per-entry approval step is being replaced.** It assumes a reviewer who
reads the target language, and it caps the dictionary at whatever a human can
face reading — which is why it stopped near 500. Phase 4.5 puts a chain of
automated verifiers in front of the queue (paradigm lookup, corpus attestation,
round-trip analysis, cross-model consensus) and leaves the human only the
residue those cannot settle. ROADMAP.md has the design and the full gap list.

## Prerequisites

- Docker (with Docker Compose v2)

## Getting Started

```bash
# Start all services (app + PostgreSQL)
docker compose up -d

# Run migrations (first time)
docker compose exec app mix ecto.migrate

# Seed vocabulary data from priv/data/*.tsv (first time; safe to re-run)
docker compose exec app mix run priv/repo/seeds.exs

# Import a larger word list for one language pair
docker compose exec app mix linguaswap.import_words priv/data/en-es.tsv

# Re-importing a REBUILT list needs --prune: the import upserts, so entries
# dropped from the file otherwise linger and compete for frontier slots.
# Entries a user has progress on are reported, never deleted.
docker compose exec app mix linguaswap.import_words priv/data/en-es.tsv --prune

# Rebuild the English side of a dictionary from a corpus frequency list.
# Writes the word list only; the translation column is authored by hand.
# See the module docstring for the corpus URL and the JS cross-check.
python3 priv/data/build_dictionary.py /tmp/en_50k.txt /tmp/lemmas.txt 500

# Open the app
open http://localhost:4000
```

## Generating the inflected forms

The dictionary ships with translations but no target-side inflections, so the
Spanish side of a swap is the base form until this is run. It calls the Claude
API. Measured cost: **$0.03 per 20 entries**, so about **$0.80 for the whole
539-entry Spanish dictionary**.

**1. Put your API key in `.env`** (gitignored; Compose reads it automatically):

```bash
cp .env.example .env
$EDITOR .env          # ANTHROPIC_API_KEY=sk-ant-...
docker compose up -d  # recreate the container so it picks the key up
```

Get a key from [console.anthropic.com](https://console.anthropic.com/settings/keys).
An `export ANTHROPIC_API_KEY=...` in your shell works too — Compose prefers the
shell over `.env`.

**2. Generate and review** at
[localhost:4000/dictionary/review](http://localhost:4000/dictionary/review).
Pick a language pair, choose how many entries, and the button tells you what it
will cost before you press it. Progress is live, a run can be stopped after the
batch it is in, and what it actually cost is reported when it finishes. Nothing
generated is put on a page until you approve it in the queue below.

A run belongs to the server rather than to the page: closing the tab does not
abandon it, and re-opening rejoins the run in progress.

**Or from the command line**, which does the same thing after an import:

```bash
docker compose exec app mix linguaswap.import_words \
  priv/data/en-es.tsv --generate --generate-limit 40
```

Dev logs every SQL statement, so pipe it if you want to read the result:
`... 2>&1 | grep -vE '^(SELECT|INSERT|UPDATE|begin|commit)|QUERY'`.

Notes:

- **Re-running the importer is safe.** It upserts, and it does not touch `pos`,
  `forms` or the review status, so a re-import never undoes a generation run.
- **An entry is only ever generated once.** Rows already generated for are
  skipped, so a second run picks up where the first stopped.
- **Only one run at a time.** Two would race for the same entries and pay for
  them twice.
- **Every run is bounded twice**: by how many entries you asked for, and by a
  $5 cost cap (`LINGUASWAP_LLM_COST_CAP_USD`) that stops it when spent. It works
  in frequency order, so a run cut short has still done the most useful words.
- **A wrong key stops the run on the first request**, and so does a first batch
  that produces nothing — rather than failing once per batch for the whole
  dictionary.

The default model is **Claude Opus 4.8**, not Opus 5: Opus 5's safety
classifiers decline this workload outright (see `config/config.exs`). To use a
different model or vendor, see `Linguaswap.LLM.Provider` — any OpenAI-compatible
endpoint, including a local Ollama, is a config change.

Then load the extension: open `chrome://extensions`, turn on **Developer mode**,
choose **Load unpacked**, and pick the `chrome-extension/` directory. Register an
account at `localhost:4000`, then sign in again from the extension popup.

The extension talks to `http://localhost:4000` by default. To point it at a
deployed backend, use the **Server** field in the popup — saving asks Chrome for
permission to reach that host, which is why it cannot be set from a config file
alone.

Reload the extension from that same page whenever `manifest.json` changes or a
file is added to `chrome-extension/` — refreshing the web page is not enough.

## Development

All commands run inside the Docker container:

```bash
# Run tests. -e MIX_ENV=test is required: docker-compose.yml pins MIX_ENV=dev,
# which otherwise overrides the task default and the run fails.
docker compose exec -e MIX_ENV=test app mix test

# Run precommit checks (compile, format, test)
docker compose exec -e MIX_ENV=test app mix precommit

# Run a specific test file
docker compose exec -e MIX_ENV=test app mix test test/linguaswap/vocabulary_test.exs

# Run the Chrome extension's JS tests (quote the glob so the shell keeps it)
docker compose exec app node --test 'chrome-extension/test/*.test.js'

# Open an IEx session
docker compose exec app iex -S mix phx.server
```

## Architecture

- **Backend:** Phoenix 1.8 + PostgreSQL — REST API for the Chrome extension, LiveView dashboard for user progress
- **Chrome extension:** Vanilla JS + Manifest V3 — content script replaces words on pages, popup shows stats. Page text is lemmatized client-side (`lemmatizer.js`) so one dictionary entry covers every inflection
- **LLM integration:** `Linguaswap.LLM` generates part of speech, translations
  and target-side inflected forms at import time. The vendor sits behind
  `Linguaswap.LLM.Provider`: `…Provider.Anthropic` (the default, Claude Messages
  API over `Req` — Elixir has no official Anthropic SDK) and
  `…Provider.OpenAICompatible` (any `/v1/chat/completions` service — OpenAI,
  OpenRouter, a local Ollama), chosen by one config key.
  `Linguaswap.LLM.Budget` caps what a run may spend and paces its requests;
  `Linguaswap.Dictionary` owns generation and the approve/reject workflow.
  A dashboard page at `/dictionary/review` drives generation and review together.
  Measured cost: $0.03 per 20 entries on Claude Opus 4.8 — see ROADMAP.md

## Learn more

- [SPEC.md](SPEC.md) — Full product specification
- [DESIGN.md](DESIGN.md) — Design discussion and decisions
- [ROADMAP.md](ROADMAP.md) — Phased development plan
- [Phoenix Guides](https://hexdocs.pm/phoenix/overview.html)
- [Phoenix Framework](https://www.phoenixframework.org/)
