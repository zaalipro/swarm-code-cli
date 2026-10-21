defmodule SwarmCode.Daemon.Service.QueueRecovery do
  @moduledoc """
  Review 1019 RC-3 (pass 77 C-BUG-5): the queued prompts a backend still holds in
  memory when it stops.

  A prompt popped off the stored queue whose start and put-back both failed is
  the only copy (`QueueState.held/1`). `hand_over/2` writes those prompts to an
  owner-private journal first (`<config dir>/queue-recovery/<conversation id>.json`,
  mode 0600, same-directory atomic replace), then tries to store them at the head
  of the conversation's queue again; the journal is removed when every prompt is
  stored, and rewritten with the ones that are not. `restore/0` runs when a
  backend starts and finishes what a stopped one could not: it hands the journal
  of every conversation over again, so a prompt is stored once the database is
  free and a crash between the two steps loses nothing.
  """
  require Logger

  alias SwarmCode.Daemon.Files.AtomicReplace
  alias SwarmCode.Domain.Conversations

  # The bounds of what is read back: a journal holds a handful of prompts.
  @max_bytes 16 * 1_024 * 1_024
  @max_texts 1_024

  @doc "The journal directory."
  @spec dir() :: Path.t()
  def dir, do: Path.join(SwarmCode.Domain.Paths.config_dir(), "queue-recovery")

  @doc """
  Stores `texts` (queue order) at the head of the stored queue of `conversation_id`,
  last first so they keep their order, and returns the ones that could not be stored,
  in queue order. A conversation that is gone has nothing left to wait for.
  """
  @spec store(String.t(), [String.t()]) :: [String.t()]
  def store(conversation_id, texts), do: put_back(Enum.reverse(texts), conversation_id)

  defp put_back([], _conversation_id), do: []

  defp put_back([text | earlier] = reversed, conversation_id) do
    case Conversations.requeue_head(conversation_id, text) do
      {:ok, _} -> put_back(earlier, conversation_id)
      {:error, :not_found} -> []
      {:error, _busy} -> Enum.reverse(reversed)
    end
  end

  @doc """
  Journals `texts` behind whatever the journal of `conversation_id` still holds, stores
  them, and leaves the journal with what could not be stored (no file when all were).
  """
  @spec hand_over(String.t(), [String.t()]) :: :ok
  def hand_over(conversation_id, texts) when is_binary(conversation_id) and is_list(texts) do
    pending = read(conversation_id) ++ texts

    if pending != [] do
      # Write-ahead: the journal exists before the database is touched.
      _ = write(conversation_id, pending)

      case store(conversation_id, pending) do
        [] -> remove(conversation_id)
        ^pending -> :ok
        rest -> write(conversation_id, rest)
      end
    end

    :ok
  end

  @doc "Hands every journal in the directory over again (a backend start)."
  @spec restore() :: :ok
  def restore do
    case File.ls(dir()) do
      {:ok, names} ->
        for name <- names, id <- [conversation_id(name)], id != nil, do: hand_over(id, [])
        :ok

      {:error, _} ->
        :ok
    end
  end

  # `<uuid>.json` and nothing else: a journal is found by its canonical name.
  defp conversation_id(name) do
    with ".json" <- Path.extname(name),
         id = Path.basename(name, ".json"),
         {:ok, ^id} <- Ecto.UUID.cast(id) do
      id
    else
      _ -> nil
    end
  end

  defp path(conversation_id), do: Path.join(dir(), conversation_id <> ".json")

  defp write(conversation_id, texts) do
    directory = dir()

    with :ok <- File.mkdir_p(directory),
         :ok <- File.chmod(directory, 0o700),
         :ok <-
           AtomicReplace.write(
             path(conversation_id),
             Jason.encode!(%{
               "version" => 1,
               "conversation_id" => conversation_id,
               "texts" => texts
             }),
             mode: 0o600
           ) do
      :ok
    else
      {:error, reason} ->
        # The log line names the failure, never a prompt.
        Logger.error("queue recovery: the journal could not be written: " <> inspect(reason))
        {:error, reason}
    end
  end

  defp remove(conversation_id) do
    case File.rm(path(conversation_id)) do
      {:error, reason} when reason != :enoent ->
        Logger.error("queue recovery: the journal could not be removed: " <> inspect(reason))

      _ ->
        :ok
    end
  end

  # An unreadable or malformed journal is set aside under another name (nothing is deleted)
  # and counts as empty.
  defp read(conversation_id) do
    file = path(conversation_id)

    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_bytes <- File.stat(file),
         {:ok, body} <- File.read(file),
         {:ok, %{"conversation_id" => ^conversation_id, "texts" => texts}} <- Jason.decode(body),
         true <- is_list(texts) and length(texts) <= @max_texts and Enum.all?(texts, &is_binary/1) do
      texts
    else
      {:error, :enoent} ->
        []

      _ ->
        Logger.warning("queue recovery: a journal could not be read and was set aside")
        _ = File.rename(file, file <> ".unreadable")
        []
    end
  end
end
