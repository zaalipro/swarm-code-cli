# pass 74 S2 scaffolding: S1's `c74-S1-core` frame types (spec §3.2.5,
# §3.3.1) did not exist when S2 started. These stand-ins carry exactly the
# fields the spec gives them so S2's handlers and tests run on S2's branch
# alone. The file is deleted in the commit that merges `c74-S1-core`.
defmodule SwarmCode.Daemon.Service.Settings.Context do
  @moduledoc false
  @derive {Inspect, except: [:env, :task_results]}
  defstruct project: nil,
            conversation: nil,
            live?: false,
            override: nil,
            env: %{},
            task_results: %{},
            seen: %{},
            settings_revision: 0,
            now: nil,
            request_id: "test",
            origin: :tui
end

defmodule SwarmCode.Daemon.Service.Settings.Command do
  @moduledoc false
  defstruct action: nil,
            target: %{},
            attributes: %{},
            expected: nil,
            secrets: [],
            dry_run: false,
            request_id: "test"

  defimpl Inspect do
    def inspect(command, _opts) do
      "#Command<#{command.action} secrets: [#{length(command.secrets || [])} redacted]>"
    end
  end
end

defmodule SwarmCode.Daemon.Service.Settings.Result do
  @moduledoc false
  defstruct status: :accepted, results: [], record: nil, message: nil, task: nil, confirm: nil
end

defmodule SwarmCode.Daemon.Service.Settings.Error do
  @moduledoc false
  defstruct code: :invalid, message: "", field_errors: []
end

defmodule SwarmCode.Daemon.Service.Settings.TaskSpec do
  @moduledoc false
  @derive {Inspect, except: [:redact, :run, :summary]}
  defstruct action: nil,
            key: nil,
            timeout_ms: 15_000,
            cancellable?: true,
            kind: :plain,
            run: nil,
            summary: nil,
            redact: []
end

defmodule SwarmCode.Settings.SecretPattern do
  @moduledoc false
  @kv_key ~r/(authorization|cookie|api[-_ ]?key|apikey|token|secret|password|credential)/i
  @kv_value ~r/^(sk-[A-Za-z0-9_\-]{4,}|Bearer\s+\S{4,})$/i
  @env_name ~r/(API_?KEY|_KEY$|SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL|_PAT$)/i
  @userinfo ~r/:\/\/[^\/@\s:]+:[^\/@\s]+@/
  @prefixes ~w(sk_live_ sk_test_ rk_live_ sk-ant- sk-proj- ghp_ gho_ ghu_ ghs_ github_pat_ glpat-
               xoxa- xoxb- xoxp- xoxr- AKIA ASIA AIza hf_ tvly-)

  def kv_key_regex, do: @kv_key
  def kv_value_regex, do: @kv_value
  def env_name_regex, do: @env_name
  def userinfo_regex, do: @userinfo
  def token_prefixes, do: @prefixes

  def desktop_secret_kv?(name, value) do
    name = to_string(name)
    value = to_string(value)
    value != "" and (Regex.match?(@kv_key, name) or Regex.match?(@kv_value, value))
  end

  def secret_kv?(name, value) do
    name = to_string(name)
    value = to_string(value)

    value != "" and
      (desktop_secret_kv?(name, value) or Regex.match?(@env_name, name) or
         String.starts_with?(value, @prefixes) or Regex.match?(@userinfo, value))
  end

  def hint(secret) when is_binary(secret) do
    if String.length(secret) >= 12, do: String.slice(secret, -4, 4)
  end

  def hint(_secret), do: nil
end
