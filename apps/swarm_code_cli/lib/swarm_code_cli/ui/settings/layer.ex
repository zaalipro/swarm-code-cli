defmodule SwarmCodeCLI.UI.Settings.Layer do
  @moduledoc """
  The settings layer while it is open (spec §3.7.1): the page stack, the
  cursor, the mode, the data the pages read, the writes and tasks in flight,
  the drafts and the paste target. Pure data; `Reducer.Settings` owns every
  change.

  The paste (a secret while it is being pasted) and the drafts (which can hold
  a new record's secret fields) never appear in `inspect/1`, logs or crash
  reports.
  """

  alias SwarmCodeCLI.UI.Settings.{Data, Page}

  @derive {Inspect, except: [:paste, :drafts]}
  defstruct generation: 1,
            restore: nil,
            stack: [],
            region: :page,
            rail_cursor: :overview,
            mode: :browse,
            search: nil,
            command_line: nil,
            editing: nil,
            paste: nil,
            popover: nil,
            data: %Data{},
            requests: %{},
            writes: %{},
            step: nil,
            conflicts: %{},
            row_errors: %{},
            tasks: %{},
            drafts: %{},
            staged: %{},
            filter: nil,
            treat_secret: MapSet.new(),
            status: nil,
            changed_elsewhere: %{},
            deep_link: nil,
            page_project_id: nil,
            jump: nil,
            detail_open: false,
            next_launch: MapSet.new(),
            available: true,
            message: nil,
            next_ref: 1,
            file_conflicts: %{}

  @type region :: :search | :rail | :page | :detail
  @type mode :: :browse | :search | :command_line | :editing | :paste | :capture
  @type t :: %__MODULE__{
          generation: pos_integer(),
          restore: nil | map(),
          stack: [Page.t()],
          region: region(),
          rail_cursor: atom(),
          mode: mode(),
          search: nil | map(),
          command_line: nil | map(),
          editing: nil | map(),
          paste: nil | SwarmCodeCLI.UI.Settings.Paste.t(),
          popover: nil | {atom(), term()},
          data: Data.t(),
          requests: map(),
          writes: map(),
          step: nil | map(),
          conflicts: map(),
          row_errors: map(),
          tasks: map(),
          drafts: map(),
          staged: map(),
          filter: nil | map(),
          treat_secret: MapSet.t(),
          status: nil | map(),
          changed_elsewhere: map(),
          deep_link: nil | term(),
          page_project_id: nil | String.t(),
          jump: nil | map(),
          detail_open: boolean(),
          next_launch: MapSet.t(),
          available: boolean(),
          message: nil | String.t(),
          next_ref: pos_integer(),
          file_conflicts: map()
        }

  @regions [:search, :rail, :page, :detail]
  @modes [:browse, :search, :command_line, :editing, :paste, :capture]

  @doc "The four regions focus moves between."
  def regions, do: @regions

  @doc "The layer's modes."
  def modes, do: @modes

  @doc "A layer of generation `generation` whose stack is `stack` (the Overview when empty)."
  @spec new(pos_integer(), [Page.t()]) :: t()
  def new(generation, stack \\ []) do
    stack = if stack == [], do: [Page.section(:overview)], else: stack
    %__MODULE__{generation: generation, stack: stack, rail_cursor: hd(stack).section}
  end

  @doc "The page on screen (the head of the stack)."
  @spec page(t()) :: Page.t()
  def page(%__MODULE__{stack: [page | _]}), do: page
  def page(%__MODULE__{}), do: Page.section(:overview)

  @doc "The section on screen."
  @spec section(t()) :: atom()
  def section(%__MODULE__{} = layer), do: page(layer).section

  @doc "Replace the page on screen."
  @spec put_page(t(), Page.t()) :: t()
  def put_page(%__MODULE__{stack: [_ | rest]} = layer, %Page{} = page),
    do: %{layer | stack: [page | rest]}

  def put_page(%__MODULE__{} = layer, %Page{} = page), do: %{layer | stack: [page]}

  @doc "Update the page on screen."
  @spec update_page(t(), (Page.t() -> Page.t())) :: t()
  def update_page(%__MODULE__{} = layer, fun), do: put_page(layer, fun.(page(layer)))

  @doc "Push a deeper page (a record page or a sub-page)."
  @spec push(t(), Page.t()) :: t()
  def push(%__MODULE__{stack: stack} = layer, %Page{} = page),
    do: %{layer | stack: [page | stack]}

  @doc "Pop one level; `:top` when the page on screen is a section page (Esc then closes)."
  @spec pop(t()) :: {:ok, t()} | :top
  def pop(%__MODULE__{stack: [_page, parent | rest]} = layer),
    do: {:ok, %{layer | stack: [parent | rest]}}

  def pop(%__MODULE__{}), do: :top

  @doc "The depth of the stack (1 = a section page)."
  @spec depth(t()) :: non_neg_integer()
  def depth(%__MODULE__{stack: stack}), do: length(stack)
end
