import Ecto.Query
alias Linguaswap.Repo
alias Linguaswap.Vocabulary.Word

# Clear existing words to make seeds idempotent
Repo.delete_all(from(w in Word))

en_es_words = [
  %{
    original_word: "the",
    target_translation: "el",
    language_pair: "en-es",
    frequency_rank: 1,
    difficulty_score: 1
  },
  %{
    original_word: "be",
    target_translation: "ser",
    language_pair: "en-es",
    frequency_rank: 2,
    difficulty_score: 2
  },
  %{
    original_word: "to",
    target_translation: "a",
    language_pair: "en-es",
    frequency_rank: 3,
    difficulty_score: 1
  },
  %{
    original_word: "of",
    target_translation: "de",
    language_pair: "en-es",
    frequency_rank: 4,
    difficulty_score: 1
  },
  %{
    original_word: "and",
    target_translation: "y",
    language_pair: "en-es",
    frequency_rank: 5,
    difficulty_score: 1
  },
  %{
    original_word: "a",
    target_translation: "un",
    language_pair: "en-es",
    frequency_rank: 6,
    difficulty_score: 1
  },
  %{
    original_word: "in",
    target_translation: "en",
    language_pair: "en-es",
    frequency_rank: 7,
    difficulty_score: 1
  },
  %{
    original_word: "that",
    target_translation: "que",
    language_pair: "en-es",
    frequency_rank: 8,
    difficulty_score: 2
  },
  %{
    original_word: "have",
    target_translation: "tener",
    language_pair: "en-es",
    frequency_rank: 9,
    difficulty_score: 2
  },
  %{
    original_word: "I",
    target_translation: "yo",
    language_pair: "en-es",
    frequency_rank: 10,
    difficulty_score: 1
  },
  %{
    original_word: "it",
    target_translation: "ello",
    language_pair: "en-es",
    frequency_rank: 11,
    difficulty_score: 1
  },
  %{
    original_word: "for",
    target_translation: "para",
    language_pair: "en-es",
    frequency_rank: 12,
    difficulty_score: 1
  },
  %{
    original_word: "not",
    target_translation: "no",
    language_pair: "en-es",
    frequency_rank: 13,
    difficulty_score: 1
  },
  %{
    original_word: "on",
    target_translation: "en",
    language_pair: "en-es",
    frequency_rank: 14,
    difficulty_score: 1
  },
  %{
    original_word: "with",
    target_translation: "con",
    language_pair: "en-es",
    frequency_rank: 15,
    difficulty_score: 1
  },
  %{
    original_word: "he",
    target_translation: "él",
    language_pair: "en-es",
    frequency_rank: 16,
    difficulty_score: 1
  },
  %{
    original_word: "as",
    target_translation: "como",
    language_pair: "en-es",
    frequency_rank: 17,
    difficulty_score: 2
  },
  %{
    original_word: "you",
    target_translation: "tú",
    language_pair: "en-es",
    frequency_rank: 18,
    difficulty_score: 1
  },
  %{
    original_word: "do",
    target_translation: "hacer",
    language_pair: "en-es",
    frequency_rank: 19,
    difficulty_score: 2
  },
  %{
    original_word: "at",
    target_translation: "en",
    language_pair: "en-es",
    frequency_rank: 20,
    difficulty_score: 1
  },
  %{
    original_word: "this",
    target_translation: "esto",
    language_pair: "en-es",
    frequency_rank: 21,
    difficulty_score: 2
  },
  %{
    original_word: "but",
    target_translation: "pero",
    language_pair: "en-es",
    frequency_rank: 22,
    difficulty_score: 1
  },
  %{
    original_word: "from",
    target_translation: "desde",
    language_pair: "en-es",
    frequency_rank: 23,
    difficulty_score: 2
  },
  %{
    original_word: "or",
    target_translation: "o",
    language_pair: "en-es",
    frequency_rank: 24,
    difficulty_score: 1
  },
  %{
    original_word: "which",
    target_translation: "cuál",
    language_pair: "en-es",
    frequency_rank: 25,
    difficulty_score: 2
  },
  %{
    original_word: "one",
    target_translation: "uno",
    language_pair: "en-es",
    frequency_rank: 26,
    difficulty_score: 1
  },
  %{
    original_word: "would",
    target_translation: "haría",
    language_pair: "en-es",
    frequency_rank: 27,
    difficulty_score: 3
  },
  %{
    original_word: "there",
    target_translation: "allí",
    language_pair: "en-es",
    frequency_rank: 28,
    difficulty_score: 2
  },
  %{
    original_word: "their",
    target_translation: "su",
    language_pair: "en-es",
    frequency_rank: 29,
    difficulty_score: 2
  },
  %{
    original_word: "what",
    target_translation: "qué",
    language_pair: "en-es",
    frequency_rank: 30,
    difficulty_score: 1
  },
  %{
    original_word: "about",
    target_translation: "sobre",
    language_pair: "en-es",
    frequency_rank: 31,
    difficulty_score: 2
  },
  %{
    original_word: "when",
    target_translation: "cuándo",
    language_pair: "en-es",
    frequency_rank: 32,
    difficulty_score: 1
  },
  %{
    original_word: "make",
    target_translation: "hacer",
    language_pair: "en-es",
    frequency_rank: 34,
    difficulty_score: 2
  },
  %{
    original_word: "like",
    target_translation: "gustar",
    language_pair: "en-es",
    frequency_rank: 35,
    difficulty_score: 2
  },
  %{
    original_word: "time",
    target_translation: "tiempo",
    language_pair: "en-es",
    frequency_rank: 36,
    difficulty_score: 1
  },
  %{
    original_word: "just",
    target_translation: "solo",
    language_pair: "en-es",
    frequency_rank: 37,
    difficulty_score: 2
  },
  %{
    original_word: "know",
    target_translation: "saber",
    language_pair: "en-es",
    frequency_rank: 38,
    difficulty_score: 2
  },
  %{
    original_word: "take",
    target_translation: "tomar",
    language_pair: "en-es",
    frequency_rank: 39,
    difficulty_score: 2
  },
  %{
    original_word: "people",
    target_translation: "personas",
    language_pair: "en-es",
    frequency_rank: 40,
    difficulty_score: 1
  },
  %{
    original_word: "into",
    target_translation: "dentro de",
    language_pair: "en-es",
    frequency_rank: 41,
    difficulty_score: 2
  },
  %{
    original_word: "year",
    target_translation: "año",
    language_pair: "en-es",
    frequency_rank: 42,
    difficulty_score: 1
  },
  %{
    original_word: "your",
    target_translation: "tu",
    language_pair: "en-es",
    frequency_rank: 43,
    difficulty_score: 1
  },
  %{
    original_word: "good",
    target_translation: "bueno",
    language_pair: "en-es",
    frequency_rank: 44,
    difficulty_score: 1
  },
  %{
    original_word: "some",
    target_translation: "algunos",
    language_pair: "en-es",
    frequency_rank: 45,
    difficulty_score: 1
  },
  %{
    original_word: "could",
    target_translation: "podría",
    language_pair: "en-es",
    frequency_rank: 46,
    difficulty_score: 3
  },
  %{
    original_word: "them",
    target_translation: "ellos",
    language_pair: "en-es",
    frequency_rank: 47,
    difficulty_score: 1
  },
  %{
    original_word: "see",
    target_translation: "ver",
    language_pair: "en-es",
    frequency_rank: 48,
    difficulty_score: 1
  },
  %{
    original_word: "other",
    target_translation: "otro",
    language_pair: "en-es",
    frequency_rank: 49,
    difficulty_score: 1
  },
  %{
    original_word: "than",
    target_translation: "que",
    language_pair: "en-es",
    frequency_rank: 50,
    difficulty_score: 2
  },
  %{
    original_word: "then",
    target_translation: "entonces",
    language_pair: "en-es",
    frequency_rank: 51,
    difficulty_score: 2
  },
  %{
    original_word: "now",
    target_translation: "ahora",
    language_pair: "en-es",
    frequency_rank: 52,
    difficulty_score: 1
  },
  %{
    original_word: "look",
    target_translation: "mirar",
    language_pair: "en-es",
    frequency_rank: 53,
    difficulty_score: 1
  },
  %{
    original_word: "only",
    target_translation: "solo",
    language_pair: "en-es",
    frequency_rank: 54,
    difficulty_score: 1
  },
  %{
    original_word: "come",
    target_translation: "venir",
    language_pair: "en-es",
    frequency_rank: 55,
    difficulty_score: 2
  },
  %{
    original_word: "its",
    target_translation: "su",
    language_pair: "en-es",
    frequency_rank: 56,
    difficulty_score: 1
  },
  %{
    original_word: "over",
    target_translation: "sobre",
    language_pair: "en-es",
    frequency_rank: 57,
    difficulty_score: 2
  },
  %{
    original_word: "think",
    target_translation: "pensar",
    language_pair: "en-es",
    frequency_rank: 58,
    difficulty_score: 2
  },
  %{
    original_word: "also",
    target_translation: "también",
    language_pair: "en-es",
    frequency_rank: 59,
    difficulty_score: 1
  },
  %{
    original_word: "back",
    target_translation: "espalda",
    language_pair: "en-es",
    frequency_rank: 60,
    difficulty_score: 1
  },
  %{
    original_word: "after",
    target_translation: "después",
    language_pair: "en-es",
    frequency_rank: 61,
    difficulty_score: 2
  },
  %{
    original_word: "use",
    target_translation: "usar",
    language_pair: "en-es",
    frequency_rank: 62,
    difficulty_score: 1
  },
  %{
    original_word: "two",
    target_translation: "dos",
    language_pair: "en-es",
    frequency_rank: 63,
    difficulty_score: 1
  },
  %{
    original_word: "how",
    target_translation: "cómo",
    language_pair: "en-es",
    frequency_rank: 64,
    difficulty_score: 1
  },
  %{
    original_word: "our",
    target_translation: "nuestro",
    language_pair: "en-es",
    frequency_rank: 65,
    difficulty_score: 1
  },
  %{
    original_word: "work",
    target_translation: "trabajo",
    language_pair: "en-es",
    frequency_rank: 66,
    difficulty_score: 1
  },
  %{
    original_word: "first",
    target_translation: "primero",
    language_pair: "en-es",
    frequency_rank: 67,
    difficulty_score: 1
  },
  %{
    original_word: "well",
    target_translation: "bien",
    language_pair: "en-es",
    frequency_rank: 68,
    difficulty_score: 1
  },
  %{
    original_word: "way",
    target_translation: "camino",
    language_pair: "en-es",
    frequency_rank: 69,
    difficulty_score: 1
  },
  %{
    original_word: "even",
    target_translation: "incluso",
    language_pair: "en-es",
    frequency_rank: 70,
    difficulty_score: 2
  },
  %{
    original_word: "new",
    target_translation: "nuevo",
    language_pair: "en-es",
    frequency_rank: 71,
    difficulty_score: 1
  },
  %{
    original_word: "want",
    target_translation: "querer",
    language_pair: "en-es",
    frequency_rank: 72,
    difficulty_score: 2
  },
  %{
    original_word: "because",
    target_translation: "porque",
    language_pair: "en-es",
    frequency_rank: 73,
    difficulty_score: 1
  },
  %{
    original_word: "any",
    target_translation: "cualquier",
    language_pair: "en-es",
    frequency_rank: 74,
    difficulty_score: 1
  },
  %{
    original_word: "these",
    target_translation: "estos",
    language_pair: "en-es",
    frequency_rank: 75,
    difficulty_score: 1
  },
  %{
    original_word: "give",
    target_translation: "dar",
    language_pair: "en-es",
    frequency_rank: 76,
    difficulty_score: 1
  },
  %{
    original_word: "day",
    target_translation: "día",
    language_pair: "en-es",
    frequency_rank: 77,
    difficulty_score: 1
  },
  %{
    original_word: "most",
    target_translation: "más",
    language_pair: "en-es",
    frequency_rank: 78,
    difficulty_score: 1
  },
  %{
    original_word: "find",
    target_translation: "encontrar",
    language_pair: "en-es",
    frequency_rank: 79,
    difficulty_score: 2
  },
  %{
    original_word: "here",
    target_translation: "aquí",
    language_pair: "en-es",
    frequency_rank: 80,
    difficulty_score: 1
  },
  %{
    original_word: "thing",
    target_translation: "cosa",
    language_pair: "en-es",
    frequency_rank: 81,
    difficulty_score: 1
  },
  %{
    original_word: "many",
    target_translation: "muchos",
    language_pair: "en-es",
    frequency_rank: 82,
    difficulty_score: 1
  },
  %{
    original_word: "tell",
    target_translation: "decir",
    language_pair: "en-es",
    frequency_rank: 83,
    difficulty_score: 2
  },
  %{
    original_word: "much",
    target_translation: "mucho",
    language_pair: "en-es",
    frequency_rank: 84,
    difficulty_score: 1
  },
  %{
    original_word: "very",
    target_translation: "muy",
    language_pair: "en-es",
    frequency_rank: 85,
    difficulty_score: 1
  },
  %{
    original_word: "her",
    target_translation: "ella",
    language_pair: "en-es",
    frequency_rank: 86,
    difficulty_score: 1
  },
  %{
    original_word: "still",
    target_translation: "aún",
    language_pair: "en-es",
    frequency_rank: 87,
    difficulty_score: 2
  },
  %{
    original_word: "life",
    target_translation: "vida",
    language_pair: "en-es",
    frequency_rank: 88,
    difficulty_score: 1
  },
  %{
    original_word: "hand",
    target_translation: "mano",
    language_pair: "en-es",
    frequency_rank: 89,
    difficulty_score: 1
  },
  %{
    original_word: "high",
    target_translation: "alto",
    language_pair: "en-es",
    frequency_rank: 90,
    difficulty_score: 1
  },
  %{
    original_word: "keep",
    target_translation: "mantener",
    language_pair: "en-es",
    frequency_rank: 91,
    difficulty_score: 2
  },
  %{
    original_word: "let",
    target_translation: "dejar",
    language_pair: "en-es",
    frequency_rank: 92,
    difficulty_score: 2
  },
  %{
    original_word: "begin",
    target_translation: "empezar",
    language_pair: "en-es",
    frequency_rank: 93,
    difficulty_score: 2
  },
  %{
    original_word: "seem",
    target_translation: "parecer",
    language_pair: "en-es",
    frequency_rank: 94,
    difficulty_score: 2
  },
  %{
    original_word: "help",
    target_translation: "ayuda",
    language_pair: "en-es",
    frequency_rank: 95,
    difficulty_score: 1
  },
  %{
    original_word: "show",
    target_translation: "mostrar",
    language_pair: "en-es",
    frequency_rank: 96,
    difficulty_score: 2
  },
  %{
    original_word: "hear",
    target_translation: "oír",
    language_pair: "en-es",
    frequency_rank: 97,
    difficulty_score: 2
  },
  %{
    original_word: "play",
    target_translation: "jugar",
    language_pair: "en-es",
    frequency_rank: 98,
    difficulty_score: 1
  },
  %{
    original_word: "run",
    target_translation: "correr",
    language_pair: "en-es",
    frequency_rank: 99,
    difficulty_score: 1
  },
  %{
    original_word: "move",
    target_translation: "mover",
    language_pair: "en-es",
    frequency_rank: 100,
    difficulty_score: 2
  }
]

