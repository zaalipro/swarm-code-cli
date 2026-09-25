defmodule SwarmCode.Settings.C74TypesTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Settings.{Entry, SecretPattern, TextValue, Validate, WireBounds, WireValue}
  alias SwarmCode.Settings.RecordKind
  alias SwarmCode.Settings.RecordKind.Field

  defp entry(type, opts \\ []) do
    struct(
      %Entry{
        key: "t.x",
        id: :t_x,
        section: :overview,
        label: "X",
        scope: :global,
        storage: nil,
        type: type
      },
      opts
    )
  end

  @uuid "0f3c0000-0000-4000-8000-000000000001"

  describe "WireValue round trips" do
    test "every type accepts its own values and refuses the wrong shape" do
      cases = [
        {entry(:toggle), true, "yes"},
        {entry(:enum, choices: [%{value: "a", label: "A", hint: nil}]), "a", "b"},
        {entry(:enum, choices: [%{value: 1, label: "1", hint: nil}]), 1, 4},
        {entry(:checklist,
           choices: [%{value: "a", label: "A", hint: nil}, %{value: "b", label: "B", hint: nil}]
         ), ["a"], ["c"]},
        {entry(:integer, min: 1, max: 16), 6, 17},
        {entry(:duration, min: 60, max: 3600, unit: :s), 600, 30},
        {entry(:money, min: 0, nullable: true), 50, 12.5},
        {entry(:text), "hello", 12},
        {entry(:list), ["a", "b"], "a"},
        {entry(:model), %{"provider_id" => @uuid, "model" => "m"},
         %{"provider_id" => "x", "model" => "m"}},
        {entry(:effort), "high", ""},
        {entry(:path, nullable: true), "/bin/sh", 1},
        {entry(:color, nullable: true), "#FF6A1A", "#ff6a1g"},
        {entry(:lsp_command, nullable: true), "off", ""},
        {entry(:combo, nullable: true), "meta+p", 3},
        {entry(:keys), %{"palette_open" => ["F5"]}, %{"x" => ["a", "b", "c", "d", "e"]}},
        {entry(:map_readonly), %{"tasks" => true}, []},
        {entry(:datetime), "2026-09-25T18:40:00Z", "yesterday"}
      ]

      for {entry, good, bad} <- cases do
        assert {:ok, ^good} = WireValue.from_json(entry, good), "#{entry.type} good"
        assert WireValue.to_json(entry, good) == good
        assert :error = WireValue.from_json(entry, bad), "#{entry.type} bad #{inspect(bad)}"
      end
    end

    test "an integral float reads as an integer; a fraction stays invalid" do
      money = entry(:money, min: 0, nullable: true)
      assert {:ok, 50} = WireValue.from_json(money, 50.0)
      assert :error = WireValue.from_json(money, 12.5)
      assert WireValue.equal?(50, 50.0)
      assert WireValue.equal?(%{a: 1}, %{"a" => 1.0})
      refute WireValue.equal?([1, 2], [2, 1])
    end

    test "null only where the entry allows it" do
      assert WireValue.type_ok?(entry(:integer, min: 1, max: 3, nullable: true), nil)
      refute WireValue.type_ok?(entry(:integer, min: 1, max: 3), nil)
      assert WireValue.type_ok?(entry(:model), nil)
      assert WireValue.type_ok?(entry(:integer, special: %{0 => "no limit"}, min: 60, max: 90), 0)
    end
  end

  describe "Validate messages" do
    test "each validator answers its exact message" do
      table = [
        {entry(:integer, validate: [{:range, 1, 16}]), 17, "must be between 1 and 16"},
        {entry(:duration,
           validate: [{:special_or_range, [0], 60, 86_400}],
           messages: %{range: "must be 0 (no limit) or between 60 and 86400"}
         ), 30, "must be 0 (no limit) or between 60 and 86400"},
        {entry(:integer, validate: [{:min, 320}]), 300, "must be greater than or equal to 320"},
        {entry(:integer, validate: [{:max, 1200}]), 1300, "must be less than or equal to 1200"},
        {entry(:enum, choices: [%{value: "a", label: "A", hint: nil}], validate: [:inclusion]),
         "z", "is invalid"},
        {entry(:effort, validate: [{:format, "^[a-z0-9][a-z0-9_-]{0,23}$"}]), "Hi There",
         "has invalid format"},
        {entry(:text, validate: [{:max_length, 3}]), "abcd", "should be at most 3 character(s)"},
        {entry(:text, validate: [:required]), "  ", "can't be blank"},
        {entry(:text, validate: [:one_line]), "a\nb", "one line only"},
        {entry(:list, validate: [{:list_max, 2}]), ["a", "b", "c"], "too many items (2 max)"},
        {entry(:list, validate: [:unique_items]), ["a", "a"], "already in the list"},
        {entry(:list, validate: [{:item, :env_name}]), ["1BAD"],
         "use a variable name: A–Z, 0–9 and _"},
        {entry(:list, validate: [{:item, :command_family}]), [" "], "can't be blank"},
        {entry(:list, validate: [{:item, :command_family}]), ["a\nb"], "one line only"},
        {entry(:color, validate: [:hex_color]), "#12345", "a colour such as #FF6A1A"},
        {entry(:text, validate: [:hint_letters]), "ABCDEFGH", "only lowercase letters a–z"},
        {entry(:text, validate: [:hint_letters]), "sfghjkls", "each letter once"},
        {entry(:text, validate: [:hint_letters]), "sfgh", "use at least 8 letters"},
        {entry(:text, validate: [:hint_letters]), "sfghjkly",
         "y a d n q answer approvals or close; they cannot be hint letters"},
        {entry(:money, nullable: true, validate: [:whole_dollars]), 12.5,
         "must be a whole number of dollars, zero or more"},
        {entry(:money, nullable: true, validate: [:whole_dollars]), -1,
         "must be a whole number of dollars, zero or more"}
      ]

      for {entry, value, message} <- table do
        assert Validate.check(entry, value) == {:error, message}, inspect({entry.validate, value})
      end
    end

    test "service checks pass on the client and are listed for the service" do
      entry = entry(:path, nullable: true, validate: [{:svc, :executable_path}])
      assert Validate.check(entry, "/nope") == :ok
      assert Validate.svc_checks(entry) == [:executable_path]
    end

    test "normalise applies the desktop normalisations" do
      domains = entry(:list, item: :domain)

      assert Validate.normalise(domains, ["https://a.com/ b.org,c.net", " "]) ==
               ["a.com", "b.org", "c.net"]

      assert Validate.normalise(entry(:list, item: :env_name), ["A, B", "C"]) == ["A", "B", "C"]
      assert Validate.normalise(entry(:color, nullable: true), "#abc") == "#AABBCC"
      assert Validate.normalise(entry(:color, nullable: true), "ff6a1a") == "#FF6A1A"
      assert Validate.normalise(entry(:path, nullable: true), "  ") == nil
      assert Validate.normalise_url(" https://x.test/v1/ ") == "https://x.test/v1"
    end
  end

  describe "TextValue" do
    defp seconds,
      do: entry(:duration, unit: :s, min: 60, max: 86_400, special: %{0 => "no limit"})

    defp ms, do: entry(:duration, unit: :ms, min: 1_000, max: 600_000)

    defp days,
      do: entry(:integer, unit: :days, min: 7, max: 3650, nullable: true, null_label: "off")

    defp enum,
      do:
        entry(:enum,
          choices: [
            %{value: "build", label: "Build", hint: nil},
            %{value: "workflow", label: "Writing a workflow", hint: nil}
          ],
          default: "build"
        )

    defp rounds,
      do:
        entry(:enum,
          choices: [%{value: 1, label: "1", hint: nil}, %{value: 2, label: "2", hint: nil}]
        )

    defp check,
      do:
        entry(:checklist,
          choices: [
            %{value: "gate", label: "Gate", hint: nil},
            %{value: "risk", label: "Risk", hint: nil}
          ],
          nullable: true
        )

    test "a table of 40 inputs" do
      table = [
        {entry(:toggle), "on", {:ok, true}},
        {entry(:toggle), "OFF", {:ok, false}},
        {entry(:toggle), "true", {:ok, true}},
        {entry(:toggle), "no", {:ok, false}},
        {entry(:toggle), "maybe", {:error, "use on or off"}},
        {seconds(), "30m", {:ok, 1800}},
        {seconds(), "90s", {:ok, 90}},
        {seconds(), "2h", {:ok, 7200}},
        {seconds(), "600", {:ok, 600}},
        {seconds(), "no limit", {:ok, 0}},
        {seconds(), "1.5m", {:ok, 90}},
        {seconds(), "500ms", {:error, "use a whole number of seconds"}},
        {seconds(), "soon", {:error, "use a number with a unit, such as 90s, 30m or 2h"}},
        {ms(), "2m", {:ok, 120_000}},
        {ms(), "1.5s", {:ok, 1500}},
        {ms(), "90000", {:ok, 90_000}},
        {days(), "30", {:ok, 30}},
        {days(), "30d", {:ok, 30}},
        {days(), "off", {:ok, nil}},
        {days(), "null", {:ok, nil}},
        {enum(), "Build", {:ok, "build"}},
        {enum(), "writing a workflow", {:ok, "workflow"}},
        {enum(), "default", {:ok, "build"}},
        {enum(), "chaos", {:error, "is invalid; choose one of: build, workflow"}},
        {rounds(), "2", {:ok, 2}},
        {check(), "gate, risk", {:ok, ["gate", "risk"]}},
        {check(), "default", {:ok, nil}},
        {entry(:list), "a, b ,c", {:ok, ["a", "b", "c"]}},
        {entry(:list), "[]", {:ok, []}},
        {entry(:money, nullable: true), "$50", {:ok, 50}},
        {entry(:money, nullable: true), "none", {:ok, nil}},
        {entry(:model), "DeepSeek/deepseek-v4-pro",
         {:ok, {:model_ref, "DeepSeek", "deepseek-v4-pro"}}},
        {entry(:model), "#{@uuid}|m-1", {:ok, %{"provider_id" => @uuid, "model" => "m-1"}}},
        {entry(:model), "nomodel", {:error, "use provider/model"}},
        {entry(:color, nullable: true), "#abc", {:ok, "#AABBCC"}},
        {entry(:color, nullable: true), "purple", {:error, "a colour such as #FF6A1A"}},
        {entry(:keys), ~s({"palette_open": ["F5"]}), {:ok, %{"palette_open" => ["F5"]}}},
        {entry(:keys), "[1]", {:error, "must be a JSON object"}},
        {entry(:lsp_command, nullable: true), "off", {:ok, "off"}},
        {entry(:path, nullable: true), "  ", {:ok, nil}},
        {entry(:effort), "XHigh", {:ok, "xhigh"}},
        {entry(:fact), "x", {:error, "read-only"}}
      ]

      assert length(table) >= 40

      for {entry, text, expected} <- table do
        assert TextValue.parse(entry, text) == expected, "#{entry.type} #{inspect(text)}"
      end
    end

    test "record fields parse by field type; secrets never parse" do
      assert TextValue.parse(%Field{name: "fallbacks", type: :bool}, "on") == {:ok, true}

      assert TextValue.parse(%Field{name: "base_url", type: :url}, " https://x/v1/ ") ==
               {:ok, "https://x/v1"}

      assert TextValue.parse(%Field{name: "input", type: :number}, "0.27") == {:ok, 0.27}
      assert TextValue.parse(%Field{name: "models", type: :list}, "a,b") == {:ok, ["a", "b"]}

      assert {:error, _} =
               TextValue.parse(%Field{name: "api_key", type: :secret, secret: true}, "sk-x")
    end

    test "format reads back through parse" do
      for {entry, value} <- [
            {seconds(), 1800},
            {seconds(), 0},
            {ms(), 120_000},
            {days(), nil},
            {enum(), "workflow"},
            {entry(:toggle), false},
            {entry(:list), ["a", "b"]}
          ] do
        assert TextValue.parse(entry, TextValue.format(entry, value)) == {:ok, value}
      end

      assert TextValue.format(entry(:model), %{"provider_id" => @uuid, "model" => "m"},
               providers: %{@uuid => "DeepSeek"}
             ) == "DeepSeek/m"
    end
  end

  describe "SecretPattern" do
    @table [
      # {name, value, desktop rule, CLI rule}
      {"Authorization", "Bearer abcdef", true, true},
      {"authorization", "x", true, true},
      {"Cookie", "a=b", true, true},
      {"API_KEY", "x", true, true},
      {"api-key", "x", true, true},
      {"apikey", "x", true, true},
      {"X-Api-Key", "x", true, true},
      {"GITHUB_TOKEN", "abc", true, true},
      {"CLIENT_SECRET", "abc", true, true},
      {"DB_PASSWORD", "abc", true, true},
      {"CREDENTIALS_FILE", "/x", true, true},
      {"SOMETHING", "sk-abcd1234", true, true},
      {"HEADER", "Bearer tok123", true, true},
      {"GITHUB_PERSONAL_ACCESS_TOKEN", "ghp_x", true, true},
      {"GH_PAT", "abc", false, true},
      {"STRIPE_KEY", "sk_live_abc", false, true},
      {"OPENAI_KEY", "abc", false, true},
      {"DB_PASSWD", "abc", false, true},
      {"DATABASE_URL", "postgres://u:pw@h/db", false, true},
      {"SLACK", "xoxb-123-456", false, true},
      {"AWS", "AKIAABCDEFGH", false, true},
      {"GOOGLE", "AIzaSyXYZ", false, true},
      {"HF", "hf_abcdef", false, true},
      {"TAVILY", "tvly-abc", false, true},
      {"GITLAB", "glpat-xyz", false, true},
      {"ANTHROPIC", "sk-ant-api03", true, true},
      {"PROJECT", "sk-proj-abcd", true, true},
      {"GH", "github_pat_123", false, true},
      {"GH2", "gho_123", false, true},
      {"STRIPE_TEST", "sk_test_123", false, true},
      {"RK", "rk_live_123", false, true},
      {"AWS_SESSION", "ASIA123", false, true},
      {"GITHUB_TOOLSETS", "repos,issues", false, false},
      {"Content-Type", "application/json", false, false},
      {"LOG_LEVEL", "debug", false, false},
      {"URL", "https://example.com/x", false, false},
      {"PATH", "/usr/bin", false, false},
      {"MONKEY", "banana", false, false},
      {"TOKEN_EMPTY", "", false, true},
      {"PLAIN", "sk-ab", false, false}
    ]

    test "a 40-row table: the CLI rule is a superset of the desktop rule" do
      assert length(@table) == 40

      for {name, value, desktop, cli} <- @table do
        assert SecretPattern.desktop_secret_kv?(name, value) == desktop, "desktop #{name}"
        assert SecretPattern.secret_kv?(name, value) == cli, "cli #{name}"
        if desktop, do: assert(SecretPattern.secret_kv?(name, value), "superset #{name}")
      end
    end

    test "hints are the last four characters of a long secret only" do
      assert SecretPattern.hint("sk-test-deepseek-00000000a1b2") == "a1b2"
      assert SecretPattern.hint("short-key") == nil
      assert SecretPattern.hint(nil) == nil
    end
  end

  describe "WireBounds" do
    defp query(overrides) do
      Map.merge(
        %{
          "view" => "values",
          "sections" => nil,
          "keys" => nil,
          "kind" => nil,
          "id" => nil,
          "project_id" => nil,
          "cursor" => nil,
          "page_size" => 200,
          "byte_limit" => 900_000,
          "options" => nil
        },
        overrides
      )
    end

    defp command(overrides) do
      Map.merge(
        %{
          "action" => "values.patch",
          "target" => nil,
          "attributes" => %{},
          "expected" => nil,
          "secrets" => [],
          "dry_run" => false
        },
        overrides
      )
    end

    test "query bounds just inside and just outside" do
      inside = [
        %{"view" => "file"},
        %{"sections" => Enum.map(1..22, fn _ -> "providers" end)},
        %{"keys" => List.duplicate(String.duplicate("k", 64), 400)},
        %{"kind" => "providers"},
        %{"id" => String.duplicate("i", 512)},
        %{"project_id" => @uuid},
        %{"cursor" => String.duplicate("c", 256)},
        %{"page_size" => 1},
        %{"byte_limit" => 4_096},
        %{"byte_limit" => 1_048_576},
        %{"options" => %{"slot" => String.duplicate("s", 32)}},
        %{"options" => Map.new(1..32, &{"k#{&1}", "v"})}
      ]

      outside = [
        {%{"view" => "everything"}, "view"},
        {%{"sections" => List.duplicate("providers", 33)}, "sections"},
        {%{"sections" => ["nope"]}, "sections"},
        {%{"keys" => List.duplicate("k", 401)}, "keys"},
        {%{"keys" => [String.duplicate("k", 65)]}, "keys"},
        {%{"kind" => "users"}, "kind"},
        {%{"id" => String.duplicate("i", 513)}, "id"},
        {%{"id" => "a\nb"}, "id"},
        {%{"project_id" => "nope"}, "project_id"},
        {%{"cursor" => String.duplicate("c", 257)}, "cursor"},
        {%{"page_size" => 201}, "page_size"},
        {%{"page_size" => 0}, "page_size"},
        {%{"byte_limit" => 4_095}, "byte_limit"},
        {%{"byte_limit" => 1_048_577}, "byte_limit"},
        {%{"options" => %{"slot" => String.duplicate("s", 33)}}, "options"},
        {%{"options" => Map.new(1..33, &{"k#{&1}", "v"})}, "options"},
        {%{"options" => %{"a" => %{"b" => %{"c" => %{"d" => 1}}}}}, "options"}
      ]

      for params <- inside,
          do: assert(WireBounds.valid?(:settings_query, query(params)) == :ok, inspect(params))

      for {params, param} <- outside,
          do:
            assert(
              WireBounds.valid?("settings.query", query(params)) == {:error, param},
              inspect(params)
            )
    end

    test "command bounds just inside and just outside" do
      big = String.duplicate("x", 262_144)

      inside = [
        %{"action" => "project_config.remove_entry"},
        %{"target" => Map.new(1..16, &{"k#{&1}", "v"})},
        %{"attributes" => %{"content" => big}},
        %{"attributes" => %{"list" => List.duplicate("a", 2_048)}},
        %{"attributes" => Map.new(1..256, &{"k#{&1}", 1})},
        %{"expected" => %{"a" => 1}},
        %{"secrets" => Enum.map(1..16, &%{"slot" => "s#{&1}", "value" => "v"})},
        %{
          "secrets" => [
            %{"slot" => String.duplicate("s", 128), "value" => String.duplicate("v", 8_192)}
          ]
        },
        %{"dry_run" => true}
      ]

      outside = [
        {%{"action" => "provider.show_key"}, "action"},
        {%{"target" => Map.new(1..17, &{"k#{&1}", "v"})}, "target"},
        {%{"target" => %{"a" => String.duplicate("x", 1_025)}}, "target"},
        {%{"attributes" => nil}, "attributes"},
        {%{"attributes" => %{"content" => big <> "x"}}, "attributes"},
        {%{"attributes" => %{"list" => List.duplicate("a", 2_049)}}, "attributes"},
        {%{"attributes" => Map.new(1..257, &{"k#{&1}", 1})}, "attributes"},
        {%{"attributes" => %{"a" => big, "b" => big, "c" => big, "d" => big}}, "attributes"},
        {%{"expected" => "x"}, "expected"},
        {%{"secrets" => Enum.map(1..17, &%{"slot" => "s#{&1}", "value" => "v"})}, "secrets"},
        {%{"secrets" => [%{"slot" => "s", "value" => String.duplicate("v", 8_193)}]}, "secrets"},
        {%{"secrets" => [%{"slot" => "s", "value" => "a" <> <<0>>}]}, "secrets"},
        {%{"secrets" => [%{"slot" => "s", "value" => ""}]}, "secrets"},
        {%{"secrets" => [%{"slot" => "s", "value" => "v", "x" => 1}]}, "secrets"},
        {%{"dry_run" => nil}, "dry_run"}
      ]

      for params <- inside,
          do:
            assert(
              WireBounds.valid?(:settings_command, command(params)) == :ok,
              inspect(Map.keys(params))
            )

      for {params, param} <- outside,
          do:
            assert(
              WireBounds.valid?(:settings_command, command(params)) == {:error, param},
              param
            )
    end

    test "the closed action list: the 57 actions §3.4.3 names" do
      assert length(WireBounds.actions()) == 57
      assert length(Enum.uniq(WireBounds.actions())) == 57
    end
  end

  test "record kinds: every declared kind is fetchable and secret fields are declared" do
    for kind <- RecordKind.all() do
      assert {:ok, ^kind} = RecordKind.fetch(kind.name)
    end

    assert {:ok, provider} = RecordKind.fetch("provider")
    assert RecordKind.secret_fields(provider) == ["api_key"]
    assert RecordKind.task_row_kind("provider.fetch_models") == "model_diff_row"
    assert :error = RecordKind.fetch("users")
  end
end
