defmodule SwarmCodeCLI.Plain.Options do
  @moduledoc "Pure, closed selection of the permanent plain surface."
  alias SwarmCodeCLI.Plain.Environment

  defstruct plain?: true,
            no_alt_screen?: false,
            ascii?: false,
            color?: true,
            reduced_motion?: false,
            ambiguous_width: :narrow

  @type t :: %__MODULE__{
          plain?: boolean(),
          no_alt_screen?: boolean(),
          ascii?: boolean(),
          color?: boolean(),
          reduced_motion?: boolean(),
          ambiguous_width: :narrow | :wide
        }

  def select(args, %Environment{} = env) when is_list(args) do
    valid =
      map_size(env) == 7 and is_binary(env.term) and byte_size(env.term) <= 256 and
        String.valid?(env.term) and
        Enum.all?(
          [env.stdin_tty?, env.stdout_tty?, env.controlling_tty?, env.color?, env.no_color?],
          &is_boolean/1
        )

    if valid do
      initial = %__MODULE__{
        plain?:
          not (env.stdin_tty? and env.stdout_tty? and env.controlling_tty?) or
            String.downcase(env.term) == "dumb",
        color?: env.color? and not env.no_color?
      }

      flags(args, initial, MapSet.new())
    else
      {:error, :invalid_option}
    end
  end

  def select(_, _), do: {:error, :invalid_option}
  defp flags([], options, _seen), do: {:ok, options}

  defp flags([arg | rest], options, seen) do
    decoded =
      case arg do
        "--plain" -> {:plain?, true}
        "--no-alt-screen" -> {:no_alt_screen?, true}
        "--ascii" -> {:ascii?, true}
        "--no-color" -> {:color?, false}
        "--reduced-motion" -> {:reduced_motion?, true}
        "--ambiguous-width=narrow" -> {:ambiguous_width, :narrow}
        "--ambiguous-width=wide" -> {:ambiguous_width, :wide}
        _ -> :error
      end

    case decoded do
      {key, value} ->
        if MapSet.member?(seen, key),
          do: {:error, :invalid_option},
          else: flags(rest, Map.put(options, key, value), MapSet.put(seen, key))

      :error ->
        {:error, :invalid_option}
    end
  end

  defp flags(_, _, _), do: {:error, :invalid_option}
end
