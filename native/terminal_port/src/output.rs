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

fn paint(previous: Option<&Painted>, next: &Painted, writer: &mut impl Write) -> io::Result<()> {
    let buffer = &next.buffer;
    let full = previous.is_none_or(|p| p.buffer.area != buffer.area);
    let columns = buffer.area.width as usize;
    let mut painted = false;
    for y in 0..buffer.area.height {
        let start = y as usize * columns;
        let row = &buffer.content[start..start + columns];
        let dirty =
            full || previous.is_some_and(|p| p.buffer.content[start..start + columns] != *row);
        if !dirty {
            continue;
        }
        if !painted {
            command(writer, Hide)?;
            painted = true;
        }
        // Clear the whole row before writing any new glyph. Ratatui's ForcedWidth
        // diff branch does not erase old trailing cells, so never use Buffer::diff.
        command(writer, SetAttribute(Attribute::Reset))?;
        command(writer, MoveTo(0, y))?;
        command(writer, Clear(ClearType::UntilNewLine))?;
        // Paint every reserved column with its desired style, including reversed
        // backgrounds. Spaces honor reverse video where ECH/BCE may not.
        for (x, cell) in row.iter().enumerate() {
            if let CellDiffOption::ForcedWidth(width) = cell.diff_option {
                style(writer, cell)?;
                command(writer, MoveTo(x as u16, y))?;
                writer.write_all(&[b' '; 500][..width.get() as usize])?;
            }
        }
        for (x, cell) in row.iter().enumerate() {
            if matches!(cell.diff_option, CellDiffOption::ForcedWidth(_)) {
                style(writer, cell)?;
                // Every lead uses absolute CUP, even when terminal shaping has a
                // different advance from the declared reserved width.
                command(writer, MoveTo(x as u16, y))?;
                writer.write_all(cell.symbol().as_bytes())?;
            }
        }
    }
    if painted {
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
    Ok(())
}

fn style(writer: &mut impl Write, cell: &Cell) -> io::Result<()> {
    command(writer, SetAttribute(Attribute::Reset))?;
    color(writer, cell.fg, true)?;
    color(writer, cell.bg, false)?;
    for (modifier, attribute) in [
        (Modifier::BOLD, Attribute::Bold),
        (Modifier::DIM, Attribute::Dim),
        (Modifier::ITALIC, Attribute::Italic),
        (Modifier::UNDERLINED, Attribute::Underlined),
        (Modifier::REVERSED, Attribute::Reverse),
    ] {
        if cell.modifier.contains(modifier) {
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
