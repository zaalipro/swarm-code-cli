defmodule SwarmCodeCLI.UI.DataSource.DTO.ShellItem do
  @moduledoc """
  cli020 C15 (competitors-9): a `!` shell command the user ran in this
  conversation, a transcript row of its own. While it runs it is transient
  (`state: :running`, no output yet); at the end it is the persisted shell
  message (`id` is the message's id): the command, the first 2 KB of what it
  printed (`detail_ref` for the rest) and how it ended.

  `exit/1` is the §8.2 view: the exit code, `:stopped`, or nil (still running,
  or it failed to run).
  """
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      id: :id,
      conversation_id: :id,
      command: {:text, 4096},
      output: {:text, 2048},
      state: {:enum, [:running, :done, :stopped, :failed]},
      exit_code: {:optional, :count},
      at: :count,
      revision: :revision,
      detail_ref: {:optional, {:dto, SwarmCodeCLI.UI.DataSource.DTO.DetailRef}}
    ],
    wire_defaults: [detail_ref: nil],
    defaults: [
      id: nil,
      conversation_id: nil,
      command: "",
      output: "",
      state: :running,
      exit_code: nil,
      at: 0,
      revision: 0,
      detail_ref: nil
    ]

  @doc "How it ended: the exit code, `:stopped`, or nil."
  @spec exit(t()) :: non_neg_integer() | :stopped | nil
  def exit(%__MODULE__{state: :stopped}), do: :stopped
  def exit(%__MODULE__{exit_code: code}), do: code
end
