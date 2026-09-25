defmodule SwarmCode.Daemon.Service.Settings.LSP do
  @moduledoc """
  Language servers in settings (pass 74 §3.5.6, §2.8): the check task (for
  each of the 13 languages the built-in command, the override, the effective
  command, whether its executable is on the PATH, and the clients running per
  project), stopping the running clients, and removing an `lsp_servers` key
  that is not a known language.
  """

  @behaviour SwarmCode.Daemon.Service.Settings.Handler

  import Ecto.Query, warn: false, only: [from: 2]

  alias SwarmCode.Daemon.Service.Settings.Kit
  alias SwarmCode.Daemon.Service.Settings.Providers, as: ProviderSettings
  alias SwarmCode.Domain.{Cache, LSP, Projects, Repo, Settings}
  alias SwarmCode.Domain.LSP.Language
  alias SwarmCode.Domain.Settings.Setting

  @check_ms 5_000

  # §2.8, in its order
  @languages [
    {"elixir", ~w(.ex .exs)},
    {"erlang", ~w(.erl .hrl)},
    {"typescript", ~w(.ts .tsx)},
    {"javascript", ~w(.js .jsx .mjs .cjs)},
    {"python", ~w(.py)},
    {"rust", ~w(.rs)},
    {"go", ~w(.go)},
    {"c", ~w(.c .h)},
    {"cpp", ~w(.cpp .cxx .cc .hpp)},
    {"ruby", ~w(.rb .rake)},
    {"java", ~w(.java)},
    {"swift", ~w(.swift)},
    {"zig", ~w(.zig)}
  ]

  @doc false
  def actions, do: ~w(lsp.check lsp.stop lsp.remove_key)

  @doc false
  def views, do: []

  @doc false
  def cache_reads(_action_or_view), do: []

  @doc "The 13 languages of §2.8."
  @spec languages() :: [String.t()]
  def languages, do: Enum.map(@languages, &elem(&1, 0))

  @doc false
  def query(_view, _kind, _params, _ctx), do: Kit.unsupported()

  ## ------------------------------------------------------------ commands

  @doc false
  def command(%{action: "lsp.check"}, _ctx) do
    overrides = overrides()

    Kit.task(
      action: "lsp.check",
      key: "check",
      timeout_ms: @check_ms,
      cancellable?: true,
      kind: :plain,
      run: fn _report -> {:ok, check(overrides)} end,
      summary: &Map.delete(&1, "rows"),
      redact: []
    )
  end

  def command(%{action: "lsp.stop"} = cmd, _ctx) do
    target = Kit.cmd(cmd, :target)

    roots =
      cond do
        Kit.get(target, "all") == true ->
          {:ok, Enum.map(Projects.list(), & &1.root_path)}

        is_binary(Kit.get(target, "project_id")) ->
          case project(Kit.get(target, "project_id")) do
            nil -> Kit.error(:not_found, "no such project")
            p -> {:ok, [p.root_path]}
          end

        true ->
          Kit.error(:invalid, "name the project, or all")
      end

    with {:ok, roots} <- roots do
      running = clients()
      stopping = Enum.count(running, fn {root, _language} -> root in roots end)

      unless Map.get(cmd, :dry_run), do: Enum.each(roots, &LSP.stop_project/1)

      Kit.ok(
        if(stopping == 0, do: :unchanged, else: :accepted),
        message:
          case stopping do
            0 -> "No language server was running"
            1 -> "1 language server stopped"
            n -> "#{n} language servers stopped"
          end
      )
    end
  end

  def command(%{action: "lsp.remove_key"} = cmd, _ctx) do
    key = Kit.get(Kit.cmd(cmd, :target), "key")

    with true <- is_binary(key) || Kit.error(:invalid, "name the key"),
         true <- key not in languages() || Kit.error(:invalid, "#{key} is a known language"),
         {:ok, expected} <- Kit.expected(cmd, "value") do
      outcome =
        Repo.retry(:settings_lsp, fn ->
          Repo.transaction(fn ->
            fresh = Repo.one(from(s in Setting, order_by: s.inserted_at, limit: 1)) || %Setting{}
            servers = fresh.lsp_servers || %{}

            cond do
              not Map.has_key?(servers, key) ->
                :unchanged

              not Kit.same?(expected, Map.get(servers, key)) ->
                Repo.rollback({:conflict, Map.get(servers, key)})

              Map.get(cmd, :dry_run) ->
                :dry_run

              true ->
                case Settings.update(%{lsp_servers: Map.delete(servers, key)}) do
                  {:ok, _} -> :removed
                  {:error, changeset} -> Repo.rollback({:invalid, changeset})
                end
            end
          end)
        end)

      case outcome do
        {:ok, :removed} ->
          Cache.delete(:settings)
          Kit.ok(results: [Kit.row(key, :accepted)], message: "#{key} removed")

        {:ok, :dry_run} ->
          Kit.ok()

        {:ok, :unchanged} ->
          Kit.ok(:unchanged, message: "#{key} is already gone")

        {:error, {:conflict, current}} ->
          Kit.ok(:conflict,
            results: [Kit.row(key, :conflict, current: current)],
            message: "#{key} changed while you looked at it."
          )

        {:error, {:invalid, changeset}} ->
          Kit.changeset_error(changeset)

        {:error, _other} ->
          Kit.busy()
      end
    end
  end

  def command(_cmd, _ctx), do: Kit.unsupported()

  defp project(id) do
    Projects.get(id)
  rescue
    Ecto.Query.CastError -> nil
  end

  defp overrides do
    case ProviderSettings.settings_row().lsp_servers do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  ## ------------------------------------------------------------ check

  @doc false
  # The check task: one `lsp_language` row per language and the unknown keys.
  def check(overrides) do
    names = Map.new(Projects.list(), &{&1.root_path, &1.name})
    running = Enum.group_by(clients(), &elem(&1, 1), &elem(&1, 0))

    rows =
      for {language, extensions} <- @languages do
        override = Map.get(overrides, language)
        default = default(language)

        effective =
          case override do
            "off" -> nil
            text when is_binary(text) and text != "" -> text
            _ -> default
          end

        executable = effective && effective |> String.split() |> List.first()

        %{
          "language" => language,
          "extensions" => extensions,
          "default" => default,
          "override" => override,
          "effective" => effective,
          "installed" => if(executable, do: System.find_executable(executable) != nil),
          "executable" => executable,
          "running" =>
            running
            |> Map.get(language, [])
            |> Enum.frequencies()
            |> Enum.map(fn {root, n} ->
              %{"project" => Map.get(names, root, Kit.tilde(root)), "count" => n}
            end)
            |> Enum.sort_by(& &1["project"])
        }
      end

    unknown =
      overrides
      |> Enum.reject(fn {key, _} -> key in languages() end)
      |> Enum.sort()
      |> Enum.take(64)
      |> Enum.map(fn {key, value} -> %{"key" => to_string(key), "value" => value} end)

    %{
      "rows" => rows,
      "unknown_keys" => unknown,
      "installed" => Enum.count(rows, &(&1["installed"] == true)),
      "missing" => Enum.count(rows, &(&1["installed"] == false)),
      "running" => rows |> Enum.map(&length(&1["running"])) |> Enum.sum()
    }
  end

  defp default(language) do
    case Language.server_command(language, %{}) do
      nil -> nil
      argv -> Enum.join(argv, " ")
    end
  end

  # `{root, language}` of every running client
  defp clients do
    Registry.select(SwarmCode.Domain.Registry, [
      {{{:lsp, :"$1", :"$2"}, :_, :_}, [], [{{:"$1", :"$2"}}]}
    ])
  end
end
