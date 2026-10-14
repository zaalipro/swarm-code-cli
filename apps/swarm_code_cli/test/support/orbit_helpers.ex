defmodule SwarmCodeCLI.OrbitHelpers do
  @moduledoc false
  # orbit lane U: pure-reducer helpers for Home's tests. A session is built with
  # `Reducer.init/1` (Home on the first frame), its shell watch is marked ready
  # by hand, and the service's answers are fed back as deliveries.

  alias SwarmCodeCLI.UI.{Capabilities, Init, Reducer, Size, State}
  alias SwarmCodeCLI.UI.DataSource.{Delivery, Delta, DTO}

  @appendix Path.expand("../fixtures/home/overview.json", __DIR__)
  @conversation "1a2b3c4d-0000-4000-8000-000000000001"
  @epoch "orbit-epoch"
  # 2026-10-14T00:00:00Z plus a minute: the fixtures' ages count from here.
  @now 1_792_000_060_000

  def conversation_id, do: @conversation
  def now, do: @now
  def appendix_c, do: @appendix |> File.read!() |> Jason.decode!()

  @doc "The decoded Appendix C overview."
  def overview(request_id \\ nil, edit \\ & &1) do
    {:ok, body} =
      appendix_c() |> Map.put("request_id", request_id) |> edit.() |> DTO.HomeOverview.decode()

    body
  end

  @doc """
  A session whose Home is open over `{:conversation, id}`: `[home?: false]`
  builds it without Home; `[size: {120, 36}]` sets the terminal; `[shell: :ready]`
  (the default) marks the shell watch ready.
  """
  def start(options \\ []) do
    {columns, rows} = Keyword.get(options, :size, {120, 36})
    size = %Size{columns: columns, rows: rows}

    init = %Init{
      size: size,
      capabilities: struct!(%Capabilities{size: size}, Keyword.get(options, :capabilities, [])),
      source_epoch: @epoch,
      destination: {:conversation, @conversation},
      now: Keyword.get(options, :now, @now),
      home?: Keyword.get(options, :home?, true),
      resume_picker?: Keyword.get(options, :resume_picker?, false),
      launch_facts:
        Map.merge(
          %{
            cli_version: "0.2.2",
            project_root: "/Users/dev/dev/swarm-code-cli",
            home: "/Users/dev"
          },
          Keyword.get(options, :launch_facts, %{})
        )
    }

    {state, effects} = Reducer.init(init)
    state = if Keyword.get(options, :shell, :ready) == :ready, do: ready_shell(state), else: state
    {state, effects}
  end

  @doc "The shell watch ready, as a snapshot delivery would leave it."
  def ready_shell(state) do
    watch = %{state.watches.shell | status: :ready, revision: 1}
    %{state | watches: Map.put(state.watches, :shell, watch)}
  end

  @doc """
  The workspace watch of the conversation in view delivered, as the service's first
  snapshot leaves it: sending is allowed, the chat provider usable. `fields` override
  the snapshot's (`interactions:`, `runs:`).
  """
  def workspace_ready(state, fields \\ []) do
    {state, _effects} = workspace_delivered(state, fields)
    state
  end

  @doc "`workspace_ready/2` with the effects the delivery caused (a deferred send replays then)."
  def workspace_delivered(state, fields \\ []) do
    watch = state.watches.workspace
    conversation = SwarmCodeCLI.UI.Home.current_conversation_id(state) || @conversation

    body =
      struct!(
        %DTO.WorkspaceSnapshot{
          conversation_id: conversation,
          allowed_actions: [:send, :queue],
          chat_provider: "anthropic",
          chat_provider_usable: true,
          trusted: true,
          approval_mode: :auto,
          project: "swarm-code-cli",
          transcript: %DTO.TranscriptWindow{items: []},
          runs_page: %DTO.PageInfo{},
          interactions_page: %DTO.PageInfo{}
        },
        fields
      )

    delivery = %Delivery{
      kind: :watch_ready,
      watch_ref: watch.watch_ref,
      request_id: nil,
      scope: watch.scope,
      generation: watch.generation,
      revision: 0,
      sequence: nil,
      body: body
    }

    Reducer.update(state, {:data, delivery})
  end

  @doc "A pending approval of the conversation in view (`id`), waiting on run `run`."
  def approval(id, run \\ "r") do
    %DTO.PendingInteraction{
      id: id,
      kind: :approval,
      run_id: run,
      node_id: "op-1",
      conversation_id: @conversation,
      expected_revision: 5,
      created_at: 1,
      allowed_actions: [:approve, :deny, :always_allow],
      approval: %DTO.Approval{
        tool: "run_command",
        permission: :execute,
        arguments_preview: "ls -la notes"
      }
    }
  end

  @doc "A run of the conversation in view."
  def run(id, state) do
    %DTO.RunSummary{
      id: id,
      conversation_id: @conversation,
      state: state,
      revision: 3,
      kind: :chat,
      started_at: 1,
      allowed_actions: [:stop, :pause]
    }
  end

  @doc "The conversations Home lists (the palette's `conversation.list` answer)."
  def put_conversations(state, items) do
    list = %DTO.ConversationList{
      project: "swarm-code-cli",
      current_id: @conversation,
      items: items,
      request_id: nil,
      presence: :covered,
      covered_ids: Enum.map(items, & &1.id),
      through_sequence: 0
    }

    %{state | conversations: list}
  end

  def summary(n, fields \\ []) do
    id = "1a2b3c4d-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")

    struct!(
      %DTO.ConversationSummary{
        id: id,
        title: "conversation #{n}",
        created_at: @now - 3_600_000 * n,
        updated_at: @now - 60_000 * n,
        run_count: n,
        current: n == 1,
        last_prompt: "prompt #{n}"
      },
      fields
    )
  end

  @doc "Feeds one action; returns `{state, effects}`."
  def step(state, action), do: Reducer.update(state, action)

  @doc "Feeds actions in order; returns the state and every effect."
  def steps(state, actions) do
    Enum.reduce(actions, {state, []}, fn action, {acc, effects} ->
      {next, more} = Reducer.update(acc, action)
      {next, effects ++ more}
    end)
  end

  @doc "The queries of a given kind among `effects`."
  def queries(effects, kind) do
    for {:query, %{kind: request_kind} = request} <- effects,
        elem(request_kind, 0) == kind,
        do: request
  end

  @doc "The commands of a given kind among `effects`."
  def commands(effects, kind) do
    for {:command, %{kind: request_kind} = request} <- effects,
        is_tuple(request_kind) and elem(request_kind, 0) == kind,
        do: request
  end

  @doc "The service's answer to `request`, as the data source would deliver it."
  def respond(state, request, body) do
    delivery = %Delivery{
      kind: :response,
      watch_ref: nil,
      request_id: request.request_id,
      scope: request.scope,
      generation: request.generation,
      revision: nil,
      sequence: nil,
      body: body
    }

    Reducer.update(state, {:data, delivery})
  end

  @doc "A `home_overview` answer to `request`, with `edit` applied to Appendix C's wire map."
  def answer_overview(state, request, edit \\ & &1) do
    respond(state, request, overview(request.request_id, edit))
  end

  @doc "A `home_stale` push naming `revision` on the shell watch (the next sequence)."
  def stale(state, revision) do
    watch = state.watches.shell
    sequence = watch.sequence + 1

    delta = %Delta{
      kind: :home_stale,
      body: %DTO.HomeStale{revision: revision},
      sequence: sequence,
      revision: watch.revision
    }

    delivery = %Delivery{
      kind: :delta,
      watch_ref: watch.watch_ref,
      request_id: nil,
      scope: watch.scope,
      generation: watch.generation,
      revision: watch.revision,
      sequence: sequence,
      body: delta
    }

    Reducer.update(state, {:data, delivery})
  end

  @doc """
  The designer's mock as a state (`Fixtures.home_state/3`) at `{columns, rows}`,
  truecolor at the rich glyph tier unless `caps:` says otherwise.
  """
  def fixture(size \\ {120, 36}, options \\ []) do
    {columns, rows} = size
    size = %Size{columns: columns, rows: rows}

    caps =
      struct!(
        %Capabilities{size: size},
        Keyword.merge(
          [glyph_tier: :rich, color_mode: :truecolor],
          Keyword.get(options, :caps, [])
        )
      )

    SwarmCodeCLI.UI.Fixtures.home_state(size, caps, Keyword.delete(options, :caps))
  end

  @golden_dir Path.expand("../fixtures/home", __DIR__)

  @doc """
  Compares `text` with the golden `name` in `test/fixtures/home/`, or writes it when
  `ORBIT_GOLDEN_WRITE=1` is set (review the file by eye before committing it).
  """
  def assert_golden(name, text) do
    path = Path.join(@golden_dir, name)
    text = String.trim_trailing(text) <> "\n"

    if System.get_env("ORBIT_GOLDEN_WRITE") == "1" do
      File.write!(path, text)
    else
      expected = File.read!(path)

      if expected != text do
        File.write!(path <> ".actual", text)

        raise ExUnit.AssertionError,
          message: "#{name} differs from its golden; the new screen is in #{name}.actual"
      end
    end

    :ok
  end

  @doc "Home's own draft text."
  def home_draft(state) do
    SwarmCodeCLI.UI.Editor.text(
      SwarmCodeCLI.UI.Drafts.fetch(state.drafts, {state.source_epoch, :home}).editor
    )
  end

  @doc "Types `text` into the composer Home types into."
  def type(state, text) do
    key = State.current_draft_key(state)
    Reducer.update(state, {:editor, key, {:insert, text}})
  end
end
