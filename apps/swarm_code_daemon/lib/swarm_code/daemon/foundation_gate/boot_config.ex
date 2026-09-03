defmodule SwarmCode.Daemon.FoundationGate.BootConfig do
  @moduledoc false

  @enforce_keys [:platform, :mode, :home, :env, :database_path, :app_version]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          platform: :macos | :linux,
          mode: :production,
          home: Path.t(),
          env: %{optional(String.t()) => String.t()},
          database_path: nil,
          app_version: String.t()
        }

  @spec canonical(:macos | :linux, Path.t(), String.t()) :: t()
  def canonical(platform, home, app_version)
      when platform in [:macos, :linux] and is_binary(home) and is_binary(app_version) do
    %__MODULE__{
      platform: platform,
      mode: :production,
      home: Path.expand(home),
      env: %{},
      database_path: nil,
      app_version: app_version
    }
  end
end
