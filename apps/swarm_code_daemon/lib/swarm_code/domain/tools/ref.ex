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

  def title(%__MODULE__{kind: :mcp} = ref, _args),
    do: "#{ref.server_name || "mcp"}: #{ref.tool_name}"

  @doc "The op_type stored on the node for this tool."
  @spec op_type(t()) :: String.t()
  def op_type(%__MODULE__{kind: :mcp}), do: "mcp"
  def op_type(%__MODULE__{kind: :structured}), do: "structured_output"
  def op_type(%__MODULE__{name: name}), do: name
end
