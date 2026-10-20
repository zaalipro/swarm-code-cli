defmodule SwarmCodeCLI.Plain.OneShotImageOutputTest do
  @moduledoc """
  Pass 77 C-FEAT-10 (headless side): `--image` files are attached one at a time
  (`/attach <path>` through the dispatch the prompt takes) before the prompt is
  sent, a refused attach ends the command without sending the prompt, and
  `-o FILE` also writes the final answer, atomically.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.Test.OneShotHarness
  alias SwarmCodeCLI.Plain.OneShot
  alias SwarmCodeCLI.Test.OneShotHarness, as: H
  alias SwarmCodeCLI.UI.DataSource.{AdmissionError, DTO, Request}

  @staged_a "88888888-8888-4888-8888-888888888881"
  @staged_b "88888888-8888-4888-8888-888888888882"

  setup do
    source = start_supervised!({H.Source, self()})
    {:ok, output} = StringIO.open("")
    {:ok, error} = StringIO.open("")

    dir =
      Path.join(System.tmp_dir!(), "one-shot-output-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{source: source, output: output, error: error, dir: dir}
  end

  defp staged(id, name) do
    %DTO.Outcome{
      status: :accepted,
      identifiers: [id],
      result: %DTO.CommandResult{
        kind: :attachment,
        attachment: %DTO.StagedAttachment{id: id, name: name, mime: "image/png", bytes: 10}
      }
    }
  end

  defp next_command do
    assert_receive {:source, {:request, :command, %Request{} = request}}, 5_000
    request
  end

  describe "--image" do
    test "each image is attached in order before the prompt is sent", context do
      session = start(context, images: ["a.png", "docs/b.png"])
      assert {:dispatch, :send, "/attach a.png", :main, []} = session.dispatch.kind

      respond(session, session.dispatch, staged(@staged_a, "a.png"))
      second = next_command()
      assert {:dispatch, :send, "/attach docs/b.png", :main, []} = second.kind
      refute_received {:source, {:request, :command, _}}

      respond(session, second, staged(@staged_b, "b.png"))
      prompt = next_command()
      assert {:dispatch, :send, "list the notes", :main, []} = prompt.kind

      session = %{session | dispatch: prompt}
      session = session |> accept() |> upsert(message("Two notes.")) |> run_update(:done)
      complete(session, [run(:done)], [message("Two notes.")])

      assert code(session) == 0
      assert text(context.output) == "Two notes.\n"
    end

    test "a refused attach exits 1 with prompt_not_sent and sends no prompt", context do
      session = start(context, images: ["a.png", "b.png"], format: :json)
      assert {:dispatch, :send, "/attach a.png", :main, []} = session.dispatch.kind

      respond(session, session.dispatch, %DTO.Outcome{
        status: :rejected,
        error: AdmissionError.new(:not_allowed)
      })

      assert code(session) == 1
      refute_received {:source, {:request, :command, _}}

      summary = context.output |> text() |> String.split("\n", trim: true) |> List.last()
      object = Jason.decode!(summary)
      assert object["reason"] == "prompt_not_sent"

      assert object["error"] ==
               "the image a.png could not be attached (it must be a PNG, JPEG, GIF or WebP inside the project folder)."
    end

    test "an accepted command that staged nothing is not an attachment", context do
      session = start(context, images: ["a.png"])

      respond(session, session.dispatch, %DTO.Outcome{status: :accepted, identifiers: []})

      assert code(session) == 1
      assert text(context.error) =~ "the image a.png could not be attached"
      refute_received {:source, {:request, :command, _}}
    end

    test "more than four images, a non-path or a huge one are refused up front", context do
      for images <- [~w(a b c d e), [:not_text], [String.duplicate("x", 300_000)], "a.png"] do
        assert {:error, :invalid_one_shot} =
                 GenServer.start(
                   OneShot,
                   data_source: context.source,
                   source_epoch: H.epoch(),
                   conversation_id: H.conversation(),
                   prompt: "p",
                   images: images
                 )
      end
    end
  end

  describe "-o" do
    test "the file gets exactly the summary text and no temporary file is left", context do
      file = Path.join(context.dir, "answer.md")
      File.write!(file, "an earlier answer")

      session =
        start(context, output_file: file, format: :json)
        |> accept()
        |> upsert(message("Two notes."))
        |> run_update(:done)

      complete(session, [run(:done)], [message("Two notes.")])

      assert code(session) == 0
      assert File.read!(file) == "Two notes."
      assert File.ls!(context.dir) == ["answer.md"]

      summary = context.output |> text() |> String.split("\n", trim: true) |> List.last()
      assert Jason.decode!(summary)["text"] == File.read!(file)
    end

    test "text mode writes the same answer the stdout shows", context do
      file = Path.join(context.dir, "answer.txt")

      session =
        start(context, output_file: file)
        |> accept()
        |> upsert(message("Two notes."))
        |> run_update(:done)

      complete(session, [run(:done)], [message("Two notes.")])

      assert code(session) == 0
      assert File.read!(file) == "Two notes."
      assert text(context.output) == "Two notes.\n"
    end

    test "a file that cannot be written is said and turns exit 0 into 1", context do
      file = Path.join([context.dir, "missing-folder", "answer.md"])

      session =
        start(context, output_file: file, format: :json)
        |> accept()
        |> upsert(message("Two notes."))
        |> run_update(:done)

      complete(session, [run(:done)], [message("Two notes.")])

      assert code(session) == 1
      assert text(context.error) =~ "ncode: could not write #{file}: no such file or directory"
      assert File.ls!(context.dir) == []

      summary = context.output |> text() |> String.split("\n", trim: true) |> List.last()
      object = Jason.decode!(summary)
      assert object["reason"] == "output_not_written"
      assert object["exit_code"] == 1
      assert object["text"] == "Two notes."
    end

    test "a failed run with no answer leaves an earlier file alone", context do
      file = Path.join(context.dir, "answer.md")
      File.write!(file, "an earlier answer")

      session = start(context, output_file: file) |> accept() |> run_update(:failed)
      complete(session, [run(:failed)], [])

      assert code(session) == 1
      assert File.read!(file) == "an earlier answer"
    end

    test "a relative or empty output file is refused up front", context do
      for file <- ["answer.md", "", :atom] do
        assert {:error, :invalid_one_shot} =
                 GenServer.start(
                   OneShot,
                   data_source: context.source,
                   source_epoch: H.epoch(),
                   conversation_id: H.conversation(),
                   prompt: "p",
                   output_file: file
                 )
      end
    end
  end
end
