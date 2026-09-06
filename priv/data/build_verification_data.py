"""Builds the target-language resources the verification chain reads.

Usage
-----
    python3 priv/data/build_verification_data.py es
    python3 priv/data/build_verification_data.py zh
    python3 priv/data/build_verification_data.py --all

Writes into priv/verification/:

    <lang>-paradigms.tsv   lemma <TAB> surface <TAB> UniMorph feature bundle
    <lang>-corpus.txt      one attested surface per line, most frequent first

Both are derived data, both are checked in, and both are optional: a missing
file makes its verifier return `:unknown` for every entry rather than failing,
which is the whole point of a three-valued verifier (see
`Linguaswap.Verification.Verifier`).

Why derived data is checked in
------------------------------
The upstream UniMorph dump for Spanish is 50MB and the frequency lists are
600KB each. Checking in the *filtered* files instead — about 1.3MB for Spanish
— means a fresh clone can verify without a network round trip, and means the
confidence floors in `Linguaswap.Languages` describe resources that are
actually present rather than resources someone might have downloaded.

What the filtering keeps
------------------------
Paradigms are cut down twice:

  * to lemmas that appear in the top 30,000 of the target language's frequency
    list, because a learner's dictionary will never gloss to a rarer word than
    that, and
  * to the feature bundles the seven form keys can ask about — third person,
    past, participle, gerund and plural.

The bundles below are deliberately *broader* than the ones
`Linguaswap.Languages.paradigm_features/1` matches against. This file keeps the
raw UniMorph tags and the matching happens in Elixir, so the feature map — the
per-language artefact that actually encodes a linguistic decision — stays in
one place and in the language the app is written in. This script only decides
which rows are worth carrying.

Sources
-------
  * UniMorph: github.com/unimorph/<iso3> — a paradigm per lemma
  * hermitdave/FrequencyWords: OpenSubtitles frequency lists, ~100 languages,
    the same source `build_dictionary.py` already uses for the English side
"""

import os
import sys
import urllib.request

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT_DIR = os.path.join(REPO_ROOT, "priv", "verification")

UNIMORPH = "https://raw.githubusercontent.com/unimorph/{iso3}/master/{iso3}"
FREQUENCY = (
    "https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/"
    "content/2018/{code}/{code}_50k.txt"
)

# Per language: the UniMorph repository (None when there is no usable one) and
# the FrequencyWords directory name.
#
# Uzbek is listed with no paradigm source on purpose rather than by oversight.
# github.com/unimorph/uzb exists, but it is 1,277 rows covering 16 noun lemmas,
# none of which appear anywhere in priv/data/en-uz.tsv, and FrequencyWords has
# no Uzbek list at all. Both tiers are therefore silent for en-uz, which is why
# its confidence floor is set where it is.
LANGUAGES = {
    "es": {"unimorph": "spa", "frequency": "es"},
    "zh": {"unimorph": None, "frequency": "zh_cn"},
    "uz": {"unimorph": None, "frequency": None},
}

# How far down the frequency list a lemma may sit and still get a paradigm.
LEMMA_FREQUENCY_CUTOFF = 30_000

# Rows worth carrying, as sets of UniMorph tags that must all be present.
#
# Wider than the exact bundles Elixir matches, narrow enough that the file stays
# a megabyte rather than seven. The seven form keys only ever ask about a third
# person singular, a participle, a gerund or a plural, so a first person plural
# subjunctive is 40 rows per verb that nothing will ever look up. Adjectives are
# absent entirely: the one adjective question — the comparative — is periphrastic
# in Spanish and is answered by the rule tier, not by a paradigm table.
KEPT_BUNDLES = [
    {"V", "IND", "3", "SG"},  # third person and past both live here
    {"V", "V.PTCP"},  # participles
    {"V", "V.CVB"},  # converbs, which is where the gerund is
    {"N", "PL"},  # noun plurals
]


def fetch(url):
    with urllib.request.urlopen(url) as response:
        return response.read().decode("utf-8", errors="replace")


def frequency_words(text):
    """The surfaces of a FrequencyWords list, most frequent first.

    Lines are `word count`; the count is dropped because attestation is a yes
    or no question. Order is kept so a later tier could weigh it.
    """
    words = []
    seen = set()
    for line in text.splitlines():
        word = line.split(" ")[0].strip()
        if word and word not in seen:
            seen.add(word)
            words.append(word)
    return words


def paradigm_rows(text, lemmas):
    rows = []
    seen = set()
    for line in text.splitlines():
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        lemma, surface, tags = (part.strip() for part in parts)
        if not lemma or not surface or lemma not in lemmas:
            continue
        tag_set = set(tags.split(";"))
        if not any(bundle <= tag_set for bundle in KEPT_BUNDLES):
            continue
        key = (lemma, surface, tags)
        if key in seen:
            continue
        seen.add(key)
        rows.append(key)
    rows.sort()
    return rows


def build(code):
    spec = LANGUAGES[code]
    os.makedirs(OUT_DIR, exist_ok=True)

    words = []
    if spec["frequency"]:
        print(f"{code}: fetching frequency list...")
        words = frequency_words(fetch(FREQUENCY.format(code=spec["frequency"])))
        path = os.path.join(OUT_DIR, f"{code}-corpus.txt")
        with open(path, "w", encoding="utf-8") as out:
            out.write("\n".join(words) + "\n")
        print(f"{code}: wrote {len(words)} attested surfaces to {path}")
    else:
        print(f"{code}: no frequency list upstream, skipping corpus attestation")

    if spec["unimorph"]:
        print(f"{code}: fetching paradigms...")
        lemmas = set(words[:LEMMA_FREQUENCY_CUTOFF])
        rows = paradigm_rows(fetch(UNIMORPH.format(iso3=spec["unimorph"])), lemmas)
        path = os.path.join(OUT_DIR, f"{code}-paradigms.tsv")
        with open(path, "w", encoding="utf-8") as out:
            for lemma, surface, tags in rows:
                out.write(f"{lemma}\t{surface}\t{tags}\n")
        print(f"{code}: wrote {len(rows)} paradigm rows to {path}")
    else:
        print(f"{code}: no usable paradigm source, skipping paradigm lookup")


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0

    codes = sorted(LANGUAGES) if argv[0] == "--all" else argv

    for code in codes:
        if code not in LANGUAGES:
            print(f"unknown language {code!r}; known: {', '.join(sorted(LANGUAGES))}")
            return 1
        build(code)

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