en_uz_words = [
  %{
    original_word: "the",
    target_translation: "the",
    language_pair: "en-uz",
    frequency_rank: 1,
    difficulty_score: 1
  },
  %{
    original_word: "be",
    target_translation: "bo'lish",
    language_pair: "en-uz",
    frequency_rank: 2,
    difficulty_score: 2
  },
  %{
    original_word: "to",
    target_translation: "ga",
    language_pair: "en-uz",
    frequency_rank: 3,
    difficulty_score: 1
  },
  %{
    original_word: "of",
    target_translation: "ning",
    language_pair: "en-uz",
    frequency_rank: 4,
    difficulty_score: 1
  },
  %{
    original_word: "and",
    target_translation: "va",
    language_pair: "en-uz",
    frequency_rank: 5,
    difficulty_score: 1
  },
  %{
    original_word: "a",
    target_translation: "bir",
    language_pair: "en-uz",
    frequency_rank: 6,
    difficulty_score: 1
  },
  %{
    original_word: "in",
    target_translation: "da",
    language_pair: "en-uz",
    frequency_rank: 7,
    difficulty_score: 1
  },
  %{
    original_word: "that",
    target_translation: "bu",
    language_pair: "en-uz",
    frequency_rank: 8,
    difficulty_score: 2
  },
  %{
    original_word: "have",
    target_translation: "ega",
    language_pair: "en-uz",
    frequency_rank: 9,
    difficulty_score: 2
  },
  %{
    original_word: "I",
    target_translation: "men",
    language_pair: "en-uz",
    frequency_rank: 10,
    difficulty_score: 1
  },
  %{
    original_word: "it",
    target_translation: "u",
    language_pair: "en-uz",
    frequency_rank: 11,
    difficulty_score: 1
  },
  %{
    original_word: "for",
    target_translation: "uchun",
    language_pair: "en-uz",
    frequency_rank: 12,
    difficulty_score: 1
  },
  %{
    original_word: "not",
    target_translation: "emas",
    language_pair: "en-uz",
    frequency_rank: 13,
    difficulty_score: 1
  },
  %{
    original_word: "on",
    target_translation: "ustida",
    language_pair: "en-uz",
    frequency_rank: 14,
    difficulty_score: 2
  },
  %{
    original_word: "with",
    target_translation: "bilan",
    language_pair: "en-uz",
    frequency_rank: 15,
    difficulty_score: 1
  },
  %{
    original_word: "he",
    target_translation: "u",
    language_pair: "en-uz",
    frequency_rank: 16,
    difficulty_score: 1
  },
  %{
    original_word: "as",
    target_translation: "sifatida",
    language_pair: "en-uz",
    frequency_rank: 17,
    difficulty_score: 3
  },
  %{
    original_word: "you",
    target_translation: "siz",
    language_pair: "en-uz",
    frequency_rank: 18,
    difficulty_score: 1
  },
  %{
    original_word: "do",
    target_translation: "qilmoq",
    language_pair: "en-uz",
    frequency_rank: 19,
    difficulty_score: 2
  },
  %{
    original_word: "at",
    target_translation: "da",
    language_pair: "en-uz",
    frequency_rank: 20,
    difficulty_score: 1
  },
  %{
    original_word: "this",
    target_translation: "bu",
    language_pair: "en-uz",
    frequency_rank: 21,
    difficulty_score: 1
  },
  %{
    original_word: "but",
    target_translation: "lekin",
    language_pair: "en-uz",
    frequency_rank: 22,
    difficulty_score: 1
  },
  %{
    original_word: "from",
    target_translation: "dan",
    language_pair: "en-uz",
    frequency_rank: 23,
    difficulty_score: 1
  },
  %{
    original_word: "or",
    target_translation: "yoki",
    language_pair: "en-uz",
    frequency_rank: 24,
    difficulty_score: 1
  },
  %{
    original_word: "which",
    target_translation: "qaysi",
    language_pair: "en-uz",
    frequency_rank: 25,
    difficulty_score: 2
  },
  %{
    original_word: "one",
    target_translation: "bir",
    language_pair: "en-uz",
    frequency_rank: 26,
    difficulty_score: 1
  },
  %{
    original_word: "would",
    target_translation: "edi",
    language_pair: "en-uz",
    frequency_rank: 27,
    difficulty_score: 3
  },
  %{
    original_word: "there",
    target_translation: "yerda",
    language_pair: "en-uz",
    frequency_rank: 28,
    difficulty_score: 2
  },
  %{
    original_word: "their",
    target_translation: "ularning",
    language_pair: "en-uz",
    frequency_rank: 29,
    difficulty_score: 2
  },
  %{
    original_word: "what",
    target_translation: "nima",
    language_pair: "en-uz",
    frequency_rank: 30,
    difficulty_score: 1
  },
  %{
    original_word: "about",
    target_translation: "haqida",
    language_pair: "en-uz",
    frequency_rank: 31,
    difficulty_score: 2
  },
  %{
    original_word: "when",
    target_translation: "qachon",
    language_pair: "en-uz",
    frequency_rank: 33,
    difficulty_score: 1
  },
  %{
    original_word: "make",
    target_translation: "qilmoq",
    language_pair: "en-uz",
    frequency_rank: 34,
    difficulty_score: 2
  },
  %{
    original_word: "like",
    target_translation: "yoqmoq",
    language_pair: "en-uz",
    frequency_rank: 35,
    difficulty_score: 2
  },
  %{
    original_word: "time",
    target_translation: "vaqt",
    language_pair: "en-uz",
    frequency_rank: 36,
    difficulty_score: 1
  },
  %{
    original_word: "just",
    target_translation: "shunchaki",
    language_pair: "en-uz",
    frequency_rank: 37,
    difficulty_score: 2
  },
  %{
    original_word: "know",
    target_translation: "bilmok",
    language_pair: "en-uz",
    frequency_rank: 38,
    difficulty_score: 2
  },
  %{
    original_word: "take",
    target_translation: "olmoq",
    language_pair: "en-uz",
    frequency_rank: 39,
    difficulty_score: 2
  },
  %{
    original_word: "people",
    target_translation: "odamlar",
    language_pair: "en-uz",
    frequency_rank: 40,
    difficulty_score: 1
  },
  %{
    original_word: "into",
    target_translation: "ichiga",
    language_pair: "en-uz",
    frequency_rank: 41,
    difficulty_score: 2
  },
  %{
    original_word: "year",
    target_translation: "yil",
    language_pair: "en-uz",
    frequency_rank: 42,
    difficulty_score: 1
  },
  %{
    original_word: "your",
    target_translation: "sening",
    language_pair: "en-uz",
    frequency_rank: 43,
    difficulty_score: 1
  },
  %{
    original_word: "good",
    target_translation: "yaxshi",
    language_pair: "en-uz",
    frequency_rank: 44,
    difficulty_score: 1
  },
  %{
    original_word: "some",
    target_translation: "ba'zi",
    language_pair: "en-uz",
    frequency_rank: 45,
    difficulty_score: 1
  },
  %{
    original_word: "could",
    target_translation: "mumkin",
    language_pair: "en-uz",
    frequency_rank: 46,
    difficulty_score: 3
  },
  %{
    original_word: "them",
    target_translation: "ular",
    language_pair: "en-uz",
    frequency_rank: 47,
    difficulty_score: 1
  },
  %{
    original_word: "see",
    target_translation: "ko'rmok",
    language_pair: "en-uz",
    frequency_rank: 48,
    difficulty_score: 1
  },
  %{
    original_word: "other",
    target_translation: "boshqa",
    language_pair: "en-uz",
    frequency_rank: 49,
    difficulty_score: 1
  },
  %{
    original_word: "than",
    target_translation: "dan",
    language_pair: "en-uz",
    frequency_rank: 50,
    difficulty_score: 2
  },
  %{
    original_word: "then",
    target_translation: "keyin",
    language_pair: "en-uz",
    frequency_rank: 51,
    difficulty_score: 2
  },
  %{
    original_word: "now",
    target_translation: "hozir",
    language_pair: "en-uz",
    frequency_rank: 52,
    difficulty_score: 1
  },
  %{
    original_word: "look",
    target_translation: "qaramoq",
    language_pair: "en-uz",
    frequency_rank: 53,
    difficulty_score: 1
  },
  %{
    original_word: "only",
    target_translation: "faqat",
    language_pair: "en-uz",
    frequency_rank: 54,
    difficulty_score: 1
  },
  %{
    original_word: "come",
    target_translation: "kelmoq",
    language_pair: "en-uz",
    frequency_rank: 55,
    difficulty_score: 2
  },
  %{
    original_word: "its",
    target_translation: "uning",
    language_pair: "en-uz",
    frequency_rank: 56,
    difficulty_score: 1
  },
  %{
    original_word: "over",
    target_translation: "ustida",
    language_pair: "en-uz",
    frequency_rank: 57,
    difficulty_score: 2
  },
  %{
    original_word: "think",
    target_translation: "o'ylamoq",
    language_pair: "en-uz",
    frequency_rank: 58,
    difficulty_score: 2
  },
  %{
    original_word: "also",
    target_translation: "ham",
    language_pair: "en-uz",
    frequency_rank: 59,
    difficulty_score: 1
  },
  %{
    original_word: "back",
    target_translation: "orqa",
    language_pair: "en-uz",
    frequency_rank: 60,
    difficulty_score: 1
  },
  %{
    original_word: "after",
    target_translation: "keyin",
    language_pair: "en-uz",
    frequency_rank: 61,
    difficulty_score: 2
  },
  %{
    original_word: "use",
    target_translation: "ishlatmoq",
    language_pair: "en-uz",
    frequency_rank: 62,
    difficulty_score: 1
  },
  %{
    original_word: "two",
    target_translation: "ikki",
    language_pair: "en-uz",
    frequency_rank: 63,
    difficulty_score: 1
  },
  %{
    original_word: "how",
    target_translation: "qanday",
    language_pair: "en-uz",
    frequency_rank: 64,
    difficulty_score: 1
  },
  %{
    original_word: "our",
    target_translation: "bizning",
    language_pair: "en-uz",
    frequency_rank: 65,
    difficulty_score: 1
  },
  %{
    original_word: "work",
    target_translation: "ish",
    language_pair: "en-uz",
    frequency_rank: 66,
    difficulty_score: 1
  },
  %{
    original_word: "first",
    target_translation: "birinchi",
    language_pair: "en-uz",
    frequency_rank: 67,
    difficulty_score: 1
  },
  %{
    original_word: "well",
    target_translation: "yaxshi",
    language_pair: "en-uz",
    frequency_rank: 68,
    difficulty_score: 1
  },
  %{
    original_word: "way",
    target_translation: "yo'l",
    language_pair: "en-uz",
    frequency_rank: 69,
    difficulty_score: 1
  },
  %{
    original_word: "even",
    target_translation: "hatto",
    language_pair: "en-uz",
    frequency_rank: 70,
    difficulty_score: 2
  },
  %{
    original_word: "new",
    target_translation: "yangi",
    language_pair: "en-uz",
    frequency_rank: 71,
    difficulty_score: 1
  },
  %{
    original_word: "want",
    target_translation: "istamoq",
    language_pair: "en-uz",
    frequency_rank: 72,
    difficulty_score: 2
  },
  %{
    original_word: "because",
    target_translation: "sababli",
    language_pair: "en-uz",
    frequency_rank: 73,
    difficulty_score: 1
  },
  %{
    original_word: "any",
    target_translation: "har qanday",
    language_pair: "en-uz",
    frequency_rank: 74,
    difficulty_score: 1
  },
  %{
    original_word: "these",
    target_translation: "shular",
    language_pair: "en-uz",
    frequency_rank: 75,
    difficulty_score: 1
  },
  %{
    original_word: "give",
    target_translation: "bermoq",
    language_pair: "en-uz",
    frequency_rank: 76,
    difficulty_score: 1
  },
  %{
    original_word: "day",
    target_translation: "kun",
    language_pair: "en-uz",
    frequency_rank: 77,
    difficulty_score: 1
  },
  %{
    original_word: "most",
    target_translation: "ko'p",
    language_pair: "en-uz",
    frequency_rank: 78,
    difficulty_score: 1
  },
  %{
    original_word: "find",
    target_translation: "topmoq",
    language_pair: "en-uz",
    frequency_rank: 79,
    difficulty_score: 2
  },
  %{
    original_word: "here",
    target_translation: "yerda",
    language_pair: "en-uz",
    frequency_rank: 80,
    difficulty_score: 1
  },
  %{
    original_word: "thing",
    target_translation: "narsa",
    language_pair: "en-uz",
    frequency_rank: 81,
    difficulty_score: 1
  },
  %{
    original_word: "many",
    target_translation: "ko'p",
    language_pair: "en-uz",
    frequency_rank: 82,
    difficulty_score: 1
  },
  %{
    original_word: "tell",
    target_translation: "aytmoq",
    language_pair: "en-uz",
    frequency_rank: 83,
    difficulty_score: 2
  },
  %{
    original_word: "very",
    target_translation: "juda",
    language_pair: "en-uz",
    frequency_rank: 85,
    difficulty_score: 1
  },
  %{
    original_word: "her",
    target_translation: "uning",
    language_pair: "en-uz",
    frequency_rank: 86,
    difficulty_score: 1
  },
  %{
    original_word: "still",
    target_translation: "hali",
    language_pair: "en-uz",
    frequency_rank: 87,
    difficulty_score: 2
  },
  %{
    original_word: "life",
    target_translation: "hayot",
    language_pair: "en-uz",
    frequency_rank: 88,
    difficulty_score: 1
  },
  %{
    original_word: "hand",
    target_translation: "qo'l",
    language_pair: "en-uz",
    frequency_rank: 89,
    difficulty_score: 1
  },
  %{
    original_word: "high",
    target_translation: "yuqori",
    language_pair: "en-uz",
    frequency_rank: 90,
    difficulty_score: 1
  },
  %{
    original_word: "keep",
    target_translation: "saqlamoq",
    language_pair: "en-uz",
    frequency_rank: 91,
    difficulty_score: 2
  },
  %{
    original_word: "let",
    target_translation: "qo'ymoq",
    language_pair: "en-uz",
    frequency_rank: 92,
    difficulty_score: 2
  },
  %{
    original_word: "begin",
    target_translation: "boshlamoq",
    language_pair: "en-uz",
    frequency_rank: 93,
    difficulty_score: 2
  },
  %{
    original_word: "seem",
    target_translation: "ko'rinmoq",
    language_pair: "en-uz",
    frequency_rank: 94,
    difficulty_score: 2
  },
  %{
    original_word: "help",
    target_translation: "yordam",
    language_pair: "en-uz",
    frequency_rank: 95,
    difficulty_score: 1
  },
  %{
    original_word: "show",
    target_translation: "ko'rsatmoq",
    language_pair: "en-uz",
    frequency_rank: 96,
    difficulty_score: 2
  },
  %{
    original_word: "hear",
    target_translation: "eshitmoq",
    language_pair: "en-uz",
    frequency_rank: 97,
    difficulty_score: 2
  },
  %{
    original_word: "play",
    target_translation: "o'ynamoq",
    language_pair: "en-uz",
    frequency_rank: 98,
    difficulty_score: 1
  },
  %{
    original_word: "run",
    target_translation: "yugurmoq",
    language_pair: "en-uz",
    frequency_rank: 99,
    difficulty_score: 1
  },
  %{
    original_word: "move",
    target_translation: "ko'chmoq",
    language_pair: "en-uz",
    frequency_rank: 100,
    difficulty_score: 2
  }
]

IO.puts("Seeding #{length(en_es_words)} en-es words and #{length(en_uz_words)} en-uz words...")

Enum.each(en_es_words ++ en_uz_words, fn attrs ->
  %Word{}
  |> Word.changeset(attrs)
  |> Repo.insert!()
end)

IO.puts("Seeds complete!")
