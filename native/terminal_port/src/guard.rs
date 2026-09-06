//! Supervisor survives writer failure. It reaps the exact writer before emergency
//! restoration; during mode transactions the writer waits for an acknowledgement.
use crate::tty::Tty;
use std::{
    fs::File,
    io::{self, Read, Write},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::net::UnixStream,
    },
    sync::atomic::{AtomicI32, Ordering},
    time::{Duration, Instant},
};
static SIGNAL: AtomicI32 = AtomicI32::new(0);
static TERMINATE: AtomicI32 = AtomicI32::new(0);
extern "C" fn signal(sig: libc::c_int) {
    if matches!(sig, libc::SIGINT | libc::SIGTERM | libc::SIGHUP) {
        TERMINATE.store(sig, Ordering::Relaxed);
    } else {
        SIGNAL.store(sig, Ordering::Relaxed);
    }
}
pub fn terminating() -> bool {
    TERMINATE.load(Ordering::Relaxed) != 0
}
pub fn take_signal() -> i32 {
    SIGNAL.swap(0, Ordering::Relaxed)
}
fn install() -> io::Result<()> {
    for sig in [
        libc::SIGINT,
        libc::SIGTERM,
        libc::SIGHUP,
        libc::SIGTSTP,
        libc::SIGCONT,
    ] {
        let mut action: libc::sigaction = unsafe { std::mem::zeroed() };
        action.sa_sigaction = signal as *const () as usize;
        unsafe {
            libc::sigemptyset(&mut action.sa_mask);
        }
        if unsafe { libc::sigaction(sig, &action, std::ptr::null_mut()) } < 0 {
            return Err(io::Error::last_os_error());
        }
    }
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
        libc::signal(libc::SIGTTOU, libc::SIG_IGN);
    }
    Ok(())
}
pub fn run(beam_port: bool) -> i32 {
    if install().is_err() {
        return 1;
    }
    let mut tty = match if beam_port {
        Tty::beam_handoff()
    } else {
        Tty::open()
    } {
        Ok(tty) => tty,
        Err(_) => return 1,
    };
    let (mut supervisor, mut writer) = match UnixStream::pair() {
        Ok(pair) => pair,
        Err(_) => return 1,
    };
    // Retain an independent read endpoint for EOF observation while the writer
    // is OS-stopped. The guard never consumes protocol bytes from this endpoint.
    let parent_fd = unsafe { libc::fcntl(0, libc::F_DUPFD_CLOEXEC, 5) };
    if parent_fd < 0 {
        return 1;
    }
    let parent_pipe = unsafe { File::from_raw_fd(parent_fd) };
    let pid = unsafe { libc::fork() };
    if pid < 0 {
        return 1;
    }
    if pid == 0 {
        drop(supervisor);
        drop(parent_pipe);
        let code = crate::session::run(&mut writer, tty.file.as_raw_fd());
        // No inherited supervisor destructor or stdio flush after the fork.
        unsafe {
            libc::_exit(code);
        }
    }
    drop(writer);
    // Only the child writes Port responses. The extra parent read endpoint
    // observes EOF without consuming commands or keeping the write end alive.
    unsafe {
        libc::close(0);
        libc::close(1);
    }
    let mut stopping = None;
    let mut status = 0;
    let mut parent_gone = false;
    loop {
        let waited = unsafe { libc::waitpid(pid, &mut status, libc::WNOHANG) };
        if waited == pid {
            break;
        }
        if waited < 0 && io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
            break;
        }
        let terminal_signal = TERMINATE.swap(0, Ordering::Relaxed);
        if terminal_signal != 0 {
            unsafe {
                libc::kill(pid, terminal_signal);
                libc::kill(pid, libc::SIGCONT);
            }
            stopping.get_or_insert(Instant::now());
        }
        let sig = take_signal();
        if sig != 0 {
            unsafe {
                libc::kill(pid, sig);
            }
        }
        if stopping.is_some_and(|t| Instant::now().duration_since(t) > Duration::from_secs(1)) {
            unsafe {
                libc::kill(pid, libc::SIGKILL);
            }
        }
        let mut polls = [
            libc::pollfd {
                fd: supervisor.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            },
            libc::pollfd {
                fd: if parent_gone {
                    -1
                } else {
                    parent_pipe.as_raw_fd()
                },
                events: libc::POLLIN,
                revents: 0,
            },
        ];
        if unsafe { libc::poll(polls.as_mut_ptr(), 2, 20) } <= 0 {
            continue;
        }
        if polls[1].revents & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL) != 0 {
            parent_gone = true;
            unsafe {
                libc::kill(pid, libc::SIGTERM);
                libc::kill(pid, libc::SIGCONT);
            }
            stopping.get_or_insert(Instant::now());
        }
        // Darwin ignores HUP when events=0. Observe POLLIN too, but never
        // read: if only buffered parent data is ready, wait on the guard socket
        // for 20ms so withheld credits cannot turn this into a busy loop.
        if polls[0].revents == 0 && !parent_gone {
            unsafe {
                libc::poll(&mut polls[0], 1, 20);
            }
        }
        if polls[0].revents == 0 {
            continue;
        }
        let mut byte = [0];
        match supervisor.read(&mut byte) {
            Ok(1) => {
                let result = match byte[0] {
                    0..=7 => tty.activate(byte[0]),
                    8 => tty.restore(),
                    _ => Err(io::ErrorKind::InvalidData.into()),
                };
                let _ = supervisor.write_all(&[u8::from(result.is_ok())]);
                if result.is_err() {
                    // The paused writer receives the failure and can send the
                    // fixed response. Escalate only if it fails to exit promptly.
                    stopping.get_or_insert(Instant::now());
                }
            }
            Ok(_) => {
                stopping.get_or_insert(Instant::now());
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => (),
            Err(_) => {
                stopping.get_or_insert(Instant::now());
            }
        }
    }
    let restored = tty.restore().is_ok();
    if restored && libc::WIFEXITED(status) {
        libc::WEXITSTATUS(status)
    } else {
        1
    }
}
pub fn modes(socket: &mut UnixStream, flags: Option<u8>) -> Result<(), u8> {
    socket.write_all(&[flags.unwrap_or(8)]).map_err(|_| 6)?;
    let mut ack = [0];
    socket.read_exact(&mut ack).map_err(|_| 6)?;
    if ack[0] == 1 { Ok(()) } else { Err(6) }
}
