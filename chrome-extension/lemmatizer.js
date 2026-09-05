// Token-level text rules for the content script: English lemmatization, the
// proper-noun guard, and the punctuation/casing helpers that keep a swapped
// word looking like the word it replaced.
//
// This file is deliberately free of DOM access so it can be loaded both as a
// content script (exposing `LinguaSwapLemmatizer` on the page's global) and by
// Node for tests (`node --test chrome-extension/test/`).
(function (root, factory) {
  const api = factory();

  if (typeof module === "object" && module.exports) {
    module.exports = api;
  } else {
    root.LinguaSwapLemmatizer = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  // Inflected form -> base form, for words the suffix rules below cannot reach.
  // Irregular verbs first, then irregular plurals and comparatives.
  const IRREGULAR = {
    am: "be", is: "be", are: "be", was: "be", were: "be", been: "be", being: "be",
    has: "have", had: "have", having: "have",
    does: "do", did: "do", done: "do", doing: "do",
    goes: "go", went: "go", gone: "go", going: "go",
    says: "say", said: "say",
    made: "make", took: "take", taken: "take", came: "come",
    saw: "see", seen: "see", knew: "know", known: "know",
    got: "get", gotten: "get", gave: "give", given: "give",
    found: "find", thought: "think", told: "tell",
    became: "become", left: "leave", felt: "feel",
    brought: "bring", began: "begin", begun: "begin",
    kept: "keep", held: "hold", wrote: "write", written: "write",
    stood: "stand", heard: "hear", meant: "mean", met: "meet",
    ran: "run", paid: "pay", sat: "sit", spoke: "speak", spoken: "speak",
    led: "lead", grew: "grow", grown: "grow", lost: "lose",
    fell: "fall", fallen: "fall", sent: "send", built: "build",
    understood: "understand", drew: "draw", drawn: "draw",
    broke: "break", broken: "break", spent: "spend",
    rose: "rise", risen: "rise", drove: "drive", driven: "drive",
    bought: "buy", wore: "wear", worn: "wear",
    chose: "choose", chosen: "choose", ate: "eat", eaten: "eat",
    taught: "teach", caught: "catch", fought: "fight",
    threw: "throw", thrown: "throw", sold: "sell", won: "win",
    forgot: "forget", forgotten: "forget", slept: "sleep",
    sang: "sing", sung: "sing", drank: "drink", drunk: "drink",
    swam: "swim", swum: "swim", woke: "wake", woken: "wake",
    sought: "seek", lay: "lie", laid: "lay",

    children: "child", men: "man", women: "woman",
    feet: "foot", teeth: "tooth", geese: "goose", mice: "mouse",
    lives: "life", wives: "wife", knives: "knife", leaves: "leaf",
    halves: "half", wolves: "wolf", shelves: "shelf", selves: "self",
    thieves: "thief",

    better: "good", best: "good", worse: "bad", worst: "bad",
    farther: "far", farthest: "far", further: "far", furthest: "far",
  };

  // What each irregular form *is*, so the swap can pick the matching target
  // form instead of the base translation (Phase 4). The suffix rules below
  // know this by construction — a word that lost an "-ing" is a gerund — but
  // an irregular carries no evidence of its own, so it is recorded here.
  //
  // The two tables are kept separate rather than merged into one map of
  // objects because `priv/data/build_dictionary.py` parses IRREGULAR out of
  // this file to fold a frequency list onto lemmas, and because a flat
  // word -> base map is easier to read than a nested one. A test asserts every
  // irregular has a feature, which is what keeps them in step.
  //
  // Forms with no target-side equivalent to choose ("am", "are") are `base`:
  // the entry's own translation is the right answer for them.
  const IRREGULAR_FEATURES = {
    am: "base", is: "third_person", are: "base", was: "past", were: "past",
    been: "past_participle", being: "gerund",
    has: "third_person", had: "past", having: "gerund",
    does: "third_person", did: "past", done: "past_participle", doing: "gerund",
    goes: "third_person", went: "past", gone: "past_participle", going: "gerund",
    says: "third_person", said: "past",
    made: "past", took: "past", taken: "past_participle", came: "past",
    saw: "past", seen: "past_participle", knew: "past", known: "past_participle",
    got: "past", gotten: "past_participle", gave: "past", given: "past_participle",
    found: "past", thought: "past", told: "past",
    became: "past", left: "past", felt: "past",
    brought: "past", began: "past", begun: "past_participle",
    kept: "past", held: "past", wrote: "past", written: "past_participle",
    stood: "past", heard: "past", meant: "past", met: "past",
    ran: "past", paid: "past", sat: "past", spoke: "past", spoken: "past_participle",
    led: "past", grew: "past", grown: "past_participle", lost: "past",
    fell: "past", fallen: "past_participle", sent: "past", built: "past",
    understood: "past", drew: "past", drawn: "past_participle",
    broke: "past", broken: "past_participle", spent: "past",
    rose: "past", risen: "past_participle", drove: "past", driven: "past_participle",
    bought: "past", wore: "past", worn: "past_participle",
    chose: "past", chosen: "past_participle", ate: "past", eaten: "past_participle",
    taught: "past", caught: "past", fought: "past",
    threw: "past", thrown: "past_participle", sold: "past", won: "past",
    forgot: "past", forgotten: "past_participle", slept: "past",
    sang: "past", sung: "past_participle", drank: "past", drunk: "past_participle",
    swam: "past", swum: "past_participle", woke: "past", woken: "past_participle",
    sought: "past", lay: "past", laid: "past",

    children: "plural", men: "plural", women: "plural",
    feet: "plural", teeth: "plural", geese: "plural", mice: "plural",
    lives: "plural", wives: "plural", knives: "plural", leaves: "plural",
    halves: "plural", wolves: "plural", shelves: "plural", selves: "plural",
    thieves: "plural",

    better: "comparative", best: "superlative",
    worse: "comparative", worst: "superlative",
    farther: "comparative", farthest: "superlative",
    further: "comparative", furthest: "superlative",
  };

  // Which stored form answers a detected feature, and what to fall back to
  // when the dictionary does not carry it. An English "-s" is deliberately
  // absent: it is either a plural or a third-person verb, and only the entry's
  // part of speech says which, so `formKeyFor` resolves it separately.
  const FORM_KEYS = {
    plural: ["plural"],
    third_person: ["third_person"],
    // A past participle usually reads acceptably as a simple past when the
    // dictionary has no separate entry for it, and "he has broken" with the
    // past form beats "he has break" with the base one.
    past_participle: ["past_participle", "past"],
    past: ["past"],
    gerund: ["gerund"],
    comparative: ["comparative"],
    superlative: ["superlative"],
  };

  // Words whose ending only looks inflected. Stripping it would produce a
  // different, usually much more common dictionary word ("as" -> "a"), and a
  // wrong swap is worse than a missed one.
  const NO_SUFFIX_RULES = new Set([
    "as", "is", "was", "has", "his", "its", "us", "this", "thus",
    "news", "yes", "hers", "ours", "theirs", "series", "species",
    "means", "perhaps", "always", "goods", "stairs", "thanks",
  ]);

  // Capitalized at the start of a sentence, these are still names. Everything
  // else capitalized mid-sentence is caught by position alone.
  const BRANDS = new Set([
    "google", "apple", "amazon", "microsoft", "facebook", "meta", "twitter",
    "youtube", "netflix", "reddit", "tesla", "uber", "nvidia", "intel", "sony",
    "android", "chrome", "safari", "firefox", "windows", "linux", "github",
    "openai", "anthropic", "claude", "wikipedia", "instagram", "tiktok",
    "spotify", "paypal", "samsung", "oracle", "adobe", "disney", "ibm",
  ]);

  // Single letters that are words in their own right, so the capitalization
  // guard must not mistake them for names.
  const COMMON_SINGLE_LETTERS = new Set(["i", "a"]);

  // Longest all-caps run still read as an initialism rather than shouting.
  const MAX_ACRONYM_LENGTH = 3;

  // Shortest stem or candidate we will believe. Two-letter output is where the
  // damaging collisions live: "thing" -> "th" -> "the", "as" -> "a".
  const MIN_LENGTH = 3;

  // Share of a sentence's words a caller may swap when it has no user setting
  // to go by. Roughly a third: enough that a paragraph reads as bilingual,
  // little enough that the English scaffolding holding it together survives.
  const DEFAULT_MAX_DENSITY = 0.35;

  // Order in which matches are given up when the density cap bites. A word the
  // user is still learning earns its place in a crowded sentence ahead of one
  // they are reviewing, which in turn earns it ahead of one they have already
  // mastered and no longer learn anything from.
  const STATUS_PRIORITY = { hard: 0, simple: 1, trivial: 2 };

  // An entry the API sent without a status is treated as review-grade: not the
  // first thing to drop, not the last.
  const DEFAULT_STATUS_PRIORITY = 1;

  function isVowel(ch) {
    return "aeiou".includes(ch);
  }

  function endsWithDoubledConsonant(stem) {
    if (stem.length < 3) return false;
    const last = stem[stem.length - 1];
    const prev = stem[stem.length - 2];
    return last === prev && !isVowel(last) && /[a-z]/.test(last);
  }

  // Every base form worth trying for a surface word, most likely first, each
  // with the English feature the rule that produced it detected. The caller
  // walks the list against the dictionary and takes the first hit, so extra
  // candidates are harmless as long as they are not themselves common words
  // with a different meaning.
  //
  // The feature is what Phase 4 added: knowing that "walked" reached "walk" by
  // losing an "-ed" is what lets the swap put the target's past tense on the
  // page instead of its dictionary form. `"s"` is left deliberately vague —
  // English spells the noun plural and the third-person verb the same way, and
  // only the dictionary entry's part of speech can tell them apart.
  function analyze(surface) {
    if (!surface) return [];

    const word = String(surface).toLowerCase();
    const out = [];
    const seen = new Set();

    function push(base, feature) {
      if (!base || seen.has(base)) return;
      seen.add(base);
      out.push({ base, feature });
    }

    function add(candidate, feature) {
      if (!candidate || candidate.length < MIN_LENGTH) return;
      if (candidate === word) return;
      push(candidate, feature);
    }

    // The surface form itself always wins: dictionary entries are stored by
    // their own spelling, and an exact match needs no guessing. Matching an
    // entry outright means no inflection was stripped, so no form is chosen.
    push(word, "base");

    if (Object.prototype.hasOwnProperty.call(IRREGULAR, word)) {
      push(IRREGULAR[word], IRREGULAR_FEATURES[word] || "base");
      return out;
    }

    if (NO_SUFFIX_RULES.has(word) || word.length < 4) return out;

    // Plurals and third-person singular. Both are "-s" in English; `pos`
    // decides which of the two stored forms answers it.
    if (word.endsWith("ies") && word.length >= 5) {
      add(word.slice(0, -3) + "y", "s");
    }
    if (/(sses|shes|ches|xes|zes)$/.test(word)) {
      add(word.slice(0, -2), "s");
    }
    if (word.endsWith("es") && word.length >= 5) {
      add(word.slice(0, -1), "s");
      add(word.slice(0, -2), "s");
    }
    if (word.endsWith("s") && !/(ss|us|is)$/.test(word)) {
      add(word.slice(0, -1), "s");
    }

    // Past tense and past participle. Regular verbs spell them the same, so
    // the simple past is the feature reported and the participle only comes
    // from the irregular table.
    if (word.endsWith("ied")) {
      add(word.slice(0, -3) + "y", "past");
    }
    if (word.endsWith("ed")) {
      const stem = word.slice(0, -2);
      add(word.slice(0, -1), "past");
      if (stem.length >= MIN_LENGTH) {
        add(stem, "past");
        if (endsWithDoubledConsonant(stem)) add(stem.slice(0, -1), "past");
      }
    }

    // Gerund and present participle.
    if (word.endsWith("ing")) {
      const stem = word.slice(0, -3);
      if (stem.length >= MIN_LENGTH) {
        add(stem, "gerund");
        add(stem + "e", "gerund");
        if (endsWithDoubledConsonant(stem)) add(stem.slice(0, -1), "gerund");
      }
    }

    // Comparatives and superlatives, limited to the -y forms. Bare -er/-est
    // stripping is left out on purpose: it turns "corner" into "corn" and
    // "flower" into "flow".
    if (word.endsWith("ier")) {
      add(word.slice(0, -3) + "y", "comparative");
    }
    if (word.endsWith("iest")) {
      add(word.slice(0, -4) + "y", "superlative");
    }

    return out;
  }

  // The base forms of `analyze`, for callers that only want to look a word up.
  function candidates(surface) {
    return analyze(surface).map((candidate) => candidate.base);
  }

  // The stored form key a detected feature asks for, in fallback order, or an
  // empty list when nothing should be substituted. This is the one place the
  // English "-s" ambiguity is resolved, and it needs the entry's part of
  // speech to do it: "runs" is a third-person verb, "walls" is a plural noun,
  // and the surface gives no clue which.
  function formKeysFor(feature, pos) {
    if (feature === "s") {
      if (pos === "noun") return FORM_KEYS.plural;
      if (pos === "verb") return FORM_KEYS.third_person;
      return [];
    }

    return FORM_KEYS[feature] || [];
  }

  // The target text that belongs in the page's slot: the stored form matching
  // what English did to the word, or the entry's base translation when the
  // dictionary has nothing better. Every swap goes through here, so an entry
  // with no `forms` behaves exactly as it did before Phase 4.
  function selectForm(entry, feature) {
    if (!entry) return "";

    const forms = entry.forms;
    if (forms) {
      for (const key of formKeysFor(feature, entry.pos)) {
        const form = forms[key];
        if (typeof form === "string" && form) return form;
      }
    }

    return entry.translation;
  }

  // Splits a whitespace-delimited segment into the punctuation around it and
  // the word itself, so a swap can put the punctuation back untouched.
  function splitToken(segment) {
    const text = String(segment == null ? "" : segment);
    const match = text.match(/^([^\p{L}\p{N}']*)(.*?)([^\p{L}\p{N}']*)$/u);

    if (!match) return { prefix: "", core: text, suffix: "" };
    return { prefix: match[1], core: match[2], suffix: match[3] };
  }

  // Carries the replaced word's capitalization over to the translation, so a
  // sentence-initial or shouted word does not come back lowercase.
  function applyCase(source, translation) {
    if (!source || !translation) return translation;

    if (source.length > 1 && source === source.toUpperCase() && source !== source.toLowerCase()) {
      return translation.toUpperCase();
    }

    const first = source[0];
    if (first === first.toUpperCase() && first !== first.toLowerCase()) {
      return translation[0].toUpperCase() + translation.slice(1);
    }

    return translation;
  }

  // True for tokens that are names rather than vocabulary. Capitalization only
  // means something away from a sentence start, so the caller has to say where
  // the token sits; at a sentence start only known brand names are caught.
  function isProperNoun(core, atSentenceStart) {
    if (!core) return false;

    const lower = core.toLowerCase();
    if (COMMON_SINGLE_LETTERS.has(lower) && core.length === 1) return false;

    // All caps is either an initialism or shouting. Short ones are initialisms
    // often enough — and collide with common words like "US" and "IT" — so they
    // are left alone; longer ones are treated as ordinary words, which is what
    // makes headline text translatable.
    if (core.length > 1 && core === core.toUpperCase() && core !== core.toLowerCase()) {
      return core.length <= MAX_ACRONYM_LENGTH;
    }

    const first = core[0];
    const capitalized = first === first.toUpperCase() && first !== first.toLowerCase();
    if (!capitalized) return false;

    return atSentenceStart ? BRANDS.has(lower) : true;
  }

  // Whether a token following `previousSegment` opens a new sentence. A null
  // or empty predecessor means the token is first in its text node, which we
  // treat as a sentence start: headings, links and list items have no leading
  // punctuation to go by.
  function startsSentence(previousSegment) {
    if (previousSegment == null) return true;

    const previous = String(previousSegment).trim();
    if (!previous) return true;

    return /[.!?:;…][)"'”’\]]*$/.test(previous);
  }

  // Splits text into the units the passes below work on: whitespace runs, kept
  // verbatim so the text round-trips, and word tokens already broken into the
  // punctuation around them.
  function tokenizeItems(text) {
    const items = [];

    for (const raw of String(text == null ? "" : text).split(/(\s+)/)) {
      if (!raw) continue;

      if (/^\s+$/.test(raw)) {
        items.push({ raw, space: true });
        continue;
      }

      const { prefix, core, suffix } = splitToken(raw);
      items.push({ raw, space: false, prefix, core, suffix });
    }

    return items;
  }

  // Groups word tokens into sentences and records which ones open a sentence.
  // The density cap is per sentence, so every token needs to know which one it
  // belongs to before anything is chosen.
  function markSentences(words) {
    let previousRaw = null;
    let sentence = 0;

    words.forEach((word, index) => {
      word.atSentenceStart = startsSentence(previousRaw);
      if (word.atSentenceStart && index > 0) sentence += 1;
      word.sentence = sentence;
      previousRaw = word.raw;
    });
  }

  // Resolves a run of `length` word tokens starting at `start`, or null.
  //
  // A hit is `{entry, feature}`: the dictionary entry, and what English had
  // done to the word that reached it, which decides which stored form the swap
  // will use.
  //
  // A phrase entry has to match an uninterrupted run of words: punctuation
  // between them ends it, so "a lot, of them" never reaches the "a lot of"
  // entry. Any name in the run disqualifies the whole phrase, for the same
  // reason a name disqualifies a single token.
  function matchAt(words, start, length, lookup) {
    const span = words.slice(start, start + length);

    for (let k = 0; k < span.length; k++) {
      const word = span[k];
      if (!word.core) return null;
      if (isProperNoun(word.core, word.atSentenceStart)) return null;
      if (k > 0 && word.prefix) return null;
      if (k < span.length - 1 && word.suffix) return null;
    }

    if (length === 1) return resolve(span[0].core, lookup);

    return resolvePhrase(span.map((word) => word.core), lookup);
  }

  // English phrases inflect on their head, and the head is almost always the
  // first word: "gave up", "looks after", "took care of". So only the first
  // token is lemmatized and the rest are matched as they stand, which keeps the
  // number of lookups per position small and bounded.
  function resolvePhrase(cores, lookup) {
    const tail = cores
      .slice(1)
      .map((core) => core.toLowerCase())
      .join(" ");

    for (const candidate of analyze(cores[0])) {
      const entry = lookup(candidate.base + " " + tail);
      // The head's feature is the phrase's: "gave up" is a past tense, and the
      // stored form for it is the whole phrase in the past.
      if (entry) return { entry, feature: candidate.feature };
    }

    return null;
  }

  // Longest match wins, left to right: at each position the longest phrase that
  // resolves is taken and its tokens are consumed, so "a lot of" beats the "a"
  // entry that starts at the same place.
  function findMatches(words, lookup, maxPhraseTokens) {
    const matches = [];
    let index = 0;

    while (index < words.length) {
      const limit = Math.min(maxPhraseTokens, words.length - index);
      let found = null;

      for (let length = limit; length >= 1 && !found; length--) {
        const hit = matchAt(words, index, length, lookup);
        if (hit) found = { start: index, length, entry: hit.entry, feature: hit.feature };
      }

      if (found) {
        matches.push(found);
        index += found.length;
      } else {
        index += 1;
      }
    }

    return matches;
  }

  function priorityOf(entry) {
    const rank = STATUS_PRIORITY[entry && entry.status];
    return rank === undefined ? DEFAULT_STATUS_PRIORITY : rank;
  }

  // How far a candidate sits from the nearest swap already committed in its own
  // sentence. A sentence nothing has been committed to yet scores infinite, so
  // every sentence gets its first swap before any sentence gets a second.
  function spacingScore(match, words, positions) {
    const chosen = positions.get(words[match.start].sentence);
    if (!chosen || chosen.length === 0) return Infinity;

    let nearest = Infinity;
    for (const position of chosen) nearest = Math.min(nearest, Math.abs(position - match.start));
    return nearest;
  }

  // Drops matches until no sentence exceeds `maxDensity` of its own words, and
  // spreads what survives across the sentence.
  //
  // This is the "decide, then commit" half of the tokenizer: matching above is
  // positional and greedy, choosing among the matches is neither. Two rules, in
  // that order.
  //
  // Priority first. A word the user is still learning is kept ahead of one they
  // are reviewing, which is kept ahead of one they have already mastered, so
  // what survives a crowded sentence is the part that still teaches them
  // something.
  //
  // Spacing second. Within one priority the obvious tie-break is reading order,
  // and it is the wrong one: it translates the front of a long sentence solid
  // and leaves the back untouched, which moves the pidgin rather than removing
  // it, and strips away the English context that makes a swapped word guessable
  // — the whole reason for reading this way. So each pick goes to the candidate
  // sitting farthest from anything already swapped in its sentence, which
  // spaces the swaps out however many of them there are.
  //
  // A phrase spends its whole token count, because three English words becoming
  // one Spanish phrase is three words of the sentence the reader no longer has.
  function applyDensityCap(matches, words, maxDensity) {
    if (maxDensity == null) return matches;
    if (!(maxDensity > 0)) return [];

    const totals = new Map();
    for (const word of words) {
      if (!word.core) continue;
      totals.set(word.sentence, (totals.get(word.sentence) || 0) + 1);
    }

    const allowance = new Map();
    for (const [sentence, total] of totals) {
      // Never zero: a heading, a link or a list item is a whole "sentence" of
      // one or two words, and rounding it down to no swaps would silence the
      // short text that makes up most of a real page.
      allowance.set(sentence, Math.max(1, Math.floor(total * maxDensity)));
    }

    const spent = new Map();
    const positions = new Map();
    const kept = new Set();

    const ranked = matches
      .map((match, index) => ({ match, index }))
      .sort((a, b) => priorityOf(a.match.entry) - priorityOf(b.match.entry) || a.index - b.index);

    // Equal priorities are adjacent after that sort, so a tier can be drained
    // before the next one is looked at: spacing never reorders across priority.
    let tierStart = 0;

    while (tierStart < ranked.length) {
      const tier = priorityOf(ranked[tierStart].match.entry);
      let tierEnd = tierStart;
      while (tierEnd < ranked.length && priorityOf(ranked[tierEnd].match.entry) === tier) tierEnd++;

      const pending = ranked.slice(tierStart, tierEnd);
      tierStart = tierEnd;

      while (pending.length) {
        let best = 0;
        let bestScore = -1;

        for (let k = 0; k < pending.length; k++) {
          const score = spacingScore(pending[k].match, words, positions);
          if (score > bestScore) {
            bestScore = score;
            best = k;
          }
        }

        const { match, index } = pending.splice(best, 1)[0];
        const sentence = words[match.start].sentence;
        const used = spent.get(sentence) || 0;

        if (used + match.length > (allowance.get(sentence) || 0)) continue;

        spent.set(sentence, used + match.length);
        if (!positions.has(sentence)) positions.set(sentence, []);
        positions.get(sentence).push(match.start);
        kept.add(index);
      }
    }

    return matches.filter((_match, index) => kept.has(index));
  }

  // Turns the surviving matches back into the neutral `parts` contract, with
  // every item not covered by a match passed through verbatim.
  function buildParts(items, words, matches) {
    const byItem = new Map();
    for (const match of matches) byItem.set(words[match.start].itemIndex, match);

    const parts = [];
    let matched = false;
    let index = 0;

    while (index < items.length) {
      const match = byItem.get(index);

      if (!match) {
        parts.push({ type: "text", text: items[index].raw });
        index += 1;
        continue;
      }

      const first = words[match.start];
      const last = words[match.start + match.length - 1];

      // The page's own spacing between the phrase's words is part of what a
      // reveal has to put back, so the raw items are re-joined rather than
      // rebuilt from the cores.
      let joined = "";
      for (let k = index; k <= last.itemIndex; k++) joined += items[k].raw;
      const core = joined.slice(first.prefix.length, joined.length - last.suffix.length);

      parts.push({
        type: "swap",
        prefix: first.prefix,
        core,
        suffix: last.suffix,
        entry: match.entry,
        // What English did to the matched word, kept on the part so a caller
        // can see why a particular form was chosen.
        feature: match.feature,
        tokens: match.length,
        display: applyCase(first.core, selectForm(match.entry, match.feature)),
      });

      matched = true;
      index = last.itemIndex + 1;
    }

    return { parts, matched };
  }

  // Walks a run of text and decides what to swap. Returns neutral parts rather
  // than strings or DOM nodes so the page walker and the title translator can
  // share one set of rules: `text` parts are passed through untouched, `swap`
  // parts carry the dictionary entry plus the punctuation and casing that must
  // survive the replacement.
  //
  // `lookup` takes a candidate base form and returns the dictionary entry for
  // it (anything with a `translation`), or null. Phrase entries are looked up
  // by their words joined with single spaces, lowercased. An entry may also
  // carry `pos` and a `forms` map of target-side inflections; when it does,
  // the swap uses the form matching what English did to the page word rather
  // than the base translation.
  //
  // Options:
  //
  //   * `maxPhraseTokens` — longest phrase entry the dictionary holds. Defaults
  //     to 1, which makes the n-gram pass a no-op, so a caller that has not
  //     been told about phrases behaves exactly as it did before them.
  //   * `maxDensity` — the share of a sentence's words that may be swapped.
  //     Defaults to no cap: how much of a page to translate is policy, and it
  //     belongs to the caller that knows the user's settings, not to the
  //     tokenizer. `DEFAULT_MAX_DENSITY` is exported for callers with no
  //     setting to hand.
  //
  // A caveat that matters on real pages: the unit here is one run of text, and
  // markup splits sentences. In `<p>Some <b>bold</b> text.</p>` the walker sees
  // three runs, so the cap applies three times over. It bounds each fragment
  // rather than the rendered sentence, which is conservative in the direction
  // that matters — no fragment is ever swapped wholesale — but it is not exact.
  function segmentText(text, lookup, options) {
    const opts = options || {};
    const maxPhraseTokens = Math.max(1, opts.maxPhraseTokens || 1);
    const maxDensity = opts.maxDensity == null ? null : Number(opts.maxDensity);

    const items = tokenizeItems(text);
    const words = [];

    items.forEach((item, itemIndex) => {
      if (item.space) return;
      item.itemIndex = itemIndex;
      words.push(item);
    });

    markSentences(words);

    const matches = findMatches(words, lookup, maxPhraseTokens);

    return buildParts(items, words, applyDensityCap(matches, words, maxDensity));
  }

  function resolve(core, lookup) {
    for (const candidate of analyze(core)) {
      const entry = lookup(candidate.base);
      if (entry) return { entry, feature: candidate.feature };
    }
    return null;
  }

  // Renders segmented parts back to a plain string, for callers that replace
  // text wholesale instead of wrapping each word.
  function renderParts(parts) {
    return parts
      .map((part) => (part.type === "swap" ? part.prefix + part.display + part.suffix : part.text))
      .join("");
  }

  return {
    analyze,
    candidates,
    formKeysFor,
    selectForm,
    splitToken,
    applyCase,
    isProperNoun,
    startsSentence,
    segmentText,
    renderParts,
    DEFAULT_MAX_DENSITY,
    IRREGULAR,
    IRREGULAR_FEATURES,
    BRANDS,
  };
});
