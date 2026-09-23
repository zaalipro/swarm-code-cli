//! Explicit, bounded output. No terminal ownership, input, environment, or global state.
//!
//! The caller supplies a writer (normally a bounded BufWriter over its terminal fd).
//! A successful flush is the commit point. Failed writes invalidate the prior screen.
use crate::frame::{Color as WireColor, Cursor, DrawFrame, FrameError};
use crossterm::{
    Command,
    cursor::{Hide, MoveTo, SetCursorStyle, Show},
    style::{Attribute, SetAttribute},
    terminal::{Clear, ClearType},
};
use ratatui_core::{
    buffer::{Buffer, Cell, CellDiffOption},
    layout::Rect,
    style::{Color, Modifier},
};
use std::{
    fmt,
    io::{self, Write},
    num::NonZeroU16,
};

#[derive(Debug)]
pub enum Error {
    Frame(FrameError),
    Io(io::Error),
}
impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Frame(_) => f.write_str("invalid terminal draw frame"),
            Self::Io(_) => f.write_str("terminal draw output failed"),
        }
    }
}
impl std::error::Error for Error {}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DrawMeta {
    pub sequence: u64,
    pub revision: u64,
    pub columns: u16,
    pub rows: u16,
}

struct Painted {
    buffer: Buffer,
    cursor: Option<Cursor>,
}

/// Retains one bounded previous cell buffer; never retains an input body or output stream.
#[derive(Default)]
pub struct Painter {
    previous: Option<Painted>,
}
impl Painter {
    pub fn new() -> Self {
        Self::default()
    }

    /// Require a full repaint after external output, suspend/resume, or terminal replacement.
    pub fn invalidate(&mut self) {
        self.previous = None;
    }

    pub fn draw(&mut self, body: &[u8], writer: &mut impl Write) -> Result<DrawMeta, Error> {
        // Decode the entire frame before projection or any write, including cursor commands.
        let frame = DrawFrame::decode(body).map_err(Error::Frame)?;
        let next = Painted {
            buffer: project(&frame),
            cursor: frame.cursor,
        };
        let result = paint(self.previous.as_ref(), &next, writer).and_then(|()| writer.flush());
        if let Err(error) = result {
            self.invalidate();
            return Err(Error::Io(error));
        }
        self.previous = Some(next);
        Ok(DrawMeta {
            sequence: frame.sequence,
            revision: frame.revision,
            columns: frame.columns,
            rows: frame.rows,
        })
    }
}

fn project(frame: &DrawFrame<'_>) -> Buffer {
    let mut buffer = Buffer::empty(Rect::new(0, 0, frame.columns, frame.rows));
    for glyph in &frame.glyphs {
        let palette = frame.palette[glyph.palette as usize];
        let mut modifiers = Modifier::empty();
        for (bit, modifier) in [
            (1, Modifier::BOLD),
            (2, Modifier::DIM),
            (4, Modifier::ITALIC),
            (8, Modifier::UNDERLINED),
            (16, Modifier::REVERSED),
        ] {
            if palette.modifiers & bit != 0 {
                modifiers.insert(modifier);
            }
        }
        // Only the lead owns text. Continuations retain styles and explicit Skip metadata.
        // Width is projector-owned, never recomputed with a Unicode width policy here.
        for x in glyph.x..glyph.x + glyph.width {
            let cell = &mut buffer[(x, glyph.y)];
            cell.fg = core_color(palette.foreground);
            cell.bg = core_color(palette.background);
            cell.modifier = modifiers;
            cell.diff_option = CellDiffOption::Skip;
        }
        let lead = &mut buffer[(glyph.x, glyph.y)];
        lead.set_symbol(glyph.text);
        lead.diff_option = CellDiffOption::ForcedWidth(NonZeroU16::new(glyph.width).unwrap());
    }
    buffer
}

