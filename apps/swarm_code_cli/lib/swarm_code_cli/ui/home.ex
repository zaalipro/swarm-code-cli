defmodule SwarmCodeCLI.UI.Home do
  @moduledoc """
  orbit: the state of Home, the full-screen layer `ncode` opens over the
  project's latest conversation (`state.home`; nil while it is closed).

  Home is a layer, not a destination: the conversation underneath keeps its
  watch, its drafts and its scroll. What Home owns is small:

    * `focus` is `:composer | :list | :map` (Tab walks them);
    * `selected` is the resume list's row, `filter`/`search` its search;
    * `orbit`/`bead` are the map's cursor (an orbit is a project, a bead one of
      its conversations, newest first);
    * `overview` is the last `home.overview` answer, `overview_request` the id
      of the one in flight, `dirty?` a stale push that arrived meanwhile and
      `seen_revision` the home revision the overview reflects;
    * `search_request`/`search_dirty?` are the same single flight for the
      list's `conversation.search`;
    * `opened_over` is the destination Esc returns to and `entered` how Home was
      opened (`:boot` at launch, else `:key` or `:command`: the hint line says
      "continue the latest" at launch and "back to" after); `pending_send` the
      text that waits for `conversation.new`;
    * `generation` counts the openings, so a late answer of an earlier one is
      dropped. `asked_revision` is the newest push the request in flight was sent
      after, and `lag_floor` the newest push an answer could not catch up with
      (or an error left unanswered): that push is not asked for again, which is
      the loop guard of the re-query.

  `Reducer.Home` changes it, `Projector.Home` draws it. The struct is U-internal
  (spec 3.6) and the integrator's smoke relies on its field names.
  """

  alias SwarmCodeCLI.UI.DataSource.DTO
  alias SwarmCodeCLI.UI.State

  defstruct generation: 0,
            focus: :composer,
            selected: 0,
            filter: "",
            search: nil,
            orbit: 0,
            bead: 0,
            overview: nil,
            overview_request: nil,
            dirty?: false,
            seen_revision: 0,
            search_request: nil,
            search_dirty?: false,
            opened_over: nil,
            entered: :boot,
            pending_send: nil,
            asked_revision: 0,
            lag_floor: 0

  @type focus :: :composer | :list | :map
  @type verb ::
          :enter
          | :escape
          | :focus_next
          | :focus_previous
          | :up
          | :down
          | :left
          | :right
          | :copy
          | :next_need
          | :interrupt
          | {:open_row, 1..9}
          | {:scroll, :up | :down, 1..32}
  @type t :: %__MODULE__{
          generation: non_neg_integer(),
          focus: focus(),
          selected: non_neg_integer(),
          filter: binary(),
          search: nil | %{query: binary(), items: [DTO.ConversationSummary.t()]},
          orbit: non_neg_integer(),
          bead: non_neg_integer(),
          overview: nil | DTO.HomeOverview.t(),
          overview_request: binary() | nil,
          dirty?: boolean(),
          seen_revision: non_neg_integer(),
          search_request: binary() | nil,
          search_dirty?: boolean(),
          opened_over: term(),
          entered: :boot | :key | :command,
          pending_send: binary() | nil,
          asked_revision: non_neg_integer(),
          lag_floor: non_neg_integer()
        }

  @doc "The field editor that holds the list's search text."
  @spec filter_key() :: {:home, :filter}
  def filter_key, do: {:home, :filter}

  @doc """
  A Home for `state` (`how` is `:boot`, `:key` or `:command`). A Home closed
  earlier left its position in `state.home_resume`: the list row, the orbit
  and the bead come back, and so does the last overview (the next answer
  replaces it a moment later); the search, the requests and a pending send
  never do. The opening counts one more than the last.
  """
  @spec new(State.t(), :boot | :key | :command) :: t()
  def new(state, how) when how in [:boot, :key, :command] do
    resume = Map.get(state, :home_resume)

    case resume do
      %__MODULE__{} = kept ->
        %__MODULE__{
          generation: kept.generation + 1,
          focus: kept.focus,
          selected: kept.selected,
          orbit: kept.orbit,
          bead: kept.bead,
          overview: kept.overview,
          seen_revision: kept.seen_revision,
          opened_over: state.destination,
          entered: how
        }

      _ ->
        %__MODULE__{generation: 1, opened_over: state.destination, entered: how}
    end
  end

  @doc "A conversation nothing has been said in: the one a new project is given."
  @spec empty?(DTO.ConversationSummary.t()) :: boolean()
  def empty?(%DTO.ConversationSummary{run_count: 0, last_prompt: nil}), do: true
  def empty?(_summary), do: false

  @doc """
  The rows of the resume list (D11): the search's matches while a search is
  shown, else the project's conversations as the last `conversation.list`
  answered, newest first, without the empty ones.
  """
  @spec rows(State.t()) :: [DTO.ConversationSummary.t()]
  def rows(%{home: %__MODULE__{search: %{items: items}}}), do: Enum.reject(items, &empty?/1)

  def rows(%{conversations: %DTO.ConversationList{items: items}}),
    do: Enum.reject(items, &empty?/1)

  def rows(_state), do: []

  @doc "The id of the conversation underneath Home, or nil."
  @spec current_conversation_id(State.t()) :: binary() | nil
  def current_conversation_id(%{destination: {:conversation, id}}), do: id

  def current_conversation_id(%{destination: {:run, run_id}, read_model: model}) do
    case Map.get(model.runs, run_id) do
      nil -> nil
      run -> run.conversation_id
    end
  end

  def current_conversation_id(_state), do: nil

  @doc "The summary of the conversation underneath Home, or nil before the list answered."
  @spec current_summary(State.t()) :: DTO.ConversationSummary.t() | nil
  def current_summary(%{conversations: %DTO.ConversationList{items: items}} = state) do
    id = current_conversation_id(state)
    Enum.find(items, &(&1.id == id)) || Enum.find(items, & &1.current)
  end

  def current_summary(_state), do: nil

  @doc "Whether the conversation underneath has had no run and no prompt (D10: Enter reuses it)."
  @spec empty_underneath?(State.t()) :: boolean()
  def empty_underneath?(state) do
    case current_summary(state) do
      nil -> false
      summary -> empty?(summary)
    end
  end

  @doc """
  The verbs of the `{:home, verb}` action. `{:open_row, n}` opens the nth
  visible row; `:interrupt` is Ctrl-C.
  """
  @spec verb?(term()) :: boolean()
  def verb?(verb)
      when verb in [
             :enter,
             :escape,
             :focus_next,
             :focus_previous,
             :up,
             :down,
             :left,
             :right,
             :copy,
             :next_need,
             :interrupt
           ],
      do: true

  def verb?({:open_row, n}) when is_integer(n) and n in 1..9, do: true
  def verb?({:scroll, direction, count}), do: direction in [:up, :down] and count in 1..32
  def verb?(_verb), do: false
end
