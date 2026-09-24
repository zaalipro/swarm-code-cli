defmodule SwarmCodeCLI.UI.Pass72HintTest do
  @moduledoc """
  Pass 72 (P7, K1-K4): hint mode's badges. `Hint.labels/1` is pure and
  property tested: no forbidden key in any label, needs-you agents first,
  digits for runs, prefix-free two-letter labels past fifteen agents.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SwarmCodeCLI.UI.Hint

  @forbidden ~w(y a Y A d D n q ?)

  defp id do
    StreamData.string(:alphanumeric, min_length: 1, max_length: 6)
  end

  defp entry do
    StreamData.one_of([
      StreamData.map(id(), &{:run, "r" <> &1}),
      StreamData.map(
        StreamData.tuple({id(), id(), StreamData.boolean()}),
        fn {run, node, needs?} -> {:agent, "r" <> run, "n" <> node, needs?} end
      )
    ])
  end

  property "no label contains a forbidden key, and every label is unique and prefix-free" do
    check all(entries <- StreamData.list_of(entry(), max_length: 260), max_runs: 150) do
      labels = Hint.labels(entries)
      keys = Map.keys(labels)

      for label <- keys,
          grapheme <- String.graphemes(label),
          do: refute(grapheme in @forbidden, "#{inspect(label)} has #{grapheme}")

      letter_labels = Enum.reject(keys, &(&1 =~ ~r/^[0-9]$/))

      for a <- letter_labels,
          b <- letter_labels,
          a != b,
          do: refute(String.starts_with?(b, a), "#{a} is a prefix of #{b}")

      assert length(Enum.uniq(Map.values(labels))) == map_size(labels)
    end
  end

  property "agents that need you get the first letters, each group in panel order" do
    check all(entries <- StreamData.list_of(entry(), max_length: 40), max_runs: 150) do
      labels = Hint.labels(entries)

      agents =
        entries
        |> Enum.flat_map(fn
          {:agent, run, node, needs?} -> [{{:agent, run, node}, needs?}]
          _ -> []
        end)
        |> Enum.uniq_by(&elem(&1, 0))

      expected =
        Enum.filter(agents, &elem(&1, 1)) ++ Enum.reject(agents, &elem(&1, 1))

      given =
        expected
        |> Enum.map(fn {target, _} -> Hint.label_for(labels, target) end)
        |> Enum.take(length(Hint.letter_labels(length(expected))))

      assert given == Enum.take(Hint.letter_labels(length(expected)), length(given))
    end
  end

  test "the hand-out order is the home row, then the top row" do
    assert Hint.letter_labels(15) == ~w(s f g h j k l w e r t u i o p)
    assert Hint.letter_labels(3) == ~w(s f g)
  end

  test "past fifteen agents the last letters become prefixes of two-letter labels" do
    labels = Hint.letter_labels(16)
    assert length(labels) == 16
    assert Enum.take(labels, 14) == ~w(s f g h j k l w e r t u i o)
    assert Enum.drop(labels, 14) == ["ps", "pf"]
    assert length(Hint.letter_labels(225)) == 225
    assert Hint.letter_labels(300) |> length() == 225
  end

  test "runs get the digits in panel order, agents the letters, needs-you first" do
    entries = [
      {:run, "r1"},
      {:agent, "r1", "lead", false},
      {:agent, "r1", "engine", false},
      {:agent, "r1", "web", true},
      {:run, "r2"},
      {:agent, "r2", "plug", true}
    ]

    assert Hint.labels(entries) == %{
             "1" => {:run, "r1"},
             "2" => {:run, "r2"},
             "s" => {:agent, "r1", "web"},
             "f" => {:agent, "r2", "plug"},
             "g" => {:agent, "r1", "lead"},
             "h" => {:agent, "r1", "engine"}
           }
  end

  test "match resolves whole labels and knows a typed prefix" do
    labels = Map.new(Hint.letter_labels(16), &{&1, {:agent, "r", &1}})
    assert Hint.match(labels, "s") == {:target, {:agent, "r", "s"}}
    assert Hint.match(labels, "p") == :prefix
    assert Hint.match(labels, "pf") == {:target, {:agent, "r", "pf"}}
    assert Hint.match(labels, "x") == :none
    assert Hint.match(labels, "") == :none
  end
end
