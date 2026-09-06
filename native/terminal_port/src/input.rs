use std::fmt;
pub const MAX_PASTE_BYTES: usize = 262_144;
pub const MAX_SEQUENCE_BYTES: usize = 64;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    Press,
    Repeat,
    Release,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Key {
    Backspace,
    Enter,
    Left,
    Right,
    Up,
    Down,
    Home,
    End,
    PageUp,
    PageDown,
    Tab,
    BackTab,
    Delete,
    Insert,
    Escape,
    Null,
    CapsLock,
    ScrollLock,
    NumLock,
    PrintScreen,
    Pause,
    Menu,
    KeypadBegin,
    F1,
    F2,
    F3,
    F4,
    F5,
    F6,
    F7,
    F8,
    F9,
    F10,
    F11,
    F12,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Modifier {
    Shift,
    Control,
    Alt,
    Super,
    Hyper,
    Meta,
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Modifiers(u8);
impl Modifiers {
    pub const NONE: Self = Self(0);
    pub fn from_bits(bits: u8) -> Option<Self> {
        (bits < 64).then_some(Self(bits))
    }
    pub fn bits(self) -> u8 {
        self.0
    }
    pub fn contains(self, modifier: Modifier) -> bool {
        self.0 & (1 << modifier as u8) != 0
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Rejection {
    InvalidUtf8,
    TextFragmentTooLarge,
    PasteTooLarge,
}
#[derive(Clone, PartialEq, Eq)]
pub enum Event {
    Key {
        phase: Phase,
        key: Key,
        modifiers: Modifiers,
    },
    Text {
        phase: Phase,
        text: String,
        modifiers: Modifiers,
    },
    Paste(String),
    Rejected(Rejection),
    FocusGained,
    FocusLost,
}
impl fmt::Debug for Event {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Key {
                phase,
                key,
                modifiers,
            } => f
                .debug_struct("Key")
                .field("phase", phase)
                .field("key", key)
                .field("modifiers", modifiers)
                .finish(),
            Self::Text {
                phase,
                text,
                modifiers,
            } => f
                .debug_struct("Text")
                .field("phase", phase)
                .field("bytes", &text.len())
                .field("modifiers", modifiers)
                .finish(),
            Self::Paste(text) => f.debug_struct("Paste").field("bytes", &text.len()).finish(),
            Self::Rejected(reason) => f.debug_tuple("Rejected").field(reason).finish(),
            Self::FocusGained => f.write_str("FocusGained"),
            Self::FocusLost => f.write_str("FocusLost"),
        }
    }
}
#[derive(Debug, PartialEq, Eq)]
pub struct Step {
    pub consumed: usize,
    pub event: Option<Event>,
}
const PASTE_END: &[u8; 6] = b"\x1b[201~";

#[derive(Default)]
enum State {
    #[default]
    Ground,
    Escape,
    EscapeIntermediate,
    Utf8 {
        bytes: [u8; 4],
        len: usize,
        expected: usize,
        modifiers: Modifiers,
    },
    InvalidContinuations,
    Sequence {
        bytes: [u8; MAX_SEQUENCE_BYTES],
        len: usize,
        ss3: bool,
    },
    DiscardSequence,
    ControlString {
        osc: bool,
        escape: bool,
    },
    Paste {
        matched: usize,
        discard: bool,
    },
}

/// A pure incremental parser with no clock, IO, queue, or environment access.
/// The terminal owner supplies the 40 ms standalone Escape deadline and calls
/// `expire_escape`. It must retain an unread suffix until `advance` consumes it.
#[derive(Default)]
pub struct InputParser {
    state: State,
    paste: Vec<u8>,
}
impl fmt::Debug for InputParser {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let name = match self.state {
            State::Ground => "ground",
            State::Escape => "escape",
            State::EscapeIntermediate => "escape_intermediate",
            State::Utf8 { .. } => "utf8",
            State::InvalidContinuations => "invalid_continuations",
            State::Sequence { .. } => "sequence",
            State::DiscardSequence => "discard_sequence",
            State::ControlString { .. } => "control_string",
            State::Paste { discard: true, .. } => "discard_paste",
            State::Paste { .. } => "paste",
        };
        f.debug_struct("InputParser")
            .field("state", &name)
            .field("retained_bytes", &self.retained_bytes())
            .field("retained_capacity", &self.retained_capacity())
            .finish()
    }
}
impl InputParser {
    pub fn new() -> Self {
        Self::default()
    }

    /// Returns at most one event and the exact consumed prefix. A malformed
    /// incomplete UTF-8 scalar may reject with zero consumed bytes: its state is
    /// reset first, so the next call processes the valid byte at the boundary.
    pub fn advance(&mut self, bytes: &[u8]) -> Step {
        let mut consumed = 0;
        while consumed < bytes.len() {
            let byte = bytes[consumed];
            let state = std::mem::take(&mut self.state);
            let mut event = None;
            match state {
                State::Ground => event = self.ordinary(byte, Modifiers::NONE),
                State::Escape => match byte {
                    b'[' => self.sequence(false),
                    b'O' => self.sequence(true),
                    b']' => {
                        self.state = State::ControlString {
                            osc: true,
                            escape: false,
                        }
                    }
                    b'P' | b'X' | b'_' | b'^' => {
                        self.state = State::ControlString {
                            osc: false,
                            escape: false,
                        }
                    }
                    0x1b => {
                        self.state = State::Escape;
                        event = Some(key_event(Key::Escape, Phase::Press, Modifiers::NONE));
                    }
                    0x21..=0x2f => self.state = State::EscapeIntermediate,
                    _ => event = self.ordinary(byte, Modifiers(4)),
                },
                State::EscapeIntermediate => {
                    if !(0x30..=0x7e).contains(&byte) {
                        self.state = State::EscapeIntermediate;
                    }
                }
                State::Utf8 {
                    mut bytes,
                    mut len,
                    expected,
                    modifiers,
                } => {
                    if byte & 0xc0 != 0x80 {
                        return Step {
                            consumed,
                            event: Some(Event::Rejected(Rejection::InvalidUtf8)),
                        };
                    }
                    bytes[len] = byte;
                    len += 1;
                    if len == expected {
                        event = Some(match std::str::from_utf8(&bytes[..len]) {
                            Ok(text) => Event::Text {
                                phase: Phase::Press,
                                text: text.into(),
                                modifiers,
                            },
                            Err(_) => Event::Rejected(Rejection::InvalidUtf8),
                        });
                    } else {
                        self.state = State::Utf8 {
                            bytes,
                            len,
                            expected,
                            modifiers,
                        };
                    }
                }
                State::InvalidContinuations => {
                    if byte & 0xc0 == 0x80 {
                        self.state = State::InvalidContinuations;
                    } else {
                        event = self.ordinary(byte, Modifiers::NONE);
                    }
                }
                State::Sequence {
                    mut bytes,
                    mut len,
                    ss3,
                } => {
                    if (0x40..=0x7e).contains(&byte) {
                        if len < MAX_SEQUENCE_BYTES {
                            if !ss3 && byte == b'~' && &bytes[..len] == b"200" {
                                self.state = State::Paste {
                                    matched: 0,
                                    discard: false,
                                };
                            } else {
                                event = decode_sequence(&bytes[..len], byte, ss3);
                            }
                        }
                    } else if len < MAX_SEQUENCE_BYTES && (0x20..=0x3f).contains(&byte) {
                        bytes[len] = byte;
                        len += 1;
                        self.state = State::Sequence { bytes, len, ss3 };
                    } else {
                        self.state = State::DiscardSequence;
                    }
                }
                State::DiscardSequence => {
                    if !(0x40..=0x7e).contains(&byte) {
                        self.state = State::DiscardSequence;
                    }
                }
                State::ControlString { osc, escape } => {
                    if !(osc && byte == 7 || escape && byte == b'\\') {
                        self.state = State::ControlString {
                            osc,
                            escape: byte == 0x1b,
                        };
                    }
                }
                State::Paste {
                    mut matched,
                    mut discard,
                } => {
                    if byte == PASTE_END[matched] {
                        matched += 1;
                        if matched == PASTE_END.len() {
                            if !discard {
                                event = Some(
                                    match String::from_utf8(std::mem::take(&mut self.paste)) {
                                        Ok(text) => Event::Paste(text),
                                        Err(_) => Event::Rejected(Rejection::InvalidUtf8),
                                    },
                                );
                            }
                        } else {
                            self.state = State::Paste { matched, discard };
                        }
                    } else {
                        // This terminator has no proper prefix/suffix overlap.
                        // A mismatching ESC starts the next candidate immediately.
                        let next_matched = usize::from(byte == PASTE_END[0]);
                        if !discard {
                            let extra = matched + usize::from(next_matched == 0);
                            if extra > MAX_PASTE_BYTES - self.paste.len() {
                                self.paste = Vec::new();
                                discard = true;
                                event = Some(Event::Rejected(Rejection::PasteTooLarge));
                            } else {
                                self.reserve_paste(extra);
                                self.paste.extend_from_slice(&PASTE_END[..matched]);
                                if next_matched == 0 {
                                    self.paste.push(byte);
                                }
                            }
                        }
                        self.state = State::Paste {
                            matched: next_matched,
                            discard,
                        };
                    }
                }
            }
            consumed += 1;
            if event.is_some() {
                return Step { consumed, event };
            }
        }
        Step {
            consumed,
            event: None,
        }
    }

    fn reserve_paste(&mut self, extra: usize) {
        let needed = self.paste.len() + extra; // Caller checked the bound first.
        if needed > self.paste.capacity() {
            let target = needed
                .max(self.paste.capacity().saturating_mul(2))
                .max(64)
                .min(MAX_PASTE_BYTES);
            self.paste.reserve_exact(target - self.paste.len());
        }
    }

    fn sequence(&mut self, ss3: bool) {
        self.state = State::Sequence {
            bytes: [0; MAX_SEQUENCE_BYTES],
            len: 0,
            ss3,
        };
    }

    fn ordinary(&mut self, byte: u8, modifiers: Modifiers) -> Option<Event> {
        let key = match byte {
            0 => Some(Key::Null),
            b'\r' | b'\n' => Some(Key::Enter),
            b'\t' => Some(Key::Tab),
            8 | 127 => Some(Key::Backspace),
            _ => None,
        };
        if let Some(key) = key {
            return Some(key_event(key, Phase::Press, modifiers));
        }
        match byte {
            0x1b => {
                self.state = State::Escape;
                None
            }
            1..=26 => Some(text_event(
                char::from(b'a' + byte - 1),
                Phase::Press,
                Modifiers(modifiers.0 | 2),
            )),
            28..=31 => Some(text_event(
                char::from(byte + 64),
                Phase::Press,
                Modifiers(modifiers.0 | 2),
            )),
            0x20..=0x7e => Some(text_event(char::from(byte), Phase::Press, modifiers)),
            0xc0..=0xf7 => {
                let expected = if byte < 0xe0 {
                    2
                } else if byte < 0xf0 {
                    3
                } else {
                    4
                };
                self.state = State::Utf8 {
                    bytes: [byte, 0, 0, 0],
                    len: 1,
                    expected,
                    modifiers,
                };
                None
            }
            _ => {
                self.state = State::InvalidContinuations;
                Some(Event::Rejected(Rejection::InvalidUtf8))
            }
        }
    }

    /// Owner clock starts only when parsing actually reaches an ambiguous ESC.
    pub fn pending_escape(&self) -> bool {
        matches!(self.state, State::Escape)
    }

    /// Only an ambiguous standalone Escape is eligible for the owner's timeout.
    pub fn expire_escape(&mut self) -> Option<Event> {
        if matches!(self.state, State::Escape) {
            self.state = State::Ground;
            Some(key_event(Key::Escape, Phase::Press, Modifiers::NONE))
        } else {
            None
        }
    }

    /// Resets at EOF. Incomplete paste/control strings never become text.
    pub fn finish(&mut self) -> Option<Event> {
        let event = match self.state {
            State::Escape => Some(key_event(Key::Escape, Phase::Press, Modifiers::NONE)),
            State::Utf8 { .. } => Some(Event::Rejected(Rejection::InvalidUtf8)),
            _ => None,
        };
        self.state = State::Ground;
        self.paste = Vec::new();
        event
    }

    /// Content bytes retained across calls, including a pending paste terminator.
    pub fn retained_bytes(&self) -> usize {
        self.paste.len()
            + match self.state {
                State::Utf8 { len, .. } | State::Sequence { len, .. } => len,
                State::Paste { matched, .. } => matched,
                State::Escape => 1,
                State::ControlString { escape: true, .. } => 1,
                _ => 0,
            }
    }

    /// Dynamic payload capacity plus the largest fixed parser byte buffer.
    /// State variants share storage; no event payload/queue is retained here.
    pub fn retained_capacity(&self) -> usize {
        self.paste.capacity() + MAX_SEQUENCE_BYTES
    }
}

fn key_event(key: Key, phase: Phase, modifiers: Modifiers) -> Event {
    Event::Key {
        phase,
        key,
        modifiers,
    }
}
fn text_event(scalar: char, phase: Phase, modifiers: Modifiers) -> Event {
    Event::Text {
        phase,
        text: scalar.to_string(),
        modifiers,
    }
}
fn decimal(bytes: &[u8]) -> Option<u32> {
    if bytes.is_empty() {
        return None;
    }
    bytes.iter().try_fold(0u32, |n, b| {
        if !b.is_ascii_digit() {
            return None;
        }
        n.checked_mul(10)?.checked_add(u32::from(b - b'0'))
    })
}
fn modifiers(parameter: &[u8]) -> Option<Modifiers> {
    let bits = decimal(parameter)?.checked_sub(1)?;
    // Kitty lock-state bits are not UI.Input modifiers; discard them.
    if bits > 255 {
        return None;
    }
    let bits = bits as u8 & 63;
    // Terminal encoding orders Shift, Alt, Control; UI.Input uses Shift, Control, Alt.
    Some(Modifiers(
        (bits & !6) | ((bits & 2) << 1) | ((bits & 4) >> 1),
    ))
}
fn decode_sequence(params: &[u8], final_byte: u8, ss3: bool) -> Option<Event> {
    if !ss3 && final_byte == b'u' {
        return decode_csi_u(params);
    }
    if !ss3 && params.is_empty() {
        if final_byte == b'I' {
            return Some(Event::FocusGained);
        }
        if final_byte == b'O' {
            return Some(Event::FocusLost);
        }
    }
    let mut fields = params.split(|b| *b == b';');
    let first = fields.next()?;
    let modification = fields.next();
    if fields.next().is_some() {
        return None;
    }
    let mods = match modification {
        Some(value) => modifiers(value)?,
        None => Modifiers::NONE,
    };
    let code = if first.is_empty() { 1 } else { decimal(first)? };
    let key = if final_byte == b'~' && !ss3 {
        match code {
            1 | 7 => Key::Home,
            2 => Key::Insert,
            3 => Key::Delete,
            4 | 8 => Key::End,
            5 => Key::PageUp,
            6 => Key::PageDown,
            11 => Key::F1,
            12 => Key::F2,
            13 => Key::F3,
            14 => Key::F4,
            15 => Key::F5,
            17 => Key::F6,
            18 => Key::F7,
            19 => Key::F8,
            20 => Key::F9,
            21 => Key::F10,
            23 => Key::F11,
            24 => Key::F12,
            _ => return None,
        }
    } else {
        if code != 1 {
            return None;
        }
        match final_byte {
            b'A' => Key::Up,
            b'B' => Key::Down,
            b'C' => Key::Right,
            b'D' => Key::Left,
            b'H' => Key::Home,
            b'F' => Key::End,
            b'E' => Key::KeypadBegin,
            b'Z' => Key::BackTab,
            b'P' => Key::F1,
            b'Q' => Key::F2,
            b'R' => Key::F3,
            b'S' => Key::F4,
            _ => return None,
        }
    };
    Some(key_event(key, Phase::Press, mods))
}
fn decode_csi_u(params: &[u8]) -> Option<Event> {
    let mut fields = params.split(|b| *b == b';');
    let code = decimal(fields.next()?)?;
    let mut phase = Phase::Press;
    let mut mods = Modifiers::NONE;
    if let Some(value) = fields.next() {
        let mut pieces = value.split(|b| *b == b':');
        mods = modifiers(pieces.next()?)?;
        if let Some(value) = pieces.next() {
            phase = match decimal(value)? {
                1 => Phase::Press,
                2 => Phase::Repeat,
                3 => Phase::Release,
                _ => return None,
            };
        }
        if pieces.next().is_some() {
            return None;
        }
    }
    if fields.next().is_some() {
        return None;
    }
    let key = match code {
        0 => Key::Null,
        8 | 127 | 57347 => Key::Backspace,
        9 | 57346 => Key::Tab,
        10 | 13 | 57345 => Key::Enter,
        27 | 57344 => Key::Escape,
        57348 => Key::Insert,
        57349 => Key::Delete,
        57350 => Key::Left,
        57351 => Key::Right,
        57352 => Key::Up,
        57353 => Key::Down,
        57354 => Key::PageUp,
        57355 => Key::PageDown,
        57356 => Key::Home,
        57357 => Key::End,
        57358 => Key::CapsLock,
        57359 => Key::ScrollLock,
        57360 => Key::NumLock,
        57361 => Key::PrintScreen,
        57362 => Key::Pause,
        57363 => Key::Menu,
        57364 => Key::F1,
        57365 => Key::F2,
        57366 => Key::F3,
        57367 => Key::F4,
        57368 => Key::F5,
        57369 => Key::F6,
        57370 => Key::F7,
        57371 => Key::F8,
        57372 => Key::F9,
        57373 => Key::F10,
        57374 => Key::F11,
        57375 => Key::F12,
        57427 => Key::KeypadBegin,
        _ => {
            let scalar = char::from_u32(code)?;
            // Reserve Kitty's complete functional-key range; unsupported keys
            // must never leak private-use characters into the editor.
            if scalar.is_control() || (57344..=63743).contains(&code) {
                return None;
            }
            return Some(text_event(scalar, phase, mods));
        }
    };
    Some(key_event(key, phase, mods))
}
