defmodule SwarmCode.Domain.Tools.Ref do
  @moduledoc """
  A tool the model can call: either a builtin module (`kind: :builtin`) or a tool
  exposed by an MCP server (`kind: :mcp`).

  Everything downstream of the registry (AgentServer, Operation, the swarm pane)
  works with refs, so MCP tools need no module.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          parameters: map(),
          kind: :builtin | :mcp | :structured,
          module: module() | nil,
          server_id: String.t() | nil,
          server_name: String.t() | nil,
          tool_name: String.t() | nil,
          read_only?: boolean(),
          enabled?: boolean(),
          permission: :read | :write | :execute | nil,
          schema: map() | nil
        }

  defstruct [
    :name,
    :description,
    :parameters,
    :kind,
    :module,
    :server_id,
    :server_name,
    :tool_name,
    read_only?: false,
    # spec 62 T2: only the Settings list ever sees a ref with `enabled?: false`
    # — `MCP.tools_for/1` drops those before an agent is built.
    enabled?: true,
    permission: nil,
    schema: nil
  ]

  @doc "The permission this call needs."
  @spec permission(t(), map()) :: :read | :write | :execute
  def permission(%__MODULE__{kind: :structured}, _args), do: :read
  def permission(%__MODULE__{kind: :builtin, module: mod}, args), do: mod.permission(args)
  def permission(%__MODULE__{kind: :mcp, read_only?: true}, _args), do: :read
  def permission(%__MODULE__{kind: :mcp}, _args), do: :execute

  @doc "The human title shown on the op row."
  @spec title(t(), map()) :: String.t()
  def title(%__MODULE__{kind: :structured}, _args), do: "structured output"
  def title(%__MODULE__{kind: :builtin, module: mod}, args), do: mod.title(args)

  # spec 61 T8: the collapsed row showed "tavily: tavily_search" and the result
  # preview, never the question — three searches in a row were indistinguishable.
  def title(%__MODULE__{kind: :mcp} = ref, args) do
    base = "#{ref.server_name || "mcp"}: #{ref.tool_name}"

    case first_argument(args) do
      nil -> base
      text -> base <> " — " <> inspect(clip(text))
    end
  end

  # The argument names servers actually use for "what was asked", in order.
  @title_keys ~w(query url input urls path text)a

  defp first_argument(args) when is_map(args) do
    Enum.find_value(@title_keys, fn key ->
      case args[Atom.to_string(key)] || args[key] do
        text when is_binary(text) -> if String.trim(text) == "", do: nil, else: String.trim(text)
        [text | _] when is_binary(text) -> if String.trim(text) == "", do: nil, else: text
        _other -> nil
      end
    end)
  end

  defp first_argument(_args), do: nil

  defp clip(text) do
    if String.length(text) > 60, do: String.slice(text, 0, 59) <> "…", else: text
  end

  # spec 66 T20: the tools that must not run beside another tool call. The
  # modules themselves answer `parallel?/0`; this list is the fallback for a
  # module that does not implement the optional callback — `run_command`
  # belongs to another owner this pass and is named here instead.
  @serial ~w(run_command)

  @doc """
  spec 66 T20: may this call run concurrently with the rest of its batch?

  Builtins answer through `Tools.Tool.parallel?/0` (default true); an MCP tool
  is parallel-safe exactly when it is read-only, because that is all this side
  knows about what the server does.
  """
  @spec parallel?(t()) :: boolean()
  def parallel?(%__MODULE__{kind: :mcp} = ref), do: ref.read_only? == true

  def parallel?(%__MODULE__{module: mod, name: name}) do
    if is_atom(mod) and not is_nil(mod) and Code.ensure_loaded?(mod) and
         function_exported?(mod, :parallel?, 0) do
      mod.parallel?()
    else
      name not in @serial
    end
  end

  @doc "The op_type stored on the node for this tool."
  @spec op_type(t()) :: String.t()
  def op_type(%__MODULE__{kind: :mcp}), do: "mcp"
  def op_type(%__MODULE__{kind: :structured}), do: "structured_output"
  def op_type(%__MODULE__{name: name}), do: name
end
