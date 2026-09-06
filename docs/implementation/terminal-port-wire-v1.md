# Terminal Port wire v1

Implementation status: draw/control codecs, bounded response framing, native
writer, credit loop, restoration guard and live Elixir owner are implemented.
Native PTY evidence is local to this machine.
This protocol belongs only to the disposable terminal adapter, not daemon IPC.
All integers are unsigned big-endian. Unknown tags/enums, trailing bytes and
invalid sizes close the renderer connection with a fixed diagnostic; they never
become domain actions. Bodies are length-prefixed with a four-byte u32.

## Draw body (tag3)

| Field | Encoding |
|---|---|
| Version, tag | u8=1, u8=3 |
| Transport sequence, Scene revision | u64, u64 |
| Columns, rows | u16 (1..500), u16 (1..200); product<=100000 |
| Ambiguous-width policy | u8: narrow0, wide1 |
| Color mode | u8: monochrome0, ansi16=1, ansi256=2, truecolor3 |
| Palette count | u16,1..4096 |
| Cursor | u8=0 for absent; otherwise1,x:u16,y:u16,shape:u8,visible:u8 |
| Glyph count | u32,1..columns*rows |
| Palette | count entries, each foreground color, background color, modifier:u8 |
| Glyphs | count entries, each width:u16, palette-index:u16, UTF8-byte-length:u32, bytes |

Cursor shape is block0,bar1,underline2; visible is0/1. Present coordinates must
be inside the grid. Absent and invisible are distinct. Colors are variable-sized:
0 default;1 followed by ANSI index0..15;2 followed by indexed color0..255;3 followed
by red,green,blue bytes. ANSI order is black,red,green,yellow,blue,magenta,cyan,
white,then the corresponding bright values. Richer modes admit poorer colors;
monochrome admits only default,ansi16 admits default/ANSI,ansi256 adds indexed,
and truecolor adds RGB. Modifier bits0..4 are bold,dim,italic,underlined,reversed;
all higher bits reject.

Glyphs cover the entire grid in row-major order, including ordinary blank cells.
Each width is1..500, stays within its row, and advances the implicit column by
exactly that many cells. A row ending advances to column0 of the next row.
Continuation cells are implicit and never contain another glyph payload. Total
coverage must equal columns*rows exactly; no missing, overlapping or extra cells.
Each glyph has1..262144bytes of valid inert UTF8 and an existing palette index.
The BEAM encoder first validates the complete Plan (including SafeText identity
and selected-policy width). The native boundary validates UTF8/control exclusion,
span geometry and bounds before creating Ratatui cells; it does not reinterpret
width through Paragraph or substitute narrow for wide.

The body cap is33554432bytes, validated from the length header before native body
allocation. The Elixir encoder returns bounded iodata with this header and returns
an explicit error if the cap would be exceeded. No terminal IO occurs in it.
Neither opaque action IDs nor focus IDs/rectangles nor clipped-action diagnostics
are serialized: the keyboard-only adapter needs cells and cursor, and activation
ownership remains in SessionRuntime. The sequence is a local monotonically
assigned draw token, separate from revision. At most one frame can be unacknowledged.

## Input mapping

Draw encoding is separate from the closed control and response records specified
below. Unknown tags cannot authorize unvalidated maps or unbounded JSON.

The parser's closed Rust event values map to existing UI.Input, with no strings
converted to atoms. Phase codes are press0,repeat1,release2. Modifier bits0..5
are Shift,Control,Alt,Super,Hyper,Meta. Key codes0..22 follow the neutral special-key
order: Backspace,Enter,Left,Right,Up,Down,Home,End,PageUp,PageDown,Tab,BackTab,
Delete,Insert,Escape,Null,CapsLock,ScrollLock,NumLock,PrintScreen,Pause,Menu,
KeypadBegin. F1..F12 reserve32..43. Any other numeric code is unsupported, never
constructed as an arbitrary key. Text fragments and completed paste retain exact
UTF8 bytes; rejections contain only a reason code, never rejected content.

## Control and response records

