defmodule SwarmCode.Daemon.Service.Elsewhere do
  @moduledoc """
  What the conversations a saved session is not showing are doing, for the
  shell watch (`elsewhere` delta and `ShellSnapshot.elsewhere`).

  A quit stops every live run of the VM and a person can be waited for in any
  conversation, but a client's read model is a normalized cache of what its
  watches loaded: it keeps the rows of an inspector that was closed, and its
  runs page holds the newest 200 only. Neither is a count of what is live, so
  exact session liveness comes from this shell fact: `facts/1` reads the
  engine's own books (the run registry, the waits table); `body/1` is the wire
  form.

    * `total`: every live run of the session, in every conversation. The quit
      confirmation counts exactly this (it is what `Shutdown` stops).
    * `live`: those outside the shown conversation, exact.
    * `waiting`: the approvals and questions waiting outside it, newest 32,
      each named by its node, carrying the conversation's title and `since`
      (when it began to wait, unix microseconds), which orders waits for
      whoever must tell a new one from one that left and came back into the
      32.
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
          kind: :approval | :question,
          since: non_neg_integer()
        }
  @type facts :: %{total: non_neg_integer(), live: non_neg_integer(), waiting: [wait()]}

  @doc "The facts of the session; `live` and `waiting` leave out `current`'s conversation."
  @spec facts(binary() | nil) :: facts()
  def facts(current) do
    runs = Registry.select(SwarmCode.Domain.Registry, [{{{:run, :_}, :_, :"$1"}, [], [:"$1"]}])

    live = Enum.count(runs, &match?({id, _kind} when is_binary(id) and id != current, &1))

    waiting =
      for wait <- Questions.list(),
          is_binary(wait.conversation_id) and wait.conversation_id != current,
          is_binary(wait.run_id) and is_binary(wait.node_id) do
        %{
          id: wait.node_id,
          run_id: wait.run_id,
          conversation_id: wait.conversation_id,
          kind: if(wait.kind == :approval, do: :approval, else: :question),
          since: since(wait.since)
        }
      end

    %{total: length(runs), live: live, waiting: Enum.take(waiting, -@waits)}
  rescue
    ArgumentError -> %{total: 0, live: 0, waiting: []}
  end

  defp since(%DateTime{} = at), do: max(DateTime.to_unix(at, :microsecond), 0)
  defp since(_other), do: 0

  @doc "The wire body of `facts`; a conversation without a title reads `Untitled`."
  @spec body(facts()) :: map()
  def body(%{total: total, live: live, waiting: waiting}) do
    titles = titles(waiting |> Enum.map(& &1.conversation_id) |> Enum.uniq())

    %{
      "total" => total,
      "live" => live,
      "waiting" =>
        for wait <- waiting do
          %{
            "id" => wait.id,
            "run_id" => wait.run_id,
            "conversation_id" => wait.conversation_id,
            "kind" => Atom.to_string(wait.kind),
            "title" => Map.get(titles, wait.conversation_id, "Untitled"),
            "since" => wait.since
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
