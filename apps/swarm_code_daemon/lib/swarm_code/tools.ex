defmodule SwarmCode.Tools do
  @moduledoc "Closed, validated registry of project coding tools owned by the daemon."

  alias SwarmCode.Tools.{EditFile, Grep, ListDir, ReadFile, RunCommand, WriteFile}

  @tools %{
    "read_file" => ReadFile,
    "list_dir" => ListDir,
    "grep" => Grep,
    "write_file" => WriteFile,
    "edit_file" => EditFile,
    "run_command" => RunCommand
  }
  @max_string_bytes 5_000_000

  def specs do
    @tools
    |> Enum.sort()
    |> Enum.map(fn {name, module} ->
      %{name: name, description: module.description(), parameters: module.parameters()}
    end)
  end

  def permission(name, args) do
    with {:ok, module} <- lookup(name),
         :ok <- validate(module, args) do
      {:ok, module.permission(args)}
    end
  end

  def run(name, args, context, progress) do
    with {:ok, module} <- lookup(name),
         :ok <- validate(module, args),
         :ok <- validate_context(context),
         true <- is_function(progress, 2) do
      module.run(args, context, progress)
    else
      false -> {:error, "invalid progress callback"}
      {:error, _} = error -> error
    end
  rescue
    _error -> {:error, "tool operation failed"}
  catch
    :throw, :file_grew_too_large -> {:error, "file grew beyond the 5 MB read limit"}
  end

  defp lookup(name) when is_binary(name) do
    case Map.fetch(@tools, name) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, "unknown tool: #{String.slice(name, 0, 100)}"}
    end
  end

  defp lookup(_), do: {:error, "tool name must be a string"}

  defp validate(module, args) when is_map(args) and not is_struct(args) do
    schema = module.parameters()
    properties = schema["properties"]

    cond do
      Enum.any?(schema["required"], &(not Map.has_key?(args, &1))) ->
        {:error, "missing required tool argument"}

      Enum.any?(args, fn {key, value} ->
        not Map.has_key?(properties, key) or not valid_value?(key, value, properties[key])
      end) ->
        {:error, "invalid tool arguments"}

      true ->
        :ok
    end
  end

  defp validate(_, _), do: {:error, "tool arguments must be an object"}

  defp valid_value?(key, value, %{"type" => "string"}) do
    max_size = if key in ["path", "glob", "pattern"], do: 16_384, else: @max_string_bytes
    max_size = if key == "command", do: 65_536, else: max_size

    is_binary(value) and String.valid?(value) and byte_size(value) <= max_size and
      not String.contains?(value, <<0>>) and
      (key not in ["path", "command"] or String.trim(value) != "")
  end

  defp valid_value?("depth", value, %{"type" => "integer"}),
    do: is_integer(value) and value in 1..3

  defp valid_value?("max_results", value, %{"type" => "integer"}),
    do: is_integer(value) and value in 1..500

  defp valid_value?("limit", value, %{"type" => "integer"}),
    do: is_integer(value) and value in 1..5000

  defp valid_value?("timeout_ms", value, %{"type" => "integer"}),
    do: is_integer(value) and value in 1..600_000

  defp valid_value?(_, value, %{"type" => "integer"}),
    do: is_integer(value) and value > 0 and value <= 2_147_483_647

  defp valid_value?(_, value, %{"type" => "boolean"}), do: is_boolean(value)
  defp valid_value?(_, _, _), do: false

  defp validate_context(%{project_root: root} = context) when is_binary(root) do
    settings = Map.get(context, :settings, %{})

    if String.valid?(root) and not String.contains?(root, <<0>>) and
         Path.type(root) == :absolute and File.dir?(root) and is_map(settings) and
         valid_timeout?(Map.get(settings, :command_timeout_ms, 120_000)) do
      :ok
    else
      {:error, "invalid tool context"}
    end
  end

  defp validate_context(_), do: {:error, "invalid tool context"}
  defp valid_timeout?(value), do: is_integer(value) and value in 1..600_000
end
