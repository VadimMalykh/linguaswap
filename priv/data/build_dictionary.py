"""Builds priv/data/en-<lang>.tsv from a real corpus frequency list.

Usage
-----
    curl -sSo /tmp/en_50k.txt \
      https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/en/en_50k.txt
    python3 priv/data/build_dictionary.py /tmp/en_50k.txt /tmp/lemmas.txt 500

That writes the English side — one entry per lemma, in corpus frequency order.
The target-language column is authored separately; this script only decides
*which* English words earn a dictionary entry, and in what order.

Why this exists
---------------
The dictionary must agree with the runtime lemmatizer about what counts as a
distinct word. If the list carries both "is" and "be", one of them is dead
weight, because the content script resolves "is" to "be" before it ever looks
anything up. So the reduction is done with the extension's own rules.

Relationship to chrome-extension/lemmatizer.js
---------------------------------------------
`candidates()` below is a port of the JavaScript function of the same name, and
is the one piece here that can drift from it. The tables it depends on
(IRREGULAR, NO_SUFFIX_RULES, MIN_LENGTH) are parsed straight out of the JS
rather than retyped, so those cannot. After changing either copy of
`candidates()`, check them against each other:

    python3 priv/data/build_dictionary.py --dump-candidates /tmp/en_50k.txt /tmp/py.json
    docker compose exec app node priv/data/dump_candidates.js /tmp/en_50k.txt /tmp/js.json
    diff <(python3 -m json.tool /tmp/py.json) <(python3 -m json.tool /tmp/js.json)
"""
import os

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import re, sys, json

JS = open(os.path.join(REPO_ROOT, "chrome-extension/lemmatizer.js")).read()

def js_block(start_marker, open_ch, close_ch):
    i = JS.index(start_marker)
    i = JS.index(open_ch, i)
    depth, j = 0, i
    while True:
        if JS[j] == open_ch: depth += 1
        elif JS[j] == close_ch:
            depth -= 1
            if depth == 0: break
        j += 1
    return JS[i:j + 1]

irregular_src = js_block("const IRREGULAR = {", "{", "}")
IRREGULAR = dict(re.findall(r'(\w+):\s*"(\w+)"', irregular_src))

nosuffix_src = js_block("const NO_SUFFIX_RULES = new Set(", "[", "]")
NO_SUFFIX_RULES = set(re.findall(r'"([^"]+)"', nosuffix_src))

MIN_LENGTH = int(re.search(r"const MIN_LENGTH = (\d+);", JS).group(1))

def ends_with_doubled_consonant(stem):
    if len(stem) < 3: return False
    last, prev = stem[-1], stem[-2]
    return last == prev and last not in "aeiou" and bool(re.match(r"[a-z]", last))

def candidates(surface):
    if not surface: return []
    word = surface.lower()
    out = []

    def add(c):
        if not c or len(c) < MIN_LENGTH: return
        if c == word: return
        if c not in out: out.append(c)

    out.append(word)

    if word in IRREGULAR:
        # Mirrors the JS: the irregular base is pushed directly, bypassing the
        # MIN_LENGTH guard, which is what lets "am" reach the two-letter "be".
        base = IRREGULAR[word]
        if base not in out: out.append(base)
        return out

    if word in NO_SUFFIX_RULES or len(word) < 4: return out

    if word.endswith("ies") and len(word) >= 5: add(word[:-3] + "y")
    if re.search(r"(sses|shes|ches|xes|zes)$", word): add(word[:-2])
    if word.endswith("es") and len(word) >= 5:
        add(word[:-1]); add(word[:-2])
    if word.endswith("s") and not re.search(r"(ss|us|is)$", word): add(word[:-1])

    if word.endswith("ied"): add(word[:-3] + "y")
    if word.endswith("ed"):
        stem = word[:-2]
        add(word[:-1])
        if len(stem) >= MIN_LENGTH:
            add(stem)
            if ends_with_doubled_consonant(stem): add(stem[:-1])

    if word.endswith("ing"):
        stem = word[:-3]
        if len(stem) >= MIN_LENGTH:
            add(stem); add(stem + "e")
            if ends_with_doubled_consonant(stem): add(stem[:-1])

    if word.endswith("ier"): add(word[:-3] + "y")
    if word.endswith("iest"): add(word[:-4] + "y")
    return out

def plural_bases(word):
    """The candidates that come from the plural / third-person rules alone.

    Stripping a plural -s is a different kind of guess from stripping -ed or
    -ing: it cannot reach a shorter word with an unrelated meaning the way
    "need" -> "nee" does. These are trusted without the frequency check, which
    is what keeps the entry at "eye" rather than "eyes" and so lets both forms
    on a page find it.
    """
    out = set()
    if word.endswith("ies") and len(word) >= 5: out.add(word[:-3] + "y")
    if re.search(r"(sses|shes|ches|xes|zes)$", word): out.add(word[:-2])
    if word.endswith("es") and len(word) >= 5:
        out.add(word[:-1]); out.add(word[:-2])
    if word.endswith("s") and not re.search(r"(ss|us|is)$", word): out.add(word[:-1])
    return {b for b in out if len(b) >= MIN_LENGTH}


