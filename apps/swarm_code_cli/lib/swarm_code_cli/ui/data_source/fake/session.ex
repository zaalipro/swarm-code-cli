defmodule SwarmCodeCLI.UI.DataSource.Fake.Session do
  @moduledoc """
  pass70 C1: the fake daemon's session-level facts, the synthetic twin of what
  the persisted backend serves beside the transcript: the project's
  conversations (list, new, open), its approval mode and trust, unified diffs
  of edits and changes (`"<id>:diff"` detail refs), background commands, a
  provider rate-limit window, and the toasts commands raise.

  Pure and deterministic like the rest of the fake: identifiers derive from
  request ids, clocks from the script's virtual clock.
  """
  alias SwarmCodeCLI.UI.DataSource.{AdmissionError, Delta, DTO}
  alias DTO.Schema

  @provider "00000000-0000-4000-8000-00000000f001"
  @background "00000000-0000-4000-8000-00000000f0b1"
  @modes [:read_only, :auto, :full_access]

  @repo_diff """
  --- a/lib/swarm_code/repo.ex
  +++ b/lib/swarm_code/repo.ex
  @@ -44,9 +44,12 @@ defmodule SwarmCode.Repo do
     def refresh(token) do
  -    if token.refreshed?, do: {:ok, token}, else: renew(token)
  +    cond do
  +      expired?(token) -> renew(token)
  +      token.refreshed? -> {:ok, token}
  +      true -> renew(token)
  +    end
     end
  +
  +  defp expired?(token), do: DateTime.compare(token.expires_at, DateTime.utc_now()) != :gt
  """

  @test_diff """
  --- a/test/swarm_code/repo_test.exs
  +++ b/test/swarm_code/repo_test.exs
  @@ -9,3 +9,8 @@ defmodule SwarmCode.RepoTest do
     test "refresh keeps a fresh token" do
       assert {:ok, _} = Repo.refresh(fresh())
     end
  +
  +  test "refresh renews an expired token" do
  +    assert {:ok, token} = Repo.refresh(expired())
  +    assert token.refreshed?
  +  end
  """

  @enforce_keys [:conversations, :current, :approval_mode, :trusted, :background, :rate_limits]
  defstruct @enforce_keys ++ [toasts: 0]

  @type t :: %__MODULE__{
          conversations: %{binary() => map()},
          current: binary(),
          approval_mode: :read_only | :auto | :full_access,
          trusted: boolean(),
          background: %{binary() => DTO.BackgroundCommand.t()},
          rate_limits: %{binary() => DTO.RateLimit.t()},
          toasts: non_neg_integer()
        }

  @doc "The provider id of the synthetic rate-limit window."
  def provider_id, do: @provider

  def initial(clock_ms, ids) do
    background = %DTO.BackgroundCommand{
      id: @background,
      run_id: ids.a2,
      agent_id: ids.builder_4,
      pid: 48_213,
      command: "mix test --trace test/swarm_code/repo_test.exs",
      cwd: ".",
      state: :running,
      started_at: clock_ms - 38_000,
      output_bytes: 2_048,
      revision: 1
    }

    limit = %DTO.RateLimit{
      provider_id: @provider,
      provider: "llmotions",
      scope: "requests",
      used_percent: 62.0,
      resets_at: clock_ms + 42_000,
      retry_at: nil,
      revision: 1
    }

    %__MODULE__{
      conversations: %{
        ids.a => %{
          id: ids.a,
          title: "Authentication review",
          created_at: clock_ms - 3_600_000,
          updated_at: clock_ms - 60_000
        },
        ids.b => %{
          id: ids.b,
          title: "Session storage research",
          created_at: clock_ms - 7_200_000,
          updated_at: clock_ms - 600_000
        }
      },
      current: ids.a,
      approval_mode: :auto,
      trusted: true,
      background: %{background.id => background},
      rate_limits: %{limit.provider_id => limit}
    }
  end

  def valid?(%__MODULE__{} = session) do
    is_map(session.conversations) and map_size(session.conversations) in 1..200 and
      Map.has_key?(session.conversations, session.current) and
      Enum.all?(session.conversations, fn {id, row} ->
        Schema.valid?(:id, id) and row.id == id and Schema.valid?({:text, 256}, row.title) and
          Schema.valid?(:count, row.created_at) and Schema.valid?(:count, row.updated_at)
      end) and session.approval_mode in @modes and is_boolean(session.trusted) and
      map_size(session.background) <= 200 and
      Enum.all?(session.background, fn {id, command} ->
        command.id == id and Schema.valid?({:dto, DTO.BackgroundCommand}, command)
      end) and map_size(session.rate_limits) <= 32 and
      Enum.all?(session.rate_limits, fn {id, limit} ->
        limit.provider_id == id and Schema.valid?({:dto, DTO.RateLimit}, limit)
      end) and Schema.valid?(:count, session.toasts)
  end

  def valid?(_), do: false

  @doc "True when `id` is a conversation of the synthetic project."
  def conversation?(%{session: %__MODULE__{conversations: rows}}, id), do: Map.has_key?(rows, id)
  def conversation?(_, _), do: false

  # -- approval card -------------------------------------------------------

  def approval(clock_ms),
    do: %DTO.Approval{
      tool: "run_command",
      permission: :execute,
      arguments_preview:
        ~s({"command":"mix test test/swarm_code/repo_test.exs","justification":"Run the repository tests after the refresh change."}),
      command: "mix test test/swarm_code/repo_test.exs",
      cwd: ".",
      reason: "Run the repository tests after the refresh change.",
      command_family: "mix test",
      classification: :normal,
      agent_id: nil,
      agent_name: "assistant",
      requested_at: clock_ms - 5_000,
      allowed_decisions: [:approve, :approve_run, :always_prefix, :deny, :deny_stop]
    }

  # -- diffs -----------------------------------------------------------------

  @doc "The `detail` reference of an edit's or a change's unified diff."
  def diff_ref(id), do: %DTO.DetailRef{id: id <> ":diff", total_bytes: byte_size(diff(id))}

  @doc "The facts a synthetic checkpoint carries beside its path."
  def change_facts(id, "lib/swarm_code/repo.ex"),
    do: [
      op_id: "00000000-0000-4000-8000-00000000a2e3",
      file_state: :modified,
      added: 42,
      removed: 7,
      diff_ref: diff_ref(id)
    ]

  def change_facts(id, "test/swarm_code/repo_test.exs"),
    do: [file_state: :modified, added: 5, removed: 0, diff_ref: diff_ref(id)]

  def change_facts(_id, _path), do: [file_state: :created, added: 18, removed: 0]

  defp diff("00000000-0000-4000-8000-00000000a2c2"), do: @test_diff
  defp diff(_id), do: @repo_diff

  @diff_owners %{
    "00000000-0000-4000-8000-00000000a2e3" => :tool,
    "00000000-0000-4000-8000-00000000a2c1" => :change,
    "00000000-0000-4000-8000-00000000a2c2" => :change
  }

  @doc "A window of a `\"<id>:diff\"` detail, or nil when `ref` names no diff."
  def detail(script, %{kind: {:query_detail, ref, offset, limit}, scope: scope, request_id: id}) do
    with [owner, "diff"] <- String.split(ref, ":", parts: 2),
         true <- Map.has_key?(@diff_owners, owner),
         true <- in_scope?(script, scope),
         text = diff(owner),
         true <- offset < byte_size(text) do
      chunk =
        SwarmCodeCLI.UI.DataSource.Fake.Details.prefix(
          binary_part(text, offset, byte_size(text) - offset),
          limit
        )

      next = offset + byte_size(chunk)

      DTO.DetailWindow.validate(%DTO.DetailWindow{
        detail_ref: diff_ref(owner),
        offset: offset,
        text: chunk,
        next_offset: if(next == byte_size(text), do: nil, else: next),
        through_sequence: script.sequence,
        request_id: id
      })
    else
      false -> {:error, AdmissionError.new(:invalid_origin)}
      _ -> nil
    end
  end

  # Every synthetic diff belongs to run a2 of conversation a.
  defp in_scope?(_script, %{kind: :global}), do: true

  defp in_scope?(_script, %{kind: :conversation, id: "00000000-0000-4000-8000-00000000000a"}),
    do: true

  defp in_scope?(_script, %{kind: :run, id: "00000000-0000-4000-8000-0000000000a2"}), do: true
  defp in_scope?(_, _), do: false

  # -- conversations -----------------------------------------------------------

  @doc "The keyset page `{:conversation_list, cursor, size, bytes}` asks for."
  def conversation_list(script, %{
        kind: {:conversation_list, cursor, size, bytes},
        request_id: request_id
      }) do
    session = script.session

    rows =
      session.conversations
      |> Map.values()
      |> Enum.sort_by(&{-&1.updated_at, &1.id})
      |> Enum.map(&summary(script, &1))

    start =
      case cursor do
        nil -> 0
        id -> (Enum.find_index(rows, &(&1.id == id)) || -1) + 1
      end

    if cursor != nil and start == 0 do
      {:error, AdmissionError.new(:invalid_request)}
    else
      selected = Enum.slice(rows, start, size)
      more? = start + length(selected) < length(rows)

      page = %DTO.ConversationList{
        project: "swarm-code",
        current_id: session.current,
        items: selected,
        before_cursor: if(start > 0 and selected != [], do: hd(selected).id),
        after_cursor: if(more? and selected != [], do: List.last(selected).id),
        request_id: request_id,
        presence: if(start > 0 or more?, do: :off_window, else: :covered),
        covered_ids: Enum.map(selected, & &1.id),
        through_sequence: script.sequence
      }

      cond do
        :erlang.external_size(page) > bytes -> {:error, AdmissionError.new(:capacity_exceeded)}
        true -> DTO.ConversationList.validate(page)
      end
    end
  end

  defp summary(script, row) do
    runs = Enum.filter(Map.values(script.runs), &(&1.conversation_id == row.id))

    waiting =
      Enum.count(script.interactions, fn {_, q} ->
        q.conversation_id == row.id and q.state == :pending
      end)

    %DTO.ConversationSummary{
      id: row.id,
      title: row.title,
      created_at: row.created_at,
      updated_at: row.updated_at,
      run_count: length(runs),
      live: Enum.any?(runs, &(&1.state in [:running, :streaming, :retrying, :waiting_approval])),
      waiting: waiting,
      unread: false,
      current: row.id == script.session.current
    }
  end

  # -- commands ------------------------------------------------------------------

  def prepare(script, %{kind: {:conversation_new}, request_id: request_id}) do
    id = uuid(request_id)
    session = script.session

    if Map.has_key?(session.conversations, id) do
      {:error, :request_conflict}
    else
      clock = SwarmCodeCLI.UI.DataSource.Fake.Script.clock_ms()

      row = %{
        id: id,
        title: "New conversation",
        created_at: clock + map_size(session.conversations),
        updated_at: clock + map_size(session.conversations)
      }

      session = %{
        session
        | conversations: Map.put(session.conversations, id, row),
          current: id
      }

      {:ok, %{script | session: session}, [], [id]}
    end
  end

  def prepare(script, %{kind: {:conversation_open, id}}) do
    if Map.has_key?(script.session.conversations, id),
      do: {:ok, %{script | session: %{script.session | current: id}}, [], [id]},
      else: {:error, :invalid_origin}
  end

  def prepare(script, %{kind: {:project_update, mode, trusted}, request_id: request_id}) do
    session = script.session
    # Trusting a read-only project lifts it to `auto`, like `Projects.trust/1`.
    mode = mode || if(trusted == true and session.approval_mode == :read_only, do: :auto)

    next = %{
      session
      | approval_mode: mode || session.approval_mode,
        trusted: trusted == true or session.trusted
    }

    text =
      case {mode, trusted} do
        {nil, true} -> "Project trusted; edits are allowed."
        {mode, _} -> "Approval mode: " <> mode_label(mode)
      end

    deltas =
      next.conversations
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map(&metadata_fact(script, next, &1))

    {:ok, %{script | session: next},
     deltas ++ [toast(request_id, :success, "Project", text, nil, nil)], [session.current]}
  end

  defp mode_label(:read_only), do: "read-only"
  defp mode_label(:auto), do: "auto"
  defp mode_label(:full_access), do: "full access"

  defp metadata_fact(script, session, conversation_id),
    do: %Delta{
      kind: :workspace_metadata,
      conversation_id: conversation_id,
      body: %DTO.WorkspaceMetadata{
        conversation_id: conversation_id,
        mode: :build,
        approval_mode: session.approval_mode,
        trusted: session.trusted,
        chat_provider: "llmotions",
        title: session.conversations[conversation_id].title,
        cost_usd: cost(script, conversation_id)
      }
    }

  @doc "Facts a widened approval decision adds after the interaction resolves."
  def decision_facts(script, q, :deny_stop) do
    run = script.runs[q.run_id]

    [
      %Delta{
        kind: :run_update,
        entity_id: run.id,
        run_id: run.id,
        conversation_id: run.conversation_id,
        body: %{
          run
          | state: :stopped,
            revision: run.revision + 2,
            allowed_actions: [],
            needs: 0,
            stop_reason: "user_stopped",
            stop_label: "stopped"
        }
      }
    ]
  end

  def decision_facts(
        _script,
        %{approval: %DTO.Approval{command_family: family}} = q,
        :always_prefix
      )
      when is_binary(family),
      do: [
        toast(
          q.id,
          :success,
          "Always allowed",
          ~s(Commands starting with "#{family}" run without asking in this project.),
          q.run_id,
          q.conversation_id
        )
      ]

  def decision_facts(_script, _q, _decision), do: []

  defp toast(seed, level, title, text, run_id, conversation_id),
    do: %Delta{
      kind: :toast,
      entity_id: uuid("toast:" <> seed),
      run_id: run_id,
      conversation_id: conversation_id,
      body: %DTO.Toast{
        id: uuid("toast:" <> seed),
        level: level,
        title: title,
        text: text,
        run_id: run_id,
        conversation_id: conversation_id,
        at: SwarmCodeCLI.UI.DataSource.Fake.Script.clock_ms()
      }
    }

  # -- canonical state -------------------------------------------------------------

  def apply_delta(%Delta{kind: :background_upsert, body: command}, %{session: s} = script),
    do: %{script | session: %{s | background: Map.put(s.background, command.id, command)}}

  def apply_delta(%Delta{kind: :background_remove, entity_id: id}, %{session: s} = script),
    do: %{script | session: %{s | background: Map.delete(s.background, id)}}

  def apply_delta(%Delta{kind: :rate_limit, body: limit}, %{session: s} = script),
    do: %{script | session: %{s | rate_limits: Map.put(s.rate_limits, limit.provider_id, limit)}}

  def apply_delta(%Delta{kind: :toast}, %{session: s} = script),
    do: %{script | session: %{s | toasts: s.toasts + 1}}

  def apply_delta(%Delta{}, script), do: script

  # -- snapshot fields ---------------------------------------------------------------

  @doc "The pass70 fields of a workspace snapshot for `scope`."
  def workspace_fields(%{session: nil}, _scope), do: []

  def workspace_fields(script, scope) do
    s = script.session

    conversation_id =
      case scope do
        %{kind: :conversation, id: id} -> id
        _ -> nil
      end

    run_ids =
      script.runs
      |> Map.values()
      |> Enum.filter(&scoped?(&1, scope))
      |> MapSet.new(& &1.id)

    [
      approval_mode: s.approval_mode,
      trusted: s.trusted,
      chat_provider: "llmotions",
      context_used: 18_640,
      context_window: 131_072,
      cost_usd: if(conversation_id, do: cost(script, conversation_id)),
      title:
        case s.conversations[conversation_id] do
          %{title: title} -> title
          _ -> nil
        end,
      background:
        s.background
        |> Map.values()
        |> Enum.filter(&MapSet.member?(run_ids, &1.run_id))
        |> Enum.sort_by(& &1.id)
    ]
  end

  @doc "The pass70 fields of a shell snapshot."
  def shell_fields(%{session: nil}), do: []

  def shell_fields(script),
    do: [
      rate_limits: script.session.rate_limits |> Map.values() |> Enum.sort_by(& &1.provider_id)
    ]

  defp scoped?(_run, %{kind: :global}), do: true
  defp scoped?(run, %{kind: :conversation, id: id}), do: run.conversation_id == id
  defp scoped?(run, %{kind: :run, id: id}), do: run.id == id
  defp scoped?(_, _), do: false

  defp cost(script, conversation_id) do
    script.runs
    |> Map.values()
    |> Enum.filter(&(&1.conversation_id == conversation_id))
    |> Enum.map(&(&1.cost_usd || 0.0))
    |> Enum.sum()
    |> Kernel.*(1.0)
    |> Float.round(4)
  end

  defp uuid(seed) do
    <<a::32, b::16, _::4, c::12, _::2, d::14, e::48, _::binary>> = :crypto.hash(:sha256, seed)

    [hex(a, 8), hex(b, 4), "4" <> hex(c, 3), hex(Bitwise.bor(d, 0x8000), 4), hex(e, 12)]
    |> Enum.join("-")
  end

  defp hex(value, size),
    do: value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(size, "0")
end
