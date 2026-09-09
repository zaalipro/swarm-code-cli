defmodule SwarmCode.Commands.Files do
  @moduledoc "Bounded Markdown command loading and exclusive confined command creation."
  alias SwarmCode.Tools.Path, as: SafePath

  @max_bytes 262_144
  @max_total 8 * 1024 * 1024
  @max_entries 1_024
  @template "---\ndescription: What this command does\nswarm: false\n---\nWrite the prompt the agent should receive here.\n\nArguments typed after the command land here: $ARGUMENTS\n"

  def list(opts) do
    if valid_options?(opts) do
      state = %{items: [], errors: [], bytes: 0, members: 0}
      state = read_dir(Keyword.fetch!(opts, :project_root), :project, state)
      state = read_dir(Keyword.fetch!(opts, :global_root), :global, state)

      if state.errors == [] do
        {:ok, state.items |> Enum.reverse() |> Enum.uniq_by(& &1.name) |> Enum.sort_by(& &1.name)}
      else
        {:error, Enum.reverse(state.errors)}
      end
    else
      {:error, [:invalid_options]}
    end
  end

  def create(root, scope, name) do
    cond do
      not valid_path?(root) or scope not in [:project, :global] -> {:error, :invalid_options}
      not valid_name?(name) -> {:error, :invalid_name}
      true -> create_valid(root, scope, name)
    end
  end

  defp create_valid(root, scope, name) do
    with {:ok, real_root} <- SafePath.real_path(root),
         {:ok, %{type: :directory}} <- File.lstat(real_root),
         dir = directory(real_root, scope),
         target = Path.join(dir, name <> ".md"),
         :ok <- confined_target(real_root, target),
         :ok <- check_directories(real_root, dir, true),
         :ok <- make_directories(real_root, dir),
         :ok <- check_directories(real_root, dir, false),
         :ok <- confined_target(real_root, target) do
      publish(real_root, dir, target)
    else
      {:error, :outside_root} -> {:error, :outside_root}
      _ -> {:error, :write_failed}
    end
  end

  defp read_dir(root, scope, state) do
    with {:ok, real_root} <- SafePath.real_path(root),
         dir = directory(real_root, scope),
         :ok <- check_directories(real_root, dir, true),
         {:ok, entries} <- File.ls(dir) do
      if length(entries) + state.members > @max_entries do
        add_error(state, :entry_limit)
      else
        state = %{state | members: state.members + length(entries)}

        entries
        |> Enum.sort()
        |> Enum.reduce_while(state, fn entry, acc ->
          cond do
            :aggregate_limit in acc.errors -> {:halt, acc}
            not valid_path_component?(entry) -> {:cont, add_error(acc, :invalid_command_file)}
            Path.extname(entry) != ".md" -> {:cont, acc}
            true -> {:cont, load_file(real_root, Path.join(dir, entry), scope, acc)}
          end
        end)
      end
    else
      {:error, :enoent} -> state
      {:error, :outside_root} -> add_error(state, :outside_root)
      _ -> add_error(state, :directory_unavailable)
    end
  end

  defp load_file(root, path, scope, state) do
    name = Path.basename(path, ".md") |> String.downcase()

    with true <- valid_name?(name),
         :ok <- confined_target(root, path),
         {:ok, stat} <- File.lstat(path),
         true <- stat.type == :regular,
         {:ok, text} <- bounded_read(path, root, stat, @max_total - state.bytes) do
      state = %{state | bytes: state.bytes + byte_size(text)}

      case parse(text, name) do
        {:ok, metadata, body} ->
          item = Map.merge(metadata, %{name: name, body: body, scope: scope, path: path})
          %{state | items: [item | state.items]}

        {:error, reason} ->
          add_error(state, reason)
      end
    else
      {:error, :outside_root} -> add_error(state, :outside_root)
      {:error, :aggregate_limit} -> add_error(state, :aggregate_limit)
      _ -> add_error(state, :invalid_command_file)
    end
  end

  defp bounded_read(_path, _root, %{size: size}, _remaining) when size > @max_bytes,
    do: {:error, :invalid_command_file}

  defp bounded_read(_path, _root, %{size: size}, remaining) when size > remaining,
    do: {:error, :aggregate_limit}

  defp bounded_read(path, root, stat, remaining) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        try do
          with :ok <- check_directories(root, Path.dirname(path), false),
               :ok <- confined_target(root, path),
               {:ok, info} <- :file.read_file_info(io),
               true <-
                 elem(info, 2) == :regular and elem(info, 11) == stat.inode and
                   elem(info, 9) == stat.major_device,
               {:ok, text} <- read_chunks(io, min(@max_bytes, remaining), [], 0),
               true <- String.valid?(text) do
            {:ok, text}
          else
            {:error, :too_large} when remaining < @max_bytes -> {:error, :aggregate_limit}
            _ -> {:error, :invalid_command_file}
          end
        after
          File.close(io)
        end

      _ ->
        {:error, :invalid_command_file}
    end
  end

  # Even if a file grows after stat, no read requests more than the remaining
  # allowance plus one detection byte. Content is never read with File.read.
  defp read_chunks(io, limit, chunks, size) do
    case :file.read(io, min(16_384, limit - size + 1)) do
      :eof ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {:ok, chunk} when byte_size(chunk) + size <= limit ->
        read_chunks(io, limit, [chunk | chunks], size + byte_size(chunk))

      {:ok, _} ->
        {:error, :too_large}

      _ ->
        {:error, :invalid_command_file}
    end
  end

  defp parse(text, name) do
    text = String.replace(text, "\r\n", "\n")
    {front, body} = split_front(text)

    attrs =
      front
      |> String.split("\n")
      |> Enum.reduce(%{}, fn line, attrs ->
        case String.split(line, ":", parts: 2) do
          [key, value] ->
            Map.put(
              attrs,
              key |> String.trim() |> String.downcase(),
              unquote_value(String.trim(value))
            )

          _ ->
            attrs
        end
      end)

    with {:ok, mode} <- mode(attrs["mode"]),
         {:ok, swarm} <- boolean(attrs["swarm"]),
         description = Map.get(attrs, "description", name),
         true <- byte_size(description) <= 256 do
      {:ok, %{description: description, mode: mode, swarm: swarm}, String.trim(body)}
    else
      _ -> {:error, :invalid_metadata}
    end
  end

  defp split_front("---\n" <> rest = original) do
    case String.split(rest, ~r/^---\s*$/m, parts: 2) do
      [front, body] -> {front, body}
      _ -> {"", original}
    end
  end

  defp split_front(text), do: {"", text}
  defp mode(nil), do: {:ok, nil}
  defp mode(""), do: {:ok, nil}

  defp mode(value) do
    case String.downcase(value) do
      "build" -> {:ok, "build"}
      "plan" -> {:ok, "plan"}
      _ -> {:error, :invalid_metadata}
    end
  end

  defp boolean(nil), do: {:ok, false}

  defp boolean(value) do
    case String.downcase(value) do
      value when value in ["true", "yes", "1"] -> {:ok, true}
      value when value in ["false", "no", "0", ""] -> {:ok, false}
      _ -> {:error, :invalid_metadata}
    end
  end

  defp unquote_value(<<quote, rest::binary>> = original) when quote in [34, 39] do
    if byte_size(rest) > 0 and String.ends_with?(rest, <<quote>>),
      do: binary_part(rest, 0, byte_size(rest) - 1),
      else: original
  end

  defp unquote_value(value), do: value

  defp publish(root, dir, target) do
    temp =
      Path.join(
        dir,
        ".command-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower) <> ".tmp"
      )

    with :ok <- check_directories(root, dir, false),
         :ok <- confined_target(root, target),
         {:ok, io} <- File.open(temp, [:write, :exclusive, :binary, :raw]) do
      try do
        result =
          with :ok <- File.chmod(temp, 0o600),
               :ok <- :file.write(io, @template),
               :ok <- :file.sync(io) do
            :ok
          end

        closed = File.close(io)

        with :ok <- result,
             :ok <- closed,
             :ok <- check_directories(root, dir, false),
             :ok <- confined_target(root, target),
             :ok <- File.ln(temp, target) do
          {:ok, target}
        else
          {:error, :eexist} -> {:error, :exists}
          {:error, :outside_root} -> {:error, :outside_root}
          _ -> {:error, :write_failed}
        end
      after
        File.close(io)
        File.rm(temp)
      end
    else
      {:error, :outside_root} -> {:error, :outside_root}
      _ -> {:error, :write_failed}
    end
  end

  defp confined_target(root, target) do
    with {:ok, real} <- SafePath.real_path(target), true <- SafePath.inside?(root, real) do
      :ok
    else
      _ -> {:error, :outside_root}
    end
  end

  # Canonicalize the caller's root once, then reject symlinks in every descendant
  # directory, including an in-root link. Check again before each mutation.
  defp check_directories(root, dir, allow_missing) do
    relative = Path.relative_to(dir, root)
    paths = if relative == ".", do: [], else: Path.split(relative)

    Enum.reduce_while([root | paths], nil, fn part, parent ->
      path = if parent == nil, do: part, else: Path.join(parent, part)

      case File.lstat(path) do
        {:ok, %{type: :directory}} -> {:cont, path}
        {:error, :enoent} when allow_missing -> {:halt, :missing}
        {:error, :enoent} -> {:halt, {:error, :enoent}}
        _ -> {:halt, {:error, :outside_root}}
      end
    end)
    |> case do
      {:error, _} = error -> error
      _ -> :ok
    end
  end

  defp make_directories(root, dir) do
    parts = Path.split(Path.relative_to(dir, root))

    Enum.reduce_while(parts, root, fn part, parent ->
      path = Path.join(parent, part)

      with :ok <- check_directories(root, parent, false),
           :ok <- make_directory(path),
           :ok <- check_directories(root, path, false) do
        {:cont, path}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:error, _} = error -> error
      _ -> :ok
    end
  end

  defp make_directory(path) do
    case File.mkdir(path) do
      :ok -> File.chmod(path, 0o700)
      {:error, :eexist} -> :ok
      error -> error
    end
  end

  defp directory(root, :project), do: Path.join(root, ".swarm_code/commands")
  defp directory(root, :global), do: Path.join(root, "commands")
  defp add_error(state, reason), do: %{state | errors: [reason | state.errors]}

  defp valid_options?(opts) do
    proper_options?(opts, []) and valid_path?(Keyword.get(opts, :project_root)) and
      valid_path?(Keyword.get(opts, :global_root))
  end

  defp proper_options?([], seen), do: length(seen) == 2

  defp proper_options?([{key, _} | rest], seen) when key in [:project_root, :global_root],
    do: key not in seen and proper_options?(rest, [key | seen])

  defp proper_options?(_, _), do: false

  defp valid_path?(path) do
    is_binary(path) and byte_size(path) in 1..4_096 and String.valid?(path) and
      not String.contains?(path, <<0>>)
  end

  defp valid_path_component?(name) do
    valid_path?(name) and not String.contains?(name, ["/", "\\"])
  end

  defp valid_name?(name) do
    is_binary(name) and byte_size(name) in 1..64 and String.valid?(name) and
      Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}\z/, name)
  end
end
