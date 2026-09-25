defmodule SwarmCodeCLI.UI.Settings.Section do
  @moduledoc """
  A settings section page (spec §3.7.2). Pure: every callback reads a
  `Settings.Ctx` and returns rows or ops; U1's layer does the rest.

  `use SwarmCodeCLI.UI.Settings.Section, id: :agents_limits` injects the
  defaults: `loads/1` asks for the section's values, `rows/1` draws every
  registry entry of the section grouped by `group` (`Rows.registry/2`), and
  `act/3`/`commit/3` answer `:default` (U1's generic handling). Override what
  the page needs.
  """

  alias SwarmCodeCLI.UI.Settings.{Attention, Ctx, Op, Row, Rows}

  @callback id() :: atom()
  @callback loads(Ctx.t()) :: [Op.load()]
  @callback rows(Ctx.t()) :: [Row.t()]
  @callback record_rows(Ctx.t(), kind :: String.t(), id :: String.t()) :: [Row.t()]
  @callback sub_rows(Ctx.t(), sub :: term()) :: [Row.t()]
  @callback act(Ctx.t(), Row.t(), action :: atom()) :: [Op.t()] | :default
  @callback commit(Ctx.t(), Row.t(), wire_value :: term()) :: [Op.t()] | :default
  @callback title(Ctx.t()) :: String.t()
  @callback attention(Ctx.t()) :: [Attention.t()]
  @callback counts(Ctx.t()) :: %{records: non_neg_integer() | nil}
  @doc "A picker's choice (`on_pick: {:section, id, tag}`): the ops it means."
  @callback picked(Ctx.t(), tag :: term(), value :: term()) :: [Op.t()]
  @doc """
  The service wants a file this section handed to the user's editor
  confirmed (`spec` = `%{content, fingerprint}`): the op(s) that ask and save
  again with the confirmation.
  """
  @callback confirm_external(Ctx.t(), spec :: map(), items :: list()) :: Op.t() | [Op.t()]
  @doc "The rows a long page's `/` filter keeps (else the layer matches the row text)."
  @callback filter(Ctx.t(), [Row.t()], query :: String.t()) :: [Row.t()]
  @optional_callbacks record_rows: 3,
                      sub_rows: 2,
                      act: 3,
                      commit: 3,
                      title: 1,
                      attention: 1,
                      counts: 1,
                      picked: 3,
                      confirm_external: 3,
                      filter: 3

  defmacro __using__(opts) do
    id = Keyword.fetch!(opts, :id)

    quote do
      @behaviour SwarmCodeCLI.UI.Settings.Section

      @impl true
      def id, do: unquote(id)

      @impl true
      def loads(ctx), do: SwarmCodeCLI.UI.Settings.Section.default_loads(unquote(id), ctx)

      @impl true
      def rows(ctx), do: SwarmCodeCLI.UI.Settings.Section.default_rows(unquote(id), ctx)

      @impl true
      def record_rows(_ctx, _kind, _id), do: []

      @impl true
      def sub_rows(_ctx, _sub), do: []

      @impl true
      def act(_ctx, _row, _action), do: :default

      @impl true
      def commit(_ctx, _row, _value), do: :default

      @impl true
      def title(_ctx), do: SwarmCodeCLI.UI.Settings.Sections.title(unquote(id))

      @impl true
      def attention(_ctx), do: []

      @impl true
      def counts(_ctx), do: %{records: nil}

      defoverridable loads: 1,
                     rows: 1,
                     record_rows: 3,
                     sub_rows: 2,
                     act: 3,
                     commit: 3,
                     title: 1,
                     attention: 1,
                     counts: 1
    end
  end

  @doc "The default loads: the section's values."
  @spec default_loads(atom(), Ctx.t()) :: [Op.load()]
  def default_loads(:overview, _ctx), do: [:overview]
  def default_loads(id, _ctx), do: [{:values, [id]}]

  @doc "The default rows: every registry entry of the section, grouped, then the danger group."
  @spec default_rows(atom(), Ctx.t()) :: [Row.t()]
  def default_rows(id, ctx), do: Rows.registry(ctx, id)
end
