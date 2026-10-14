defmodule SwarmCodeCLI.UI.Home.CopyCommand do
  @moduledoc """
  orbit U7: the command that opens a conversation of another project in its own
  terminal tab: `ncode <path> -r <8-character id prefix>`.

  Pure. A project has one session at a time, so a conversation elsewhere cannot
  be opened in this tab; Home copies the command instead (D14) and says so.

  The path is written the way a person would type it:

    * under the home folder and made only of `A-Za-z0-9._/@+-`: `~/rest`;
    * otherwise, when the whole path is made only of those: as it is;
    * otherwise single-quoted, a `'` inside becoming `'\\''`. Nothing inside quotes
      expands, so a quoted path is always absolute.
  """

  @safe ~r/\A[A-Za-z0-9._\/@+-]+\z/
  @prefix_length 8

  @doc "The shell command that opens `conversation_id` of the project at `root_path`."
  @spec command(binary(), binary(), binary() | nil) :: binary()
  def command(root_path, conversation_id, home_dir) do
    "ncode " <> path(root_path, home_dir) <> " -r " <> prefix(conversation_id)
  end

  @doc "The id prefix `-r` takes: the first 8 characters."
  @spec prefix(term()) :: binary()
  def prefix(id) when is_binary(id), do: String.slice(id, 0, @prefix_length)
  def prefix(_id), do: ""

  @doc "The path as the command writes it (see the moduledoc)."
  @spec path(binary(), binary() | nil) :: binary()
  def path(root_path, home_dir) when is_binary(root_path) do
    case under_home(root_path, home_dir) do
      {:ok, rest} ->
        if Regex.match?(@safe, rest), do: "~/" <> rest, else: bare_or_quoted(root_path)

      :error ->
        bare_or_quoted(root_path)
    end
  end

  def path(_root_path, _home_dir), do: "''"

  @doc "The path for display: `~/rest` under the home folder, else as it is (never quoted)."
  @spec abbreviate(binary(), binary() | nil) :: binary()
  def abbreviate(root_path, home_dir) when is_binary(root_path) do
    case under_home(root_path, home_dir) do
      {:ok, rest} -> "~/" <> rest
      :error -> root_path
    end
  end

  def abbreviate(_root_path, _home_dir), do: ""

  defp bare_or_quoted(path) do
    if Regex.match?(@safe, path),
      do: path,
      else: "'" <> String.replace(path, "'", "'\\''") <> "'"
  end

  defp under_home(path, home) when is_binary(home) do
    home = String.trim_trailing(home, "/")

    cond do
      home == "" -> :error
      String.starts_with?(path, home <> "/") -> rest_after(path, home)
      true -> :error
    end
  end

  defp under_home(_path, _home), do: :error

  defp rest_after(path, home) do
    case binary_part(path, byte_size(home) + 1, byte_size(path) - byte_size(home) - 1) do
      "" -> :error
      rest -> {:ok, rest}
    end
  end
end
