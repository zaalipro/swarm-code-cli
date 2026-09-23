defmodule SwarmCode.Governance.ProvenanceSync.Rules do
  @moduledoc """
  `provenance/sync-rules.json`: the pinned upstream commit, the ordered rewrite
  table that turns desktop modules into `SwarmCode.Domain.*`, and the mappings
  that say which upstream files are synced, where they land and how they are
  derived (rewritten, formatted, or copied byte for byte).
  """

  defmodule Mapping do
    @moduledoc false
    @enforce_keys [:upstream, :destination, :classification, :rewrite, :format, :select]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            upstream: String.t(),
            destination: String.t(),
            classification: String.t(),
            rewrite: boolean(),
            format: boolean(),
            select: {:include, [Regex.t()]} | {:files, [String.t()]}
          }
  end

  @enforce_keys [:path, :upstream_commit, :rewrite_rules, :mappings, :exclude]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          path: Path.t(),
          upstream_commit: String.t(),
          rewrite_rules: [{String.t(), Regex.t(), String.t()}],
          mappings: [Mapping.t()],
          exclude: [Regex.t()]
        }

  @relative "provenance/sync-rules.json"
  @classifications ~w(source test spec)

  @spec relative_path() :: String.t()
  def relative_path, do: @relative

  @spec load(Path.t()) :: {:ok, t()} | {:error, String.t()}
  def load(root) do
    path = Path.join(root, @relative)

    with {:ok, bytes} <- read(path),
         {:ok, %{} = json} <- decode(bytes, path) do
      build(json, path)
    end
  end

  @doc "The rules with `upstream_commit` replaced, written back in place."
  @spec write_pin(t(), String.t()) :: :ok
  def write_pin(%__MODULE__{path: path}, sha) do
    bytes = File.read!(path)

    updated =
      Regex.replace(~r/"upstream_commit": "[0-9a-f]{40}"/, bytes, ~s("upstream_commit": "#{sha}"),
        global: false
      )

    File.write!(path, updated)
  end

  @doc "Applies the ordered rewrite table."
  @spec rewrite(t(), binary()) :: binary()
  def rewrite(%__MODULE__{rewrite_rules: rules}, source) do
    Enum.reduce(rules, source, fn {_id, regex, replacement}, acc ->
      Regex.replace(regex, acc, replacement)
    end)
  end

  @doc "The mapping that owns `upstream_path`, or nil when it is excluded or unmapped."
  @spec mapping_for(t(), String.t()) :: Mapping.t() | nil
  def mapping_for(%__MODULE__{} = rules, upstream_path) do
    if Enum.any?(rules.exclude, &Regex.match?(&1, upstream_path)) do
      nil
    else
      Enum.find(rules.mappings, &selected?(&1, upstream_path))
    end
  end

  @spec destination(Mapping.t(), String.t()) :: String.t()
  def destination(%Mapping{} = mapping, upstream_path) do
    mapping.destination <> String.replace_prefix(upstream_path, mapping.upstream, "")
  end

  defp selected?(%Mapping{upstream: prefix, select: select}, path) do
    String.starts_with?(path, prefix) and
      case select do
        {:include, globs} ->
          relative = String.replace_prefix(path, prefix, "")
          Enum.any?(globs, &Regex.match?(&1, relative))

        {:files, files} ->
          String.replace_prefix(path, prefix, "") in files
      end
  end

  defp build(json, path) do
    with :ok <- expect(json["version"] == 1, "sync rules version must be 1"),
         :ok <- expect(sha?(json["upstream_commit"]), "sync rules need a 40-hex upstream_commit"),
         {:ok, rewrite_rules} <- rewrite_rules(json["rewrite_rules"]),
         {:ok, mappings} <- mappings(json["mappings"]),
         {:ok, exclude} <- globs(json["exclude"], "exclude") do
      {:ok,
       %__MODULE__{
         path: path,
         upstream_commit: json["upstream_commit"],
         rewrite_rules: rewrite_rules,
         mappings: mappings,
         exclude: exclude
       }}
    end
  end

  defp rewrite_rules(rules) when is_list(rules) and rules != [] do
    Enum.reduce_while(rules, {:ok, []}, fn
      %{"id" => id, "pattern" => pattern, "replacement" => replacement}, {:ok, acc}
      when is_binary(id) and is_binary(pattern) and is_binary(replacement) ->
        case Regex.compile(pattern) do
          {:ok, regex} -> {:cont, {:ok, acc ++ [{id, regex, replacement}]}}
          {:error, _reason} -> {:halt, {:error, "rewrite rule #{id} has an invalid pattern"}}
        end

      _rule, _acc ->
        {:halt, {:error, "every rewrite rule needs id, pattern and replacement"}}
    end)
  end

  defp rewrite_rules(_rules), do: {:error, "sync rules need a non-empty rewrite_rules list"}

  defp mappings(mappings) when is_list(mappings) and mappings != [] do
    Enum.reduce_while(mappings, {:ok, []}, fn mapping, {:ok, acc} ->
      case mapping(mapping) do
        {:ok, built} -> {:cont, {:ok, acc ++ [built]}}
        {:error, _message} = error -> {:halt, error}
      end
    end)
  end

  defp mappings(_mappings), do: {:error, "sync rules need a non-empty mappings list"}

  defp mapping(%{"upstream" => upstream, "destination" => destination} = json)
       when is_binary(upstream) and is_binary(destination) do
    with :ok <- expect(prefix?(upstream), "mapping upstream #{inspect(upstream)} must end in /"),
         :ok <-
           expect(
             prefix?(destination),
             "mapping destination #{inspect(destination)} must end in /"
           ),
         :ok <-
           expect(
             json["classification"] in @classifications,
             "mapping #{upstream} has an invalid classification"
           ),
         :ok <-
           expect(
             is_boolean(json["rewrite"]) and is_boolean(json["format"]),
             "mapping #{upstream} needs boolean rewrite and format"
           ),
         {:ok, select} <- select(json) do
      {:ok,
       %Mapping{
         upstream: upstream,
         destination: destination,
         classification: json["classification"],
         rewrite: json["rewrite"],
         format: json["format"],
         select: select
       }}
    end
  end

  defp mapping(_json), do: {:error, "every mapping needs upstream and destination"}

  defp select(%{"include" => include} = json) when not is_map_key(json, "files") do
    with {:ok, globs} <- globs(include, "include"), do: {:ok, {:include, globs}}
  end

  defp select(%{"files" => files} = json) when not is_map_key(json, "include") do
    if is_list(files) and files != [] and Enum.all?(files, &relative?/1),
      do: {:ok, {:files, files}},
      else: {:error, "mapping files must be a non-empty list of relative paths"}
  end

  defp select(json),
    do: {:error, "mapping #{json["upstream"]} needs exactly one of include or files"}

  defp globs(globs, label) when is_list(globs) do
    if Enum.all?(globs, &relative?/1),
      do: {:ok, Enum.map(globs, &glob_regex/1)},
      else: {:error, "#{label} must list relative glob patterns"}
  end

  defp globs(_globs, label), do: {:error, "sync rules need an #{label} list"}

  @doc false
  @spec glob_regex(String.t()) :: Regex.t()
  def glob_regex(glob) do
    body =
      ~r/\*\*\/|\*\*|\*|\?|[^*?]+/
      |> Regex.scan(glob)
      |> Enum.map_join(fn
        ["**/"] -> "(?:.*/)?"
        ["**"] -> ".*"
        ["*"] -> "[^/]*"
        ["?"] -> "[^/]"
        [literal] -> Regex.escape(literal)
      end)

    Regex.compile!("\\A" <> body <> "\\z")
  end

  defp relative?(path),
    do:
      is_binary(path) and path != "" and Path.type(path) == :relative and
        ".." not in Path.split(path)

  defp prefix?(path), do: relative?(path) and String.ends_with?(path, "/")
  defp sha?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{40}\z/, value)

  defp expect(true, _message), do: :ok
  defp expect(_false, message), do: {:error, message}

  defp read(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _reason} -> {:error, "cannot read #{path}"}
    end
  end

  defp decode(bytes, path) do
    case Jason.decode(bytes) do
      {:ok, %{} = json} -> {:ok, json}
      _other -> {:error, "#{path} is not a JSON object"}
    end
  end
end
