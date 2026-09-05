const test = require("node:test");
const assert = require("node:assert");

const lemmatizer = require("../lemmatizer.js");
const { candidates, splitToken, applyCase, isProperNoun, startsSentence } = lemmatizer;

// Mirrors how the content script uses the candidate list: first hit wins.
function lookup(dictionary, surface) {
  for (const candidate of candidates(surface)) {
    if (dictionary.has(candidate)) return candidate;
  }
  return null;
}

test("the surface form is always tried first", () => {
  assert.strictEqual(candidates("run")[0], "run");
  assert.strictEqual(candidates("Running")[0], "running");
});

test("regular verb inflections reach the base form", () => {
  const dict = new Set(["run", "walk", "stop", "make", "come", "use", "study", "carry", "watch"]);

  assert.strictEqual(lookup(dict, "running"), "run");
  assert.strictEqual(lookup(dict, "runs"), "run");
  assert.strictEqual(lookup(dict, "walked"), "walk");
  assert.strictEqual(lookup(dict, "walking"), "walk");
  assert.strictEqual(lookup(dict, "stopped"), "stop");
  assert.strictEqual(lookup(dict, "stopping"), "stop");
  assert.strictEqual(lookup(dict, "making"), "make");
  assert.strictEqual(lookup(dict, "makes"), "make");
  assert.strictEqual(lookup(dict, "coming"), "come");
  assert.strictEqual(lookup(dict, "used"), "use");
  assert.strictEqual(lookup(dict, "studied"), "study");
  assert.strictEqual(lookup(dict, "studies"), "study");
  assert.strictEqual(lookup(dict, "carries"), "carry");
  assert.strictEqual(lookup(dict, "watches"), "watch");
});

test("plurals reach the singular", () => {
  const dict = new Set(["word", "box", "city", "day", "child", "man", "life"]);

  assert.strictEqual(lookup(dict, "words"), "word");
  assert.strictEqual(lookup(dict, "boxes"), "box");
  assert.strictEqual(lookup(dict, "cities"), "city");
  assert.strictEqual(lookup(dict, "days"), "day");
  assert.strictEqual(lookup(dict, "children"), "child");
  assert.strictEqual(lookup(dict, "men"), "man");
  assert.strictEqual(lookup(dict, "lives"), "life");
});

test("irregular verbs reach the base form", () => {
  const dict = new Set(["be", "have", "go", "take", "think", "eat", "good"]);

  assert.strictEqual(lookup(dict, "was"), "be");
  assert.strictEqual(lookup(dict, "been"), "be");
  assert.strictEqual(lookup(dict, "has"), "have");
  assert.strictEqual(lookup(dict, "went"), "go");
  assert.strictEqual(lookup(dict, "taken"), "take");
  assert.strictEqual(lookup(dict, "thought"), "think");
  assert.strictEqual(lookup(dict, "ate"), "eat");
  assert.strictEqual(lookup(dict, "better"), "good");
});

test("an irregular form never falls through to the suffix rules", () => {
  // "does" must not be offered as "doe"; the irregular map is the last word.
  assert.deepStrictEqual(candidates("does"), ["does", "do"]);
  assert.deepStrictEqual(candidates("lives"), ["lives", "life"]);
});

test("short function words are not stripped into commoner words", () => {
  const dict = new Set(["a", "i", "it", "the", "on", "hi", "do", "new"]);

  // Each of these once produced a wrong, very common word.
  assert.strictEqual(lookup(dict, "as"), null);
  assert.strictEqual(lookup(dict, "is"), null);
  assert.strictEqual(lookup(dict, "its"), null);
  assert.strictEqual(lookup(dict, "his"), null);
  assert.strictEqual(lookup(dict, "thing"), null);
  assert.strictEqual(lookup(dict, "news"), null);
  assert.strictEqual(lookup(dict, "this"), null);
  assert.strictEqual(lookup(dict, "us"), null);
});

test("bare -er and -est are left alone", () => {
  const dict = new Set(["corn", "flow", "numb", "happy"]);

  assert.strictEqual(lookup(dict, "corner"), null);
  assert.strictEqual(lookup(dict, "flower"), null);
  assert.strictEqual(lookup(dict, "number"), null);
  // The -y forms are safe enough to keep.
  assert.strictEqual(lookup(dict, "happier"), "happy");
  assert.strictEqual(lookup(dict, "happiest"), "happy");
});

