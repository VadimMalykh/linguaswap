defmodule Linguaswap.LanguagesTest do
  use ExUnit.Case, async: true

  alias Linguaswap.Languages
  alias Linguaswap.Verification
  alias Linguaswap.Vocabulary.Word

  test "every language pair the app serves has a declaration" do
    for pair <- Word.language_pairs() do
      {source, target} = Languages.split(pair)

      assert source in Languages.known(), "no declaration for source language #{source}"
      assert target in Languages.known(), "no declaration for target language #{target}"
    end
  end

  test "an undeclared language gets the strictest floor rather than a generous one" do
    # A pair nobody has declared has no resources by definition, so the safe
    # reading of "we know nothing about this language" is that nothing
    # auto-approves.
    assert Languages.confidence_floor("en-xx") == 1
    assert Languages.paradigm_features("en-xx") == %{}
    assert Languages.rules("en-xx") == nil
  end

  # The floor is only meaningful next to what is actually on disk: a floor of 3
  # is a lie if tiers 1 to 3 have nothing to say. These assertions are the point
  # where the declaration and the data files have to agree, and they are what
  # fails if a data file is deleted or a floor is moved without one.
  describe "the floors match the resources that exist" do
    test "Spanish can settle morphology from data, so it approves at tier 3" do
      assert Languages.confidence_floor("en-es") == 3

      for {verifier, available?} <- Verification.availability("en-es"), verifier.tier() <= 3 do
        assert available?,
               "#{verifier.name()} has no data for en-es but the floor assumes it does"
      end
    end

    test "Chinese has no morphology to check, so only the round trip can speak" do
      # Chinese does not inflect: `forms` is empty for every entry and the only
      # claim worth verifying is the translation, which no local tier will
      # confirm. Hence a floor of 4.
      assert Languages.confidence_floor("en-zh") == 4
      assert Languages.paradigm_features("en-zh") == %{}
      assert Languages.romanization("en-zh") == :pinyin
      assert Languages.romanized?("en-zh")
    end

    test "Uzbek has no resources at all, and a floor that admits it" do
      # Not caution for its own sake. github.com/unimorph/uzb is 1,277 rows over
      # 16 noun lemmas, none of which appear in priv/data/en-uz.tsv, and
      # FrequencyWords has no Uzbek list. A floor of 2 with nothing at tiers 1
      # or 2 means en-uz auto-approves nothing and says so.
      assert Languages.confidence_floor("en-uz") == 2

      for {verifier, available?} <- Verification.availability("en-uz"), verifier.tier() <= 2 do
        refute available?, "#{verifier.name()} unexpectedly has data for en-uz"
      end
    end

    test "only a target with a non-Latin script asks for a pronunciation" do
      refute Languages.romanized?("en-es")
      refute Languages.romanized?("en-uz")
    end
  end
end