These exact layouts extend v1 for the terminal owner. Every body begins
with version:u8=1,tag:u8. They use the same four-byte length prefix as Draw.
Generation and token/sequence are u64. A token identifies one outstanding control
or input credit, not a source/domain action.

| Direction/tag | Fields after version/tag |
|---|---|
| BEAM→native Init1 | generation, flags:u8 |
| BEAM→native Credit2,Shutdown4,Suspend5,Resume6 | generation, token |
| Native→BEAM Ready16 | generation, columns:u16, rows:u16, flags:u8 |
| Native→BEAM Input17 | generation, credit-token, input-kind:u8, payload below |
| Native→BEAM Painted18 | generation, draw-sequence, revision:u64 |
| Native→BEAM Skipped23 | generation, draw-sequence, revision:u64 |
| Native→BEAM ResumeNeeded24 | generation |
| Native→BEAM Restored19 | generation, control-token, state:u8 (closed0,suspended1) |
| Native→BEAM Resize20 | generation, credit-token, columns:u16,rows:u16 |
| Native→BEAM Error21 | generation, reason:u8 |

Flag bits are alternate-screen0,focus-reporting1,bracketed-paste2; others reject.
Ready confirms applied flags. Sizes are nonzero u16 observations; the renderer's
Draw admission remains500×200. Input kinds/payloads are:

- Key0: phase:u8,key-code:u8,modifier-bits:u8.
- Text1: phase:u8,modifier-bits:u8,length:u16,exact UTF8 bytes (1..4096).
- Paste2: length:u32,exact UTF8 bytes (0..262144).
- Rejected3: reason:u8 (invalid-UTF8=0,text-fragment-too-large1,paste-too-large2).
- FocusGained4/FocusLost5: empty payload.

Error reasons1..6 are protocol,initialization,draw,read,write,restoration. No raw
exception, OS path, terminal bytes, or source content enters an error. The maximum
native response body is262167bytes (largest paste record). Decode checks this cap,
closed enums, exact lengths and trailing-byte absence before admitting neutral
Input. Framing must bound retained bytes before passing a complete body to decode.

Input and Resize share one credit. The native reader consumes only while a credit
is outstanding, emits exactly one event bearing that token, then stops reading.
Pending resize observations coalesce and use the next credit. The BEAM owner
submits input to SessionRuntime before granting the next strictly increasing
token. No unsolicited event is admitted. Generation mismatches, duplicate credit,
and non-increasing draw sequences close the connection. A Painted record is sent
only after output flush and returns both draw sequence and Scene revision.
Skipped23 means that observed terminal dimensions differ from the frame before
painting. It emits no terminal bytes, consumes that draw sequence, and schedules
a Resize for the next input credit. The owner settles the old draw as retryable
and supplies a fresh frame after applying Resize. Geometry can still change
during multi-write painting; no atomic terminal resize guarantee is implied.

Shutdown and Suspend revoke input credit before mode restoration. Restored is
sent only after successful mode output and exact termios restoration; Resume produces a new Ready and a
fresh full paint. The native session loop and guard enforce these lifecycle properties in the
owned PTY tests. Full supported-platform and shell job-control evidence remains
separate from local protocol tests.

Every restoration attempt uses nonblocking output with a bounded write deadline,
including retries after restoring descriptor status flags. Exact termios reset
runs even if mode output fails. A permanently blocked terminal can prevent escape
mode cleanup; that path returns restoration Error21 and exits nonzero, without a
false Restored acknowledgement. BEAM waits for actual guard exit status before
claiming cleanup; protocol EOF alone does not establish process termination.

External suspend/continue uses an explicit barrier. On CONT the writer remains
inactive and sends ResumeNeeded24. That record cancels pre-barrier pending paints
and credits; the owner settles old draws as retryable and sends a fresh Resume
control. FIFO ordering lets native discard old queued Draw/Credit commands until
that Resume. Only after reactivation/Ready may the owner send a fresh draw and
credit. This avoids stale credits crossing external resume. Pending terminal
bytes stay bounded and are not read or emitted while the barrier is active.