test("splitToken keeps punctuation apart from the word", () => {
  assert.deepStrictEqual(splitToken("world"), { prefix: "", core: "world", suffix: "" });
  assert.deepStrictEqual(splitToken("world,"), { prefix: "", core: "world", suffix: "," });
  assert.deepStrictEqual(splitToken('"world"'), { prefix: '"', core: "world", suffix: '"' });
  assert.deepStrictEqual(splitToken("(world)."), { prefix: "(", core: "world", suffix: ")." });
  assert.deepStrictEqual(splitToken("don't"), { prefix: "", core: "don't", suffix: "" });
  assert.deepStrictEqual(splitToken("—"), { prefix: "—", core: "", suffix: "" });
  assert.deepStrictEqual(splitToken("café."), { prefix: "", core: "café", suffix: "." });
});

test("applyCase carries the replaced word's capitalization over", () => {
  assert.strictEqual(applyCase("world", "mundo"), "mundo");
  assert.strictEqual(applyCase("World", "mundo"), "Mundo");
  assert.strictEqual(applyCase("WORLD", "mundo"), "MUNDO");
  // A single capital is a sentence start, not shouting.
  assert.strictEqual(applyCase("A", "un"), "Un");
});

test("proper nouns are only swapped when capitalization is explained", () => {
  // Mid-sentence capitals are names.
  assert.strictEqual(isProperNoun("Paris", false), true);
  assert.strictEqual(isProperNoun("USA", false), true);
  assert.strictEqual(isProperNoun("USA", true), true);
  // Long all-caps is shouting, not an initialism.
  assert.strictEqual(isProperNoun("WATER", false), false);
  // At a sentence start, capitalization says nothing.
  assert.strictEqual(isProperNoun("The", true), false);
  assert.strictEqual(isProperNoun("world", false), false);
  // Except for names we know.
  assert.strictEqual(isProperNoun("Apple", true), true);
  assert.strictEqual(isProperNoun("Windows", true), true);
  // "I" and "A" are words, not initials.
  assert.strictEqual(isProperNoun("I", false), false);
  assert.strictEqual(isProperNoun("A", false), false);
});

test("startsSentence reads the preceding token", () => {
  assert.strictEqual(startsSentence(null), true);
  assert.strictEqual(startsSentence(""), true);
  assert.strictEqual(startsSentence("word"), false);
  assert.strictEqual(startsSentence("end."), true);
  assert.strictEqual(startsSentence("really?"), true);
  assert.strictEqual(startsSentence('said."'), true);
  assert.strictEqual(startsSentence("e.g."), true);
});

// A dictionary shaped like the one the API sends: entries keyed by spelling
// and by lemma, sharing one object per entry. A phrase entry is keyed by its
// words joined with single spaces, which is what the tokenizer looks up.
//
// Three spellings for an entry, in rising detail:
//   word: "translation"
//   word: [translation, status]           — a status other than "hard"
//   word: { translation, pos, forms }     — the Phase 4 fields as well
function dictionary(entries) {
  const map = {};
  for (const [word, spec] of Object.entries(entries)) {
    if (spec && typeof spec === "object" && !Array.isArray(spec)) {
      map[word] = Object.assign({ original: word, status: "hard" }, spec);
      continue;
    }

    const [translation, status] = Array.isArray(spec) ? spec : [spec, "hard"];
    map[word] = { original: word, translation, status };
  }
  return (candidate) => map[candidate] || null;
}

function swap(text, entries, options) {
  const { parts, matched } = lemmatizer.segmentText(text, dictionary(entries), options);
  return { text: lemmatizer.renderParts(parts), matched, parts };
}

// The dictionaries below carry phrases, so the caller has to say how long the
// longest one is — exactly as the content script does from `token_count`.
const PHRASES = { maxPhraseTokens: 3 };

test("segmentText swaps inflected forms through their lemma", () => {
  const { text } = swap("She was running and he stopped.", {
    be: "ser",
    run: "correr",
    stop: "parar",
  });

  assert.strictEqual(text, "She ser correr and he parar.");
});

test("segmentText keeps punctuation outside the swap", () => {
  const { text, parts } = swap('He said, "the word."', { word: "palabra", the: "el" });

  assert.strictEqual(text, 'He said, "el palabra."');

  const swapped = parts.filter((p) => p.type === "swap");
  assert.deepStrictEqual(
    swapped.map((p) => [p.prefix, p.core, p.suffix]),
    [['"', "the", ""], ["", "word", '."']]
  );
});

