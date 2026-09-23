//! Version-one terminal Port bodies and bounded response packet encoding.
//! The owner validates length headers before allocating command bodies and
//! enforces generations, credits, and lifecycle ordering. This module does no IO.
use crate::frame::{DrawFrame, MAX_FRAME_BYTES};
use crate::input::{Event, Key, Phase, Rejection};
use std::fmt;

pub const MAX_COMMAND_BYTES: usize = MAX_FRAME_BYTES;
/// pass70 B10: the largest clipboard text one Copy command carries (OSC 52
/// sends it base64-encoded, about 87 KiB).
pub const MAX_COPY_BYTES: usize = 65_536;
/// Init flag bits: alternate screen, focus reports, bracketed paste, and
/// (pass70 B10, opt-in) SGR mouse reports for the wheel.
pub const FLAG_MOUSE: u8 = 16;
pub const FLAGS: u8 = 1 | 2 | 4 | FLAG_MOUSE;
pub const MAX_RESPONSE_BYTES: usize = 262_167;

/// A fixed diagnostic that cannot expose rejected input or OS details.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ProtocolError;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Command<'a> {
    Init {
        generation: u64,
        flags: u8,
    },
    Credit {
        generation: u64,
        token: u64,
    },
    Draw {
        sequence: u64,
        body: &'a [u8],
    },
    Shutdown {
        generation: u64,
        token: u64,
    },
    Suspend {
        generation: u64,
        token: u64,
    },
    Resume {
        generation: u64,
        token: u64,
    },
    Copy {
        generation: u64,
        token: u64,
        text: &'a str,
    },
}
impl Command<'_> {
    /// Draw inherits the already initialized connection's generation.
    pub fn generation(&self) -> Option<u64> {
        match self {
            Self::Init { generation, .. }
            | Self::Credit { generation, .. }
            | Self::Shutdown { generation, .. }
            | Self::Suspend { generation, .. }
            | Self::Resume { generation, .. }
            | Self::Copy { generation, .. } => Some(*generation),
            Self::Draw { .. } => None,
        }
    }
    pub fn token(&self) -> Option<u64> {
        match self {
            Self::Credit { token, .. }
            | Self::Shutdown { token, .. }
            | Self::Suspend { token, .. }
            | Self::Resume { token, .. }
            | Self::Copy { token, .. } => Some(*token),
            _ => None,
        }
    }
    pub fn operation(&self) -> &'static str {
        match self {
            Self::Init { .. } => "init",
            Self::Credit { .. } => "credit",
            Self::Draw { .. } => "draw",
            Self::Shutdown { .. } => "shutdown",
            Self::Suspend { .. } => "suspend",
            Self::Resume { .. } => "resume",
            Self::Copy { .. } => "copy",
        }
    }
}
impl fmt::Debug for Command<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut debug = f.debug_struct("Command");
        debug
            .field("operation", &self.operation())
            .field("generation", &self.generation())
            .field("token", &self.token());
        match self {
            Self::Init { flags, .. } => {
                debug.field("flags", flags);
            }
            Self::Draw { sequence, body } => {
                debug
                    .field("sequence", sequence)
                    .field("body_bytes", &body.len());
            }
            Self::Copy { text, .. } => {
                debug.field("text_bytes", &text.len());
            }
            _ => {}
        }
        debug.finish()
    }
}

/// Decodes one complete unframed body, rejecting trailing bytes and unknown
/// values. The drawing route borrows input; temporary validation tables drop
/// before return and the owner retains only its bounded body buffer.
pub fn decode_command(body: &[u8]) -> Result<Command<'_>, ProtocolError> {
    if body.len() > MAX_COMMAND_BYTES || body.len() < 2 || body[0] != 1 {
        return Err(ProtocolError);
    }
    if body[1] == 3 {
        let frame = DrawFrame::decode(body).map_err(|_| ProtocolError)?;
        return Ok(Command::Draw {
            sequence: frame.sequence,
            body,
        });
    }
    if body[1] == 7 {
        return decode_copy(body);
    }
    let expected = match body[1] {
        1 => 11,
        2 | 4 | 5 | 6 => 18,
        _ => return Err(ProtocolError),
    };
    if body.len() != expected {
        return Err(ProtocolError);
    }
    let generation = u64::from_be_bytes(body[2..10].try_into().map_err(|_| ProtocolError)?);
    if body[1] == 1 {
        let flags = body[10];
        if flags & !FLAGS != 0 {
            return Err(ProtocolError);
        }
        return Ok(Command::Init { generation, flags });
    }
    let token = u64::from_be_bytes(body[10..18].try_into().map_err(|_| ProtocolError)?);
    Ok(match body[1] {
        2 => Command::Credit { generation, token },
        4 => Command::Shutdown { generation, token },
        5 => Command::Suspend { generation, token },
        6 => Command::Resume { generation, token },
        _ => return Err(ProtocolError),
    })
}

