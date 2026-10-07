# spec 70 B3
defmodule SwarmCode.Domain.LSP do
  @moduledoc """
  Public API for LSP operations. Lazily starts one client per {project, language}.
  """

  alias SwarmCode.Domain.LSP.{Client, Language}

  @doc "Registry key for an LSP client."
  def via(project_root, language),
    do: {:via, Registry, {SwarmCode.Domain.Registry, {:lsp, project_root, language}}}

  @doc """
  Send an LSP request for `file_path` in `project_root`.

  Detects the language from the extension, ensures a client is running, and
  forwards the request. Returns `{:ok, result}` or `{:error, reason}`.

  spec 74 BUGS-7: a new client is started only with `trusted?: true` — a
  language server runs the project's code, so the caller must have checked the
  project's trust. `env:` is the child's environment (default: the scrubbed
  `RunCommand.clean_env/1`).
  """
  @spec request(String.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, term()} | {:error, String.t()}
  def request(project_root, file_path, method, params, opts \\ []) do
    overrides = opts[:lsp_servers] || %{}

    case Language.detect(file_path) do
      nil ->
        ext = Path.extname(file_path)
        {:error, "no language server for #{ext}"}

      language ->
        case Language.server_command(language, overrides) do
          nil ->
            {:error, "no language server configured for #{language}"}

          command ->
            timeout = opts[:timeout] || 30_000

            case ensure_client(project_root, language, command, opts) do
              {:ok, pid} ->
                case Client.request(pid, method, params, timeout) do
                  # spec 74 EFFICIENCY-53: the client stopped between the
                  # lookup and the call (idle shutdown): once more, fresh.
                  {:error, :gone} ->
                    retry_request(project_root, language, command, opts, method, params, timeout)

                  other ->
                    other
                end

              {:error, reason} ->
                {:error, reason}
            end
        end
    end
  end

  defp retry_request(project_root, language, command, opts, method, params, timeout) do
    with {:ok, pid} <- ensure_client(project_root, language, command, opts) do
      case Client.request(pid, method, params, timeout) do
        {:error, :gone} -> {:error, "server not running"}
        other -> other
      end
    end
  end

  @doc "Stop all LSP clients for a project."
  @spec stop_project(String.t()) :: :ok
  def stop_project(project_root) do
    # Walk the registry for all {:lsp, project_root, _language} entries.
    match = {{:lsp, project_root, :"$1"}, :"$2", :"$3"}
    guards = []
    body = [:"$2"]

    Registry.select(SwarmCode.Domain.Registry, [{match, guards, body}])
    |> Enum.each(&Client.stop/1)
  end

  defp ensure_client(project_root, language, command, opts) do
    case Registry.lookup(SwarmCode.Domain.Registry, {:lsp, project_root, language}) do
      [{pid, _}] ->
        if Process.alive?(pid),
          do: {:ok, pid},
          else: start_client(project_root, language, command, opts)

      [] ->
        start_client(project_root, language, command, opts)
    end
  end

  defp start_client(project_root, language, command, opts) do
    if opts[:trusted?] == true do
      env = opts[:env] || SwarmCode.Domain.Tools.RunCommand.clean_env(%{})
      do_start_client(project_root, language, command, env)
    else
      {:error,
       "language servers build and run project code — trust the project first " <>
         "(banner above the composer)"}
    end
  end

  defp do_start_client(project_root, language, command, env) do
    spec = Client.child_spec({project_root, language, command, env})

    case start_child(spec) do
      {:ok, pid} ->
        {:ok, pid}

      {:unavailable, reason} ->
        {:error, "language server unavailable: " <> reason}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, {:not_installed, exe}} ->
        {:error, "#{exe} is not installed — install it or set lsp_servers in Settings"}

      {:error, {{:not_installed, exe}, _}} ->
        {:error, "#{exe} is not installed — install it or set lsp_servers in Settings"}

      {:error, reason} ->
        {:error, "could not start LSP client: #{inspect(reason)}"}
    end
  end

  # spec 74 BUGS-17: a supervisor that is restarting (or gone) exits the
  # caller; that is an answer for the tool, never an exit through `Operation`.
  defp start_child(spec) do
    DynamicSupervisor.start_child(SwarmCode.Domain.LSP.ClientSup, spec)
  catch
    :exit, reason -> {:unavailable, inspect(reason, limit: 5)}
  end
end
