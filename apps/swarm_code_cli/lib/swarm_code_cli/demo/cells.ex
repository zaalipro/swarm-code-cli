defmodule SwarmCodeCLI.Demo.Cells.Directory do
  @moduledoc false

  # Read-only admission check. Missing suffixes are allowed; existing components
  # must all be directories, including the final output directory when present.
  def check_ancestors(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> Enum.reduce_while("", fn component, parent ->
      current = if parent == "", do: component, else: Path.join(parent, component)

      case File.lstat(current) do
        {:ok, %{type: :directory}} -> {:cont, current}
        {:error, :enoent} -> {:cont, current}
        _ -> {:halt, {:error, :unsafe_output_path}}
      end
    end)
    |> case do
      {:error, _} = error -> error
      _ -> :ok
    end
  end
end

defmodule SwarmCodeCLI.Demo.Cells do
  @moduledoc """
  Exports a fixed, synthetic cell gallery without starting applications or reading
  user input. Output is always a fresh directory under repository
  `_build/cell-previews`; filenames and fixtures are closed.

  `run/0` returns `{:ok, %{directory: absolute_path, files: sorted_relative_names}}`
  or `{:error, reason}`, where reason is `:unsafe_output_path`, `:output_failed`,
  or `:render_failed`. A failed export removes only its freshly owned directory.
  Existing directories and files are never replaced. SVG colors are preview
  approximations, not native terminal acceptance evidence.
  """
  alias SwarmCodeCLI.Demo.Cells.Directory
  alias SwarmCodeCLI.UI.{Capabilities, Fixtures, Paint, Projector, Size}
  alias SwarmCodeCLI.UI.DataSource.DTO.{Approval, PendingInteraction, Question, QuestionOption}
  alias SwarmCodeCLI.UI.Paint.{Options, SVG}

  @root Path.expand("../../../../..", __DIR__)
  @output Path.join(@root, "_build/cell-previews")
  # `{kind, {columns, rows}, color_mode, ascii?, glyph_tier}`.
  @core for kind <- [:chat, :swarm, :consensus, :research],
            size <- [{80, 24}, {120, 40}, {160, 50}],
            do: {kind, size, :truecolor, false, :measured}
  @dialogs for kind <- [:question, :confirmation],
               size <- [{80, 24}, {50, 16}],
               do: {kind, size, :monochrome, true, :measured}
  # The agents tab at both glyph tiers, on a 56-cell dock, and the waiting card.
  @pane [
    {:swarm, {170, 42}, :truecolor, false, :rich},
    {:swarm, {170, 42}, :truecolor, false, :measured},
    {:consensus, {170, 42}, :truecolor, false, :rich},
    {:approval, {170, 42}, :truecolor, false, :rich},
    {:swarm, {150, 30}, :truecolor, false, :rich}
  ]
  @examples @core ++ @dialogs ++ @pane ++ [{:too_small, {49, 13}, :monochrome, true, :measured}]

  @spec run() ::
          {:ok, %{directory: binary(), files: [binary()]}}
          | {:error, :unsafe_output_path | :output_failed | :render_failed}
  def run do
    with :ok <- prepare_parent(), {:ok, directory} <- fresh_directory(10) do
      result = export(directory)
      if match?({:error, _}, result), do: cleanup(directory)
      result
    end
  end

  defp prepare_parent do
    with :ok <- Directory.check_ancestors(@output) do
      case File.mkdir(@output) do
        :ok -> :ok
        {:error, :eexist} -> Directory.check_ancestors(@output)
        _ -> {:error, :output_failed}
      end
    end
  end

  defp fresh_directory(0), do: {:error, :output_failed}

  defp fresh_directory(attempts) do
    suffix =
      "#{System.system_time(:microsecond)}-#{System.unique_integer([:positive, :monotonic])}"

    path = Path.join(@output, "preview-" <> suffix)

    with :ok <- Directory.check_ancestors(path) do
      case File.mkdir(path) do
        :ok -> {:ok, path}
        {:error, :eexist} -> fresh_directory(attempts - 1)
        _ -> {:error, :output_failed}
      end
    end
  end

  defp export(directory) do
    result =
      Enum.reduce_while(@examples, {:ok, []}, fn example, {:ok, files} ->
        filename = filename(example)

        with {:ok, svg} <- render(example),
             :ok <- write(directory, filename, svg) do
          {:cont, {:ok, [filename | files]}}
        else
          error -> {:halt, error}
        end
      end)

    with {:ok, files} <- result,
         :ok <- write(directory, "index.html", gallery()) do
      {:ok, %{directory: directory, files: Enum.sort(["index.html" | files])}}
    end
  rescue
    _ -> {:error, :render_failed}
  end

  defp render({kind, {columns, rows}, mode, ascii?, tier}) do
    size = %Size{columns: columns, rows: rows}
    capabilities = %Capabilities{size: size, color_mode: mode, ascii?: ascii?, glyph_tier: tier}
    state = fixture(kind, size, capabilities)
    {scene, _table} = Projector.project(state)
    options = %Options{color_mode: mode, ascii?: ascii?, glyph_tier: tier}

    with {:ok, plan} <- Paint.build(scene, options),
         {:ok, svg} <- SVG.encode(plan) do
      {:ok, svg}
    else
      _ -> {:error, :render_failed}
    end
  end

  defp fixture(:question, size, capabilities) do
    state = Fixtures.representative(:chat, size, capabilities)

    interaction = %PendingInteraction{
      id: "preview-question",
      run_id: "fixture-run",
      node_id: "preview-node",
      conversation_id: "fixture-conversation",
      expected_revision: 3,
      question: %Question{
        prompt: "Which synthetic change should be reviewed first?",
        options: [
          %QuestionOption{id: "layout", label: "Review the workspace layout"},
          %QuestionOption{id: "actions", label: "Check the visible action controls"}
        ]
      },
      allowed_actions: [:answer_question]
    }

    state = put_in(state.read_model.interactions[interaction.id], interaction)
    %{state | layers: [{:question, interaction.id}], focus: "layout"}
  end

  defp fixture(:confirmation, size, capabilities) do
    state = Fixtures.representative(:chat, size, capabilities)
    %{state | layers: [{:confirm_intent, {:run_control, :stop, "fixture-run"}}], focus: "cancel"}
  end

  # A swarm whose builder waits for permission to run a command: the waiting
  # card under the lead card, and the count on the strip.
  defp fixture(:approval, size, capabilities) do
    state = Fixtures.representative(:swarm, size, capabilities) |> wide_dock()

    interaction = %PendingInteraction{
      id: "preview-approval",
      run_id: "fixture-run",
      node_id: "agent-4",
      conversation_id: "fixture-conversation",
      kind: :approval,
      expected_revision: 4,
      approval: %Approval{
        tool: "run_command",
        permission: :execute,
        arguments_preview: "mix ecto.migrate"
      },
      allowed_actions: [:approve, :deny],
      urgency: :high,
      created_at: state.now - 1_000
    }

    state = put_in(state.read_model.interactions[interaction.id], interaction)
    put_in(state.read_model.agents["agent-4"].state, :waiting_approval)
  end

  defp fixture(:too_small, size, capabilities),
    do: Fixtures.representative(:chat, size, capabilities)

  defp fixture(kind, size, capabilities),
    do: Fixtures.representative(kind, size, capabilities) |> wide_dock()

  # From 170 columns the dock has room for the two-column sub-agent grid.
  defp wide_dock(%{size: %Size{columns: columns}} = state) when columns >= 170,
    do: %{state | preferences: %{state.preferences | inspector_width: 56}}

  defp wide_dock(state), do: state

  defp filename({kind, {columns, rows}, mode, ascii?, tier}) do
    name = if kind == :too_small, do: "too-small", else: Atom.to_string(kind)
    suffix = if(ascii?, do: "-ascii", else: "") <> if(tier == :rich, do: "-rich", else: "")
    "#{name}-#{columns}x#{rows}-#{mode}#{suffix}.svg"
  end

  defp write(directory, filename, content) do
    path = Path.join(directory, filename)

    with :ok <- Directory.check_ancestors(directory) do
      case File.write(path, content, [:write, :exclusive]) do
        :ok -> :ok
        _ -> {:error, :output_failed}
      end
    end
  end

  defp cleanup(directory) do
    if Directory.check_ancestors(directory) == :ok, do: File.rm_rf(directory)
    :ok
  end

  defp gallery do
    figures =
      Enum.map(@examples, fn {kind, {columns, rows}, mode, ascii?, tier} = example ->
        label =
          "#{kind} / #{columns} × #{rows} / #{mode}" <>
            if(ascii?, do: " / ASCII", else: "") <> if(tier == :rich, do: " / rich", else: "")

        "<figure><figcaption>#{label}</figcaption><img src=\"#{filename(example)}\" " <>
          "alt=\"#{label} synthetic cell preview\" width=\"#{columns * 10}\" " <>
          "height=\"#{rows * 20}\"></figure>"
      end)

    [
      "<!doctype html><html lang=\"en\"><meta charset=\"utf-8\">",
      "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
      "<title>Synthetic cell previews</title><style>",
      "*{box-sizing:border-box}body{margin:0;background:#101010;color:#f3f2f0;",
      "font:15px/1.5 system-ui,sans-serif;padding:32px}header{max-width:900px;margin-bottom:32px}",
      "h1{font-size:32px;line-height:1.15;margin:12px 0}p{color:#b6b5b3}",
      "main{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,800px),1fr));gap:32px}",
      "figure{margin:0;min-width:0}figcaption{padding:0 0 10px;color:#c9c8c5}",
      "img{display:block;width:auto;max-width:100%;height:auto;background:#141414;border:1px solid #343434}",
      "@media(max-width:600px){body{padding:16px}h1{font-size:26px}}",
      "</style><body><header><strong>FAKE DEMO — NO USER DATA</strong>",
      "<h1>Synthetic cell previews</h1><p>Fixed fixtures for reviewing terminal cell geometry. ",
      "Read-only SVGs; colors and font rendering are browser approximations. ",
      "These are not native terminal acceptance frames.</p></header><main>",
      figures,
      "</main></body></html>"
    ]
  end
end