/// `1, 7, generation, token, length:u32, text`: clipboard text for OSC 52.
/// Line feeds and tabs are kept; every other control, and the bidirectional
/// overrides and isolates, are refused so the clipboard never receives
/// terminal instructions or reordered text.
fn decode_copy(body: &[u8]) -> Result<Command<'_>, ProtocolError> {
    if body.len() < 23 {
        return Err(ProtocolError);
    }
    let generation = u64::from_be_bytes(body[2..10].try_into().map_err(|_| ProtocolError)?);
    let token = u64::from_be_bytes(body[10..18].try_into().map_err(|_| ProtocolError)?);
    let length = u32::from_be_bytes(body[18..22].try_into().map_err(|_| ProtocolError)?) as usize;
    if !(1..=MAX_COPY_BYTES).contains(&length) || body.len() != 22 + length {
        return Err(ProtocolError);
    }
    let text = std::str::from_utf8(&body[22..]).map_err(|_| ProtocolError)?;
    if text.chars().any(|c| {
        (c.is_control() && c != '\n' && c != '\t')
            || matches!(c, '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}')
    }) {
        return Err(ProtocolError);
    }
    Ok(Command::Copy {
        generation,
        token,
        text,
    })
}

/// The OSC 52 sequence that puts `text` on the system clipboard.
pub fn osc52(text: &str) -> Vec<u8> {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(8 + bytes.len().div_ceil(3) * 4);
    out.extend_from_slice(b"\x1b]52;c;");
    for chunk in bytes.chunks(3) {
        let n = (u32::from(chunk[0]) << 16)
            | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
            | u32::from(*chunk.get(2).unwrap_or(&0));
        out.push(ALPHABET[(n >> 18) as usize & 63]);
        out.push(ALPHABET[(n >> 12) as usize & 63]);
        out.push(if chunk.len() > 1 {
            ALPHABET[(n >> 6) as usize & 63]
        } else {
            b'='
        });
        out.push(if chunk.len() > 2 {
            ALPHABET[n as usize & 63]
        } else {
            b'='
        });
    }
    out.push(7);
    out
}

