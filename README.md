# Linguaswap

A Chrome extension that helps you learn a new language by gradually replacing words on web pages with their target language translations.

## Status

Phases 0–3 of [ROADMAP.md](ROADMAP.md) are built and tested; **Phase 4 (the LLM
precompute pipeline) is next.**

Working today: sign-in, a per-user pool of words in flight (default 50, refilled
as words graduate), in-page swapping with client-side lemmatization so one entry
covers every inflection, multi-word phrase entries matched longest-first, a
density cap that keeps most of every sentence in English, hover-to-reveal and
Hard/Simple/Easy rating, a progress dashboard, and translated YouTube titles.
The extension reports the swaps it actually made, so a word graduates on real
exposure rather than on having been in the pool while you browsed.

Not yet: inflected output in the target language — the Spanish side is always
the dictionary form — and any LLM involvement. The Spanish dictionary holds 539
entries in corpus frequency order, 45 of them phrases; **Uzbek is still the
original 98-word seed**. ROADMAP.md has the full gap list and what addresses
each.

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
- **LLM integration:** (planned) Word difficulty ranking and translation generation

## Learn more

- [SPEC.md](SPEC.md) — Full product specification
- [DESIGN.md](DESIGN.md) — Design discussion and decisions
- [ROADMAP.md](ROADMAP.md) — Phased development plan
- [Phoenix Guides](https://hexdocs.pm/phoenix/overview.html)
- [Phoenix Framework](https://www.phoenixframework.org/)
