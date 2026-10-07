defmodule SwarmCode.Domain.Missions.Plan do
  @moduledoc """
  Spec 75 §5.5: the mission plan `mission_start` takes — its JSON schema, the
  validation rules and the normal form handed to the builtin `mission` workflow.

  `validate/1` collects every problem (it never stops at the first), rejects
  over-long strings instead of cutting them and returns a string-keyed plan.
  """

  @val ~r/^VAL-[A-Z]{2,8}-\d{3}$/
  @mid ~r/^M\d{1,2}$/
  @fid ~r/^F\d{1,2}$/
  @methods ~w(test command read)

  @max_milestones 6
  @max_features 24
  @max_features_per_milestone 8
  @max_assertions 60
  @max_claims_per_milestone 20
  @max_files 12

  @doc "The `mission_start` parameters — contract §5.5, string keys."
  @spec parameters() :: map()
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "title" => %{
          "type" => "string",
          "description" => "Short mission title (at most 80 characters)"
        },
        "summary" => %{
          "type" => "string",
          "description" => "What the mission delivers, 1-3 sentences"
        },
        "guidelines" => %{
          "type" => "string",
          "description" =>
            "Rules every worker follows: conventions, the exact test/build commands, files never to touch (at most 4000 characters)"
        },
        "knowledge" => %{
          "type" => "string",
          "description" =>
            "What you learned while investigating that workers need: key files, APIs, gotchas (at most 6000 characters)"
        },
        "contract" => %{
          "type" => "array",
          "description" => "The validation contract, written before the features",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "id" => %{
                "type" => "string",
                "description" => "VAL-<AREA>-NNN, AREA 2-8 capital letters, NNN three digits"
              },
              "assertion" => %{
                "type" => "string",
                "description" => "Observable behaviour that must be true (at most 300 characters)"
              },
              "method" => %{"type" => "string", "enum" => @methods},
              "evidence" => %{
                "type" => "string",
                "description" =>
                  "What a validator must capture to prove it (at most 300 characters)"
              }
            },
            "required" => ["id", "assertion", "method", "evidence"]
          }
        },
        "milestones" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "id" => %{"type" => "string", "description" => "M1, M2, … in order"},
              "title" => %{"type" => "string"},
              "features" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "properties" => %{
                    "id" => %{
                      "type" => "string",
                      "description" => "F1, F2, … unique across the mission"
                    },
                    "title" => %{"type" => "string"},
                    "spec" => %{
                      "type" => "string",
                      "description" =>
                        "Self-contained spec for one fresh worker (at most 4000 characters)"
                    },
                    "claims" => %{
                      "type" => "array",
                      "items" => %{"type" => "string"},
                      "description" => "Contract ids this feature satisfies"
                    },
                    "files" => %{
                      "type" => "array",
                      "items" => %{"type" => "string"},
                      "description" => "Files this feature expects to own"
                    }
                  },
                  "required" => ["id", "title", "spec", "claims"]
                }
              }
            },
            "required" => ["id", "title", "features"]
          }
        }
      },
      "required" => ["title", "contract", "milestones"]
    }
  end

  @spec validate(term()) :: {:ok, map()} | {:error, [String.t()]}
  def validate(plan) when is_map(plan) and not is_struct(plan) do
    norm = normalize(plan)

    errors =
      top_errors(norm) ++ contract_errors(norm) ++ milestone_errors(norm) ++ claim_errors(norm)

    if errors == [], do: {:ok, norm}, else: {:error, errors}
  end

  def validate(_plan), do: {:error, ["the plan must be an object"]}

  # ------------------------------------------------------------------ normal form

  defp normalize(plan) do
    %{
      "title" => str(plan["title"]),
      "summary" => str(plan["summary"]),
      "guidelines" => str(plan["guidelines"]),
      "knowledge" => str(plan["knowledge"]),
      "contract" => Enum.map(list(plan["contract"]), &assertion/1),
      "milestones" => Enum.map(list(plan["milestones"]), &milestone/1)
    }
  end

  defp assertion(a) when is_map(a) and not is_struct(a) do
    %{
      "id" => str(a["id"]),
      "assertion" => str(a["assertion"]),
      "method" => str(a["method"]),
      "evidence" => str(a["evidence"])
    }
  end

  defp assertion(_a), do: %{"id" => "", "assertion" => "", "method" => "", "evidence" => ""}

  defp milestone(m) when is_map(m) and not is_struct(m) do
    %{
      "id" => str(m["id"]),
      "title" => str(m["title"]),
      "features" => Enum.map(list(m["features"]), &feature/1)
    }
  end

  defp milestone(_m), do: %{"id" => "", "title" => "", "features" => []}

  defp feature(f) when is_map(f) and not is_struct(f) do
    %{
      "id" => str(f["id"]),
      "title" => str(f["title"]),
      "spec" => str(f["spec"]),
      "claims" => Enum.map(list(f["claims"]), &str/1),
      "files" => Enum.map(list(f["files"]), &str/1)
    }
  end

  defp feature(_f), do: %{"id" => "", "title" => "", "spec" => "", "claims" => [], "files" => []}

  defp str(v) when is_binary(v), do: String.trim(v)
  defp str(nil), do: ""
  defp str(v) when is_number(v) or is_atom(v), do: v |> to_string() |> String.trim()
  defp str(_v), do: ""

  defp list(v) when is_list(v), do: v
  defp list(_v), do: []

  # ------------------------------------------------------------------ rules

  defp top_errors(p) do
    title = p["title"]

    cond_error(title == "", "title is required") ++
      cond_error(String.length(title) > 80, "title is longer than 80 characters") ++
      cond_error(
        String.length(p["guidelines"]) > 4000,
        "guidelines is longer than 4000 characters"
      ) ++
      cond_error(
        String.length(p["knowledge"]) > 6000,
        "knowledge is longer than 6000 characters"
      )
  end

  defp contract_errors(p) do
    contract = p["contract"]

    list_errors =
      cond_error(contract == [], "contract needs at least one assertion") ++
        cond_error(
          length(contract) > @max_assertions,
          "contract has more than #{@max_assertions} assertions"
        )

    ids = Enum.map(contract, & &1["id"])

    dup_errors =
      ids
      |> duplicates()
      |> Enum.map(&"contract id #{&1} appears twice")

    item_errors =
      Enum.flat_map(contract, fn a ->
        id = a["id"]

        cond_error(
          not Regex.match?(@val, id),
          "contract id #{id} must look like VAL-AREA-001"
        ) ++
          cond_error(
            not in_range?(a["assertion"], 300),
            "#{id}: assertion must be 1-300 characters"
          ) ++
          cond_error(
            a["method"] not in @methods,
            "#{id}: method must be test, command or read"
          ) ++
          cond_error(
            not in_range?(a["evidence"], 300),
            "#{id}: evidence must be 1-300 characters"
          )
      end)

    list_errors ++ dup_errors ++ item_errors
  end

  defp milestone_errors(p) do
    milestones = p["milestones"]
    total = milestones |> Enum.map(&length(&1["features"])) |> Enum.sum()

    list_errors =
      cond_error(milestones == [], "milestones needs at least one milestone") ++
        cond_error(
          length(milestones) > @max_milestones,
          "a mission has at most #{@max_milestones} milestones"
        ) ++
        cond_error(total > @max_features, "a mission has at most #{@max_features} features")

    milestone_dups =
      milestones
      |> Enum.map(& &1["id"])
      |> duplicates()
      |> Enum.map(&"milestone id #{&1} appears twice")

    feature_dups =
      milestones
      |> Enum.flat_map(& &1["features"])
      |> Enum.map(& &1["id"])
      |> duplicates()
      |> Enum.map(&"feature id #{&1} appears twice")

    known = p["contract"] |> Enum.map(& &1["id"]) |> MapSet.new()

    item_errors =
      Enum.flat_map(milestones, fn m ->
        mid = m["id"]
        features = m["features"]

        claimed = features |> Enum.flat_map(& &1["claims"]) |> Enum.uniq()

        cond_error(not Regex.match?(@mid, mid), "milestone id #{mid} must look like M1") ++
          cond_error(m["title"] == "", "#{mid}: title is required") ++
          cond_error(features == [], "#{mid}: needs at least one feature") ++
          cond_error(
            length(features) > @max_features_per_milestone,
            "#{mid}: at most #{@max_features_per_milestone} features per milestone"
          ) ++
          Enum.flat_map(features, &feature_errors(&1, known)) ++
          cond_error(
            length(claimed) > @max_claims_per_milestone,
            "#{mid}: claims more than #{@max_claims_per_milestone} assertions"
          )
      end)

    list_errors ++ milestone_dups ++ feature_dups ++ item_errors
  end

  defp feature_errors(f, known) do
    fid = f["id"]

    cond_error(not Regex.match?(@fid, fid), "feature id #{fid} must look like F1") ++
      cond_error(not in_range?(f["title"], 80), "#{fid}: title must be 1-80 characters") ++
      cond_error(not in_range?(f["spec"], 4000), "#{fid}: spec must be 1-4000 characters") ++
      cond_error(f["claims"] == [], "#{fid}: claims at least one contract id") ++
      Enum.flat_map(Enum.uniq(f["claims"]), fn id ->
        cond_error(not MapSet.member?(known, id), "#{fid}: claims unknown id #{id}")
      end) ++
      cond_error(length(f["files"]) > @max_files, "#{fid}: at most #{@max_files} files")
  end

  defp claim_errors(p) do
    owners =
      for m <- p["milestones"], f <- m["features"], id <- f["claims"], reduce: %{} do
        acc -> Map.update(acc, id, MapSet.new([m["id"]]), &MapSet.put(&1, m["id"]))
      end

    p["contract"]
    |> Enum.map(& &1["id"])
    |> Enum.uniq()
    |> Enum.flat_map(fn id ->
      case Map.get(owners, id) do
        nil -> ["#{id} is claimed by no feature"]
        set -> cond_error(MapSet.size(set) > 1, "#{id} is claimed in more than one milestone")
      end
    end)
  end

  # ------------------------------------------------------------------ helpers

  defp cond_error(true, message), do: [message]
  defp cond_error(false, _message), do: []

  defp in_range?(text, max), do: text != "" and String.length(text) <= max

  defp duplicates(values) do
    values
    |> Enum.frequencies()
    |> Enum.filter(fn {_v, n} -> n > 1 end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end
end
