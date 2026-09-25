defmodule SwarmCode.Daemon.Service.Settings.Cas do
  @moduledoc """
  Compare-and-set helpers every handler uses (pass 74, spec §3.3.5, D7). A
  write carries what the writer last read; the handler compares it with a
  fresh read inside the write's transaction and refuses a mismatch with the
  current value. `{"$any": true}` skips the comparison.
  """

  alias SwarmCode.Settings.WireValue

  @any %{"$any" => true}

  @doc "The expectation that matches anything."
  @spec any() :: map()
  def any, do: @any

  @doc "True for the `$any` expectation."
  @spec any?(term()) :: boolean()
  def any?(expected), do: expected == @any

  @doc "Compare a fresh value with an expectation. `:ok` or `{:conflict, current}`."
  @spec compare(term(), term()) :: :ok | {:conflict, term()}
  def compare(current, expected) do
    if any?(expected) or WireValue.equal?(current, expected),
      do: :ok,
      else: {:conflict, WireValue.canonical(current)}
  end

  @doc """
  Compare the named fields of a fresh record (`%{"name" => value}`) with an
  expectation `%{"fields" => %{...}}`. `:ok` or `{:conflict, fresh_fields}`.
  """
  @spec fields(map(), map() | nil) :: :ok | {:conflict, map()}
  def fields(_fresh, nil), do: :ok

  def fields(fresh, %{"fields" => expected}) when is_map(expected) do
    subset = Map.take(fresh, Map.keys(expected))

    if Enum.all?(expected, fn {name, value} ->
         any?(value) or WireValue.equal?(Map.get(fresh, name), value)
       end),
       do: :ok,
       else: {:conflict, WireValue.canonical(subset)}
  end

  def fields(_fresh, expected), do: if(any?(expected), do: :ok, else: {:conflict, %{}})

  @doc "The fingerprint of file content: `%{\"sha256\" => hex, \"size\" => n}`."
  @spec fingerprint(binary()) :: map()
  def fingerprint(content) when is_binary(content),
    do: %{
      "sha256" => :crypto.hash(:sha256, content) |> Base.encode16(case: :lower),
      "size" => byte_size(content)
    }

  @doc "The fingerprint of a file on disk (`%{\"missing\" => true}` when absent)."
  @spec file_fingerprint(Path.t()) :: map()
  def file_fingerprint(path) do
    case File.read(path) do
      {:ok, content} -> fingerprint(content)
      {:error, _} -> %{"missing" => true}
    end
  end

  @doc "Compare a fingerprint expectation with a file on disk."
  @spec file(Path.t(), map() | nil) :: :ok | {:conflict, map()}
  def file(path, %{"fingerprint" => expected}) do
    current = file_fingerprint(path)

    if current == expected or any?(expected),
      do: :ok,
      else: {:conflict, %{"fingerprint" => current}}
  end

  def file(_path, expected), do: if(any?(expected), do: :ok, else: {:conflict, %{}})
end
