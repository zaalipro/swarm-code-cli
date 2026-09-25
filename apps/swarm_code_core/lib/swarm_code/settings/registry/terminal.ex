defmodule SwarmCode.Settings.Registry.Terminal do
  @moduledoc false
  # §2.14–§2.17 This terminal: the cli.json preferences (scope :cli) and the
  # terminal's facts. Created by S1 for the tag `c74-S1-core`; U3 owns it after
  # (pass74 U3-1: groups for the pages' headings; the accent's validator).
  import SwarmCode.Settings.Registry.Build

  @next_launch "Applies at the next launch."

  @appearance [
    cli("terminal.theme", :appearance, "Theme",
      group: "theme",
      description:
        "Follow the desktop app's mode, or pick one. Applies at once; SWARM_THEME wins at the next launch.",
      storage: {:cli, "theme"},
      type: :enum,
      choices:
        choices([
          {"follow", "Follow the desktop app"},
          {"dark", "Dark"},
          {"light", "Light"}
        ]),
      default: "follow",
      layers: [:env, :cli, :global, :default],
      env: ["SWARM_THEME"],
      follows: "desktop.mode",
      applies: :at_once,
      synonyms: ["theme", "dark mode", "light mode", "colour theme"],
      parity: "CLI /theme"
    ),
    cli("terminal.colors", :appearance, "Colours",
      group: "colour and glyphs",
      description:
        "#{@next_launch} NO_COLOR (set and not empty) wins; auto probes COLORTERM and TERM.",
      storage: {:cli, "colors"},
      type: :enum,
      choices:
        choices([
          {"auto", "auto"},
          {"truecolor", "truecolor"},
          {"256", "256"},
          {"16", "16"},
          {"none", "none"}
        ]),
      default: "auto",
      layers: [:env, :cli, :default],
      env: ["NO_COLOR"],
      applies: :next_launch,
      synonyms: ["colours", "colors", "no color"],
      since: :c74,
      parity: "NEW"
    ),
    cli("terminal.glyphs", :appearance, "Glyphs",
      group: "colour and glyphs",
      description: "#{@next_launch} SWARM_ASCII=1 wins (ascii).",
      storage: {:cli, "glyphs"},
      type: :enum,
      choices:
        choices([
          {"auto", "auto"},
          {"rich", "rich"},
          {"measured", "measured"},
          {"ascii", "ascii"}
        ]),
      default: "auto",
      layers: [:env, :cli, :default],
      env: ["SWARM_ASCII"],
      applies: :next_launch,
      synonyms: ["ascii"],
      since: :c74,
      parity: "NEW"
    ),
    cli("terminal.ambiguous_width", :appearance, "Ambiguous-width characters",
      group: "colour and glyphs",
      description: @next_launch,
      storage: {:cli, "ambiguous_width"},
      type: :enum,
      choices: choices([{"narrow", "narrow"}, {"wide", "wide"}]),
      default: "narrow",
      applies: :next_launch,
      since: :c74,
      parity: "NEW"
    ),
    cli("terminal.reduced_motion", :appearance, "Reduced motion",
      group: "colour and glyphs",
      description: @next_launch,
      storage: {:cli, "reduced_motion"},
      type: :toggle,
      default: false,
      applies: :next_launch,
      since: :c74,
      parity: "NEW"
    ),
    cli("terminal.accent", :appearance, "Accent colour",
      group: "colour and glyphs",
      description:
        "The focus bar, caret, hint badges and the assistant's colour. #{@next_launch} Below 4.5:1 contrast warns, never blocks.",
      storage: {:cli, "accent"},
      type: :color,
      validate: [:hex_color],
      example: "#2DD4BF",
      nullable: true,
      null_label: "Carbon (#FF6A1A)",
      applies: :next_launch,
      synonyms: ["accent"],
      since: :c74,
      parity: "NEW"
    ),
    link(
      "terminal.desktop_theme_link",
      :appearance,
      "The desktop app's theme",
      :desktop,
      "desktop.theme"
    )
  ]

  @layout [
    cli("terminal.panel", :layout, "Side panel",
      group: "layout",
      description: "Applies at once; Ctrl-B cycles it.",
      storage: {:cli, "panel"},
      type: :enum,
      choices: choices([{"full", "full"}, {"compact", "compact"}, {"hidden", "hidden"}]),
      default: "full",
      applies: :at_once,
      synonyms: ["panel", "side panel"],
      parity: "CLI /panel"
    ),
    cli("terminal.composer_rows", :layout, "Composer height",
      group: "layout",
      description: "Rows at launch; Ctrl-↑/↓ still adjust it.",
      storage: {:cli, "composer_rows"},
      type: :integer,
      unit: :rows,
      min: 1,
      max: 8,
      default: 3,
      applies: :at_once,
      since: :c74,
      parity: "NEW"
    ),
    cli("terminal.inspector_width", :layout, "Inspector width",
      group: "layout",
      storage: {:cli, "inspector_width"},
      type: :enum,
      choices:
        choices([
          {"compact", "compact", "38"},
          {"default", "default", "46"},
          {"wide", "wide", "56"}
        ]),
      default: "default",
      applies: :at_once,
      since: :c74,
      parity: "NEW"
    ),
    cli("terminal.show_diffs", :layout, "Show diffs",
      group: "transcript",
      description: "Off draws every tool row on one line.",
      storage: {:cli, "show_diffs"},
      type: :toggle,
      default: true,
      applies: :at_once,
      synonyms: ["diffs", "diff"],
      parity: "CLI /diff"
    ),
    cli("terminal.notice_seconds", :layout, "Notices stay for",
      group: "transcript",
      storage: {:cli, "notice_seconds"},
      type: :duration,
      unit: :s,
      min: 2,
      max: 30,
      default: 6,
      applies: :at_once,
      since: :c74,
      parity: "NEW"
    ),
    cli("terminal.diff_lines", :layout, "Diff lines shown",
      group: "transcript",
      description: "Lines of each diff hunk drawn before … N more lines · Enter opens.",
      storage: {:cli, "diff_lines"},
      type: :integer,
      unit: :lines,
      min: 4,
      max: 200,
      big_step: 10,
      default: 12,
      applies: :at_once,
      since: :c74,
      parity: "NEW"
    )
  ]

  @keys [
    cli("terminal.keymap", :keys, "Keymap",
      group: "keyboard and wheel",
      description:
        "Vim adds NORMAL/VISUAL modes to the composer. SWARM_KEYMAP wins at the next launch.",
      storage: {:cli, "keymap"},
      type: :enum,
      choices: choices([{"standard", "standard"}, {"vim", "vim"}]),
      default: "standard",
      layers: [:env, :cli, :default],
      env: ["SWARM_KEYMAP"],
      applies: :at_once,
      synonyms: ["vim", "vim mode", "keymap"],
      parity: "CLI"
    ),
    cli("terminal.mouse", :keys, "Wheel scrolling",
      group: "keyboard and wheel",
      description:
        "Off gives the terminal its own selection back. SWARM_MOUSE wins at the next launch.",
      storage: {:cli, "mouse"},
      type: :toggle,
      default: true,
      layers: [:env, :cli, :default],
      env: ["SWARM_MOUSE"],
      applies: :at_once,
      synonyms: ["mouse", "wheel"],
      parity: "CLI /mouse"
    ),
    cli("terminal.wheel_lines", :keys, "Lines per notch",
      group: "keyboard and wheel",
      description: "Only when Wheel scrolling is on.",
      storage: {:cli, "wheel_lines"},
      type: :integer,
      unit: :lines,
      min: 1,
      max: 10,
      default: 3,
      applies: :at_once,
      since: :c74,
      parity: "NEW"
    ),
    cli("terminal.editor", :keys, "Editor for Ctrl-X",
      group: "typing and hints",
      description: "A command line; unset uses $VISUAL, then $EDITOR, then vi.",
      storage: {:cli, "editor"},
      type: :text,
      nullable: true,
      null_label: "$VISUAL, then $EDITOR, then vi",
      layers: [:cli, :env, :default],
      env: ["VISUAL", "EDITOR"],
      validate: [:required, :one_line, {:max_length, 1024}],
      example: "hx",
      applies: :at_once,
      synonyms: ["editor"],
      since: :c74,
      parity: "NEW"
    ),
    cli("terminal.hint_letters", :keys, "Hint letters",
      group: "typing and hints",
      description: "Ctrl-F badges, in order.",
      storage: {:cli, "hint_letters"},
      type: :text,
      unit: :letters,
      default: "sfghjklwertuiop",
      example: "sfghjklw",
      validate: [:hint_letters],
      applies: :at_once,
      since: :c74,
      parity: "NEW"
    ),
    cli("terminal.keys", :keys, "Key bindings",
      group: "key bindings",
      description:
        "Overrides only; an empty list unbinds. Every printed hint follows. swarmcode config reset terminal.keys recovers the defaults.",
      storage: {:cli, "keys"},
      type: :keys,
      default: %{},
      applies: :at_once,
      synonyms: ["key bindings", "keybindings", "bindings", "shortcuts"],
      since: :c74,
      parity: "NEW"
    ),
    fact("terminal.terminal_facts", :keys, "This terminal reports", :terminal_facts,
      group: "key bindings",
      description: "Bracketed paste, focus, wheel; enhanced keys never.",
      parity: "T§5.15"
    )
  ]

  @startup [
    cli("terminal.startup_conversation", :startup, "On launch",
      group: "launch",
      description:
        "#{@next_launch} --new/--continue/--resume and SWARM_CONVERSATION win for their launch.",
      storage: {:cli, "startup_conversation"},
      type: :enum,
      choices:
        choices([
          {"latest", "Continue the latest conversation"},
          {"new", "Start a new conversation"},
          {"ask", "Ask (the resume picker, as --resume)"}
        ]),
      default: "latest",
      layers: [:flag, :env, :cli, :default],
      flag: "--new/--continue/--resume",
      env: ["SWARM_CONVERSATION"],
      applies: :next_launch,
      since: :c74,
      parity: "NEW"
    ),
    cli("terminal.companion", :startup, "Visual companion",
      group: "launch",
      description:
        "The loopback web mirror (palette \"Open visual companion\"). SWARM_COMPANION=0 wins.",
      storage: {:cli, "companion"},
      type: :toggle,
      default: true,
      layers: [:env, :cli, :default],
      env: ["SWARM_COMPANION"],
      applies: :next_launch,
      synonyms: ["companion"],
      since: :c74,
      parity: "NEW"
    ),
    fact("terminal.project_root", :startup, "Project folder", :project_root_launch,
      group: "this launch",
      description: "The DIR argument, else the current directory.",
      parity: "A§6.3"
    ),
    fact("terminal.launch_flags", :startup, "This launch", :launch_flags,
      group: "this launch",
      description: "The flags it was started with.",
      parity: "A§6.3"
    )
  ]

  def entries, do: @appearance ++ @layout ++ @keys ++ @startup
end