# A -ed / -ing base is believed only if the corpus shows it is a common word in
# its own right. The two populations separate cleanly: real bases like "arrive"
# (2271) and "decide" (1137) sit near the top, while the junk the suffix rules
# invent — "nee" from "need" (27210), "someth" from "something" (43767) — sits
# far out in the tail.
COMMON_RANK = 5000


def trusted(word, base, rank):
    if word in NO_SUFFIX_RULES: return False
    if base in plural_bases(word): return True
    # Everything else is a -ed / -ing / -ier guess. At runtime it is checked
    # against the dictionary; the only stand-in here is the corpus, so the base
    # has to look like a common word rather than merely appearing somewhere.
    return rank[base] < COMMON_RANK


if __name__ == "__main__":
    if sys.argv[1] == "--dump-candidates":
        # Emits candidates for every corpus word, so the JS can be diffed
        # against this port once the container is available again.
        words = [l.split(" ")[0] for l in open(sys.argv[2]).read().strip().split("\n")]
        words = [w for w in words if re.fullmatch(r"[a-z]+", w or "")]
        out = {w: candidates(w) for w in words}
        json.dump(out, open(sys.argv[3], "w"))
        print(f"dumped {len(out)} candidate lists")
        sys.exit(0)

    FRAGMENTS = {
        "don","didn","doesn","isn","wasn","aren","weren","won","wouldn","couldn",
        "shouldn","cannot","ain","haven","hasn","hadn","mustn","needn","ll","ve",
        "re","em","im","ya","til","tis",
    }
    FILLERS = {
        "uh","um","erm","hmm","mm","mmm","ah","ahh","aah","eh","huh","hm","ha",
        "haha","oooh","ooh","ow","ugh","shh","psst","aw","aww","er","uhh","yah",
        "duh","gah","argh",
    }

    # Subtitle corpora are full of first names. Automatic filtering against a
    # names list was tried and abandoned: the published lists carry "in", "my",
    # "so" and "long" as names, and re-admitting them one by one is a longer
    # list than the names themselves. This is instead the reviewed set of
    # proper nouns actually seen in the top of this corpus, plus two entries
    # the suffix rules get wrong.
    NAMES = {
        "adam", "alex", "ben", "bob", "charlie", "chris", "danny", "dave",
        "david", "eddie", "frank", "george", "harry", "henry", "jack", "james",
        "jimmy", "jim", "joe", "john", "johnny", "jack", "kate", "kevin",
        "lucy", "mary", "michael", "mike", "nick", "paul", "peter", "ray",
        "richard", "robert", "sam", "sarah", "steve", "tom", "tommy", "tony",
        "billy", "bobby", "eric", "jane", "jerry", "julie", "linda", "louis",
        "martin", "matt", "nancy", "oliver", "rachel", "rick", "sally", "susan",
        "victor", "walter", "willie",
        # Places, holidays and nationalities: capitalized in real text, so the
        # proper-noun guard would skip them on the page anyway.
        "america", "american", "england", "english", "france", "french",
        "spain", "spanish", "germany", "german", "china", "chinese", "russia",
        "russian", "italy", "italian", "japan", "japanese", "york", "paris",
        "london", "texas", "california", "christmas", "jesus", "god",
        # Not names: fragments and a bad lemma. "clothes" is the real word;
        # "clothe" is a rare verb no starter dictionary needs.
        "clothe", "ma", "de", "max", "mr", "mrs", "ms", "sir", "lt", "la",
        "yo", "christ", "gonna", "wanna", "gotta", "los", "el", "en", "es",
        "que", "un", "una", "por", "para", "con", "hid",
    }

    lines = open(sys.argv[1]).read().strip().split("\n")
    corpus, order = set(), []
    for line in lines:
        w = line.split(" ")[0]
        if w and re.fullmatch(r"[a-z]+", w):
            corpus.add(w); order.append(w)

    rank = {}
    for i, w in enumerate(order):
        rank.setdefault(w, i)

    kept, kept_set = [], set()
    for word in order:
        if len(word) < 2 and word not in ("a", "i"): continue
        if word in FRAGMENTS or word in FILLERS: continue
        if word in NAMES: continue

        # candidates()[0] is always the surface form, because at runtime an
        # exact dictionary entry must beat a guess. Building the dictionary
        # wants the opposite: collapse to the base, so "is", "are" and "was"
        # all become the single "be" entry.
        #
        # How far to trust a candidate depends on where it came from. The
        # irregular map is hand-curated, so its base is taken outright. The
        # suffix rules are guesses, and at runtime they are checked against the
        # dictionary; here the only stand-in is the corpus, which also contains
        # junk like "someth" and rare words like "nee". So a guessed base has
        # to additionally be MORE frequent than the form it came from — a real
        # lemma almost always is, and "need" -> "nee" is exactly what that
        # rejects.
        if word in IRREGULAR:
            base = IRREGULAR[word]
            lemma = base if base in corpus else word
        else:
            bases = candidates(word)[1:]
            lemma = next(
                (b for b in bases if b in corpus and trusted(word, b, rank)),
                word,
            )

        if lemma in kept_set: continue
        kept_set.add(lemma); kept.append(lemma)

    limit = int(sys.argv[3]) if len(sys.argv) > 3 else 1200
    open(sys.argv[2], "w").write("\n".join(kept[:limit]) + "\n")
    print(f"kept {len(kept)} lemmas from {len(order)} corpus rows")
