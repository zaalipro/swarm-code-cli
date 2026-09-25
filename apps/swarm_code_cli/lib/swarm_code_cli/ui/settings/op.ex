defmodule SwarmCodeCLI.UI.Settings.Op do
  @moduledoc """
  What a section or an editor asks the settings layer to do (spec §3.7.2).
  Sections are pure: they return ops, and `Reducer.Settings` turns ops into
  state changes and effects.

    * `{:patch, key, wire_value}` — write one registry value (CAS, undoable).
    * `{:reset, [key]}` / `{:reset_section, id}` — back to the defaults.
    * `{:command, action, target, attributes, opts}` — a `settings.command`;
      `opts` is `%{expected, write_key, secrets_from, undo, toast}` (any subset).
    * `{:task, action, target, attributes}` / `{:cancel_task, task_id}`.
    * `{:load, load}` — `{:values, sections} | {:records, kind, options} |
      {:record, kind, id} | {:file, ref} | :overview | :facts | :usage |
      {:auto_task, action, target}`.
    * `{:open, page}` / `:back` / `{:section, id}` — navigation.
    * `{:confirm, %Confirm{}, then: [op]}` / `{:picker, %Picker{}}` — popovers.
    * `{:paste, paste_target}` / `{:edit, row_id}` — open the paste target or
      the row's editor.
    * `{:external_edit, %{ref, content, fingerprint, suffix}}` — a private
      copy edited in the user's editor (owned by the session runtime).
    * `{:cli_write, %{json_name => value | :remove}}` — a cli.json change set.
    * `{:open_folder, path}` / `{:copy, text}` — OS-facing work the runtime owns.
    * `{:toast, text, role}` / `{:leave, then}`.
  """

  alias SwarmCodeCLI.UI.Settings.{Confirm, Page, Picker}

  @type load ::
          {:values, [atom()]}
          | {:records, String.t(), map()}
          | {:record, String.t(), String.t()}
          | {:file, String.t()}
          | :overview
          | :facts
          | :usage
          | {:auto_task, String.t(), map() | nil}

  @type t ::
          {:patch, String.t(), term()}
          | {:reset, [String.t()]}
          | {:reset_section, atom()}
          | {:command, String.t(), map() | nil, map(), map()}
          | {:task, String.t(), map() | nil, map()}
          | {:cancel_task, String.t()}
          | {:load, load()}
          | {:open, Page.t()}
          | :back
          | {:section, atom()}
          | {:confirm, Confirm.t(), [{:then, [t()]}]}
          | {:picker, Picker.t()}
          | {:paste, map()}
          | {:edit, String.t()}
          | {:external_edit, map()}
          | {:cli_write, %{String.t() => term()}}
          | {:open_folder, String.t()}
          | {:copy, String.t()}
          | {:toast, String.t(), atom()}
          | {:leave, term()}

  @doc "A `settings.command` op with its options."
  @spec command(String.t(), map() | nil, map(), map()) :: t()
  def command(action, target, attributes, opts \\ %{}),
    do: {:command, action, target, attributes, opts}

  @doc "Whether `op` is one of the shapes above (the reducer drops anything else)."
  @spec valid?(term()) :: boolean()
  def valid?({:patch, key, _value}), do: is_binary(key)
  def valid?({:reset, keys}), do: is_list(keys) and Enum.all?(keys, &is_binary/1)
  def valid?({:reset_section, id}), do: is_atom(id)

  def valid?({:command, action, target, attributes, opts}),
    do:
      is_binary(action) and (is_nil(target) or is_map(target)) and is_map(attributes) and
        is_map(opts)

  def valid?({:task, action, target, attributes}),
    do: is_binary(action) and (is_nil(target) or is_map(target)) and is_map(attributes)

  def valid?({:cancel_task, id}), do: is_binary(id)
  def valid?({:load, _load}), do: true
  def valid?({:open, %Page{}}), do: true
  def valid?(:back), do: true
  def valid?({:section, id}), do: is_atom(id)
  def valid?({:confirm, %Confirm{}, then: ops}), do: is_list(ops)
  def valid?({:picker, %Picker{}}), do: true
  def valid?({:paste, target}), do: is_map(target)
  def valid?({:edit, row_id}), do: is_binary(row_id)
  def valid?({:external_edit, spec}), do: is_map(spec)
  def valid?({:cli_write, changes}), do: is_map(changes) and map_size(changes) > 0
  def valid?({:open_folder, path}), do: is_binary(path)
  def valid?({:copy, text}), do: is_binary(text)
  def valid?({:toast, text, role}), do: is_binary(text) and is_atom(role)
  def valid?({:leave, _then}), do: true
  def valid?(_op), do: false
end
