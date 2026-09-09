defmodule SwarmCode.Domain.Tools.GitStatus do
  @moduledoc "Reports the git status of the project root."
  @behaviour SwarmCode.Domain.Tools.Tool

  alias SwarmCode.Domain.Git

  @impl true
  def name, do: "git_status"

  @impl true
  def description, do: "Show the current branch and the files changed in the working tree."

  @impl true
  def parameters, do: %{"type" => "object", "properties" => %{}}

  @impl true
  def permission(_args), do: :read

  @impl true
  def title(_args), do: "git status"

  @impl true
  def run(_args, ctx, progress) do
    root = ctx.project_root

    if Git.repo?(root) do
      progress.(50, "reading")
      branch = Git.current_branch(root)
      files = Git.status(root)

      body =
        if files == [] do
          "working tree clean"
        else
          Enum.map_join(files, "\n", fn f -> "#{f.x}#{f.y} #{f.path}" end)
        end

      progress.(100, "#{length(files)} file(s)")
      {:ok, "On branch #{branch}\n" <> body}
    else
      {:error, "#{root} is not a git repository"}
    end
  end
end

defmodule SwarmCode.Domain.Tools.GitDiff do
  @moduledoc "Shows the unified diff of the working tree (or the index)."
  @behaviour SwarmCode.Domain.Tools.Tool

  alias SwarmCode.Domain.Git

  @cap 60_000

  @impl true
  def name, do: "git_diff"

  @impl true
  def description,
    do: "Show the unified diff of uncommitted changes. Optionally for one path, or staged only."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Limit the diff to this path"},
        "staged" => %{"type" => "boolean", "description" => "Diff the index instead"}
      }
    }
  end

  @impl true
  def permission(_args), do: :read

  @impl true
  def title(args), do: "git diff" <> if(args["path"], do: " " <> args["path"], else: "")

  @impl true
  def run(args, ctx, progress) do
    root = ctx.project_root

    if Git.repo?(root) do
      progress.(50, "diffing")

      text =
        Git.diff(root,
          paths: if(args["path"], do: [args["path"]]),
          staged: args["staged"] == true
        )

      progress.(100, "done")
      {:ok, cap(if(String.trim(text) == "", do: "no changes", else: text))}
    else
      {:error, "#{root} is not a git repository"}
    end
  end

  defp cap(text) do
    if String.length(text) > @cap,
      do: String.slice(text, 0, @cap) <> "\n…[diff truncated]",
      else: text
  end
end

defmodule SwarmCode.Domain.Tools.GitLog do
  @moduledoc "Shows the recent commits."
  @behaviour SwarmCode.Domain.Tools.Tool

  alias SwarmCode.Domain.Git

  @impl true
  def name, do: "git_log"

  @impl true
  def description, do: "Show the most recent commits, one per line."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "n" => %{"type" => "integer", "description" => "How many commits (default 20)"}
      }
    }
  end

  @impl true
  def permission(_args), do: :read

  @impl true
  def title(_args), do: "git log"

  @impl true
  def run(args, ctx, progress) do
    root = ctx.project_root
    n = min(max(args["n"] || 20, 1), 200)
    progress.(50, "reading")

    case Git.log(root, n) do
      {:ok, out} ->
        progress.(100, "done")
        {:ok, if(String.trim(out) == "", do: "no commits", else: out)}

      {:error, out} ->
        {:error, out}
    end
  end
end

defmodule SwarmCode.Domain.Tools.GitCommit do
  @moduledoc "Commits the working tree."
  @behaviour SwarmCode.Domain.Tools.Tool

  alias SwarmCode.Domain.Git

  @impl true
  def name, do: "git_commit"

  @impl true
  def description,
    do: "Commit changes. Without `paths` everything in the working tree is staged and committed."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "message" => %{"type" => "string", "description" => "The commit message"},
        "paths" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Only commit these paths"
        }
      },
      "required" => ["message"]
    }
  end

  @impl true
  def permission(_args), do: :write

  @impl true
  def title(args), do: "git commit: " <> String.slice(to_string(args["message"] || ""), 0, 50)

  @impl true
  def run(args, ctx, progress) do
    root = ctx.project_root
    paths = if is_list(args["paths"]) and args["paths"] != [], do: args["paths"], else: :all
    progress.(50, "committing")

    case Git.commit(root, to_string(args["message"]), paths) do
      {:ok, out} ->
        progress.(100, "committed")
        {:ok, out}

      {:error, out} ->
        {:error, out}
    end
  end
end
