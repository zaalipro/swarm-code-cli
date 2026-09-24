defmodule SwarmCodeCLI.UI.Hint do
  @moduledoc """
  Hint mode's badges (pass 72, P7 and K1-K4): which key opens which entry of
  the side panel.

  `labels/1` is pure. It takes the panel's visible entries in display order
  (`Projector.PanelOrder.entries/1`: `{:run, run_id}` and
  `{:agent, run_id, node_id, needs_you?}`) and answers `%{label => target}`,
  where a target is `{:run, run_id}` or `{:agent, run_id, node_id}`:

    * runs get the digits `1`..`9` in panel order (`0` is the runs dashboard,
      which the keymap handles, never a label);
    * agents that need you get the first letters, oldest in panel order first,
      then every other agent in panel order;
    * the letters are the home row `s f g h j k l`, then `w e r t u i o p`;
      past those fifteen the labels become two letters, prefix-free, so a
      typed first letter is never also a whole label;
    * a label never contains `y a Y A d D n q ?`: those answer approvals, open
      help or are reserved, and a hint key never answers a request (K4).
  """

  @letters ~w(s f g h j k l w e r t u i o p)
  @forbidden ~w(y a Y A d D n q ?)
  @digits ~w(1 2 3 4 5 6 7 8 9)

  @type target :: {:run, binary()} | {:agent, binary(), binary()}
  @type entry :: {:run, binary()} | {:agent, binary(), binary(), boolean()}

  @doc "The badge letters in the order they are handed out."
  @spec letters() :: [binary()]
  def letters, do: @letters

  @doc "The keys a label never contains."
  @spec forbidden() :: [binary()]
  def forbidden, do: @forbidden

  @doc "The labels for the panel's `entries`, as `%{label => target}`."
  @spec labels([entry()]) :: %{binary() => target()}
  def labels(entries) when is_list(entries) do
    runs =
      entries
      |> Enum.flat_map(fn
        {:run, id} when is_binary(id) -> [{:run, id}]
        _ -> []
      end)
      |> Enum.uniq()
      |> Enum.zip(@digits)
      |> Map.new(fn {target, digit} -> {digit, target} end)

    agents =
      entries
      |> Enum.flat_map(fn
        {:agent, run, node, needs?} when is_binary(run) and is_binary(node) ->
          [{{:agent, run, node}, needs? == true}]

        _ ->
          []
      end)
      |> Enum.uniq_by(&elem(&1, 0))

    # Needs-you first, each group keeping panel order (a stable sort).
    ordered =
      agents
      |> Enum.with_index()
      |> Enum.sort_by(fn {{_target, needs?}, index} -> {if(needs?, do: 0, else: 1), index} end)
      |> Enum.map(fn {{target, _}, _} -> target end)

    letters =
      ordered
      |> Enum.zip(letter_labels(length(ordered)))
      |> Map.new(fn {target, label} -> {label, target} end)

    Map.merge(runs, letters)
  end

  @doc """
  `count` prefix-free letter labels in hand-out order: single letters while
  they last, and then the letters at the end of the list turn into prefixes of
  two-letter labels, as few of them as `count` needs. At most 225.
  """
  @spec letter_labels(non_neg_integer()) :: [binary()]
  def letter_labels(count) when is_integer(count) and count >= 0 do
    size = length(@letters)

    if count <= size do
      Enum.take(@letters, count)
    else
      # The most singles `s` with s + (size - s) * size >= count.
      singles = max(0, div(size * size - count, size - 1))
      {single, prefixes} = Enum.split(@letters, singles)
      doubles = for prefix <- prefixes, letter <- @letters, do: prefix <> letter
      Enum.take(single ++ doubles, count)
    end
  end

  @doc """
  What `typed` means against `labels`: `{:target, target}` for a whole label,
  `:prefix` when a longer label starts with it, `:none` otherwise.
  """
  @spec match(%{binary() => target()}, binary()) :: {:target, target()} | :prefix | :none
  def match(labels, typed) when is_map(labels) and is_binary(typed) do
    case Map.fetch(labels, typed) do
      {:ok, target} ->
        {:target, target}

      :error ->
        if typed != "" and Enum.any?(Map.keys(labels), &String.starts_with?(&1, typed)),
          do: :prefix,
          else: :none
    end
  end

  @doc "The label `labels` gives `target`, or nil."
  @spec label_for(%{binary() => target()}, target()) :: binary() | nil
  def label_for(labels, target) when is_map(labels) do
    Enum.find_value(labels, fn {label, current} -> if current == target, do: label end)
  end
end
