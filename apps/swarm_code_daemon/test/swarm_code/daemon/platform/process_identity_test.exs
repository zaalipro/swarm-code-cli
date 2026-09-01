defmodule SwarmCode.Daemon.Platform.ProcessIdentityTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Daemon.Platform.ProcessIdentity

  test "Linux identity uses proc start ticks and boot id" do
    stat = "731 (beam.smp) S " <> Enum.join(List.duplicate("0", 18), " ") <> " 998877 0 0"

    assert {:ok, identity} = ProcessIdentity.from_linux(502, 731, stat, " boot-uuid\n")

    assert identity == %ProcessIdentity{
             uid: 502,
             pid: 731,
             process_start_id: "linux-proc-start:998877",
             boot_id: "boot-uuid"
           }
  end

  test "Linux identity finds field 22 after a process name containing spaces and parentheses" do
    stat =
      "731 (beam worker (scheduler)) S " <>
        Enum.join(List.duplicate("0", 18), " ") <> " 112233 0 0"

    assert {:ok, identity} = ProcessIdentity.from_linux(502, 731, stat, "boot-uuid")
    assert identity.process_start_id == "linux-proc-start:112233"
  end

  test "Darwin identity normalizes fixed helper output" do
    assert {:ok, identity} =
             ProcessIdentity.from_darwin(
               502,
               731,
               "2026-09-01T10:11:12.123456Z\n",
               "2026-08-20T07:00:00Z\n"
             )

    assert identity.process_start_id == "darwin-proc-start:2026-09-01T10:11:12.123456Z"
    assert identity.boot_id == "darwin-boot:2026-08-20T07:00:00Z"
  end

  test "current reads fixed Linux identity sources through explicit function options" do
    pid = System.pid() |> String.to_integer()
    stat = "#{pid} (beam.smp) S " <> Enum.join(List.duplicate("0", 18), " ") <> " 445566 0 0"

    read_file = fn
      "/proc/self/stat" -> {:ok, stat}
      "/proc/sys/kernel/random/boot_id" -> {:ok, "current-boot\n"}
    end

    command = fn "/usr/bin/id", ["-u"], [] -> {"502\n", 0} end

    assert {:ok, identity} =
             ProcessIdentity.current(platform: :linux, read_file: read_file, command: command)

    assert identity == %ProcessIdentity{
             uid: 502,
             pid: pid,
             process_start_id: "linux-proc-start:445566",
             boot_id: "current-boot"
           }
  end

  test "current fails closed on Darwin while the signed helper is unavailable" do
    assert {:error, :macos_platform_helper_unavailable} =
             ProcessIdentity.current(platform: :macos)
  end
end
