# Linguaswap

A Chrome extension that helps you learn a new language by gradually replacing words on web pages with their target language translations.

## Prerequisites

- Docker (with Docker Compose v2)

## Getting Started

```bash
# Start all services (app + PostgreSQL)
docker compose up -d

# Run migrations (first time)
docker compose exec app mix ecto.migrate

# Seed vocabulary data (first time)
docker compose exec app mix run priv/repo/seeds.exs

# Open the app
open http://localhost:4000
```

## Development

All commands run inside the Docker container:

```bash
# Run tests
docker compose exec app mix test

# Run precommit checks (compile, format, test)
docker compose exec app mix precommit

# Open an IEx session
docker compose exec app iex -S mix phx.server

# Run a specific test file
docker compose exec app mix test test/linguaswap_web/controllers/page_controller_test.exs
```

## Architecture

- **Backend:** Phoenix 1.8 + PostgreSQL — REST API for the Chrome extension, LiveView dashboard for user progress
- **Chrome extension:** Vanilla JS + Manifest V3 — content script replaces words on pages, popup shows stats
- **LLM integration:** (planned) Word difficulty ranking and translation generation

## Learn more

- [SPEC.md](SPEC.md) — Full product specification
- [Phoenix Guides](https://hexdocs.pm/phoenix/overview.html)
- [Phoenix Framework](https://www.phoenixframework.org/)
