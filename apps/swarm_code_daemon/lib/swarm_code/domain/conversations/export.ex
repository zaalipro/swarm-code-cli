defmodule SwarmCode.Domain.Conversations.Export do
  @moduledoc """
  Renders a conversation transcript as a Markdown string.
  """

  # spec 70 D7

  alias SwarmCode.Domain.Conversations

  @spec to_markdown(String.t()) :: String.t()
  def to_markdown(conversation_id) do
    conv = Conversations.get!(conversation_id)
    messages = Conversations.list_messages(conversation_id)
    runs = Conversations.list_runs(conversation_id)

    visible =
      Enum.filter(messages, fn m ->
        is_nil(m.superseded_at) and (m.content || "") != ""
      end)

    [
      "# #{conv.title || "Untitled"}\n\n",
      "**Project:** #{project_name(conv)}  \n",
      "**Created:** #{format_time(conv.inserted_at)}  \n",
      "**Messages:** #{length(visible)}  \n",
      "**Runs:** #{length(runs)}\n\n",
      "---\n\n",
      Enum.map(visible, &render_message/1)
    ]
    |> IO.iodata_to_binary()
  end

  defp render_message(m) do
    label = role_label(m.role)
    time = format_time(m.inserted_at)
    content = m.content || ""

    "## #{label}\n_#{time}_\n\n#{content}\n\n"
  end

  defp role_label("user"), do: "User"
  defp role_label("assistant"), do: "Assistant"
  defp role_label("swarm"), do: "Swarm"
  defp role_label("compact"), do: "Summary"
  defp role_label("error"), do: "Error"
  defp role_label("workflow"), do: "Workflow"
  defp role_label(other), do: other

  defp project_name(%{project: %{name: name}}) when is_binary(name), do: name
  defp project_name(_), do: "None"

  defp format_time(nil), do: ""
  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_time(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_time(_), do: ""
end
