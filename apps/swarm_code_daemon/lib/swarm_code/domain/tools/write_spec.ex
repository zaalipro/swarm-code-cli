defmodule SwarmCode.Domain.Tools.WriteSpec do
  @moduledoc """
  Consensus mode with an implementer (spec 45 §6.2): the planner hands over
  the approved plan as a spec file under `<root>/.swarm_code/specs`, the
  implementer — a worker on the implementer model — works it task by task,
  and its report comes back as the tool result. Blocks like `submit_plan`
  does, on `RunServer.await_agent/3`, and reports the ticked tasks as progress
  while it waits.
  """
  @behaviour SwarmCode.Domain.Tools.Tool

  alias SwarmCode.Domain.Engine.{Consensus, RunServer, SpecTemplate}
  alias SwarmCode.Domain.Tools

  @implementer_max_turns 120
  @poll_ms 5_000
  @implement_head "# How to implement"

  @impl true
  def name, do: "write_spec"

  @impl true
  def description,
    do:
      "Consensus mode: save the approved plan as a spec file (Requirements → Design → Tasks, " <>
        "per SPEC WORKFLOW) under .swarm_code/specs and hand it to the implementer model. " <>
        "Returns the implementer's report."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string", "description" => "the feature name (names the file)"},
        "spec" => %{
          "type" => "string",
          "description" => "the whole spec as markdown — Requirements, Design, Tasks"
        }
      },
      "required" => ["title", "spec"]
    }
  end

  @impl true
  def permission(_args), do: :write

  @impl true
  def title(args) do
    case slug(args["title"]) do
      "" -> "spec"
      slug -> "spec " <> slug
    end
  end

  @impl true
  def run(args, ctx, progress) do
    title = String.trim(to_string(args["title"] || ""))
    spec = String.trim_trailing(to_string(args["spec"] || ""))

    cond do
      title == "" -> {:error, "title must not be empty"}
      spec == "" -> {:error, "spec must not be empty"}
      true -> write_and_implement(title, spec, ctx, progress)
    end
  end

  # spec 60 T2: belt and braces — plan mode writes nothing even if the tool is reached.
  defp write_and_implement(title, spec, ctx, progress) do
    case RunServer.consensus_config(ctx.run_id) do
      %{mode: "plan"} -> {:error, "plan mode: no spec is written and nothing is implemented"}
      _other -> write_spec_file(title, spec, ctx, progress)
    end
  end

  # spec 60 T3: confined like every other file tool (`Tools.Path.resolve/2`, resolved
  # again after the mkdir so a link planted in between is caught) and created
  # exclusively — a number taken between the scan and the open is retried, never
  # overwritten.
  defp write_spec_file(title, spec, ctx, progress) do
    root = ctx.project_root

    spec =
      if String.contains?(spec, @implement_head),
        do: spec <> "\n",
        else: spec <> "\n\n" <> SpecTemplate.implement_block() <> "\n"

    with {:ok, _} <- Tools.Path.resolve(root, ".swarm_code"),
         {:ok, dir} <- Tools.Path.resolve(root, ".swarm_code/specs"),
         :ok <- File.mkdir_p(dir),
         {:ok, dir} <- Tools.Path.resolve(root, ".swarm_code/specs"),
         {:ok, path, file} <- create_exclusive(dir, title, spec, 20) do
      rel = Path.join([".swarm_code", "specs", file])

      # The UI reads the relative path from `detail` and the file from
      # `workspace_path` (spec 45 §6.3).
      RunServer.update_node(ctx.run_id, ctx.node_id, %{
        title: "spec " <> file,
        detail: rel,
        workspace_path: path
      })

      case RunServer.consensus_config(ctx.run_id) do
        %{} = config ->
          implement(config, path, rel, ctx, progress)

        _other ->
          {:ok, "Spec written to #{rel}. No implementer is configured — implement it yourself."}
      end
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "cannot write the spec: #{:file.format_error(reason)}"}
    end
  end

  # spec 60 T3: `:exclusive` — a number taken between the scan and the open is retried, never overwritten.
  defp create_exclusive(_dir, _title, _spec, 0),
    do: {:error, "could not allocate a spec number after 20 tries"}

  defp create_exclusive(dir, title, spec, tries) do
    file = "#{next_number(dir)}_#{slug(title)}_spec.md"
    path = Path.join(dir, file)

    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, io} ->
        result = IO.binwrite(io, spec)
        File.close(io)
        if result == :ok, do: {:ok, path, file}, else: {:error, "cannot write #{file}"}

      {:error, :eexist} ->
        create_exclusive(dir, title, spec, tries - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp implement(config, path, rel, ctx, progress) do
    implementer = Map.get(config, :implementer)

    if is_nil(implementer) do
      {:ok, "Spec written to #{rel}. No implementer is configured — implement it yourself."}
    else
      {done, total} = Consensus.spec_tasks(path)
      progress.(pct(done, total), "task #{done} of #{total}")

      opts =
        [
          capability: :all,
          max_turns: @implementer_max_turns,
          model_map: implementer,
          system_extra:
            "You are the implementer of a consensus run: a spec was approved by a judge; " <>
              "your job is to implement it exactly, task by task.\n\n" <>
              SpecTemplate.implement_block()
        ]
        |> then(fn opts ->
          case Map.get(config, :implementer_effort) do
            effort when is_binary(effort) and effort != "" -> Keyword.put(opts, :effort, effort)
            _none -> opts
          end
        end)

      {:ok, node_id} =
        RunServer.start_agent(ctx.run_id, %{
          parent_id: ctx.node_id,
          role: "worker",
          name: "Implementer",
          prompt: implementer_prompt(rel),
          opts: opts
        })

      model = implementer_name(implementer)
      await(ctx.run_id, node_id, path, rel, model, progress)
    end
  end

  # Spec 45 §6.2: every five seconds the ticked boxes become the op's progress.
  defp await(run_id, node_id, path, rel, model, progress) do
    case RunServer.await_agent(run_id, node_id, @poll_ms) do
      {:error, :timeout} ->
        {done, total} = Consensus.spec_tasks(path)
        progress.(pct(done, total), "task #{done} of #{total}")
        await(run_id, node_id, path, rel, model, progress)

      {:ok, text} ->
        {done, total} = Consensus.spec_tasks(path)
        progress.(100, "#{done}/#{total} tasks")

        {:ok,
         "IMPLEMENTER REPORT (#{model}):\n#{text}\n\nSpec: #{rel} — #{done}/#{total} tasks ticked."}

      # Spec 51 §5.9 (a): a stopped implementer lands here too, as the stop
      # it is — never as an IMPLEMENTER REPORT.
      {:error, reason} ->
        {done, total} = Consensus.spec_tasks(path)
        progress.(100, "implementer failed")

        {:ok,
         "IMPLEMENTER FAILED: #{reason}. Spec: #{rel} — #{done}/#{total} tasks ticked. " <>
           "Finish the remaining tasks yourself or report."}
    end
  end

  defp implementer_prompt(rel) do
    "Implement the spec at #{rel} (inside this project). Read the whole file first with " <>
      "read_file. Work the tasks in order, one at a time; after each task run the checks it " <>
      "names, then tick its box in the file (edit_file: `- [ ]` → `- [x]`). If something the " <>
      "spec names does not exist, or a check fails twice, stop and describe the problem under " <>
      "\"## Blockers\" in the file. Finish with a report: tasks done, tasks left, blockers, " <>
      "the commands you ran and their results."
  end

  defp implementer_name(%{model: model}) when is_binary(model), do: model
  defp implementer_name(%{"model" => model}) when is_binary(model), do: model
  defp implementer_name(_other), do: "implementer"

  defp pct(_done, 0), do: nil
  defp pct(done, total), do: min(100, round(done / total * 100))

  # `01` on an empty directory, else one past the highest numeric prefix —
  # two digits at least, like the repo's own `.specs/` (spec 45 §6.2).
  defp next_number(dir) do
    names =
      case File.ls(dir) do
        {:ok, names} -> names
        _ -> []
      end

    highest =
      names
      |> Enum.map(fn name ->
        case Regex.run(~r/^(\d+)/, name) do
          [_, digits] -> String.to_integer(digits)
          nil -> 0
        end
      end)
      |> Enum.max(fn -> 0 end)

    (highest + 1) |> Integer.to_string() |> String.pad_leading(2, "0")
  end

  @doc false
  def slug(title) do
    title
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
    |> String.slice(0, 40)
    |> String.trim("_")
  end
end
