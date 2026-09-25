defmodule SwarmCode.Daemon.Service.Settings.C74SecretsTest do
  @moduledoc "pass 74 S2-1: the secrets helper (§3.5.9, D6)."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SwarmCode.Daemon.Service.Settings.{Kit, Secrets}
  alias SwarmCode.Domain.MCP.Server
  alias SwarmCode.Domain.Providers.Provider
  alias SwarmCode.Domain.Search.SearchProvider
  alias SwarmCode.Test.C74S2

  describe "mask/1 and hint/1" do
    test "a set secret of 12 characters or more shows its last 4" do
      assert Secrets.mask("sk-test-deepseek-00000000a1b2") == %{"set" => true, "hint" => "a1b2"}
      assert Secrets.mask(C74S2.canary()) == %{"set" => true, "hint" => "SHOW"}
    end

    test "under 12 characters there is no hint, blank is not set" do
      assert Secrets.mask("abcdefghijk") == %{"set" => true, "hint" => nil}
      assert Secrets.mask("abcdefghijkl") == %{"set" => true, "hint" => "ijkl"}
      assert Secrets.mask("") == %{"set" => false, "hint" => nil}
      assert Secrets.mask("   ") == %{"set" => false, "hint" => nil}
      assert Secrets.mask(nil) == %{"set" => false, "hint" => nil}
    end

    test "a hint is never a space or a control character" do
      assert Secrets.hint("abcdefghi jk") == nil
      assert Secrets.hint("abcdefghij\u0001k") == nil
    end

    property "a hint is nil or exactly the last 4 printable characters" do
      check all(secret <- string(:printable, min_length: 0, max_length: 40)) do
        case Secrets.hint(secret) do
          nil ->
            assert String.length(secret) < 12 or String.slice(secret, -4, 4) =~ ~r/\s/u or
                     not String.printable?(String.slice(secret, -4, 4))

          hint ->
            assert String.length(secret) >= 12
            assert hint == String.slice(secret, -4, 4)
            assert String.length(hint) == 4
        end
      end
    end
  end

  describe "check_paste/1" do
    test "the words of each refusal" do
      assert Secrets.check_paste("sk-abc\nsecond") ==
               {:error, "paste only the key: it had 2 lines"}

      assert Secrets.check_paste("a\r\nb\nc") == {:error, "paste only the key: it had 3 lines"}
      assert Secrets.check_paste("sk-abc def-ghi") == {:error, "a key has no spaces inside"}
      assert Secrets.check_paste("sk-abcd") == {:error, "that is too short to be a key"}
      assert Secrets.check_paste("   ") == {:error, "that is too short to be a key"}

      assert Secrets.check_paste(String.duplicate("a", 8_193)) ==
               {:error, "that is too long to be a key"}

      assert Secrets.check_paste(nil) == {:error, "that is too short to be a key"}
    end

    test "the 8-byte floor and the trim" do
      assert Secrets.check_paste("12345678") == :ok
      assert Secrets.check_paste("  #{C74S2.canary()}\n") == :ok
      assert Secrets.normalise("  #{C74S2.canary()}\n") == C74S2.canary()
      assert Secrets.check_paste(String.duplicate("a", 8_192)) == :ok
    end

    property "a single printable word of 8..8192 bytes is accepted" do
      check all(key <- string(?!..?~, min_length: 8, max_length: 200)) do
        assert Secrets.check_paste(key) == :ok
      end
    end
  end

  describe "take/2 and slots/1" do
    test "reads a slot from either key form, never anything else" do
      command =
        C74S2.command("provider.set_key",
          secrets: [%{slot: "api_key", value: "v1"}, %{"slot" => "env:TOKEN", "value" => "v2"}]
        )

      assert Secrets.take(command, "api_key") == {:ok, "v1"}
      assert Secrets.take(command, "env:TOKEN") == {:ok, "v2"}
      assert Secrets.take(command, "missing") == :error
      assert Secrets.slots(command) == ["api_key", "env:TOKEN"]
    end
  end

  describe "masked_entries/1" do
    test "masks by the broader rule and keeps plain values" do
      entries =
        Secrets.masked_entries(%{
          "GITHUB_PERSONAL_ACCESS_TOKEN" => "ghp_test_0000000000000000i9j0",
          "GITHUB_TOOLSETS" => "repos,issues",
          "GH_PAT" => "abcdefghijklmnop",
          "STRIPE_KEY" => "sk_live_0000000000000000",
          "DATABASE_URL" => "postgres://u:pw@h/db",
          "DB_PASSWD" => "hunter22hunter22",
          "SLACK" => "xoxb-000000000000",
          "AWS" => "AKIA0000000000000000",
          "OPENAI_KEY" => "not-a-sk-value-0000"
        })

      shown = for %{"secret" => false, "name" => n, "value" => v} <- entries, do: {n, v}
      assert shown == [{"GITHUB_TOOLSETS", "repos,issues"}]

      for %{"secret" => true} = entry <- entries do
        assert entry["value"] == nil
      end

      assert Enum.map(entries, & &1["name"]) == Enum.sort(Enum.map(entries, & &1["name"]))
    end

    test "every value the desktop's Server.secrets/1 masks is masked here (superset)" do
      samples = [
        {"Authorization", "Bearer abcdefgh"},
        {"Cookie", "session=1"},
        {"X-API-Key", "value"},
        {"apikey", "v"},
        {"MY_TOKEN", "t"},
        {"client_secret", "s"},
        {"PASSWORD", "p"},
        {"CREDENTIALS", "c"},
        {"PLAIN", "sk-abcd1234"},
        {"H", "Bearer tokentoken"},
        {"content-type", "application/json"},
        {"LOG_LEVEL", "debug"}
      ]

      server = %Server{env: Map.new(samples), headers: %{}}
      desktop = MapSet.new(Server.secrets(server))

      masked =
        for %{"secret" => true, "name" => n} <- Secrets.masked_entries(Map.new(samples)), do: n

      masked_values = for {n, v} <- samples, n in masked, into: MapSet.new(), do: v

      assert MapSet.subset?(desktop, masked_values)
      refute "LOG_LEVEL" in masked
      refute "content-type" in masked
    end
  end

  describe "redaction_list/1" do
    test "names the stored secrets of each record kind that has one" do
      assert Secrets.redaction_list(%Provider{api_key: "sk-test-deepseek-00000000a1b2"}) == [
               "sk-test-deepseek-00000000a1b2"
             ]

      assert Secrets.redaction_list(%Provider{api_key: ""}) == []

      assert Secrets.redaction_list(%SearchProvider{api_key: "tvly-test-0000"}) == [
               "tvly-test-0000"
             ]

      server = %Server{
        env: %{"GH_PAT" => "abcdefghijkl", "MODE" => "fast"},
        headers: %{"Authorization" => "Bearer test-token-0000000000k1l2"}
      }

      list = Secrets.redaction_list(server)
      assert "abcdefghijkl" in list
      assert "Bearer test-token-0000000000k1l2" in list
      refute "fast" in list
    end

    test "Kit.redact removes long and short secrets and cuts to 2 048 bytes" do
      text = "failed with sk-canary-7Q2X-DO-NOT-SHOW and pw1 " <> String.duplicate("é", 2_000)
      out = Kit.redact(text, [C74S2.canary(), "pw1", nil, ""])
      refute out =~ C74S2.canary()
      refute out =~ "pw1"
      assert byte_size(out) <= 2_048
      assert String.valid?(out)
    end
  end
end