const ANSI_COLORS: [Color; 16] = [
    Color::Black,
    Color::Red,
    Color::Green,
    Color::Yellow,
    Color::Blue,
    Color::Magenta,
    Color::Cyan,
    Color::Gray,
    Color::DarkGray,
    Color::LightRed,
    Color::LightGreen,
    Color::LightYellow,
    Color::LightBlue,
    Color::LightMagenta,
    Color::LightCyan,
    Color::White,
];
fn core_color(color: WireColor) -> Color {
    match color {
        WireColor::Default => Color::Reset,
        WireColor::Ansi(i) => ANSI_COLORS[i as usize],
        WireColor::Indexed(i) => Color::Indexed(i),
        WireColor::Rgb(r, g, b) => Color::Rgb(r, g, b),
    }
}

/// The SGR state a glyph needs; tracked so a run of equally styled glyphs pays
/// for its style once.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Pen {
    fg: Color,
    bg: Color,
    modifier: Modifier,
}
const DEFAULT_PEN: Pen = Pen {
    fg: Color::Reset,
    bg: Color::Reset,
    modifier: Modifier::empty(),
};
const MODIFIERS: [(Modifier, Attribute); 5] = [
    (Modifier::BOLD, Attribute::Bold),
    (Modifier::DIM, Attribute::Dim),
    (Modifier::ITALIC, Attribute::Italic),
    (Modifier::UNDERLINED, Attribute::Underlined),
    (Modifier::REVERSED, Attribute::Reverse),
];
const SPACES: [u8; 500] = [b' '; 500];

/// What the terminal is known to hold while one frame is written: the pen and
/// the cursor position. `None` means unknown, so the next glyph states it.
struct Pencil {
    pen: Option<Pen>,
    at: Option<(u16, u16)>,
}

// pass70 B8 (ux M9): a frame writes only the cells that changed. Each dirty
// row repaints one span, from the first to the last changed cell widened to
// whole glyphs of both frames, with one cursor move per span, SGR only when
// the style changes, and implicit advance across ASCII glyphs whose width is
// their length. Any other glyph (wide, or non-ASCII whose terminal advance
// the projector's width policy only declares) reserves its columns with
// spaces first and re-anchors the cursor after itself. A span whose old
// glyphs were such glyphs is erased (ECH) before the new ones land, so no
// half of an old wide glyph survives; a full repaint erases each row (EL).
fn paint(previous: Option<&Painted>, next: &Painted, writer: &mut impl Write) -> io::Result<()> {
    let buffer = &next.buffer;
    let old = previous
        .filter(|p| p.buffer.area == buffer.area)
        .map(|p| &p.buffer);
    let columns = buffer.area.width as usize;
    let mut pencil = Pencil {
        pen: None,
        at: None,
    };
    let mut painted = false;
    for y in 0..buffer.area.height {
        let start = y as usize * columns;
        let row = &buffer.content[start..start + columns];
        let old_row = old.map(|b| &b.content[start..start + columns]);
        let Some((from, to)) = span(row, old_row) else {
            continue;
        };
        if !painted {
            // DEC private mode 2026: the terminal holds the frame back until the
            // closing sequence, so a partially painted grid is never shown.
            writer.write_all(b"\x1b[?2026h")?;
            command(writer, Hide)?;
            painted = true;
        }
        match old_row {
            None => {
                // EL erases with the current background: reset it first.
                set_pen(writer, &mut pencil, DEFAULT_PEN)?;
                move_to(writer, &mut pencil, 0, y)?;
                command(writer, Clear(ClearType::UntilNewLine))?;
            }
            Some(old_row) => {
                if old_row[from..to].iter().any(|cell| !exact(cell)) {
                    move_to(writer, &mut pencil, from as u16, y)?;
                    write!(writer, "\x1b[{}X", to - from)?;
                }
            }
        }
        let mut x = from;
        while x < to {
            let cell = &row[x];
            let width = lead_width(cell);
            glyph(writer, &mut pencil, (x as u16, y), width, columns, cell)?;
            x += width;
        }
    }
    if painted && pencil.pen != Some(DEFAULT_PEN) {
        command(writer, SetAttribute(Attribute::Reset))?;
    }
    if painted || previous.is_none_or(|p| p.cursor != next.cursor) {
        match next.cursor {
            None => command(writer, Hide)?,
            Some(cursor) => {
                command(
                    writer,
                    match cursor.shape {
                        0 => SetCursorStyle::SteadyBlock,
                        1 => SetCursorStyle::SteadyBar,
                        _ => SetCursorStyle::SteadyUnderScore,
                    },
                )?;
                command(writer, MoveTo(cursor.x, cursor.y))?;
                if cursor.visible {
                    command(writer, Show)?;
                } else {
                    command(writer, Hide)?;
                }
            }
        }
    }
    // A cursor-only change stays unbracketed: one cursor move cannot tear.
    if painted {
        writer.write_all(b"\x1b[?2026l")?;
    }
    Ok(())
}

