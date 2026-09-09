defmodule SwarmCode.Daemon.Platform.MacOSTest do
  use ExUnit.Case, async: false
  alias SwarmCode.Daemon.Platform.MacOS

  test "parses bounded exact helper identity output" do
    assert {:ok, identity} =
             MacOS.parse_identity(
               ~s({"boot":"93E635C8-D50D-4ACD-8690-D6FEF716B2A9","kind":"identity","pid":731,"start":"1788912204:122765","uid":502,"version":1}\n),
               731
             )

    assert identity.uid == 502
    assert identity.process_start_id == "darwin-proc-start:1788912204:122765"
  end

  test "rejects malformed, extra, or mismatched helper output" do
    assert {:error, :macos_platform_helper_unavailable} = MacOS.parse_identity("{}\n", 1)

    assert {:error, :macos_platform_helper_unavailable} =
             MacOS.parse_identity("{\"kind\":\"identity\"}\n", 1)

    assert {:error, :macos_platform_helper_unavailable} =
             MacOS.parse_desktop(
               ~s({"version":1,"kind":"desktop","active":true,"pid":10,"uid":502,"application":"com.other.app"}\n),
               502
             )

    assert {:ok, :none} =
             MacOS.parse_desktop(~s({"version":1,"kind":"desktop","active":false}\n), 502)
  end

  test "identity rejects PID substitution and output framing violations" do
    valid =
      Jason.encode!(%{
        "boot" => "93E635C8-D50D-4ACD-8690-D6FEF716B2A9",
        "kind" => "identity",
        "pid" => 731,
        "start" => "1788912204:122765",
        "uid" => 502,
        "version" => 1
      }) <> "\n"

    for output <- [
          String.trim(valid),
          valid <> valid,
          "\n" <> valid,
          String.duplicate("a", 2049),
          String.replace(valid, "122765", "-00001")
        ] do
      assert {:error, :macos_platform_helper_unavailable} = MacOS.parse_identity(output, 731)
    end

    assert {:error, :macos_platform_helper_unavailable} = MacOS.parse_identity(valid, 732)

    assert {:error, :macos_platform_helper_unavailable} =
             MacOS.parse_desktop(
               ~s({"version":1,"kind":"desktop","active":false,"extra":true}\n),
               502
             )

    assert {:error, :macos_platform_helper_unavailable} =
             MacOS.parse_desktop(
               ~s({"version":1,"kind":"desktop","active":true,"pid":10,"uid":503,"application":"com.zaali.swarmcode"}\n),
               502
             )
  end

  if :os.type() == {:unix, :darwin} do
    test "missing, symlinked and tampered signed helpers fail closed" do
      root = temporary()
      path = Path.join(root, "helper")
      assert {:error, :macos_platform_helper_unavailable} = MacOS.verify_helper(path)
      File.cp!(MacOS.helper_path(), path)
      File.chmod!(path, 0o755)
      assert :ok = MacOS.verify_helper(path)
      File.write!(path, "tamper", [:append])
      assert {:error, :macos_platform_helper_unavailable} = MacOS.verify_helper(path)
      File.rm!(path)
      File.ln_s!(MacOS.helper_path(), path)
      assert {:error, :macos_platform_helper_unavailable} = MacOS.verify_helper(path)
    end

    test "native detector distinguishes exact bundle identity from a lookalike" do
      root = temporary()
      {_port, _pid} = launch_bundle(root, "lookalike", "com.zaali.swarmcode.other")
      assert :none = MacOS.desktop_detector().()
      {_port, pid} = launch_bundle(root, "exact", "com.zaali.swarmcode")

      assert {:active, %{pid: ^pid, application: "com.zaali.swarmcode", uid: uid}} =
               MacOS.desktop_detector().()

      assert {:ok, identity} = MacOS.current_identity()
      assert uid == identity.uid
    end
  end

  defp temporary do
    root = Path.join(System.tmp_dir!(), "swarm-macos-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp launch_bundle(root, name, identifier) do
    app = Path.join(root, name <> ".app")
    executable = Path.join(app, "Contents/MacOS/fixture")
    File.mkdir_p!(Path.dirname(executable))
    File.cp!("/bin/sleep", executable)
    File.chmod!(executable, 0o755)

    File.write!(
      Path.join(app, "Contents/Info.plist"),
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>#{identifier}</string><key>CFBundleExecutable</key><string>fixture</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>"
    )

    {_, 0} =
      System.cmd("/usr/bin/codesign", ["--force", "--sign", "-", app], stderr_to_stdout: true)

    port = Port.open({:spawn_executable, executable}, [:binary, :exit_status, args: ["30"]])
    on_exit(fn -> if Port.info(port), do: Port.close(port) end)
    Process.sleep(10)
    {:os_pid, pid} = Port.info(port, :os_pid)
    {port, pid}
  end
end
