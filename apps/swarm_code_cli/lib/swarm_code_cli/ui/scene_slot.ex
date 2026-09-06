defmodule SwarmCodeCLI.UI.SceneSlot do
  @moduledoc "A protected runtime-owned slot containing one validated, bounded Scene."
  alias SwarmCodeCLI.UI.Scene
  @max_bytes 4_194_304
  def new, do: :ets.new(__MODULE__, [:set, :protected, read_concurrency: true])

  def put(tid, %Scene{} = scene) do
    with :ok <- Scene.validate(scene), true <- :erlang.external_size(scene) <= @max_bytes do
      :ets.insert(tid, {:latest, scene.revision, scene})
      :ok
    else
      _ -> {:error, :invalid_scene}
    end
  end

  def put(_, _), do: {:error, :invalid_scene}

  def fetch(tid, revision) do
    case :ets.lookup(tid, :latest) do
      [{:latest, ^revision, scene}] -> {:ok, scene}
      _ -> {:error, :stale_revision}
    end
  rescue
    ArgumentError -> {:error, :closed}
  end

  def destroy(tid) do
    :ets.delete(tid)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
