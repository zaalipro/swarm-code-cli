//! Descriptor-local terminal ownership. Never uses standard streams as a tty.
use std::{
    fs::{File, OpenOptions},
    io::{self, Write},
    os::fd::{AsRawFd, FromRawFd, RawFd},
    os::unix::fs::OpenOptionsExt,
    time::{Duration, Instant},
};

pub struct Tty {
    pub file: File,
    original: libc::termios,
    active: bool,
    flags: u8,
    original_status_flags: libc::c_int,
}
impl Tty {
    pub fn open() -> io::Result<Self> {
        // O_NONBLOCK: opening the tty of a vanished pty must fail, never wait
        // (rel F17). Blocking mode is restored before the flags are recorded.
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(libc::O_NONBLOCK | libc::O_NOCTTY)
            .open("/dev/tty")?;
        blocking(file.as_raw_fd())?;
        Self::from_file(file)
    }
    pub fn beam_handoff() -> io::Result<Self> {
        let mut input: libc::stat = unsafe { std::mem::zeroed() };
        let mut output: libc::stat = unsafe { std::mem::zeroed() };
        if unsafe {
            libc::isatty(0) != 1
                || libc::isatty(1) != 1
                || libc::fstat(0, &mut input) < 0
                || libc::fstat(1, &mut output) < 0
        } || input.st_mode & libc::S_IFMT != libc::S_IFCHR
            || output.st_mode & libc::S_IFMT != libc::S_IFCHR
            || input.st_rdev != output.st_rdev
        {
            return Err(io::ErrorKind::InvalidInput.into());
        }
        // Reopen only the kernel-reported name of the verified terminal. An
        // independent open-file description keeps native nonblocking flags and
        // Darwin's line-discipline bookkeeping off the BEAM/shell descriptor.
        let mut name = [0 as libc::c_char; 1024];
        if unsafe { libc::ttyname_r(0, name.as_mut_ptr(), name.len()) } != 0 {
            return Err(io::Error::last_os_error());
        }
        // O_NONBLOCK: an open of a revoked or vanished terminal fails at once
        // instead of parking this helper in the kernel (rel F17). The
        // descriptor is returned to blocking mode before its flags are recorded.
        let fd = unsafe {
            libc::open(
                name.as_ptr(),
                libc::O_RDWR
                    | libc::O_NOCTTY
                    | libc::O_NOFOLLOW
                    | libc::O_CLOEXEC
                    | libc::O_NONBLOCK,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        let file = unsafe { File::from_raw_fd(fd) };
        blocking(fd)?;
        let mut owned: libc::stat = unsafe { std::mem::zeroed() };
        if unsafe { libc::fstat(fd, &mut owned) < 0 || libc::isatty(fd) != 1 }
            || owned.st_mode & libc::S_IFMT != libc::S_IFCHR
            || owned.st_rdev != input.st_rdev
            || owned.st_dev != input.st_dev
            || owned.st_ino != input.st_ino
        {
            return Err(io::ErrorKind::InvalidInput.into());
        }
        if unsafe { libc::dup2(3, 0) < 0 || libc::dup2(4, 1) < 0 } {
            return Err(io::Error::last_os_error());
        }
        unsafe {
            libc::close(3);
            libc::close(4);
        }
        Self::from_file(file)
    }
    fn from_file(file: File) -> io::Result<Self> {
        let mut original = unsafe { std::mem::zeroed() };
        if unsafe { libc::tcgetattr(file.as_raw_fd(), &mut original) } < 0 {
            return Err(io::Error::last_os_error());
        }
        let original_status_flags = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GETFL) };
        if original_status_flags < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Self {
            file,
            original,
            active: false,
            flags: 0,
            original_status_flags,
        })
    }
    pub fn activate(&mut self, flags: u8) -> io::Result<()> {
        self.flags = flags;
        // Mark first: every partial initialization is eligible for restoration.
        self.active = true;
        nonblocking(self.file.as_raw_fd())?;
        let mut raw = self.original;
        unsafe {
            libc::cfmakeraw(&mut raw);
        }
        if unsafe { libc::tcsetattr(self.file.as_raw_fd(), libc::TCSANOW, &raw) } < 0 {
            return Err(io::Error::last_os_error());
        }
        let mut out = FdWriter::new(self.file.as_raw_fd(), false);
        out.write_all(b"\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?1004l\x1b[?2004l")?;
        if flags & 1 != 0 {
            out.write_all(b"\x1b[?1049h")?;
        }
        out.write_all(b"\x1b[?7l")?;
        if flags & 2 != 0 {
            out.write_all(b"\x1b[?1004h")?;
        }
        if flags & 4 != 0 {
            out.write_all(b"\x1b[?2004h")?;
        }
        out.flush()
    }
    pub fn restore(&mut self) -> io::Result<()> {
        if !self.active {
            return Ok(());
        }
        let mut out = FdWriter::new(self.file.as_raw_fd(), false);
        // A prior failed attempt still restored the original descriptor flags,
        // which may be blocking. Reestablish nonblocking on EVERY attempt so a
        // saturated sink cannot trap the guard inside write before its deadline.
        // Preserve setup failure as a result, never return before termios reset.
        let modes = nonblocking(self.file.as_raw_fd()).and_then(|()| {
            out.write_all(b"\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?1004l\x1b[?2004l")?;
            if self.flags & 1 != 0 {
                out.write_all(b"\x1b[?1049l")?;
            }
            // Set the final main-screen state after leaving alternate screen.
            out.write_all(b"\x1b[0m\x1b[0 q\x1b[?25h\x1b[?7h")
        });
        // Exact termios restoration must run even when terminal output or
        // nonblocking setup failed.
        let result =
            unsafe { libc::tcsetattr(self.file.as_raw_fd(), libc::TCSANOW, &self.original) };
        if result < 0 {
            return Err(io::Error::last_os_error());
        }
        // Darwin marks canonical input pending when ICANON changes. A
        // byte-count observation asks the line discipline to finish
        // that transition without consuming input (unlike a one-byte read).
        #[cfg(target_os = "macos")]
        if self.original.c_lflag & libc::PENDIN == 0 {
            let mut available: libc::c_int = 0;
            if unsafe { libc::ioctl(self.file.as_raw_fd(), libc::FIONREAD, &mut available) } < 0 {
                return Err(io::Error::last_os_error());
            }
        }
        let mut actual: libc::termios = unsafe { std::mem::zeroed() };
        if unsafe { libc::tcgetattr(self.file.as_raw_fd(), &mut actual) } < 0 {
            return Err(io::Error::last_os_error());
        }
        if actual.c_iflag != self.original.c_iflag
            || actual.c_oflag != self.original.c_oflag
            || actual.c_cflag != self.original.c_cflag
            || actual.c_lflag != self.original.c_lflag
            || actual.c_cc != self.original.c_cc
            || unsafe {
                libc::cfgetispeed(&actual) != libc::cfgetispeed(&self.original)
                    || libc::cfgetospeed(&actual) != libc::cfgetospeed(&self.original)
            }
        {
            return Err(io::ErrorKind::Other.into());
        }
        if unsafe {
            libc::fcntl(
                self.file.as_raw_fd(),
                libc::F_SETFL,
                self.original_status_flags,
            )
        } < 0
        {
            return Err(io::Error::last_os_error());
        }
        self.active = modes.is_err();
        modes
    }
}
pub fn size(fd: RawFd) -> io::Result<(u16, u16)> {
    let mut size: libc::winsize = unsafe { std::mem::zeroed() };
    if unsafe { libc::ioctl(fd, libc::TIOCGWINSZ, &mut size) } < 0 {
        return Err(io::Error::last_os_error());
    }
    if size.ws_col == 0 || size.ws_row == 0 {
        return Err(io::ErrorKind::InvalidData.into());
    }
    Ok((size.ws_col, size.ws_row))
}
fn blocking(fd: RawFd) -> io::Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags & !libc::O_NONBLOCK) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}
pub fn nonblocking(fd: RawFd) -> io::Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}
/// Bounded blocking at each write, interruptible by lifecycle signals.
pub struct FdWriter {
    fd: RawFd,
    interruptible: bool,
}
impl FdWriter {
    pub fn new(fd: RawFd, interruptible: bool) -> Self {
        Self { fd, interruptible }
    }
}
impl Write for FdWriter {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        let end = Instant::now() + Duration::from_millis(500);
        loop {
            if self.interruptible && crate::guard::terminating() {
                return Err(io::ErrorKind::BrokenPipe.into());
            }
            let n = unsafe { libc::write(self.fd, bytes.as_ptr().cast(), bytes.len()) };
            if n >= 0 {
                return Ok(n as usize);
            }
            let error = io::Error::last_os_error();
            if !matches!(
                error.kind(),
                io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
            ) {
                return Err(error);
            }
            if Instant::now() >= end {
                return Err(io::ErrorKind::TimedOut.into());
            }
            let mut poll = libc::pollfd {
                fd: self.fd,
                events: libc::POLLOUT,
                revents: 0,
            };
            unsafe {
                libc::poll(&mut poll, 1, 20);
            }
        }
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// Fixed-capacity batching with an explicit commit. Deliberately has no Drop
/// implementation: abandoning an errored/suspended paint must never write later.
pub struct BufferedWriter<W: Write> {
    inner: W,
    bytes: [u8; 8192],
    used: usize,
}
impl<W: Write> BufferedWriter<W> {
    pub fn new(inner: W) -> Self {
        Self {
            inner,
            bytes: [0; 8192],
            used: 0,
        }
    }
    pub fn discard(&mut self) {
        self.used = 0;
    }
}
impl<W: Write> Write for BufferedWriter<W> {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if bytes.len() > self.bytes.len() - self.used {
            self.flush()?;
        }
        if bytes.len() >= self.bytes.len() {
            return self.inner.write(bytes);
        }
        self.bytes[self.used..self.used + bytes.len()].copy_from_slice(bytes);
        self.used += bytes.len();
        Ok(bytes.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        // Reset before IO, so a partial failed write cannot replay at any later
        // flush or mode transaction. Painter invalidates its previous screen.
        let used = std::mem::replace(&mut self.used, 0);
        self.inner.write_all(&self.bytes[..used])?;
        self.inner.flush()
    }
}
