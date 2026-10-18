defmodule SwarmCode.Daemon.Service.Elsewhere do
  @moduledoc """
  What the conversations a saved session is not showing are doing, for the
  shell watch (`elsewhere` delta and `ShellSnapshot.elsewhere`).

  A quit stops every live run of the VM and a person can be waited for in any
  conversation, but a client's read model holds the shown conversation only.
  `facts/1` reads the engine's own books (the run registry, the waits table)
  for every other conversation; `body/1` is the wire form.

    * `live`: every live run outside the shown conversation, exact.
    * `waiting`: the approvals and questions waiting there, newest 32, each
      named by its node and carrying the conversation's title.
  """
  import Ecto.Query, only: [from: 2]

  alias SwarmCode.Domain.Conversations.Conversation
  alias SwarmCode.Domain.Engine.Questions

  @waits 32
  @title_bytes 256

  @type wait :: %{
          id: binary(),
          run_id: binary(),
          conversation_id: binary(),
          kind: :approval | :question
        }
  @type facts :: %{live: non_neg_integer(), waiting: [wait()]}

  @doc "The facts of every conversation but `current`."
  @spec facts(binary() | nil) :: facts()
  def facts(current) do
    live =
      SwarmCode.Domain.Registry
      |> Registry.select([{{{:run, :_}, :_, {:"$1", :_}}, [], [:"$1"]}])
      |> Enum.count(&(is_binary(&1) and &1 != current))

    waiting =
      for wait <- Questions.list(),
          is_binary(wait.conversation_id) and wait.conversation_id != current,
          is_binary(wait.run_id) and is_binary(wait.node_id) do
        %{
          id: wait.node_id,
          run_id: wait.run_id,
          conversation_id: wait.conversation_id,
          kind: if(wait.kind == :approval, do: :approval, else: :question)
        }
      end

    %{live: live, waiting: Enum.take(waiting, -@waits)}
  rescue
    ArgumentError -> %{live: 0, waiting: []}
  end

  @doc "The wire body of `facts`; a conversation without a title reads `Untitled`."
  @spec body(facts()) :: map()
  def body(%{live: live, waiting: waiting}) do
    titles = titles(waiting |> Enum.map(& &1.conversation_id) |> Enum.uniq())

    %{
      "live" => live,
      "waiting" =>
        for wait <- waiting do
          %{
            "id" => wait.id,
            "run_id" => wait.run_id,
            "conversation_id" => wait.conversation_id,
            "kind" => Atom.to_string(wait.kind),
            "title" => Map.get(titles, wait.conversation_id, "Untitled")
          }
        end
    }
  end

  defp titles([]), do: %{}

  defp titles(ids) do
    from(c in Conversation, where: c.id in ^ids, select: {c.id, c.title})
    |> SwarmCode.Domain.Repo.all()
    |> Map.new(fn {id, title} -> {id, clip(title)} end)
  rescue
    _ -> %{}
  end

  defp clip(title) when is_binary(title) and title != "",
    do: title |> binary_part(0, min(byte_size(title), @title_bytes)) |> utf8_prefix()

  defp clip(_), do: "Untitled"

  defp utf8_prefix(text),
    do:
      if(String.valid?(text),
        do: text,
        else: utf8_prefix(binary_part(text, 0, byte_size(text) - 1))
      )
end
