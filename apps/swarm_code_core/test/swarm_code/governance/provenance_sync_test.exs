defmodule SwarmCode.Governance.ProvenanceSyncTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Governance.ProvenanceSync
  alias SwarmCode.Governance.ProvenanceSync.{Ledger, Rules, UnifiedDiff}

  @domain "apps/d/lib/swarm_code/domain/"
  @migrations "apps/d/priv/domain_repo/migrations/"
  @agents "apps/d/priv/agents/"

  @beta_a """
  defmodule SwarmCode.Beta do
    @moduledoc "Beta."

    def one, do: 1

    def two, do: 2

    def three, do: 3

    def four, do: 4

    def five, do: 5

    def six, do: 6

    def seven, do: 7
  end
  """

  setup do
    base = Path.join(System.tmp_dir!(), "provenance-sync-#{System.unique_integer([:positive])}")
    upstream = Path.join(base, "upstream")
    root = Path.join(base, "cli")
    File.mkdir_p!(upstream)
    File.mkdir_p!(Path.join(root, "provenance"))
    on_exit(fn -> File.rm_rf!(base) end)

    git!(upstream, ["init", "-q", "-b", "main"])
    git!(upstream, ["config", "user.email", "t@example.com"])
    git!(upstream, ["config", "user.name", "t"])
    git!(upstream, ["config", "commit.gpgsign", "false"])

    write!(upstream, "lib/swarm_code/alpha.ex", """
    defmodule SwarmCode.Alpha do
      def app,   do:   Application.get_env(:swarm_code, :x)
      def pubsub(t), do: Phoenix.PubSub.subscribe(SwarmCode.PubSub, t)
    end
    """)

    write!(upstream, "lib/swarm_code/beta.ex", @beta_a)
    write!(upstream, "lib/swarm_code/application.ex", "defmodule SwarmCode.Application do\nend\n")

    write!(upstream, "priv/repo/migrations/20260101000000_one.exs", """
    defmodule SwarmCode.Repo.Migrations.One do
      use Ecto.Migration
      def change do
        alter table(:settings) do
          add :x,    :string
        end
      end
    end
    """)

    write!(upstream, "priv/agents/scout.md", "# Scout\n\nSwarmCode.Engine stays as written.\n")
    write!(upstream, "README.md", "not synced\n")
    commit_a = commit!(upstream, "a")

    write_rules!(root, commit_a)

    # A frozen entry (the CLI's un-namespaced live-runtime copy): outside every
    # mapping's destination, so sync and check leave it alone.
    File.mkdir_p!(Path.join(root, "apps/d/lib/legacy"))
    File.write!(Path.join(root, "apps/d/lib/legacy/alpha.ex"), "frozen copy\n")

    frozen = %{
      "classification" => "source",
      "destination" => "apps/d/lib/legacy/alpha.ex",
      "sha256" => sha256("frozen copy\n"),
      "upstream_commit" => String.duplicate("f", 40),
      "upstream_path" => "lib/swarm_code/alpha.ex",
      "upstream_sha256" => String.duplicate("0", 64)
    }

    Ledger.write(root, [frozen])

    %{root: root, upstream: upstream, commit_a: commit_a, frozen: frozen}
  end

  describe "sync/2" do
    test "derives every mapped file, records the ledger and the pin, and check passes", ctx do
      assert {:ok, report} = sync(ctx, ctx.commit_a)
      assert report.ref == ctx.commit_a

      assert Enum.sort(report.created) ==
               Enum.sort([
                 @domain <> "alpha.ex",
                 @domain <> "beta.ex",
                 @migrations <> "20260101000000_one.exs",
                 @agents <> "scout.md"
               ])

      alpha = read!(ctx.root, @domain <> "alpha.ex")
      assert alpha =~ "defmodule SwarmCode.Domain.Alpha do"
      assert alpha =~ "Application.get_env(:swarm_code_daemon, :x)"
      assert alpha =~ "SwarmCode.Domain.PubSub.subscribe(SwarmCode.Domain.PubSub, t)"
      # formatted: the upstream's extra spaces are gone
      assert alpha =~ "  def app, do: Application.get_env(:swarm_code_daemon, :x)\n"
      refute alpha =~ "   "

      migration = read!(ctx.root, @migrations <> "20260101000000_one.exs")
      assert migration =~ "defmodule SwarmCode.Domain.Repo.Migrations.One do"
      assert migration =~ "add :x,    :string", "migrations are rewritten, never formatted"

      assert read!(ctx.root, @agents <> "scout.md") ==
               "# Scout\n\nSwarmCode.Engine stays as written.\n"

      refute File.exists?(Path.join(ctx.root, @domain <> "application.ex"))
      refute File.exists?(Path.join(ctx.root, "provenance/patches"))

      {:ok, %{entries: entries}} = Ledger.load(ctx.root)
      assert hd(entries) == ctx.frozen
      alpha_entry = Enum.find(entries, &(&1["destination"] == @domain <> "alpha.ex"))

      assert alpha_entry == %{
               "classification" => "source",
               "destination" => @domain <> "alpha.ex",
               "sha256" => sha256(alpha),
               "upstream_commit" => ctx.commit_a,
               "upstream_path" => "lib/swarm_code/alpha.ex",
               "upstream_sha256" =>
                 sha256(show!(ctx.upstream, ctx.commit_a, "lib/swarm_code/alpha.ex"))
             }

      {:ok, rules} = Rules.load(ctx.root)
      assert rules.upstream_commit == ctx.commit_a
      assert :ok = check(ctx)
      assert read!(ctx.root, "apps/d/lib/legacy/alpha.ex") == "frozen copy\n"
    end

    test "untouched files follow upstream, a patched file merges, a deleted one goes", ctx do
      {:ok, _} = sync(ctx, ctx.commit_a)
      beta = @domain <> "beta.ex"

      local =
        String.replace(read!(ctx.root, beta), "def seven, do: 7", "def seven, do: :cli_seven")

      File.write!(Path.join(ctx.root, beta), local)

      assert {:error, errors} = check(ctx)

      assert Enum.any?(
               errors,
               &(&1 =~ "#{beta}: differs from the upstream derivation and has no recorded patch")
             )

      # Re-syncing to the pin records the deliberate edit as a patch.
      assert {:ok, %{patched: [^beta], merged: [^beta]}} = sync(ctx, ctx.commit_a)
      patch = read!(ctx.root, ProvenanceSync.patch_path(beta))
      assert patch =~ "-  def seven, do: 7\n+  def seven, do: :cli_seven\n"
      assert :ok = check(ctx)

      write!(
        ctx.upstream,
        "lib/swarm_code/beta.ex",
        String.replace(@beta_a, "def one, do: 1", "def one, do: :one")
      )

      write!(ctx.upstream, "lib/swarm_code/gamma.ex", "defmodule SwarmCode.Gamma do\nend\n")
      git!(ctx.upstream, ["rm", "-q", "lib/swarm_code/alpha.ex"])
      commit_b = commit!(ctx.upstream, "b")

      assert {:ok, report} = sync(ctx, commit_b)
      assert report.merged == [beta]
      assert report.created == [@domain <> "gamma.ex"]
      assert report.removed == [@domain <> "alpha.ex"]

      merged = read!(ctx.root, beta)
      assert merged =~ "def one, do: :one"
      assert merged =~ "def seven, do: :cli_seven"
      refute File.exists?(Path.join(ctx.root, @domain <> "alpha.ex"))

      {:ok, %{entries: entries}} = Ledger.load(ctx.root)
      destinations = Enum.map(entries, & &1["destination"])
      refute (@domain <> "alpha.ex") in destinations
      assert (@domain <> "gamma.ex") in destinations
      assert Enum.find(entries, &(&1["destination"] == beta))["upstream_commit"] == commit_b
      assert :ok = check(ctx)
    end

    test "the recorded patch is a unified diff git applies to the derivation", ctx do
      {:ok, _} = sync(ctx, ctx.commit_a)
      beta = @domain <> "beta.ex"
      derived = read!(ctx.root, beta)

      local =
        derived
        |> String.replace("def two, do: 2\n", "def two, do: 2\n\n  def two_and_a_half, do: 2.5\n")
        |> String.replace("  def six, do: 6\n\n", "")

      File.write!(Path.join(ctx.root, beta), local)
      {:ok, _} = sync(ctx, ctx.commit_a)

      scratch = Path.join(Path.dirname(ctx.root), "apply")
      File.mkdir_p!(Path.join(scratch, Path.dirname(beta)))
      File.write!(Path.join(scratch, beta), derived)

      {_out, 0} =
        System.cmd("git", ["apply", Path.join(ctx.root, ProvenanceSync.patch_path(beta))],
          cd: scratch,
          stderr_to_stdout: true
        )

      assert File.read!(Path.join(scratch, beta)) == local
    end

    test "a conflict writes only the .sync-conflict file; --resolved takes the hand merge", ctx do
      {:ok, _} = sync(ctx, ctx.commit_a)
      beta = @domain <> "beta.ex"

      File.write!(
        Path.join(ctx.root, beta),
        String.replace(read!(ctx.root, beta), "def four, do: 4", "def four, do: :cli")
      )

      {:ok, _} = sync(ctx, ctx.commit_a)

      write!(
        ctx.upstream,
        "lib/swarm_code/beta.ex",
        String.replace(@beta_a, "def four, do: 4", "def four, do: :upstream")
      )

      write!(ctx.upstream, "lib/swarm_code/gamma.ex", "defmodule SwarmCode.Gamma do\nend\n")
      commit_c = commit!(ctx.upstream, "c")

      before = snapshot(ctx.root)
      assert {:error, %{conflicts: [^beta], removed_but_patched: []}} = sync(ctx, commit_c)
      conflict = read!(ctx.root, beta <> ".sync-conflict")
      assert conflict =~ "<<<<<<< cli #{beta}"
      assert conflict =~ "def four, do: :upstream"
      assert Map.delete(snapshot(ctx.root), beta <> ".sync-conflict") == before
      refute File.exists?(Path.join(ctx.root, @domain <> "gamma.ex"))

      resolved =
        String.replace(
          read!(ctx.root, beta),
          "def four, do: :cli",
          "def four, do: {:cli, :upstream}"
        )

      File.write!(Path.join(ctx.root, beta), resolved)

      assert {:error, message} = sync(ctx, commit_c, resolved: ["apps/d/lib/elsewhere.ex"])
      assert message =~ "not synced"

      assert {:ok, report} = sync(ctx, commit_c, resolved: [beta])
      assert report.resolved == [beta]
      assert read!(ctx.root, beta) == resolved
      refute File.exists?(Path.join(ctx.root, beta <> ".sync-conflict"))
      assert :ok = check(ctx)
    end

    test "a new upstream file landing on a CLI-local file stops before writing", ctx do
      {:ok, _} = sync(ctx, ctx.commit_a)
      File.write!(Path.join(ctx.root, @domain <> "gamma.ex"), "cli-local\n")
      write!(ctx.upstream, "lib/swarm_code/gamma.ex", "defmodule SwarmCode.Gamma do\nend\n")
      commit_b = commit!(ctx.upstream, "b")
      before = snapshot(ctx.root)

      assert {:error, message} = sync(ctx, commit_b)
      assert message =~ "gamma.ex exists but is not a provenance entry"
      assert snapshot(ctx.root) == before
    end

    test "a dirty upstream worktree is refused; a bad ref is refused", ctx do
      write!(ctx.upstream, "lib/swarm_code/alpha.ex", "defmodule SwarmCode.Alpha do\nend\n")

      assert {:error, message} =
               ProvenanceSync.sync(ctx.root, upstream: ctx.upstream, ref: ctx.commit_a)

      assert message =~ "uncommitted changes"

      assert {:error, message} =
               ProvenanceSync.sync(ctx.root, upstream: ctx.upstream, ref: "--output=/tmp/x")

      assert message =~ "invalid upstream ref"

      assert {:error, _message} =
               ProvenanceSync.sync(ctx.root,
                 upstream: Path.join(ctx.root, "missing"),
                 ref: "main"
               )
    end
  end

  describe "check/2" do
    test "names every kind of drift", ctx do
      {:ok, _} = sync(ctx, ctx.commit_a)
      beta = @domain <> "beta.ex"
      File.write!(Path.join(ctx.root, beta), read!(ctx.root, beta) <> "# local\n")
      {:ok, _} = sync(ctx, ctx.commit_a)
      assert :ok = check(ctx)

      File.write!(Path.join(ctx.root, beta), read!(ctx.root, beta) <> "# more\n")
      stray = ProvenanceSync.patch_path(@domain <> "nothing.ex")
      File.mkdir_p!(Path.dirname(Path.join(ctx.root, stray)))
      File.write!(Path.join(ctx.root, stray), "stale\n")

      {:ok, %{entries: entries}} = Ledger.load(ctx.root)
      Ledger.write(ctx.root, Enum.reject(entries, &(&1["destination"] == @agents <> "scout.md")))

      assert {:error, errors} = check(ctx)
      assert Enum.any?(errors, &(&1 =~ "#{beta}: sha256 does not match the file"))
      assert Enum.any?(errors, &(&1 =~ "no longer describes the file"))
      assert Enum.any?(errors, &(&1 =~ "no synced file carries this patch"))
      assert Enum.any?(errors, &(&1 =~ "scout.md is upstream but not synced"))
    end
  end

  describe "UnifiedDiff" do
    test "equal texts have no diff; hunks carry three lines of context" do
      old = Enum.map_join(1..20, "", &"line #{&1}\n")
      assert UnifiedDiff.diff(old, old, "a", "b") == ""

      new = String.replace(old, "line 10\n", "line ten\n")

      assert UnifiedDiff.diff(old, new, "x", "x") == """
             --- a/x
             +++ b/x
             @@ -7,7 +7,7 @@
              line 7
              line 8
              line 9
             -line 10
             +line ten
              line 11
              line 12
              line 13
             """
    end

    test "a pure insertion and a missing final newline follow git's notation" do
      assert UnifiedDiff.diff("a\n", "a\nb", "f", "f") == """
             --- a/f
             +++ b/f
             @@ -1 +1,2 @@
              a
             +b
             \\ No newline at end of file
             """

      assert UnifiedDiff.diff("", "x\n", "f", "f") == "--- a/f\n+++ b/f\n@@ -0,0 +1 @@\n+x\n"
    end
  end

  describe "Rules" do
    test "globs match path segments the way the rules file means them" do
      assert Regex.match?(Rules.glob_regex("**/*.ex"), "a.ex")
      assert Regex.match?(Rules.glob_regex("**/*.ex"), "engine/isolation/clone.ex")
      refute Regex.match?(Rules.glob_regex("*.exs"), "nested/one.exs")
      assert Regex.match?(Rules.glob_regex("*.exs"), ".formatter.exs")

      assert Regex.match?(
               Rules.glob_regex("lib/swarm_code/desktop/**"),
               "lib/swarm_code/desktop/memory.ex"
             )
    end

    test "the CLI's own rules file loads and keeps the desktop-only modules out", %{} do
      root = Path.expand("../../../../..", __DIR__)
      assert {:ok, rules} = Rules.load(root)

      for path <-
            ~w(lib/swarm_code/application.ex lib/swarm_code/bootstrap.ex
                     lib/swarm_code/desktop.ex lib/swarm_code/desktop/memory.ex
                     lib/swarm_code/quit.ex lib/swarm_code/tray_menu.ex lib/swarm_code/menu_bar.ex) do
        assert Rules.mapping_for(rules, path) == nil, path
      end

      assert %Rules.Mapping{} = Rules.mapping_for(rules, "lib/swarm_code/engine/run_server.ex")

      assert Rules.rewrite(rules, "SwarmCode.Desktop.notify(x) Phoenix.HTML.raw(y) :swarm_code") ==
               "SwarmCode.Domain.Notifications.notify(x) SwarmCode.Domain.HTML.raw(y) :swarm_code_daemon"
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp sync(ctx, ref, extra \\ []),
    do: ProvenanceSync.sync(ctx.root, [upstream: ctx.upstream, ref: ref] ++ extra)

  defp check(ctx), do: ProvenanceSync.check(ctx.root, upstream: ctx.upstream)

  defp write_rules!(root, commit) do
    rules = %{
      "version" => 1,
      "upstream_commit" => commit,
      "rewrite_rules" => [
        %{
          "id" => "namespace",
          "pattern" => "\\bSwarmCode\\.(?!Domain\\b)([A-Z{])",
          "replacement" => "SwarmCode.Domain.\\1"
        },
        %{
          "id" => "pubsub",
          "pattern" => "\\bPhoenix\\.PubSub\\.(subscribe)\\(",
          "replacement" => "SwarmCode.Domain.PubSub.\\1("
        },
        %{
          "id" => "otp",
          "pattern" => ":swarm_code\\b(?!_)",
          "replacement" => ":swarm_code_daemon"
        }
      ],
      "mappings" => [
        %{
          "upstream" => "lib/swarm_code/",
          "destination" => @domain,
          "classification" => "source",
          "rewrite" => true,
          "format" => true,
          "include" => ["**/*.ex"]
        },
        %{
          "upstream" => "priv/repo/migrations/",
          "destination" => @migrations,
          "classification" => "source",
          "rewrite" => true,
          "format" => false,
          "include" => ["*.exs"]
        },
        %{
          "upstream" => "priv/agents/",
          "destination" => @agents,
          "classification" => "source",
          "rewrite" => false,
          "format" => false,
          "include" => ["*.md"]
        }
      ],
      "exclude" => ["lib/swarm_code/application.ex"]
    }

    File.write!(Path.join(root, Rules.relative_path()), Jason.encode!(rules, pretty: true))
  end

  defp write!(dir, relative, contents) do
    path = Path.join(dir, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  defp read!(dir, relative), do: File.read!(Path.join(dir, relative))

  defp commit!(upstream, message) do
    git!(upstream, ["add", "-A"])
    git!(upstream, ["commit", "-q", "-m", message])
    upstream |> git!(["rev-parse", "HEAD"]) |> String.trim()
  end

  defp show!(upstream, sha, path), do: git!(upstream, ["cat-file", "blob", "#{sha}:#{path}"])

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
    out
  end

  defp snapshot(root) do
    root
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Map.new(&{Path.relative_to(&1, root), File.read!(&1)})
  end

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
