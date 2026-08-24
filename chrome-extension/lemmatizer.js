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

  function isVowel(ch) {
    return "aeiou".includes(ch);
  }

  function endsWithDoubledConsonant(stem) {
    if (stem.length < 3) return false;
    const last = stem[stem.length - 1];
    const prev = stem[stem.length - 2];
    return last === prev && !isVowel(last) && /[a-z]/.test(last);
  }

  // Every base form worth trying for a surface word, most likely first. The
  // caller walks the list against the dictionary and takes the first hit, so
  // extra candidates are harmless as long as they are not themselves common
  // words with a different meaning.
  function candidates(surface) {
    if (!surface) return [];

    const word = String(surface).toLowerCase();
    const out = [];

    function add(candidate) {
      if (!candidate || candidate.length < MIN_LENGTH) return;
      if (candidate === word) return;
      if (!out.includes(candidate)) out.push(candidate);
    }

    // The surface form itself always wins: dictionary entries are stored by
    // their own spelling, and an exact match needs no guessing.
    out.push(word);

    if (Object.prototype.hasOwnProperty.call(IRREGULAR, word)) {
      const base = IRREGULAR[word];
      if (!out.includes(base)) out.push(base);
      return out;
    }

    if (NO_SUFFIX_RULES.has(word) || word.length < 4) return out;

    // Plurals and third-person singular.
    if (word.endsWith("ies") && word.length >= 5) {
      add(word.slice(0, -3) + "y");
    }
    if (/(sses|shes|ches|xes|zes)$/.test(word)) {
      add(word.slice(0, -2));
    }
    if (word.endsWith("es") && word.length >= 5) {
      add(word.slice(0, -1));
      add(word.slice(0, -2));
    }
    if (word.endsWith("s") && !/(ss|us|is)$/.test(word)) {
      add(word.slice(0, -1));
    }

    // Past tense and past participle.
    if (word.endsWith("ied")) {
      add(word.slice(0, -3) + "y");
    }
    if (word.endsWith("ed")) {
      const stem = word.slice(0, -2);
      add(word.slice(0, -1));
      if (stem.length >= MIN_LENGTH) {
        add(stem);
        if (endsWithDoubledConsonant(stem)) add(stem.slice(0, -1));
      }
    }

    // Gerund and present participle.
    if (word.endsWith("ing")) {
      const stem = word.slice(0, -3);
      if (stem.length >= MIN_LENGTH) {
        add(stem);
        add(stem + "e");
        if (endsWithDoubledConsonant(stem)) add(stem.slice(0, -1));
      }
    }

    // Comparatives and superlatives, limited to the -y forms. Bare -er/-est
    // stripping is left out on purpose: it turns "corner" into "corn" and
    // "flower" into "flow".
    if (word.endsWith("ier")) {
      add(word.slice(0, -3) + "y");
    }
    if (word.endsWith("iest")) {
      add(word.slice(0, -4) + "y");
    }

    return out;
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

  // Walks a run of text and decides, token by token, what to swap. Returns
  // neutral parts rather than strings or DOM nodes so the page walker and the
  // title translator can share one set of rules: `text` parts are passed
  // through untouched, `swap` parts carry the dictionary entry plus the
  // punctuation and casing that must survive the replacement.
  //
  // `lookup` takes a candidate base form and returns the dictionary entry for
  // it (anything with a `translation`), or null.
  function segmentText(text, lookup) {
    const parts = [];
    let matched = false;
    let previousSegment = null;

    for (const segment of String(text == null ? "" : text).split(/(\s+)/)) {
      if (!segment) continue;

      if (/^\s+$/.test(segment)) {
        parts.push({ type: "text", text: segment });
        continue;
      }

      const { prefix, core, suffix } = splitToken(segment);
      const atSentenceStart = startsSentence(previousSegment);
      previousSegment = segment;

      const entry = core && !isProperNoun(core, atSentenceStart) ? resolve(core, lookup) : null;

      if (entry) {
        matched = true;
        parts.push({
          type: "swap",
          prefix,
          core,
          suffix,
          entry,
          display: applyCase(core, entry.translation),
        });
      } else {
        parts.push({ type: "text", text: segment });
      }
    }

    return { parts, matched };
  }

  function resolve(core, lookup) {
    for (const candidate of candidates(core)) {
      const entry = lookup(candidate);
      if (entry) return entry;
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
    candidates,
    splitToken,
    applyCase,
    isProperNoun,
    startsSentence,
    segmentText,
    renderParts,
    IRREGULAR,
    BRANDS,
  };
});