test("segmentText carries capitalization onto the translation", () => {
  assert.strictEqual(swap("Water is cold.", { water: "agua" }).text, "Agua is cold.");
  assert.strictEqual(swap("drink WATER now", { water: "agua" }).text, "drink AGUA now");
});

test("segmentText leaves names alone but not sentence-initial words", () => {
  const dict = { apple: "manzana", the: "el", world: "mundo", may: "mayo" };

  // Mid-sentence capital: a name.
  assert.strictEqual(swap("I ate an Apple today", dict).text, "I ate an Apple today");
  // Sentence-initial capital of a brand: still a name.
  assert.strictEqual(swap("Apple shipped it.", dict).text, "Apple shipped it.");
  // Sentence-initial ordinary word: swapped, with its capital kept.
  assert.strictEqual(swap("The end.", dict).text, "El end.");
  // A new sentence starts after terminal punctuation.
  assert.strictEqual(swap("Yes. The end.", dict).text, "Yes. El end.");
  // Acronyms are never vocabulary.
  assert.strictEqual(swap("the USA today", dict).text, "el USA today");
});

test("segmentText reports whether anything was swapped", () => {
  assert.strictEqual(swap("nothing here matches", { word: "palabra" }).matched, false);
  assert.strictEqual(swap("one word here", { word: "palabra" }).matched, true);
});

test("segmentText round-trips text it does not change", () => {
  const original = "  Spacing,   punctuation — and (parentheses) stay put.  ";
  assert.strictEqual(swap(original, {}).text, original);
});

test("a swap part carries the entry the API knows, not the page form", () => {
  const { parts } = swap("running fast", { run: "correr" });
  const swapped = parts.find((p) => p.type === "swap");

  assert.strictEqual(swapped.core, "running");
  assert.strictEqual(swapped.entry.original, "run");
  assert.strictEqual(swapped.display, "correr");
});

test("a phrase beats the single words inside it", () => {
  const dict = { "a lot of": "muchos", a: "un", lot: "montón", of: "de", time: "tiempo" };

  assert.strictEqual(swap("I need a lot of time", dict, PHRASES).text, "I need muchos tiempo");
});

test("a phrase matches through its head's inflection", () => {
  // English phrases inflect on the head, which is the first word here.
  const dict = { "give up": "rendirse", "look for": "buscar" };

  assert.strictEqual(swap("He gave up", dict, PHRASES).text, "He rendirse");
  assert.strictEqual(swap("She gives up", dict, PHRASES).text, "She rendirse");
  assert.strictEqual(swap("They looked for it", dict, PHRASES).text, "They buscar it");
});

test("a phrase carries the page's own spacing into the reveal", () => {
  const { parts } = swap("say a  lot   of things", { "a lot of": "muchos" }, PHRASES);
  const swapped = parts.find((p) => p.type === "swap");

  assert.strictEqual(swapped.core, "a  lot   of");
  assert.strictEqual(swapped.tokens, 3);
});

test("punctuation inside a run stops a phrase from matching", () => {
  const dict = { "a lot of": "muchos" };

  assert.strictEqual(swap("a lot, of them", dict, PHRASES).matched, false);
  assert.strictEqual(swap("a lot (of) them", dict, PHRASES).matched, false);
});

test("a name anywhere in a run stops a phrase from matching", () => {
  const dict = { "out of": "fuera de", out: "fuera" };

  // "Africa" is a name, so "out of Africa" is not offered as a phrase; the
  // shorter "out of" still is.
  assert.strictEqual(swap("straight out of Africa", dict, PHRASES).text, "straight fuera de Africa");
});

test("phrases are invisible to a caller that does not ask for them", () => {
  // The default keeps a pre-phrase caller behaving exactly as it did.
  const dict = { "a lot of": "muchos", a: "un" };

  assert.strictEqual(swap("a lot of time", dict).text, "un lot of time");
});

test("segmentText is uncapped unless the caller sets a density", () => {
  const dict = { one: "uno", two: "dos", three: "tres", four: "cuatro" };

  assert.strictEqual(swap("one two three four", dict).text, "uno dos tres cuatro");
});

