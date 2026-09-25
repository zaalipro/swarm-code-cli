defmodule SwarmCode.Settings.SecretPattern do
  @moduledoc """
  What counts as a secret in a name/value pair (pass 74, spec §3.2.5, D6).

  `desktop_secret_kv?/2` is the desktop's `MCP.Server.secrets/1` rule copied by
  value. `secret_kv?/2` is a strict superset of it: it also masks names that
  look like credentials to the shell scrub (`GH_PAT`, `DB_PASSWD`), values that
  start with a known token prefix (`sk_live_`, `ghp_`, `AKIA`) and URLs with a
  `user:password@` part. Masking only changes what the terminal shows, so the
  CLI may be stricter than the desktop.
  """

  @kv_key_source "(authorization|cookie|api[-_ ]?key|apikey|token|secret|password|credential)"
  @kv_value_source "^(sk-[A-Za-z0-9_\\-]{4,}|Bearer\\s+\\S{4,})$"
  @env_name_source "(API_?KEY|_KEY$|SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL|_PAT$)"
  @userinfo_source "://[^/@\\s:]+:[^/@\\s]+@"

  @token_prefixes ~w(sk_live_ sk_test_ rk_live_ sk-ant- sk-proj- ghp_ gho_ ghu_ ghs_ github_pat_
                     glpat- xoxa- xoxb- xoxp- xoxr- AKIA ASIA AIza hf_ tvly-)

  @doc "The desktop's name rule (caseless)."
  @spec kv_key_regex() :: Regex.t()
  def kv_key_regex, do: Regex.compile!(@kv_key_source, "i")

  @doc "The desktop's value rule (caseless)."
  @spec kv_value_regex() :: Regex.t()
  def kv_value_regex, do: Regex.compile!(@kv_value_source, "i")

  @doc "The shell scrub's credential-name rule (caseless)."
  @spec env_name_regex() :: Regex.t()
  def env_name_regex, do: Regex.compile!(@env_name_source, "i")

  @doc "A URL with a `user:password@` part."
  @spec userinfo_regex() :: Regex.t()
  def userinfo_regex, do: Regex.compile!(@userinfo_source)

  @doc "Value prefixes of well-known API tokens."
  @spec token_prefixes() :: [String.t()]
  def token_prefixes, do: @token_prefixes

  @doc "The desktop rule alone (`MCP.Server.secrets/1`): used by log-redaction parity only."
  @spec desktop_secret_kv?(term(), term()) :: boolean()
  def desktop_secret_kv?(name, value) do
    name = to_text(name)
    value = to_text(value)
    value != "" and (Regex.match?(kv_key_regex(), name) or Regex.match?(kv_value_regex(), value))
  end

  @doc "True when a name/value pair must be masked (the desktop rule or the broader CLI rules)."
  @spec secret_kv?(term(), term()) :: boolean()
  def secret_kv?(name, value) do
    name_text = to_text(name)
    value_text = to_text(value)

    desktop_secret_kv?(name_text, value_text) or Regex.match?(env_name_regex(), name_text) or
      token_prefix?(value_text) or Regex.match?(userinfo_regex(), value_text)
  end

  @doc "True when an environment variable name names a secret (`API_KEY`, `*_PAT`…)."
  @spec secret_name?(term()) :: boolean()
  def secret_name?(name) do
    name = to_text(name)
    Regex.match?(env_name_regex(), name) or Regex.match?(kv_key_regex(), name)
  end

  @doc "The last 4 characters of a secret of at least 12 characters, else nil."
  @spec hint(term()) :: String.t() | nil
  def hint(secret) when is_binary(secret) do
    if String.length(secret) >= 12, do: String.slice(secret, -4, 4), else: nil
  end

  def hint(_secret), do: nil

  defp token_prefix?(value) do
    trimmed = String.trim_leading(value)
    Enum.any?(@token_prefixes, &String.starts_with?(trimmed, &1))
  end

  defp to_text(value) when is_binary(value), do: value
  defp to_text(nil), do: ""
  defp to_text(value) when is_atom(value) or is_number(value), do: to_string(value)
  defp to_text(_value), do: ""
end
