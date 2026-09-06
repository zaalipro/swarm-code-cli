# Guarded terminal Port candidate

Status: implementation candidate; not adopted. This follows the completed cell
painter and the exact ExRatatui rejection. Work stays in swarm-code-cli; the
desktop, canonical data, and global toolchain are untouched.

## Architecture and selection

The first candidate remains a Rust Port. It consumes the existing Paint.Plan,
uses ratatui-core 0.1.2 cells and project-owned output with crossterm 0.29.0
commands, and reads terminal bytes through a project parser. Do not use the
stock ratatui-crossterm backend: its default dependency enables the event reader,
and cursor::position reads input and writes DSR to stdout. A pure-Elixir renderer
remains the fallback candidate, with separate evidence. Direct ExRatatui widgets
remain rejected for the reasons recorded in the renderer ADR.

Static source review found no blocker to this composition. Ratatui ForcedWidth
accepts positive u16 widths; its special diff branch does not clear old trailing
columns. The project must validate row fit and clear affected complete spans.
The output writer positions every glyph explicitly rather than assuming the
terminal advances by one cell. Terminals still choose font shaping; declared
width reserves cells, and native captures must establish actual appearance.

## Components

- `native/terminal_port`: project-owned Rust library and eventual executable.
  Pure parser tests need only std. Rendering adds exact direct versions of
  ratatui-core and crossterm with default features disabled; Cargo.lock pins all
  transitive versions. Crossterm events, cursor queries and raw-mode global state
  are unused. The guard owns termios on the explicit descriptor instead.
- `UI.Renderer.RatatuiPort`: the only Elixir adapter aware of the executable and
  binary protocol. It validates Plan and converts closed input records to Input.
- A terminal owner registers with SessionRuntime only after terminal readiness.
  It fetches the exact Scene revision from SceneSlot and acknowledges only after
  the corresponding paint completes. At most one frame and one input record are
  outstanding. Canonical semantic deliveries continue through SessionRuntime.
- A separate restoration guard retains the original termios and a lifecycle pipe.
  The writer alone performs active drawing. Guard restoration is serialized with
  writer termination. Broken parent pipes, normal exit, and handled signals have
  one restoration path. No claim covers killing the entire process group with
  SIGKILL; recovery remains `reset`/`stty sane` for that case.

The runnable integration will be a fixed synthetic terminal demo using existing
Fake.Source/SessionRuntime. It must exercise navigation, editor input, questions,
run/agent controls and detach, not only draw static scenes. The plain command
retains its application/process boundary. This candidate does not start a daemon,
provider, Repo, or canonical-data service.

## Bounded input contract

`InputParser::advance(&mut self, bytes: &[u8]) -> Step` consumes a prefix and returns
at most one owned Event. `Step.consumed` is exact; the caller retains the unconsumed
suffix in its fixed read buffer and must not read again until it is consumed.
An empty input consumes zero. No hidden event queue or whole-input copy exists.
A terminal loop uses reads of at most 4096 bytes and forwards one record only
when the BEAM owner grants credit. Lack of credit stops terminal reads.

Events use closed key/phase/modifier/rejection enums matching UI.Input. Ordinary
UTF-8 is committed in complete scalar fragments (at most four bytes), preserving
sequence for the editor's grapheme assembly. ASCII controls map explicitly to
Enter, Tab, Backspace or control-modified text; unknown controls are ignored.
No external string creates an atom. Standard CSI/SS3 navigation and F1–F12 are
recognized; modified navigation and supported CSI-u press/repeat/release events
have explicit closed mappings. Unsupported CSI/SS3/control-string forms produce
no text event. Legacy ESC plus a letter/Unicode scalar is Alt text. ESC punctuation
! through / remains an ECMA escape-intermediate prefix, so legacy Alt punctuation
in that range is unsupported and may consume its following final byte. CSI-u
can represent those keys; this subset is not a full Alt-key fidelity claim.
CSI-u alternate-key and associated-text extensions are currently ignored.

The pure parser has no clock. An owner waits 40 ms for an ambiguous standalone
Escape, then calls `expire_escape`; incomplete UTF-8 or control strings are not
flushed as ordinary text by that timeout. `finish` yields a pending standalone
Escape or invalid-UTF-8 rejection, discards incomplete control sequences/paste,
and resets state. EOF never inserts an unterminated paste.

Bracketed paste begins at ESC[200~ and ends at ESC[201~. The parser retains at
most 262144 payload bytes plus the fixed terminator prefix. Reservation is checked
before allocation/growth. Overflow releases retained payload, emits exactly one
PasteTooLarge event, and consumes through the terminator with constant state;
bytes after the terminator resume ordinary parsing. No truncated paste is emitted.
A completed payload is UTF-8 checked and moved into one owned event, or rejected
without retaining rejected bytes. Terminator splits and false prefixes preserve
exact admitted payload bytes. Nested start markers are literal paste content.

CSI/SS3 state is at most 64 bytes. Overflow switches to discard-until-final state.
OSC and other control strings are discarded with constant terminator state until
BEL (OSC) or ST; their contents never become text/key events. Invalid UTF-8 emits
one rejection per malformed sequence and resynchronizes without dropping the next
valid scalar. Parser debug/status output contains counts/state names, never text.

## Output and lifecycle work

The protocol is local to the disposable renderer, separate from daemon IPC.
Each direction uses a length header validated before body allocation and a closed
versioned binary body. Draw frames carry revision, dimensions, palette, positioned
whole glyphs and cursor only; action Intents and source DTOs never leave BEAM.
The adapter preserves opaque action metadata locally because live mouse remains
disabled. Frame, event, credit, ready, paint-ack, shutdown and restored records
will receive exact layouts and cross-language fixtures in the transport task.

The writer opens /dev/tty explicitly; stdin/stdout remain protocol channels.
Initialization explicitly chooses alternate-screen or no-alt before any mode
change. No-alt never enters the alternate screen. Resize is queried on that fd;
raw/cooked transitions use the retained original termios. Disable mouse, bracketed
paste and focus reporting, restore cursor visibility/style, and restore termios
on orderly closure and each injected initialization failure. Suspend restores
before stopping; resume reinitializes and requests a fresh current frame.

## Verification and claim boundary

Each component has failing behavioral tests before implementation. Parser tests
cover every packet split, exact paste bounds, malformed UTF-8 recovery, unknown
control-string floods, false terminators, 100 bounded pastes, 10000 ordered keys,
credit-compatible prefix consumption, and retained-capacity counters.

The next tasks add cross-language wire fixtures, exact frame-output tests for both
width policies, overwritten wide spans, all color modes and cursor shapes, and a
real PTY harness. The integrated demo must restore exact termios and preserve
main-screen sentinels in no-alt mode. Real keyboard paths use the existing reducer;
shutdown never synthesizes domain Stop. Browser checks, when needed for captured
visual artifacts, use ego-lite and close only the task space without clearing
sessions/cookies.

Adoption still requires the interaction contract's native macOS14+/Ubuntu22.04+
arm64/x86_64, lifecycle, input, performance, soak, offline release and manual
terminal matrix. Local source/unit/PTY evidence is reported at its actual scope.
Neither a working parser nor one native machine establishes full renderer or
product parity. Daemon/provider/persistence work remains on the original goal.
