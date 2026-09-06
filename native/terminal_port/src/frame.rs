//! Bounded borrowed decode of the project's declared-width draw frame.
use std::fmt;

pub const MAX_FRAME_BYTES: usize = 33_554_432;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FrameError {
    Invalid,
    Capacity,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Color {
    Default,
    Ansi(u8),
    Indexed(u8),
    Rgb(u8, u8, u8),
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PaletteEntry {
    pub foreground: Color,
    pub background: Color,
    pub modifiers: u8,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Cursor {
    pub x: u16,
    pub y: u16,
    pub shape: u8,
    pub visible: bool,
}
pub struct Glyph<'a> {
    pub x: u16,
    pub y: u16,
    pub width: u16,
    pub palette: u16,
    pub text: &'a str,
}
pub struct DrawFrame<'a> {
    pub sequence: u64,
    pub revision: u64,
    pub columns: u16,
    pub rows: u16,
    pub wide: bool,
    pub color_mode: u8,
    pub palette: Vec<PaletteEntry>,
    pub cursor: Option<Cursor>,
    pub glyphs: Vec<Glyph<'a>>,
}
impl fmt::Debug for DrawFrame<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("DrawFrame")
            .field("sequence", &self.sequence)
            .field("revision", &self.revision)
            .field("columns", &self.columns)
            .field("rows", &self.rows)
            .field("glyph_count", &self.glyphs.len())
            .field("palette_count", &self.palette.len())
            .finish_non_exhaustive()
    }
}
impl fmt::Debug for Glyph<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Glyph")
            .field("x", &self.x)
            .field("y", &self.y)
            .field("width", &self.width)
            .field("palette", &self.palette)
            .field("text_bytes", &self.text.len())
            .finish_non_exhaustive()
    }
}
impl<'a> DrawFrame<'a> {
    pub fn decode(bytes: &'a [u8]) -> Result<Self, FrameError> {
        if bytes.len() > MAX_FRAME_BYTES {
            return Err(FrameError::Capacity);
        }
        let mut r = Reader { bytes, offset: 0 };
        if r.u8()? != 1 || r.u8()? != 3 {
            return Err(FrameError::Invalid);
        }
        let sequence = r.u64()?;
        let revision = r.u64()?;
        let columns = r.u16()?;
        let rows = r.u16()?;
        if !(1..=500).contains(&columns) || !(1..=200).contains(&rows) {
            return Err(FrameError::Invalid);
        }
        let wide = match r.u8()? {
            0 => false,
            1 => true,
            _ => return Err(FrameError::Invalid),
        };
        let color_mode = r.u8()?;
        if color_mode > 3 {
            return Err(FrameError::Invalid);
        }
        let palette_count = r.u16()? as usize;
        if !(1..=4096).contains(&palette_count) {
            return Err(FrameError::Invalid);
        }
        let cursor = match r.u8()? {
            0 => None,
            1 => {
                let x = r.u16()?;
                let y = r.u16()?;
                let shape = r.u8()?;
                let visible = r.u8()?;
                if x >= columns || y >= rows || shape > 2 || visible > 1 {
                    return Err(FrameError::Invalid);
                }
                Some(Cursor {
                    x,
                    y,
                    shape,
                    visible: visible == 1,
                })
            }
            _ => return Err(FrameError::Invalid),
        };
        let count = r.u32()? as usize;
        let cells = columns as usize * rows as usize;
        if count == 0 || count > cells {
            return Err(FrameError::Invalid);
        }
        // Even a one-byte glyph needs 9 bytes and a palette needs 3 bytes.
        // Validate this minimum before allocating either table.
        if r.remaining() < count * 9 + palette_count * 3 {
            return Err(FrameError::Invalid);
        }
        let mut palette = Vec::with_capacity(palette_count);
        for _ in 0..palette_count {
            let foreground = r.color(color_mode)?;
            let background = r.color(color_mode)?;
            let modifiers = r.u8()?;
            if modifiers & !31 != 0 {
                return Err(FrameError::Invalid);
            }
            palette.push(PaletteEntry {
                foreground,
                background,
                modifiers,
            });
        }
        let mut glyphs = Vec::with_capacity(count);
        let mut position = 0usize;
        for _ in 0..count {
            let width = r.u16()?;
            let palette_index = r.u16()?;
            let length = r.u32()? as usize;
            let x = position % columns as usize;
            let y = position / columns as usize;
            if width == 0
                || width > 500
                || x + width as usize > columns as usize
                || y >= rows as usize
                || palette_index as usize >= palette_count
                || length == 0
                || length > 262_144
            {
                return Err(FrameError::Invalid);
            }
            let text = std::str::from_utf8(r.take(length)?).map_err(|_| FrameError::Invalid)?;
            if text.chars().any(|c| {
                c.is_control() || matches!(c,'\u{202a}'..='\u{202e}'|'\u{2066}'..='\u{2069}')
            }) {
                return Err(FrameError::Invalid);
            }
            glyphs.push(Glyph {
                x: x as u16,
                y: y as u16,
                width,
                palette: palette_index,
                text,
            });
            position += width as usize;
        }
        if position != cells || r.remaining() != 0 {
            return Err(FrameError::Invalid);
        }
        Ok(Self {
            sequence,
            revision,
            columns,
            rows,
            wide,
            color_mode,
            palette,
            cursor,
            glyphs,
        })
    }
}
struct Reader<'a> {
    bytes: &'a [u8],
    offset: usize,
}
impl<'a> Reader<'a> {
    fn remaining(&self) -> usize {
        self.bytes.len() - self.offset
    }
    fn take(&mut self, n: usize) -> Result<&'a [u8], FrameError> {
        if n > self.remaining() {
            return Err(FrameError::Invalid);
        }
        let result = &self.bytes[self.offset..self.offset + n];
        self.offset += n;
        Ok(result)
    }
    fn u8(&mut self) -> Result<u8, FrameError> {
        Ok(self.take(1)?[0])
    }
    fn u16(&mut self) -> Result<u16, FrameError> {
        Ok(u16::from_be_bytes(self.take(2)?.try_into().unwrap()))
    }
    fn u32(&mut self) -> Result<u32, FrameError> {
        Ok(u32::from_be_bytes(self.take(4)?.try_into().unwrap()))
    }
    fn u64(&mut self) -> Result<u64, FrameError> {
        Ok(u64::from_be_bytes(self.take(8)?.try_into().unwrap()))
    }
    fn color(&mut self, mode: u8) -> Result<Color, FrameError> {
        match self.u8()? {
            0 => Ok(Color::Default),
            1 if mode >= 1 => {
                let i = self.u8()?;
                if i < 16 {
                    Ok(Color::Ansi(i))
                } else {
                    Err(FrameError::Invalid)
                }
            }
            2 if mode >= 2 => Ok(Color::Indexed(self.u8()?)),
            3 if mode == 3 => Ok(Color::Rgb(self.u8()?, self.u8()?, self.u8()?)),
            _ => Err(FrameError::Invalid),
        }
    }
}
