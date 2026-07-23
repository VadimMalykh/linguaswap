# LinguaSwap - Language Learning Chrome Extension

## Progress (as of Mar 2026)

### Completed ✅
- [x] Phoenix 1.8.5 project with LiveView
- [x] PostgreSQL database setup (Docker)
- [x] User authentication (email/password via phx.gen.auth)
- [x] User model with target_language and settings fields
- [x] Word model (vocabulary/translation pairs)
- [x] UserWord model (tracks reveal_count, replacement_count, status)
- [x] PageVisit model (tracks pages visited, time spent)
- [x] REST API endpoints for Chrome extension (`/api/v1/*`)
- [x] LiveView dashboard at `/dashboard`
- [x] Docker setup (Dockerfile + docker-compose.yml)
- [x] Live reload configured (inotify-tools)

### In Progress 🚧
- Chrome extension (not started)

### Next Steps 📋
- Create Chrome extension (manifest, content script, background script)
- Add initial word seed data (en-es, en-uz)
- Test API with extension

---

## Project Overview

**LinguaSwap** is a Chrome extension that helps users learn a new language by gradually replacing words on web pages with their target language translations. As users demonstrate familiarity with words (by not revealing translations), the app progressively increases the target language exposure.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Elixir Backend                         │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐ │
│  │  Phoenix    │  │   LiveView   │  │   LLM Integration   │ │
│  │  API        │  │   Dashboard  │  │   (OpenAI/Anthropic)│ │
│  └─────────────┘  └─────────────┘  └─────────────────────┘ │
│         │                │                    │             │
│  ┌─────────────────────────────────────────────────────────┐│
│  │              PostgreSQL Database                        ││
│  │  - Users, Word Stats, Page History, Settings            ││
│  └─────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                  Chrome Extension                           │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │ Content     │  │ Background  │  │   Popup UI         │  │
│  │ Script      │  │ Script      │  │   (stats/settings) │  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Core Features

### 1. User Authentication
- Email/password registration
- Target language selection (multiple supported)
- Original language auto-detection from page content

### 2. Word Replacement Engine

**Phase 1 (MVP): Word-by-word replacement**
- Replace individual words based on user's learned vocabulary
- Replacement threshold based on "confidence score" (reveal count)

**Phase 2: Sentence-level translation**
- When >50% of page words are in user's vocabulary
- Translate entire sentence to target language
- Replace back original words for unknown vocabulary
- Maintains grammatical correctness

### 3. User Progress Tracking

| Metric | Description |
|--------|-------------|
| `reveal_count` | Times user hovered/clicked to see translation |
| `last_revealed` | Timestamp of last reveal |
| `replacement_count` | Times word was replaced on page |

**Learning Algorithm:**
- New words: Show translation immediately
- Familiar words (reveal_count < 3): Show on hover
- Known words (reveal_count = 0 for 7+ days): Replace silently
- Struggling words (reveal_count > 5): Reduce replacement frequency

### 4. Chrome Extension UI

**On-page word interactions:**
- **Unknown word** (high reveal count): Show both languages, original highlighted
- **Learning word**: Hover to reveal translation
- **Known word** (low/no reveals): Silent replacement, optional hover

**Visual indicators (configurable):**
- Subtle underline color for replacement intensity
- Green = well-known, Yellow = learning, Red = struggling
- Option to disable all visual hints

**Extension popup:**
- Current page stats (words replaced, time spent)
- Quick toggle: Pause/Resume replacement
- Link to dashboard

### 5. LiveView Dashboard

**User Profile:**
- Total words learned
- Daily/weekly/monthly progress charts
- Time spent reading (tracked passively)

**Vocabulary Manager:**
- List of all words with status
- Manual review mode
- Export vocabulary

**Settings:**
- Target language
- Replacement intensity (0-100%)
- Visual hints toggle
- Notification preferences

### 6. LLM Integration

**Purpose:**
- Generate word difficulty rankings for new users
- Provide translations (initial dictionary seed)
- Suggest next words to learn

**Implementation:**
- Real-time API calls for new pages (async, non-blocking)
- Results cached in user
- Fallback to dictionary static dictionary for offline

## Data Models

### User
```
- id
- email
- password_hash
- target_language (e.g., "es", "uz")
- settings (JSONB)
- inserted_at
- updated_at
```

### Word
```
- id
- original_word
- target_translation
- language_pair (e.g., "en-es")
- frequency_rank
- difficulty_score
- inserted_at
```

### UserWord (junction)
```
- id
- user_id
- word_id
- reveal_count (default: 0)
- replacement_count (default: 0)
- last_revealed_at
- status (new/learning/known)
```

### PageVisit
```
- id
- user_id
- url
- words_replaced
- time_spent_seconds
- visited_at
```

## MVP Scope

### Language Pairs
- English → Spanish
- English → Uzbek

### Features (MVP)
- [x] User registration/login
- [x] Basic word replacement (word-by-word) - API ready, extension pending
- [x] Hover-to-reveal translation - API ready, extension pending
- [x] Simple stats (words learned, pages visited) - API + dashboard ready
- [ ] Chrome extension with on/off toggle
- [x] LiveView dashboard with basic stats

### Features (Post-MVP)
- [ ] Sentence-level translation (the "flip" approach)
- [ ] Visual difficulty indicators (color coding)
- [ ] Word difficulty ranking via LLM
- [ ] Progress gamification
- [ ] Browser sync across devices

## Technology Stack

- **Backend:** Elixir 1.19, Phoenix 1.8.5, LiveView
- **Database:** PostgreSQL 16 (Docker)
- **Auth:** Phoenix auth (phx.gen.auth)
- **LLM:** OpenAI API (not yet implemented)
- **Extension:** Vanilla JS + Chrome APIs

## How to Run

```bash
# Start Docker services
cd linguaswap
docker compose up -d

# Run migrations (first time)
docker compose exec app mix ecto.migrate

# Access app
open http://localhost:4000
```

## Open Questions

1. How to handle proper nouns/brand names (should never replace)?
2. What's the minimum word frequency threshold for MVP?
3. Should we integrate with existing spaced repetition systems (Anki)?
4. Rate limiting for LLM calls (cost management)?