/// The columns `[from, to)` of a row to repaint: all of it without a previous
/// row, else the changed cells widened until both frames have a glyph boundary
/// at each end. `None` when nothing changed.
fn span(row: &[Cell], old_row: Option<&[Cell]>) -> Option<(usize, usize)> {
    let Some(old_row) = old_row else {
        return Some((0, row.len()));
    };
    let first = row.iter().zip(old_row).position(|(a, b)| a != b)?;
    let last = row.iter().zip(old_row).rposition(|(a, b)| a != b)?;
    let continuation = |x: usize| {
        row[x].diff_option == CellDiffOption::Skip || old_row[x].diff_option == CellDiffOption::Skip
    };
    let mut from = first;
    while from > 0 && continuation(from) {
        from -= 1;
    }
    let mut to = last + 1;
    while to < row.len() && continuation(to) {
        to += 1;
    }
    Some((from, to))
}

fn lead_width(cell: &Cell) -> usize {
    match cell.diff_option {
        CellDiffOption::ForcedWidth(width) => width.get() as usize,
        _ => 1,
    }
}

/// A glyph whose terminal advance is certain: ASCII text exactly as long as
/// its declared width (the frame decoder already refused control characters).
fn exact(cell: &Cell) -> bool {
    match cell.diff_option {
        CellDiffOption::ForcedWidth(width) => {
            let text = cell.symbol();
            text.is_ascii() && text.len() == width.get() as usize
        }
        _ => true,
    }
}

fn glyph(
    writer: &mut impl Write,
    pencil: &mut Pencil,
    (x, y): (u16, u16),
    width: usize,
    columns: usize,
    cell: &Cell,
) -> io::Result<()> {
    set_pen(
        writer,
        pencil,
        Pen {
            fg: cell.fg,
            bg: cell.bg,
            modifier: cell.modifier,
        },
    )?;
    move_to(writer, pencil, x, y)?;
    let certain = exact(cell);
    if !certain && width > 1 {
        // Reserve every declared column with the glyph's own style (spaces
        // honor reverse video where ECH/BCE may not), then write it over them.
        writer.write_all(&SPACES[..width])?;
        pencil.at = None;
        move_to(writer, pencil, x, y)?;
    }
    writer.write_all(cell.symbol().as_bytes())?;
    // After the last column the cursor waits to wrap; after an uncertain
    // advance its column is unknown. Either way the next glyph moves first.
    let end = x as usize + width;
    pencil.at = (certain && end < columns).then_some((end as u16, y));
    Ok(())
}

fn move_to(writer: &mut impl Write, pencil: &mut Pencil, x: u16, y: u16) -> io::Result<()> {
    if pencil.at != Some((x, y)) {
        command(writer, MoveTo(x, y))?;
        pencil.at = Some((x, y));
    }
    Ok(())
}

