defmodule SwarmCode.Daemon.Service.Settings.Handler do
  @moduledoc """
  A settings handler module (pass 74, spec §3.3.2). The Router maps actions
  and view kinds to handlers by a static table. `attention/1` and `glance/1`
  feed the Overview; `cache_reads/1` declares the task-cache entries a view or
  action needs (the backend copies only those into `ctx.task_results`).
  """

  alias SwarmCode.Daemon.Service.Settings.{Command, Context, Error, Result, TaskSpec}

  @type cache_read :: {String.t(), :all | :target | :sessions_store | {:param, String.t()}}

  @callback actions() :: [String.t()]
  @callback views() :: [{view :: String.t(), kind :: String.t() | nil}]
  @callback command(Command.t(), Context.t()) ::
              {:ok, Result.t()} | {:task, TaskSpec.t(), Result.t()} | {:error, Error.t()}
  @callback query(view :: String.t(), kind :: String.t() | nil, params :: map(), Context.t()) ::
              {:ok, map()} | {:error, Error.t()}
  @callback attention(Context.t()) :: [map()]
  @callback glance(Context.t()) :: map()
  @callback cache_reads(action_or_view :: String.t()) :: [cache_read()]
  @optional_callbacks attention: 1, glance: 1, cache_reads: 1
end
