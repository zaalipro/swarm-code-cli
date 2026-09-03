defmodule SwarmCode.Daemon.Schema.Binding do
  @moduledoc false

  @enforce_keys [:path, :identity, :sidecars]
  defstruct @enforce_keys

  @type identity ::
          {atom(), non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
  @type t :: %__MODULE__{
          path: Path.t(),
          identity: identity(),
          sidecars: %{String.t() => identity()}
        }
end