fn set_pen(writer: &mut impl Write, pencil: &mut Pencil, pen: Pen) -> io::Result<()> {
    match pencil.pen {
        Some(current) if current == pen => return Ok(()),
        // Only added modifiers: change what differs.
        Some(current) if pen.modifier.contains(current.modifier) => {
            if current.fg != pen.fg {
                color(writer, pen.fg, true)?;
            }
            if current.bg != pen.bg {
                color(writer, pen.bg, false)?;
            }
            modifiers(writer, pen.modifier.difference(current.modifier))?;
        }
        // Unknown, or a modifier to drop: SGR has no portable per-attribute
        // off for all of them, so start from a reset.
        _ => {
            command(writer, SetAttribute(Attribute::Reset))?;
            if pen.fg != Color::Reset {
                color(writer, pen.fg, true)?;
            }
            if pen.bg != Color::Reset {
                color(writer, pen.bg, false)?;
            }
            modifiers(writer, pen.modifier)?;
        }
    }
    pencil.pen = Some(pen);
    Ok(())
}

fn modifiers(writer: &mut impl Write, set: Modifier) -> io::Result<()> {
    for (modifier, attribute) in MODIFIERS {
        if set.contains(modifier) {
            command(writer, SetAttribute(attribute))?;
        }
    }
    Ok(())
}

fn color(writer: &mut impl Write, color: Color, foreground: bool) -> io::Result<()> {
    // crossterm's Colored formatter reads NO_COLOR and memoizes global state.
    // The validated wire palette is authoritative; encode this small SGR subset.
    let base = if foreground { 38 } else { 48 };
    match color {
        Color::Reset => write!(writer, "\x1b[{}m", base + 1),
        Color::Indexed(index) => write!(writer, "\x1b[{base};5;{index}m"),
        Color::Rgb(r, g, b) => write!(writer, "\x1b[{base};2;{r};{g};{b}m"),
        named => {
            let index = ANSI_COLORS
                .iter()
                .position(|color| *color == named)
                .expect("all named core colors are ANSI");
            let sgr = if index < 8 {
                30 + index
            } else {
                90 + index - 8
            } + if foreground { 0 } else { 10 };
            write!(writer, "\x1b[{sgr}m")
        }
    }
}

/// Write only the ANSI representation: no execute/queue platform fallback or global IO.
fn command(writer: &mut impl Write, command: impl Command) -> io::Result<()> {
    struct Adapter<'a, W> {
        writer: &'a mut W,
        error: Option<io::Error>,
    }
    impl<W: Write> fmt::Write for Adapter<'_, W> {
        fn write_str(&mut self, text: &str) -> fmt::Result {
            self.writer.write_all(text.as_bytes()).map_err(|error| {
                self.error = Some(error);
                fmt::Error
            })
        }
    }
    let mut adapter = Adapter {
        writer,
        error: None,
    };
    command.write_ansi(&mut adapter).map_err(|_| {
        adapter
            .error
            .unwrap_or_else(|| io::Error::other("terminal command formatting failed"))
    })
}

#[cfg(test)]
mod sync_tests {
    use super::*;

    fn painted(symbol: &str) -> Painted {
        let mut buffer = Buffer::empty(Rect::new(0, 0, 2, 1));
        let cell = &mut buffer[(0, 0)];
        cell.set_symbol(symbol);
        cell.diff_option = CellDiffOption::ForcedWidth(NonZeroU16::new(1).unwrap());
        Painted {
            buffer,
            cursor: None,
        }
    }

    #[test]
    fn a_painted_frame_is_bracketed_in_synchronized_update_mode() {
        let mut out = Vec::new();
        paint(None, &painted("x"), &mut out).unwrap();
        let text = String::from_utf8_lossy(&out);
        assert!(
            text.starts_with("\x1b[?2026h"),
            "opens the bracket first: {text:?}"
        );
        assert!(text.ends_with("\x1b[?2026l"), "closes it last: {text:?}");
    }

    #[test]
    fn an_unchanged_frame_writes_nothing() {
        let first = painted("x");
        let mut out = Vec::new();
        paint(Some(&first), &painted("x"), &mut out).unwrap();
        assert!(out.is_empty(), "{:?}", String::from_utf8_lossy(&out));
    }
}
