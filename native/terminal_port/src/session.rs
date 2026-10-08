//! One writer, one input credit, one command body, one fixed tty-read buffer.
use crate::{
    guard,
    input::{Event, InputParser},
    output::Painter,
    protocol::{self, Command, NotifyKind},
    tty::{self, BufferedWriter, FdWriter},
};

/// cli020 D2: how long the start-up keyboard probe waits for the terminal's
/// answers before it treats the kitty protocol as unavailable.
const PROBE_WAIT: Duration = Duration::from_millis(500);
use std::{
    io::{self, Write},
    os::{fd::RawFd, unix::net::UnixStream},
    time::{Duration, Instant},
};

#[derive(Default)]
struct Framer {
    header: [u8; 4],
    header_used: usize,
    body: Vec<u8>,
    body_used: usize,
}
enum ReadFrame {
    Pending,
    Eof,
    Body(Vec<u8>),
}
impl Framer {
    fn read(&mut self) -> Result<ReadFrame, u8> {
        if self.header_used < 4 {
            match read_fd(0, &mut self.header[self.header_used..]).map_err(|_| 4)? {
                None => return Ok(ReadFrame::Pending),
                Some(0) => return Ok(ReadFrame::Eof),
                Some(n) => self.header_used += n,
            }
            if self.header_used < 4 {
                return Ok(ReadFrame::Pending);
            }
            let length = u32::from_be_bytes(self.header) as usize;
            if !(2..=protocol::MAX_COMMAND_BYTES).contains(&length) {
                return Err(1);
            }
            // Header admission precedes the only body allocation. No packet queue.
            self.body = vec![0; length];
        }
        match read_fd(0, &mut self.body[self.body_used..]).map_err(|_| 4)? {
            None => return Ok(ReadFrame::Pending),
            Some(0) => return Ok(ReadFrame::Eof),
            Some(n) => self.body_used += n,
        }
        if self.body_used == self.body.len() {
            self.header_used = 0;
            self.body_used = 0;
            Ok(ReadFrame::Body(std::mem::take(&mut self.body)))
        } else {
            Ok(ReadFrame::Pending)
        }
    }
}
fn read_fd(fd: RawFd, bytes: &mut [u8]) -> io::Result<Option<usize>> {
    let n = unsafe { libc::read(fd, bytes.as_mut_ptr().cast(), bytes.len()) };
    if n >= 0 {
        return Ok(Some(n as usize));
    }
    let e = io::Error::last_os_error();
    if matches!(
        e.kind(),
        io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
    ) {
        Ok(None)
    } else {
        Err(e)
    }
}
struct Session<'a> {
    guard: &'a mut UnixStream,
    tty: RawFd,
    stdout: FdWriter,
    output: BufferedWriter<FdWriter>,
    generation: Option<u64>,
    flags: u8,
    active: bool,
    externally_suspended: bool,
    awaiting_resume: bool,
    token: u64,
    sequence: u64,
    credit: Option<u64>,
    painter: Painter,
    parser: InputParser,
    input: [u8; 4096],
    start: usize,
    end: usize,
    escape_since: Option<Instant>,
    dimensions: (u16, u16),
    pending_resize: Option<(u16, u16)>,
    // Bytes queued before raw mode began, typed under cooked input (Q17).
    cooked: usize,
    // cli020 D2: the start-up probe (`CSI ? u`, `CSI c`) is waiting since then;
    // Ready is sent when it ends.
    probe: Option<Instant>,
    probed: bool,
    kitty_seen: bool,
    // cli020 D2: the kitty disambiguate mode is on (Ready reports it).
    enhanced: bool,
    // cli020 D3: the last window title asked for, and whether the terminal's
    // own title is saved (`CSI 22;2 t`) and must be restored (`CSI 23;2 t`).
    title: Option<String>,
    title_saved: bool,
    // cli020 D5: an arrow burst read as the wheel, waiting for input credit.
    pending_scroll: Option<Event>,
    // cli020 D4: the session runs inside tmux (`TMUX` set at start), so OSC 52
    // goes through tmux's DCS passthrough.
    tmux: bool,
}
impl Session<'_> {
    fn send(&mut self, bytes: Vec<u8>) -> Result<(), u8> {
        self.stdout
            .write_all(&bytes)
            .and_then(|()| self.stdout.flush())
            .map_err(|_| 5)
    }
    fn activate(&mut self) -> Result<(), u8> {
        guard::modes(self.guard, Some(self.flags)).map_err(|_| 2)?;
        // Everything queued at this moment was typed before the terminal was
        // raw (while swarmcode started, or in the shell while suspended).
        self.cooked = tty::pending(self.tty).unwrap_or(0);
        self.active = true;
        self.painter.invalidate();
        self.dimensions = tty::size(self.tty).map_err(|_| 2)?;
        self.pending_resize = None;
        self.escape_since = self.parser.pending_escape().then(Instant::now);
        // cli020 D2: a resume pushes the kitty mode the probe found again.
        if self.enhanced {
            guard::kitty(self.guard).map_err(|_| 2)?;
        }
        // cli020 D3: and puts the session's title back.
        if let Some(title) = self.title.take() {
            self.write_title(&title);
            self.title = Some(title);
        }
        // cli020 D2: once, after entering the alternate screen, ask whether
        // the kitty keyboard protocol is there; the DA1 answer ends the wait.
        if !self.probed && self.flags & 1 != 0 {
            self.probed = true;
            if self
                .output
                .write_all(b"\x1b[?u\x1b[c")
                .and_then(|()| self.output.flush())
                .is_ok()
            {
                self.probe = Some(Instant::now());
                return Ok(());
            }
            self.output.discard();
        }
        self.ready()
    }
    fn ready(&mut self) -> Result<(), u8> {
        let enhanced = if self.enhanced {
            protocol::READY_ENHANCED_KEYS
        } else {
            0
        };
        self.send(
            protocol::ready(
                self.generation.unwrap(),
                self.dimensions.0,
                self.dimensions.1,
                self.flags | enhanced,
            )
            .map_err(|_| 2)?,
        )
    }
    /// cli020 D2: reads the probe's answers without an input credit (nothing
    /// is sent to the owner before Ready), keeping any typeahead in order.
    fn probe_step(&mut self, since: Instant) -> Result<(), u8> {
        if self.start > 0 {
            self.input.copy_within(self.start..self.end, 0);
            self.end -= self.start;
            self.start = 0;
        }
        let mut finished = since.elapsed() >= PROBE_WAIT;
        if self.end < self.input.len() {
            match read_fd(self.tty, &mut self.input[self.end..]).map_err(|_| 4)? {
                None => (),
                Some(0) => finished = true,
                Some(n) => {
                    let end = self.end + n;
                    self.cooked =
                        crate::input::typeahead_enter(&mut self.input[self.end..end], self.cooked);
                    self.end = end;
                }
            }
        } else {
            finished = true;
        }
        let (end, found) = crate::input::take_probe_replies(&mut self.input[..self.end]);
        self.end = end;
        self.kitty_seen |= found.kitty_flags.is_some();
        if found.attributes || finished {
            self.probe = None;
            if self.kitty_seen && guard::kitty(self.guard).is_ok() {
                self.enhanced = true;
            }
            self.ready()?;
        }
        Ok(())
    }
    /// cli020 D3: an OSC 2 title, saving the terminal's own title first.
    fn write_title(&mut self, title: &str) {
        let mut bytes = Vec::with_capacity(16 + title.len());
        if !self.title_saved {
            bytes.extend_from_slice(b"\x1b[22;2t");
        }
        bytes.extend_from_slice(&protocol::notify_bytes(NotifyKind::Title, title));
        if self
            .output
            .write_all(&bytes)
            .and_then(|()| self.output.flush())
            .is_ok()
        {
            self.title_saved = true;
        } else {
            self.output.discard();
            self.painter.invalidate();
        }
    }
    /// cli020 D3: the terminal's own title back, before the modes are restored.
    /// cli020 R2: part of restoration, so bounded like the guard's writes
    /// (the frame writer waits for a slow terminal; this one never hangs a
    /// shutdown on a terminal that stopped reading). Callers discard the
    /// frame buffer first.
    fn restore_title(&mut self) {
        if self.title_saved {
            self.title_saved = false;
            let _ = FdWriter::new(self.tty, true).write_all(b"\x1b[23;2t");
        }
    }
    fn suspend(&mut self) -> Result<(), u8> {
        self.credit = None;
        self.output.discard();
        self.escape_since = None;
        self.probe = None;
        self.pending_scroll = None;
        self.restore_title();
        guard::modes(self.guard, None)?;
        self.active = false;
        self.painter.invalidate();
        Ok(())
    }
    fn command(&mut self, bytes: &[u8]) -> Result<bool, u8> {
        let command = protocol::decode_command(bytes).map_err(|_| 1)?;
        if self.generation.is_none() {
            if let Command::Init { generation, flags } = command {
                self.generation = Some(generation);
                self.flags = flags;
                self.activate()?;
                return Ok(false);
            }
            return Err(1);
        }
        if command
            .generation()
            .is_some_and(|generation| Some(generation) != self.generation)
        {
            return Err(1);
        }
        if let Some(token) = command.token() {
            if token <= self.token {
                return Err(1);
            }
            self.token = token;
        }
        let generation = self.generation.unwrap();
        match command {
            Command::Init { .. } => return Err(1),
            Command::Credit { token, .. } => {
                if self.awaiting_resume {
                    return Ok(false);
                }
                if !self.active || self.credit.is_some() {
                    return Err(1);
                }
                self.credit = Some(token);
            }
            Command::Draw { sequence, body } => {
                if sequence <= self.sequence {
                    return Err(1);
                }
                if self.awaiting_resume {
                    self.sequence = sequence;
                    return Ok(false);
                }
                if !self.active {
                    return Err(1);
                }
                let frame = crate::frame::DrawFrame::decode(body).map_err(|_| 1)?;
                let dimensions = tty::size(self.tty).map_err(|_| 4)?;
                if dimensions != self.dimensions {
                    self.dimensions = dimensions;
                    self.pending_resize = Some(dimensions);
                }
                if (frame.columns, frame.rows) != dimensions {
                    self.sequence = sequence;
                    self.dimensions = dimensions;
                    self.pending_resize = Some(dimensions);
                    self.painter.invalidate();
                    self.send(protocol::skipped(generation, sequence, frame.revision))?;
                    return Ok(false);
                }
                let meta = self.painter.draw(body, &mut self.output).map_err(|_| 3)?;
                self.sequence = sequence;
                self.send(protocol::painted(generation, sequence, meta.revision))?;
            }
            Command::Shutdown { token, .. } => {
                self.suspend()?;
                self.send(protocol::restored(generation, token, false))?;
                return Ok(true);
            }
            Command::Suspend { token, .. } => {
                if !self.active {
                    return Err(1);
                }
                self.suspend()?;
                self.send(protocol::restored(generation, token, true))?;
            }
            Command::Resume { .. } => {
                if self.active || self.externally_suspended {
                    return Err(1);
                }
                self.awaiting_resume = false;
                self.activate()?;
            }
            // pass73 T9: wheel reports on or off without leaving raw mode.
            // The flags keep the choice, so a resume (after the editor or a
            // shell suspend) activates with it and its ready reports it.
            Command::Mouse { on, .. } => {
                let flags = if on {
                    self.flags | protocol::FLAG_MOUSE
                } else {
                    self.flags & !protocol::FLAG_MOUSE
                };
                if flags != self.flags {
                    self.flags = flags;
                    if self.active && !self.awaiting_resume {
                        guard::mouse(self.guard, on)?;
                    }
                }
            }
            // cli020 D3: bell, notification or title between frames. A
            // suspended terminal is the shell's: only the title is kept, for
            // the resume.
            Command::Notify { kind, text, .. } => {
                let live = self.active && !self.awaiting_resume && self.probe.is_none();
                match kind {
                    NotifyKind::Title => {
                        if live {
                            self.write_title(text);
                        }
                        self.title = Some(text.to_owned());
                    }
                    _ if live => {
                        let bytes = protocol::notify_bytes(kind, text);
                        if self
                            .output
                            .write_all(&bytes)
                            .and_then(|()| self.output.flush())
                            .is_err()
                        {
                            self.output.discard();
                            self.painter.invalidate();
                        }
                    }
                    _ => (),
                }
            }
            // cli020 D11: Ctrl-L. The painter forgets what is on screen, so
            // the next frame repaints every cell.
            Command::Redraw { .. } => self.painter.invalidate(),
            // pass70 B10: OSC 52 between frames. A suspended terminal belongs
            // to the shell, so the text is dropped; a failed write only costs
            // the next frame a full repaint.
            Command::Copy { text, .. } => {
                if self.active && !self.awaiting_resume {
                    let sequence = if self.tmux {
                        protocol::osc52_tmux(text)
                    } else {
                        protocol::osc52(text)
                    };
                    if self
                        .output
                        .write_all(&sequence)
                        .and_then(|()| self.output.flush())
                        .is_err()
                    {
                        self.output.discard();
                        self.painter.invalidate();
                    }
                }
            }
        }
        Ok(false)
    }
    fn input(&mut self) -> Result<(), u8> {
        let Some(token) = self.credit else {
            return Ok(());
        };
        let generation = self.generation.unwrap();
        if let Some((columns, rows)) = self.pending_resize.take() {
            self.credit = None;
            return self.send(protocol::resize(generation, token, columns, rows).map_err(|_| 1)?);
        }
        if let Some(event) = self.pending_scroll.take() {
            self.credit = None;
            return self.send(protocol::encode_event(generation, token, &event).map_err(|_| 1)?);
        }
        if self.start < self.end {
            let step = self.parser.advance(&self.input[self.start..self.end]);
            self.start += step.consumed;
            self.escape_since = if self.parser.pending_escape() {
                Some(Instant::now())
            } else {
                None
            };
            if let Some(event) = step.event {
                self.credit = None;
                return self
                    .send(protocol::encode_event(generation, token, &event).map_err(|_| 1)?);
            }
        }
        Ok(())
    }
    fn run(&mut self) -> Result<(), u8> {
        let mut framer = Framer::default();
        let mut size_time = Instant::now();
        loop {
            if guard::terminating() {
                return Ok(());
            }
            match guard::take_signal() {
                libc::SIGTSTP if self.active => {
                    self.suspend()?;
                    self.externally_suspended = true;
                    // The guard stays runnable to restore/reap us if killed while stopped.
                    unsafe {
                        libc::raise(libc::SIGSTOP);
                    }
                    // Handle CONT and establish its barrier before queued parent
                    // commands can be interpreted against the suspended state.
                    continue;
                }
                libc::SIGCONT if self.externally_suspended => {
                    self.externally_suspended = false;
                    self.awaiting_resume = true;
                    self.send(protocol::resume_needed(self.generation.unwrap()))?;
                }
                _ => (),
            }
            if self.active && size_time.elapsed() >= Duration::from_millis(100) {
                let dimensions = tty::size(self.tty).map_err(|_| 4)?;
                if dimensions != self.dimensions {
                    self.dimensions = dimensions;
                    self.pending_resize = Some(dimensions);
                }
                size_time = Instant::now();
            }
            if let Some(since) = self.probe {
                self.probe_step(since)?;
            } else if self.active {
                self.input()?;
            }
            let read_tty = self.active && self.credit.is_some() && self.start == self.end;
            let buffered = self.active && self.credit.is_some() && self.start < self.end;
            let mut fds = [
                libc::pollfd {
                    fd: 0,
                    events: libc::POLLIN,
                    revents: 0,
                },
                libc::pollfd {
                    fd: if read_tty { self.tty } else { -1 },
                    events: libc::POLLIN,
                    revents: 0,
                },
            ];
            let n = unsafe { libc::poll(fds.as_mut_ptr(), 2, if buffered { 0 } else { 10 }) };
            if n < 0 {
                if io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(4);
            }
            // Parent commands/lifecycle take precedence over terminal reads.
            if fds[0].revents != 0 {
                match framer.read()? {
                    ReadFrame::Eof => return Ok(()),
                    ReadFrame::Body(body) => {
                        if self.command(&body)? {
                            return Ok(());
                        }
                    }
                    ReadFrame::Pending => (),
                }
            }
            if fds[1].revents != 0 && self.active && self.credit.is_some() && self.start == self.end
            {
                match read_fd(self.tty, &mut self.input).map_err(|_| 4)? {
                    None => (),
                    Some(0) => {
                        if let Some(event) = self.parser.finish() {
                            let token = self.credit.take().unwrap();
                            self.send(
                                protocol::encode_event(self.generation.unwrap(), token, &event)
                                    .map_err(|_| 1)?,
                            )?;
                        }
                        return Ok(());
                    }
                    Some(n) => {
                        self.cooked =
                            crate::input::typeahead_enter(&mut self.input[..n], self.cooked);
                        self.start = 0;
                        self.end = n;
                        // cli020 D5: with no mouse reports, alternate scroll
                        // sends the wheel as a burst of identical arrows.
                        if self.flags & 1 != 0 && self.flags & protocol::FLAG_MOUSE == 0 {
                            if let Some((up, count)) = crate::input::arrow_burst(&self.input[..n]) {
                                self.pending_scroll = Some(Event::Scroll { up, count });
                                self.end = 0;
                            }
                        }
                    }
                }
            }
            // Never let time spent waiting for input credit expire bytes that
            // have not reached the parser. Read queued suffixes before deciding
            // a parsed standalone ESC is old enough to emit.
            if read_tty
                && self.active
                && self.credit.is_some()
                && self.start == self.end
                && self
                    .escape_since
                    .is_some_and(|t| t.elapsed() >= Duration::from_millis(40))
            {
                match read_fd(self.tty, &mut self.input).map_err(|_| 4)? {
                    Some(0) => return Ok(()),
                    Some(n) => {
                        self.cooked =
                            crate::input::typeahead_enter(&mut self.input[..n], self.cooked);
                        self.start = 0;
                        self.end = n;
                    }
                    None => {
                        if let Some(event) = self.parser.expire_escape() {
                            self.escape_since = None;
                            let token = self.credit.take().unwrap();
                            self.send(
                                protocol::encode_event(self.generation.unwrap(), token, &event)
                                    .map_err(|_| 1)?,
                            )?;
                        }
                    }
                }
            }
        }
    }
}
pub fn run(guard: &mut UnixStream, tty: RawFd) -> i32 {
    if tty::nonblocking(0).is_err() || tty::nonblocking(1).is_err() {
        return 1;
    }
    let mut session = Session {
        guard,
        tty,
        stdout: FdWriter::new(1, true),
        // cli020 R2: a terminal that stops reading for a while delays the
        // frame; only a gone terminal or termination ends the write.
        output: BufferedWriter::new(FdWriter::patient(tty)),
        generation: None,
        flags: 0,
        active: false,
        externally_suspended: false,
        awaiting_resume: false,
        token: 0,
        sequence: 0,
        credit: None,
        painter: Painter::new(),
        parser: InputParser::new(),
        input: [0; 4096],
        start: 0,
        end: 0,
        escape_since: None,
        dimensions: (0, 0),
        pending_resize: None,
        cooked: 0,
        probe: None,
        probed: false,
        kitty_seen: false,
        enhanced: false,
        title: None,
        title_saved: false,
        pending_scroll: None,
        tmux: std::env::var_os("TMUX").is_some_and(|value| !value.is_empty()),
    };
    let result = session.run();
    // This synchronous handshake also handles initialization failure. The guard
    // remains the emergency backstop for panic, abrupt writer death or bad pipes.
    session.output.discard();
    session.restore_title();
    let restored = guard::modes(session.guard, None);
    let reason = match (result, restored) {
        (_, Err(_)) => Some(6),
        (Err(reason), _) => Some(reason),
        _ => None,
    };
    if let Some(reason) = reason {
        let _ = session.send(protocol::failure(session.generation.unwrap_or(0), reason).unwrap());
        1
    } else {
        0
    }
}
