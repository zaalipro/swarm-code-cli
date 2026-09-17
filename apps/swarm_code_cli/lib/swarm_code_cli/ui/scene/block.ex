defmodule SwarmCodeCLI.UI.Scene.Block do
  alias SwarmCodeCLI.UI.Scene.Block.{
    Text,
    RichText,
    Markdown,
    Code,
    VirtualList,
    RunCard,
    AgentList,
    ConsensusLedger,
    ResearchDocument,
    Progress,
    Tabs,
    KeyValues,
    Composer,
    Notice,
    ActionDeck,
    Diff,
    Gauge,
    Chart,
    Surface,
    Columns
  }

  @type t ::
          Text.t()
          | RichText.t()
          | Markdown.t()
          | Code.t()
          | VirtualList.t()
          | RunCard.t()
          | AgentList.t()
          | ConsensusLedger.t()
          | ResearchDocument.t()
          | Progress.t()
          | Tabs.t()
          | KeyValues.t()
          | Composer.t()
          | Notice.t()
          | ActionDeck.t()
          | Diff.t()
          | Gauge.t()
          | Chart.t()
          | Surface.t()
          | Columns.t()
  def modules,
    do: [
      Text,
      RichText,
      Markdown,
      Code,
      VirtualList,
      RunCard,
      AgentList,
      ConsensusLedger,
      ResearchDocument,
      Progress,
      Tabs,
      KeyValues,
      Composer,
      Notice,
      ActionDeck,
      Diff,
      Gauge,
      Chart,
      Surface,
      Columns
    ]
end