test("the density cap leaves most of a sentence in English", () => {
  const dict = {
    one: "uno", two: "dos", three: "tres", four: "cuatro", five: "cinco",
    six: "seis", seven: "siete", eight: "ocho", nine: "nueve", ten: "diez",
  };

  // Ten words at 30% is three swaps, and they are spread across the sentence
  // rather than taken in reading order: a solid Spanish opening followed by a
  // solid English tail is the pidgin the cap exists to prevent, and it would
  // leave the swapped words with no English context to be guessed from.
  assert.strictEqual(
    swap("one two three four five six seven eight nine ten", dict, { maxDensity: 0.3 }).text,
    "uno two three four cinco six seven eight nine diez"
  );
});

test("priority still outranks spacing", () => {
  const dict = {
    one: ["uno", "trivial"],
    two: ["dos", "hard"],
    three: ["tres", "hard"],
    four: ["cuatro", "trivial"],
    five: ["cinco", "trivial"],
    six: ["seis", "trivial"],
  };

  // Six words at 35% is two swaps. Both go to the words still being learned
  // even though they sit next to each other, because spacing only ever breaks
  // a tie inside one priority.
  assert.strictEqual(
    swap("one two three four five six", dict, { maxDensity: 0.35 }).text,
    "one dos tres four five six"
  );
});

test("the cap gives up mastered words before words still being learned", () => {
  const dict = {
    one: ["uno", "trivial"],
    two: ["dos", "trivial"],
    three: ["tres", "hard"],
    four: ["cuatro", "simple"],
  };

  // Four words at 25% is one swap, and it goes to the word the user is still
  // learning rather than to the first one on the line.
  assert.strictEqual(swap("one two three four", dict, { maxDensity: 0.25 }).text, "one two tres four");
});

test("the cap counts every word a phrase covers", () => {
  const dict = { "a lot of": "muchos", time: "tiempo", here: "aquí" };

  // Five words at 60% is three swaps, and the phrase spends all three: three
  // English words became one Spanish phrase.
  assert.strictEqual(
    swap("a lot of time here", dict, { maxDensity: 0.6, maxPhraseTokens: 3 }).text,
    "muchos time here"
  );
});

test("each sentence gets its own share of swaps", () => {
  const dict = { one: "uno", two: "dos", three: "tres", four: "cuatro" };

  assert.strictEqual(
    swap("one two three four. one two three four.", dict, { maxDensity: 0.25 }).text,
    "uno two three four. uno two three four."
  );
});

test("a short fragment still gets one swap", () => {
  // Headings, links and list items are one- and two-word "sentences". Rounding
  // them down to nothing would silence most of a real page.
  const dict = { home: "inicio", the: "el", end: "fin" };

  assert.strictEqual(swap("Home", dict, { maxDensity: 0.3 }).text, "Inicio");
  assert.strictEqual(swap("The end", dict, { maxDensity: 0.3 }).text, "El end");
});

test("a density of zero swaps nothing", () => {
  const dict = { one: "uno", two: "dos" };
  const result = swap("one two", dict, { maxDensity: 0 });

  assert.strictEqual(result.text, "one two");
  assert.strictEqual(result.matched, false);
});

// --- Inflected target forms (Phase 4) -------------------------------------
//
// The lemmatizer reports *why* a surface word reached its entry, and the swap
// uses that to pick a stored target form instead of the dictionary one.

const { analyze, formKeysFor, selectForm, IRREGULAR, IRREGULAR_FEATURES } = lemmatizer;

// The feature attached to the candidate that reached `base`, or undefined when
// the word never reaches it.
function featureFor(surface, base) {
  const hit = analyze(surface).find((candidate) => candidate.base === base);
  return hit && hit.feature;
}

test("analyze reports which rule reached a base form", () => {
  assert.strictEqual(featureFor("run", "run"), "base");
  assert.strictEqual(featureFor("running", "run"), "gerund");
  assert.strictEqual(featureFor("walked", "walk"), "past");
  assert.strictEqual(featureFor("studied", "study"), "past");
  assert.strictEqual(featureFor("happier", "happy"), "comparative");
  assert.strictEqual(featureFor("happiest", "happy"), "superlative");
});

test("analyze leaves an English -s unresolved", () => {
  // Nothing about the surface says whether "-s" is a plural or a verb ending;
  // only the entry's part of speech can decide, so the feature stays vague.
  assert.strictEqual(featureFor("walls", "wall"), "s");
  assert.strictEqual(featureFor("runs", "run"), "s");
  assert.strictEqual(featureFor("cities", "city"), "s");
});