// Length is checked by each public encoder before this sole allocation site.
fn response(tag: u8, generation: u64, body_len: usize) -> Vec<u8> {
    debug_assert!((10..=MAX_RESPONSE_BYTES).contains(&body_len));
    let mut packet = Vec::with_capacity(4 + body_len);
    packet.extend_from_slice(&(body_len as u32).to_be_bytes());
    packet.extend_from_slice(&[1, tag]);
    packet.extend_from_slice(&generation.to_be_bytes());
    packet
}
fn phase_code(phase: Phase) -> u8 {
    match phase {
        Phase::Press => 0,
        Phase::Repeat => 1,
        Phase::Release => 2,
    }
}
fn key_code(key: Key) -> u8 {
    match key {
        Key::Backspace => 0,
        Key::Enter => 1,
        Key::Left => 2,
        Key::Right => 3,
        Key::Up => 4,
        Key::Down => 5,
        Key::Home => 6,
        Key::End => 7,
        Key::PageUp => 8,
        Key::PageDown => 9,
        Key::Tab => 10,
        Key::BackTab => 11,
        Key::Delete => 12,
        Key::Insert => 13,
        Key::Escape => 14,
        Key::Null => 15,
        Key::CapsLock => 16,
        Key::ScrollLock => 17,
        Key::NumLock => 18,
        Key::PrintScreen => 19,
        Key::Pause => 20,
        Key::Menu => 21,
        Key::KeypadBegin => 22,
        Key::F1 => 32,
        Key::F2 => 33,
        Key::F3 => 34,
        Key::F4 => 35,
        Key::F5 => 36,
        Key::F6 => 37,
        Key::F7 => 38,
        Key::F8 => 39,
        Key::F9 => 40,
        Key::F10 => 41,
        Key::F11 => 42,
        Key::F12 => 43,
    }
}
pub fn encode_event(generation: u64, credit: u64, event: &Event) -> Result<Vec<u8>, ProtocolError> {
    let payload_len = match event {
        Event::Key { .. } => 4,
        Event::Text { text, .. } => {
            if !(1..=4096).contains(&text.len()) {
                return Err(ProtocolError);
            }
            5 + text.len()
        }
        Event::Paste(text) => {
            if text.len() > 262_144 {
                return Err(ProtocolError);
            }
            5 + text.len()
        }
        Event::Rejected(_) => 2,
        Event::FocusGained | Event::FocusLost => 1,
        Event::Wheel { .. } => 7,
    };
    let body_len = 18 + payload_len;
    if body_len > MAX_RESPONSE_BYTES {
        return Err(ProtocolError);
    }
    let mut packet = response(17, generation, body_len);
    packet.extend_from_slice(&credit.to_be_bytes());
    match event {
        Event::Key {
            phase,
            key,
            modifiers,
        } => packet.extend_from_slice(&[0, phase_code(*phase), key_code(*key), modifiers.bits()]),
        Event::Text {
            phase,
            text,
            modifiers,
        } => {
            packet.extend_from_slice(&[1, phase_code(*phase), modifiers.bits()]);
            packet.extend_from_slice(&(text.len() as u16).to_be_bytes());
            packet.extend_from_slice(text.as_bytes());
        }
        Event::Paste(text) => {
            packet.push(2);
            packet.extend_from_slice(&(text.len() as u32).to_be_bytes());
            packet.extend_from_slice(text.as_bytes());
        }
        Event::Rejected(reason) => packet.extend_from_slice(&[
            3,
            match reason {
                Rejection::InvalidUtf8 => 0,
                Rejection::TextFragmentTooLarge => 1,
                Rejection::PasteTooLarge => 2,
            },
        ]),
        Event::FocusGained => packet.push(4),
        Event::FocusLost => packet.push(5),
        Event::Wheel {
            up,
            column,
            row,
            modifiers,
        } => {
            packet.extend_from_slice(&[6, u8::from(!*up), modifiers.bits()]);
            packet.extend_from_slice(&column.to_be_bytes());
            packet.extend_from_slice(&row.to_be_bytes());
        }
    }
    Ok(packet)
}
pub fn ready(
    generation: u64,
    columns: u16,
    rows: u16,
    flags: u8,
) -> Result<Vec<u8>, ProtocolError> {
    if columns == 0 || rows == 0 || flags & !FLAGS != 0 {
        return Err(ProtocolError);
    }
    let mut packet = response(16, generation, 15);
    packet.extend_from_slice(&columns.to_be_bytes());
    packet.extend_from_slice(&rows.to_be_bytes());
    packet.push(flags);
    Ok(packet)
}
pub fn painted(generation: u64, sequence: u64, revision: u64) -> Vec<u8> {
    let mut packet = response(18, generation, 26);
    packet.extend_from_slice(&sequence.to_be_bytes());
    packet.extend_from_slice(&revision.to_be_bytes());
    packet
}
/// A valid frame was not painted because its viewport no longer matches the tty.
pub fn skipped(generation: u64, sequence: u64, revision: u64) -> Vec<u8> {
    let mut packet = response(23, generation, 26);
    packet.extend_from_slice(&sequence.to_be_bytes());
    packet.extend_from_slice(&revision.to_be_bytes());
    packet
}
/// External continue requires a FIFO Resume barrier before terminal activation.
/// This notification retires prior in-flight draw/input work without paint ack.
pub fn resume_needed(generation: u64) -> Vec<u8> {
    response(24, generation, 10)
}
pub fn restored(generation: u64, token: u64, suspended: bool) -> Vec<u8> {
    let mut packet = response(19, generation, 19);
    packet.extend_from_slice(&token.to_be_bytes());
    packet.push(u8::from(suspended));
    packet
}
pub fn resize(
    generation: u64,
    credit: u64,
    columns: u16,
    rows: u16,
) -> Result<Vec<u8>, ProtocolError> {
    if columns == 0 || rows == 0 {
        return Err(ProtocolError);
    }
    let mut packet = response(20, generation, 22);
    packet.extend_from_slice(&credit.to_be_bytes());
    packet.extend_from_slice(&columns.to_be_bytes());
    packet.extend_from_slice(&rows.to_be_bytes());
    Ok(packet)
}
pub fn failure(generation: u64, reason: u8) -> Result<Vec<u8>, ProtocolError> {
    if !(1..=6).contains(&reason) {
        return Err(ProtocolError);
    }
    let mut packet = response(21, generation, 11);
    packet.push(reason);
    Ok(packet)
}
