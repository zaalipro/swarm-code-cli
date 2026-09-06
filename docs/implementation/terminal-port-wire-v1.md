# Terminal Port wire v1

Implementation status: Elixir draw encoder and bounded native draw decoder are
implemented and checked with cross-language fixtures. Control/event transport,
credits and live terminal owner remain in progress.
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

## Reserved record tags and input mapping

Tag1 init,2 input-credit,4 shutdown,5 suspend,6 resume,16 ready,17 input,18 painted,
19 restored,20 resize and21 fixed error are reserved for the native integration.
They are not accepted by the draw encoder and have no executable implementation
yet. Exact record layouts, decoder allocation limits and connection-state tests
must precede use. Reserved tags cannot authorize the terminal owner to send
unvalidated maps or unbounded JSON.

The parser's closed Rust event values map to existing UI.Input, with no strings
converted to atoms. Phase codes are press0,repeat1,release2. Modifier bits0..5
are Shift,Control,Alt,Super,Hyper,Meta. Key codes0..22 follow the neutral special-key
order: Backspace,Enter,Left,Right,Up,Down,Home,End,PageUp,PageDown,Tab,BackTab,
Delete,Insert,Escape,Null,CapsLock,ScrollLock,NumLock,PrintScreen,Pause,Menu,
KeypadBegin. F1..F12 reserve32..43. Any other numeric code is unsupported, never
constructed as an arbitrary key. Text fragments and completed paste retain exact
UTF8 bytes; rejections contain only a reason code, never rejected content.