test("analyze knows what each irregular form is", () => {
  assert.strictEqual(featureFor("was", "be"), "past");
  assert.strictEqual(featureFor("been", "be"), "past_participle");
  assert.strictEqual(featureFor("being", "be"), "gerund");
  assert.strictEqual(featureFor("is", "be"), "third_person");
  assert.strictEqual(featureFor("children", "child"), "plural");
  assert.strictEqual(featureFor("better", "good"), "comparative");
  assert.strictEqual(featureFor("worst", "bad"), "superlative");
});

test("every irregular carries a feature", () => {
  // The two tables are separate so the dictionary builder can keep parsing
  // IRREGULAR; this is what keeps them from drifting apart.
  const missing = Object.keys(IRREGULAR).filter((word) => !IRREGULAR_FEATURES[word]);
  assert.deepStrictEqual(missing, []);

  const extra = Object.keys(IRREGULAR_FEATURES).filter((word) => !IRREGULAR[word]);
  assert.deepStrictEqual(extra, []);
});

test("an -s is a plural on a noun and a verb ending on a verb", () => {
  assert.deepStrictEqual(formKeysFor("s", "noun"), ["plural"]);
  assert.deepStrictEqual(formKeysFor("s", "verb"), ["third_person"]);
  // Neither reading applies to anything else, so nothing is substituted.
  assert.deepStrictEqual(formKeysFor("s", "preposition"), []);
  assert.deepStrictEqual(formKeysFor("s", null), []);
});

test("a past participle falls back to the past form", () => {
  const entry = { translation: "romper", pos: "verb", forms: { past: "rompió" } };

  assert.strictEqual(selectForm(entry, "past_participle"), "rompió");
});

test("selectForm falls back to the base translation", () => {
  const entry = { translation: "correr", pos: "verb", forms: { past: "corrió" } };

  assert.strictEqual(selectForm(entry, "base"), "correr");
  assert.strictEqual(selectForm(entry, "gerund"), "correr");
  assert.strictEqual(selectForm({ translation: "correr" }, "past"), "correr");
});

test("the swap puts the inflected form on the page", () => {
  const { text } = swap("She was running and he walked.", {
    be: { translation: "ser", pos: "verb", forms: { past: "era", gerund: "siendo" } },
    run: { translation: "correr", pos: "verb", forms: { gerund: "corriendo" } },
    walk: { translation: "caminar", pos: "verb", forms: { past: "caminó" } },
  });

  // The whole point of Phase 4: "she era corriendo", not "she ser correr".
  assert.strictEqual(text, "She era corriendo and he caminó.");
});

test("a plural noun and a third-person verb are told apart by part of speech", () => {
  const dict = {
    wall: { translation: "pared", pos: "noun", forms: { plural: "paredes" } },
    run: { translation: "correr", pos: "verb", forms: { third_person: "corre" } },
  };

  assert.strictEqual(swap("walls", dict).text, "paredes");
  assert.strictEqual(swap("runs", dict).text, "corre");
});

test("an entry with no forms behaves exactly as it did before", () => {
  const { text } = swap("She was running.", { be: "ser", run: "correr" });

  assert.strictEqual(text, "She ser correr.");
});

test("a phrase inflects as a whole", () => {
  // The head carries the tense and the tail is fixed, so the stored form is
  // the whole phrase — the client never glues one onto the other.
  const dict = {
    "give up": { translation: "rendirse", pos: "verb", forms: { past: "se rindió" } },
  };

  assert.strictEqual(swap("He gave up.", dict, PHRASES).text, "He se rindió.");
  assert.strictEqual(swap("He will give up.", dict, PHRASES).text, "He will rendirse.");
});

test("capitalization carries onto the chosen form", () => {
  const dict = { be: { translation: "ser", pos: "verb", forms: { past: "era" } } };

  assert.strictEqual(swap("Was it here?", dict).text, "Era it here?");
});

test("a swap part records the feature it matched on", () => {
  const dict = { run: { translation: "correr", pos: "verb", forms: { past: "corrió" } } };
  const { parts } = swap("He ran.", dict);
  const swapped = parts.find((part) => part.type === "swap");

  assert.strictEqual(swapped.feature, "past");
  assert.strictEqual(swapped.display, "corrió");
  // The entry itself is unchanged, so reporting the swap still names the entry
  // the dictionary was keyed on rather than the form shown.
  assert.strictEqual(swapped.entry.original, "run");
});
