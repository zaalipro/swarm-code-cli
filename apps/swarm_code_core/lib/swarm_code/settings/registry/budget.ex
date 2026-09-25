defmodule SwarmCode.Settings.Registry.Budget do
  @moduledoc false
  # §2.19 Budget & usage.
  import SwarmCode.Settings.Registry.Build

  @entries [
    global("budget.monthly_usd", :budget, "Monthly budget",
      description: "A target; nothing is blocked when it runs out. A project file cannot set it.",
      storage: {:setting, :monthly_budget_usd},
      type: :money,
      unit: :usd,
      min: 0,
      big_step: 10,
      nullable: true,
      null_label: "no budget",
      example: 100,
      applies: :at_once,
      shared: true,
      synonyms: ["budget"],
      parity: "D§13"
    ),
    fact("budget.month", :budget, "This month", :usage_month,
      description: "Spend with a gauge against the budget.",
      parity: "D§13"
    ),
    fact("budget.by_model", :budget, "Last 30 days by model", :usage_by_model,
      description: "Tokens in/out and cost; a model without a price says no price.",
      since: :c74,
      parity: "NEW"
    )
  ]

  def entries, do: @entries
end
