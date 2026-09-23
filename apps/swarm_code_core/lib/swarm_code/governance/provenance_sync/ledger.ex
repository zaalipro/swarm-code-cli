defmodule SwarmCode.Governance.ProvenanceSync.Ledger do
  @moduledoc """
  Reads and writes `provenance/extracted-files.json` byte-compatibly with the
  existing file: `version` then `entries`, two-space indentation, entry keys in
  sorted order (the shape `mix swarm_code.provenance.repin` edits in place).
  """

  @relative "provenance/extracted-files.json"
  @entry_keys ~w(classification destination sha256 upstream_commit upstream_path upstream_sha256)

  @spec relative_path() :: String.t()
  def relative_path, do: @relative

  @spec load(Path.t()) ::
          {:ok, %{version: pos_integer(), entries: [map()]}} | {:error, String.t()}
  def load(root) do
    path = Path.join(root, @relative)

    with {:ok, bytes} <- File.read(path),
         {:ok, %{"version" => 2, "entries" => entries}} when is_list(entries) <-
           Jason.decode(bytes),
         true <- Enum.all?(entries, &entry?/1) do
      {:ok, %{version: 2, entries: entries}}
    else
      _other -> {:error, "#{path} is not a version 2 provenance ledger"}
    end
  end

  @spec write(Path.t(), [map()]) :: :ok
  def write(root, entries) do
    File.write!(Path.join(root, @relative), encode(entries))
  end

  @doc false
  @spec encode([map()]) :: binary()
  def encode(entries) do
    body =
      entries
      |> Enum.map(fn entry ->
        fields =
          Enum.map_join(@entry_keys, ",\n", fn key ->
            ~s(      "#{key}": ) <> Jason.encode!(Map.fetch!(entry, key))
          end)

        "    {\n" <> fields <> "\n    }"
      end)
      |> Enum.join(",\n")

    ~s({\n  "version": 2,\n  "entries": [\n) <> body <> "\n  ]\n}\n"
  end

  defp entry?(entry) do
    is_map(entry) and Enum.sort(Map.keys(entry)) == @entry_keys and
      Enum.all?(@entry_keys, &is_binary(entry[&1]))
  end
end
