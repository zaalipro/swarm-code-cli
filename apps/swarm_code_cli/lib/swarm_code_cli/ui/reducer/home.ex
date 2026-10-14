defmodule SwarmCodeCLI.UI.Reducer.Home do
  @moduledoc """
  orbit: Home's transitions (spec 3.2, 3.6; D6-D21).

  Home is `state.home`, a layer over the real conversation. Everything it asks
  of the service goes through the shell watch's scope as an ordinary request,
  one at a time per kind, and everything it receives is checked against the
  request id it is waiting for, so an answer of an earlier opening (or of a
  query a newer one replaced) is dropped.

    * `open/2`, `close/2` change the layer;
    * `handle/2` is every `{:home, verb}` the keys resolve to;
    * `response/3` takes the answers of `home.overview` and `conversation.search`;
    * `after_update/2` runs after every reducer step: it asks again when the
      shell has become ready or a `home_stale` push moved the revision, closes
      Home when the destination changed (D20), and hands a pending send on.
  """

  alias SwarmCodeCLI.UI.{Draft, DraftKey, Drafts, Editor, FieldEditors, Home, State}
  alias SwarmCodeCLI.UI.DataSource.{DTO, Request}
  alias SwarmCodeCLI.UI.Reducer
  alias SwarmCodeCLI.UI.Reducer.Editing

  # The constants of spec 3.3.
  @overview {:home_overview, 6, 12, 131_072}
  @search_limit 50
  @search_bytes 262_144

  @doc "The request Home sends for its overview."
  @spec overview_kind() :: Request.kind()
  def overview_kind, do: @overview

  # ------------------------------------------------------------- open, close

  @doc """
  Opens Home over the conversation in view. Opening while Home is open, while
  Settings or a layer is open (they own the keys), is a no-op, except at boot,
  when nothing else exists yet.
  """
  @spec open(State.t(), :boot | :key | :command) :: {State.t(), [term()]}
  def open(%{home: %Home{}} = state, _how), do: {state, []}

  def open(%{settings: settings} = state, how) when settings != nil and how != :boot,
    do: {state, []}

  def open(%{layers: [_ | _]} = state, how) when how != :boot, do: {state, []}

  def open(state, how) do
    home = Home.new(state, how)
    state = %{state | home: home, home_resume: nil}
    {state, listed} = list_when_ready(state)
    {state, asked} = ask_overview(state)
    {state, listed ++ asked}
  end

  @doc """
  Closes Home. `:continue` leaves it onto the conversation underneath (Esc),
  `:opened` is a destination change (D20): the position is kept for the next
  opening, with the focus back on the composer. Requests in flight are
  cancelled; the search text is dropped with the field that held it.
  """
  @spec close(State.t(), :continue | :opened) :: {State.t(), [term()]}
  def close(%{home: nil} = state, _how), do: {state, []}

  def close(%{home: %Home{} = home} = state, how) do
    ids = Enum.reject([home.overview_request, home.search_request], &is_nil/1)

    kept = %Home{
      home
      | focus: if(how == :opened, do: :composer, else: home.focus),
        filter: "",
        search: nil,
        overview_request: nil,
        search_request: nil,
        dirty?: false,
        search_dirty?: false,
        pending_send: nil
    }

    state = %{
      state
      | home: nil,
        home_resume: kept,
        requests: Map.drop(state.requests, ids),
        field_editors: drop_filter(state.field_editors)
    }

    {state, Enum.map(ids, &{:cancel_request, &1})}
  end

  defp drop_filter(fields),
    do: %{fields | entries: Map.delete(fields.entries, Home.filter_key())}

  # ------------------------------------------------------------------ verbs

  @doc "A `{:home, verb}` action."
  @spec handle(State.t(), term()) :: {State.t(), [term()]}
  def handle(%{home: nil} = state, _verb), do: {state, []}

  # Esc: the composer leaves Home onto the conversation underneath; a text
  # waiting for `conversation.new` keeps Home until the new conversation opens.
  def handle(%{home: %Home{pending_send: text}} = state, :escape) when is_binary(text),
    do: {state, []}

  def handle(%{home: %Home{focus: :composer}} = state, :escape), do: close(state, :continue)
  def handle(%{home: %Home{}} = state, :escape), do: {set_focus(state, :composer), []}

  def handle(%{home: %Home{focus: focus}} = state, :focus_next),
    do: {set_focus(state, next_focus(focus)), []}

  def handle(%{home: %Home{focus: focus}} = state, :focus_previous),
    do: {set_focus(state, previous_focus(focus)), []}

  def handle(%{home: %Home{}} = state, verb) when verb in [:up, :down] do
    count = length(Home.rows(state))
    home = state.home
    last = max(count - 1, 0)
    selected = if verb == :up, do: home.selected - 1, else: home.selected + 1
    {%{state | home: %{home | selected: min(max(selected, 0), last)}}, []}
  end

  def handle(state, _verb), do: {state, []}

  defp set_focus(state, focus), do: %{state | home: %{state.home | focus: focus}}

  defp next_focus(:composer), do: :list
  defp next_focus(:list), do: :map
  defp next_focus(:map), do: :composer

  defp previous_focus(:composer), do: :map
  defp previous_focus(:map), do: :list
  defp previous_focus(:list), do: :composer

  # ---------------------------------------------------------------- requests

  # The conversations of the project: Home's list is the palette's (one list
  # request at a time; the answer lands in `state.conversations`).
  defp list_when_ready(state) do
    if shell_ready?(state), do: Reducer.request_conversations(state), else: {state, []}
  end

  @doc false
  # One overview request at a time. A second ask while one is in flight only
  # marks it, and the answer asks again.
  def ask_overview(%{home: %Home{overview_request: id} = home} = state) when is_binary(id),
    do: {%{state | home: %{home | dirty?: true}}, []}

  def ask_overview(%{home: %Home{}} = state) do
    if shell_ready?(state) do
      {state, effects} = Reducer.service_request(state, @overview, {:home, :overview})

      case effects do
        [{:query, %Request{request_id: id}}] ->
          home = %{
            state.home
            | overview_request: id,
              dirty?: false,
              asked_revision: state.read_model.home_revision
          }

          {%{state | home: home}, effects}

        _ ->
          {state, effects}
      end
    else
      {state, []}
    end
  end

  def ask_overview(state), do: {state, []}

  defp shell_ready?(state), do: match?(%{status: :ready}, Map.get(state.watches, :shell))

  # ------------------------------------------------------------ the search

  @doc """
  The list's search text changed (the field editor `{:home, :filter}` took a
  key): the search is asked for with the new text, one request at a time; an
  empty text drops the search and shows the list again.
  """
  @spec filter_changed(State.t()) :: {State.t(), [term()]}
  def filter_changed(%{home: %Home{} = home} = state) do
    text = filter_text(state)

    cond do
      text == home.filter ->
        {state, []}

      search_text(text) == "" ->
        cancel = if home.search_request, do: [{:cancel_request, home.search_request}], else: []

        requests =
          if home.search_request,
            do: Map.delete(state.requests, home.search_request),
            else: state.requests

        {%{
           state
           | requests: requests,
             home: %{
               home
               | filter: text,
                 search: nil,
                 search_request: nil,
                 search_dirty?: false,
                 selected: 0
             }
         }, cancel}

      true ->
        ask_search(%{state | home: %{home | filter: text, selected: 0}})
    end
  end

  def filter_changed(state), do: {state, []}

  @doc false
  # Ctrl-C on the list (D21): the search text goes, and the list is the project's again.
  def clear_filter(%{home: %Home{}} = state) do
    fields = %{
      state.field_editors
      | entries: Map.delete(state.field_editors.entries, Home.filter_key())
    }

    filter_changed(%{state | field_editors: fields})
  end

  @doc "The text of the list's search field."
  @spec filter_text(State.t()) :: binary()
  def filter_text(state),
    do: Editor.text(FieldEditors.fetch(state.field_editors, Home.filter_key()))

  # The request's query: one line, no control characters, at most 200 bytes.
  defp search_text(text) do
    text
    |> String.replace(~r/[\x00-\x1F\x7F]+/u, " ")
    |> String.trim()
    |> clip_bytes(200)
  end

  defp clip_bytes(text, max) when byte_size(text) <= max, do: text

  defp clip_bytes(text, max) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({"", 0}, fn grapheme, {acc, used} ->
      size = byte_size(grapheme)

      if used + size > max,
        do: {:halt, {acc, used}},
        else: {:cont, {acc <> grapheme, used + size}}
    end)
    |> elem(0)
    |> String.trim()
  end

  defp ask_search(%{home: %Home{search_request: id} = home} = state) when is_binary(id),
    do: {%{state | home: %{home | search_dirty?: true}}, []}

  defp ask_search(%{home: %Home{} = home} = state) do
    query = search_text(home.filter)

    if query != "" and shell_ready?(state) do
      kind = {:conversation_search, query, @search_limit, @search_bytes}
      {state, effects} = Reducer.service_request(state, kind, {:home, :search})

      case effects do
        [{:query, %Request{request_id: id}}] ->
          {%{state | home: %{state.home | search_request: id, search_dirty?: false}}, effects}

        _ ->
          {state, effects}
      end
    else
      {state, []}
    end
  end

  # -------------------------------------------------------------- responses

  @doc """
  The answer to a request with origin `{:home, :overview | :search}`. The
  request is out of `state.requests` already when it is the one waited for.
  """
  @spec response(State.t(), Request.t(), term()) :: {State.t(), [term()]}
  def response(state, %Request{request_id: id, origin: origin} = request, body) do
    state = %{state | requests: Map.delete(state.requests, id)}

    case {state.home, origin} do
      {%Home{overview_request: ^id}, {:home, :overview}} -> overview_response(state, body)
      {%Home{search_request: ^id}, {:home, :search}} -> search_response(state, request, body)
      _ -> {state, []}
    end
  end

  # An error body (a daemon without the `home` grant, a timeout) is kept so the
  # screen stays on its placeholders and nothing asks again until the revision
  # moves or Home is opened again. An answer older than the newest push is
  # applied and asked for once more; `lag_floor` stops a daemon that cannot
  # catch up from being asked in a loop.
  defp overview_response(%{home: home} = state, %DTO.HomeOverview{} = body) do
    held = state.read_model.home_revision
    ready? = body.state == :ready
    behind? = not ready? or body.revision < held
    retry? = ready? and behind? and home.lag_floor < held

    home = %{
      home
      | overview: body,
        overview_request: nil,
        seen_revision:
          if(ready?, do: max(home.seen_revision, body.revision), else: home.seen_revision),
        lag_floor: if(behind?, do: max(home.lag_floor, held), else: home.lag_floor)
    }

    ask? = retry? or home.dirty?
    state = clamp(%{state | home: %{home | dirty?: false}})
    if ask?, do: ask_overview(state), else: {state, []}
  end

  defp overview_response(state, _body), do: {state, []}

  defp search_response(
         %{home: home} = state,
         %Request{kind: {:conversation_search, query, _, _}},
         %DTO.ConversationList{} = body
       ) do
    home =
      if body.state == :error,
        do: %{home | search_request: nil},
        else: %{home | search_request: nil, search: %{query: query, items: body.items}}

    state = clamp(%{state | home: home})

    # Typing went on while the request was out: the newest text goes now.
    if home.search_dirty? and search_text(home.filter) not in ["", query],
      do: ask_search(%{state | home: %{state.home | search_dirty?: false}}),
      else: {%{state | home: %{state.home | search_dirty?: false}}, []}
  end

  defp search_response(state, _request, _body), do: {state, []}

  # The list never selects a row it does not have.
  defp clamp(%{home: %Home{selected: selected} = home} = state) do
    last = max(length(Home.rows(state)) - 1, 0)
    %{state | home: %{home | selected: min(selected, last)}}
  end

  defp clamp(state), do: state

  # --------------------------------------------------------------- after step

  @doc """
  Runs after every reducer step: Home asks again when the shell has just become
  ready or a `home_stale` push moved the revision (one request in flight), and
  closes when the destination changed (D20).
  """
  @spec after_update(State.t(), State.t()) :: {State.t(), [term()]}
  def after_update(_prev, %{home: nil} = next), do: {next, []}

  def after_update(prev, %{home: %Home{}} = next) do
    next = reconcile(next)

    cond do
      prev.home != nil and prev.destination != next.destination ->
        close(next, :opened)

      true ->
        {next, listed} = relist(prev, next)
        {next, asked} = requery(next)
        {next, listed ++ asked}
    end
  end

  # A request the reducer dropped (the watch it was sent in was reopened) will
  # not be answered: forget it, so the next ask is not mistaken for a second
  # request in flight.
  defp reconcile(%{home: %Home{} = home} = next) do
    overview = if home.overview_request in Map.keys(next.requests), do: home.overview_request
    search = if home.search_request in Map.keys(next.requests), do: home.search_request

    if overview == home.overview_request and search == home.search_request,
      do: next,
      else: %{next | home: %{home | overview_request: overview, search_request: search}}
  end

  # The list is asked for when the shell turns ready under an open Home.
  defp relist(prev, next) do
    was = match?(%{status: :ready}, Map.get(prev.watches, :shell))
    if shell_ready?(next) and not was, do: Reducer.request_conversations(next), else: {next, []}
  end

  # The overview is asked for while there is none (the shell was not ready at
  # open), and again when the home revision the pushes named is newer than the
  # one the overview reflects. A push that lands while a request is in flight
  # marks it, and the answer asks once more (3.2).
  defp requery(%{home: %Home{overview_request: id} = home} = next) when is_binary(id) do
    if next.read_model.home_revision > home.asked_revision,
      do: {%{next | home: %{home | dirty?: true}}, []},
      else: {next, []}
  end

  defp requery(%{home: %Home{overview: nil}} = next), do: ask_overview(next)

  defp requery(%{home: %Home{} = home} = next) do
    if next.read_model.home_revision > max(home.seen_revision, home.lag_floor),
      do: ask_overview(next),
      else: {next, []}
  end

  # -------------------------------------------------------------- the draft

  @doc "The key of Home's own draft."
  @spec draft_key(State.t()) :: DraftKey.t()
  def draft_key(state), do: {state.source_epoch, :home}

  @doc false
  # Puts `text` into Home's draft (a failed `conversation.new` gives it back).
  def restore_draft(state, text) do
    key = draft_key(state)
    draft = Drafts.fetch(state.drafts, key)
    editor = Editor.reset(draft.editor)

    case Editor.apply(editor, {:insert, text}) do
      {:ok, editor} -> %{state | drafts: Drafts.put(state.drafts, %Draft{draft | editor: editor})}
      _ -> state
    end
  rescue
    ArgumentError -> state
  end

  @doc false
  def apply_editor(state, key, operation), do: Editing.apply(state, :editor, key, operation)
end
