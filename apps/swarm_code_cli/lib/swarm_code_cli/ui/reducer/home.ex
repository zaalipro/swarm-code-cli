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

  alias SwarmCodeCLI.UI.{Draft, DraftKey, Drafts, Editor, FieldEditors, Home, Keymap, State}
  alias SwarmCodeCLI.UI.DataSource.{DTO, Request}
  alias SwarmCodeCLI.UI.Draft.Pastes
  alias SwarmCodeCLI.UI.Home.{CopyCommand, View}
  alias SwarmCodeCLI.UI.{ModelPicker, SlashPalette}
  alias SwarmCodeCLI.UI.Reducer
  alias SwarmCodeCLI.UI.Reducer.Editing

  # The slash commands that act on the conversation in view: Home closes first,
  # so you see what they act on (D10).
  @conversation_bound [:rewind, :undo, :delete, :queue, :diff]
  # The same commands with arguments (`/rewind 3`, `/effort high`) are not client
  # commands, they go to the daemon for the conversation in view: Home goes first.
  # orbit int (UI-U-2): so does every other remote command whose catalogue words
  # say "this conversation" (`SwarmCode.Commands`): stop, compact, rename, fork,
  # export, cost, resume-run, and the model, worker model and profile of it.
  # Anything else (text, `/swarm`, `/plan`, `/goal`, ...) starts work: D10.
  @bound_words ~w(rewind undo delete queue diff effort worker_effort stop compact rename fork
                  export cost resume-run model worker_model profile)

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

  # Tab on a slash list completes the highlighted row, as in the shell.
  def handle(%{home: %Home{focus: :composer}} = state, :focus_next) do
    case SlashPalette.selected(state) do
      %{arg?: true, text: text} -> SlashPalette.complete_argument(state, text)
      %{name: name} -> SlashPalette.complete(state, name)
      nil -> {set_focus(state, next_focus(state, :composer)), []}
    end
  end

  def handle(%{home: %Home{focus: focus}} = state, :focus_next),
    do: {set_focus(state, next_focus(state, focus)), []}

  def handle(%{home: %Home{focus: focus}} = state, :focus_previous),
    do: {set_focus(state, previous_focus(state, focus)), []}

  # The project map: ←/→ the orbit, ↑/↓ the bead (clamped).
  def handle(%{home: %Home{focus: :map}} = state, verb) when verb in [:left, :right] do
    last = max(length(View.map_projects(state)) - 1, 0)
    home = state.home
    orbit = if verb == :left, do: home.orbit - 1, else: home.orbit + 1
    {clamp(%{state | home: %{home | orbit: min(max(orbit, 0), last)}}), []}
  end

  def handle(%{home: %Home{focus: :map}} = state, verb) when verb in [:up, :down] do
    home = state.home
    bead = if verb == :up, do: home.bead - 1, else: home.bead + 1
    {clamp(%{state | home: %{home | bead: max(bead, 0)}}), []}
  end

  # A draft of several lines keeps ↑/↓ for the caret while the caret is not on
  # its first/last line; only there they move the list.
  def handle(%{home: %Home{focus: :composer}} = state, verb) when verb in [:up, :down] do
    cond do
      # An open slash list owns ↑/↓, as in the shell.
      SlashPalette.open?(state) ->
        {SlashPalette.move(state, if(verb == :up, do: :previous, else: :next)), []}

      caret_on_edge?(state, verb) ->
        select_row(state, verb)

      true ->
        Editing.apply(state, :editor, draft_key(state), {:move, verb})
    end
  end

  def handle(%{home: %Home{}} = state, verb) when verb in [:up, :down],
    do: select_row(state, verb)

  # Enter. Nothing is sent while a `conversation.new` is out for an earlier Enter.
  def handle(%{home: %Home{pending_send: text}} = state, :enter) when is_binary(text),
    do: {state, []}

  def handle(%{home: %Home{focus: :composer}} = state, :enter), do: enter_composer(state)
  def handle(%{home: %Home{focus: :list}} = state, :enter), do: open_selected(state)
  def handle(%{home: %Home{focus: :map}} = state, :enter), do: enter_map(state)

  def handle(%{home: %Home{}} = state, {:open_row, n}), do: open_nth(state, n)

  # `y` on the map: the command that opens the bead's conversation, for any project.
  def handle(%{home: %Home{focus: :map}} = state, :copy) do
    case View.map_target(state) do
      %{project: project, conversation: %{id: _} = conversation} ->
        copy_command(state, project, conversation)

      _ ->
        {state, []}
    end
  end

  def handle(%{home: %Home{}} = state, :next_need), do: next_need(state)
  def handle(%{home: %Home{}} = state, :interrupt), do: interrupt(state)

  def handle(state, _verb), do: {state, []}

  defp set_focus(state, focus), do: %{state | home: %{state.home | focus: focus}}

  # Tab walks composer → list → map → composer, and passes the map by where it
  # is not drawn (the minimal class, no overview yet).
  defp next_focus(_state, :composer), do: :list
  defp next_focus(state, :list), do: if(View.map?(state), do: :map, else: :composer)
  defp next_focus(_state, :map), do: :composer

  defp previous_focus(state, :composer), do: if(View.map?(state), do: :map, else: :list)
  defp previous_focus(_state, :map), do: :list
  defp previous_focus(_state, :list), do: :composer

  # ------------------------------------------------------- the list's cursor

  defp select_row(state, verb) do
    count = length(Home.rows(state))
    home = state.home
    last = max(count - 1, 0)
    selected = if verb == :up, do: home.selected - 1, else: home.selected + 1
    {%{state | home: %{home | selected: min(max(selected, 0), last)}}, []}
  end

  # The caret is on the first (for ↑) or last (for ↓) logical line of the draft.
  defp caret_on_edge?(state, verb) do
    editor = Drafts.fetch(state.drafts, draft_key(state)).editor
    graphemes = editor |> Editor.text() |> String.graphemes()
    {before, rest} = Enum.split(graphemes, Editor.cursor(editor))
    scanned = if verb == :up, do: before, else: rest
    not Enum.any?(scanned, &Editor.newline?/1)
  end

  @doc """
  The wheel (or alternate scroll) over Home moves the list's selection: one row
  per notch, up for a negative `delta`.
  """
  @spec scroll(State.t(), integer()) :: {State.t(), [term()]}
  def scroll(%{home: %Home{}} = state, delta) when is_integer(delta) do
    rows = if delta < 0, do: -1, else: 1
    home = state.home
    last = max(length(Home.rows(state)) - 1, 0)
    {%{state | home: %{home | selected: min(max(home.selected + rows, 0), last)}}, []}
  end

  def scroll(state, _delta), do: {state, []}

  # ------------------------------------------------------------ enter, open

  # Enter in the composer. An empty draft opens the selected row (D10); a client
  # slash command runs as it does in the shell, closing Home first when it acts
  # on the conversation; any other text starts work in this project.
  defp enter_composer(state) do
    # A slash list is open on the draft: Enter completes the highlighted row, or
    # writes it and goes on as if it had been typed whole (the shell's T4).
    case SlashPalette.enter_completion(state) do
      {:complete, name} ->
        SlashPalette.complete(state, name)

      {:run, name} ->
        enter_replaced(state, "/" <> name)

      {:run_argument, text} ->
        enter_replaced(state, "/" <> text)

      nil ->
        enter_text(state)
    end
  end

  defp enter_replaced(state, text) do
    {state, replaced} = Reducer.home_replace_draft(state, draft_key(state), text)
    {state, sent} = enter_text(state)
    {state, replaced ++ sent}
  end

  defp enter_text(state) do
    text = draft_text(state)

    cond do
      String.trim(text) == "" -> open_selected(state, :continue)
      close_first?(text) -> run_closing(state, text)
      Keymap.local_command(text) != nil -> run_here(state)
      true -> start_work(state, text)
    end
  end

  defp close_first?(text) do
    case Keymap.local_command(text) do
      command when command in @conversation_bound -> true
      {:effort, _} -> true
      nil -> ModelPicker.opener(text) != nil or bound_word?(text)
      _ -> false
    end
  end

  defp bound_word?(text) do
    case String.split(String.trim_leading(text), ~r/\s/, parts: 2) do
      ["/" <> word | _] -> word in @bound_words
      _ -> false
    end
  end

  # A client command or a picker runs at once; any other text waits for the
  # workspace of the conversation it is sent to.
  defp deferrable?(text),
    do: Keymap.local_command(text) == nil and ModelPicker.opener(text) == nil

  # A command about this session (/trust, /settings, /theme …) runs from Home's
  # own draft, which it clears; Home stays.
  defp run_here(state), do: Reducer.home_send(state, false)

  # A command about the conversation in view: Home goes, the text is moved to the
  # conversation's draft and runs there, and the draft that was there is put back.
  defp run_closing(state, text) do
    from = draft_key(state)
    {state, closed} = close(state, :continue)

    case State.current_draft_key(state) do
      nil ->
        {state, closed}

      to ->
        saved = Editor.text(Drafts.fetch(state.drafts, to).editor)

        with {:ok, state} <- move_draft(state, from, to) do
          {state, sent} = Reducer.home_send(state, deferrable?(text))
          {state, kept} = restore_draft_text(state, to, saved, text)
          {state, closed ++ sent ++ kept}
        else
          :error -> {note(state, "Too many drafts are open to run that here."), closed}
        end
    end
  end

  defp restore_draft_text(state, _key, "", _text), do: {state, []}

  defp restore_draft_text(state, key, saved, text) do
    current = Editor.text(Drafts.fetch(state.drafts, key).editor)
    if current in ["", text], do: Reducer.home_replace_draft(state, key, saved), else: {state, []}
  end

  # D10: text over an empty conversation (no run, no prompt, no draft) goes there;
  # otherwise a new conversation is made first and the text follows it.
  defp start_work(state, text) do
    if underneath_free?(state), do: send_here(state), else: send_in_new(state, text)
  end

  defp underneath_free?(state) do
    with true <- Home.empty_underneath?(state),
         id when is_binary(id) <- Home.current_conversation_id(state) do
      draft = Drafts.fetch(state.drafts, {id, :main})
      not Draft.dirty?(draft)
    else
      _ -> false
    end
  end

  defp send_here(state) do
    from = draft_key(state)
    {state, closed} = close(state, :opened)

    with to when not is_nil(to) <- State.current_draft_key(state),
         {:ok, state} <- move_draft(state, from, to) do
      {state, sent} = Reducer.home_send(state)
      {state, closed ++ sent}
    else
      _ -> {note(state, "Could not start that here."), closed}
    end
  end

  defp send_in_new(state, text) do
    draft = Drafts.fetch(state.drafts, draft_key(state))

    case Pastes.expand(text, draft.pastes) do
      {:ok, expanded} ->
        {state, effects} =
          Reducer.service_request(state, {:conversation_new}, {:conversation, :new})

        if effects == [] do
          {note(state, "Not ready yet: try again in a moment."), []}
        else
          {state, cleared} = Reducer.home_replace_draft(state, draft_key(state), "")
          {%{state | home: %{state.home | pending_send: expanded}}, effects ++ cleared}
        end

      {:error, :too_large} ->
        {note(state, "The message is over 256 KiB."), []}
    end
  end

  # The draft moves with its collapsed pastes, attachments and target.
  defp move_draft(state, from, to) do
    draft = Drafts.fetch(state.drafts, from)
    moved = %Draft{draft | key: to, scroll_x: 0, scroll_y: 0}
    drafts = state.drafts |> Drafts.put(moved) |> Drafts.put(Draft.clear(draft))
    {:ok, %{state | drafts: drafts, slash_palette: nil}}
  rescue
    ArgumentError -> :error
  end

  defp note(state, words), do: %{state | notice: {:command_feedback, words}}

  defp draft_text(state), do: Editor.text(Drafts.fetch(state.drafts, draft_key(state)).editor)

  defp open_selected(state, empty \\ :stay) do
    case Enum.at(Home.rows(state), state.home.selected) do
      %{id: id} -> open_conversation(state, id)
      nil when empty == :continue -> close(state, :continue)
      nil -> {state, []}
    end
  end

  # Alt-1..9: row n of the list as drawn; in a first run, the nth conversation
  # "elsewhere", whose command is copied.
  defp open_nth(state, n) do
    if View.first_run?(state) do
      case Enum.at(View.elsewhere(state, 5), n - 1) do
        nil -> {state, []}
        entry -> copy_command(state, entry.project, entry.conversation)
      end
    else
      case Enum.at(View.visible_list(state).rows, n - 1) do
        %{summary: %{id: id}} -> open_conversation(state, id)
        _ -> {state, []}
      end
    end
  end

  # The conversation in view: Home just closes. Another of this project: the
  # service switches to it, and the destination change closes Home (D20).
  defp open_conversation(state, id) do
    if id == Home.current_conversation_id(state) do
      close(state, :opened)
    else
      Reducer.service_request(state, {:conversation_open, id}, {:conversation, :open})
    end
  end

  defp enter_map(state) do
    case View.map_target(state) do
      %{project: %{current: true}, conversation: %{id: id}} ->
        open_conversation(state, id)

      %{project: project, conversation: %{id: _} = conversation} ->
        copy_command(state, project, conversation)

      _ ->
        {state, []}
    end
  end

  # Another project opens in its own tab: the command goes to the clipboard.
  defp copy_command(state, project, conversation) do
    command =
      CopyCommand.command(project.root_path, conversation.id, View.launch_fact(state, :home))

    {note(state, "Copied: " <> command <> " — run it in a new terminal tab."), [{:copy, command}]}
  end

  # Ctrl-N (D19): the first approval or question that waits, here or elsewhere.
  defp next_need(state) do
    here =
      case state.conversations do
        %DTO.ConversationList{items: items} -> Enum.find(items, &(&1.waiting > 0))
        _ -> nil
      end

    elsewhere =
      for project <- View.projects(state),
          not project.current,
          conversation <- project.conversations,
          conversation.waiting > 0,
          do: {project, conversation}

    cond do
      here != nil -> open_conversation(state, here.id)
      elsewhere != [] -> elsewhere |> hd() |> then(fn {p, c} -> copy_command(state, p, c) end)
      true -> {note(state, "Nothing waits for you."), []}
    end
  end

  # Ctrl-C (D21): the search text, then the draft; with neither, a press that
  # has nothing to do arms the quit, and a second one quits. It never stops a
  # turn: Home has none in view.
  defp interrupt(%{home: %Home{focus: :list, filter: filter}} = state) when filter != "",
    do: clear_filter(state)

  defp interrupt(%{home: %Home{focus: :composer}} = state) do
    if draft_text(state) != "",
      do: Reducer.home_replace_draft(state, draft_key(state), ""),
      else: Reducer.home_ctrl_c(state)
  end

  defp interrupt(state), do: Reducer.home_ctrl_c(state)

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
  #
  # orbit int (lane S issue 1): an error never replaces an overview already on
  # screen. `capacity_exceeded` is both "the body does not fit its byte limit"
  # (S's `fit_home/2`, `conversation.list`'s code) and "the request window is
  # full" (the 33rd request, the client's own admission), and a deadline or a
  # closed source is as passing: the last good board stays, and the next push
  # asks again.
  defp overview_response(%{home: home} = state, %DTO.HomeOverview{} = body) do
    held = state.read_model.home_revision
    ready? = body.state == :ready
    behind? = not ready? or body.revision < held
    retry? = ready? and behind? and home.lag_floor < held

    shown =
      if ready? or not match?(%DTO.HomeOverview{state: :ready}, home.overview),
        do: body,
        else: home.overview

    home = %{
      home
      | overview: shown,
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

  # The list never selects a row it does not have, nor the map a bead.
  defp clamp(%{home: %Home{} = home} = state) do
    last = max(length(Home.rows(state)) - 1, 0)
    projects = View.map_projects(state)
    orbit = min(home.orbit, max(length(projects) - 1, 0))

    beads =
      case Enum.at(projects, orbit) do
        nil -> 0
        project -> length(project.conversations)
      end

    focus = if home.focus == :map and projects == [], do: :composer, else: home.focus

    %{
      state
      | home: %{
          home
          | selected: min(home.selected, last),
            orbit: orbit,
            bead: min(home.bead, max(beads - 1, 0)),
            focus: focus
        }
    }
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
        arrived(next)

      true ->
        {next, restored} = settle_pending(next)
        {next, listed} = relist(prev, next)
        {next, asked} = requery(next)
        {next, restored ++ listed ++ asked}
    end
  end

  # The destination changed (D20): Home goes. A text that waited for
  # `conversation.new` is put in the new conversation's draft and sent as soon as
  # its workspace is ready (`Reducer.home_send/1` defers it until then).
  defp arrived(next) do
    text = next.home.pending_send
    {next, closed} = close(next, :opened)

    with true <- is_binary(text) and text != "",
         key when not is_nil(key) <- State.current_draft_key(next) do
      {next, put} = Reducer.home_replace_draft(next, key, text)
      {next, sent} = Reducer.home_send(next)
      {next, closed ++ put ++ sent}
    else
      _ -> {next, closed}
    end
  end

  # A `conversation.new` that was refused (or dropped) gives the text back.
  defp settle_pending(%{home: %Home{pending_send: text} = home} = next) when is_binary(text) do
    if Enum.any?(Map.values(next.requests), &(&1.kind == {:conversation_new})) do
      {next, []}
    else
      next = %{next | home: %{home | pending_send: nil}}
      existing = draft_text(next)
      restored = if String.trim(existing) == "", do: text, else: text <> "\n" <> existing
      Reducer.home_replace_draft(next, draft_key(next), restored)
    end
  end

  defp settle_pending(next), do: {next, []}

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
