defmodule SwarmCode.Domain.Workflows.Canned do
  @moduledoc """
  The fake Runner the smoke check drives the program with (spec 09 §4.4): every
  agent "succeeds" with a canned object and nothing touches the network, the
  database or the LLM.

  Host calls are the exception (spec 11 §7.2): with a `root:` the read-only host
  helpers run **for real against the project tree**, so a work-list that comes
  out empty here comes out empty in the run too. Without a `root:` (the Library
  shape preview) they answer with the old fixed values.
  """
  use GenServer

  alias SwarmCode.Domain.Workflows.{Host, Schema}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def result(pid), do: GenServer.call(pid, :result)

  @impl true
  def init(opts) do
    {:ok,
     %{
       budget: opts[:budget] || 128,
       root: opts[:root],
       admitted: 0,
       seq: 0,
       phases: [],
       trace: [],
       gates: 0,
       logs: []
     }}
  end

  @impl true
  def handle_call(:result, _from, state) do
    # spec 68 T32: reverse the prepend-accumulated lists before returning
    result = %{
      state
      | phases:
          Enum.reverse(state.phases)
          |> Enum.map(fn p -> %{p | panels: Enum.reverse(p.panels)} end),
        trace: Enum.reverse(state.trace),
        logs: Enum.reverse(state.logs)
    }

    {:reply, result, state}
  end

  def handle_call({:phase, title}, _from, state) do
    # spec 68 T32: prepend instead of append
    {:reply, :ok,
     %{
       state
       | phases: [%{title: title, agents: 0, panels: []} | state.phases],
         trace: ["phase #{title}" | state.trace]
     }}
  end

  def handle_call({:log, text}, _from, state) do
    # spec 68 T32: prepend instead of append
    {:reply, :ok, %{state | logs: [text | state.logs]}}
  end

  def handle_call(:budget, _from, state) do
    {:reply,
     %{total: state.budget, spent: state.admitted, remaining: state.budget - state.admitted},
     state}
  end

  def handle_call({:panel_admit, count}, _from, state) do
    seq = state.seq + 1
    state = %{state | seq: seq}
    remaining = state.budget - state.admitted

    if count > remaining do
      message =
        "Panel of #{count} agents needs more than the remaining #{remaining} of " <>
          "#{state.budget} slots. Resume with a higher budget."

      {:reply, {:pause, "budget", message}, state}
    else
      state = %{
        state
        | admitted: state.admitted + count,
          trace: ["panel #{count}" | state.trace]
      }

      {:reply, {:ok, seq}, add_panel(state, count)}
    end
  end

  def handle_call({:host, :agent, _prompt, opts, %{seq: seq0, panel: panel?}}, _from, state) do
    state = if seq0, do: state, else: %{state | seq: state.seq + 1}

    if not panel? and state.admitted >= state.budget do
      message =
        "Panel of 1 agents needs more than the remaining 0 of #{state.budget} slots. " <>
          "Resume with a higher budget."

      {:reply, {:pause, "budget", message}, state}
    else
      state = if panel?, do: state, else: add_agent(%{state | admitted: state.admitted + 1})
      value = if opts[:schema], do: Schema.sample(opts[:schema]), else: "ok"
      {:reply, {:replay, value}, %{state | trace: ["agent" | state.trace]}}
    end
  end

  def handle_call({:host, :await_user, _question, opts, _where}, _from, state) do
    answer = List.first(Enum.map(opts[:options] || [], &to_string/1)) || "yes"
    {:reply, {:replay, answer}, %{state | gates: state.gates + 1}}
  end

  def handle_call({:host, :write_report, name, _opts, _where}, _from, state) do
    {:reply, {:replay, ".swarm_code/workflows/runs/smoke/#{name}"}, state}
  end

  def handle_call({:host, :read_report, _name, _opts, _where}, _from, state) do
    {:reply, {:replay, nil}, state}
  end

  def handle_call({:host, :host, op, opts, _where}, _from, state) do
    value =
      if state.root && Host.read_only?(op) do
        Host.run(op, opts, state.root)
      else
        canned(op)
      end

    {:reply, {:replay, value}, %{state | trace: ["host #{op}" | state.trace]}}
  end

  def handle_call(:last_error, _from, state), do: {:reply, nil, state}

  def handle_call({:commit, _seq, _slot, _kind, _value}, _from, state), do: {:reply, :ok, state}

  defp canned(:changed_files), do: ["lib/sample.ex"]
  defp canned(:glob), do: ["lib/sample.ex"]
  defp canned(:files), do: ["lib/sample.ex"]
  defp canned(:subdirs), do: ["lib/sample"]
  defp canned(:git_diff), do: "--- a/lib/sample.ex\n+++ b/lib/sample.ex\n+  sample line\n"

  defp canned(:git_log),
    do: [%{sha: "0000000", date: "2026-01-01", subject: "sample commit"}]

  defp canned(:read_file), do: "sample"
  defp canned(:list_dir), do: [%{name: "sample.ex", path: "lib/sample.ex", dir?: false}]
  defp canned(:grep), do: [%{file: "lib/sample.ex", line: 1, text: "sample"}]
  defp canned(:exists?), do: true
  defp canned(:dir?), do: false
  defp canned(:now), do: "2026-01-01T00:00:00Z"
  defp canned({:integrate, _id}), do: "ok"
  defp canned(_op), do: "sample"

  defp add_agent(state), do: update_phase(state, fn p -> %{p | agents: p.agents + 1} end)

  defp add_panel(state, count) do
    update_phase(state, fn p -> %{p | agents: p.agents + count, panels: [count | p.panels]} end)
  end

  # spec 68 T32: phases are prepended, so the current phase is the head
  defp update_phase(%{phases: []} = state, fun) do
    update_phase(%{state | phases: [%{title: "Run", agents: 0, panels: []}]}, fun)
  end

  defp update_phase(%{phases: [head | rest]} = state, fun) do
    %{state | phases: [fun.(head) | rest]}
  end
end
