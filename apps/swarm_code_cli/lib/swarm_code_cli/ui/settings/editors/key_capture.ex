defmodule SwarmCodeCLI.UI.Settings.Editors.KeyCapture do
  @moduledoc """
  pass74 (spec F11, §3.7.8, §3.9.3, §4.3 `settings_capture`): the key-capture
  editor. While it captures, every key is data (`{:raw, {code, mods}}`); the
  first chord pressed is the value.

  Two modes:

    * `:binding` (the Key bindings sub-page, cli.json `"keys"`): opts
      `%{mode: :binding, binding: "<binding id>", add?: boolean}`. Enter on a
      binding replaces its keys; `+` (`add?: true`) adds one (≤ 4). The commit
      value is the whole `keys` map after the change, so a swap of two
      bindings is one cli.json write. A key another binding holds stops the
      capture and offers `s swap` (the other takes this binding's key),
      `r replace` (the other keeps its remaining keys), `k press another key`
      and `Esc keep`. A fixed or unreportable key offers `k` and `Esc`.
    * `:desktop` (the desktop app's shortcuts, a web combo string): opts
      `%{mode: :desktop, action: "file_finder"}`. A modifier is required
      except for Esc; ⌘ cannot be captured in a terminal, so after a capture
      `t` types a combo instead (`meta+shift+s`), Enter commits it.

  Esc pressed once is captured as `Esc` (refused as fixed); Esc twice within
  1.5 s cancels. Pure: time is `ctx.now`.
  """

  alias SwarmCodeCLI.UI.Keymap.{KeyName, Overrides}

  @double_esc_ms 1_500
  @max_keys 4
  @combo ~r/\A(?:Escape|(?:meta|ctrl|shift|alt)(?:\+(?:meta|ctrl|shift|alt))*\+(?:[a-zA-Z0-9,.;=\-]|Arrow(?:Left|Right|Up|Down)))\z/

  @type state :: %{
          mode: :binding | :desktop,
          binding: String.t() | nil,
          action: String.t() | nil,
          add?: boolean(),
          phase: :capture | :taken | :refused | :typing,
          pressed: nil | String.t(),
          message: nil | String.t(),
          proposal: nil | map(),
          typed: String.t(),
          last_esc: nil | integer()
        }

  @doc false
  def init(row, opts, ctx) do
    opts = opts || %{}
    mode = Map.get(opts, :mode, :binding)

    state = %{
      mode: mode,
      binding: Map.get(opts, :binding),
      action: Map.get(opts, :action),
      add?: Map.get(opts, :add?, false) == true,
      phase: :capture,
      pressed: nil,
      message: nil,
      proposal: nil,
      typed: "",
      last_esc: nil,
      label: Map.get(opts, :label) || Map.get(row || %{}, :label) || ""
    }

    cond do
      mode == :binding and is_nil(Overrides.id(state.binding || "")) ->
        {:error, "no binding is called #{state.binding}"}

      mode == :binding and Overrides.fixed?(Overrides.id(state.binding)) ->
        {:error, ~s("#{state.label}" cannot be remapped)}

      mode == :binding and state.add? and length(current_keys(state, ctx)) >= @max_keys ->
        {:error, "4 keys at most"}

      true ->
        {:ok, state}
    end
  end

  # ------------------------------------------------------------------ keys

  @doc false
  def handle(%{phase: :capture} = state, {:raw, {:escape, []}}, ctx), do: escape(state, ctx)
  def handle(%{phase: :capture} = state, {:key, :escape}, ctx), do: escape(state, ctx)

  def handle(%{phase: :capture} = state, {:raw, {code, mods}}, ctx),
    do: captured(state, {code, Enum.sort(mods)}, ctx)

  def handle(%{phase: :capture} = state, {:text, text}, ctx) when byte_size(text) > 0,
    do: captured(state, {String.first(text), []}, ctx)

  def handle(%{phase: :capture} = state, {:key, key}, ctx) when is_atom(key),
    do: captured(state, {raw_code(key), []}, ctx)

  def handle(%{phase: :capture} = state, _event, _ctx), do: {:cont, state}

  # After a message the capture has ended: the letters are the ways out.
  def handle(%{phase: :typing} = state, event, _ctx), do: typing(state, event)

  def handle(%{phase: phase} = state, event, _ctx) when phase in [:taken, :refused] do
    case letter(event) do
      "s" when phase == :taken and not is_nil(state.proposal) ->
        {:commit, state.proposal.swap, state}

      "r" when phase == :taken and not is_nil(state.proposal) ->
        {:commit, state.proposal.replace, state}

      "k" ->
        {:cont, %{state | phase: :capture, pressed: nil, message: nil, proposal: nil}}

      "t" when state.mode == :desktop ->
        {:cont, %{state | phase: :typing, typed: "", message: nil}}

      :escape ->
        {:cancel, state}

      _ ->
        {:cont, state}
    end
  end

  defp escape(state, ctx) do
    now = Map.get(ctx || %{}, :now, 0)

    if is_integer(state.last_esc) and now - state.last_esc <= @double_esc_ms do
      {:cancel, state}
    else
      state = %{state | last_esc: now}

      if state.mode == :desktop do
        {:commit, "Escape", state}
      else
        {:cont,
         %{
           state
           | pressed: "Esc",
             message: "Esc is fixed · Esc again cancels",
             phase: :capture
         }}
      end
    end
  end

  defp captured(%{mode: :desktop} = state, key, _ctx) do
    case combo(key) do
      {:ok, combo} ->
        {:commit, combo, state}

      {:error, message} ->
        {:cont,
         %{state | phase: :refused, pressed: KeyName.name(key), message: message, last_esc: nil}}
    end
  end

  defp captured(state, key, ctx) do
    name = KeyName.name(key)
    overrides = Map.get(ctx || %{}, :overrides)
    current = current_keys(state, ctx)

    names =
      if state.add?,
        do: Enum.uniq(Enum.map(current, &KeyName.name/1) ++ [name]),
        else: [name]

    state = %{state | pressed: name, last_esc: nil}

    case Overrides.check(overrides, state.binding, names) do
      :ok ->
        {:commit, keys_map(ctx, state.binding, names), state}

      {:error, message} ->
        if String.contains?(message, " is taken by ") do
          {:cont,
           %{state | phase: :taken, message: message, proposal: proposal(state, names, ctx)}}
        else
          {:cont, %{state | phase: :refused, message: message, proposal: nil}}
        end
    end
  end

  defp proposal(state, names, ctx) do
    overrides = Map.get(ctx || %{}, :overrides)
    [name | _] = Enum.take(names, -1)

    case Overrides.bindings_for_key(overrides, name)
         |> Enum.reject(fn {b, _} -> Atom.to_string(b.id) == state.binding end) do
      [{other, _contexts} | _] ->
        other_sid = Atom.to_string(other.id)
        {:ok, [key]} = first_key(name)
        theirs = Overrides.effective_keys(overrides, other.id) -- [key]
        base = source(ctx)

        swap =
          case Overrides.swap(overrides, state.binding, names) do
            {:ok, swapped} ->
              base
              |> Map.put(state.binding, Map.fetch!(swapped, state.binding))
              |> Map.put(other_sid, Map.fetch!(swapped, other_sid))

            {:error, _} ->
              nil
          end

        replace =
          base
          |> Map.put(state.binding, names)
          |> Map.put(other_sid, Enum.map(theirs, &KeyName.name/1))

        %{
          other: other.label,
          other_keys: Enum.map(theirs, &KeyName.name/1),
          swap: swap,
          replace: replace
        }

      [] ->
        nil
    end
  end

  defp first_key(name) do
    case KeyName.keys(name) do
      {:ok, [key | _]} -> {:ok, [key]}
      error -> error
    end
  end

  defp typing(state, {:text, text}), do: {:cont, %{state | typed: state.typed <> text}}

  defp typing(state, {:key, :backspace}),
    do: {:cont, %{state | typed: String.slice(state.typed, 0..-2//1)}}

  defp typing(state, {:key, {:ctrl, "u"}}), do: {:cont, %{state | typed: ""}}
  defp typing(state, {:key, :escape}), do: {:cancel, state}
  defp typing(state, {:raw, {:escape, []}}), do: {:cancel, state}

  defp typing(state, {:key, :enter}) do
    typed = String.trim(state.typed)

    if Regex.match?(@combo, typed),
      do: {:commit, typed, state},
      else: {:cont, %{state | message: "invalid key combo"}}
  end

  defp typing(state, _event), do: {:cont, state}

  defp letter({:text, <<c::utf8>>}), do: <<c::utf8>>
  defp letter({:raw, {<<c::utf8>>, []}}), do: <<c::utf8>>
  defp letter({:raw, {:escape, []}}), do: :escape
  defp letter({:key, :escape}), do: :escape
  defp letter(_), do: nil

  defp raw_code(:space), do: " "
  defp raw_code(key), do: key

  # --------------------------------------------------------------- desktop

  @doc """
  A captured terminal key as the desktop's web combo (`ctrl+shift+s`,
  `shift+alt+ArrowLeft`): modifiers in the order meta, ctrl, shift, alt, the
  key lower-cased; a modifier is required except for Esc.
  """
  @spec combo({term(), [atom()]}) :: {:ok, String.t()} | {:error, String.t()}
  def combo({:escape, []}), do: {:ok, "Escape"}

  def combo({code, mods}) do
    key =
      case code do
        :left -> "ArrowLeft"
        :right -> "ArrowRight"
        :up -> "ArrowUp"
        :down -> "ArrowDown"
        text when is_binary(text) -> String.downcase(text)
        _ -> nil
      end

    shift? = :shift in mods or (is_binary(code) and code != String.downcase(code))

    prefix =
      [{"ctrl", :control in mods}, {"shift", shift?}, {"alt", :alt in mods}]
      |> Enum.filter(&elem(&1, 1))
      |> Enum.map(&elem(&1, 0))

    combo = Enum.join(prefix ++ [key || ""], "+")

    cond do
      prefix == [] -> {:error, "the desktop needs a modifier (Ctrl, Alt or Shift) with the key"}
      is_nil(key) or not Regex.match?(@combo, combo) -> {:error, "invalid key combo"}
      true -> {:ok, combo}
    end
  end

  @doc "Whether `combo` is a combo the desktop accepts (its validator's grammar)."
  @spec combo?(term()) :: boolean()
  def combo?(combo) when is_binary(combo), do: Regex.match?(@combo, combo)
  def combo?(_), do: false

  # --------------------------------------------------------------- display

  @doc false
  def display(state, ctx) do
    tier = tier(ctx)

    case state.mode do
      :desktop -> desktop_display(state)
      :binding -> binding_display(state, ctx, tier)
    end
  end

  defp binding_display(state, ctx, tier) do
    now = current_keys(state, ctx) |> Enum.map_join(", ", &KeyName.format(&1, tier))
    now = if now == "", do: "unbound", else: now
    head = [[{"new keys for #{state.label} · now #{now}", :text_faint}]]

    pressed =
      if state.pressed,
        do: [[{"pressed    ", :text_muted}, {state.pressed, :text_primary}]],
        else: []

    {lines, footer, context} =
      case state.phase do
        :capture ->
          message = if state.message, do: [[{"! " <> state.message, :warning}]], else: []

          {message, [{"any key", "is the new key"}, {"Esc Esc", "cancel"}], :settings_capture}

        :taken ->
          p = state.proposal

          options =
            if p do
              [
                [{"  s ", :key}, {"swap: \"#{p.other}\" takes #{now}", :text_faint}],
                [{"  r ", :key}, {"replace: \"#{p.other}\" keeps #{keeps(p)}", :text_faint}]
              ]
            else
              []
            end

          {[[{"! " <> state.message, :warning}]] ++
             options ++
             [
               [{"  k ", :key}, {"press another key", :text_faint}],
               [{"  Esc ", :key}, {"keep #{now}", :text_faint}]
             ],
           [{"s", "swap"}, {"r", "replace"}, {"k", "press another key"}, {"Esc", "keep #{now}"}],
           :settings_popover}

        :refused ->
          {[
             [{"✗ " <> state.message, :error}],
             [{"  k ", :key}, {"press another key", :text_faint}],
             [{"  Esc ", :key}, {"keep #{now}", :text_faint}]
           ], [{"k", "press another key"}, {"Esc", "keep #{now}"}], :settings_popover}
      end

    %{
      value: [{"press the new keys…", :text_muted}],
      lines: head ++ pressed ++ lines,
      popover: nil,
      context: context,
      footer: footer
    }
  end

  defp keeps(%{other_keys: []}), do: "no key (unbound)"
  defp keeps(%{other_keys: keys}), do: Enum.join(keys, " and ")

  defp desktop_display(state) do
    case state.phase do
      :capture ->
        %{
          value: [{"press the new keys…", :text_muted}],
          lines: [
            [
              {"⌘ cannot reach a terminal: Ctrl stands in; t types meta+… after a key",
               :text_faint}
            ]
          ],
          popover: nil,
          context: :settings_capture,
          footer: [{"any key", "is the new key"}, {"Esc Esc", "cancel"}]
        }

      :typing ->
        lines =
          if state.message, do: [[{"✗ " <> state.message, :error}]], else: []

        %{
          value: [{state.typed, :code}],
          lines: [[{"a combo such as meta+shift+s · ctrl+alt+ArrowLeft", :text_faint}] | lines],
          popover: nil,
          context: :settings_edit,
          footer: [{"Enter", "save"}, {"Esc", "cancel"}]
        }

      _ ->
        %{
          value: [{state.pressed || "", :text_primary}],
          lines: [
            [{"✗ " <> (state.message || ""), :error}],
            [{"  t ", :key}, {"type a combo instead", :text_faint}],
            [{"  k ", :key}, {"press another key", :text_faint}]
          ],
          popover: nil,
          context: :settings_popover,
          footer: [{"t", "type a combo"}, {"k", "press another key"}, {"Esc", "cancel"}]
        }
    end
  end

  # ---------------------------------------------------------------- helpers

  defp current_keys(%{binding: sid}, ctx) do
    case Overrides.id(sid || "") do
      nil -> []
      id -> Overrides.effective_keys(Map.get(ctx || %{}, :overrides), id)
    end
  end

  defp source(ctx) do
    case ctx |> Kernel.||(%{}) |> Map.get(:prefs) |> Kernel.||(%{}) |> Map.get("keys") do
      keys when is_map(keys) -> keys
      _ -> %{}
    end
  end

  defp keys_map(ctx, sid, names), do: Map.put(source(ctx), sid, names)

  defp tier(ctx) do
    caps = Map.get(ctx || %{}, :caps)

    cond do
      is_map(caps) and Map.get(caps, :ascii?) == true -> :ascii
      is_map(caps) -> Map.get(caps, :glyph_tier, :measured)
      true -> :measured
    end
  end
end
