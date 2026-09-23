defmodule SwarmCode.Domain.AtomicFileTest do
  @moduledoc "Spec 31 §2.1/§2.2, as narrowed by spec 32 §1."
  use ExUnit.Case, async: true

  alias SwarmCode.Domain.AtomicFile

  setup do
    root = Path.join(System.tmp_dir!(), "atomic_file_#{System.unique_integer([:positive])}")

    outside =
      Path.join(root, "..") |> Path.expand() |> Path.join("outside_#{:erlang.phash2(root)}")

    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf(root) && File.rm_rf(outside) end)
    {:ok, root: root, outside: outside}
  end

  defp mode(path) do
    {:ok, %File.Stat{mode: mode}} = File.stat(path)
    Bitwise.band(mode, 0o7777)
  end

  defp temps(dir), do: dir |> File.ls!() |> Enum.filter(&String.contains?(&1, "swarm-code-"))

  describe "replace/3" do
    test "writes the content and leaves no temporary behind", %{root: root} do
      assert AtomicFile.replace(root, "a.txt", "hello") == :ok
      assert File.read!(Path.join(root, "a.txt")) == "hello"
      assert temps(root) == []
    end

    test "an existing file keeps its permissions", %{root: root} do
      path = Path.join(root, "script.sh")
      File.write!(path, "old")
      File.chmod!(path, 0o755)

      assert AtomicFile.replace(root, "script.sh", "new") == :ok
      assert File.read!(path) == "new"
      assert mode(path) == 0o755
    end

    test "a new file is the user's own", %{root: root} do
      assert AtomicFile.replace(root, "secret.txt", "x") == :ok
      assert mode(Path.join(root, "secret.txt")) == 0o600
    end

    test "creates missing parents", %{root: root} do
      assert AtomicFile.replace(root, "deep/er/still.txt", "x") == :ok
      assert File.read!(Path.join(root, "deep/er/still.txt")) == "x"
    end

    test "a large write arrives whole", %{root: root} do
      data = String.duplicate("0123456789", 500_000)
      assert AtomicFile.replace(root, "big.bin", data) == :ok
      assert File.read!(Path.join(root, "big.bin")) == data
      assert temps(root) == []
    end
  end

  describe "symlinks" do
    test "an in-root link is written through, not replaced", %{root: root} do
      real = Path.join(root, "docs/real.md")
      File.mkdir_p!(Path.dirname(real))
      File.write!(real, "old")
      link = Path.join(root, "README.md")
      File.ln_s!("docs/real.md", link)

      assert AtomicFile.replace(root, "README.md", "new") == :ok

      # The user's layout survives: the link is still a link, and the file it
      # points at is the one that changed.
      assert File.lstat!(link).type == :symlink
      assert File.read!(real) == "new"
      assert temps(Path.dirname(real)) == []
    end

    test "a link out of the root is refused and changes nothing", %{root: root, outside: outside} do
      victim = Path.join(outside, "passwd")
      File.write!(victim, "root:x:0:0")
      File.ln_s!(victim, Path.join(root, "escape"))

      assert AtomicFile.replace(root, "escape", "pwned") == {:error, :outside_root}
      assert File.read!(victim) == "root:x:0:0"
    end

    test "a directory link out of the root is refused", %{root: root, outside: outside} do
      File.write!(Path.join(outside, "keep.txt"), "safe")
      File.ln_s!(outside, Path.join(root, "away"))

      assert AtomicFile.replace(root, "away/keep.txt", "pwned") == {:error, :outside_root}
      assert File.read!(Path.join(outside, "keep.txt")) == "safe"
    end

    test "a link that loops is refused", %{root: root} do
      File.ln_s!(Path.join(root, "loop"), Path.join(root, "loop"))
      assert AtomicFile.replace(root, "loop", "x") == {:error, :symlink_cycle}
    end
  end

  describe "confinement" do
    test "a path above the root is refused", %{root: root, outside: outside} do
      victim = Path.join(outside, "target.txt")
      File.write!(victim, "safe")

      relative = Path.relative_to(victim, root)
      assert AtomicFile.replace(root, relative, "pwned") == {:error, :outside_root}
      assert AtomicFile.replace(root, victim, "pwned") == {:error, :outside_root}
      assert File.read!(victim) == "safe"
    end

    test "the root itself resolves to the root", %{root: root} do
      assert {:ok, target} = AtomicFile.target(root, ".")
      assert {:ok, ^target} = SwarmCode.Domain.Tools.Path.real_path(root)
    end
  end

  describe "update/4" do
    test "transforms what is there", %{root: root} do
      File.write!(Path.join(root, "a.txt"), "one")

      assert AtomicFile.update(root, "a.txt", fn current -> {:ok, current <> " two"} end) == :ok
      assert File.read!(Path.join(root, "a.txt")) == "one two"
    end

    test "a missing file is an error unless the caller says otherwise", %{root: root} do
      assert AtomicFile.update(root, "gone.txt", fn c -> {:ok, c} end) == {:error, :enoent}

      assert AtomicFile.update(root, "gone.txt", fn "" -> {:ok, "made"} end, missing: :empty) ==
               :ok

      assert File.read!(Path.join(root, "gone.txt")) == "made"
    end

    test "the callback's own error comes back and nothing is written", %{root: root} do
      File.write!(Path.join(root, "a.txt"), "one")

      assert AtomicFile.update(root, "a.txt", fn _ -> {:error, "no match"} end) ==
               {:error, "no match"}

      assert File.read!(Path.join(root, "a.txt")) == "one"
      assert temps(root) == []
    end

    test "an escaping target is refused before the callback runs", %{root: root, outside: outside} do
      File.write!(Path.join(outside, "x"), "safe")
      File.ln_s!(Path.join(outside, "x"), Path.join(root, "x"))

      assert AtomicFile.update(root, "x", fn _ -> flunk("must not read") end) ==
               {:error, :outside_root}
    end
  end

  describe "read/2 and remove/2" do
    test "reads only inside the root", %{root: root, outside: outside} do
      File.write!(Path.join(root, "in.txt"), "inside")
      File.write!(Path.join(outside, "out.txt"), "outside")
      File.ln_s!(Path.join(outside, "out.txt"), Path.join(root, "out.txt"))

      assert AtomicFile.read(root, "in.txt") == {:ok, "inside"}
      assert AtomicFile.read(root, "out.txt") == {:error, :outside_root}
    end

    test "removing is idempotent and confined", %{root: root, outside: outside} do
      File.write!(Path.join(root, "a.txt"), "x")
      victim = Path.join(outside, "keep.txt")
      File.write!(victim, "safe")

      assert AtomicFile.remove(root, "a.txt") == :ok
      assert AtomicFile.remove(root, "a.txt") == :ok
      refute File.exists?(Path.join(root, "a.txt"))

      assert AtomicFile.remove(root, victim) == {:error, :outside_root}
      assert File.exists?(victim)
    end
  end

  describe "format_error/1" do
    test "says what happened" do
      assert AtomicFile.format_error(:outside_root) == "path is outside the allowed root"
      assert AtomicFile.format_error(:symlink_cycle) == "the path links to itself"
      assert AtomicFile.format_error(:eacces) == "permission denied"
      assert AtomicFile.format_error("already a sentence") == "already a sentence"
    end
  end
end
