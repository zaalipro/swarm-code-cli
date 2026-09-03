defmodule SwarmCodeCLI.UI.Scene do
  alias SwarmCodeCLI.UI.{SafeText, Size}
  alias SwarmCodeCLI.UI.Renderer.Error

  alias SwarmCodeCLI.UI.Scene.{
    Rect,
    Region,
    Dialog,
    Cursor,
    Announcement,
    Block,
    Span,
    Style,
    Color
  }

  defstruct schema_version: 1,
            revision: 0,
            size: nil,
            ambiguous_width: :narrow,
            layout_class: :too_small,
            regions: [],
            overlay: nil,
            cursor: nil,
            announcements: []

  @type t :: %__MODULE__{
          schema_version: 1,
          revision: non_neg_integer(),
          size: Size.t(),
          ambiguous_width: :narrow | :wide,
          layout_class: atom(),
          regions: [Region.t()],
          overlay: Dialog.t() | nil,
          cursor: Cursor.t() | nil,
          announcements: [Announcement.t()]
        }
  @roles [:title, :navigator, :main, :inspector, :activity, :composer, :status]
  @layouts [:xl, :wide, :medium, :narrow, :small, :compressed_small, :too_small]
  @run_states [
    :queued,
    :running,
    :streaming,
    :paused,
    :waiting_question,
    :waiting_approval,
    :completed,
    :failed,
    :cancelled
  ]

  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = scene) do
    if valid_scene?(scene), do: :ok, else: {:error, Error.invalid_scene()}
  end

  def validate(_), do: {:error, Error.invalid_scene()}

  defp valid_scene?(
         %__MODULE__{
           schema_version: 1,
           revision: rev,
           size: %Size{columns: columns, rows: rows} = size,
           ambiguous_width: width,
           layout_class: layout,
           regions: regions,
           overlay: overlay,
           cursor: cursor,
           announcements: announcements
         } = scene
       ) do
    is_integer(rev) and rev >= 0 and is_integer(columns) and columns > 0 and
      is_integer(rows) and rows > 0 and width in [:narrow, :wide] and layout in @layouts and
      is_list(regions) and unique?(Enum.map(regions, &id/1)) and
      Enum.all?(regions, &valid_region?(&1, size)) and valid_dialog?(overlay, size) and
      valid_cursor?(cursor, size) and is_list(announcements) and
      Enum.all?(announcements, &valid_announcement?/1) and unique_action_ids?(scene) and
      not forbidden_term?(scene)
  end

  defp valid_scene?(_), do: false

  defp id(%{id: id}) when is_binary(id) and byte_size(id) > 0, do: id
  defp id(_), do: nil
  defp unique?(items), do: nil not in items and length(items) == length(Enum.uniq(items))

  defp valid_region?(
         %Region{
           id: id,
           role: role,
           rect: rect,
           label: label,
           blocks: blocks,
           focus: focus,
           scroll_offset: scroll,
           visible_range: range,
           follow: follow
         },
         size
       ) do
    is_binary(id) and byte_size(id) > 0 and role in @roles and valid_rect?(rect, size) and
      safe_text?(label) and focus in [:inactive, :active, :contains_focus] and is_list(blocks) and
      Enum.all?(blocks, &valid_block?/1) and optional_nonneg?(scroll) and optional_range?(range) and
      follow in [nil, :none, :start, :end]
  end

  defp valid_region?(_, _), do: false

  defp valid_rect?(%Rect{x: x, y: y, width: width, height: height}, %Size{columns: c, rows: r}) do
    Enum.all?([x, y, width, height], &(is_integer(&1) and &1 >= 0)) and x + width <= c and
      y + height <= r
  end

  defp valid_rect?(_, _), do: false

  defp valid_dialog?(nil, _), do: true

  defp valid_dialog?(
         %Dialog{
           id: id,
           rect: rect,
           title: title,
           blocks: blocks,
           footer: footer,
           focused_control_id: focused,
           body_scroll: scroll,
           body_visible_range: range,
           body_total_count: total
         },
         size
       ) do
    is_binary(id) and byte_size(id) > 0 and valid_rect?(rect, size) and safe_text?(title) and
      is_list(blocks) and Enum.all?(blocks, &valid_block?/1) and is_list(footer) and
      Enum.all?(footer, &valid_block?/1) and (is_nil(focused) or nonempty_binary?(focused)) and
      is_integer(scroll) and scroll >= 0 and is_integer(total) and total >= 0 and scroll <= total and
      bounded_range?(range, total)
  end

  defp valid_dialog?(_, _), do: false

  defp valid_cursor?(nil, _), do: true

  defp valid_cursor?(%Cursor{x: x, y: y, shape: shape, visible?: visible}, %Size{
         columns: c,
         rows: r
       }),
       do:
         is_integer(x) and x >= 0 and x < c and is_integer(y) and y >= 0 and y < r and
           shape in [:block, :bar, :underline] and is_boolean(visible)

  defp valid_cursor?(_, _), do: false

  defp valid_announcement?(%Announcement{id: id, text: text, politeness: politeness}),
    do: nonempty_binary?(id) and safe_text?(text) and politeness in [:polite, :assertive]

  defp valid_announcement?(_), do: false

  defp valid_block?(%Block.Text{text: text, action_id: action}),
    do: safe_text?(text) and action_id?(action)

  defp valid_block?(%Block.RichText{spans: spans, action_id: action}),
    do: is_list(spans) and Enum.all?(spans, &valid_span?/1) and action_id?(action)

  defp valid_block?(%Block.Markdown{text: text}), do: safe_text?(text)

  defp valid_block?(%Block.Code{text: text, language: language}),
    do: safe_text?(text) and (is_nil(language) or safe_text?(language))

  defp valid_block?(%Block.VirtualList{
         total_count: total,
         first_index: first,
         items: items,
         before_cursor: before,
         after_cursor: after_cursor,
         overscan: overscan
       }),
       do:
         nonneg?(total) and nonneg?(first) and first <= total and is_list(items) and
           first + length(items) <= total and
           Enum.all?(items, &valid_block?/1) and opaque?(before) and opaque?(after_cursor) and
           nonneg?(overscan) and overscan <= 2

  defp valid_block?(%Block.RunCard{id: id, title: title, status: status, body: body}),
    do:
      nonempty_binary?(id) and safe_text?(title) and status in @run_states and
        is_list(body) and Enum.all?(body, &valid_block?/1)

  defp valid_block?(%Block.AgentList{agents: agents}), do: valid_display_list?(agents)
  defp valid_block?(%Block.ConsensusLedger{entries: entries}), do: valid_display_list?(entries)

  defp valid_block?(%Block.ResearchDocument{title: title, sources: sources}),
    do: safe_text?(title) and valid_display_list?(sources)

  defp valid_block?(%Block.Progress{label: label, value: value, maximum: maximum}),
    do: safe_text?(label) and nonneg?(value) and nonneg?(maximum) and value <= maximum

  defp valid_block?(%Block.Tabs{tabs: tabs, selected: selected}),
    do:
      valid_display_list?(tabs) and nonneg?(selected) and (tabs == [] or selected < length(tabs))

  defp valid_block?(%Block.KeyValues{rows: rows}),
    do:
      is_list(rows) and
        Enum.all?(rows, fn
          {key, value} -> safe_text?(key) and safe_text?(value)
          _ -> false
        end)

  defp valid_block?(%Block.Composer{text: text, placeholder: placeholder}),
    do: safe_text?(text) and safe_text?(placeholder)

  defp valid_block?(%Block.Notice{severity: severity, text: text, action_id: action}),
    do:
      severity in [:info, :success, :warning, :error] and safe_text?(text) and action_id?(action)

  defp valid_block?(%Block.ActionDeck{actions: actions}), do: valid_display_list?(actions)
  defp valid_block?(_), do: false

  defp valid_display_list?(items) when is_list(items),
    do: Enum.all?(items, &(safe_text?(&1) or valid_span?(&1) or valid_block?(&1)))

  defp valid_display_list?(_), do: false

  defp valid_span?(%Span{text: text, style: style, action_id: action}),
    do: safe_text?(text) and valid_style?(style) and action_id?(action)

  defp valid_span?(_), do: false

  defp valid_style?(%Style{role: role, foreground: fg, background: bg, modifiers: modifiers}),
    do:
      role in Style.roles() and valid_color?(fg) and valid_color?(bg) and is_list(modifiers) and
        Enum.all?(modifiers, &(&1 in Style.modifiers()))

  defp valid_style?(_), do: false
  defp valid_color?(nil), do: true
  defp valid_color?(%Color{role: role}), do: role in Color.roles()
  defp valid_color?(_), do: false

  defp safe_text?(%SafeText{} = text) do
    try do
      is_binary(SafeText.value(text))
    rescue
      _ -> false
    end
  end

  defp safe_text?(_), do: false
  defp action_id?(nil), do: true
  defp action_id?(value), do: nonempty_binary?(value)
  defp opaque?(nil), do: true
  defp opaque?(value), do: nonempty_binary?(value)
  defp nonempty_binary?(value), do: is_binary(value) and byte_size(value) > 0
  defp nonneg?(value), do: is_integer(value) and value >= 0
  defp optional_nonneg?(nil), do: true
  defp optional_nonneg?(value), do: nonneg?(value)
  defp optional_range?(nil), do: true
  defp optional_range?({first, last}), do: nonneg?(first) and nonneg?(last) and first <= last
  defp optional_range?(_), do: false

  defp bounded_range?({first, last}, total),
    do: nonneg?(first) and nonneg?(last) and first <= last and last <= total

  defp bounded_range?(_, _), do: false

  defp unique_action_ids?(scene) do
    ids = action_ids(scene)
    Enum.all?(ids, &nonempty_binary?/1) and length(ids) == length(Enum.uniq(ids))
  end

  defp action_ids(%Span{action_id: id}), do: optional_id(id)
  defp action_ids(%Block.Text{action_id: id}), do: optional_id(id)

  defp action_ids(%Block.RichText{action_id: id, spans: spans}),
    do: optional_id(id) ++ action_ids(spans)

  defp action_ids(%Block.Notice{action_id: id}), do: optional_id(id)

  defp action_ids(%{__struct__: _} = struct),
    do: struct |> Map.from_struct() |> Map.values() |> action_ids()

  defp action_ids(map) when is_map(map), do: map |> Map.values() |> action_ids()
  defp action_ids(list) when is_list(list), do: Enum.flat_map(list, &action_ids/1)
  defp action_ids(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> action_ids()
  defp action_ids(_), do: []
  defp optional_id(nil), do: []
  defp optional_id(id), do: [id]

  defp forbidden_term?(term)
       when is_function(term) or is_pid(term) or is_port(term) or is_reference(term),
       do: true

  defp forbidden_term?(%{__struct__: module} = struct) do
    Map.keys(struct) |> Enum.sort() != Map.keys(module.__struct__()) |> Enum.sort() or
      struct |> Map.from_struct() |> forbidden_term?()
  rescue
    _ -> true
  end

  defp forbidden_term?(map) when is_map(map),
    do: Enum.any?(map, fn {k, v} -> forbidden_term?(k) or forbidden_term?(v) end)

  defp forbidden_term?(list) when is_list(list), do: Enum.any?(list, &forbidden_term?/1)

  defp forbidden_term?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> forbidden_term?()

  defp forbidden_term?(_), do: false
end
