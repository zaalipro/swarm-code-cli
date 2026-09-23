//! One writer, one input credit, one command body, one fixed tty-read buffer.
use crate::{
    guard,
    input::InputParser,
    output::Painter,
    protocol::{self, Command},
    tty::{self, BufferedWriter, FdWriter},
};
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
        self.active = true;
        self.painter.invalidate();
        self.dimensions = tty::size(self.tty).map_err(|_| 2)?;
        self.pending_resize = None;
        self.escape_since = self.parser.pending_escape().then(Instant::now);
        self.send(
            protocol::ready(
                self.generation.unwrap(),
                self.dimensions.0,
                self.dimensions.1,
                self.flags,
            )
            .map_err(|_| 2)?,
        )
    }
    fn suspend(&mut self) -> Result<(), u8> {
        self.credit = None;
        self.output.discard();
        self.escape_since = None;
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
            // pass70 B10: OSC 52 between frames. A suspended terminal belongs
            // to the shell, so the text is dropped; a failed write only costs
            // the next frame a full repaint.
            Command::Copy { text, .. } => {
                if self.active && !self.awaiting_resume {
                    let sequence = protocol::osc52(text);
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
            if self.active {
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
                        self.start = 0;
                        self.end = n;
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
        output: BufferedWriter::new(FdWriter::new(tty, true)),
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
    };
    let result = session.run();
    // This synchronous handshake also handles initialization failure. The guard
    // remains the emergency backstop for panic, abrupt writer death or bad pipes.
    session.output.discard();
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
