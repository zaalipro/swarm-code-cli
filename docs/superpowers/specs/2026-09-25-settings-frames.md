# Settings TUI — frames

Companion to `inv-tui-design.md` (rationale, information architecture, interaction rules). These
16 frames are the visual contract for `/settings` in the SwarmCode CLI. They were drawn on a
cell canvas by `scratch/tui-design/build_frames.py`: every row is exactly the frame's width under the
narrow ambiguous-width policy, and the builder refuses overflow and overlapping text, so the columns
below are real. `frames.html` (same directory) renders the same frames in the Carbon dark palette with
every span classed by its Theme role, the way the side-panel gallery's `D2.html` was.

## How to read a frame

- The ```text block is the screen, glyph for glyph. Trailing spaces are part of the frame.
- **Roles** lists, for every Theme role used in the frame, the texts drawn in it (deduplicated, in
  reading order). A role written `text_muted on selection` is a foreground role over the
  `:selection` background. Roles are `SwarmCodeCLI.UI.Theme` roles (`ui/theme.ex`); the short code
  in brackets is the builder's and the HTML class.
- **Notes** are the behaviour the picture cannot show.
- Mapping to the D2 gallery's classes: `tp`=`:text_primary`, `tm`=`:text_muted`, `tf`=`:text_faint`,
  `tg`=`:text_ghost`, `ac`=`:accent`, `wa`=`:warning`, `er`=`:error`, `ok`=`:success`, `in`=`:info`,
  D2's `.key` badge = `:on_accent` (here `oa`), `surf`=`:surface`, `card`=`:card`. Footer key names
  use `:key` (info blue, bold), exactly as the live status row does ("Enter act").
- Rules (`─ │`) are drawn in `text_ghost`, as D2 draws them; the painter may use `:border_soft`.
- Sample data: project `ailogic`, conversation `4f2a`, providers DeepSeek / Anthropic / llmotions /
  Local Ollama, MCP servers tavily / filesystem / github, an approval from `deps-agent` waiting.

## Role codes

| code | Theme role | Carbon dark value |
|---|---|---|
| `tp` | `text_primary` | `color:#F3F2F0` |
| `tb` | `title / emphasis (text_primary bold)` | `color:#F3F2F0;font-weight:700` |
| `tm` | `text_muted (label)` | `color:#8C8B88` |
| `tf` | `text_faint` | `color:#5E5D5A` |
| `tg` | `text_ghost` | `color:#4B4A48` |
| `fo` | `focus` | `color:#FF6A1A` |
| `ac` | `accent` | `color:#FF6A1A` |
| `wa` | `warning` | `color:#F5B400` |
| `wb` | `warning bold` | `color:#F5B400;font-weight:700` |
| `er` | `error` | `color:#FF4D4F` |
| `ok` | `success` | `color:#3DDC5A` |
| `in` | `info` | `color:#4DA3FF` |
| `ky` | `key (info bold)` | `color:#4DA3FF;font-weight:700` |
| `oa` | `on_accent (hint badge)` | `color:#111111;background:#FF6A1A;font-weight:700` |
| `ow` | `on_warn` | `color:#111111;background:#F5B400;font-weight:700` |
| `cw` | `chip_warn` | `color:#F5B400;background:#3C331A` |
| `ca` | `chip_accent` | `color:#FF6A1A;background:#3E291D` |
| `ck` | `chip_ok` | `color:#3DDC5A;background:#223926` |
| `ce` | `chip_err` | `color:#FF4D4F;background:#3E2525` |
| `ci` | `chip_info` | `color:#4DA3FF;background:#25313E` |
| `cd` | `code` | `color:#F3F2F0;background:#262626` |
| `di` | `disabled` | `color:#5E5D5A` |
| `l1` | `agent_lane_1` | `color:#2DD4BF` |
| `l2` | `agent_lane_2` | `color:#A78BFA` |
| `as` | `run_assistant` | `color:#FF6A1A` |
| `sw` | `run_swarm` | `color:#2DD4BF` |
| `+se` | `selection` (background) | `background:#262626` |
| `+po` | `popover` (background) | `background:#1C1C1C` |
| `+su` | `surface` (background) | `background:#191919` |
| `+lt` | `light page (preview swatch)` (background) | `background:#F4F3EF` |
| `mo` `mb` `mr` | NO_COLOR: plain, bold, reversed (`:selection` in monochrome is `[:reversed]`) | no SGR colour |
| `L*` | the light theme's own roles, used only inside the light preview swatch of F10 | light palette |

## Frames

