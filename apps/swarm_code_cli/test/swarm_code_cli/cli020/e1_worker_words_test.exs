defmodule SwarmCodeCLI.Cli020.E1WorkerWordsTest do
  # cli020 E1 (tui-code-7, owner decision 7): the desktop renamed "Sub agent
  # model" to "Worker model" and added "Validator model"; the CLI uses the
  # same words. Keys stay (`models.sub_agent`, `session.sub_agent_*`).
  use ExUnit.Case, async: true

  alias SwarmCode.Settings.Registry
  alias SwarmCodeCLI.UI.ModelPicker

  @root Path.expand("../../../../..", __DIR__)

  test "no lib string says sub-agent model or sub agent model" do
    hits =
      for app <- ~w[swarm_code_core swarm_code_cli swarm_code_daemon],
          path <- Path.wildcard(Path.join([@root, "apps", app, "lib", "**", "*.ex"])),
          {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          Regex.match?(~r/sub[- ]agent (model|effort)/i, line),
          do: "#{Path.relative_to(path, @root)}:#{n}"

    assert hits == []
  end

  test "the registry labels say Worker and the keys are unchanged" do
    assert Registry.fetch!("models.sub_agent").label == "Worker model"
    assert Registry.fetch!("efforts.sub_agent").label == "Worker effort"
    assert Registry.fetch!("session.sub_agent_model").label == "Worker model · this conversation"

    assert Registry.fetch!("session.sub_agent_effort").label ==
             "Worker effort · this conversation"

    assert Registry.fetch!("session.judge_model").null_label == "the worker model"
  end

  test "the validator entries exist" do
    v = Registry.fetch!("models.validator")
    assert v.label == "Validator model"
    assert v.home == :global
    assert v.storage == {:setting_pair, :default_validator_provider_id, :default_validator_model}
    assert v.null_label == "the main model"

    assert v.description ==
             "Checks mission work in the ncode app; the CLI's Ultra runs workflows."

    assert Registry.fetch!("efforts.validator").label == "Validator effort"
    assert Registry.fetch!("efforts.validator").storage == {:setting, :default_validator_effort}

    s = Registry.fetch!("session.validator_model")
    assert s.label == "Validator model · this conversation"
    assert s.storage == {:conversation_pair, :validator_provider_id, :validator_model}
  end

  test "the model picker says worker" do
    assert ModelPicker.title(:swarm) == "Worker model"
    assert ModelPicker.label(:swarm) == "Switch worker model…"
  end

  test "the command descriptions say worker" do
    descriptions = Map.new(SwarmCode.Commands.catalogue("/"), &{&1.name, &1.desc})
    assert descriptions["swarm_effort"] == "Reasoning effort of this conversation's worker model"
    assert descriptions["swarm_model"] == "Switch the model the workers use"
  end
end
