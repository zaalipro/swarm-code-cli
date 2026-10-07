defmodule SwarmCode.Domain.Missions.Outline do
  @moduledoc """
  Spec 75 §5.6: what a LiveView may hold of a mission plan — ids, titles and
  claims, never the feature specs, guidelines, knowledge or evidence texts.
  """

  defstruct title: "",
            summary: "",
            parallel: 1,
            isolate: false,
            max_fix_rounds: 2,
            milestones: [],
            contract: []

  @type t :: %__MODULE__{}

  @spec from_args(map() | nil) :: t() | nil
  def from_args(%{"plan" => %{"milestones" => [_ | _] = milestones} = plan} = args) do
    owner =
      for m <- milestones, f <- m["features"] || [], id <- f["claims"] || [], into: %{} do
        {id, m["id"]}
      end

    %__MODULE__{
      title: to_string(args["title"] || plan["title"] || ""),
      summary: String.slice(to_string(plan["summary"] || ""), 0, 400),
      parallel: int(args["parallel"], 1),
      isolate: args["isolate"] == true,
      max_fix_rounds: rounds(args["max_fix_rounds"]),
      milestones:
        Enum.map(milestones, fn m ->
          features =
            Enum.map(m["features"] || [], fn f ->
              %{id: to_string(f["id"]), title: to_string(f["title"]), claims: f["claims"] || []}
            end)

          %{
            id: to_string(m["id"]),
            title: to_string(m["title"]),
            features: features,
            claims: features |> Enum.flat_map(& &1.claims) |> Enum.uniq()
          }
        end),
      contract:
        Enum.map(plan["contract"] || [], fn a ->
          %{
            id: to_string(a["id"]),
            assertion: String.slice(to_string(a["assertion"]), 0, 160),
            method: to_string(a["method"]),
            milestone: owner[a["id"]]
          }
        end)
    }
  end

  def from_args(_args), do: nil

  # 0 is a real choice ("hand back at once"), unlike a parallelism of 0.
  defp rounds(n) when is_integer(n) and n >= 0, do: n
  defp rounds(_n), do: 2

  defp int(n, _default) when is_integer(n) and n > 0, do: n
  defp int(_n, default), do: default
end