- [F1 · Overview · the landing page](#f1) — 160 × 45
- [F2 · Search · every setting by label, key, description and value](#f2) — 160 × 45
- [F3 · Models & effort · provenance for the focused value](#f3) — 160 × 45
- [F4 · Model picker · fetched models, grouped by provider](#f4) — 160 × 45
- [F5 · Providers › DeepSeek · a secret, a test, the models](#f5) — 160 × 45
- [F6 · Providers › DeepSeek · pasting a key, checking a fetch](#f6) — 160 × 45
- [F7 · Search & research · ordered providers, a stepped number, lists](#f7) — 160 × 45
- [F8 · MCP servers › github · key-value with secrets, tools, a restart in flight](#f8) — 160 × 45
- [F9 · Agents & limits · a rejected value, bounds, lists, definitions](#f9) — 160 × 45
- [F10 · Appearance · the theme with an environment override, colour and glyph tiers, preview](#f10) — 160 × 45
- [F11 · Keys & input · capturing a key that is taken](#f11) — 160 × 45
- [F12 · Confirmation · deleting a provider that others depend on](#f12) — 160 × 45
- [F13 · Help · ? (or F1) over settings](#f13) — 160 × 45
- [F14 · Narrow · 90 × 30 · Approvals & trust (this project)](#f14) — 90 × 30
- [F15 · Narrow · 90 × 30 · the same frame with NO_COLOR and SWARM_ASCII=1](#f15) — 90 × 30
- [F16 · Smallest · 80 × 24 · drill-down pages](#f16) — 80 × 24

---

## F1

### F1 · Overview · the landing page · 160 × 45

`/settings` with no argument. The rail lists Overview and 21 sections in six groups; the page says what needs you, what is set, what differs from the defaults and where values come from. Focus is on the first attention item; its detail is on the right.

```text
 Settings › Overview                                                                                            ailogic · conversation 4f2a    Esc back to chat 
 / search 212 settings, providers, servers and keys                                                   • 14 changed from default  ! 3 need attention  2 from env 
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
▌ Overview                │  needs attention                                                                 3 │ github  MCP server · stdio · every project     
                          │▌! github MCP server failed to start                                     Enter open │                                                
  models                  │     command not found: github-mcp-server · last try 18:41                          │ ✗ failed to start at 18:41                     
   Models & effort     •4 │ ! 2 models in use have no price                                         Enter open │ command not found: github-mcp-server           
   Providers            4 │     claude-sonnet-5 and qwen3-coder count as $0.00 in every cost                   │                                                
   Pricing             !2 │                                                                                    │ it ran                                         
                          │  at a glance                                                                       │    github-mcp-server stdio                     
  tools                   │   providers   4 · 3 answered their last test · 1 never tested                      │ with                                           
   Search & research   •2 │   search      Tavily and Exa on · pages through web_fetch · 4 off                  │   GITHUB_PERSONAL_ACCESS_TOKEN ●●●●●●●●        
   MCP servers         !1 │   MCP         3 servers · 2 connected · 1 failed · 41 tools, 3 switched off        │   GITHUB_TOOLSETS repos,issues                 
   Language servers       │   agents      6 at once · depth 2 · 60 turns · 30 min each                         │                                                
                          │   approvals   ailogic: auto · trusted · 5 always-allowed commands                  │ server output · last 2 lines                   
  agents                  │   storage     1.8 GB · last cleanup 12 days ago                                    │   sh: github-mcp-server: command not found     
   Agents & limits     •2 │   budget      $38.20 of $50.00 this month    ▰▰▰▰▰▰▰▰▰▰▰▰▱▱▱▱                      │   exited 127 after 0.1 s                       
   Approvals & trust   •1 │                                                                                    │                                                
   Project file           │  changed from default                               14 · @modified lists every one │ what you can do                                
   Memory                 │ • Theme                         light · cli.json says dark         env SWARM_THEME │   Enter  open the server and fix it            
   Library                │ • Side panel                    compact                                   cli.json │   r      reconnect now                         
                          │ • Show diffs                    off                                       cli.json │   Space  switch it off; it stays listed        
  this terminal           │ • Chat model                    deepseek-v4-pro · DeepSeek                  global │   o      all of its output                     
   Appearance          •1 │ • Sub-agent model               deepseek-v4-flash · DeepSeek                global │                                                
   Layout & transcript •2 │ • Effort · this conversation    high                                       session │                                                
   Keys & input        •1 │ • Max concurrent agents         6                                           global │                                                
   Notifications          │ • Approvals                     auto                               project ailogic │                                                
   Session & startup      │ • Research agents in flight     12                                          global │                                                
                          │   … 5 more                                                                         │                                                
  data                    │                                                                                    │                                                
   Storage                │  where values come from                             values each layer supplies now │                                                
   Budget & usage      •1 │   flag            1  --model deepseek-v4-pro, this launch only                     │                                                
                          │   env             2  SWARM_THEME, VISUAL                                           │                                                
  more                    │   session         2  model, effort · this conversation                             │                                                
   Desktop app            │   project         3  approvals, trust, 5 always-allowed commands                   │                                                
   Files & environment    │   cli.json        4  panel, diffs, theme, 1 key · this machine's terminal          │                                                
   Import & export        │   global         11  shared with the desktop app                                   │                                                
                          │   project file    0  effort is set there but the global row wins                   │                                                
                          │   default       189  built in                                                      │                                                
                          │                                                                                    │                                                
                          │  changed in this session                                       u undoes the newest │                                                
                          │   18:40 Side panel full → compact  18:31 DeepSeek API key replaced · no undo       │                                                
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 /settings <words> opens straight at a setting · : runs a settings command such as :set theme light                                                             
 ↑↓ move   Enter open   / search   [ ] section   Ctrl-F jump   : command   u undo   ? keys                                                             settings 
```

**Roles**

- `title / emphasis (text_primary bold)` (tb): `Settings` · `Overview` · `github`
- `text_faint` (tf): `›` · `ailogic · conversation 4f2a` · `back to chat` · `14 changed from default` · `3 need attention` · `2 from env` · `▌` · `MCP server · stdio · every project` · `models` · `open` · `4` · `tools` · `agents` · `sh: github-mcp-server: command not found` · `exited 127 after 0.1 s` · `14 · @modified lists every one` · `· cli.json says dark` · `SWARM_THEME` · `this terminal` · `ailogic` · `… 5 more` · `data` · `values each layer supplies now` · `--model deepseek-v4-pro, this launch only` · `SWARM_THEME, VISUAL` · `more` · `model, effort · this conversation` · `approvals, trust, 5 always-allowed commands` · `panel, diffs, theme, 1 key · this machine's t…` · `shared with the desktop app` · `effort is set there but the global row wins` · `built in` · `undoes the newest` · `18:40` · `18:31` · `· no undo` · `/settings <words> opens straight at a setting…` · `move` · `search` · `section` · `jump` · `command` · `undo` · `keys` · `settings`
- `text_primary` (tp): `Overview` · `failed to start at 18:41` · `2 models in use have no price` · `4 · 3 answered their last test · 1 never test…` · `Tavily and Exa on · pages through web_fetch ·…` · `GITHUB_PERSONAL_ACCESS_TOKEN` · `3 servers · 2 connected · 1 failed · 41 tools…` · `GITHUB_TOOLSETS` · `6 at once · depth 2 · 60 turns · 30 min each` · `ailogic: auto · trusted · 5 always-allowed co…` · `1.8 GB · last cleanup 12 days ago` · `$38.20 of $50.00 this month` · `Theme` · `light` · `open the server and fix it` · `Side panel` · `compact` · `reconnect now` · `Show diffs` · `off` · `switch it off; it stays listed` · `Chat model` · `deepseek-v4-pro · DeepSeek` · `all of its output` · `Sub-agent model` · `deepseek-v4-flash · DeepSeek` · `Effort · this conversation` · `high` · `Max concurrent agents` · `6` · `Approvals` · `auto` · `Research agents in flight` · `12` · `1` · `2` · `3` · `4` · `11` · `0` · `189` · `DeepSeek API key`
- `key (info bold)` (ky): `Esc` · `Enter` · `r` · `Space` · `o` · `u` · `↑↓` · `/` · `[ ]` · `Ctrl-F` · `:` · `?`
- `text_muted (label)` (tm): `/` · `•` · `needs attention` · `command not found: github-mcp-server · last t…` · `Models & effort` · `•4` · `command not found: github-mcp-server` · `Providers` · `claude-sonnet-5 and qwen3-coder count as $0.0…` · `Pricing` · `it ran` · `at a glance` · `providers` · `with` · `Search & research` · `•2` · `search` · `●●●●●●●●` · `MCP servers` · `MCP` · `repos,issues` · `Language servers` · `agents` · `approvals` · `server output · last 2 lines` · `storage` · `Agents & limits` · `budget` · `▰▰▰▰▰▰▰▰▰▰▰▰` · `Approvals & trust` · `•1` · `Project file` · `changed from default` · `what you can do` · `Memory` · `env` · `Library` · `cli.json` · `global` · `Appearance` · `Layout & transcript` · `session` · `Keys & input` · `Notifications` · `project` · `Session & startup` · `Storage` · `where values come from` · `Budget & usage` · `flag` · `Desktop app` · `Files & environment` · `Import & export` · `project file` · `default` · `changed in this session` · `full → compact` · `replaced`
- `text_ghost` (tg): `search 212 settings, providers, servers and k…` · `─────────────────────────────────────────────…` · `│` · `▱▱▱▱`
- `warning` (wa): `!` · `3` · `!2` · `!1`
- `focus on selection` (fo+se): `▌`
- `warning on selection` (wa+se): `!`
- `text_primary on selection` (tp+se): `github MCP server failed to start`
- `key (info bold) on selection` (ky+se): `Enter`
- `text_faint on selection` (tf+se): `open`
- `error` (er): `✗`
- `code` (cd): `github-mcp-server stdio`

**Notes**

- Opening focus: the first *needs attention* row when there is one, else the last section visited in this session, else Overview.
- The rail's `•4` is a count of values changed from their defaults (text_muted); `!2` is a count of attention items (warning). A plain number is a record count (text_faint).
- The budget gauge is allowed by R5: spend over a configured limit is a known ratio.
- `u` undoes the newest row of *changed in this session*; a secret change is listed but never undoable.

---

## F2

### F2 · Search · every setting by label, key, description and value · 160 × 45

`/` then `timeout`. Results are the real rows, editable in place, grouped by section in rail order. The rail dims the sections without a match and counts the matches of the others. Each result has a second row: its key and the words that matched, the match in bold.

```text
 Settings › Search                                                                                                                             Esc back to chat 
 / timeout▏                                                                                                                               7 of 212 · 3 sections 
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  Overview                │  filters   @modified  @env  @project  @session  @shared  @cli  @secret  @attention │ Command timeout                                
                          │                                                                                    │ limits.command_timeout · command_timeout_ms    
  models                  │  Agents & limits                                                                 3 │                                                
   Models & effort        │   Sub-agent time limit          30 min                                     default │ The time every shell command an agent runs     
   Providers              │     limits.sub_agent_timeout  a worker past this is stopped; also called timeout   │ gets at least; a tool call may ask for more,   
   Pricing                │▌• Command timeout               180 s                                       global │ never for less. Past its limit the command     
                          │     limits.command_timeout  the least any shell command gets; a call may ask more  │ and its process tree are stopped.              
  tools                   │   Tool timeout                  120 s                                      default │                                                
   Search & research    3 │     limits.tool_timeout  any other tool call                                       │ value     180 s                                
   MCP servers            │                                                                                    │ default   120 s                                
   Language servers       │  Search & research                                                               3 │ range     1 – 600 s · step 5 s, Shift ×10      
                          │   Seconds an agent may take     600 s                                      default │ applies   to commands started from now         
  agents                  │     research.agent_timeout  then a partial note · also called timeout              │ shared    with the desktop app                 
   Agents & limits      3 │   Retries after a timeout       1                                          default │                                                
   Approvals & trust      │     research.max_retries  each retry starts from the partial note                  │ where it comes from        strongest first     
   Project file         1 │   Retry timed-out agents        [✓] on                                     default │ › global    180 s                          ✓   
   Memory                 │     research.retry_timeouts  off: the round keeps the partial note · timeout       │   default   120 s                              
   Library                │                                                                                    │                                                
                          │  Project file · ailogic                                                          1 │ Enter type a value   ←→ step   r reset to 120 s
  this terminal           │   Hook timeout · mix format     10 s                                  project file │ y copy the key      g go to Agents & limits    
   Appearance             │     project.hooks.pre_tool_use[1].timeout  pre_tool_use · the hook is stopped      │                                                
   Layout & transcript    │                                                                                    │                                                
   Keys & input           │  not what you meant? words like wait, limit or seconds search descriptions too     │                                                
   Notifications          │                                                                                    │                                                
   Session & startup      │                                                                                    │                                                
                          │                                                                                    │                                                
  data                    │                                                                                    │                                                
   Storage                │                                                                                    │                                                
   Budget & usage         │                                                                                    │                                                
                          │                                                                                    │                                                
  more                    │                                                                                    │                                                
   Desktop app            │                                                                                    │                                                
   Files & environment    │                                                                                    │                                                
   Import & export        │                                                                                    │                                                
                          │                                                                                    │                                                
                          │                                                                                    │                                                
                          │                                                                                    │                                                
                          │                                                                                    │                                                
                          │                                                                                    │                                                
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 Enter edits in place · ↓ from the query goes to the results · Esc clears the query                              writes to global · shared with the desktop app 
 ↑↓ move   Enter edit   ←→ step   r reset   g go to its section   Tab complete @filter   Esc clear                                            settings · search 
```

**Roles**

- `title / emphasis (text_primary bold)` (tb): `Settings` · `Command timeout` · `timeout`
- `text_faint` (tf): `›` · `back to chat` · `of 212 · 3 sections` · `filters` · `limits.command_timeout · command_timeout_ms` · `models` · `3` · `default` · `limits.sub_agent_timeout` · `a worker past this is stopped; also called` · `tools` · `limits.tool_timeout` · `any other tool call` · `agents` · `research.agent_timeout` · `then a partial note · also called` · `research.max_retries` · `each retry starts from the partial note` · `strongest first` · `1` · `research.retry_timeouts` · `off: the round keeps the partial note ·` · `default   120 s` · `type a value` · `step` · `reset to 120 s` · `this terminal` · `file` · `copy the key` · `go to Agents & limits` · `project.hooks.pre_tool_use[1].timeout` · `pre_tool_use · the hook is stopped` · `not what you meant? words like` · `,` · `or` · `search descriptions too` · `data` · `more` · `Enter edits in place · ↓ from the query goes …` · `writes to` · `· shared with the desktop app` · `move` · `edit` · `reset` · `go to its section` · `complete @filter` · `clear` · `settings · search`
- `text_primary` (tp): `Search` · `timeout` · `7` · `Sub-agent time limit` · `The time every shell command an agent runs` · `gets at least; a tool call may ask for more,` · `never for less. Past its limit the command` · `and its process tree are stopped.` · `Tool` · `180 s` · `Seconds an agent may take` · `Retries after a` · `Retry timed-out agents` · `› global    180 s` · `Hook` · `· mix format` · `global`
- `key (info bold)` (ky): `Esc` · `Enter` · `←→` · `r` · `y` · `g` · `↑↓` · `Tab`
- `text_muted (label)` (tm): `/` · `@modified  @env  @project  @session  @shared …` · `Agents & limits` · `30 min` · `120 s` · `Search & research` · `value` · `default` · `range` · `1 – 600 s · step 5 s, Shift ×10` · `600 s` · `applies` · `to commands started from now` · `shared` · `with the desktop app` · `1` · `where it comes from` · `Project file` · `[✓] on` · `Project file · ailogic` · `10 s` · `project` · `wait` · `limit` · `seconds`
- `focus` (fo): `▏`
- `text_ghost` (tg): `─────────────────────────────────────────────…` · `Overview` · `│` · `Models & effort` · `Providers` · `Pricing` · `MCP servers` · `Language servers` · `Approvals & trust` · `Memory` · `Library` · `Appearance` · `Layout & transcript` · `Keys & input` · `Notifications` · `Session & startup` · `Storage` · `Budget & usage` · `Desktop app` · `Files & environment` · `Import & export`
- `focus on selection` (fo+se): `▌`
- `text_muted (label) on selection` (tm+se): `•` · `global`
- `text_primary on selection` (tp+se): `Command` · `180 s`
- `title / emphasis (text_primary bold) on selection` (tb+se): `timeout`
- `text_faint on selection` (tf+se): `limits.command_timeout` · `the least any shell command gets; a call may …`
- `success` (ok): `✓`

**Notes**

- Search covers labels, keys (`limits.command_timeout`), the stored column name (`command_timeout_ms`), descriptions, synonyms, record names (providers, servers, models, key actions) and the displayed value. It never covers secret values.
- `@` filters combine with words: `@modified timeout`, `@env`, `@project`, `@session`, `@shared`, `@cli`, `@secret`, `@attention`, `@restart`, `@section:mcp`.
- Esc clears the query; a second Esc leaves search with the focused row kept.
- Ranking: exact key > label prefix > label word > synonym > description > value; ties in rail order. Fuzzy (subsequence) matches only when nothing matches by word.

---

## F3

### F3 · Models & effort · provenance for the focused value · 160 × 45

The conversation's effort was just raised with ←→. The detail pane stacks every layer that could supply the value, strongest first; `›` and ✓ mark the one that wins; a layer it shadows keeps its value in text_muted.

```text
 Settings › Models & effort                                                                                                                    Esc back to chat 
 / search 212 settings, providers, servers and keys                                                   • 14 changed from default  ! 3 need attention  2 from env 
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  Overview                │  defaults for new conversations                        shared with the desktop app │ Effort · this conversation                     
                          │ • Chat model                    deepseek-v4-pro · DeepSeek                  global │ session.effort · /effort                       
  models                  │ • Sub-agent model               deepseek-v4-flash · DeepSeek                global │                                                
▌  Models & effort     •4 │   Scheduled task model          same as the chat model                     default │ How hard the model thinks before it answers.   
   Providers            4 │   Workflow model                same as the chat model                     default │ Higher levels take longer and cost more. The   
   Pricing             !2 │ • Implementer model             claude-opus-5 · Anthropic                   global │ levels are the chat model's provider's own:    
                          │   ▸ Fetch every provider's models     last run 2 h ago · 4 providers     f runs it │ Providers › DeepSeek › Effort levels says      
  tools                   │                                                                                    │ what each one adds to the request.             
   Search & research   •2 │  effort for new conversations         each provider maps a level to its API fields │                                                
   MCP servers         !1 │   Default effort                medium                                     default │ levels    off · high · max (DeepSeek V4)       
   Language servers       │   Sub-agent effort              medium                                     default │ applies   from the next turn; a turn that      
                          │   Scheduled effort              same as the default effort                 default │           is running keeps its level           
  agents                  │   Workflow effort               same as the default effort                 default │ scope     this conversation, until /new        
   Agents & limits     •2 │   Implementer effort            same as the default effort                 default │                                                
   Approvals & trust   •1 │                                                                                    │ where it comes from        strongest first     
   Project file           │  this conversation · 4f2a            until /new · /model and /effort set these too │   env           SWARM_EFFORT not set           
   Memory                 │   Model                         deepseek-v4-pro · DeepSeek            flag --model │ › session       high     18:22 here       ✓    
   Library                │▌• Effort                         off  [high]  max   DeepSeek's levels      session │   global        medium   default effort        
                          │   Sub-agent model               the default: deepseek-v4-flash             default │   project file  medium   only fills a gap      
  this terminal           │   Sub-agent effort              the default: medium                        default │   default       medium                         
   Appearance          •1 │                                                                                    │                                                
   Layout & transcript •2 │  this project's file · ailogic/.swarm_code/config.json                  e opens it │ Enter and ←→ write to this conversation        
   Keys & input        •1 │   effort                        medium               shadowed: the global row wins │ S writes the global default or this            
   Notifications          │   swarm_effort                  not set                                            │   project's file instead                       
   Session & startup      │   model                         not set                                            │ r removes the session value; the               
                          │   swarm_model                   not set                                            │   global medium takes over                     
  data                    │   profiles                      2 · fast, careful                       Enter open │                                                
   Storage                │                                                                                    │                                                
   Budget & usage      •1 │  from the environment                                each one wins while it is set │                                                
                          │   SWARM_MODEL                   not set                                            │                                                
  more                    │   SWARM_MODEL_OVERRIDE          not set                                            │                                                
   Desktop app            │   SWARM_EFFORT                  not set                                            │                                                
   Files & environment    │   SWARM_PROVIDER, SWARM_BASE_URL    not set                                        │                                                
   Import & export        │                                                                                    │                                                
                          │                                                                                    │                                                
                          │                                                                                    │                                                
                          │                                                                                    │                                                
                          │                                                                                    │                                                
                          │                                                                                    │                                                
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 ✓ Effort medium → high for this conversation · u undo                                                            writes to this conversation · S changes where 
 ←→ choose   Enter pick from a list   S write where   r reset   / search   [ ] section   ? keys                                                        settings 
```

**Roles**

- `title / emphasis (text_primary bold)` (tb): `Settings` · `Effort` · `Models & effort`
- `text_faint` (tf): `›` · `back to chat` · `14 changed from default` · `3 need attention` · `2 from env` · `shared with the desktop app` · `· this conversation` · `· DeepSeek` · `session.effort · /effort` · `models` · `▌` · `default` · `4` · `· Anthropic` · `last run 2 h ago · 4 providers` · `runs it` · `tools` · `each provider maps a level to its API fields` · `agents` · `strongest first` · `until /new · /model and /effort set these too` · `SWARM_EFFORT not set` · `--model` · `18:22 here` · `default effort` · `only fills a gap` · `this terminal` · `default       medium` · `opens it` · `shadowed: the global row wins` · `writes the global default or this` · `project's file instead` · `removes the session value; the` · `global medium takes over` · `data` · `open` · `each one wins while it is set` · `more` · `·` · `undo` · `writes to` · `changes where` · `choose` · `pick from a list` · `write where` · `reset` · `search` · `section` · `keys` · `settings`
- `text_primary` (tp): `Models & effort` · `Chat model` · `deepseek-v4-pro` · `Sub-agent model` · `deepseek-v4-flash` · `Scheduled task model` · `How hard the model thinks before it answers.` · `Workflow model` · `Higher levels take longer and cost more. The` · `Implementer model` · `claude-opus-5` · `levels are the chat model's provider's own:` · `Fetch every provider's models` · `Providers › DeepSeek › Effort levels says` · `what each one adds to the request.` · `Default effort` · `Sub-agent effort` · `Scheduled effort` · `Workflow effort` · `Implementer effort` · `Model` · `› session       high` · `this conversation` · `Effort`
- `key (info bold)` (ky): `Esc` · `f` · `e` · `S` · `r` · `Enter` · `u` · `←→` · `/` · `[ ]` · `?`
- `text_muted (label)` (tm): `/` · `•` · `Overview` · `defaults for new conversations` · `global` · `•4` · `same as the chat model` · `Providers` · `Pricing` · `▸` · `Search & research` · `•2` · `effort for new conversations` · `MCP servers` · `medium` · `levels` · `off · high · max (DeepSeek V4)` · `Language servers` · `applies` · `from the next turn; a turn that` · `same as the default effort` · `is running keeps its level` · `scope` · `this conversation, until /new` · `Agents & limits` · `Approvals & trust` · `•1` · `where it comes from` · `Project file` · `this conversation · 4f2a` · `env` · `Memory` · `flag` · `Library` · `global        medium` · `the default: deepseek-v4-flash` · `project file  medium` · `the default: medium` · `Appearance` · `Layout & transcript` · `this project's file · ailogic/.swarm_code/con…` · `Enter and ←→ write to` · `Keys & input` · `effort` · `Notifications` · `swarm_effort` · `Session & startup` · `model` · `swarm_model` · `profiles` · `2 · fast, careful` · `Storage` · `Budget & usage` · `from the environment` · `SWARM_MODEL` · `SWARM_MODEL_OVERRIDE` · `Desktop app` · `SWARM_EFFORT` · `Files & environment` · `SWARM_PROVIDER, SWARM_BASE_URL` … +2 more
- `text_ghost` (tg): `search 212 settings, providers, servers and k…` · `─────────────────────────────────────────────…` · `│` · `not set`
- `warning` (wa): `!` · `!2` · `!1`
- `success` (ok): `✓`
- `focus on selection` (fo+se): `▌`
- `text_muted (label) on selection` (tm+se): `•` · `off` · `max` · `session`
- `text_primary on selection` (tp+se): `Effort`
- `title / emphasis (text_primary bold) on selection` (tb+se): `[high]`
- `text_faint on selection` (tf+se): `DeepSeek's levels`

**Notes**

- The row's own tag names only the winning layer. A value that differs from its default reads in text_primary; a default reads in text_muted.
- `S` opens the write-target chooser for this field: this conversation, this project's file, or the global default. The footer always says where Enter will write.
- Rows from the environment are read-only; they show `not set` in text_ghost when absent so the user learns the variable exists.
- The toast on the status row is the only confirmation of an instant change; `u` undoes it.

---

## F4

### F4 · Model picker · fetched models, grouped by provider · 160 × 45

Enter on *Chat model*. The picker is a popover in the /approval picker's style: title in the top border, the query row, provider groups with their fetch state, and the key row inside the frame. Anthropic is fetching as the picker opens; Local Ollama failed.

```text
 Settings › Models & effort › Chat model                                                                                                       Esc back to chat 
 / search 212 settings, providers, servers and keys                                                   • 14 changed from default  ! 3 need attention  2 from env 
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  Overview                │  defaults for new conversations                        shared with the desktop app │                                                
                          │▌• Chat model                    deepseek-v4-pro · DeepSeek                  global │                                                
  models                  │ • Sub-agent model               deepseek-v4-flash · DeepSeek                global │                                                
▌  Models & effort     •4 │   ┌─ Chat model · new conversations ──────────────────────────────────────────────────────────── 4 providers · 23 models ─┐         
   Providers            4 │   │ / type to filter · provider/model works too                                                                           │         
   Pricing             !2 │ • │                                                                                                                       │         
                          │   │     model                           context   $ per M tokens · in · out     can                                       │         
  tools                   │   │ DeepSeek  OpenAI-compatible · fetched 2 h ago                                                               f refetch │         
   Search & research   •2 │  e│▌  ✓ deepseek-v4-pro                    128k   0.55 · 2.19                   thinking · effort                 current │         
   MCP servers         !1 │   │     deepseek-v4-flash                  128k   0.07 · 0.28                   effort                                    │         
   Language servers       │   │     deepseek-coder-v3                   64k   no price                                                                │         
                          │   │     deepseek-r2                        128k   0.55 · 2.19                   thinking            not in the last fetch │         
  agents                  │   │                                                                                                                       │         
   Agents & limits     •2 │   │ Anthropic  ◷ fetching the model list · 1 s                                                                Esc cancels │         
   Approvals & trust   •1 │   │     claude-opus-5                      200k   15.00 · 75.00                 thinking · effort                         │         
   Project file           │  t│     claude-sonnet-5                    200k   no price                      thinking · effort                         │         
   Memory                 │   │     claude-haiku-5                     200k   1.00 · 5.00                   effort                                    │         
   Library                │ • │                                                                                                                       │         
                          │   │ llmotions  OpenAI-compatible · fetched yesterday                                                                      │         
  this terminal           │   │     gpt-5                              400k   1.25 · 10.00                  effort                                    │         
   Appearance          •1 │   │     … 11 more, type to filter                                                                                         │         
   Layout & transcript •2 │  t│                                                                                                                       │         
   Keys & input        •1 │   │ Local Ollama  ✗ not reachable: connection refused · localhost:11434                                       t try again │         
   Notifications          │   │     qwen3-coder                         32k   no price                                            from the saved list │         
   Session & startup      │   │                                                                                                                       │         
                          │   │───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────│         
  data                    │   │ Enter choose   Tab next provider   f fetch all   p set a price   Esc close                                    1 of 23 │         
   Storage                │   └───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘         
   Budget & usage      •1 │  from the environment                                each one wins while it is set │                                                
                          │   SWARM_MODEL                   not set                                            │                                                
  more                    │   SWARM_MODEL_OVERRIDE          not set                                            │                                                
   Desktop app            │   SWARM_EFFORT                  not set                                            │                                                
   Files & environment    │   SWARM_PROVIDER, SWARM_BASE_URL    not set                                        │                                                
   Import & export        │                                                                                    │                                                
                          │                                                                                    │                                                
                          │                                                                                    │                                                
                          │                                                                                    │                                                
                          │                                                                                    │                                                
                          │                                                                                    │                                                
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 the picker lists 23 models from 4 providers · a pick writes the global default                                  writes to global · shared with the desktop app 
 ↑↓ move   Enter choose   Tab next provider   f fetch all   p set a price   Esc close                                                         settings · picker 
```

**Roles**

- `title / emphasis (text_primary bold)` (tb): `Settings` · `Models & effort`
- `text_faint` (tf): `›` · `back to chat` · `14 changed from default` · `3 need attention` · `2 from env` · `shared with the desktop app` · `models` · `· DeepSeek` · `▌` · `4` · `tools` · `agents` · `this terminal` · `data` · `each one wins while it is set` · `more` · `the picker lists 23 models from 4 providers ·…` · `writes to` · `· shared with the desktop app` · `move` · `choose` · `next provider` · `fetch all` · `set a price` · `close` · `settings · picker`
- `text_muted (label)` (tm): `Models & effort` · `/` · `•` · `Overview` · `defaults for new conversations` · `global` · `•4` · `Providers` · `Pricing` · `Search & research` · `•2` · `e` · `MCP servers` · `Language servers` · `Agents & limits` · `Approvals & trust` · `•1` · `Project file` · `t` · `Memory` · `Library` · `Appearance` · `Layout & transcript` · `Keys & input` · `Notifications` · `Session & startup` · `Storage` · `Budget & usage` · `from the environment` · `SWARM_MODEL` · `SWARM_MODEL_OVERRIDE` · `Desktop app` · `SWARM_EFFORT` · `Files & environment` · `SWARM_PROVIDER, SWARM_BASE_URL` · `Import & export`
- `text_primary` (tp): `Chat model` · `Sub-agent model` · `deepseek-v4-flash` · `global`
- `key (info bold)` (ky): `Esc` · `↑↓` · `Enter` · `Tab` · `f` · `p`
- `text_ghost` (tg): `search 212 settings, providers, servers and k…` · `─────────────────────────────────────────────…` · `│` · `not set`
- `warning` (wa): `!` · `!2` · `!1`
- `focus on selection` (fo+se): `▌`
- `text_muted (label) on selection` (tm+se): `•` · `global` · `128k` · `0.55 · 2.19` · `thinking · effort`
- `text_primary on selection` (tp+se): `Chat model` · `deepseek-v4-pro`
- `text_faint on selection` (tf+se): `· DeepSeek` · `current`
- `text_ghost on popover` (tg+po): `┌─` · `─────────────────────────────────────────────…` · `─┐` · `│` · `type to filter · provider/model works too` · `│────────────────────────────────────────────…` · `└────────────────────────────────────────────…`
- `title / emphasis (text_primary bold) on popover` (tb+po): `Chat model`
- `text_faint on popover` (tf+po): `· new conversations` · `4 providers · 23 models` · `model` · `context` · `$ per M tokens · in · out` · `can` · `OpenAI-compatible · fetched 2 h ago` · `refetch` · `not in the last fetch` · `cancels` · `OpenAI-compatible · fetched yesterday` · `… 11 more, type to filter` · `try again` · `from the saved list` · `choose` · `next provider` · `fetch all` · `set a price` · `close` · `1 of 23`
- `text_muted (label) on popover` (tm+po): `/` · `DeepSeek` · `128k` · `0.07 · 0.28` · `effort` · `64k` · `0.55 · 2.19` · `thinking` · `Anthropic` · `fetching the model list · 1 s` · `200k` · `15.00 · 75.00` · `thinking · effort` · `1.00 · 5.00` · `llmotions` · `400k` · `1.25 · 10.00` · `Local Ollama` · `not reachable: connection refused · localhost…` · `32k`
- `key (info bold) on popover` (ky+po): `f` · `Esc` · `t` · `Enter` · `Tab` · `p`
- `success on selection` (ok+se): `✓`
- `text_primary on popover` (tp+po): `deepseek-v4-flash` · `deepseek-coder-v3` · `deepseek-r2` · `claude-opus-5` · `claude-sonnet-5` · `claude-haiku-5` · `gpt-5` · `qwen3-coder`
- `warning on popover` (wa+po): `no price`
- `info on popover` (in+po): `◷`
- `error on popover` (er+po): `✗`

**Notes**

- Every number is real or absent: context and prices come from Pricing, `no price` in warning when the model has no row; capabilities come from the provider's model caps.
- A model that the last fetch no longer lists stays pickable and says so.
- A query that matches nothing offers `use “<query>” with <provider> as typed`, marked *not in its list*.
- Fetching is owned work of the picker: Esc cancels it; results arriving after close are dropped. `f` refetches every provider, `Tab` jumps to the next provider group.

---

## F5

### F5 · Providers › DeepSeek · a secret, a test, the models · 160 × 45

A provider page (drill-down from the Providers list). The key is a secret: its row says only *set* and where it is stored. The connection test is a real request whose result stays on its row with the time it ran. An approval is waiting elsewhere, so the header carries the needs-you chip.

```text
 Settings › Providers › DeepSeek                                                     ! 1 needs you · deps-agent wants to run a command · ^N    Esc back to chat 
 / search 212 settings, providers, servers and keys                                                   • 14 changed from default  ! 3 need attention  2 from env 
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  Overview                │  DeepSeek  OpenAI-compatible · global · 12 conversations use it   ✓ answered 18:42 │ API key · DeepSeek                             
                          │                                                                                    │ providers.deepseek.api_key · secret            
  models                  │  connection                                                                        │                                                
   Models & effort     •4 │   Name                          DeepSeek                                    global │ The key SwarmCode sends to api.deepseek.com    
▌  Providers            4 │   Kind                           Anthropic  [OpenAI-compatible]             global │ with each request of this provider. It is never
   Pricing             !2 │   Base URL                      https://api.deepseek.com/v1                 global │ shown again, never written to a log, never in  
                          │▌  API key                       ●●●●●●●● set · macOS Keychain               global │ search results and never kept for undo.        
  tools                   │   ▸ Test connection             ✓ listed 6 models in 412 ms · 18:42              t │                                                
   Search & research   •2 │                                                                                    │ state     set                                  
   MCP servers         !1 │  models                                                                            │ stored    macOS Keychain                       
   Language servers       │   Default model                 deepseek-v4-pro                             global │ sent to   api.deepseek.com only                
                          │   Models                        6 · fetched 2 h ago            Enter edit the list │ shared    with the desktop app                 
  agents                  │     deepseek-v4-pro  deepseek-v4-flash  deepseek-coder-v3  deepseek-r2  +2         │                                                
   Agents & limits     •2 │   ▸ Fetch models                shows the difference before it changes the list  f │ where it comes from        strongest first     
   Approvals & trust   •1 │   Effort levels                 DeepSeek V4 preset · 3 levels           Enter open │   env       SWARM_API_KEY not set              
   Project file           │                                                                                    │ › global    set      Keychain             ✓    
   Memory                 │  used by                                                                           │                                                
   Library                │   the chat default · the sub-agent default · 12 conversations · 2 scheduled tasks  │ Enter  paste a new key                         
                          │                                                                                    │ x      remove the key · asks first             
  this terminal           │  danger                                                                            │ t      test the connection                     
   Appearance          •1 │   ▸ Delete this provider…       asks first and shows what uses it                D │                                                
   Layout & transcript •2 │                                                                                    │                                                
   Keys & input        •1 │                                                                                    │                                                
   Notifications          │                                                                                    │                                                
   Session & startup      │                                                                                    │                                                
                          │                                                                                    │                                                
  data                    │                                                                                    │                                                
   Storage                │                                                                                    │                                                
   Budget & usage      •1 │                                                                                    │                                                
                          │                                                                                    │                                                
  more                    │                                                                                    │                                                
   Desktop app            │                                                                                    │                                                
   Files & environment    │                                                                                    │                                                
   Import & export        │                                                                                    │                                                
                          │                                                                                    │                                                
                          │                                                                                    │                                                
                          │                                                                                    │                                                
                          │                                                                                    │                                                
                          │                                                                                    │                                                
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 ✓ DeepSeek answered: 6 models listed in 412 ms                                                                  writes to global · shared with the desktop app 
 ↑↓ move   Enter paste a new key   t test   f fetch models   x remove the key   h back to Providers   ? keys                                           settings 
```

**Roles**

- `title / emphasis (text_primary bold)` (tb): `Settings` · `DeepSeek` · `API key` · `Providers` · `[OpenAI-compatible]`
- `text_faint` (tf): `›` · `· deps-agent wants to run a command ·` · `back to chat` · `14 changed from default` · `3 need attention` · `2 from env` · `OpenAI-compatible · global · 12 conversations…` · `· DeepSeek` · `providers.deepseek.api_key · secret` · `models` · `▌` · `4` · `tools` · `· fetched 2 h ago` · `edit the list` · `agents` · `shows the difference before it changes the li…` · `strongest first` · `open` · `SWARM_API_KEY not set` · `Keychain` · `paste a new key` · `remove the key · asks first` · `this terminal` · `test the connection` · `asks first and shows what uses it` · `data` · `more` · `writes to` · `· shared with the desktop app` · `move` · `test` · `fetch models` · `remove the key` · `back to Providers` · `keys` · `settings`
- `text_muted (label)` (tm): `Providers` · `/` · `•` · `Overview` · `answered 18:42` · `connection` · `Models & effort` · `•4` · `global` · `Anthropic` · `Pricing` · `▸` · `listed 6 models in 412 ms · 18:42` · `Search & research` · `•2` · `state` · `MCP servers` · `models` · `stored` · `macOS Keychain` · `Language servers` · `sent to` · `api.deepseek.com only` · `shared` · `with the desktop app` · `deepseek-v4-pro  deepseek-v4-flash  deepseek-…` · `Agents & limits` · `where it comes from` · `Approvals & trust` · `•1` · `DeepSeek V4 preset · 3 levels` · `env` · `Project file` · `Memory` · `used by` · `Library` · `the chat default · the sub-agent default · 12…` · `danger` · `Appearance` · `Layout & transcript` · `Keys & input` · `Notifications` · `Session & startup` · `Storage` · `Budget & usage` · `Desktop app` · `Files & environment` · `Import & export` · `answered: 6 models listed in 412 ms`
- `text_primary` (tp): `DeepSeek` · `Name` · `The key SwarmCode sends to api.deepseek.com` · `Kind` · `with each request of this provider. It is nev…` · `Base URL` · `https://api.deepseek.com/v1` · `shown again, never written to a log, never in` · `search results and never kept for undo.` · `Test connection` · `set` · `Default model` · `deepseek-v4-pro` · `Models` · `6` · `Fetch models` · `Effort levels` · `› global    set` · `Delete this provider…` · `global`
- `warning` (wa): `! 1 needs you` · `!` · `!2` · `!1`
- `key (info bold)` (ky): `^N` · `Esc` · `t` · `Enter` · `f` · `x` · `D` · `↑↓` · `h` · `?`
- `text_ghost` (tg): `search 212 settings, providers, servers and k…` · `─────────────────────────────────────────────…` · `│`
- `success` (ok): `✓`
- `focus on selection` (fo+se): `▌`
- `text_primary on selection` (tp+se): `API key` · `set`
- `text_muted (label) on selection` (tm+se): `●●●●●●●●` · `global`
- `text_faint on selection` (tf+se): `· macOS Keychain`

**Notes**

- Existing records save field by field, like preferences. New records (a provider being added) are drafts until `Ctrl-S` creates them.
- The test lists models (GET /models or /v1/models); 412 ms is the time of that request and is labelled as such, never as a latency of the model.
- `^N` leaves settings for the waiting card; `/settings` comes back to this row.
- `D` on the danger row opens the delete confirmation (frame F12).

---

## F6

### F6 · Providers › DeepSeek · pasting a key, checking a fetch · 160 × 45

Enter on the key opened a paste target; a key was pasted and is held, undrawn, until Enter or Esc. `f` fetched the model list: the page shows the difference and changes nothing until `a` or `+`.

```text
 Settings › Providers › DeepSeek                                                                                                               Esc back to chat 
 / search 212 settings, providers, servers and keys                                                   • 14 changed from default  ! 3 need attention  2 from env 
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  Overview                │  DeepSeek  OpenAI-compatible · global · 12 conversations use it   ✓ answered 18:42 │ API key · pasting                              
                          │                                                                                    │ providers.deepseek.api_key · secret            
  models                  │  connection                                                                        │                                                
   Models & effort     •4 │   Name                          DeepSeek                                    global │ The pasted text is held here until Enter or    
▌  Providers            4 │   Kind                           Anthropic  [OpenAI-compatible]             global │ Esc and is cleared either way. It is not       
   Pricing             !2 │   Base URL                      https://api.deepseek.com/v1                 global │ drawn, not kept for undo and not searchable.   
                          │▌  API key                       ▏●●●●●●●● pasted · 1 line · not shown    not saved │                                                
  tools                   │                                 Enter save and test   Esc throw it away            │ checks                                         
   Search & research   •2 │                                 typing is ignored here · paste with Cmd-V          │   ✓ one line, no spaces inside                 
   MCP servers         !1 │                                                                                    │   ✓ looks like a DeepSeek key                  
   Language servers       │  models                                                                            │   ○ the connection test runs after saving      
                          │   Default model                 deepseek-v4-pro                             global │                                                
  agents                  │   Models                        6 → 7 after this fetch                 not applied │ on Enter                                       
   Agents & limits     •2 │   ▸ Fetch models                ✓ 7 models from api.deepseek.com · 380 ms        f │   the old key is replaced in the Keychain,     
   Approvals & trust   •1 │     + deepseek-v4-pro-0925      new                                                │   the test runs, and the row shows its result  
   Project file           │     + deepseek-embed-2          new                                                │                                                
   Memory                 │     − deepseek-r2               not listed any more · 3 conversations use it       │ this terminal marks pastes (bracketed paste).  
   Library                │       5 unchanged                                                                  │ Where it does not, typing is accepted and this 
                          │     a apply all   + add the new ones only   Esc keep the old list                  │ row says so.                                   
  this terminal           │   Effort levels                 DeepSeek V4 preset · 3 levels           Enter open │                                                
   Appearance          •1 │                                                                                    │                                                
   Layout & transcript •2 │  used by                                                                           │                                                
   Keys & input        •1 │   the chat default · the sub-agent default · 12 conversations · 2 scheduled tasks  │                                                
   Notifications          │                                                                                    │                                                
   Session & startup      │  danger                                                                            │                                                
                          │   ▸ Delete this provider…       asks first and shows what uses it                D │                                                
  data                    │                                                                                    │                                                
   Storage                │                                                                                    │                                                
   Budget & usage      •1 │                                                                                    │                                                
                          │                                                                                    │                                                
  more                    │                                                                                    │                                                
   Desktop app            │                                                                                    │                                                
   Files & environment    │                                                                                    │                                                
   Import & export        │                                                                                    │                                                
                          │                                                                                    │                                                
                          │                                                                                    │                                                
                          │                                                                                    │                                                
                          │                                                                                    │                                                
                          │                                                                                    │                                                
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 ! 2 things wait on this page: the pasted key and the fetched list                                               writes to global · shared with the desktop app 
 Enter save the key   Esc throw it away   a apply the list   + add new models only   ? keys                                                   settings · secret 
```

**Roles**

- `title / emphasis (text_primary bold)` (tb): `Settings` · `DeepSeek` · `API key` · `Providers` · `[OpenAI-compatible]`
- `text_faint` (tf): `›` · `back to chat` · `14 changed from default` · `3 need attention` · `2 from env` · `OpenAI-compatible · global · 12 conversations…` · `· pasting` · `providers.deepseek.api_key · secret` · `models` · `▌` · `4` · `tools` · `typing is ignored here · paste with Cmd-V` · `○ the connection test runs after saving` · `agents` · `after this fetch` · `new` · `not listed any more · 3 conversations use it` · `5 unchanged` · `Where it does not, typing is accepted and this` · `apply all` · `add the new ones only` · `keep the old list` · `row says so.` · `this terminal` · `open` · `asks first and shows what uses it` · `data` · `more` · `writes to` · `· shared with the desktop app` · `save the key` · `throw it away` · `apply the list` · `add new models only` · `keys` · `settings · secret`
- `text_muted (label)` (tm): `Providers` · `/` · `•` · `Overview` · `answered 18:42` · `connection` · `Models & effort` · `•4` · `global` · `Anthropic` · `Pricing` · `checks` · `Search & research` · `•2` · `one line, no spaces inside` · `MCP servers` · `looks like a DeepSeek key` · `Language servers` · `models` · `on Enter` · `Agents & limits` · `▸` · `7 models from api.deepseek.com · 380 ms` · `the old key is replaced in the Keychain,` · `Approvals & trust` · `•1` · `the test runs, and the row shows its result` · `Project file` · `Memory` · `this terminal marks pastes (bracketed paste).` · `Library` · `DeepSeek V4 preset · 3 levels` · `Appearance` · `Layout & transcript` · `used by` · `Keys & input` · `the chat default · the sub-agent default · 12…` · `Notifications` · `Session & startup` · `danger` · `Storage` · `Budget & usage` · `Desktop app` · `Files & environment` · `Import & export` · `2 things wait on this page: the pasted key an…`
- `text_primary` (tp): `DeepSeek` · `Name` · `The pasted text is held here until Enter or` · `Kind` · `Esc and is cleared either way. It is not` · `Base URL` · `https://api.deepseek.com/v1` · `drawn, not kept for undo and not searchable.` · `Default model` · `deepseek-v4-pro` · `Models` · `6 → 7` · `Fetch models` · `deepseek-v4-pro-0925` · `deepseek-embed-2` · `deepseek-r2` · `Effort levels` · `Delete this provider…` · `global`
- `key (info bold)` (ky): `Esc` · `f` · `a` · `+` · `Enter` · `D` · `?`
- `text_ghost` (tg): `search 212 settings, providers, servers and k…` · `─────────────────────────────────────────────…` · `│`
- `warning` (wa): `!` · `!2` · `!1` · `not applied`
- `success` (ok): `✓` · `+`
- `focus on selection` (fo+se): `▌` · `▏`
- `text_primary on selection` (tp+se): `API key` · `pasted`
- `text_muted (label) on selection` (tm+se): `●●●●●●●●`
- `text_faint on selection` (tf+se): `· 1 line · not shown` · `save and test` · `throw it away`
- `warning on selection` (wa+se): `not saved`
- `key (info bold) on selection` (ky+se): `Enter` · `Esc`
- `error` (er): `−`

**Notes**

- The pasted secret lives only in the paste target; Enter hands it to the secret store and clears it, Esc clears it. It never enters the undo stack, a toast, the log or the search index.
- Soft checks run on the pasted text before saving: one line, no inner spaces, the shape the provider's keys usually have. A failed shape check warns; it does not block.
- A model that disappears from the provider's list but is used by conversations is flagged, never silently removed.
- Two things wait for the user on this page, so the status row counts them; leaving the page with them open asks first (discard the pasted key, keep the old list).

---

## F7

### F7 · Search & research · ordered providers, a stepped number, lists · 160 × 45

The search providers are an ordered list of toggles (J/K move a row, Space switches it). The focused number is being stepped with ←→: the value updates at once and is written when stepping pauses; the slider shows the value over its range, which is a known ratio.

```text
 Settings › Search & research                                                                                                                  Esc back to chat 
 / search 212 settings, providers, servers and keys                                                   • 14 changed from default  ! 3 need attention  2 from env 
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  Overview                │  search providers                    tried in this order · J K move · Space on/off │ Agents in flight at once                       
                          │   1 [✓] Tavily        key ●●●●●●●● set                            ✓ searched 18:30 │ research.max_live · research_max_live          
  models                  │   2 [✓] Exa           key ●●●●●●●● set                                never tested │                                                
   Models & effort     •4 │   3 [ ] Brave         no key                                                       │ How many research agents run at the same       
   Providers            4 │   4 [ ] Serper        no key                                                       │ time in one research. Research has its own     
   Pricing             !2 │   5 [ ] Firecrawl     no key · can also read pages                                 │ cap: Max concurrent agents (6, per run) does   
                          │   6 [ ] Jina          no key · reads pages without one, rate limited               │ not apply to it.                               
  tools                   │                                                                                    │                                                
▌  Search & research   •2 │  reading pages                          every agent's web_fetch, not only research │ value     12                                   
   MCP servers         !1 │   Page reader                   [web_fetch]  Jina   Firecrawl              default │ default   10                                   
   Language servers       │                                                                                    │ range     1 – 32 · step 1 · Shift ×5           
                          │  depth                                                                             │ applies   from the next round                  
  agents                  │   Default level                  Fastest  [medium]  high   ultra           default │ shared    with the desktop app                 
   Agents & limits     •2 │                                 median here: Fastest 50 s · medium 6 min 40        │                                                
   Approvals & trust   •1 │                                                                                    │ where it comes from        strongest first     
   Project file           │  limits                                                                            │ › global    12                             ✓   
   Memory                 │▌• Agents in flight at once      ‹ 12 ›  1–32  ▰▰▰▰▰▰▱▱▱▱▱▱▱▱▱▱              global │   default   10                                 
   Library                │   Pages each agent must read    5  1–20                                    default │                                                
                          │   Only sources newer than       any age  days · blank = any                default │ typing                                         
  this terminal           │   Seconds an agent may take     600 s  60–3600                             default │   a digit starts a typed value; Enter keeps    
   Appearance          •1 │   Retries after a timeout       1  0–3                                     default │   it, Esc goes back to 12. Outside 1–32 the    
   Layout & transcript •2 │   Retry timed-out agents        [✓] on                                     default │   row says so and Enter does nothing.          
   Keys & input        •1 │   A headline per round          [✓] on                                     default │                                                
   Notifications          │                                                                                    │                                                
   Session & startup      │  report                                                                            │                                                
                          │   Designed HTML report          [after deep]  after every one   on request default │                                                
  data                    │                                                                                    │                                                
   Storage                │  domains                                                                           │                                                
   Budget & usage      •1 │   Only these domains            any domain                                   a add │                                                
                          │ • Never these domains           pinterest.com · quora.com                   global │                                                
  more                    │                                                                                    │                                                
   Desktop app            │  models per tier                                                                   │                                                
   Files & environment    │   Lead                          the chat model · medium                    default │                                                
   Import & export        │   Workers                       the sub-agent model · medium               default │                                                
                          │   Reporter                      the lead's model · medium                  default │                                                
                          │                                                                                    │                                                
                          │  where reports are kept                                                            │                                                
                          │   Research folder               ~/.swarmcode/research                     o reveal │                                                
                          │                                                                                    │                                                
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 Agents in flight at once 10 → 12 · written when you stop stepping · u undo                                      writes to global · shared with the desktop app 
 ←→ step   Shift-←→ ×5   0-9 type   Space switch   J K reorder   Enter open   r reset   ? keys                                                         settings 
```

**Roles**

- `title / emphasis (text_primary bold)` (tb): `Settings` · `Agents in flight at once` · `Search & research` · `[web_fetch]` · `[medium]` · `[after deep]`
- `text_faint` (tf): `›` · `back to chat` · `14 changed from default` · `3 need attention` · `2 from env` · `tried in this order ·` · `move ·` · `on/off` · `1` · `research.max_live · research_max_live` · `models` · `2` · `never tested` · `3` · `no key` · `4` · `5` · `no key · can also read pages` · `6` · `no key · reads pages without one, rate limited` · `tools` · `▌` · `every agent's web_fetch, not only research` · `default` · `agents` · `median here: Fastest 50 s · medium 6 min 40` · `strongest first` · `default   10` · `1–20` · `days · blank = any` · `this terminal` · `60–3600` · `a digit starts a typed value; Enter keeps` · `0–3` · `it, Esc goes back to 12. Outside 1–32 the` · `row says so and Enter does nothing.` · `data` · `add` · `more` · `reveal` · `· written when you stop stepping ·` · `undo` · `writes to` · `· shared with the desktop app` · `step` · `×5` · `type` · `switch` · `reorder` · `open` · `reset` · `keys` · `settings`
- `text_primary` (tp): `Search & research` · `[✓] Tavily` · `[✓] Exa` · `How many research agents run at the same` · `time in one research. Research has its own` · `cap: Max concurrent agents (6, per run) does` · `not apply to it.` · `12` · `Page reader` · `Default level` · `› global    12` · `Pages each agent must read` · `Only sources newer than` · `Seconds an agent may take` · `Retries after a timeout` · `Retry timed-out agents` · `A headline per round` · `Designed HTML report` · `Only these domains` · `Never these domains` · `pinterest.com · quora.com` · `Lead` · `Workers` · `Reporter` · `Research folder` · `Agents in flight at once` · `global`
- `key (info bold)` (ky): `Esc` · `J K` · `Space` · `a` · `o` · `u` · `←→` · `Shift-←→` · `0-9` · `Enter` · `r` · `?`
- `text_muted (label)` (tm): `/` · `•` · `Overview` · `search providers` · `key ●●●●●●●● set` · `searched 18:30` · `Models & effort` · `•4` · `[ ] Brave` · `Providers` · `[ ] Serper` · `Pricing` · `[ ] Firecrawl` · `[ ] Jina` · `•2` · `reading pages` · `value` · `MCP servers` · `Jina` · `Firecrawl` · `default` · `10` · `Language servers` · `range` · `1 – 32 · step 1 · Shift ×5` · `depth` · `applies` · `from the next round` · `Fastest` · `high` · `ultra` · `shared` · `with the desktop app` · `Agents & limits` · `Approvals & trust` · `•1` · `where it comes from` · `Project file` · `limits` · `Memory` · `Library` · `5` · `any age` · `typing` · `600 s` · `Appearance` · `1` · `Layout & transcript` · `[✓] on` · `Keys & input` · `Notifications` · `Session & startup` · `report` · `after every one` · `on request` · `Storage` · `domains` · `Budget & usage` · `global` · `Desktop app` … +9 more
- `text_ghost` (tg): `search 212 settings, providers, servers and k…` · `─────────────────────────────────────────────…` · `│` · `any domain`
- `warning` (wa): `!` · `!2` · `!1`
- `success` (ok): `✓`
- `focus on selection` (fo+se): `▌` · `‹`
- `text_muted (label) on selection` (tm+se): `•` · `▰▰▰▰▰▰` · `global`
- `text_primary on selection` (tp+se): `Agents in flight at once` · `›`
- `title / emphasis (text_primary bold) on selection` (tb+se): `12`
- `text_faint on selection` (tf+se): `1–32`
- `text_ghost on selection` (tg+se): `▱▱▱▱▱▱▱▱▱▱`

**Notes**

- Order matters: web_search tries the enabled providers top to bottom; the first answer wins.
- A provider row opens a sub-page: key (secret), base URL, a test search that says it spends one search from the provider's quota before it runs.
- The level picker shows each level's median time to the answer from this machine's own runs, or *not measured yet*; never an estimate.
- Domain lists are list editors: `a` adds, `x` removes (undoable), duplicates and malformed names are refused inline.

---

## F8

### F8 · MCP servers › github · key-value with secrets, tools, a restart in flight · 160 × 45

The command was just corrected. Connection fields save as they are edited and the server restarts once, when the user leaves the page or presses `r`; here the restart is in flight. Environment values whose names look like credentials are secrets: masked, paste-only, never drawn.

```text
 Settings › MCP servers › github                                                                                                               Esc back to chat 
 / search 212 settings, providers, servers and keys                                                   • 14 changed from default  ! 3 need attention  2 from env 
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  Overview                │  github  MCP server · stdio · every project                         ✗ failed 18:41 │ Command · github                               
                          │  ◷ restarting with the new command · 2 s                          Esc stop waiting │ mcp.github.command                             
  models                  │                                                                                    │                                                
   Models & effort     •4 │  server                                                                            │ The program SwarmCode starts for this server.  
   Providers            4 │   Name                          github                                      global │ It speaks MCP on its stdin and stdout. A name  
   Pricing             !2 │   Enabled                       [✓] on                                     default │ without a slash is looked up on PATH.          
                          │   Scope                         [every project]  ailogic only               global │                                                
  tools                   │   Transport                     [stdio]  http                               global │ checks                                         
   Search & research   •2 │▌• Command                       /opt/homebrew/bin/github-mcp-server         global │   ✓ the file exists                            
▌  MCP servers         !1 │   Arguments                     stdio                       one line, shell-quoted │   ✓ it is executable                           
   Language servers       │   Environment                   2 variables                             Enter edit │   ◷ the server answers MCP: waiting            
                          │       GITHUB_PERSONAL_ACCESS_TOKEN  ●●●●●●●● secret · set                          │                                                
  agents                  │       GITHUB_TOOLSETS               repos,issues,pull_requests                     │ applies   when the server restarts             
   Agents & limits     •2 │                                                                                    │ scope     every project                        
   Approvals & trust   •1 │  tools · from the last connection, 18:10                     41 · 3 off · / filter │                                                
   Project file           │   [✓] create_issue          [✓] get_issue             [✓] list_issues              │ where it comes from                            
   Memory                 │   [✓] create_pull_request   [✓] get_pull_request      [ ] merge_pull_request       │ › global    /opt/homebrew/bin/github-mcp-… ✓   
   Library                │   [ ] delete_repository     [ ] push_files            [✓] search_code              │                                                
                          │   … 32 more                                                                        │ Enter edit   Tab completes a path              
  this terminal           │                                                                                    │ r restart now   o the server's output          
   Appearance          •1 │  server output · last 2 lines                                          o all of it │                                                
   Layout & transcript •2 │   sh: github-mcp-server: command not found                                         │                                                
   Keys & input        •1 │   exited 127 after 0.1 s                                                           │                                                
   Notifications          │                                                                                    │                                                
   Session & startup      │  danger                                                                            │                                                
                          │   ▸ Delete this server…         asks first                                       D │                                                
  data                    │                                                                                    │                                                
   Storage                │                                                                                    │                                                
   Budget & usage      •1 │                                                                                    │                                                
                          │                                                                                    │                                                
  more                    │                                                                                    │                                                
   Desktop app            │                                                                                    │                                                
   Files & environment    │                                                                                    │                                                
   Import & export        │                                                                                    │                                                
                          │                                                                                    │                                                
                          │                                                                                    │                                                
                          │                                                                                    │                                                
                          │                                                                                    │                                                
                          │                                                                                    │                                                
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 ✓ Command saved · the server restarts with it                                                                   writes to global · shared with the desktop app 
 ↑↓ move   Enter edit   Tab complete a path   r restart now   o output   Space switch a tool   ? keys                                                  settings 
```

**Roles**

- `title / emphasis (text_primary bold)` (tb): `Settings` · `github` · `Command` · `[every project]` · `[stdio]` · `MCP servers`
- `text_faint` (tf): `›` · `back to chat` · `14 changed from default` · `3 need attention` · `2 from env` · `MCP server · stdio · every project` · `· github` · `stop waiting` · `mcp.github.command` · `models` · `4` · `default` · `tools` · `▌` · `one line, shell-quoted` · `edit` · `secret · set` · `agents` · `· 3 off ·` · `filter` · `… 32 more` · `completes a path` · `this terminal` · `restart now` · `the server's output` · `all of it` · `sh: github-mcp-server: command not found` · `exited 127 after 0.1 s` · `asks first` · `data` · `more` · `writes to` · `· shared with the desktop app` · `move` · `complete a path` · `output` · `switch a tool` · `keys` · `settings`
- `text_muted (label)` (tm): `MCP servers` · `/` · `•` · `Overview` · `failed 18:41` · `restarting with the new command · 2 s` · `Models & effort` · `•4` · `server` · `Providers` · `global` · `Pricing` · `[✓] on` · `ailogic only` · `http` · `checks` · `Search & research` · `•2` · `the file exists` · `it is executable` · `Language servers` · `the server answers MCP: waiting` · `GITHUB_PERSONAL_ACCESS_TOKEN` · `●●●●●●●●` · `GITHUB_TOOLSETS` · `applies` · `when the server restarts` · `Agents & limits` · `scope` · `every project` · `Approvals & trust` · `•1` · `tools · from the last connection, 18:10` · `Project file` · `where it comes from` · `Memory` · `[ ] merge_pull_request` · `Library` · `[ ] delete_repository` · `[ ] push_files` · `Appearance` · `server output · last 2 lines` · `Layout & transcript` · `Keys & input` · `Notifications` · `Session & startup` · `danger` · `▸` · `Storage` · `Budget & usage` · `Desktop app` · `Files & environment` · `Import & export` · `saved · the server restarts with it`
- `text_primary` (tp): `github` · `The program SwarmCode starts for this server.` · `Name` · `It speaks MCP on its stdin and stdout. A name` · `Enabled` · `without a slash is looked up on PATH.` · `Scope` · `Transport` · `Arguments` · `stdio` · `Environment` · `2 variables` · `repos,issues,pull_requests` · `41` · `[✓] create_issue` · `[✓] get_issue` · `[✓] list_issues` · `[✓] create_pull_request` · `[✓] get_pull_request` · `› global    /opt/homebrew/bin/github-mcp-…` · `[✓] search_code` · `Delete this server…` · `Command` · `global`
- `key (info bold)` (ky): `Esc` · `Enter` · `/` · `Tab` · `r` · `o` · `D` · `↑↓` · `Space` · `?`
- `text_ghost` (tg): `search 212 settings, providers, servers and k…` · `─────────────────────────────────────────────…` · `│`
- `warning` (wa): `!` · `!2` · `!1`
- `error` (er): `✗`
- `info` (in): `◷`
- `focus on selection` (fo+se): `▌`
- `text_muted (label) on selection` (tm+se): `•` · `global`
- `text_primary on selection` (tp+se): `Command` · `/opt/homebrew/bin/github-mcp-server`
- `success` (ok): `✓`

**Notes**

- The restart is owned work of the settings layer with a 30 s limit; `Esc` on the row stops waiting. The result replaces the status line: `✓ connected · 41 tools` or the failure in the server's own words.
- Tools are toggles in a grid; a switched-off tool is never offered to an agent. `/` on the grid filters tools by name.
- Server output is the last lines the server wrote (stderr), redacted with its secrets.
- Scope `ailogic only` moves the server to this project; the rail's MCP count follows.

---

## F9

### F9 · Agents & limits · a rejected value, bounds, lists, definitions · 160 × 45

`45s` was typed into the sub-agent time limit. The editor keeps the text, says why in the rule's own words under the row and on the status row, and Enter does nothing until the value is allowed; Esc puts 30 min back.

```text
 Settings › Agents & limits                                                                                                                    Esc back to chat 
 / search 212 settings, providers, servers and keys                                                   • 14 changed from default  ! 3 need attention  2 from env 
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  Overview                │  limits for every run                     hard stops · shared with the desktop app │ Sub-agent time limit                           
                          │ • Max concurrent agents         6  1–16  ▰▰▰▰▰▱▱▱▱▱▱▱▱▱▱▱                   global │ limits.sub_agent_timeout · sub_agent_timeout_s 
  models                  │   Max agent depth                1  [2]  3                                 default │                                                
   Models & effort     •4 │   Max agent turns               60  1–200                                  default │ How long a worker may run. Past it the worker  
   Providers            4 │▌  Sub-agent time limit           45s▏  was 30 min                          default │ is stopped and what it found so far goes to    
   Pricing             !2 │                                 ✗ 0 (no limit), or 60 s to 24 h                    │ its lead as a partial result.                  
                          │   Workflow agent budget         128  1–1024                                default │                                                
  tools                   │   Max live workflow agents      16  1–64                                   default │ value     30 min (typing 45s)                  
   Search & research   •2 │ • Command timeout               180 s  1–600 s                              global │ allowed   0 = no limit, or 60 s – 24 h         
   MCP servers         !1 │   Tool timeout                  120 s  1–600 s                             default │ typing    90s · 30m · 1h 30m; a bare           
   Language servers       │                                                                                    │           number is minutes                    
                          │  isolation                                                                         │ applies   to workers started from now          
  agents                  │   Isolate sub-agents            [✓] on · each writer in its own copy       default │ shared    with the desktop app                 
▌  Agents & limits     •2 │   How                           [auto]  clone   worktree                   default │                                                
   Approvals & trust   •1 │                                                                                    │ where it comes from                            
   Project file           │  shell for agent commands                                                          │ › default   30 min                         ✓   
   Memory                 │   Hide secrets from commands    [✓] on                                     default │                                                
   Library                │   Keep these variables          GITHUB_TOKEN · GH_TOKEN                    default │                                                
                          │   Shell                         detect · /bin/zsh here                     default │                                                
  this terminal           │   Login shell                   [✓] on                                     default │                                                
   Appearance          •1 │                                                                                    │                                                
   Layout & transcript •2 │  agent definitions                  project › user › bundled · the first name wins │                                                
   Keys & input        •1 │   reviewer          project     claude-opus-5 · high       shadows the bundled one │                                                
   Notifications          │   researcher        user        the sub-agent model                                │                                                
   Session & startup      │   reviewer          bundled     the sub-agent model                       shadowed │                                                
                          │   implementer       bundled     the sub-agent model                                │                                                
  data                    │   scout             bundled     the sub-agent model                                │                                                
   Storage                │   Enter opens one in $VISUAL   n new, from a template   o reveals its folder       │                                                
   Budget & usage      •1 │                                                                                    │                                                
                          │  always-allowed commands live in Approvals & trust                      g go there │                                                
  more                    │                                                                                    │                                                
   Desktop app            │                                                                                    │                                                
   Files & environment    │                                                                                    │                                                
   Import & export        │                                                                                    │                                                
                          │                                                                                    │                                                
                          │                                                                                    │                                                
                          │                                                                                    │                                                
                          │                                                                                    │                                                
                          │                                                                                    │                                                
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 ✗ Sub-agent time limit 45 s is under the 60 s minimum; 0 means no limit                                         writes to global · shared with the desktop app 
 Enter keep   Esc put 30 min back   Ctrl-U clear   ↑↓ leave, keeping 30 min   ? keys                                                         settings · editing 
```

**Roles**

- `title / emphasis (text_primary bold)` (tb): `Settings` · `Sub-agent time limit` · `[2]` · `Agents & limits` · `[auto]`
- `text_faint` (tf): `›` · `back to chat` · `14 changed from default` · `3 need attention` · `2 from env` · `hard stops · shared with the desktop app` · `1–16` · `limits.sub_agent_timeout · sub_agent_timeout_s` · `models` · `default` · `1–200` · `4` · `1–1024` · `tools` · `1–64` · `(typing 45s)` · `1–600 s` · `agents` · `▌` · `· /bin/zsh here` · `this terminal` · `project › user › bundled · the first name wins` · `shadows the bundled one` · `shadowed` · `data` · `opens one in $VISUAL` · `new, from a template` · `reveals its folder` · `go there` · `more` · `writes to` · `· shared with the desktop app` · `keep` · `put 30 min back` · `clear` · `leave, keeping 30 min` · `keys` · `settings · editing`
- `text_primary` (tp): `Agents & limits` · `Max concurrent agents` · `6` · `Max agent depth` · `Max agent turns` · `How long a worker may run. Past it the worker` · `is stopped and what it found so far goes to` · `its lead as a partial result.` · `Workflow agent budget` · `Max live workflow agents` · `30 min` · `Command timeout` · `180 s` · `Tool timeout` · `Isolate sub-agents` · `How` · `› default   30 min` · `Hide secrets from commands` · `Keep these variables` · `Shell` · `Login shell` · `reviewer` · `researcher` · `implementer` · `Sub-agent time limit` · `global`
- `key (info bold)` (ky): `Esc` · `Enter` · `n` · `o` · `g` · `Ctrl-U` · `↑↓` · `?`
- `text_muted (label)` (tm): `/` · `•` · `Overview` · `limits for every run` · `▰▰▰▰▰` · `global` · `1` · `3` · `Models & effort` · `•4` · `60` · `Providers` · `Pricing` · `128` · `16` · `value` · `Search & research` · `•2` · `allowed` · `0 = no limit, or 60 s – 24 h` · `MCP servers` · `120 s` · `typing` · `90s · 30m · 1h 30m; a bare` · `Language servers` · `number is minutes` · `isolation` · `applies` · `to workers started from now` · `[✓] on · each writer in its own copy` · `shared` · `with the desktop app` · `clone` · `worktree` · `Approvals & trust` · `•1` · `where it comes from` · `Project file` · `shell for agent commands` · `Memory` · `[✓] on` · `Library` · `GITHUB_TOKEN · GH_TOKEN` · `Appearance` · `Layout & transcript` · `agent definitions` · `Keys & input` · `project` · `claude-opus-5 · high` · `Notifications` · `user` · `the sub-agent model` · `Session & startup` · `reviewer` · `bundled` · `scout` · `Storage` · `Budget & usage` · `always-allowed commands live in Approvals & t…` · `Desktop app` … +3 more
- `text_ghost` (tg): `search 212 settings, providers, servers and k…` · `─────────────────────────────────────────────…` · `│` · `▱▱▱▱▱▱▱▱▱▱▱` · `detect`
- `warning` (wa): `!` · `!2` · `!1`
- `focus on selection` (fo+se): `▌` · `▏`
- `text_primary on selection` (tp+se): `Sub-agent time limit`
- `code on selection` (cd+se): `45s`
- `text_faint on selection` (tf+se): `was 30 min` · `default`
- `error on selection` (er+se): `✗ 0 (no limit), or 60 s to 24 h`
- `success` (ok): `✓`
- `error` (er): `✗`

**Notes**

- Durations accept `90s`, `30m`, `1h 30m`; a bare number is the unit the row shows. Values are stored in the column's unit (seconds, milliseconds) and shown in the largest whole unit.
- A special value has a word: `0` is shown as *no limit*.
- Bounds come from the same validation the desktop uses; the TUI never offers a value the service would refuse, and a refusal from the service (another writer) is shown on the row in its words.
- Agent definitions are files: Enter opens one in $VISUAL/$EDITOR, `n` writes a template in the chosen tier; the list shows which definition shadows which.

---

## F10

### F10 · Appearance · the theme with an environment override, colour and glyph tiers, preview · 160 × 45

SWARM_THEME=light is set in the shell, so the theme row shows light and says why. ←→ on the row repaints the whole screen with the choice (a preview); Enter keeps it and writes cli.json; Esc repaints back. The preview boxes draw the same chat rows in the theme chosen and in the other one, and the glyph line shows the tier and its ASCII twins.

```text
 Settings › Appearance                                                                                                                         Esc back to chat 
 / search 212 settings, providers, servers and keys                                                   • 14 changed from default  ! 3 need attention  2 from env 
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  Overview                │  theme                                          this machine's terminal · cli.json │ Theme · this terminal                          
                          │▌• Theme                          follow desktop   dark  [light]    env SWARM_THEME │ terminal.theme · cli.json "theme"              
  models                  │                                 SWARM_THEME=light wins while set · cli.json: dark  │                                                
   Models & effort     •4 │                                                                                    │ Dark or light colours for SwarmCode in this    
   Providers            4 │  colour and glyphs                               auto reads the terminal at launch │ terminal. Follow desktop uses the desktop      
   Pricing             !2 │   Colours                       [auto: truecolor]  256   16   none         default │ app's light or dark mode.                      
                          │   Glyphs                        [auto: measured]  rich   ASCII             default │                                                
  tools                   │   Ambiguous width               [auto: narrow]  wide                       default │ values    follow desktop · dark · light        
   Search & research   •2 │   Reduced motion                [ ] off  --reduced-motion: one launch      default │ applies   at once: the screen repaints         
   MCP servers         !1 │   Accent colour                 #FF6A1A ▮▮▮ 256: 208 · 16: bright yellow   default │                                                
   Language servers       │                                 ✓ contrast 6.6 : 1 on the page                     │ where it comes from        strongest first     
                          │                                                                                    │ › env       light   SWARM_THEME, your shell ✓  
  agents                  │  preview · the same rows in both themes           the screen itself previews on ←→ │   cli.json  dark    shadowed                   
   Agents & limits     •2 │  ┌─ dark ───────────────────────────────┐ ┌─ light ──────────────────────────────┐ │   desktop   dark    its mode · global          
   Approvals & trust   •1 │  │ ✳ Assistant  deepseek-v4-pro         │ │ ✳ Assistant  deepseek-v4-pro         │ │   default   follow desktop                     
   Project file           │  │   ✓ read  README.md        9ms       │ │   ✓ read  README.md        9ms       │ │                                                
   Memory                 │  │   ✓ edit  README.md    +1 −0         │ │   ✓ edit  README.md    +1 −0         │ │ A change here repaints now and writes          
   Library                │  │ ! deps-agent wants to run            │ │ ! deps-agent wants to run            │ │ cli.json; SWARM_THEME still wins at the        
                          │  │    y  once   Y  run   d  deny        │ │   [y] once  [Y] run  [d] deny        │ │ next launch while it is set.                   
  this terminal           │  │ ▌focus   s  hint  Enter key          │ │ ▌focus  [s] hint  Enter key          │ │                                                
▌  Appearance          •1 │  │ engine data text_muted faint         │ │ engine data text_muted faint         │ │                                                
   Layout & transcript •2 │  │ ✳ ⋔ ⚖ ◉ ⧉ ⌕  ● ◐ ◌ ! ✓ ✗ ○ ▰▱        │ │ ✳ ⋔ ⚖ ◉ ⧉ ⌕  ● ◐ ◌ ! ✓ ✗ ○ ▰▱        │ │                                                
   Keys & input        •1 │  │                                      │ │                                      │ │                                                
   Notifications          │  └──────────────────────────────────────┘ └──────────────────────────────────────┘ │                                                
   Session & startup      │   ASCII twins  * S C * # /   * ~ . ! v x o   #-   (Glyphs: ASCII, or SWARM_ASCII=1)│                                                
                          │                                                                                    │                                                
  data                    │  the desktop app's own theme                                  g More › Desktop app │                                                
   Storage                │   Carbon · dark · the terminal keeps its own dark and light                        │                                                
   Budget & usage      •1 │                                                                                    │                                                
                          │                                                                                    │                                                
  more                    │                                                                                    │                                                
   Desktop app            │                                                                                    │                                                
   Files & environment    │                                                                                    │                                                
   Import & export        │                                                                                    │                                                
                          │                                                                                    │                                                
                          │                                                                                    │                                                
                          │                                                                                    │                                                
                          │                                                                                    │                                                
                          │                                                                                    │                                                
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 ←→ previews on the whole screen · Enter keeps it · Esc goes back                                             writes to cli.json · this machine's terminal only 
 ←→ preview   Enter keep   Esc go back   r reset   S write where   ? keys                                                                              settings 
```

**Roles**

- `title / emphasis (text_primary bold)` (tb): `Settings` · `Theme` · `[auto: truecolor]` · `[auto: measured]` · `[auto: narrow]` · `Assistant` · `Appearance`
- `text_faint` (tf): `›` · `back to chat` · `14 changed from default` · `3 need attention` · `2 from env` · `this machine's terminal · cli.json` · `· this terminal` · `terminal.theme · cli.json "theme"` · `models` · `4` · `auto reads the terminal at launch` · `default` · `tools` · `--reduced-motion: one launch` · `256: 208 · 16: bright yellow` · `strongest first` · `SWARM_THEME, your shell` · `agents` · `the screen itself previews on ←→` · `shadowed` · `its mode · global` · `default   follow desktop` · `9ms` · `this terminal` · `key` · `▌` · `faint` · `(Glyphs: ASCII, or SWARM_ASCII=1)` · `data` · `More › Desktop app` · `more` · `←→ previews on the whole screen · Enter keeps…` · `writes to` · `· this machine's terminal only` · `preview` · `keep` · `go back` · `reset` · `write where` · `keys` · `settings`
- `text_primary` (tp): `Appearance` · `Dark or light colours for SwarmCode in this` · `terminal. Follow desktop uses the desktop` · `Colours` · `app's light or dark mode.` · `Glyphs` · `Ambiguous width` · `Reduced motion` · `Accent colour` · `#FF6A1A` · `› env       light` · `README.md` · `wants to run` · `focus` · `✳ ⋔ ⚖ ◉ ⧉ ⌕  ● ◐ ◌ ! ✓ ✗ ○ ▰▱` · `* S C * # /   * ~ . ! v x o   #-` · `cli.json`
- `key (info bold)` (ky): `Esc` · `Enter` · `g` · `←→` · `r` · `S` · `?`
- `text_muted (label)` (tm): `/` · `•` · `Overview` · `theme` · `Models & effort` · `•4` · `Providers` · `colour and glyphs` · `Pricing` · `256` · `16` · `none` · `rich` · `ASCII` · `wide` · `values` · `follow desktop · dark · light` · `Search & research` · `•2` · `[ ] off` · `applies` · `at once: the screen repaints` · `MCP servers` · `Language servers` · `contrast 6.6 : 1 on the page` · `where it comes from` · `preview · the same rows in both themes` · `cli.json  dark` · `Agents & limits` · `dark` · `desktop   dark` · `Approvals & trust` · `•1` · `deepseek-v4-pro` · `Project file` · `read` · `Memory` · `edit` · `A change here repaints now and writes` · `Library` · `cli.json; SWARM_THEME still wins at the` · `once` · `run` · `deny` · `next launch while it is set.` · `hint` · `text_muted` · `Layout & transcript` · `Keys & input` · `Notifications` · `Session & startup` · `ASCII twins` · `the desktop app's own theme` · `Storage` · `Carbon · dark · the terminal keeps its own da…` · `Budget & usage` · `Desktop app` · `Files & environment` · `Import & export`
- `text_ghost` (tg): `search 212 settings, providers, servers and k…` · `─────────────────────────────────────────────…` · `│` · `┌─` · `───────────────────────────────┐` · `└──────────────────────────────────────┘`
- `warning` (wa): `!` · `!2` · `!1`
- `focus on selection` (fo+se): `▌`
- `text_muted (label) on selection` (tm+se): `•` · `follow desktop` · `dark` · `env` · `SWARM_THEME=light wins while set · cli.json: …`
- `text_primary on selection` (tp+se): `Theme`
- `title / emphasis (text_primary bold) on selection` (tb+se): `[light]`
- `text_faint on selection` (tf+se): `SWARM_THEME`
- `accent` (ac): `▮▮▮`
- `success` (ok): `✓` · `+1`
- `text_ghost on light page (preview swatch)` (tg+lt): `┌─` · `──────────────────────────────┐` · `│` · `└──────────────────────────────────────┘`
- `text_muted (light) on light page (preview swatch)` (Lm+lt): `light` · `deepseek-v4-pro` · `read` · `9ms` · `edit` · `once` · `run` · `deny` · `hint` · `key` · `engine data text_muted faint`
- `run_assistant` (as): `✳`
- `accent (light) on light page (preview swatch)` (La+lt): `✳` · `▌` · `[s]`
- `text_primary (light) on light page (preview swatch)` (Lp+lt): `Assistant` · `README.md` · `wants to run` · `focus` · `Enter` · `✳ ⋔ ⚖ ◉ ⧉ ⌕  ● ◐ ◌ ! ✓ ✗ ○ ▰▱`
- `success (light) on light page (preview swatch)` (Lo+lt): `✓` · `+1`
- `error` (er): `−0`
- `error (light) on light page (preview swatch)` (Le+lt): `−0`
- `warning bold` (wb): `deps-agent`
- `warning (light) on light page (preview swatch)` (Lw+lt): `!` · `deps-agent` · `[y]` · `[Y]` · `[d]`
- `chip_warn` (cw): `y` · `Y` · `d`
- `focus` (fo): `▌`
- `on_accent (hint badge)` (oa): `s`
- `agent_lane_1` (l1): `engine`
- `agent_lane_2` (l2): `data`

**Notes**

- Pass 73 wording is kept: after a change under an override the toast says *Dark theme · SWARM_THEME=light still wins at the next launch*.
- `auto` choices show what auto found (`auto: truecolor`), read once at launch; a forced value is honoured even where the probe disagrees, and the row warns when forcing `rich` on a terminal whose ambiguous width is wide.
- The accent colour is a colour field: hex with a swatch, its 256- and 16-colour twins and its contrast on the page (WCAG ratio). Below 4.5:1 the row warns; it never blocks.
- The light swatch uses the light theme's own values; nothing else on screen changes until ←→ previews.

---

## F11

### F11 · Keys & input · capturing a key that is taken · 160 × 45

Enter on *Open the next approval or question* armed capture; the user pressed Ctrl-J, which the Composer already uses for a line break. Capture stops and offers the ways out by letter; the letters work because capture has ended.

```text
 Settings › Keys & input › Key bindings                                                                                                        Esc back to chat 
 / search 212 settings, providers, servers and keys                                                   • 14 changed from default  ! 3 need attention  2 from env 
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  Overview                │  keyboard                                       this machine's terminal · cli.json │ Open the next approval or question             
                          │   Keymap                        [standard]  vim                            default │ keys.composer.next_needs_you                   
  models                  │   Hint leader                   [Ctrl-F and Ctrl-Space]  Ctrl-F only       default │                                                
   Models & effort     •4 │   Editor for Ctrl-X             nvim · from $VISUAL                     env VISUAL │ Jumps to the oldest thing waiting on you. It   
   Providers            4 │   Wheel scrolling               [✓] on · 3 lines a notch                   default │ works in the Composer, the Transcript and the  
   Pricing             !2 │                                                                                    │ side panel; in hint mode the leader pressed    
                          │  key bindings                                   212 actions in 9 places · / filter │ again does the same.                           
  tools                   │   in [Composer]  Transcript  Inspector  Pickers  Dialogs  Overlay  Panel  …        │                                                
   Search & research   •2 │                                                                                    │ default   Ctrl-N                               
   MCP servers         !1 │   does                                      keys                              from │ printed   the needs-you band, the approval     
   Language servers       │   Send the draft                            Enter                          default │           card, the footer and the help say    
                          │ • Queue the draft instead of sending it     Alt-Q · was Alt-Enter         cli.json │           the key it has now                   
  agents                  │   Insert a line break                       Ctrl-O  Ctrl-J  Shift-Enter    default │                                                
   Agents & limits     •2 │▌  Open the next approval or question         press the new keys…         capturing │ where it comes from                            
   Approvals & trust   •1 │   Command palette                           Ctrl-P                         default │ › default   Ctrl-N                         ✓   
   Project file           │   Runs dashboard                            Ctrl-G                         default │                                                
   Memory                 │   Side panel: full, compact, hidden         Ctrl-B  Alt-I                  default │ r back to Ctrl-N   + add a second key          
   Library                │   Hint mode                                 Ctrl-F  Ctrl-Space             default │                                                
                          │   Stop the turn that is streaming           Esc                              fixed │                                                
  this terminal           │   Clear the draft, else stop, twice quits   Ctrl-C                           fixed │                                                
   Appearance          •1 │   … 31 more in the Composer                                                        │                                                
   Layout & transcript •2 │                                                                                    │                                                
▌  Keys & input        •1 │  ───────────────────────────────────────────────────────────────────────────────── │                                                
   Notifications          │   new keys for Open the next approval or question · now Ctrl-N                     │                                                
   Session & startup      │   pressed    Ctrl-J                                                                │                                                
                          │   ! Ctrl-J already inserts a line break in the Composer                            │                                                
  data                    │     s swap: the line break takes Ctrl-N                                            │                                                
   Storage                │     r replace: the line break keeps Ctrl-O and Shift-Enter                         │                                                
   Budget & usage      •1 │     k press another key                                                            │                                                
                          │     Esc keep Ctrl-N                                                                │                                                
  more                    │                                                                                    │                                                
   Desktop app            │  ───────────────────────────────────────────────────────────────────────────────── │                                                
   Files & environment    │   fixed: Esc, Ctrl-C, F1, and y a Y A d D n where an approval shows                │                                                
   Import & export        │   this terminal reports: Alt, Ctrl-Shift, Shift-Enter (enhanced keys on)           │                                                
                          │                                                                                    │                                                
                          │   ▸ Reset every key binding…    1 changed · asks first                           D │                                                
                          │                                                                                    │                                                
                          │                                                                                    │                                                
                          │                                                                                    │                                                
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 ! Ctrl-J already inserts a line break in the Composer                                                        writes to cli.json · this machine's terminal only 
 s swap   r replace   k press another key   Esc keep Ctrl-N                                                                                  settings · capture 
```

**Roles**

- `title / emphasis (text_primary bold)` (tb): `Settings` · `Open the next approval or question` · `[standard]` · `[Ctrl-F and Ctrl-Space]` · `[Composer]` · `Keys & input`
- `text_faint` (tf): `›` · `back to chat` · `14 changed from default` · `3 need attention` · `2 from env` · `this machine's terminal · cli.json` · `default` · `keys.composer.next_needs_you` · `models` · `· from $VISUAL` · `VISUAL` · `4` · `212 actions in 9 places ·` · `filter` · `tools` · `in` · `does` · `keys` · `from` · `· was Alt-Enter` · `agents` · `back to Ctrl-N` · `add a second key` · `fixed` · `this terminal` · `… 31 more in the Composer` · `▌` · `· now Ctrl-N` · `data` · `swap: the line break takes Ctrl-N` · `replace: the line break keeps Ctrl-O and Shif…` · `press another key` · `keep Ctrl-N` · `more` · `fixed:` · `this terminal reports:` · `1 changed · asks first` · `writes to` · `· this machine's terminal only` · `swap` · `replace` · `settings · capture`
- `text_muted (label)` (tm): `Keys & input` · `/` · `•` · `Overview` · `keyboard` · `vim` · `Ctrl-F only` · `Models & effort` · `•4` · `env` · `Providers` · `[✓] on · 3 lines a notch` · `Pricing` · `key bindings` · `Transcript  Inspector  Pickers  Dialogs  Over…` · `Search & research` · `•2` · `default` · `Ctrl-N` · `MCP servers` · `printed` · `the needs-you band, the approval` · `Language servers` · `Enter` · `card, the footer and the help say` · `cli.json` · `the key it has now` · `Ctrl-O  Ctrl-J  Shift-Enter` · `Agents & limits` · `where it comes from` · `Approvals & trust` · `•1` · `Ctrl-P` · `Project file` · `Ctrl-G` · `Memory` · `Ctrl-B  Alt-I` · `Library` · `Ctrl-F  Ctrl-Space` · `Esc` · `Ctrl-C` · `Appearance` · `Layout & transcript` · `Notifications` · `new keys for` · `Session & startup` · `pressed` · `Storage` · `Budget & usage` · `Desktop app` · `Files & environment` · `Esc, Ctrl-C, F1, and y a Y A d D n where an a…` · `Import & export` · `Alt, Ctrl-Shift, Shift-Enter (enhanced keys o…` · `▸` · `already inserts a line break in the Composer`
- `text_primary` (tp): `Key bindings` · `Keymap` · `Hint leader` · `Editor for Ctrl-X` · `nvim` · `Jumps to the oldest thing waiting on you. It` · `Wheel scrolling` · `works in the Composer, the Transcript and the` · `side panel; in hint mode the leader pressed` · `again does the same.` · `Send the draft` · `Queue the draft instead of sending it` · `Alt-Q` · `Insert a line break` · `Command palette` · `› default   Ctrl-N` · `Runs dashboard` · `Side panel: full, compact, hidden` · `Hint mode` · `Stop the turn that is streaming` · `Clear the draft, else stop, twice quits` · `Open the next approval or question` · `Ctrl-J already inserts a line break in the Co…` · `Reset every key binding…` · `Ctrl-J` · `cli.json`
- `key (info bold)` (ky): `Esc` · `/` · `r` · `+` · `s` · `k` · `D`
- `text_ghost` (tg): `search 212 settings, providers, servers and k…` · `─────────────────────────────────────────────…` · `│`
- `warning` (wa): `!` · `!2` · `!1`
- `focus on selection` (fo+se): `▌`
- `text_primary on selection` (tp+se): `Open the next approval or question`
- `chip_accent on selection` (ca+se): `press the new keys…`
- `warning on selection` (wa+se): `capturing`
- `success` (ok): `✓`
- `code` (cd): `Ctrl-J`

**Notes**

- Capture takes exactly one chord. Esc cancels capture (Esc itself cannot be bound). Enter pressed first is captured as Enter; a second Enter keeps what was captured.
- Conflicts are checked in the contexts the action lives in (Composer, Transcript, Panel…); a key used only in other contexts is not a conflict.
- Fixed keys: Esc, Ctrl-C, F1, and the approval letters y a Y A d D n where an approval is shown. Keys this terminal cannot report (enhanced keys off) are refused with the reason.
- Every printed hint (footers, the band's `^N`, cards, help) reads the binding table, so a rebind changes what the screen prints; `mix swarm_code.keymap` documents the defaults and the file of overrides.

---

## F12

### F12 · Confirmation · deleting a provider that others depend on · 160 × 45

`D` on *Delete this provider…*. The dialog names every consequence with counts, requires a replacement for the defaults it would leave empty, starts focused on the safe button, and deletes only with the named letter or Enter on the red button.

```text
 Settings › Providers › DeepSeek                                                                                                               Esc back to chat 
 / search 212 settings, providers, servers and keys                                                   • 14 changed from default  ! 3 need attention  2 from env 
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  Overview                │  DeepSeek  OpenAI-compatible · global · 12 conversations use it   ✓ answered 18:42 │ Delete this provider                           
                          │                                                                                    │ providers.deepseek · danger                    
  models                  │  connection                                                                        │                                                
   Models & effort     •4 │   Name                          DeepSeek                                    global │ Removes DeepSeek and its key. Asks first and   
▌  Providers            4 │   Kind                           Anthropic  [OpenAI-compatible]             global │ shows what uses it.                            
   Pricing             !2 │   Base URL                      https://api.deepseek.com/v1                 global │                                                
                          │▌  API ┌─ Delete DeepSeek? ───────────────────────────────────────────────────────── not undoable ─┐                                 
  tools                   │   ▸ Te│                                                                                           │                                 
   Search & research   •2 │       │  DeepSeek is in use:                                                                      │                                 
   MCP servers         !1 │  model│    the chat default and the sub-agent default                                             │                                 
   Language servers       │   Defa│    12 conversations · their messages stay; new turns need another model                   │                                 
                          │   Mode│    2 scheduled tasks · they run on the replacement below                                  │                                 
  agents                  │     de│    its API key is removed from the Keychain                                               │                                 
   Agents & limits     •2 │   ▸ Fe│                                                                                           │                                 
   Approvals & trust   •1 │   Effo│  New conversations and the two tasks will use                                             │                                 
   Project file           │       │     claude-opus-5 · Anthropic  ▾   Enter on it picks another                              │                                 
   Memory                 │  used │  Sub-agents will use                                                                      │                                 
   Library                │   the │     claude-haiku-5 · Anthropic ▾                                                          │                                 
                          │       │                                                                                           │                                 
  this terminal           │  dange│  The conversations keep DeepSeek as their model in their history; each asks               │                                 
   Appearance          •1 │   ▸ De│  for a new model the next time you send in it.                                            │                                 
   Layout & transcript •2 │       │                                                                                           │                                 
   Keys & input        •1 │       │  ▌ Keep DeepSeek      D  Delete DeepSeek                                                  │                                 
   Notifications          │       │                                                                                           │                                 
   Session & startup      │       │                                                                                           │                                 
                          │       │───────────────────────────────────────────────────────────────────────────────────────────│                                 
  data                    │       │  Tab moves   Enter presses the focused button   D deletes   Esc keeps it                  │                                 
   Storage                │       └───────────────────────────────────────────────────────────────────────────────────────────┘                                 
   Budget & usage      •1 │                                                                                    │                                                
                          │                                                                                    │                                                
  more                    │                                                                                    │                                                
   Desktop app            │                                                                                    │                                                
   Files & environment    │                                                                                    │                                                
   Import & export        │                                                                                    │                                                
                          │                                                                                    │                                                
                          │                                                                                    │                                                
                          │                                                                                    │                                                
                          │                                                                                    │                                                
                          │                                                                                    │                                                
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 the page behind the dialog does not take keys until the dialog closes                                                                                          
 Tab next button   Enter press the focused button   D delete   Esc keep DeepSeek                                                             settings · confirm 
```

**Roles**

- `title / emphasis (text_primary bold)` (tb): `Settings` · `DeepSeek` · `Delete this provider` · `Providers` · `[OpenAI-compatible]`
- `text_faint` (tf): `›` · `back to chat` · `14 changed from default` · `3 need attention` · `2 from env` · `OpenAI-compatible · global · 12 conversations…` · `providers.deepseek · danger` · `models` · `▌` · `4` · `tools` · `agents` · `this terminal` · `data` · `more` · `the page behind the dialog does not take keys…` · `next button` · `press the focused button` · `delete` · `keep DeepSeek` · `settings · confirm`
- `text_muted (label)` (tm): `Providers` · `/` · `•` · `Overview` · `answered 18:42` · `connection` · `Models & effort` · `•4` · `global` · `Anthropic` · `Pricing` · `▸` · `Search & research` · `•2` · `MCP servers` · `model` · `Language servers` · `de` · `Agents & limits` · `Approvals & trust` · `•1` · `Project file` · `Memory` · `used` · `Library` · `the` · `dange` · `Appearance` · `Layout & transcript` · `Keys & input` · `Notifications` · `Session & startup` · `Storage` · `Budget & usage` · `Desktop app` · `Files & environment` · `Import & export`
- `text_primary` (tp): `DeepSeek` · `Name` · `Removes DeepSeek and its key. Asks first and` · `Kind` · `shows what uses it.` · `Base URL` · `https://api.deepseek.com/v1` · `Te` · `Defa` · `Mode` · `Fe` · `Effo` · `De`
- `key (info bold)` (ky): `Esc` · `Tab` · `Enter` · `D`
- `text_ghost` (tg): `search 212 settings, providers, servers and k…` · `─────────────────────────────────────────────…` · `│`
- `warning` (wa): `!` · `!2` · `!1`
- `success` (ok): `✓`
- `focus on selection` (fo+se): `▌`
- `text_primary on selection` (tp+se): `API`
- `text_ghost on popover` (tg+po): `┌─` · `─────────────────────────────────────────────…` · `─┐` · `│` · `│────────────────────────────────────────────…` · `└────────────────────────────────────────────…`
- `title / emphasis (text_primary bold) on popover` (tb+po): `Delete DeepSeek?`
- `text_faint on popover` (tf+po): `not undoable` · `on it picks another` · `The conversations keep DeepSeek as their mode…` · `for a new model the next time you send in it.` · `moves` · `presses the focused button` · `deletes` · `keeps it`
- `text_primary on popover` (tp+po): `DeepSeek is in use:` · `New conversations and the two tasks will use` · `Sub-agents will use`
- `text_muted (label) on popover` (tm+po): `the chat default and the sub-agent default` · `12 conversations · their messages stay; new t…` · `2 scheduled tasks · they run on the replaceme…` · `its API key is removed from the Keychain`
- `code on popover` (cd+po): `claude-opus-5 · Anthropic  ▾` · `claude-haiku-5 · Anthropic ▾`
- `key (info bold) on popover` (ky+po): `Enter` · `Tab` · `D` · `Esc`
- `title / emphasis (text_primary bold) on selection` (tb+se): `Keep DeepSeek`
- `chip_err on popover` (ce+po): `D  Delete DeepSeek`

**Notes**

- Dialog rules (AGENTS.md): initial focus on *Keep*, Tab/Shift-Tab trapped inside, Esc closes once, the page behind is inert, focus returns to the row that opened it.
- The destructive button uses chip_err; it is the only error-coloured element and it says the object's name, not *OK*.
- Counts come from queries run when the dialog opens (owned work); while they load the rows say *counting…* and the delete button is disabled.
- After deleting: the toast says what went (`DeepSeek deleted · 12 conversations now use claude-opus-5 for new turns`); a provider delete is not undoable, and the dialog says so.

---

## F13

### F13 · Help · ? (or F1) over settings · 160 × 45

The settings keys in three columns that wrap instead of cutting, then the meaning of every mark and tag. Generated from the binding table, so a rebind shows here; the same lists print in docs/keybindings.md.

```text
 Settings › Appearance                                                                                                                         Esc back to chat 
 / search 212 settings, providers, servers and keys                                                   • 14 changed from default  ! 3 need attention  2 from env 
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
   ┌─ Keys · Settings ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────── ? or Esc closes ─┐   
   │                                                                                                                                                        │   
   │  move                                              change                                            while editing                                     │   
   │  ↑ ↓   j k           the previous or next row      Enter               edit, open or pick from a     Enter               keep the value                │   
   │  PgUp PgDn           a screen up or down                               list                          Esc                 put the old value back        │   
   │  Home End  g G       the first or last row         Space               switch on or off              Ctrl-A Ctrl-E       start or end of the line      │   
   │  [ ]                 the previous or next          ← →                 the next choice; step a       Ctrl-W Ctrl-U       delete a word, or to the      │   
   │                      section                                           number                                            start                         │   
   │  Tab  Shift-Tab      rail, page, detail, in turn   Shift-← →           a bigger step                 Ctrl-O Shift-Enter  a line break, in a long       │   
   │  h  ←                back to the rail (on a row    0-9                 start typing a number                             text                          │   
   │                      with no value to step)        r                   reset to the default          Tab                 complete a path, a key or     │   
   │  l  →  Enter         into a record or a sub-page   S                   choose where the change is                        an @filter                    │   
   │  Esc                 up one level; at the top,                         written                       Cmd-V               paste; the only way into a    │   
   │                      back to the chat              u  Ctrl-Z           undo the last change                              secret                        │   
   │  q                   back to the chat from any     Ctrl-Shift-Z        redo                                                                            │   
   │                      level                         Ctrl-X              edit a text, a list or a                                                        │   
   │  Ctrl-F              badges on sections and                            file in $VISUAL                                                                 │   
   │                      rows; a letter jumps          a  x                add or remove a list row                                                        │   
   │  /                   search every setting; Esc     J K                 move a list row down or up                                                      │   
   │                      clears it                     Ctrl-S              create a new record; save a                                                     │   
   │  :                   a settings command: :set,                         long text                                                                       │   
   │                      :reset, :goto                 D                   delete a record (always                                                         │   
   │  Ctrl-N              the next approval or                              asks)                                                                           │   
   │                      question (leaves settings)                                                                                                        │   
   │                                                                                                                                                        │   
   │                                                                                                                                                        │   
   │ ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────── │   
   │  marks                                                                                                                                                 │   
   │  • changed from its default                        ! needs your attention                            ✗ failed, or not allowed                          │   
   │  ✓ answered, allowed, the winner                   ◷ running now                                     ▌ focus                                           │   
   │  [✓] on  [ ] off                                   [high] the choice made                            ‹ 12 › a number being stepped                     │   
   │  ●●●●●●●● a secret, never shown                    ▸ an action, not a value                          … opens a confirmation first                      │   
   │                                                                                                                                                        │   
   │  where a value comes from, strongest first (a setting uses only the layers it has)                                                                     │   
   │  flag this launch's command line · env a variable in your shell · session this conversation · project this project · cli.json this machine's terminal  │   
   │  global shared with the desktop app · project file .swarm_code/config.json, fills gaps only · default built in.                                        │   
   │  flag and env are read at launch and are not changed here; their row names the flag or the variable.                                                   │   
   │  Every key above can be changed in Keys & input › Key bindings › Settings.                                                                             │   
   └────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘   
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 the same list is in docs/keybindings.md (mix swarm_code.keymap)                                                                                                
 Esc close   ? close   PgUp PgDn scroll   / find a key                                                                                          settings · help 
```

**Roles**

- `title / emphasis (text_primary bold)` (tb): `Settings`
- `text_faint` (tf): `›` · `back to chat` · `14 changed from default` · `3 need attention` · `2 from env` · `the same list is in docs/keybindings.md (mix …` · `close` · `scroll` · `find a key` · `settings · help`
- `text_primary` (tp): `Appearance`
- `key (info bold)` (ky): `Esc` · `?` · `PgUp PgDn` · `/`
- `text_muted (label)` (tm): `/` · `•`
- `text_ghost` (tg): `search 212 settings, providers, servers and k…` · `─────────────────────────────────────────────…`
- `warning` (wa): `!`
- `text_ghost on popover` (tg+po): `┌─` · `─────────────────────────────────────────────…` · `─┐` · `│` · `└────────────────────────────────────────────…`
- `title / emphasis (text_primary bold) on popover` (tb+po): `Keys · Settings` · `[high]`
- `key (info bold) on popover` (ky+po): `?` · `Esc` · `↑ ↓   j k` · `Enter` · `PgUp PgDn` · `Home End  g G` · `Space` · `Ctrl-A Ctrl-E` · `[ ]` · `← →` · `Ctrl-W Ctrl-U` · `Tab  Shift-Tab` · `Shift-← →` · `Ctrl-O Shift-Enter` · `h  ←` · `0-9` · `r` · `Tab` · `l  →  Enter` · `S` · `Cmd-V` · `u  Ctrl-Z` · `q` · `Ctrl-Shift-Z` · `Ctrl-X` · `Ctrl-F` · `a  x` · `/` · `J K` · `Ctrl-S` · `:` · `D` · `Ctrl-N`
- `text_faint on popover` (tf+po): `or` · `closes` · `changed from its default` · `needs your attention` · `failed, or not allowed` · `answered, allowed, the winner` · `running now` · `focus` · `the choice made` · `a number being stepped` · `a secret, never shown` · `an action, not a value` · `opens a confirmation first` · `this launch's command line ·` · `a variable in your shell ·` · `this conversation ·` · `this project ·` · `this machine's terminal` · `shared with the desktop app ·` · `.swarm_code/config.json, fills gaps only ·` · `built in.` · `flag and env are read at launch and are not c…` · `Every key above can be changed in Keys & inpu…`
- `text_muted (label) on popover` (tm+po): `move` · `change` · `while editing` · `marks` · `•` · `[✓] on  [ ] off` · `‹ 12 ›` · `●●●●●●●●` · `▸` · `…` · `where a value comes from, strongest first (a …`
- `text_primary on popover` (tp+po): `the previous or next row` · `edit, open or pick from a` · `keep the value` · `a screen up or down` · `list` · `put the old value back` · `the first or last row` · `switch on or off` · `start or end of the line` · `the previous or next` · `the next choice; step a` · `delete a word, or to the` · `section` · `number` · `start` · `rail, page, detail, in turn` · `a bigger step` · `a line break, in a long` · `back to the rail (on a row` · `start typing a number` · `text` · `with no value to step)` · `reset to the default` · `complete a path, a key or` · `into a record or a sub-page` · `choose where the change is` · `an @filter` · `up one level; at the top,` · `written` · `paste; the only way into a` · `back to the chat` · `undo the last change` · `secret` · `back to the chat from any` · `redo` · `level` · `edit a text, a list or a` · `badges on sections and` · `file in $VISUAL` · `rows; a letter jumps` · `add or remove a list row` · `search every setting; Esc` · `move a list row down or up` · `clears it` · `create a new record; save a` · `a settings command: :set,` · `long text` · `:reset, :goto` · `delete a record (always` · `the next approval or` · `asks)` · `question (leaves settings)` · `flag` · `env` · `session` · `project` · `cli.json` · `global` · `project file` · `default`
- `warning on popover` (wa+po): `!`
- `error on popover` (er+po): `✗`
- `success on popover` (ok+po): `✓`
- `info on popover` (in+po): `◷`
- `focus on popover` (fo+po): `▌`

**Notes**

- Unlike today's help sheet (pass 73 `hc.png`), no description is cut with `…`: a column wraps its descriptions, and under 120 columns the columns stack and PgUp/PgDn scroll.
- `?` inside a text editor types a `?`; F1 opens help from anywhere.
- The legend is part of help, not of every page (the critique's rule against a legend row on every screen).

---

## F14

### F14 · Narrow · 90 × 30 · Approvals & trust (this project) · 90 × 30

Under 120 columns the rail becomes a one-row section strip (`[` `]` step it), the page takes the full width, and the focused row's detail is a three-row drawer; `i` opens the whole detail as its own page. The needs-you chip shortens to `! 1 needs you ^N`.

```text
 Settings › Approvals & trust                         ! 1 needs you ^N   Esc back to chat 
 [ Agents & limits  Approvals & trust  Project file  Memory  Library ]            9 of 22 
 / search 212 settings                                                   • 14  ! 3  2 env 
──────────────────────────────────────────────────────────────────────────────────────────
  ailogic  ~/dev/ailogic · this project only                                              
                                                                                          
  approvals                                                                               
▌• Approvals               read-only  [auto]  full access                         project 
                          auto: edits go ahead, commands ask first                        
   Trusted                [✓] yes · since Sep 20                                  project 
                          reads AGENTS.md · allows edits · runs hooks                     
                                                                                          
  always-allowed commands                                                       5 · a add 
   mix test               a command family: anything starting with it            x forget 
   mix format                                                                    x forget 
   git diff                                                                      x forget 
   git status                                                                    x forget 
   ls                                                                            x forget 
                                                                                          
  from the environment                                                                    
   SWARM_APPROVAL         not set · when set it wins for that launch                      
                                                                                          
                                                                                          
──────────────────────────────────────────────────────────────────────────────────────────
 Approvals · project.approval_mode                   › project auto ✓ · default read-only 
 What agents may do in ailogic without asking. Full access runs commands and              
 edits without asking, so choosing it asks you first.                                     
──────────────────────────────────────────────────────────────────────────────────────────
 writes to this project · i the whole detail                                              
 ←→ choose   Enter edit   [ ] section   / search   ? keys                        settings 
```

**Roles**

- `title / emphasis (text_primary bold)` (tb): `Settings` · `Approvals & trust` · `ailogic` · `Approvals`
- `text_faint` (tf): `›` · `back to chat` · `9 of 22` · `14` · `3` · `2 env` · `~/dev/ailogic · this project only` · `reads AGENTS.md · allows edits · runs hooks` · `·` · `add` · `a command family: anything starting with it` · `forget` · `· when set it wins for that launch` · `· project.approval_mode` · `· default read-only` · `writes to` · `the whole detail` · `choose` · `edit` · `section` · `search` · `keys` · `settings`
- `text_primary` (tp): `Approvals & trust` · `Trusted` · `5` · `mix test` · `mix format` · `git diff` · `git status` · `ls` · `SWARM_APPROVAL` · `› project auto` · `this project`
- `warning` (wa): `! 1 needs you` · `!`
- `key (info bold)` (ky): `^N` · `Esc` · `[` · `]` · `a` · `x` · `i` · `←→` · `Enter` · `[ ]` · `/` · `?`
- `text_muted (label)` (tm): `Agents & limits` · `Project file` · `Memory` · `Library` · `/` · `•` · `approvals` · `[✓] yes · since Sep 20` · `project` · `always-allowed commands` · `from the environment` · `What agents may do in ailogic without asking.…` · `edits without asking, so choosing it asks you…`
- `text_ghost` (tg): `search 212 settings` · `─────────────────────────────────────────────…` · `not set`
- `focus on selection` (fo+se): `▌`
- `text_muted (label) on selection` (tm+se): `•` · `read-only` · `full access` · `project` · `auto: edits go ahead, commands ask first`
- `text_primary on selection` (tp+se): `Approvals`
- `title / emphasis (text_primary bold) on selection` (tb+se): `[auto]`
- `success` (ok): `✓`

**Notes**

- Choosing *full access* opens a confirmation first (it lets agents run commands without asking); going down to auto or read-only does not ask.
- An always-allowed command family is forgotten with `x` and can be undone with `u`.
- Labels are never cut while space remains (R14); a value that does not fit wraps under its row, the label keeps its column.

---

## F15

### F15 · Narrow · 90 × 30 · the same frame with NO_COLOR and SWARM_ASCII=1 · 90 × 30

The mono/ASCII twin of F14: no colour at all, every glyph ASCII. The focused row is reversed video (the Theme's monochrome `selection`), and `>` still marks it for terminals that ignore reverse. Meaning survives through words, brackets and `!`.

```text
 Settings > Approvals & trust                         ! 1 needs you ^N   Esc back to chat 
 [ Agents & limits  Approvals & trust  Project file  Memory  Library ]            9 of 22 
 / search 212 settings                                                   * 14  ! 3  2 env 
------------------------------------------------------------------------------------------
  ailogic  ~/dev/ailogic - this project only                                              
                                                                                          
  approvals                                                                               
>* Approvals               read-only  [auto]  full access                         project 
                          auto: edits go ahead, commands ask first                        
   Trusted                [v] yes - since Sep 20                                  project 
                          reads AGENTS.md - allows edits - runs hooks                     
                                                                                          
  always-allowed commands                                                       5 - a add 
   mix test               a command family: anything starting with it            x forget 
   mix format                                                                    x forget 
   git diff                                                                      x forget 
   git status                                                                    x forget 
   ls                                                                            x forget 
                                                                                          
  from the environment                                                                    
   SWARM_APPROVAL         not set - when set it wins for that launch                      
                                                                                          
                                                                                          
------------------------------------------------------------------------------------------
 Approvals - project.approval_mode                   > project auto v - default read-only 
 What agents may do in ailogic without asking. Full access runs commands and              
 edits without asking, so choosing it asks you first.                                     
------------------------------------------------------------------------------------------
 writes to this project - i the whole detail                                              
 Left/Right choose   Enter edit   [ ] section   / search   ? keys                settings 
```

**Roles**

- `monochrome bold` (mb): `Settings` · `^N` · `Esc` · `[` · `Approvals & trust` · `]` · `ailogic` · `a` · `x` · `Approvals` · `i` · `Left/Right` · `Enter` · `[ ]` · `/` · `?`
- `monochrome text (NO_COLOR: no SGR colour)` (mo): `> Approvals & trust` · `! 1 needs you` · `back to chat` · `Agents & limits` · `Project file  Memory  Library` · `9 of 22` · `/ search 212 settings` · `* 14  ! 3  2 env` · `---------------------------------------------…` · `~/dev/ailogic - this project only` · `approvals` · `Trusted` · `[v] yes - since Sep 20` · `project` · `reads AGENTS.md - allows edits - runs hooks` · `always-allowed commands` · `5 -` · `add` · `mix test` · `a command family: anything starting with it` · `forget` · `mix format` · `git diff` · `git status` · `ls` · `from the environment` · `SWARM_APPROVAL` · `not set - when set it wins for that launch` · `- project.approval_mode` · `> project auto v - default read-only` · `What agents may do in ailogic without asking.…` · `edits without asking, so choosing it asks you…` · `writes to this project -` · `the whole detail` · `choose` · `edit` · `section` · `search` · `keys` · `settings`
- `monochrome reversed (selection in mono)` (mr): `>* Approvals               read-only  [auto] …` · `auto: edits go ahead, commands ask first`

**Notes**

- Twins: `▌`→`>`, `•`→`*`, `›`→`>`, `·`→`-`, `✓`→`v`, `✗`→`x`, `[✓]`→`[v]`, `●●●●`→`****`, `◷`→`~`, `←→`→`<- ->`, rules `─│`→`-|`.
- Warning, error and success keep their words (`! 1 needs you`, `x failed`, `v`), which is why no mark in this design is colour-only.

---

## F16

### F16 · Smallest · 80 × 24 · drill-down pages · 80 × 24

At 80 columns there is no rail and no side detail: sections are a page of their own, a section is a page, a record is a page. The breadcrumb says where you are and Esc says where it goes. The detail is a single row; `i` opens it whole.

```text
 Settings › Providers                                              Esc sections 
 / search 212 settings                                                      ! 3 
────────────────────────────────────────────────────────────────────────────────
  4 providers                                         a add  f fetch all models 
  name           kind       key      models    last test                        
▌ DeepSeek       OpenAI     set        6       ✓ 412 ms · 18:42                 
  Anthropic      Anthropic  set        9       never tested                     
  llmotions      OpenAI     set       12       ✓ 610 ms · 18:30                 
  Local Ollama   OpenAI     none       1       ✗ refused · 18:31                
                                                                                
  from the environment                                                          
   SWARM_PROVIDER, SWARM_BASE_URL, SWARM_API_KEY: not set                       
                                                                                
  add from a preset                                                             
   Anthropic · OpenAI · OpenRouter · DeepSeek · Ollama · LM Studio · other      
                                                                                
  Enter or l opens a provider · h or Esc goes back to the sections              
                                                                                
                                                                                
                                                                                
────────────────────────────────────────────────────────────────────────────────
 DeepSeek · api.deepseek.com · chat and sub-agent default · 12 chats            
 80 × 24: one page at a time · i the whole detail                               
 ↑↓ move   Enter open   a add   / search   ? keys                      settings 
```

**Roles**

- `title / emphasis (text_primary bold)` (tb): `Settings` · `DeepSeek`
- `text_faint` (tf): `›` · `sections` · `3` · `add` · `fetch all models` · `name` · `kind` · `key` · `models` · `last test` · `never tested` · `none` · `SWARM_PROVIDER, SWARM_BASE_URL, SWARM_API_KEY…` · `Enter or l opens a provider · h or Esc goes b…` · `· api.deepseek.com · chat and sub-agent defau…` · `80 × 24: one page at a time ·` · `the whole detail` · `move` · `open` · `search` · `keys` · `settings`
- `text_primary` (tp): `Providers` · `Anthropic` · `set` · `llmotions` · `Local Ollama` · `Anthropic · OpenAI · OpenRouter · DeepSeek · …`
- `key (info bold)` (ky): `Esc` · `a` · `f` · `i` · `↑↓` · `Enter` · `/` · `?`
- `text_muted (label)` (tm): `/` · `4 providers` · `Anthropic` · `9` · `OpenAI` · `12` · `610 ms · 18:30` · `1` · `refused · 18:31` · `from the environment` · `add from a preset`
- `text_ghost` (tg): `search 212 settings` · `─────────────────────────────────────────────…`
- `warning` (wa): `!`
- `focus on selection` (fo+se): `▌`
- `text_primary on selection` (tp+se): `DeepSeek` · `set`
- `text_muted (label) on selection` (tm+se): `OpenAI` · `6` · `412 ms · 18:42`
- `success on selection` (ok+se): `✓`
- `success` (ok): `✓`
- `error` (er): `✗`

**Notes**

- Below 80 × 20 the layer shows only: *Settings needs 80 × 20; this terminal is 72 × 18. Make it larger, or use `swarmcode config` in a shell.* Esc still closes it.
- Table columns drop from the right as width shrinks: last test, then models, then kind; the name and the key state never drop.
